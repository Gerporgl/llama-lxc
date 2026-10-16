# AGENTS.md — llama-lxc

Purpose: build a **systemd-based LXC-ready container image** (Ubuntu 24.04 + ROCm) that runs
[llama-swap](https://github.com/mostlygeek/llama-swap) as the main service, with locally-compiled
**llama.cpp** and **stable-diffusion.cpp** binaries (ROCm **and** Vulkan variants), for **AMD GPUs
(ROCm)**, deployed mainly as an **unprivileged Proxmox VE container** with `amdgpu` passthrough.
Local testing is done with **podman** (docker is tolerated but unsupported).

## Hard rules for every agent session

1. **Always keep `AGENTS.md` (this file) and `README.md` up to date** in the same change as the code.
   If you learn a gotcha, add it here; if you change behavior, config, build, or deploy flow, update
   the README. Users read the README; agents read this file first.
2. **Never `git commit` or `git push` (including to GitHub / tags) without explicit confirmation from
   the user.** Prepare the change, show the diff/summary, ask, and wait. Never force-push, never push
   a tag (tags trigger CI image builds/pushes to ghcr.io).
3. Do not invent hardware/ROCm behavior — the whole project is empirical (see Gotchas).
4. **Do not build or run the container image from an agent session** (no `./build.sh`, no `podman build`,
   no `build_and_run.sh`, not even a single stage). The ROCm stages take ~15 min on a 16-core machine and
   up to ~2 h on a quad core, they pull multi-GB base layers, and the build output floods the context.
   The user builds images on their own desktop (with layer cache) or lets CI do it. Validate with cheap
   static checks only, and test runtime behavior against an already-running container if the user gives
   access. Build something only when the user explicitly asks for it in this session, and then redirect
   output to a file and report only a short tail. Never let a "syntax check" command expand into running
   a script: `bash -n $(git ls-files '*.sh')` checks only the first file, and dropping `-n` from a loop
   over `git ls-files '*.sh'` executes `build.sh` (this actually happened — it started a full image build).

## Repository layout

| Path | What it is |
|---|---|
| `Dockerfile` | 5-stage build (see below). Single source of truth for the image. |
| `build.sh` | Resolves latest upstream versions from GitHub APIs, then builds each stage separately. |
| `run.sh` / `run_local.sh` / `build_and_run.sh` | Local podman/docker test harness (root password prompt, `./data` bind mount, ports 2222→22, 8888→8080). |
| `container-files/` | Files injected into the image: systemd units, `prepare.sh`, launcher, `config.default.yaml`, `cleanup-hf-cache.sh`, MOTD. |
| `proxmox-host-scripts/setup-llama-lxc.sh` | Runs **on the Proxmox host**: creates/patches the CT config for GPU passthrough + idmaps, optional ZFS tuning. |
| `.github/workflows/docker-image.yml` | CI: builds on tag `v*`, weekly schedule (Fri 22:37 UTC), manual dispatch; pushes `:latest` + versioned tag to ghcr.io. |

## Build pipeline (order matters)

Stages, in build order (`build.sh` builds them one at a time with `--target`):

1. `rocm-dev` — Ubuntu 24.04 + ROCm **dev** packages (build base for compiling).
2. `stable-diffusion` — compiles `sd-server`/`sd-cli` with `amdclang`, `-DSD_HIPBLAS=ON`,
   `GPU_TARGETS`; then a **second** cmake pass with `-DSD_VULKAN=ON`. Output → `/opt/stable-diffusion/{bin,lib,vulkan/{bin,lib}}`.
   The upstream frontend submodule is **replaced by a clone of `leejet/stable-ui`** (upstream switched to
   `sdcpp-webui`, which works badly with llama-swap). Keep this patch unless upstream reverts.
3. `llama-cpp` — `ggml-org/llama.cpp` with `GGML_HIP` (+`ROCWMMA_FATTN`, `GGML_BACKEND_DL`,
   `GGML_CPU_ALL_VARIANTS`), then a Vulkan pass. Output → `/opt/llama/{bin,vulkan/bin}`.
   `llama.cpp`'s build number is derived from the git tag: `b11539` → `11539` (`DLLAMA_BUILD_NUMBER`).
4. `rocm-base` — Ubuntu 24.04 + ROCm **runtime only** (`rocm-hip-runtime`, `amd-smi-lib`, `rocminfo`, `hipblas`),
   then heavy trimming of `/opt/rocm` incl. **hipblaslt Tensile libs for gfx families not in `GPU_TARGETS`**.
5. `llama-lxc` — final image: `FROM rocm-base`, installs `init` (systemd as `ENTRYPOINT ["/sbin/init"]`,
   `STOPSIGNAL SIGRTMIN+3`), sshd, `systemd-networkd`, python + `huggingface_hub` (`hf` CLI),
   downloads the **llama-swap release tarball** (not built), copies compiled binaries, enables units.

`build.sh` writes `rocm_version.txt`, `llama_version.txt`, `sd_version.txt`, `llama_swap_version.txt`,
and `image_version.txt` (all gitignored). `image_version.txt` is read by CI and also baked into the OCI
`org.opencontainers.image.version` label — **single source of truth, do not fork it**.

Key build args: `ROCM_VERSION` (currently 7.2.4), `GPU_TARGETS`, `llama_build`, `stable_diffusion_tag`,
`llama_swap_build`, `IMAGE_VERSION`. Override targets to make builds sane: `GPU_TARGETS="gfx1030" ./build.sh`.
Default is a 9-target list → **15+ min on 16 cores, hours on a quad core**. Vulkan builds are arch-agnostic.
Only stages whose `FROM` is a public image (`rocm-dev`, `rocm-base`) may receive `--pull`/`--pull=newer`
(`build.sh pull`); passing a pull flag to stages that `FROM`/`COPY --from` local tags **breaks the build**
(commit `7a27327`). `build.sh` prefers podman; `CT_TOOL=docker` forces docker (what CI does).

## Runtime contract inside the container

- All persistent state lives on the **data volume at `/root/data`**:
  `config.yaml`, `llama-swap-launcher`, `models/` (and `models/sd/` for SD files).
  This is what survives base-image upgrades — never put user-editable state elsewhere.
- `prepare-llama.service` (oneshot, required by `llama-swap.service`) runs `prepare.sh`:
  seeds `/root` from `/opt/root-home-default/` if `/root/.profile` is missing, copies
  `config.default.yaml` → `/root/data/config.yaml` and the default launcher → `/root/data/llama-swap-launcher`
  if absent. Idempotent; existing user files are never overwritten.
- `llama-swap.service` → `ExecStart=/root/data/llama-swap-launcher` → `exec llama-swap --config
  /root/data/config.yaml --watch-config`. `Restart=always`. Env from `/etc/environment`
  (`LLAMA_CACHE=/root/data/models`, `HF_HUB_CACHE=/root/data/models/`, `ROCR_VISIBLE_DEVICES=0`,
  `HF_XET_HIGH_PERFORMANCE=1`, PATH includes `/opt/rocm/bin:/opt/llama/bin:/opt/stable-diffusion/bin`).
  Per-GPU overrides such as `HSA_OVERRIDE_GFX_VERSION` go in the **launcher on the volume** or commented
  in the unit (example: `10.3.0` for gfx1030 / RX 6750 XT).
- Binary names used by config macros: `llama-server`, `sd-server` (ROCm, from PATH) and
  `llama-server-vulkan`, `sd-server-vulkan` (symlinks in `/usr/local/bin` → `/opt/*/vulkan/bin`).
- `config.default.yaml` uses llama-swap **macros** (`llama`, `llama-vulkan`, `sd`, `sd-vulkan`,
  `models_dir`, `default_ctx`, `default_llama_args`) plus `models:` and `groups:`; llama-swap hot-reloads
  config, no systemctl restart needed.
- Inside the CT, useful commands (also in the MOTD `/etc/llama-lxc-motd`):
  `journalctl -u llama-swap -f`, `systemctl restart llama-swap`, `nano ~/data/config.yaml`,
  `hf cache list`, `hf cache prune`, `cleanup-hf-cache.sh`, `watch amd-smi`.
- `cleanup-hf-cache.sh` builds a KEEP list by scanning `~/data/config.yaml` (or `--keep-file` files) for
  `-hf <repo>[:<quant>]` / `-hfr <repo> [-hff <file>]` tokens (**commented lines still count as kept**,
  and the token must be on the same line as its repo). Two tiers: a repo with **no** reference is an
  orphan and is wiped entirely (all revisions + mmproj), while a referenced repo only loses the quant
  variants that match none of its kept quants (its `mmproj*` files are never touched). Quant tags are
  matched as case-insensitive substrings of the cached file name (same rule llama.cpp uses); no quant /
  `latest` == `Q4_K_M`, `all` == everything. Flags: `--dry-run`, `--yes`, `--keep-file`, `--cache-dir`,
  `--allow-empty-keep-list`, `--verbose`. Ends with `hf cache prune` + a sweep of broken snapshot links,
  unlinked blobs, empty repo/lock dirs; never touches `*.incomplete`.

## Proxmox deployment (the intended target)

- Pull the OCI image in Proxmox (CT Templates → "Pull from OCI Registry"), e.g.
  `ghcr.io/gerporgl/llama-lxc:latest`; `setup-llama-lxc.sh` defaults to a manually-imported
  `/var/lib/vz/template/cache/llama-lxc_latest.tar` — check/adjust `DEFAULT_IMAGE`.
- `setup-llama-lxc.sh <CTID>`: adds `lxc.cgroup2.devices.allow` for `/dev/kfd` (major 511) and
  `/dev/dri/render*`, bind-mounts `dev/kfd` + `dev/dri`, and writes **reverse uid/gid idmaps**; backs up the
  CT conf, refuses to run if the CT has snapshots, and is safe/idempotent to re-run.
  Then the user must add a **second volume/mountpoint at `/root/data`** (rootfs is only 16 GB;
  128 GB+ recommended). Optional ZFS tuning assumes pool `rpool` at `/rpool`, sets `recordsize=1M`,
  `xattr=sa`, `atime=off`, `sync=disabled`.
- **Critical cross-file invariant:** the image hard-codes container GIDs `render=444`, `video_host=555`,
  `render_host=777` (Dockerfile) and `setup-llama-lxc.sh` hard-codes `video_gid_ct=555`, `render_gid_ct=777`
  and builds the host↔container gid idmap around those exact numbers, so the host's real `video`/`render`
  GIDs map 1:1 into the CT. If you change one side you **must** change the other, and keep the
  `<`-comparison ordering logic that handles host GIDs above/below 777.
- Network defaults: `vmbr0`, DHCP v4+v6, no firewall; llama-swap UI/API on port **8080**.
  Proxmox needs VE 9.1.7+ with latest kernel/firmware for ROCm 7.2.x on gfx1200; **no ROCm needed on the host**.

## Gotchas / lessons already learned

- **Do not mix ROCm and Vulkan binaries at the same time** — observed hard `amdgpu` crash (ring buffer
  errors in dmesg) requiring a full power-off of the machine to recover.
- ROCm binaries must be compiled for the right gfx target(s); a mismatch made `sd-server` **exit silently**
  mid-generation. The default multi-target list fixes this at the cost of build time/image size.
- `--device /dev/dri/renderD128` alone is **not** enough in LXC; the whole `/dev/dri` dir must be bind-mounted,
  and `/dev/kfd` already exposes all GPUs to ROCm — GPU selection is done with `ROCR_VISIBLE_DEVICES` inside
  the CT (`-1` forces CPU, used for the small persistent autocomplete model).
- systemd-in-container details that matter: `ENTRYPOINT ["/sbin/init"]`, `STOPSIGNAL SIGRTMIN+3`
  (`poweroff` to stop), `init` package installed, `dbus` removed, apt/dpkg/fstrim/motd **timers deleted**
  (updates are manual / via new images), `systemd-networkd` enabled instead of ifupdown for IPv6/DHCP in LXC.
- `run.sh` needs different flags per runtime: podman uses `--userns=keep-id:uid=0,gid=0`; docker needs
  tmpfs + `systempaths=unconfined` + `label=disable` + cgroup mount. Root password is injected **after**
  `create` by editing `/etc/shadow` in the stopped container (never baked into the image).
- stable-diffusion's `--offload-to-cpu` is recommended for ≥1024px images; `--chroma-disable-dit-mask`
  crashes ("buffer not set") despite the docs.
- `hf cache rm` **can** delete single files (the old assumption in the cleanup script was wrong): `hf cache rm model/<repo>` removes a whole repo (the `model/` prefix is **mandatory**, `hf cache rm <repo>` finds nothing) and `hf cache rm hf://models/<repo>/<file>` removes one quant variant from all revisions (`@<rev>` in the URI is rejected). Both support `--dry-run`, `-y`, `--json`, `--cache-dir`; unknown targets only warn and exit 0. `hf cache list --revisions --format json` gives exact `repo_id`/`snapshot_path` (use it instead of reversing `models--org--name`, which is ambiguous for repo names containing `--`). hfh 2.2.0 does not sanitize repo ids beyond `/` → `--`.
- llama.cpp's `-hf` also downloads `mmproj*` files, so quant-level cleanup used to leave ~0.9–1.2 GB of orphan vision files per abandoned model (the reason the script now has the orphan-repo tier). `-hft <token>` (HF auth token, used in the default config) must not be parsed as `-hf`.
- Never remove `blobs/*.incomplete` by hand — that is an in-progress download; `hf cache prune` owns them.
- Upstream drift is real: llama.cpp is pinned to the **latest pre-release** tag (stable releases are too old);
  `build.sh` guards against empty version resolution. Upstream `stable-diffusion.cpp` frontend swap (see above).
- `container-files/llama-server-wrapper.sh`, `llama-server-vulkan-wrapper.sh`, `sd-server-wrapper.sh`,
  `sd-server-vulkan-wrapper.sh` are **legacy leftovers — not referenced by the Dockerfile**. Binaries are
  reached via PATH and `/usr/local/bin` symlinks instead (the ROCm binaries find their libs through the
  `$ORIGIN;$ORIGIN/../lib` rpath set in every cmake invocation; keep those rpath flags when changing builds).
  Do not "fix" them into the image without a reason.
- Local helper scripts (`push.sh`), `data/`, `home-root/`, `*_version.txt`, `pi-session*` are gitignored —
  don't commit them.

## Branches / release conventions

- Branch `master` is the working branch. Experiment branches exist upstream:
  `rocm-7.12`, `rocm_therock`, `rocm-7.2.2`, `sd-binary-frontend`, `turboquant` — check them before
  re-doing an experiment (e.g. ROCm 7.12 / TheRock builds, turboquant HIP fork).
- Tags look like `v1.0.9-b8740` (`v<semver>-b<llama build>`); pushing a `v*` tag makes CI build and push
  `:<version>-<image_version>` **and** `:latest` to ghcr.io. So tagging == releasing; ask first.

## How to validate changes locally

No unit tests exist. **Static checks are the default; do not build the image (see hard rule 4)** — the
user builds it on their own machine, or CI builds it from a tag:

```bash
for f in $(git ls-files '*.sh'); do bash -n "$f" || echo "FAIL $f"; done   # syntax check all shell
python3 -c 'import yaml;yaml.safe_load(open("container-files/config.default.yaml"))'   # YAML sanity
```

Script-level logic can be exercised without any image: build a synthetic fixture under `/tmp` and run the
script against it (`--dry-run` first, then `--yes` on the fixture only). For container behavior, prefer
inspecting a live container the user grants access to (read-only, plus `--dry-run` for destructive tools).

Build commands below are documented for the user's benefit — do not run them from an agent session:

```bash
GPU_TARGETS="gfx1030" ./build.sh               # user-run: fast-ish full build (still long)
podman build --target <stage> -t <stage>:latest .   # user-run: one stage only
./build_and_run.sh                             # user-run: then podman attach llama-lxc
```

Full builds are the expensive part (multi-target ROCm compiles).
Never delete Dockerfile trimming steps to "make it build faster" — image size and the hipblaslt trim are
deliberate. When changing anything user-visible (ports, paths, env, config keys, deploy steps, GPU support,
cleanup behavior), update `README.md` **and** this `AGENTS.md` in the same change, then ask the user before
committing/pushing.
