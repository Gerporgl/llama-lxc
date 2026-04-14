# Use the AMD rocm base dev image as a builder for stable-diffusion
# using version 7.2.1 instead of 7.2 makes a huge different to performance,
# even for compiling (7.2 can take 50% more time per image step generation)
#FROM docker.io/rocm/dev-ubuntu-24.04:7.2.1 as stable-diffusion
FROM node:25-slim as stable-ui
ARG stable_diffusion_tag
# Build stable-diffusion.cpp (sd-server and sd-cli)
# We also compile the vulkan version, since it is fast to compile and has a small binary size
# and may be a viable option in some use cases. Combining both vulkan and rocm at the same time
# could lead to GPU crash needing a full power off and on in my experience... so use with caution, ymmv
ARG SD_GPU_TARGETS="gfx1151;gfx1200;gfx1201;gfx1100;gfx1101;gfx1102;gfx1030;gfx1031;gfx1032"
RUN apt update && apt install -y git python3 python3-venv python3-pip curl pkg-config libpixman-1-dev libcairo2-dev libpango1.0-dev && \
    curl -fsSL https://get.pnpm.io/install.sh | ENV="$HOME/.bashrc" SHELL="$(which bash)" bash - && \
    # Use the supported stable-ui variant of stable-diffusion front-end
    git clone --depth 1 https://github.com/leejet/stable-ui.git && \
    . /root/.bashrc && \
    cd stable-ui && \
    echo ============= install ================ && \
    pnpm -C ./ install && \
    echo ============= run build ================ && \
    pnpm -C ./ run build && \
    mkdir /dist && mv ./dist/index.html /dist && \
    apt remove -y git python3 python3-venv python3-pip curl pkg-config libpixman-1-dev libcairo2-dev libpango1.0-dev && \
    apt autoremove -y && \
    apt clean && \
    rm -rf \
    /root/stable-ui \
    /var/lib/apt/lists/* \
    /var/tmp/* \
    /tmp/* \
    /root/.local/share/pnpm

# Use bare ubuntu 24.04 and install rocm from amd
FROM ubuntu:24.04 as llama-lxc 

RUN sed -i 's|http://archive.ubuntu.com/ubuntu/|http://ubuntu.linux.n0c.ca/ubuntuarchive/|g' /etc/apt/sources.list.d/ubuntu.sources && \
    sed -i 's|http://security.ubuntu.com/ubuntu/|http://ubuntu.linux.n0c.ca/ubuntuarchive/|g' /etc/apt/sources.list.d/ubuntu.sources && \
    apt-get update && \
    apt-get remove -y unminimize && \
    apt-get install -y --no-install-recommends \ 
    ca-certificates \
    software-properties-common && \
    apt-get install -y --no-install-recommends \
    curl \
    openssh-server \
    sudo \
    # For convenience, instal nano
    nano \
    jq yq \
    # Network tools such as ping and host command
    iputils-ping \
    bind9-host \
    # Full systemd init entrypoint
    init \
    # Networkd based stack (better ipv6 and dhcp support than network interfaces when running on proxmox/lxc)
    #networkd-dispatcher \
    iproute2 && \
    apt-get -y remove dbus && \
    apt-get -y autoremove && \
    apt-get -y clean  && \
    rm -rf \
    /var/lib/apt/lists/* \
    /var/tmp/* \
    /tmp/* && \
    # Remove clutter messages on login
    rm /etc/update-motd.d/10* && rm /etc/update-motd.d/50* && rm /etc/update-motd.d/60* && \
    # Enable some service and remove a bunch of unwanted automatic timers
    # Updates will have to be run manually or with new containers builds
    systemctl enable systemd-networkd.service && \ 
    rm /etc/systemd/system/timers.target.wants/apt* && \
    rm /etc/systemd/system/timers.target.wants/dpkg* && \
    rm /etc/systemd/system/timers.target.wants/e2scrub* && \
    rm /etc/systemd/system/timers.target.wants/fstrim* && \
    rm /etc/systemd/system/timers.target.wants/motd* && \
    rm /usr/lib/systemd/system/apt-daily-upgrade.timer && \
    rm /usr/lib/systemd/system/apt-daily.timer && \
    rm /usr/lib/systemd/system/dpkg-db-backup.timer && \
    rm /usr/lib/systemd/system/e2scrub_all.timer && \
    rm /usr/lib/systemd/system/fstrim.timer && \
    rm /lib/systemd/system/motd-news.timer && \
    mkdir -p /home/ubuntu/.ssh && chown ubuntu:ubuntu /home/ubuntu/.ssh && \
    sed -i -e '2iTERM=xterm-color\\' /root/.profile && \
    cp /root/.profile /home/ubuntu/.profile && \
    cp /root/.bashrc /home/ubuntu/.bashrc 

USER root

WORKDIR /root

# Install "minimum" dependencies (4GB?), register ROCm 7.2.1 repository, and install runtime + tools
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    curl \
    gnupg2 \
    ca-certificates \
    && mkdir -p /etc/apt/keyrings \
    \
    # 1. Download and install the official AMD GPG key
    && curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor | tee /etc/apt/keyrings/rocm.gpg > /dev/null \
    \
    # 2. Register the ROCm 7.2.1 repository for Ubuntu 22.04 (Jammy)
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2.1 noble main" \

    | tee /etc/apt/sources.list.d/rocm.list \
    \
    # 3. Pin the repository to prioritize official AMD packages
    && echo 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600' \
    | tee /etc/apt/preferences.d/rocm-pin-600 \
    \
    # 4. Install only what's needed for llama-server and monitoring
    && apt-get update && apt-get install -y --no-install-recommends \
    rocm-hip-runtime \
    rocm-smi \
    rocminfo \
    hipblas \
    rocblas \
    \
    # 5. Cleanup to keep image slim
    && apt-get purge -y gnupg2 \
    && apt-get autoremove -y \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y libvulkan1 vulkan-tools mesa-vulkan-drivers && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Grab the latest release of llama.cpp from their release binaries
# It is often newer than the base image...
# Also grab the vulkan version, just like stable-diffusion, in case some prefer vulkan
ARG llama_build
RUN rm -rf /app && \
    cd /root && \
    echo llama_build=$llama_build && \
    mkdir -p /opt/llama/vulkan && \
    curl -sLO https://github.com/ggml-org/llama.cpp/releases/download/$llama_build/llama-$llama_build-bin-ubuntu-vulkan-x64.tar.gz && \
    tar -xzvf llama-$llama_build-bin-ubuntu-vulkan-x64.tar.gz && \
    mv ./llama-$llama_build/* /opt/llama/vulkan && \
    curl -sLO https://github.com/ggml-org/llama.cpp/releases/download/$llama_build/llama-$llama_build-bin-ubuntu-rocm-7.2-x64.tar.gz && \
    tar -xzvf llama-$llama_build-bin-ubuntu-rocm-7.2-x64.tar.gz && \
    mv ./llama-$llama_build/* /opt/llama/ && \
    rm -fr ./llama-$llama_build*

# Get llama-swap binary directly from their github release download
# It seems simpler that way, and no extra delay for getting the latest llama-cpp, which is the most important
ARG llama_swap_build
RUN mkdir -p /opt/llama/llama-swap && \
    curl -sL https://github.com/mostlygeek/llama-swap/releases/download/v${llama_swap_build}/llama-swap_${llama_swap_build}_linux_amd64.tar.gz > llama-swap.tar.gz && \
    mkdir llama-swap && tar -xzvf llama-swap.tar.gz -C ./llama-swap && \
    mv ./llama-swap/llama-swap /usr/local/bin/ && mv ./llama-swap/LICENSE.md /opt/llama/llama-swap/ && rm -rf llama-swap.tar.gz llama-swap

# Copy the stable-diffusion binaries that we compiled in a previous stage
#COPY --from=stable-diffusion /usr/local/bin/sd* /usr/local/bin/
RUN mkdir -p /opt/stable-ui/ && \
    mkdir -p /opt/stable-diffusion/ && \
    apt update && apt install -y unzip
COPY --from=stable-ui /dist/index.html /opt/stable-ui/
ARG stable_diffusion_tag
ADD --chmod=755 container-files/sd-server-wrapper.sh /usr/local/bin/sd-server
RUN echo stable_diffusion_tag=$stable_diffusion_tag && \
    url=$(curl -s https://api.github.com/repos/leejet/stable-diffusion.cpp/releases/tags/${stable_diffusion_tag} | jq -r '.assets[] | select(.browser_download_url | test("Linux.*rocm")) | .browser_download_url') && \
    curl -sL $url > sd.zip && \
    unzip sd.zip build/bin/sd-server build/bin/sd-cli build/bin/libstable-diffusion.so && \
    mv ./build/bin/sd-* /opt/stable-diffusion/ && \
    ln -s /opt/stable-diffusion/sd-cli /usr/local/bin/sd-cli && \
    cp ./build/bin/libstable-diffusion.so /usr/local/lib/ && \
    rm -rf build sd.zip

RUN \
    # Create our own expected gid for video and render
    # so that our host script can expect pre defined numbers
    # that won't change
    groupadd -g 444 render && \
    groupadd -g 555 video_host && \
    groupadd -g 777 render_host && \
    # but also add the root user to every possible group (probably needed for podman local run)
    usermod -aG video_host,render_host,video,render root && \
    echo "LLAMA_ARG_HOST=0.0.0.0" >> /etc/environment && \
    echo "/opt/rocm/lib" > /etc/ld.so.conf.d/10-rocm.conf && \
    echo "/opt/rocm-7.2.1/lib/llvm//lib" >> /etc/ld.so.conf.d/10-rocm.conf

ADD --chmod=0755 container-files/llama-server-wrapper.sh /usr/local/bin/llama-server
ADD container-files/llama-swap-launcher.sh /opt/llama/llama-swap/default-llama-swap-launcher

ADD container-files/prepare-llama.service /etc/systemd/system/
ADD --chmod=755 container-files/prepare.sh /usr/local/bin

ADD container-files/llama-swap.service /etc/systemd/system/
ADD container-files/config.default.yaml /opt/llama/llama-swap
RUN mkdir -p /root/.cache && touch /root/.cache/motd.legal-displayed && \
    systemctl enable llama-swap.service && \
    systemctl enable prepare-llama.service


STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/sbin/init"]
