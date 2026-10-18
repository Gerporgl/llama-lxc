# AGENTS.md — llama-lxc

Purpose: a **systemd-based LXC-ready container image** (Ubuntu 24.04 + ROCm) that runs
[llama-swap](https://github.com/mostlygeek/llama-swap) as the main service, with locally-compiled
**llama.cpp** and **stable-diffusion.cpp** (ROCm **and** Vulkan variants) plus a CPU-only
**Kokoro-FastAPI** text-to-speech layer, for **AMD GPUs (ROCm)**, deployed mainly as an
**unprivileged Proxmox VE container** with `amdgpu` passthrough. Local testing with **podman**
(docker tolerated but unsupported).

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

## Where the truth lives

This file holds **agent-only knowledge**: rules, cross-file invariants, gotchas, validation recipes.
Anything that describes one file's own behavior lives as comments **in that file** — read these before
editing the area they cover, and keep them in sync (they are the reference for user-facing behavior):

| Topic | Read this, not this AGENTS.md |
|---|---|
| Image contents, stage list, cmake flags, install paths, ROCm trimming | `Dockerfile` — single source of truth for the image |
| Upstream version resolution, build order, `--pull` rule, build args, `image_version.txt` | `build.sh` (its comments state the rules) |
| llama-swap config: macros, model entries, groups, **every Kokoro setting we rely on** | `container-files/config.default.yaml` |
| First-run seeding of `/root` and `/root/data` | `container-files/prepare.sh` |
| Service env, `HSA_OVERRIDE_GFX_VERSION` example, why `EnvironmentFile=/etc/environment` is load-bearing | `container-files/llama-swap.service` |
| Kokoro launch: env overrides, espeak paths, weight download, uvicorn command | `container-files/kokoro-launcher.sh` |
| Kokoro web player behind llama-swap's `/upstream/` prefix (root_path, redirects, Referer) | `container-files/kokoro-asgi-app.py` module docstring |
| HF cache cleanup policy, quant matching, flags, exit codes | `container-files/cleanup-hf-cache.sh` header block |
| GPU passthrough, uid/gid idmaps, `/dev/dri` handling, ZFS tuning | `proxmox-host-scripts/setup-llama-lxc.sh` header block |
| What users see: deploy steps, ports, TTS usage + client table, cost, cleanup usage | `README.md` |
| In-container commands surfaced to users (keep in sync with README) | `container-files/llama-lxc-motd` |

## Repository layout

| Path | What it is |
|---|---|
| `Dockerfile` | Multi-stage build. Single source of truth for the image. |
| `build.sh` | Resolves latest upstream versions from GitHub APIs, then builds each stage separately. |
| `run.sh` / `run_local.sh` / `build_and_run.sh` | Local podman/docker test harness (root password prompt, `./data` bind mount, ports 2222→22, 8888→8080). |
| `container-files/` | Files injected into the image: systemd units, `prepare.sh`, launchers (`llama-swap-launcher.sh`, `kokoro-launcher.sh` → `/opt/kokoro/bin/kokoro-server`, `kokoro-asgi-app.py` → `/opt/kokoro/bin/kokoro_asgi_app.py`), `config.default.yaml`, `cleanup-hf-cache.sh`, MOTD. |
| `proxmox-host-scripts/setup-llama-lxc.sh` | Runs **on the Proxmox host**: creates/patches the CT config for GPU passthrough + idmaps, optional ZFS tuning. |
| `.github/workflows/docker-image.yml` | CI: builds on tag `v*`, weekly schedule (Fri 22:37 UTC), manual dispatch; pushes `:latest` + versioned tag to ghcr.io. |

## Build pipeline

Order matters: `rocm-dev` → `stable-diffusion` → `llama-cpp` → `rocm-base` → `kokoro` → `llama-lxc`
(one `${CT_TOOL} build --target <stage>` per stage, see `build.sh`). Details, flags and install paths are
in the `Dockerfile`; these are the parts you cannot see there:

- Stages whose `FROM` is a public image (`rocm-dev`, `rocm-base`, `kokoro`) may receive
  `--pull`/`--pull=newer` (`build.sh pull`); passing a pull flag to a stage that `FROM`/`COPY --from`
  **local** tags **breaks the build** (commit `7a27327`). `kokoro` is independent of the ROCm stages
  (`FROM ubuntu:24.04`) but must be built before `llama-lxc`, which `COPY --from` it.
- `llama.cpp` is pinned to the **latest pre-release** tag (their stable releases are too old);
  `build.sh` guards against empty version resolution. Its build number is derived from the tag:
  `b11539` → `11539` (`DLLAMA_BUILD_NUMBER`).
- The `stable-diffusion` stage **replaces the upstream frontend submodule with a clone of
  `leejet/stable-ui`** (upstream switched to `sdcpp-webui`, which works badly with llama-swap).
  Keep this patch unless upstream reverts.
- `rocm-base` installs ROCm **runtime only** and then does heavy trimming of `/opt/rocm`, including
  **hipblaslt Tensile libs for gfx families not in `GPU_TARGETS`**. Never delete trimming steps to
  "make it build faster" — image size and that trim are deliberate.
- Every cmake pass sets the rpath `$ORIGIN;$ORIGIN/../lib`; the ROCm binaries find their libs through
  it. Keep those flags when changing builds.
- `build.sh` writes `rocm_version.txt`, `llama_version.txt`, `sd_version.txt`, `llama_swap_version.txt`,
  `kokoro_version.txt`, `image_version.txt` (all gitignored). `image_version.txt` is read by CI **and**
  baked into the OCI `org.opencontainers.image.version` label — single source of truth, do not fork it.
- Key build args: `ROCM_VERSION` (currently 7.2.4), `GPU_TARGETS`, `llama_build`, `stable_diffusion_tag`,
  `llama_swap_build`, `kokoro_build`, `KOKORO_JAPANESE` (default false), `IMAGE_VERSION`. Default
  `GPU_TARGETS` is a 9-target list → **15+ min on 16 cores, hours on a quad core**;
  `GPU_TARGETS="gfx1030" ./build.sh` for a sane build. Vulkan compiles are arch-agnostic; Kokoro has no
  GPU target at all (no HIP/ROCm code).
- `build.sh` prefers podman; `CT_TOOL=docker` forces docker (what CI does).

## Runtime contract inside the container

- All persistent state lives on the **data volume at `/root/data`**: `config.yaml`,
  `llama-swap-launcher`, `models/` (`models/sd/` for SD files), `kokoro-model/`. This is what survives
  base-image upgrades — never put user-editable state elsewhere, and never rewrite a user's existing
  files (`prepare.sh` only seeds what is missing).
- `llama-swap.service` → `ExecStart=/root/data/llama-swap-launcher` → `exec llama-swap --config
  /root/data/config.yaml --watch-config`, `Restart=always`, env from `/etc/environment`
  (`LLAMA_CACHE`, `HF_HUB_CACHE`, `ROCR_VISIBLE_DEVICES=0`, `HF_XET_HIGH_PERFORMANCE=1`, PATH with
  `/opt/rocm/bin:/opt/llama/bin:/opt/stable-diffusion/bin`). Per-GPU overrides such as
  `HSA_OVERRIDE_GFX_VERSION` go in the **launcher on the volume** or commented in the unit.
- **llama-swap resolves a model's `cmd` with its own PATH, not the model's `env:` PATH** — bare binary
  names work only because of `EnvironmentFile=/etc/environment` + the `/usr/local/bin` symlinks
  (details in `container-files/llama-swap.service`). Keep both when changing install paths.
- Config macros resolve to `llama-server` / `sd-server` (ROCm, from PATH) and `llama-server-vulkan` /
  `sd-server-vulkan` / `kokoro-server` (`/usr/local/bin` symlinks → `/opt/*/vulkan/bin`,
  `/opt/kokoro/bin`). Validate any config edit with `llama-swap -validate -config <file>` (starts no
  server). llama-swap hot-reloads config, no systemctl restart needed.
- Inside the CT, useful commands (also in the MOTD `/etc/llama-lxc-motd`): `journalctl -u llama-swap -f`,
  `systemctl restart llama-swap`, `nano ~/data/config.yaml`, `hf cache list`, `hf cache prune`,
  `cleanup-hf-cache.sh`, `watch amd-smi`.
- `cleanup-hf-cache.sh` semantics are documented in its own header block and the README. Gotchas that
  live nowhere else: llama.cpp's `-hf` also downloads `mmproj*` vision files (~0.9–1.2 GB of orphans per
  abandoned model — the reason the script has an orphan-repo tier), `-hft <token>` (HF auth token, used
  in the default config) must **not** be parsed as `-hf`, and it never touches `~/data/kokoro-model`.

