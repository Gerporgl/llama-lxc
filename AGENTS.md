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
| `container-files/` | Files injected into the image: systemd units, `prepare.sh`, launchers (`llama-swap-launcher.sh`, `kokoro-launcher.sh` → installed as `/opt/kokoro/bin/kokoro-server`, plus `kokoro-asgi-app.py` → `/opt/kokoro/bin/kokoro_asgi_app.py`), `config.default.yaml`, `cleanup-hf-cache.sh`, MOTD. |
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
5. `kokoro` — `remsky/Kokoro-FastAPI` at the latest **release** tag (they publish real releases, unlike
   llama.cpp) into `/opt/kokoro`, following their own `docker/cpu/Dockerfile.optimized`: shallow clone, then
   `uv venv --python 3.12 && uv sync --frozen --extra cpu --no-install-project` (the `cpu` extra is CPU torch,
   never ROCm/CUDA torch; `--frozen` honors their `uv.lock`; `--no-install-project` + `PYTHONPATH` is how
   upstream runs it). Build tools stay in this throwaway stage. Optional `python -m unidic download` when
   `KOKORO_JAPANESE=true` (Japanese voices, ~550MB). **No model weights are ever baked in.** Independent of
   the ROCm stages (`FROM ubuntu:24.04`), so it may receive `--pull`, and must be built before `llama-lxc`.
6. `llama-lxc` — final image: `FROM rocm-base`, installs `init` (systemd as `ENTRYPOINT ["/sbin/init"]`,
   `STOPSIGNAL SIGRTMIN+3`), sshd, `systemd-networkd`, python + `huggingface_hub` (`hf` CLI),
   downloads the **llama-swap release tarball** (not built), copies compiled binaries, `COPY --from=kokoro:latest /opt/kokoro`
   plus its runtime libs (`espeak-ng`, `libsndfile1`, `libgomp1`), enables units.

`build.sh` writes `rocm_version.txt`, `llama_version.txt`, `sd_version.txt`, `llama_swap_version.txt`,
`kokoro_version.txt` and `image_version.txt` (all gitignored). `image_version.txt` is read by CI and also
baked into the OCI `org.opencontainers.image.version` label — **single source of truth, do not fork it**.

Key build args: `ROCM_VERSION` (currently 7.2.4), `GPU_TARGETS`, `llama_build`, `stable_diffusion_tag`,
`llama_swap_build`, `kokoro_build`, `KOKORO_JAPANESE` (default false), `IMAGE_VERSION`. Override targets to
make builds sane: `GPU_TARGETS="gfx1030" ./build.sh`.
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
  `llama-server-vulkan`, `sd-server-vulkan` (symlinks in `/usr/local/bin` → `/opt/*/vulkan/bin`), plus
  `kokoro-server` (symlink in `/usr/local/bin` → `/opt/kokoro/bin/kokoro-server`, also on PATH via
  `/etc/environment`).
- `kokoro-server` (`container-files/kokoro-launcher.sh`, our adaptation of upstream's
  `docker/scripts/entrypoint.sh`) is the only way to start Kokoro: it derives `KOKORO_HOME` from its own
  location, exports the app settings (`MODEL_DIR`, `VOICES_DIR`, `WEB_PLAYER_PATH`, `TEMP_FILE_DIR`,
  `TIKTOKEN_CACHE_DIR`, `USE_GPU=false`, `DEVICE_TYPE=cpu`, espeak paths — upstream defaults are `/app/...`
  and must all be overridden), runs upstream `docker/scripts/download_model.py --output $KOKORO_DATA_DIR/v1_0`,
  then `exec python -m uvicorn api.src.main:app` from `$KOKORO_HOME`. `--port`/`--host` flags, and
  `KOKORO_DATA_DIR` (default `/root/data/kokoro-model`) + `KOKORO_HOME` + `DOWNLOAD_MODEL` env overrides.
  It runs upstream's app through `kokoro_asgi_app:app` (our thin ASGI wrapper, see Kokoro gotchas) unless
  `KOKORO_ROOT_REDIRECT=false`.
  Weights therefore live on the data volume, never in the image.
- `config.default.yaml` uses llama-swap **macros** (`llama`, `llama-vulkan`, `sd`, `sd-vulkan`, `kokoro`,
  `models_dir`, `default_ctx`, `default_llama_args`) plus `models:` and `groups:`; llama-swap hot-reloads
  config, no systemctl restart needed. The `kokoro-tts` model **needs** `useModelName: "tts-1"` (see
  Gotchas). It also ships `aliases: [tts-1, tts-1-hd]` (so OpenAI-hardcoded clients route here) and
  `capabilities: {in: [text], out: [audio]}` (llama-swap then advertises `text->audio` +
  `capabilities.audio_speech` in `/v1/models`; verified on v265). Validate any config edit with
  `llama-swap -validate -config <file>` (no server started).
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

