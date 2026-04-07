# Llama-swap as a Systemd LXC Container

A containerized service for managing multiple models with automatic model swapping, designed for AMD GPUs with ROCm support, and specifically designed for Proxmox VE Containers.

It runs with systemd init so that you can SSH to the container, retain logs using journalctl and access it through Proxmox built-in tty console. Basic (traditional "Docker") containers with normal app entrypoint in Proxmox are often not ideal as stdout logs are lost.

This solution greatly improves the sysadmin user experience, and is probably the closest you can get to a bare-metal setup while using Proxmox for other VMs hosting usage, and you don't have to deal with hardware virtualization with iommu and sr-iov, etc. and it should still be secure enough since the container is running in unprivileged mode without nesting, with all uid/gid mapped differently as is the case with lxc (except for the gpu device, which is needed)

## Quick Start

### Prerequisites
- Linux with AMD GPU (ROCm enabled)
- Podman installed (Docker may work, but is unsupported)
  - This is mostly for running this locally for testing
- Proxmox VE (for Proxmox deployment)
  - This is the intended way of deploying this solution
  - Note: Most likely Requires Proxmox VE 9.1.7+ updated to latest kernel and firmware ("no subcription" or "test" may be needed), to properly support ROCm 7.2.1 and above on gfx1200 hardware
  - There is no need to install ROCm or anything special on the host for this to work, simply updating to the latest kernel and firmware packages seems sufficient

### How to use this container

**Option 1: Local Testing**
```bash
./build_and_run.sh
```

Or if you don't want to build the entire Dockerfile locally, you can use run.sh directly which will by default download a pre-build image from ghcr.io:
```bash
./run.sh
```

Note: unfortunately, the llama-swap rocm image is pretty big, around 7+ GB, so you may need to be patient while it downloads, depending on your internet connection.

Running the script above will ask for the containers root password (can be blank/empty), and will create and mount a local ./data folder on your computer.

After startup, the container should automatically have started llama-swap, you can check the journalctl logs to verify if was started successfully.

On a typical podman linux desktop setup, where you already have a working amdgpu compatible with ROCm, everything should hopefully work out of the box, as long as your distro kernel is recent enough (my distro uses zen kernels always up to date, so I am uncertain how it works if it is too old). No special user or group id mapping should be needed with podman (unlike proxmox lxc, explained in the next section)

There are some tricks also to enable offically unsupported amd gpus, using HSA_OVERRIDE_GFX_VERSION env in lllam-swap.service. You can see a commented example HSA_OVERRIDE_GFX_VERSION=10.3.0 (for a gfx1030 gpu, like RX 6750 XT) which worked pretty well overall for ROCm and llama-server.

**Option 2: Proxmox Deployment**

