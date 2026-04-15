FROM docker.io/rocm/dev-ubuntu-24.04:7.2.2 as rocm-base

USER root
WORKDIR /root
ARG ROCM_VERSION=7.2.2
# Install "minimum" dependencies (4GB?), register ROCm 7.2.2 repository, and install runtime + tools
RUN sed -i 's|http://archive.ubuntu.com/ubuntu/|http://ubuntu.linux.n0c.ca/ubuntuarchive/|g' /etc/apt/sources.list.d/ubuntu.sources && \
    sed -i 's|http://security.ubuntu.com/ubuntu/|http://ubuntu.linux.n0c.ca/ubuntuarchive/|g' /etc/apt/sources.list.d/ubuntu.sources && \
    apt-get update && apt-get install -y --no-install-recommends \
    rocm-hip-runtime \
    amd-smi-lib \
    rocminfo \
    hipblas \
    rocblas \
    # Cleanup to keep image slim
    && apt-get purge -y gnupg2 \
    && apt-get autoremove -y \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

FROM rocm-base as rocm-dev
RUN apt update && apt install -y \
    # Vulkan related dev packages
    libssl-dev curl libxcb-xinput0 libxcb-xinerama0 libxcb-cursor-dev libvulkan-dev glslc spirv-headers \
    # ROCm packages
    hip-dev \
    hipblas-dev \
    rocblas-dev \
    rocm-dev \
    rocwmma-dev \
    # build essentials
    build-essential \
    cmake \
    git \
    libssl-dev \
    curl \
    libgomp1 \
    ninja-build \
    && apt-get autoremove -y \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

FROM rocm-dev as stable-diffusion
ARG stable_diffusion_tag
# Build stable-diffusion.cpp (sd-server and sd-cli)
ARG GPU_TARGETS="gfx1151;gfx1200;gfx1201;gfx1100;gfx1101;gfx1102;gfx1030;gfx1031;gfx1032"
RUN sed -i 's|http://archive.ubuntu.com/ubuntu/|http://ubuntu.linux.n0c.ca/ubuntuarchive/|g' /etc/apt/sources.list.d/ubuntu.sources && \
    sed -i 's|http://security.ubuntu.com/ubuntu/|http://ubuntu.linux.n0c.ca/ubuntuarchive/|g' /etc/apt/sources.list.d/ubuntu.sources && \