## Proxmox deployment (the intended target)

- User-facing flow is in the README; script behavior is in the `setup-llama-lxc.sh` header. It defaults
  to a manually-imported `/var/lib/vz/template/cache/llama-lxc_latest.tar` — check/adjust `DEFAULT_IMAGE`.
  The user must add a **second volume/mountpoint at `/root/data`** (rootfs is only 16 GB; 128 GB+
  recommended). Network defaults `vmbr0`, DHCP v4+v6, no firewall; llama-swap UI/API on port **8080**.
  Proxmox needs VE 9.1.7+ with latest kernel/firmware for ROCm 7.2.x on gfx1200; **no ROCm on the host**.
- **Critical cross-file invariant:** the image hard-codes container GIDs `render=444`, `video_host=555`,
  `render_host=777` (Dockerfile) and `setup-llama-lxc.sh` hard-codes `video_gid_ct=555`,
  `render_gid_ct=777` and builds the host↔container gid idmap around those exact numbers, so the host's
  real `video`/`render` GIDs map 1:1 into the CT. Change one side and you **must** change the other, and
  keep the `<`-comparison ordering logic that handles host GIDs above/below 777.

## Gotchas / lessons already learned

- **Do not mix ROCm and Vulkan binaries at the same time** — observed hard `amdgpu` crash (ring buffer
  errors in dmesg) requiring a full power-off of the machine to recover.
