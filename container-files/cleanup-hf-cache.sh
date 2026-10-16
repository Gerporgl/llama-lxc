#!/bin/bash
#
# cleanup-hf-cache.sh — reclaim space in the Hugging Face model cache by removing
# models that llama-swap no longer references.
#
# How a model counts as "referenced":
#   A `-hf <repo>[:<quant>]` or `-hfr <repo> [-hff <file>]` token appears in one of
#   the scanned config files (default: ~/data/config.yaml). Lines that are commented
#   out DO count as references on purpose, so a commented model keeps its files
#   cached. To really free a model, delete the line from the config.
#
# Cleanup policy (two tiers):
#   Tier 1 - orphan repo: the repo appears in the cache but no reference of any kind
#            points at it -> the ENTIRE repo is removed (every revision, every quant
#            and the mmproj/vision files too). This is what frees the bulk of the
#            space over time, and it is also what removes mmproj files that were left
#            behind by earlier quant-level cleanups.
#   Tier 2 - quant variant: the repo IS referenced -> every non-mmproj cached file of
#            that repo that matches none of its referenced quants is removed. mmproj
#            files are never touched while the repo is referenced (llama.cpp picks the
#            right one at runtime, they are small and redownloaded on demand).
#
# Quant matching mirrors llama.cpp: the quant tag is matched as a case-insensitive
# substring of the cached filename (llama.cpp itself selects files that way). The
# llama.cpp pseudo tags are understood: no quant / `latest` == Q4_K_M, `all` == every
# file of the repo.
#
# It always finishes with `hf cache prune` plus a sweep of leftovers: dangling
# snapshot symlinks, blobs that no snapshot links anymore, empty repo shells and
# empty .locks entries. In-progress downloads (*.incomplete) are never touched.
#
# Usage:
#   cleanup-hf-cache.sh                  # plan + interactive confirmation
#   cleanup-hf-cache.sh --dry-run        # plan only, never deletes anything
#   cleanup-hf-cache.sh --yes            # no prompt (cron / ssh one-liner)
#   cleanup-hf-cache.sh --keep-file f --keep-file g
#
# Environment:
#   HF_HUB_CACHE               cache directory (default here), or use --cache-dir
#   LLAMA_CACHE                used as fallback cache directory
#   HF_CLEANUP_EXTRA_KEEP      colon separated list of extra files to scan for refs
#   HF_CLEANUP_ALLOW_EMPTY_KEEP_LIST=1  same as --allow-empty-keep-list
#
# Exit codes: 0 = done (or nothing to do), 1 = configuration error, 2 = cancelled.

shopt -s nullglob
set -f    # disable pathname expansion while tokenising config lines (re-enabled later)

if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Error: this script needs bash >= 4 (found ${BASH_VERSION:-not bash})." >&2
    exit 1
fi

HF_BIN="$(command -v hf || true)"
JQ_BIN="$(command -v jq || true)"

DRY_RUN=0
ASSUME_YES=0
ALLOW_EMPTY_KEEP="${HF_CLEANUP_ALLOW_EMPTY_KEEP_LIST:-0}"
VERBOSE=0
CACHE_DIR_OPT=""
KEEP_FILES=()

usage() {
    cat <<'EOF'
Usage: cleanup-hf-cache.sh [options]

  -n, --dry-run                show what would be removed, delete nothing
  -y, --yes                    do not ask for confirmation
  -k, --keep-file <path>       extra file to scan for -hf/-hfr references
                               (repeatable). Replaces the default ~/data/config.yaml
                               when at least one --keep-file is given.
  -c, --cache-dir <path>       HF cache dir (default: $HF_HUB_CACHE, then
                               $LLAMA_CACHE, then ~/.cache/huggingface/hub)
      --allow-empty-keep-list  accept a config with no reference at all, which means
                               "every cached model is an orphan" (also
                               HF_CLEANUP_ALLOW_EMPTY_KEEP_LIST=1)
  -v, --verbose                also list the files that are kept, and why
  -h, --help                   this help
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

warn() {
    echo "Warning: $*" >&2
}

# ---------------------------------------------------------------- arguments ----
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run)           DRY_RUN=1 ;;
        -y|--yes)               ASSUME_YES=1 ;;
        -k|--keep-file)         [ $# -ge 2 ] || die "--keep-file needs a path"; KEEP_FILES+=("$2"); shift ;;
        --keep-file=*)          KEEP_FILES+=("${1#*=}") ;;
        -c|--cache-dir)         [ $# -ge 2 ] || die "--cache-dir needs a path"; CACHE_DIR_OPT="$2"; shift ;;
        --cache-dir=*)          CACHE_DIR_OPT="${1#*=}" ;;
        --allow-empty-keep-list) ALLOW_EMPTY_KEEP=1 ;;
        -v|--verbose)           VERBOSE=1 ;;
        -h|--help)              usage; exit 0 ;;
        *)                      echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

