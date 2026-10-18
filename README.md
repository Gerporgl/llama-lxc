# Llama-swap as a Systemd LXC Container

A containerized service for managing multiple models with automatic model swapping, designed for AMD GPUs with ROCm support, and specifically designed for Proxmox VE Containers.

It runs with systemd init so that you can SSH to the container, retain logs using journalctl and access it through Proxmox built-in tty console. Basic (traditional "Docker") containers with normal app entrypoint in Proxmox are often not ideal as stdout logs are lost.

This solution greatly improves the sysadmin user experience, and is probably the closest you can get to a bare-metal setup while using Proxmox for other VMs hosting usage, and you don't have to deal with hardware virtualization with iommu and sr-iov, etc. and it should still be secure enough since the container is running in unprivileged mode without nesting, with all uid/gid mapped differently as is the case with lxc (except for the gpu device, which is needed)

Note for contributors (and AI agents working on this repo): see [AGENTS.md](AGENTS.md) for the build
pipeline internals, cross-file invariants and gotchas. Keep **both** `AGENTS.md` and this `README.md`
up to date with every change, and always confirm with the maintainer before committing or pushing.

## Quick Start

### Prerequisites
- Linux with AMD GPU (ROCm enabled)
- Podman installed (Docker may work, but is unsupported)
  - This is mostly for running this locally for testing
- Proxmox VE (for Proxmox deployment)
  - This is the intended way of deploying this solution
  - Note: Most likely Requires Proxmox VE 9.1.7+ updated to latest kernel and firmware ("no subcription" or "test" may be needed), to properly support ROCm 7.2.x and above on gfx1200 hardware
  - There is no need to install ROCm or anything special on the host for this to work, simply updating to the latest kernel and firmware packages seems sufficient

### Included engines (and optional ones)
- The image include the following engines:
  - llama.cpp: build from the latest pre-release
    - ROCM binaries: this is the default binaries with the usual names in global path (llama-cli, llama-server, etc.)
    - Vulkan binaries: avaialble as llama-server-vulkan, or other binaries are under /opt/llama/vulkan
  - stable-diffusion.cpp
    - Same idea as llama.cpp: build form latest release, both ROCM and vulkan
  - kokoro fastapi (tts):
    - Package is included, and ready to use. CPU only. Takes a lot of image space (python)... see bellow for more details.