### Kokoro-FastAPI (text-to-speech)

- It is **CPU only by design**: the `cpu` extra installs the CPU torch wheel. Never add ROCm/CUDA torch, and
  never route TTS through a GPU — the point of the layer is to stay off the GPU paths that already crash when
  mixed (see above).
- The venv is **not relocatable**: `/opt/kokoro/.venv/bin/python3.12` is an absolute symlink to the builder's
  `/usr/bin/python3.12`, and upstream's docs call running that venv's python from a different path out of
  spec (they warn about `PYTHONHOME`). So `COPY --from=kokoro /opt/kokoro /opt/kokoro` must keep the **exact**
  path, and the launcher derives `KOKORO_HOME` from its own location. Ubuntu 24.04's system python is 3.12,
  which matches their `requires-python`; if the base moves to a newer Ubuntu the venv must be rebuilt there
  (never copy a venv across images).
- Upstream install contract (do not "simplify" it): `uv venv --python 3.12` + `uv sync --frozen --extra cpu
  --no-install-project`, then run with `PYTHONPATH=$KOKORO_HOME` + `python -m uvicorn api.src.main:app` — the
  project itself is deliberately **not** installed into the venv. Our launcher instead targets
  `kokoro_asgi_app:app` (`/opt/kokoro/bin/kokoro_asgi_app.py`, `$KOKORO_HOME/bin` is added to `PYTHONPATH`),
  which does `from api.src.main import app` — the same import path upstream's own entrypoint uses — and wraps
  it, so upstream files stay untouched. Their `pyproject.toml` pins
  `torch==2.8.0` / `onnxruntime==1.23.2`, so an unbuildable wheel pin upstream eventually breaks this stage.
- Upstream defaults are all `/app/...` (`model_dir`, `voices_dir`, `web_player_path`, `temp_file_dir`,
  `use_gpu`, `device_type` — pydantic-settings fields in `api/src/core/config.py`, matched case-insensitively
  from the environment, `extra="ignore"`); the launcher must override every path. `MODEL_DIR` must contain
  `v1_0/kokoro-v1_0.pth` (`api/src/core/model_config.py` hardcodes `v1_0/kokoro-v1_0.pth`), and upstream's
  `download_model.py --output <dir>` writes exactly `<dir>/v1_0/kokoro-v1_0.pth` + `config.json` (sha256
  verified, idempotent, downloaded from the `v0.1.4` release assets regardless of the app version).
- Keep the launcher's `${VAR:-default}` form for `MODEL_DIR`, `VOICES_DIR`, `WEB_PLAYER_PATH`,
  `TEMP_FILE_DIR`, `TIKTOKEN_CACHE_DIR`: llama-swap per-model `env:` entries must keep working. `USE_GPU`
  stays a hard `false`.
- Upstream images bake the weights into `/app/models`; ours does **not** (user requirement). Weights come
  from `~/data/kokoro-model` on the data volume, downloaded on first start — that is why `healthCheckTimeout:
  600` in the llama-swap config must stay generous, and why `DOWNLOAD_MODEL=false` exists for pre-seeded or
  air-gapped setups. `cleanup-hf-cache.sh` deliberately never touches `~/data/kokoro-model` (not an HF cache).
  Note `download_model.py`'s `main()` also pulls **21MB of Inno voice-tuner weights** into `inno_tuner/` for
  the `/dev/tune` endpoint (disabled by default via `enable_inno_tuner`), and its `check_tuner_update()` adds
  up to 3s to every start unless `HF_HUB_OFFLINE=1`. Not worth patching upstream for; set `DOWNLOAD_MODEL=false`
  on a pre-seeded volume to skip all of it.