- ROCm binaries must be compiled for the right gfx target(s); a mismatch made `sd-server` **exit silently**
  mid-generation. The default multi-target list fixes this at the cost of build time/image size.
- `--device /dev/dri/renderD128` alone is **not** enough in LXC; the whole `/dev/dri` dir must be
  bind-mounted, and `/dev/kfd` already exposes all GPUs to ROCm — GPU selection is done with
  `ROCR_VISIBLE_DEVICES` inside the CT (`-1` forces CPU, used for the small persistent autocomplete model).
- systemd-in-container details that matter: `ENTRYPOINT ["/sbin/init"]`, `STOPSIGNAL SIGRTMIN+3`
  (`poweroff` to stop), `init` package installed, `dbus` removed, apt/dpkg/fstrim/motd **timers deleted**
  (updates are manual / via new images), `systemd-networkd` enabled instead of ifupdown for IPv6/DHCP in LXC.
- `run.sh` needs different flags per runtime: podman uses `--userns=keep-id:uid=0,gid=0`; docker needs
  tmpfs + `systempaths=unconfined` + `label=disable` + cgroup mount. Root password is injected **after**
  `create` by editing `/etc/shadow` in the stopped container (never baked into the image).
- stable-diffusion's `--offload-to-cpu` is recommended for ≥1024px images; `--chroma-disable-dit-mask`
  crashes ("buffer not set") despite the docs.
- `hf cache rm` **can** delete single files (the old assumption in the cleanup script was wrong):
  `hf cache rm model/<repo>` removes a whole repo (the `model/` prefix is **mandatory**, `hf cache rm
  <repo>` finds nothing) and `hf cache rm hf://models/<repo>/<file>` removes one quant variant from all
  revisions (`@<rev>` in the URI is rejected). Both support `--dry-run`, `-y`, `--json`, `--cache-dir`;
  unknown targets only warn and exit 0. `hf cache list --revisions --format json` gives exact
  `repo_id`/`snapshot_path` (use it instead of reversing `models--org--name`, ambiguous for repo names
  containing `--`). hfh 2.2.0 does not sanitize repo ids beyond `/` → `--`.