# ------------------------------------------------------------- keep files ------
if [ ${#KEEP_FILES[@]} -eq 0 ]; then
    KEEP_FILES=("$HOME/data/config.yaml")
fi
if [ -n "${HF_CLEANUP_EXTRA_KEEP:-}" ]; then
    IFS=':' read -r -a _extra_keep <<< "$HF_CLEANUP_EXTRA_KEEP"
    for _ek in "${_extra_keep[@]}"; do
        [ -n "$_ek" ] && KEEP_FILES+=("$_ek")
    done
fi

SCANNED=()
for f in "${KEEP_FILES[@]}"; do
    if [ -r "$f" ]; then
        SCANNED+=("$f")
    else
        warn "cannot read keep file: $f"
    fi
done
[ ${#SCANNED[@]} -gt 0 ] || die "no readable config file to scan (looked at: ${KEEP_FILES[*]})"

# ------------------------------------------------------------- keep rules ------
# Parallel arrays: a rule is "this repo, keep files whose name contains <pattern>".
# pattern == "*" means: keep every file of that repo.
declare -a KEEP_REPO KEEP_PATTERN
declare -A SEEN_RULE
RULE_COUNT=0

add_rule() {
    local repo="$1" pattern="$2" key
    repo="${repo,,}"
    pattern="${pattern,,}"
    case "$pattern" in
        ""|"latest")        pattern="q4_k_m" ;;   # llama.cpp default quant
        "all"|"*"|"any")    pattern="*" ;;
    esac
    [ -n "$repo" ] || return 0
    key="$repo|$pattern"
    [ -n "${SEEN_RULE[$key]:-}" ] && return 0
    SEEN_RULE[$key]=1
    KEEP_REPO+=("$repo")
    KEEP_PATTERN+=("$pattern")
    (( ++RULE_COUNT ))
}

# llama.cpp accepts the reference in two forms, always on the same logical line:
#   -hf  <repo>[:<quant>]
#   -hfr <repo>  -hff <filename-or-quant>
parse_refs_from_file() {
    local file="$1" line lineno=0 tok nxt repo_for_hff rule_idx
    local -a words
    while IFS= read -r line || [ -n "$line" ]; do
        (( ++lineno ))
        repo_for_hff=""
        rule_idx=-1
        words=()
        for tok in $line; do
            words+=("$tok")
        done
        local i=0
        while [ $i -lt ${#words[@]} ]; do
            tok="${words[$i]}"
            # strip yaml/sh quoting around tokens
            tok="${tok//[\"\`\']/}"
            tok="${tok#-}"
            tok="${tok#-}"
            case "$tok" in
                hf)
                    nxt="${words[$((i+1))]:-}"
                    nxt="${nxt//[\"\`\']/}"
                    if [ -z "$nxt" ]; then
                        warn "$file:$lineno: -hf with nothing after it, ignoring"
                    elif [[ "$nxt" == *:* ]]; then
                        add_rule "${nxt%%:*}" "${nxt#*:}"
                    else
                        add_rule "$nxt" ""    # no quant given -> llama.cpp default (Q4_K_M)
                    fi
                    i=$((i+2))
                    ;;
                hfr)
                    nxt="${words[$((i+1))]:-}"
                    nxt="${nxt//[\"\`\']/}"
                    if [ -z "$nxt" ]; then
                        warn "$file:$lineno: -hfr with nothing after it, ignoring"
                    else
                        repo_for_hff="${nxt%%:*}"
                        add_rule "$repo_for_hff" "*"
                        rule_idx=$(( ${#KEEP_REPO[@]} - 1 ))
                    fi
                    i=$((i+2))
                    ;;
                hff)
                    nxt="${words[$((i+1))]:-}"
                    nxt="${nxt//[\"\`\']/}"
                    if [ $rule_idx -ge 0 ] && [ -n "$nxt" ]; then
                        case "${nxt,,}" in
                            ""|"latest") KEEP_PATTERN[$rule_idx]="q4_k_m" ;;
                            "all"|"*")   KEEP_PATTERN[$rule_idx]="*" ;;
                            *)           KEEP_PATTERN[$rule_idx]="${nxt,,}" ;;
                        esac
                    else
                        warn "$file:$lineno: -hff found without a matching -hfr on the same line, ignoring"
                    fi
                    i=$((i+2))
                    ;;
                *)
                    i=$((i+1))
                    ;;
            esac
        done
    done < "$file"
}