- **llama-swap routing (verified on v265, both locally and against the user's live instance): there is no
  `/<model-name>/...` route at all.** OpenAI calls are routed by the `model` field of the **body** on `/v1/...`;
  `/kokoro-tts/v1/models` is answered by llama-swap's own mux (404 `404 page not found`, Go text, not Kokoro's
  `{"detail":...}`). `/upstream/<id>/<path>` is the raw passthrough (it strips that prefix before proxying, so
  Kokoro sees `/web/...`, and it still swaps the model in); clients *can* use
  `/upstream/kokoro-tts/v1/audio/speech` with `"model":"tts-1"` but it bypasses llama-swap's name rewriting,
  aliases and capabilities, so the default config pushes clients to `/v1`. Do not try to add a per-model URL
  mount: llama-swap has no such option (checked `config-schema.json`: per-model keys are cmd, cmdStop, name,
  description, env, proxy, aliases, checkEndpoint, ttl, unloadTimeout, useModelName, filters, metadata,
  concurrencyLimit, sendLoadingState, unlisted, timeouts, disableKeepAlives, compat, capabilities).
- **Web player through llama-swap's `/upstream/` needs our wrapper.** Kokoro serves the player only under
  `/web/` and has no route at `/`, while llama-swap's "open engine UI" button is hardcoded to
  `/upstream/<model>/` (`ui/src/lib/modelUtils.ts` in their repo), so the button 404s. Worse, Kokoro's own
  `/web` → `/web/` 307 is built from the `Host` header, so through a prefix-stripping proxy it points at the
  proxy root (live check: `location: http://ai.asqw.net/web/`, and with `http://` even behind TLS). Fix =
  `container-files/kokoro-asgi-app.py`: for exactly `""`, `/` and `/web` it buffers upstream's answer and only
  replaces a 404/3xx with a **relative** `Location: web/` (browsers resolve it against the current URL, so it
  lands on `<prefix>/web/` through llama-swap and `/web/` when hit directly); verified with the real launcher
  through llama-swap v265. Everything else (including `/health`, `/docs`, `/openapi.json`, `/v1/*`) is passed
  through untouched, so if upstream ever serves those paths itself we get out of the way.
- **Do not set `UVICORN_ROOT_PATH` or uvicorn `--root-path`** for the prefixed case. The player does not need
  it: `web/index.html` references its assets relatively (`styles/*.css`, `src/App.js`) and
  `web/src/config.js` derives the API prefix from the current URL (`currentPath.split('/web')[0]`) when
  `/web/config` reports `root_path: ""` — `UVICORN_ROOT_PATH` is only what feeds that JSON field. A real
  `--root-path` would break the *unprefixed* `/v1/...` calls llama-swap proxies (Starlette strips root_path
  before matching), so it is unusable here.
- `upstream.ignorePaths` (llama-swap) defaults to `.*\.(js|json|css|png|gif|jpg|jpeg|ico|txt)$`, so a cold
  `GET /upstream/kokoro-tts/web/styles/base.css` while the model is unloaded answers `409 Conflict` "path
  matches upstream.ignorePaths". That is harmless in a browser: the document itself (`/`, `/web/`) is not
  ignored, it starts the model, and the assets then proxy fine (verified 200). Do not "fix" it by emptying
  `ignorePaths` — listing any pattern **replaces** the default. Also: Kokoro's player holds no websocket and
  does not poll, so an idle tab does not keep the model loaded (unlike ComfyUI).
- Kokoro rejects unknown model names with HTTP 400 (accepted: `tts-1`, `tts-1-hd`, `kokoro`,
  `gpt-4o-mini-tts`), hence `useModelName`. Verified end to end with the real `config.default.yaml`: cold
  start ≈15s, unload via `/api/models/unload/<id>` terminates the uvicorn process cleanly. llama-swap also
  proxies `GET /v1/audio/voices?model=kokoro-tts` to it (leave `capabilities.voices` unset so the list always
  matches what is installed).
- espeak is **not** optional and its path differs by distro: `api/src/services/text_processing/phonemizer.py`
  uses `phonemizer` (phonemizer-fork) `EspeakBackend` for the languages misaki does not cover, which needs the
  system `libespeak-ng` (found with `find_library`) → apt `espeak-ng` (pulls `libespeak-ng1` +
  `espeak-ng-data`) is a runtime dep of the final stage. On **Ubuntu 24.04 the data lives in
  `/usr/lib/x86_64-linux-gnu/espeak-ng-data`**, not `/usr/share/espeak-ng-data` as on Debian — verified by
  installing the package in a throwaway ubuntu:24.04 container, so the launcher globs the multiarch path
  first. The var phonemizer-fork actually reads is `PHONEMIZER_ESPEAK_DATA_PATH` (upstream's Dockerfile sets
  `PHONEMIZER_ESPEAK_DATA`, which nothing reads). `misaki` is path-agnostic: `espeakng-loader` ships its own
  14MB copy of libespeak-ng 1.52 + data inside the venv, and misaki calls `set_data_path()` with it.
