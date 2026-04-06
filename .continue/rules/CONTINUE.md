# CONTINUE.md - Project Guide

## 1. Project Overview

**Llama-swap** is a containerized service for managing multiple AI/ML models (Llama, Gemma, Stable Diffusion) with automatic model swapping and load balancing. It runs as a systemd container with GPU passthrough support for ROCm (AMD GPUs).

**Key Technologies:**
- **LXC (Linux Containers)** with systemd support
- **ROCm** (Radeon Open Compute) for AMD GPU acceleration
- **Podman/Docker** for container management
- **YAML-based configuration** for model definitions
- **Go** (llama-swap implementation)

**Architecture:**
- Systemd container with privileged GPU access
- LXC configuration for device passthrough (/dev/kfd, /dev/dri)
- Model group management with swap/exclusive options
- Health monitoring and automatic model unloading

## 2. Getting Started

### Prerequisites
- **Host**: Linux with AMD GPU (ROCm support)
- **Software**:
  - Podman (recommended) or Docker
  - Proxmox VE (for Proxmox setup script)
  - ROCm drivers and tools on host

### Installation

#### Option A: Local Development
```bash
# Build the container
./build.sh pull

# Build the image
./build.sh

# Run locally for testing
./build_and_run.sh
```

#### Option B: Proxmox VE Deployment
```bash
# Run setup script with container ID
./proxmox-host-scripts/setup-llama-lxc.sh <CONTAINER_ID>

# This will:
# - Create required groups (video, render)
# - Configure GPU passthrough
# - Create/update container
# - Setup systemd services
```

### Configuration

1. **Basic Run**:
```bash
# Run with default configuration
./run.sh

# Or with custom image
IMAGE_NAME=custom-image ./run.sh
```

2. **Configuration File** (`data/config.yaml`):
- Define models with their proxy URLs and commands
- Create groups for model swapping
- Set global TTL and logging options

### Running Tests
- Basic smoke test: `./build_and_run.sh`
- GPU passthrough test: Verify `/dev/kfd` and `/dev/dri` in container
- Model loading test: Verify models load via proxy URLs

## 3. Project Structure

```
.
├── build.sh              # Build script (pulls base image, builds llama-lxc target)
├── run.sh                # Main container runner with password setup
├── run_local.sh          # Local testing wrapper
├── build_and_run.sh      # Combined build and run for testing
├── container-files/
│   ├── config.default.yaml  # Example model configuration
│   ├── llama-server-wrapper.sh  # Wrapper for llama-server
│   ├── llama-swap.service       # systemd service definition
│   ├── prepare-llama.service    # Initial setup service
│   └── prepare.sh              # Config initialization script
└── proxmox-host-scripts/
    └── setup-llama-lxc.sh   # Proxmox VE deployment script
```

### Key Files Explained

**build.sh**: Uses Podman/Docker to build the `llama-lxc` target image from `ghcr.io/mostlygeek/llama-swap:rocm`

**run.sh**: 
- Creates container with GPU device mapping (--device /dev/kfd /dev/dri)
- Supports Podman (recommended), may work with Docker (untested)
- Handles root password setup for initial access
- Mounts `data/` directory for model storage

**llama-swap.service**: 
- Runs llama-swap with `--watch-config` flag
- Depends on prepare-llama.service
- Uses environment variables for GPU selection

**prepare-llama.service**: 
- One-shot service that initializes config.yaml
- Copies default config if missing

**setup-llama-lxc.sh**: 
- Host-level script for Proxmox VE
- Creates GPU passthrough configuration
- Patches LXC cgroup2 device allow rules
- Handles container ID mapping for GPU access

## 4. Development Workflow

### Coding Standards
- **Bash**: POSIX-compliant where possible, set -euo pipefail for safety
- **YAML**: Strict schema validation (refer to llama-swap schema)
- **Linux**: Follow systemd and LXC best practices

### Testing Approach
- Test with both Podman and Docker
- Verify GPU device nodes mount correctly
- Test model swapping with multiple models
- Verify health check endpoints

### Build Process
1. `build.sh`: Pulls base image, builds with BuildKit
2. `prepare.sh`: Sets up initial config
3. `run.sh`: Creates and starts container