for f in "${SCANNED[@]}"; do
    parse_refs_from_file "$f"
done
set +f

echo "=== cleanup-hf-cache.sh ==="
echo "Config files scanned for -hf / -hfr references:"
for f in "${SCANNED[@]}"; do
    echo "  - $f"
done

if [ "$RULE_COUNT" -eq 0 ]; then
    echo ""
    echo "No reference to any Hugging Face model was found in those files."
    echo "That means every cached model would be treated as an orphan and wiped out."
    if [ "$ALLOW_EMPTY_KEEP" != "1" ]; then
        die "empty keep list refused. If that is really what you want, re-run with --allow-empty-keep-list (a wrong --keep-file path otherwise wipes the whole cache)."
    fi
    echo "Proceeding as requested (--allow-empty-keep-list)."
else
    echo ""
    echo "--- models to KEEP ($RULE_COUNT rule(s)) ---"
    for i in "${!KEEP_REPO[@]}"; do
        if [ "${KEEP_PATTERN[$i]}" = "*" ]; then
            echo "  ${KEEP_REPO[$i]}  (every file)"
        else
            echo "  ${KEEP_REPO[$i]} : ${KEEP_PATTERN[$i]}"
        fi
    done
    echo "-------------------------------------------"
fi

# ----------------------------------------------------------- cache location ----
CACHE_DIR="$CACHE_DIR_OPT"
if [ -z "$CACHE_DIR" ]; then
    CACHE_DIR="${HF_HUB_CACHE:-}"
fi
if [ -z "$CACHE_DIR" ]; then
    CACHE_DIR="${LLAMA_CACHE:-}"
fi
if [ -z "$CACHE_DIR" ]; then
    CACHE_DIR="$HOME/.cache/huggingface/hub"
fi
CACHE_DIR="${CACHE_DIR%/}"
[ -d "$CACHE_DIR" ] || die "cache directory not found: $CACHE_DIR (set HF_HUB_CACHE or use --cache-dir)"
echo "HF cache directory: $CACHE_DIR"
if [ -z "$HF_BIN" ]; then
    warn "'hf' CLI not found; falling back to raw file removal (no hf cache prune)."
fi

# Exact repo id per cache directory, taken from `hf cache list` when possible
# (repo ids may contain "--", which makes the directory name ambiguous).
declare -A EXACT_REPO_ID
if [ -n "$HF_BIN" ] && [ -n "$JQ_BIN" ]; then
    _list="$("$HF_BIN" cache list --revisions --cache-dir "$CACHE_DIR" --format json 2>/dev/null || true)"
    if [ -n "$_list" ]; then
        while IFS=$'\t' read -r _rid _rev _snap; do
            [ -n "$_rid" ] && [ -n "$_snap" ] || continue
            EXACT_REPO_ID["$(dirname "$(dirname "$_snap")")"]="$_rid"
        done < <(printf '%s' "$_list" | "$JQ_BIN" -r \
            '.[] | select(.repo_type=="model") | [(.repo_id//""),(.revision//""),(.snapshot_path//"")] | @tsv' 2>/dev/null)
    fi
fi

dir_size() {
    local v
    v="$(du -sb -- "$1" 2>/dev/null | cut -f1)"
    [ -n "$v" ] && echo "$v" || echo 0
}

file_size() {
    local v
    v="$(stat -Lc %s -- "$1" 2>/dev/null)"
    [ -n "$v" ] && echo "$v" || echo 0
}

human() {
    awk -v b="${1:-0}" 'BEGIN{ n=split("B KiB MiB GiB TiB",u," "); i=1;
        while (b>=1024 && i<n) { b/=1024; i++ }
        if (i==1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i] }'
}

cache_total() {
    local t=0 d
    for d in "$CACHE_DIR"/models--*; do
        [ -d "$d" ] || continue
        t=$(( t + $(dir_size "$d") ))
    done
    echo "$t"
}