- Never remove `blobs/*.incomplete` by hand — that is an in-progress download; `hf cache prune` owns them.
- `container-files/llama-server-wrapper.sh`, `llama-server-vulkan-wrapper.sh`, `sd-server-wrapper.sh`,
  `sd-server-vulkan-wrapper.sh` are **legacy leftovers — not referenced by the Dockerfile**. Binaries are
  reached via PATH and `/usr/local/bin` symlinks instead. Do not "fix" them into the image without a reason.
- Local helper scripts (`push.sh`), `data/`, `home-root/`, `*_version.txt`, `pi-session*` are gitignored —
  don't commit them.

## Kokoro-FastAPI (text-to-speech)

The implementation is documented where it lives: `container-files/kokoro-launcher.sh` (env overrides,
espeak discovery, weight download, uvicorn invocation), `container-files/kokoro-asgi-app.py` (module
docstring: why the web player breaks behind llama-swap's `/upstream/<model>/` prefix and exactly what the
wrapper repairs), and the `kokoro` macro + `kokoro-tts` entry in `container-files/config.default.yaml`
(`useModelName`, aliases, capabilities, `concurrencyLimit: 999`, `KOKORO_ROOT_REDIRECT` /
`KOKORO_ROOT_PATH`, the 409-vs-429 explanation, and the "there is no `/<model-name>/` route" routing note).
Read those three first. What is **not** in them:

- **README scope for Kokoro is deliberately minimal**: what the image installs, the curl example, the
  client-pointing table, and a short "Configuration" subsection that defers to `config.default.yaml`.
  All design/implementation prose lives in the files above and here — the user asked for that trim, do not
  re-add web-player / root_path / concurrency prose to the README.
- **CPU only by design** (the `cpu` extra installs CPU torch). Never add ROCm/CUDA torch and never route
  TTS through a GPU: the point of this layer is to stay off the GPU paths that already crash when mixed.
- The venv is **not relocatable**, and must never be copied across images: its `python3.12` is an absolute
  symlink to the builder's `/usr/bin/python3.12`, and upstream calls running that interpreter from another
  path out of spec. So `COPY --from=kokoro /opt/kokoro /opt/kokoro` keeps the exact path, the launcher
  derives `KOKORO_HOME` from its own location, and Ubuntu 24.04's system python 3.12 must match their
  `requires-python` — if the base moves to a newer Ubuntu, **rebuild the venv there**.
- Upstream install contract (do not "simplify" it): `uv venv --python 3.12` + `uv sync --frozen --extra cpu
  --no-install-project`, then run with `PYTHONPATH` + `python -m uvicorn api.src.main:app`; the project is
  deliberately not installed into the venv. Their `pyproject.toml` pins `torch==2.8.0` /
  `onnxruntime==1.23.2`, so an unbuildable upstream wheel pin eventually breaks this stage.
- **No per-model URL mount exists in llama-swap** (checked `config-schema.json`), so do not try to add one:
  routing is by the body `model` field, `/upstream/<id>/<path>` is the raw prefix-stripping passthrough.
- **Never set `UVICORN_ROOT_PATH` or uvicorn `--root-path`**: a real `--root-path` breaks the *unprefixed*
  `/v1/...` calls llama-swap proxies (Starlette strips root_path before matching), and the JSON field it
  would otherwise feed is already derived per request by our wrapper (which steps aside if a user sets it).
- Voice names: v1_0 set only (72 `.pt` files, 64 reported by `/v1/audio/voices`). Legacy v0.19 names with a
  hyphen (`bf-selena`) are **not** available — a hyphen is a voice-combination separator (`bf-selena` →
  voice `bf`). Verified working through the launcher: en, es, fr, it, pt, hi, zh.
- Kokoro's uvicorn binds **IPv4 only** (`0.0.0.0`): inside the CT use `127.0.0.1`, not `localhost` (which
  may resolve to `::1`). `speed` is a top-level field of Kokoro's own schema (verified 0.6/1.0/1.8), not an
  OpenAI `overrides` thing; `response_format` verified for mp3 and wav.
