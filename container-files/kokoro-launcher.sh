#!/bin/bash
# Kokoro-FastAPI (TTS) launcher. CPU backend only, no ROCm and no CUDA.
#
# This is our version of upstream's docker/scripts/entrypoint.sh, with the paths
# adapted to this image (we install under /opt/kokoro instead of /app, and keep
# the weights on the data volume instead of baking them into the image).
# Upstream itself is not patched, so re-check this launcher when bumping it.
#
# Single entry point for the TTS server:
#   kokoro-server                     # manual run, default port 8880
#   kokoro-server --port 5800         # what llama-swap does via the "kokoro" macro
#
# Everything persistent lives under $KOKORO_DATA_DIR (data volume), so the 327MB
# model weights survive a base image refresh.

set -e

# /opt/kokoro, resolved through the /usr/local/bin symlink
KOKORO_HOME="${KOKORO_HOME:-$(dirname "$(dirname "$(readlink -f "$0")")")}"
PY="$KOKORO_HOME/.venv/bin/python"

KOKORO_DATA_DIR="${KOKORO_DATA_DIR:-/root/data/kokoro-model}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8880}"

usage() {
    echo "usage: kokoro-server [--host HOST] [--port PORT]"
    echo "  env: KOKORO_DATA_DIR (model files), DOWNLOAD_MODEL=true|false,"
    echo "       API_LOG_LEVEL, VOICES_DIR, WEB_PLAYER_PATH, TEMP_FILE_DIR,"
    echo "       and any Kokoro-FastAPI setting (see their docs/configuration.md)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --port=*) PORT="${1#*=}"; shift ;;
        --host) HOST="$2"; shift 2 ;;
        --host=*) HOST="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "kokoro-server: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ ! -x "$PY" ]]; then
    echo "kokoro-server: no virtualenv at $KOKORO_HOME/.venv (is KOKORO_HOME correct?)" >&2
    exit 1
fi

# Kokoro reads its settings from the environment (api/src/core/config.py, field
# names uppercased). Its defaults are the absolute paths of their own container
# (/app/...), so every path has to be set here, but each one can still be
# overridden from the llama-swap model's env: list (or the environment).
# USE_GPU stays hard-coded: this is the CPU backend, there is no ROCm/CUDA torch.
export PYTHONPATH="$KOKORO_HOME:$KOKORO_HOME/api:$KOKORO_HOME/bin"
export PATH="$KOKORO_HOME/.venv/bin:$PATH"
export USE_GPU=false
export DEVICE_TYPE="${DEVICE_TYPE:-cpu}"
# weights are looked up as $MODEL_DIR/v1_0/kokoro-v1_0.pth
export MODEL_DIR="${MODEL_DIR:-$KOKORO_DATA_DIR}"
export VOICES_DIR="${VOICES_DIR:-$KOKORO_HOME/api/src/voices/v1_0}"
export WEB_PLAYER_PATH="${WEB_PLAYER_PATH:-$KOKORO_HOME/web}"
export TEMP_FILE_DIR="${TEMP_FILE_DIR:-$KOKORO_DATA_DIR/temp}"
export TIKTOKEN_CACHE_DIR="${TIKTOKEN_CACHE_DIR:-$KOKORO_DATA_DIR/.cache}"
export API_LOG_LEVEL="${API_LOG_LEVEL:-INFO}"

# espeak-ng backs the languages misaki does not cover (phonemizer-fork's
# EspeakBackend). On Ubuntu its data is in the multiarch dir, not /usr/share like
# on Debian; misaki itself uses the copy bundled in the espeakng-loader wheel.
# PHONEMIZER_ESPEAK_DATA_PATH is the name phonemizer-fork actually reads.
if command -v espeak-ng >/dev/null 2>&1; then
    export PHONEMIZER_ESPEAK_PATH="$(dirname "$(readlink -f "$(command -v espeak-ng)")")"
fi
for data_dir in /usr/lib/*/espeak-ng-data /usr/share/espeak-ng-data; do
    if [[ -d "$data_dir" ]]; then
        export ESPEAK_DATA_PATH="$data_dir"
        export PHONEMIZER_ESPEAK_DATA_PATH="$data_dir"
        break
    fi
done

mkdir -p "$MODEL_DIR" "$TEMP_FILE_DIR" "$TIKTOKEN_CACHE_DIR"

# Same as upstream: their script verifies checksums and no-ops when the files
# are already in place. DOWNLOAD_MODEL=false keeps it offline.
if [[ "${DOWNLOAD_MODEL:-true}" == "true" ]]; then
    echo "kokoro-server: checking model files in $MODEL_DIR/v1_0"
    "$PY" "$KOKORO_HOME/docker/scripts/download_model.py" --output "$MODEL_DIR/v1_0"
fi

if [[ ! -f "$MODEL_DIR/v1_0/kokoro-v1_0.pth" ]]; then
    echo "kokoro-server: no $MODEL_DIR/v1_0/kokoro-v1_0.pth (download disabled or it failed); not starting" >&2
    exit 1
fi

echo "kokoro-server: serving TTS on http://$HOST:$PORT (cpu, model dir $MODEL_DIR)"

# uvicorn must run from the project root: the app package is api.src.main.
# kokoro_asgi_app is our own wrapper (container-files/kokoro-asgi-app.py): it makes
# Kokoro's web player work behind llama-swap's /upstream/<model>/ prefix (relative
# redirect for "/" and "/web", plus the real prefix in /web/config). Set
# KOKORO_ROOT_REDIRECT=false to run upstream's app directly.
APP="api.src.main:app"
if [[ "${KOKORO_ROOT_REDIRECT:-true}" == "true" ]]; then
    APP="kokoro_asgi_app:app"
fi

cd "$KOKORO_HOME"
exec "$PY" -m uvicorn "$APP" --host "$HOST" --port "$PORT"