# ------------------------------------------------------------- planning --------
# Tier 1: whole orphan repos. Tier 2: individual files of referenced repos.
# Dangling symlinks are reported separately.
declare -a ORPHAN_REPO ORPHAN_DIR ORPHAN_SIZE ORPHAN_NOTE
declare -a T2_REPO T2_FILE T2_PATH T2_SIZE
declare -a DANGLING
declare -a KEPT_VERBOSE
ORPHAN_BYTES=0
T2_BYTES=0
REPO_TOTAL=0
REFERENCED_REPOS=()

matches_a_kept_quant() {
    local repo="$1" filename="$2" i
    local -a idx=()
    for i in "${!KEEP_REPO[@]}"; do
        [ "${KEEP_REPO[$i]}" = "$repo" ] && idx+=("$i")
    done
    [ ${#idx[@]} -eq 0 ] && return 2      # no rule for this repo at all
    for i in "${idx[@]}"; do
        local p="${KEEP_PATTERN[$i]}"
        [ "$p" = "*" ] && return 0
        [[ "$filename" == *"$p"* ]] && return 0
    done
    return 1
}

note_kept() {
    [ "$VERBOSE" = "1" ] && KEPT_VERBOSE+=("$1")
}

for repo_dir in "$CACHE_DIR"/models--*; do
    [ -d "$repo_dir" ] || continue
    (( ++REPO_TOTAL ))
    base="${repo_dir##*/}"
    repo_id="${EXACT_REPO_ID[$repo_dir]:-}"
    if [ -z "$repo_id" ]; then
        repo_id="${base#models--}"
        repo_id="${repo_id//--//}"
    fi

    # does any rule reference this repo? (exact match, case-insensitive)
    has_rule=0
    for i in "${!KEEP_REPO[@]}"; do
        if [ "${KEEP_REPO[$i]}" = "${repo_id,,}" ]; then
            has_rule=1
            break
        fi
    done

    if [ "$has_rule" = "0" ]; then
        sz=$(dir_size "$repo_dir")
        files=""
        for s in "$repo_dir"/snapshots/*/; do
            [ -d "$s" ] || continue
            for f in "$s"*; do
                [ -e "$f" ] || [ -L "$f" ] || continue
                b="${f##*/}"
                case "$b" in *.incomplete) continue ;; esac
                files="${files:+$files, }$b"
            done
        done
        ORPHAN_REPO+=("$repo_id")
        ORPHAN_DIR+=("$repo_dir")
        ORPHAN_SIZE+=("$sz")
        ORPHAN_NOTE+=("${files:-<empty>}")
        ORPHAN_BYTES=$(( ORPHAN_BYTES + sz ))
        continue
    fi

    REFERENCED_REPOS+=("$repo_id")

    # Tier 2: walk every revision of a referenced repo.
    for snap in "$repo_dir"/snapshots/*/; do
        [ -d "$snap" ] || continue
        for f in "$snap"*; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            # broken links are handled by the dangling-link pass below
            if [ -L "$f" ] && [ ! -e "$f" ]; then
                continue
            fi
            fname="${f##*/}"
            case "${fname,,}" in
                *.incomplete)
                    note_kept "keeping in-progress download: $repo_id/$fname"
                    continue
                    ;;
                mmproj*)
                    note_kept "keeping mmproj (repo is referenced): $repo_id/$fname"
                    continue
                    ;;
            esac
            matches_a_kept_quant "${repo_id,,}" "${fname,,}"
            case $? in
                0)
                    note_kept "keeping (quant referenced): $repo_id/$fname"
                    ;;
                2)
                    warn "no keep rule matched $repo_id while it was classified as referenced; keeping $fname"
                    ;;
                *)
                    sz=$(file_size "$f")
                    T2_REPO+=("$repo_id")
                    T2_FILE+=("$fname")
                    T2_PATH+=("$f")
                    T2_SIZE+=("$sz")
                    T2_BYTES=$(( T2_BYTES + sz ))
                    ;;
            esac
        done
    done

    # dangling snapshot symlinks: leftovers of older blob-level deletions
    for snap in "$repo_dir"/snapshots/*/; do
        [ -d "$snap" ] || continue
        for f in "$snap"*; do
            if [ -L "$f" ] && [ ! -e "$f" ]; then
                DANGLING+=("$f")
            fi
        done
    done
done

# --------------------------------------------------------------- reporting -----
echo ""
echo "Cached model repos found: $REPO_TOTAL ($(human $(cache_total)))"

if [ ${#ORPHAN_REPO[@]} -gt 0 ]; then
    echo ""
    echo "--- TIER 1: orphan repos, no reference at all -> removed entirely (mmproj included) ---"
    for i in "${!ORPHAN_REPO[@]}"; do
        printf '  %-70s %10s   files: %s\n' "${ORPHAN_REPO[$i]}" "$(human "${ORPHAN_SIZE[$i]}")" "${ORPHAN_NOTE[$i]}"
    done
fi

if [ ${#T2_REPO[@]} -gt 0 ]; then
    echo ""
    echo "--- TIER 2: quant variants of referenced repos that no longer match the config ---"
    for i in "${!T2_REPO[@]}"; do
        printf '  %-60s %10s   %s\n' "${T2_REPO[$i]}/${T2_FILE[$i]}" "$(human "${T2_SIZE[$i]}")" "${T2_PATH[$i]}"
    done
fi

if [ ${#DANGLING[@]} -gt 0 ]; then
    echo ""
    echo "--- broken snapshot symlinks (leftovers of older cleanups) ---"
    for f in "${DANGLING[@]}"; do
        echo "  $f"
    done
fi

if [ "$VERBOSE" = "1" ] && [ ${#KEPT_VERBOSE[@]} -gt 0 ]; then
    echo ""
    echo "--- kept ---"
    for k in "${KEPT_VERBOSE[@]}"; do
        echo "  $k"
    done
fi

TOTAL_PLAN=$(( ORPHAN_BYTES + T2_BYTES ))
echo ""
if [ ${#ORPHAN_REPO[@]} -eq 0 ] && [ ${#T2_REPO[@]} -eq 0 ] && [ ${#DANGLING[@]} -eq 0 ]; then
    echo "Nothing to remove: every cached file matches a reference in the config."
else
    echo "Planned removal: ${#ORPHAN_REPO[@]} repo(s), ${#T2_REPO[@]} file(s), ${#DANGLING[@]} broken link(s) -> $(human $TOTAL_PLAN)"
fi
if [ ${#REFERENCED_REPOS[@]} -gt 0 ]; then
    echo "Referenced repos left untouched (their mmproj files included): ${REFERENCED_REPOS[*]}"
fi

run_prune() {
    # $1: "report" to preview with --dry-run, anything else to actually prune.
    local mode="${1:-act}"
    [ -n "$HF_BIN" ] || { warn "skipping 'hf cache prune': hf CLI not available"; return 0; }
    if [ "$mode" = "report" ]; then
        echo "\$ hf cache prune --dry-run --cache-dir $CACHE_DIR"
        "$HF_BIN" cache prune --dry-run --cache-dir "$CACHE_DIR" || true
    else
        echo "\$ hf cache prune -y --cache-dir $CACHE_DIR"
        "$HF_BIN" cache prune -y --cache-dir "$CACHE_DIR" || true
    fi
}

do_sweep() {
    # $1: "report" to only show what would be removed, anything else to act.
    local mode="${1:-act}"
    local report=0
    [ "$mode" = "report" ] && report=1
    # Remove unlinked blobs, empty repo shells and empty lock dirs. Never touches
    # *.incomplete (those belong to running downloads and to hf cache prune).
    local removed=0 repo_dir b f t linked
    declare -A seen_link
    for repo_dir in "$CACHE_DIR"/models--*; do
        [ -d "$repo_dir" ] || continue
        linked=0
        for f in "$repo_dir"/snapshots/*/*; do
            if [ -L "$f" ]; then
                t="$(realpath -- "$f" 2>/dev/null || true)"
                [ -n "$t" ] && { seen_link["$t"]=1; (( ++linked )); }
            elif [ -f "$f" ]; then
                (( ++linked ))
            fi
        done
        for b in "$repo_dir"/blobs/*; do
            case "${b##*/}" in *.incomplete) continue ;; esac
            [ -f "$b" ] || continue
            t="$(realpath -- "$b" 2>/dev/null || echo "$b")"
            if [ -z "${seen_link[$t]:-}" ]; then
                if [ "$report" = "1" ]; then
                    echo "  would remove unlinked blob: $b"
                else
                    rm -f -- "$b" && echo "  removed unlinked blob: $b" && (( ++removed ))
                fi
            fi
        done
        # empty repo shell (no file, no snapshot link left inside)
        if [ "$linked" -eq 0 ] && [ -z "$(find "$repo_dir" -type f ! -name '*.incomplete' -print -quit 2>/dev/null)" ]; then
            if [ "$report" = "1" ]; then
                echo "  would remove empty cache dir: $repo_dir"
            else
                rm -rf -- "$repo_dir" && echo "  removed empty cache dir: $repo_dir"
            fi
        fi
    done
    for lockdir in "$CACHE_DIR"/.locks/models--*; do
        [ -d "$lockdir" ] || continue
        if [ -z "$(ls -A "$lockdir" 2>/dev/null)" ]; then
            if [ "$report" = "1" ]; then
                echo "  would remove empty lock dir: $lockdir"
            else
                rmdir -- "$lockdir" 2>/dev/null && echo "  removed empty lock dir: $lockdir"
            fi
        fi
    done
}

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "After the removals the script also runs 'hf cache prune' and a sweep of unlinked"
    echo "blobs / empty cache dirs / empty lock dirs. Preview on the current state:"
    run_prune report
    do_sweep report
    echo ""
    echo "Dry run: nothing was deleted."
    exit 0