- Kokoro rejects unknown model names with HTTP 400 (accepted: `tts-1`, `tts-1-hd`, `kokoro`,
  `gpt-4o-mini-tts`) — hence `useModelName`. Verified end to end with the real `config.default.yaml`: cold
  start ≈15s, unload via `/api/models/unload/<id>` terminates the uvicorn process cleanly.

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
for f in $(git ls-files '*.sh') container-files/kokoro-launcher.sh container-files/llama-lxc-motd; do bash -n "$f" || echo "FAIL $f"; done   # syntax check all shell
python3 -c 'import ast;ast.parse(open("container-files/kokoro-asgi-app.py").read())'   # wrapper module sanity
python3 -c 'import yaml;yaml.safe_load(open("container-files/config.default.yaml"))'   # YAML sanity
./llama-swap -validate -config container-files/config.default.yaml   # llama-swap's own config validator
```

Script-level logic can be exercised without any image: build a synthetic fixture under `/tmp` and run the
script against it (`--dry-run` first, then `--yes` on the fixture only). For container behavior, prefer
inspecting a live container the user grants access to (read-only, plus `--dry-run` for destructive tools).
In hand-written test configs: llama-swap does **not** shell-expand `env:` entries (`PATH=/app/bin:$PATH`
breaks the launcher), use its own `${env.PATH}` macro.

Build commands below are documented for the user's benefit — do not run them from an agent session:

```bash
GPU_TARGETS="gfx1030" ./build.sh                    # user-run: fast-ish full build (still long)
podman build --target <stage> -t <stage>:latest .   # user-run: one stage only
./build_and_run.sh                                  # user-run: then podman attach llama-lxc
```

Kokoro recipe that needs **no image build of ours** (how the launcher, the config entry and the
`/upstream/` UI behavior were verified): run upstream's `ghcr.io/remsky/kokoro-fastapi-cpu:latest` with
`-v $PWD/container-files/kokoro-launcher.sh:/app/bin/kokoro-server:ro` and
`-v $PWD/container-files/kokoro-asgi-app.py:/app/bin/kokoro_asgi_app.py:ro` (their `/app` layout matches
the `KOKORO_HOME` our launcher derives), bind-mount a llama-swap release binary and a trimmed copy of
`config.default.yaml` whose `kokoro` macro points at `/app/bin/kokoro-server`; then POST
`/v1/audio/speech`, GET `/upstream/kokoro-tts/`, watch `/running`. Two traps: their image has an
**ENTRYPOINT**, so `podman run ... bash -c ...` exits 127 — override with `--entrypoint bash` (or
`--entrypoint /usr/local/bin/llama-swap`); and their image flattens the repo (`/app/download_model.py`,
no `/app/docker/`), so also mount `-v <clone>/docker/scripts/download_model.py:/app/docker/scripts/download_model.py:ro`
or the launcher's weight check fails. Building only the `kokoro` stage (`--target kokoro`, ≈10 min, +2 GB
storage) is far cheaper than the ROCm stages, but it is still an image build: ask the user first.

For **player-level** bugs (prefix handling, MIME/concurrency symptoms) there is no real browser in this
agent sandbox — playwright's firefox needs `libgtk-3.so.0`, absent and uninstallable without root — so
replay the player's own logic in node instead (node has `fetch`): re-implement `web/src/config.js`
`detectRootPath()` + the `/web/config` overwrite + `VoiceService`, send the `Referer` a browser would
send, then fetch every `web/src/**/*.js` **in parallel** (that is what trips the concurrency limit;
resolve specifiers relative to the page URL, not to `root_path`). Pair it with
`curl -w '%{http_code} %{content_type}'` on `/upstream/<id>/`, `/web/config`, `/v1/audio/voices`, and
always compare a before/after run (two containers, one with the suspect config key removed) — statuses
and MIME types reproduce the browser's `NS_ERROR_CORRUPTED_CONTENT` complaint exactly.

When changing anything user-visible (ports, paths, env, config keys, deploy steps, GPU support, cleanup
behavior), update `README.md` **and** this `AGENTS.md` in the same change, then ask the user before
committing/pushing.