- Not included, but used by the author daily:
  - [Strata](https://github.com/Niko1221/Strata):
    - A config example can be found in the default config yaml example, or on Strata github / doc repo.
    - At this point, Strata is not inlcude in the llama-lxc image itself, automated build steps are not clear to me.
    - However it is fairly easy to install manually in our container, basic packages have been included (git, build-essential, python).
      - Recommended method: clone their repo under /root/data/Strata (so that it persists after base image update), and use their setup.sh tools. It will download its own python rocm version (our ROCM does not have all the python libraries they require) and create an isolated .venv
      - You can specify a folder to persists their models:
        - ex.: ./setup.sh --setup --backend hip --data-dir /root/data/Strata-data/
        - Important note for Proxmox ZFS!
          - You may want to set you data volume recordsize to 32K (do this BEFORE running setup.sh and downloading the models! Otherwise, rewrite the entire dataset.)
          - This made a HUGE difference for me since before I had set this to 1M, which was causing large read ovehead (even on a 4 x nvme setup) and it was slow (Strata is using a lot of ramdom access reads)
          - When using `zpool iostat rpool 2 -r`, I was able to see that the optimal size for ISTA IQ3_S (and XXS) was 32K. The default 128K may still work, but is less ideal.
            - ex.: `zfs set recordsize=32K rpool/data/subvol-CTID-disk-1` (replace with correct ctid and data volume)
            - unsloths models seems to read a lot fo 4K chunks, this may be because I don't have enough RAM (64GB)
      - I often update the base llama-lxc rootfs image independently from Strata without any issue
    - For now this is the recommended method, they release new version fairly often (every day, sometimes more):
      - You can ssh to llama.lxc and just run the update.sh script to get their latest version
    - It works fairly well, and Qwen3.8 Flash seems to be currently the best model for a 64GB RAM and 16VRAM setup and to get a 128K context at 45 tokens/sec or more. Qwen3.8 27B is probaly the next best one, but it may be hard to fit more than 64K context and a decent quality, and it will be slower than if you meet the requirements of Strata (this is the author's own experience, YMMV).

### Important notes / updates

 * Text-to-speech is now included (Kokoro-FastAPI):
  * A CPU-only text-to-speech server, managed by llama-swap as the `kokoro-tts` model, on the OpenAI compatible `v1/audio/speech` endpoint
  * Nothing to download or configure by hand, the voice model is fetched on first use into `~/data/kokoro-model` (data volume)
  * It never touches the GPU, so it does not affect your vram budget. See [Text-to-speech (Kokoro TTS)](#text-to-speech-kokoro-tts)
  * This works well with open-webui if you are hosting it locally. Set the audio api to openai url to "http[s]://yourserver/v1
    * For tts voice, you can also mix voices, ex.: `am_michael(1.2)+bm_daniel(1)`
    * The model can be left as tts-1, if using the config example and aliases
    * Additional params:
```json
    {
      "response_format": "wav",
      "stream": true,
      "return_timing": true,
      "normalization_options": {
        "unit_normalization": true,
        "remove_emoji": true
      }
    }
```

 * Vulkan + ROCm binaries now included:
   * The container image now include both llama.cpp and stable-diffusion vulkan binaries as well as ROCm 7.2.4
   * You can change your config.yaml to point to these binaries, their location can be seen in the config.default.yaml, and a macro is already defined if you want to use them.
   * WARNING! Just be aware that if you mix both (use ROCm and vulkan at the same time), based on my experience, this could cause the amdgpu to have a hard crash (ring buffer errors in dmesg), and need a full card power off (host computer turned off completely), in order to recover from this.

  * GPU targets:
    * The ROCm build of stable-diffusion is now properly compiled with all gpu targets, not just gfx1200.
    * Previously this would have caused stable-diffusion to exit silently while generating an image if the gpu did not match. This should now work properly.

  * Latest stable-diffusion, patched with stable-ui:
    * On April 11 2026, stable-diffusion started to include a different webui (sdcpp-webui), instead of their original modified fork of stable-ui
    * This UI did not appear to work well out of the box with llama-swap, and had less features than stable-ui
    * For the time being, we get the latest source from stable-diffusion to compile it, but we patch it with the old stable-ui submodule.

### How to use this container

**Option 1: Local Testing**
```bash
./build_and_run.sh
```

Or if you don't want to build the entire Dockerfile locally, you can use run.sh directly which will by default download a pre-build image from ghcr.io:
```bash
./run.sh
```

Running the script above will ask for the containers root password (can be blank/empty), and will create and mount a local ./data folder on your computer.

After startup, the container should automatically have started llama-swap, you can check the journalctl logs to verify if was started successfully.

On a typical podman linux desktop setup, where you already have a working amdgpu compatible with ROCm, everything should hopefully work out of the box, as long as your distro kernel is recent enough (my distro uses zen kernels always up to date, so I am uncertain how it works if it is too old). No special user or group id mapping should be needed with podman (unlike proxmox lxc, explained in the next section)

There are some tricks also to enable offically unsupported amd gpus, using HSA_OVERRIDE_GFX_VERSION env in lllam-swap.service. You can see a commented example HSA_OVERRIDE_GFX_VERSION=10.3.0 (for a gfx1030 gpu, like RX 6750 XT) which worked pretty well overall for ROCm and llama-server.

**Option 2: Proxmox Deployment**

Pre requisites:
 - First of all, you will need to push your image somewhere to your own OCI registry, or use one of the pre-build images availabel in this gh repo (ghcr.io)
 - In Proxmox VE, you need to go to your storage (i.e.: local), then under CT Templates, click "Pull from OCI Registry"
 - Enter the URL of the registry where this image is located
   - If using the pre-build ghcr.io images, you should be able to enter ghcr.io/gerporgl/llama-lxc:latest (or ghcr.io/gerporgl/llama-lxc then "Query Tags" and select latest)
   - Pro tip: You can also use "Distribution registry" running as a CT container on your Proxmox local network as a simple solution for convenience along with registry-ui
 - Proxmox should then download the container image locally
 - Also, very important!:
   - The container is designed to use a second volume to store models and data
   - You need to create this additonal volume in Proxmox after the initial container was created (so don't start it right away!), and mount it under /root/data. You can also mount it under /root home folder directly if you want to preserve root user bash history, etc., a default skeleton will be seeded if it is deemed empty.
   - With the default configs, models are designed to be stored under /root/data/models.
   - The main partition is relatively small (16GB), so you will run out of space soon if you don't create an additional volume. 128GB or more is recommended... depending on your usage, however it is also easy to grow the zfs size afterware without even restarting anything.
   - The use of a separate volume makes it easy to keep models and your config when you update the base image.
   - The config is stored under /root/data/config.yaml, so it should be carried over when you update the base image as well
   - The root folder contains a default config (/opt/llama/llama-swap/config.default.yaml), and if no config exists under /root/data or the volume is empty, it will be automatically copied before llama-swap starts.

If you successfully downloaded the container image to your Proxmox local storage, you should now be able to run the automated container setup script on the host by running it like this (you need to copy this to the host, for example under /root folder):
```bash
./setup-llama-lxc.sh <CONTAINER_ID>
```
You can check the script and adjust the container image location filename, it will likely be different from what I used. There is also more technical information in the script itself about what it does exactly.

Alternatively, you can create the LXC container yourself, or perhaps to start with, and then manually edit the lxc config file to pass the proper GPU devices and set groups IDs and cgroupv2 if you are already very familiar with this.

The script can also be run after the CT was created manually in Proxmox UI, it will update the existing LXC config to set all required permissions and devices required. Make sure you specify the correct container ID that you want to have updated or created!

The default network setup uses vmbr0, no vlan (or default), and DHCP for ipv4 and ipv6, default host DNS and no firewall.
Once started, the llama-swap UI should be available at http://x.x.x.x:8080 as well as all the other actual inference endpoints and proxyed endpoints. Where x.x.x.x is your new dynamically allocated ip address. This address should be visible in proxmox UI, almost immediately after the container started. Otherwise you can adjust the container to suit you need, if you like hardcoding ip addresses statically for example.

The script now has an experimental feature at the end to optimize the zfs flags, to set recordsize to 1M, xattr=sa and atime=off on the data volume (disk 1 or mp0), ans set zattr=sa on the rootfs. The zfs must be called rpool and mounted under /rpool currently, so this is optional if it doesn't work for you (you can answer no, or modify the script variables).

**Manual Setup**
```bash
./build.sh      # Only build the container image
./run_local.sh  # Run the container that you just build locally
```

By default, the build script will include the following GPU targets:
```
"gfx1151;gfx1200;gfx1201;gfx1100;gfx1101;gfx1102;gfx1030;gfx1031;gfx1032"
```
This signficiantly increases build times (over 15 minutes with a 16 core CPU, hours on a quad core), if you only have one GPU familiy that you need to support, you can override this easily by running the build script like this:
```
GPU_TARGETS="gfx1030" ./build.sh 
```
This will build both stable-diffusion.cpp and llama.cpp for these GPU tagets only, and will be a lot faster to build, and will produce smaller images.

This only apply to ROCm binaries, the vulkan binaries do not target any specific architecture and are generic.

The Kokoro text-to-speech server is CPU only and has no GPU target. The only build option that matters is
whether you want Japanese voices, which need a ~550MB dictionary that is not installed by default:
```
KOKORO_JAPANESE=true ./build.sh
```

## What It Does / technical details

Llama-Swap runs as a systemd container with GPU passthrough, allowing you to:

- **Swap models automatically**: The concurrency of multiple models is based on the config.yaml and the groups configured. You can decide based on your need and the vram you have...
- **GPU passthrough**: Access AMD GPU devices via `/dev/kfd` and `/dev/dri`
- **Multi-model support**: Llama, Gemma, Stable Diffusion, Kokoro text-to-speech, and more
  - This is mostly thanks to the fact we uses llama-swap: this container uses llama-swap official container image as a base, but currently also compile and adds sd-server (stable-diffusion.cpp build for ROCm) to it.
  - The provided config.yaml example is an actual working setup on a 16GB vram AMDGPU, huggingface models should be downloaded automatically, but for stable diffusion, you'll have to download the model files manually (you can find the info on stable-diffusion.cpp project under the z-image-turbo section, or try your own models)

## Key Features

### GPU Support
- **ROCm Integration**: AMD GPU acceleration via HSA (Heterogeneous System Architecture)
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

## Text-to-speech (Kokoro TTS)

The image bundles [Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI), a FastAPI server for the
[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) voice model, which exposes the OpenAI compatible
`v1/audio/speech` endpoint (plus a small web player). It is installed under `/opt` like the other apps,
and llama-swap starts it on demand as if it were just another model:

- `/opt/kokoro`: upstream checkout, plus its own self contained python virtualenv (installed with `uv` from
  their lock file, **CPU torch only**: no ROCm, no CUDA, no GPU of any sort is used for TTS)
- `kokoro-server`: the launcher, on the PATH (`/opt/kokoro/bin/kokoro-server`), accepts `--port` and `--host`
  and can be run by hand exactly the same way llama-swap runs it
- `~/data/kokoro-model/`: weights and caches, on the data volume. Created automatically, and the 327MB
  `v1_0/kokoro-v1_0.pth` is downloaded on first start using upstream's own download script (checksum
  verified, no-op on every start after that). No weight is baked into the image

The default config defines the `kokoro` macro and a `kokoro-tts` model, so speech works out of the box on
port 8080. The first request is slow (the server has to boot and load the model, and on the very first run
it also downloads it), after that it is close to instant:

```bash
curl -H 'Content-Type: application/json' \
  -d '{"input":"Hello there!","model":"kokoro-tts","voice":"af_heart","response_format":"mp3"}' \
  http://<container-ip>:8080/v1/audio/speech -o hello.mp3
```

### Pointing clients at it

llama-swap routes OpenAI requests by the `model` name **in the request body**, it never mounts model names
into the URL, so the base URL of any client is llama-swap's own root, and the model name is `kokoro-tts`:

| what | url |
| --- | --- |
| speech (OpenAI compatible) | `POST http://<container-ip>:8080/v1/audio/speech` with `"model": "kokoro-tts"` |
| voice list | `GET http://<container-ip>:8080/v1/audio/voices?model=kokoro-tts` |
| model listing | `GET http://<container-ip>:8080/v1/models` — advertised as `text->audio`, `capabilities.audio_speech` |
| its own web player | `http://<container-ip>:8080/upstream/kokoro-tts/` (llama-swap's "open engine UI" button) |

For example in Open WebUI (Settings → Audio): TTS API base URL `https://your-host/v1`, TTS model
`kokoro-tts`, voice `af_heart`. The default config also declares `tts-1` and `tts-1-hd` as *aliases* of the
model, so clients that hardcode an OpenAI TTS model name work unchanged as well; drop those aliases if you
add another engine that should own those names. There is **no** `/<model-name>/v1/...` route: llama-swap
answers 404 for `http://<container-ip>:8080/kokoro-tts/v1/models`. If a client insists on a base URL that
contains the model name, `/upstream/kokoro-tts/v1` does work (it is the raw passthrough, the model still
swaps in and out), but it bypasses llama-swap's routing, name rewriting and capability reporting, so prefer
`/v1` whenever the client lets you set the model name.

### Configuration

The image's [config.default.yaml](container-files/config.default.yaml) is the reference: its `kokoro` macro
and the `kokoro-tts` model entry show every setting we rely on, with a comment for each one. Your own
`~/data/config.yaml` is never rewritten for you, so copy new keys there by hand. Anything else is a plain
environment variable in that model's `env:` list; upstream keeps the full list in
[docs/configuration.md](https://github.com/remsky/Kokoro-FastAPI/blob/master/docs/configuration.md).

A few notes for day to day use:

- The voices are Kokoro's own names, not OpenAI's (`alloy` alone will fail), and the first letter is the
  language (`a`/`m` American, `b` British, `e` Spanish, `f` French, `h` Hindi, `i` Italian, `j` Japanese,
  `p` Portuguese, `z` Mandarin); a hyphen combines two voices. `GET
  http://<container-ip>:8080/v1/audio/voices?model=kokoro-tts` lists what is installed. For custom
  voicepacks point `VOICES_DIR` to a folder on the data volume.
- Like any other model it unloads after `globalTTL` of inactivity. It never competes for vram (CPU only) but
  holds roughly 0.5GB of system RAM while loaded, so add it to `persistent-group` if you want it warm.
- Japanese voices are **not** installed by default, they need the full UniDic dictionary (~550MB). Build
  with `KOKORO_JAPANESE=true ./build.sh` if you need them. Every other language works.

The size cost is roughly 1.1GB on top of the previous image (the CPU torch wheel is the bulk of it), plus
about 350MB of weights on the data volume (the 327MB model, its config, and 21MB of optional voice tuning
weights that upstream's download script also fetches).

## Huggingface and model cleanup

The container image includes the Huggingface CLI (`hf` command), so you can list and prune the cache by hand (`hf cache list`, `hf cache prune`).

A helper script, `cleanup-hf-cache.sh`, reclaims the space llama.cpp leaves behind. It scans `~/data/config.yaml` (or the files you give it with `--keep-file`) for every `-hf <repo>[:<quant>]` and `-hfr <repo> [-hff <file>]` reference, then cleans in two tiers:

- **Orphan models** — a cached repo with **no reference at all** in the config is wiped completely: every revision, every quant, and the `mmproj*` (vision) files too. This is the usual drift: you tried a model, removed it from the config, and only its mmproj stayed behind — which is easy to miss because `hf cache list` still reports the repo.
- **Quant variants** — a repo that **is** referenced keeps its `mmproj*` files, but any other cached `.gguf` of that repo matching none of its referenced quants is deleted. Useful when the same model is used twice with two different quants: the quants you dropped from the config are freed.

Quant matching mirrors llama.cpp: the quant tag is compared as a case-insensitive substring of the cached file name. `-hf repo` without a quant (and `:latest`) means `Q4_K_M`, `:all` keeps every file of the repo.

It then always runs `hf cache prune` and sweeps leftovers: broken snapshot symlinks, blobs that no snapshot links anymore, empty cache dirs, empty lock dirs. Files named `*.incomplete` (a download in progress) are never touched, and `sd/` or any other non-Huggingface folder in `~/data/models` is ignored.

Models listed in config.yaml but **commented out** still count as referenced and are not deleted. To really free a model, remove the line from the config (or back the config up somewhere else first).

```
cleanup-hf-cache.sh --dry-run    # show the plan only, delete nothing (start here)
cleanup-hf-cache.sh              # show the plan, then ask before deleting
cleanup-hf-cache.sh --yes        # no prompt, for scripted use
cleanup-hf-cache.sh --keep-file other.yaml --verbose
```

If the scanned files contain no model reference at all, the script refuses to delete anything unless you pass `--allow-empty-keep-list`, so a wrong `--keep-file` path can never wipe the whole cache. Non-interactive runs (no TTY) need `--yes`.

The same removals can be done by hand with the CLI: `hf cache rm model/<repo>` (whole repo, the `model/` prefix is required) and `hf cache rm hf://models/<repo>/<file>` (one quant variant); both accept `--dry-run`.

## See Also

- [llama-Swap](https://github.com/mostlygeek/llama-swap) documentation
- [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/z_image.md) z-image-turbo documentation and model download location