### Contribution Guidelines
1. Modify `config.default.yaml` for new model types
2. Update service files when systemd behavior changes
3. Test with Proxmox setup script when making host-level changes
4. Document new configuration options

## 5. Key Concepts

### LXC Systemd Container
A special type of Linux container that runs systemd, allowing full Linux desktop/server services to run inside the container. Requires privileged mode with specific device access.

### GPU Passthrough
The process of exposing physical GPU devices to the container:
- `/dev/kfd`: AMD GPU kernel driver (ROCm)
- `/dev/dri/render*`: Direct rendering nodes
- Requires cgroup2 device rules for security

### Model Groups
Collections of models with swapping behavior:
- **swap: true**: Only one model runs at a time (exclusive)
- **swap: false**: All models run concurrently
- **exclusive: true**: Unloads other groups when activated

### ROCm Integration
Radeon Open Compute platform for AMD GPU acceleration:
- HSA_OVERRIDE_GFX_VERSION environment variable for GPU selection
- ROCR_VISIBLE_DEVICES for per-model GPU assignment
- KFD (Kernel Driver Framework) for compute access

## 6. Common Tasks

### Task 1: Add New Model
1. Edit `data/config.yaml`
2. Add model entry with:
   ```yaml
   "my-model":
     proxy: "http://127.0.0.1:${PORT}"
     cmd: |
       llama-server
       -hf model-name:GGUF:Q4_K_M
   ```
3. Restart service: `systemctl restart llama-swap.service`

### Task 2: Troubleshoot GPU Access
```bash
# Check if devices mounted
ls -la /dev/kfd /dev/dri/render*

# Check container LXC config
pct config <CT_ID> | grep -E "cgroup2|mount|idmap"

# Verify ROCm in container
ls /opt/rocm/bin/rocminfo
```

### Task 3: Update Proxmox Configuration
1. Run setup script: `./proxmox-host-scripts/setup-llama-lxc.sh <CT_ID>`
2. Verify cgroup2 rules in `/etc/pve/lxc/<CT_ID>.conf`:
   ```
   lxc.cgroup2.devices.allow: c 226:0 rwm    # kfd
   lxc.cgroup2.devices.allow: c 226:128 rwm  # renderD128
   ```

### Task 4: Debug Model Loading
```bash
# Check container logs
journalctl -u llama-swap.service -f

# Test proxy endpoint
curl http://localhost:8080/v1/models

# Inspect health check
curl http://localhost:8080/health
```

## 7. Troubleshooting

### Common Issues

**GPU Not Detected in Container**
- Verify `/dev/kfd` exists on host
- Check LXC cgroup2 rules: `grep "cgroup2.devices" /etc/pve/lxc/<CT_ID>.conf`
- Ensure root user added to video/render groups on host

**Model Loading Fails**
- Verify proxy URL is reachable
- Check model path in cmd section exists
- Ensure GGUF file format supported by llama-server

**Permission Denied on Data Directory**
- Check idmap configuration in LXC config
- Verify UID/GID mapping in `/etc/pve/lxc/<CT_ID>.conf`
- Ensure data directory ownership matches container user

**Service Won't Start**
- Check `prepare-llama.service` completed: `systemctl status prepare-llama.service`
- Verify no snapshots exist on container (requires snapshot removal for update)
- Check systemd dependencies: `systemctl cat llama-swap.service`

### Debugging Tips
- Enable debug logging: `logLevel: debug` in config.yaml
- Use `podman logs -f` or `journalctl -f` for real-time monitoring
- Check container network: `podman exec <CT_ID> ip addr`
- Verify device nodes: `podman exec <CT_ID> ls -l /dev/kfd`

## 8. References

### Documentation
- **Llama-swap**: https://github.com/mostlygeek/llama-swap
- **LXC Systemd Container**: https://man7.org/linux/man-pages/man8/lxc-systemd.8.html
- **ROCm**: https://rocm.docs.amd.com/
- **Podman**: https://podman.io/docs
- **Proxmox VE**: https://pve.proxmox.com/wiki/Category:Containers

### Important URLs
- **Base Image**: `ghcr.io/mostlygeek/llama-swap:rocm`
- **Config Schema**: `https://raw.githubusercontent.com/mostlygeek/llama-swap/main/config-schema.json`

---

*Note: Some sections may require verification based on specific deployment environments. Always test changes in a non-production container first.*