- Voice names: v1_0 set only (72 `.pt` files under `api/src/voices/v1_0`, 64 reported by `/v1/audio/voices`;
  the prefix letter is the language). Legacy v0.19 names with a hyphen (`bf-selena`) are **not** available and
  a hyphen is parsed as a voice-combination separator (`bf-selena` → voice `bf`). Tested working through the
  launcher: en, es, fr, it, pt, hi, zh (each with its own misaki/phonemizer pipeline).
- **llama-swap resolves the `cmd` executable with its own PATH; a per-model `env:` PATH entry does not affect
  that lookup** (Go's `exec.Command`/`LookPath` — verified: the model then fails with
  `executable file not found in $PATH` and every request 500s). Bare macro binaries like `llama-server` and
  `kokoro-server` therefore work only because `llama-swap.service` has `EnvironmentFile=/etc/environment`
  (which carries the `/opt/*/bin` PATH line); the `/usr/local/bin` symlinks are the belt-and-braces fallback.
  Keep both when changing install paths, and never suggest moving a binary by adding a `PATH=` `env:` entry.
- Kokoro's uvicorn binds **IPv4 only** (`0.0.0.0`): inside the CT use `127.0.0.1`, not `localhost` (which may
  resolve to `::1`). Its OpenAI-compatible surface is under `/v1`, the web player under `/web/` (`/web` only
  307-redirects), Swagger at `/docs` — all reachable at the llama-swap-assigned port (5800+) since it binds
  all interfaces.
- Japanese voices need `python -m unidic download` (~550MB dictionary, an extra network fetch at build time),
  gated by `KOKORO_JAPANESE`; everything else works without it (see the verified list above).
- `speed` is a top-level request field of Kokoro's own schema (verified: 0.6 / 1.0 / 1.8 produce clearly
  different lengths), not an OpenAI `overrides` thing. `response_format` verified for mp3 and wav.
- Cost: ≈1.1GB added to the image (CPU torch is the bulk; the venv is ≈1.6GB uncompressed), plus ≈350MB of
  weights on the data volume. CI disk space and pull times both grow.
- kokoro ships no HIP/ROCm code at all, so it is unaffected by `GPU_TARGETS`; the stage is `FROM ubuntu:24.04`
  and may receive `--pull` like `rocm-dev`/`rocm-base` (see the pull-flag rule).

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

Build commands below are documented for the user's benefit — do not run them from an agent session:

```bash
GPU_TARGETS="gfx1030" ./build.sh               # user-run: fast-ish full build (still long)
podman build --target <stage> -t <stage>:latest .   # user-run: one stage only
./build_and_run.sh                             # user-run: then podman attach llama-lxc
```

Kokoro recipe that needs **no image build of ours** (this is how the launcher, the config entry and the
`/upstream/` UI behavior were verified): run upstream's `ghcr.io/remsky/kokoro-fastapi-cpu:latest` with
`-v $PWD/container-files/kokoro-launcher.sh:/app/bin/kokoro-server:ro` and
`-v $PWD/container-files/kokoro-asgi-app.py:/app/bin/kokoro_asgi_app.py:ro` (their `/app` layout matches the
`KOKORO_HOME` our launcher derives, `/app/.venv` included), bind-mount a llama-swap release binary and a
trimmed copy of `config.default.yaml` whose `kokoro` macro points at `/app/bin/kokoro-server`, then POST
`/v1/audio/speech` with `{"model":"kokoro-tts",...}`, GET `/upstream/kokoro-tts/` for the redirect, and watch
`/running`. Two traps when doing that: their image has an **ENTRYPOINT**, so passing `bash -c ...` to
`podman run` exits 127 — override with `--entrypoint /usr/local/bin/llama-swap` (or `--entrypoint bash`); and
their image flattens the repo (`/app/download_model.py`, no `/app/docker/`), so also mount
`-v <clone>/docker/scripts/download_model.py:/app/docker/scripts/download_model.py:ro` or the launcher's
weight check fails. Building only the `kokoro` stage (`--target kokoro`) is far cheaper than the ROCm stages
(≈10 min, +2GB of local storage), but it is still an image build: ask the user first.

Full builds are the expensive part (multi-target ROCm compiles).
Never delete Dockerfile trimming steps to "make it build faster" — image size and the hipblaslt trim are
deliberate. When changing anything user-visible (ports, paths, env, config keys, deploy steps, GPU support,
cleanup behavior), update `README.md` **and** this `AGENTS.md` in the same change, then ask the user before
committing/pushing.