#    curl -fsSL https://packages.lunarg.com/lunarg-signing-key-pub.asc | tee /etc/apt/trusted.gpg.d/lunarg.asc && \
#    curl -fsSL -o /etc/apt/sources.list.d/lunarg-vulkan-noble.list http://packages.lunarg.com/vulkan/lunarg-vulkan-noble.list && \
    apt update && apt install -y \
    zip \
    nodejs npm && \
    curl -fsSL https://get.pnpm.io/install.sh | PNPM_VERSION=10.15.1 ENV="$HOME/.bashrc" SHELL="$(which bash)" bash - && \
    . /root/.bashrc && \
    echo $SD_GPU_TARGETS && \
    echo stable_diffusion_tag=${stable_diffusion_tag} && \
    git clone --branch ${stable_diffusion_tag} --depth 1 https://github.com/leejet/stable-diffusion.cpp && \
    cd stable-diffusion.cpp && \
    # Use the supported stable-ui variant of stable-diffusion front-end
    git clone --depth 1 https://github.com/leejet/stable-ui.git examples/server/frontend && \
    git submodule init && \
    git submodule sync && \
    git submodule update --recursive --depth 1 -- ./ ':!examples/server/frontend' && \
    cd .. && \
    mkdir stable-diffusion.cpp/build && \
    cd stable-diffusion.cpp/build && \
    cmake .. -G "Ninja" -DCMAKE_C_COMPILER=amdclang -DSD_BUILD_SHARED_LIBS=ON -DCMAKE_CXX_COMPILER=amdclang++ -DSD_HIPBLAS=ON -DCMAKE_BUILD_TYPE=Release -DGPU_TARGETS=$GPU_TARGETS -DAMDGPU_TARGETS=$GPU_TARGETS -DCMAKE_INSTALL_RPATH="\$ORIGIN" -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON  && \
    cmake --build . --config Release && \
    mkdir -p /opt/stable-diffusion && \
    cp ./bin/sd-server /opt/stable-diffusion/ && \
    cp ./bin/sd-cli /opt/stable-diffusion/ && \
    cp ./bin/libstable-diffusion.so /opt/stable-diffusion/ && \
    cd .. && rm build -R && \
    mkdir build && cd build && \
    cmake .. -G "Ninja" -DSD_BUILD_SHARED_LIBS=ON -DSD_VULKAN=ON  -DCMAKE_INSTALL_RPATH="\$ORIGIN" -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON && \
    cmake --build . --config Release && \
    mkdir -p /opt/stable-diffusion/vulkan && \
    cp ./bin/sd-server /opt/stable-diffusion/vulkan/ && \
    cp ./bin/sd-cli /opt/stable-diffusion/vulkan/ && \
    cp ./bin/libstable-diffusion.so /opt/stable-diffusion/vulkan/ && \
    cd .. && \
    apt remove -y git zip nodejs npm \
    && \
    apt autoremove -y && \
    apt clean && \
    mkdir -p /opt/stable-diffusion && \
    mv ./LICENSE /opt/stable-diffusion/LICENSE && \
    chmod 444 /opt/stable-diffusion/LICENSE && \
    rm -rf \
    /root/stable-diffusion.cpp \
    /var/lib/apt/lists/* \
    /var/tmp/* \
    /tmp/* \
    /root/.local/share/pnpm

FROM rocm-dev as llama-cpp

WORKDIR /app

ARG GPU_TARGETS="gfx1151;gfx1200;gfx1201;gfx1100;gfx1101;gfx1102;gfx1030;gfx1031;gfx1032"
ARG llama_build
RUN echo llama_build=$llama_build && \
    git clone --branch ${llama_build} --depth 1 https://github.com/ggml-org/llama.cpp.git && \
    cd llama.cpp && \
    export build_int=$(echo "$llama_build" | sed 's/[[:alpha:]]//g') && \
    HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -S . -B build \
        -DLLAMA_BUILD_NUMBER="$build_int" \
        -DGGML_HIP=ON \
        -DCMAKE_INSTALL_RPATH="\$ORIGIN" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -DGGML_HIP_ROCWMMA_FATTN=ON \
        -DAMDGPU_TARGETS="$GPU_TARGETS" \
        -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON \
        -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_TESTS=OFF \
    && cmake --build build --config Release -j$(nproc) && \
    mkdir -p /opt/llama && \
    mv /app/llama.cpp/LICENSE /opt/llama && \
    mv /app/llama.cpp/build/bin/* /opt/llama && \
    rm /app/llama.cpp/build -R && \
    cmake -B build -DGGML_NATIVE=OFF \
        -DLLAMA_BUILD_NUMBER="$build_int" \
        -DGGML_VULKAN=ON \
        -DCMAKE_INSTALL_RPATH="\$ORIGIN" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DGGML_BACKEND_DL=ON \
        -DGGML_CPU_ALL_VARIANTS=ON && \
    cmake --build build --config Release -j$(nproc) && \
    mkdir -p /opt/llama/vulkan && \
    mv /app/llama.cpp/build/bin/* /opt/llama/vulkan && \
    rm /app -rf

# Use our own rocm base and install our lxc base system and service
FROM rocm-base as llama-lxc 

RUN sed -i 's|http://archive.ubuntu.com/ubuntu/|http://ubuntu.linux.n0c.ca/ubuntuarchive/|g' /etc/apt/sources.list.d/ubuntu.sources && \
    sed -i 's|http://security.ubuntu.com/ubuntu/|http://ubuntu.linux.n0c.ca/ubuntuarchive/|g' /etc/apt/sources.list.d/ubuntu.sources && \
    apt-get update && \
    apt-get remove -y unminimize && \
    apt-get install -y --no-install-recommends \ 
    ca-certificates \
    software-properties-common && \
    apt-get install -y --no-install-recommends \
    libvulkan1 vulkan-tools mesa-vulkan-drivers \
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

# Get llama-swap binary directly from their github release download
# It seems simpler that way, and no extra delay for getting the latest llama-cpp, which is the most important
ARG llama_swap_build
RUN mkdir -p /opt/llama/llama-swap && \
    curl -sL https://github.com/mostlygeek/llama-swap/releases/download/v${llama_swap_build}/llama-swap_${llama_swap_build}_linux_amd64.tar.gz > llama-swap.tar.gz && \
    mkdir llama-swap && tar -xzvf llama-swap.tar.gz -C ./llama-swap && \
    mv ./llama-swap/llama-swap /usr/local/bin/ && mv ./llama-swap/LICENSE.md /opt/llama/llama-swap/ && rm -rf llama-swap.tar.gz llama-swap

# Copy llama.cpp binaries that we just build in a previous stage
COPY --from=llama-cpp /opt/llama /opt/llama

# Copy the stable-diffusion binaries that we compiled in a previous stage
COPY --from=stable-diffusion /opt/stable-diffusion /opt/stable-diffusion

RUN \
    # Create our own expected gid for video and render
    # so that our host script can expect pre defined numbers
    # that won't change
    groupadd -g 555 video_host && \
    groupadd -g 777 render_host && \
    # but also add the root user to every possible group (probably needed for podman local run)
    usermod -aG video_host,render_host,video,render root && \
    echo "PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/rocm/bin\"" > /etc/environment && \
    echo "LLAMA_ARG_HOST=0.0.0.0" >> /etc/environment && \
    echo "/opt/rocm/lib" > /etc/ld.so.conf.d/10-rocm.conf && \
    echo "/opt/rocm/lib/llvm//lib" >> /etc/ld.so.conf.d/10-rocm.conf

RUN ln -s /opt/llama/llama-server /usr/local/bin/llama-server && \
    ln -s /opt/llama/vulkan/llama-server /usr/local/bin/llama-server-vulkan && \
    ln -s /opt/stable-diffusion/sd-server /usr/local/bin/sd-server && \
    ln -s /opt/stable-diffusion/vulkan/sd-server /usr/local/bin/sd-server-vulkan
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