fi

# ---------------------------------------------------------------- action -----

# Nothing to remove: still worth running prune + sweep, no confirmation needed then.
if [ ${#ORPHAN_REPO[@]} -eq 0 ] && [ ${#T2_REPO[@]} -eq 0 ] && [ ${#DANGLING[@]} -eq 0 ]; then
    echo ""
    echo "Nothing matched for removal; running 'hf cache prune' and the leftover sweep only."
    BEFORE=$(cache_total)
    run_prune act
    echo "--- leftover sweep ---"
    do_sweep act
    AFTER=$(cache_total)
    echo ""
    echo "Done. Cache of model repos: $(human $BEFORE) -> $(human $AFTER) (freed $(human $(( BEFORE - AFTER ))))"
    exit 0
fi

if [ "$ASSUME_YES" != "1" ]; then
    if [ ! -t 0 ]; then
        echo ""
        echo "Cancelled: not an interactive terminal, refusing to delete anything."
        echo "Re-run with --yes (or --dry-run to just look)."
        exit 2
    fi
    echo ""
    printf "Delete %s of unreferenced model cache? (y/N) " "$(human $TOTAL_PLAN)"
    read -r answer
    case "$answer" in
        [Yy]*) ;;
        *) echo "Cancelled."; exit 2 ;;
    esac
