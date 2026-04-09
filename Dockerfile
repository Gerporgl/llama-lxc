FROM ghcr.io/mostlygeek/llama-swap:v199-rocm-b8702 as llama-lxc

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
RUN apt update && apt install -y git cmake ninja-build clang \
    zip \
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
    mv /app/LICENSE.md /opt/llama/llama-swap/LICENSE.md && \
    chmod 0000 /opt/llama/llama-swap/LICENSE.md && \
    rm -f /app/*.md /app/config* && \
    mkdir -p /opt/llama/llama-swap && \
    mv /app/llama-swap /usr/local/bin && \
    mv /app/* /opt/llama/ && \
    rm -fr /app && \
    # Create our own expected gid for video and render
    # so that our hsot script can expect pre defined numbers
    # that won't change
    groupadd -g 555 video_host && \
    groupadd -g 777 render_host && \
    # but also add the root user to every possible group (probably needed for podman local run)
    usermod -aG video_host,render_host,video,render root

ADD --chmod=0755 container-files/llama-server-wrapper.sh /usr/local/bin/llama-server

RUN echo "LLAMA_ARG_HOST=0.0.0.0" >> /etc/environment

ADD container-files/prepare-llama.service /etc/systemd/system/
ADD --chmod=755 container-files/prepare.sh /root

ADD container-files/llama-swap.service /etc/systemd/system/
ADD container-files/config.default.yaml /root
RUN mkdir -p /root/.cache && touch /root/.cache/motd.legal-displayed && \
    systemctl enable llama-swap.service && \
    systemctl enable prepare-llama.service

STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/sbin/init"]
