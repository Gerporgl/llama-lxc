FROM ghcr.io/ggml-org/llama.cpp:server-rocm as llama-lxc

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

# Build and install stable-diffusion.cpp (sd-server and sd-cli)
# Specifically for rocm hip and gfx1200 (otherwise change it bellow)
# All rocm dependencies are already provided in the base image
# as part of the "small" 6 GB base image size...
# From that points of view, adding sd-server and sd-cli is a small
# size increase and is worth it.
RUN curl -fsSL https://packages.lunarg.com/lunarg-signing-key-pub.asc | tee /etc/apt/trusted.gpg.d/lunarg.asc && \
    curl -fsSL -o /etc/apt/sources.list.d/lunarg-vulkan-noble.list http://packages.lunarg.com/vulkan/lunarg-vulkan-noble.list && \
    apt update && apt install -y git cmake clang ninja-build \
    zip \
    vulkan-sdk \
    nodejs npm && \
    curl -fsSL https://get.pnpm.io/install.sh | PNPM_VERSION=10.15.1 ENV="$HOME/.bashrc" SHELL="$(which bash)" bash - && \
    . /root/.bashrc && \
    git clone --recursive https://github.com/leejet/stable-diffusion.cpp && \
    mkdir stable-diffusion.cpp/build && \
    cd stable-diffusion.cpp/build && \
    export GFX_NAME=gfx1200 && \
    cmake .. -G "Ninja" -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DSD_HIPBLAS=ON -DCMAKE_BUILD_TYPE=Release -DGPU_TARGETS=$GFX_NAME -DAMDGPU_TARGETS=$GFX_NAME -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON  && \
    cmake --build . --config Release && \
    cp ./bin/* /usr/local/bin/ && \
    cd .. && rm build -R && \
    mkdir build && cd build && \
    cmake .. -G "Ninja" -DSD_VULKAN=ON  && \
    cmake --build . --config Release && \
    cp ./bin/sd-server /usr/local/bin/sd-server-vulkan && \
    cp ./bin/sd-cli /usr/local/bin/sd-cli-vulkan && \
    apt remove -y vulkan-sdk && \
    apt remove -y git cmake ninja-build clang zip nodejs npm && \
    apt autoremove -y && \
    apt clean && \
    mkdir -p /opt/stable-diffusion.cpp && \
    mv ../LICENSE /opt/stable-diffusion.cpp/LICENSE && \
    chmod 0000 /opt/stable-diffusion.cpp/LICENSE && \
    rm -rf \
    /root/stable-diffusion.cpp \
    /var/lib/apt/lists/* \
    /var/tmp/* \
    /tmp/* \
    /root/.local/share/pnpm

# Some shenanigan to make llama-swap and llama-server in more standard locations
# Also add a clean wrapper that allow the usage of llama-server
# system wide, without having to make its library available system wide
# in case they would conflict with other tools such as sd-server, etc.
RUN mkdir -p /opt/llama/llama-swap && \
    # Create our own expected gid for video and render
    # so that our hsot script can expect pre defined numbers
    # that won't change
    groupadd -f video && \
    groupadd -f render && \
    groupadd -g 555 video_host && \
    groupadd -g 777 render_host && \
    # but also add the root user to every possible group (probably needed for podman local run)
    usermod -aG video_host,render_host,video,render root

ADD --chmod=0755 container-files/llama-server-wrapper.sh /usr/local/bin/llama-server
ADD container-files/llama-swap-launcher.sh /opt/llama/llama-swap/default-llama-swap-launcher

RUN echo "LLAMA_ARG_HOST=0.0.0.0" >> /etc/environment

ADD container-files/prepare-llama.service /etc/systemd/system/
ADD --chmod=755 container-files/prepare.sh /usr/local/bin

ADD container-files/llama-swap.service /etc/systemd/system/
ADD container-files/config.default.yaml /opt/llama/llama-swap
RUN mkdir -p /root/.cache && touch /root/.cache/motd.legal-displayed && \
    systemctl enable llama-swap.service && \
    systemctl enable prepare-llama.service

# Grab the latest release of llama.cpp from their release binaries
# it is often newer than the base image...
RUN cd /root && \
    export llama_build=$(curl -s https://api.github.com/repos/ggml-org/llama.cpp/releases/latest | jq -r '.tag_name') && \
    echo llama_build=$llama_build && \
    curl -sLO https://github.com/ggml-org/llama.cpp/releases/download/$llama_build/llama-$llama_build-bin-ubuntu-rocm-7.2-x64.tar.gz && \
    tar -xzvf llama-$llama_build-bin-ubuntu-rocm-7.2-x64.tar.gz && \
    mv ./llama-$llama_build/* /opt/llama/ && \
    rm -fr ./llama-$llama_build*

# Get llama-swap binary directly from their public image
# It seems simpler that way, and no extra delay for getting the latest llama-cpp, which is the most important
COPY --from=ghcr.io/mostlygeek/llama-swap:unified-vulkan /usr/local/bin/llama-swap /usr/local/bin

STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/sbin/init"]