Pre requisites:
 - First of all, you will need to push your image somewhere to your own OCI registry (update: some pre-build images are now available on github ghcr.io)
 - In Proxmox VE, you need to go to your storage (i.e.: local), then under CT Templates, click "Pull from OCI Registry"
 - Enter the URL of the registry where this image is located
   - Pro tip: You can also use "Distribution registry" running as a CT container on your Proxmox local network as a simple solution for convenience along with registry-ui
   - Alternatively, you can now download the image from ghcr.io/gerporgl/llama-lxc:latest
     - Important note: The current tagging scheme does not really tell you which upstream version of llama-swap and sd-server you'll get from ghcr.io, but you can be certain that it was the latest rocm build at the time the image was pushed to ghcr.io... however, for that reason, you may want to build your own image locally afterward, as I may not often refresh the build on ghcr.io, unless I find some way to automate that.
 - Proxmox should then download the container image locally
 - Also, very important!:
   - The container is designed to use a second volume to store models and data
   - You need to create this additonal volume in Proxmox after the initial container was created (so don't start it right way!), and mount it under /root/data
   - With the default configs, models are designed to be stored under /root/data/models.
   - The main partition is relatively small (16GB), so you will run out of space soon if you don't create an additional volume. 128GB or more is recommended... depending on your usage, however it is also easy to grow the zfs size afterware without even restarting anything.
   - The use of a separate volume makes it easy to keep models and your config when you update the base image.
   - The config is stored under /root/data/config.yaml, so it should be carried over when you update the base image as well
   - The root folder contains a default config (/root/config.default.yaml), and if no config exists under /root/data or the volume is empty, it will be automatically copied before llama-swap starts.

If you successfully downloaded the container image to your Proxmox local storage, you should now be able to run the automated container setup script on the host by running it like this (you need to copy this to the host, for example under /root folder):
```bash
./setup-llama-lxc.sh <CONTAINER_ID>
```
You can check the script and adjust the container image location filename, it will likely be different from what I used. There is also more technical information in the script itself about what it does exactly.

Alternatively, you can create the LXC container yourself, or perhaps to start with, and then manually edit the lxc config file to pass the proper devices and set groups IDs and cgroupv2 if you are already familiar with this.

The script can also be run after the CT was created manually in Proxmox UI, it will update the existing LXC config to set all required permissions and devices required. Make sure you specify the correct container ID that you want to have updated or created!

The default network setup uses vmbr0, no vlan (or default), and DHCP for ipv4 and ipv6, default host DNS and no firewall.
Once started, the llama-swap UI should be available at http://x.x.x.x:8080 as well as all the other actual inference endpoints and proxyed endpoints. Where x.x.x.x is your new dynamically allocated ip address. This address should be visible in proxmox UI, almost immediately after the container started. Otherwise you can adjust the container to suit you need, if you like hardcoding ip addresses statically for example.

The script now has an experimental feature at the end to optimize the zfs flags, to set recordsize to 1M, xattr=sa and atime=off on the data volume (disk 1 or mp0), ans set zattr=sa on the rootfs. The zfs must be called rpool and mounted under /rpool currently, so this is optional if it doesn't work for you (you can answer no, or modify the script variables).

**Manual Setup**
```bash
./build.sh      # Only build the container image
./build.sh pull # Only build the container image, making sure to pull the latest llama-swap base image first
./run_local.sh  # Run the container that you just build locally
```

The "pull" option is very important if you want later on to get the latest llama-swap that will hopefully match closely sd-server compilation later on!

## What It Does / technical details

Llama-Swap runs as a systemd container with GPU passthrough, allowing you to:

- **Swap models automatically**: The concurrency of multiple modesl is based on the config.yaml and the groups configured. You can decide based on your need and the vram you have...
- **GPU passthrough**: Access AMD GPU devices via `/dev/kfd` and `/dev/dri`
- **Multi-model support**: Llama, Gemma, Stable Diffusion, and more
  - This is mostly thanks to the fact we uses llama-swap: this container uses llama-swap official container image as a base, but currently also compile and adds sd-server (stable-diffusion.cpp build for ROCm) to it.
  - The provided config.yaml example is an actual working setup on a 16GB vram AMDGPU, huggingface models should be downloaded automatically, but for stable diffusion, you'll have to download the model files manually (you can find the info on stable-diffusion.cpp project under the z-image-turbo section, or try your own models)

## Key Features

### GPU Support
- **ROCm Integration**: AMD GPU acceleration via HSA (Heterogeneous System Architecture <- that is what the AI said...)
- **Device Mapping**: Passes through `/dev/kfd` (kernel driver) and `/dev/dri/render*` (direct rendering)
- **GPU Assignment**: Control which GPU to use via `ROCR_VISIBLE_DEVICES` environment variable, already set in llama-swap service to only use GPU 0 (so that iGPU is not used if you have one), you can adjust this based on your hardware.

### Container Architecture
- **LXC Systemd Container**: Runs full Linux services inside the container
- **cgroup2 Device Rules**: Secure GPU access with proper isolation
- **Root Password Setup**: Optional initial access via `run.sh` for local testing, Proxmox will also setup root password automatically as usual as well as SSH authorized_keys.
- **systemd services**:
  - **llama-swap**: Main service, starts the llama-swap main server process, and manages the models
  - **prepare-llama**: Prepares the llama-swap service, mostly for the first time run. Creates the config file if it does not exists. llama-swap depends in this before it starts. It runs "prepare.sh"

## Configuration and model management

Edit `/root/data/config.yaml` to define:
- **Models**: Proxy URLs and server commands
- **Groups**: Collections with swap/exclusive behavior
- **Global Settings**: TTL, logging level, and health check options

Check the default bundled config for a good start: [config.default.yaml](container-files/config.default.yaml)

Full config example from llama-swap project: [config.example.yaml](https://github.com/mostlygeek/llama-swap/blob/main/config.example.yaml)

After saving the config, llama-swap should automatically reload it, there should be no need to restart the service via systemctl.

## See Also

- [llama-Swap](https://github.com/mostlygeek/llama-swap) documentation
- [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/z_image.md) z-image-turbo documentation and model download location