fi

BEFORE=$(cache_total)
echo ""

if [ ${#DANGLING[@]} -gt 0 ]; then
    for f in "${DANGLING[@]}"; do
        rm -f -- "$f" && echo "removed broken link: $f"
    done
fi

if [ ${#T2_REPO[@]} -gt 0 ]; then
    if [ -n "$HF_BIN" ]; then
        targets=()
        for i in "${!T2_REPO[@]}"; do
            targets+=("hf://models/${T2_REPO[$i]}/${T2_FILE[$i]}")
        done
        echo "Removing quant variants with: hf cache rm <${#targets[@]} files>"
        "$HF_BIN" cache rm --cache-dir "$CACHE_DIR" -y "${targets[@]}" || true
    fi
    # verify, and fall back to removing the snapshot link directly (the blob sweep
    # then reclaims the data) for anything hf did not handle
    for i in "${!T2_PATH[@]}"; do
        if [ -e "${T2_PATH[$i]}" ] || [ -L "${T2_PATH[$i]}" ]; then
            rm -f -- "${T2_PATH[$i]}" && echo "removed snapshot link: ${T2_PATH[$i]}"
        fi
    done
fi

if [ ${#ORPHAN_REPO[@]} -gt 0 ]; then
    if [ -n "$HF_BIN" ]; then
        targets=()
        for i in "${!ORPHAN_REPO[@]}"; do
            targets+=("model/${ORPHAN_REPO[$i]}")
        done
        echo "Removing ${#targets[@]} orphan repo(s) with hf cache rm"
        "$HF_BIN" cache rm --cache-dir "$CACHE_DIR" -y "${targets[@]}" || true
    fi
    for i in "${!ORPHAN_DIR[@]}"; do
        if [ -d "${ORPHAN_DIR[$i]}" ]; then
            rm -rf -- "${ORPHAN_DIR[$i]}" && echo "removed cache dir: ${ORPHAN_DIR[$i]}"
        fi
    done
fi

run_prune act
echo "--- leftover sweep ---"
do_sweep act

AFTER=$(cache_total)
echo ""
echo "Done. Cache of model repos: $(human $BEFORE) -> $(human $AFTER) (freed $(human $(( BEFORE - AFTER ))))"
