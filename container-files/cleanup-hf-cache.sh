#!/bin/bash

clean_blob() {
    echo "Checking for any unreferenced blobs and removing."
    
    for f in ${HF_CACHE_DIR}/*/blobs/*; do
        dir=$(dirname "$f")
        realpath_f=$(realpath "$f")
        if ! find ${dir}/../snapshots/ -type l -exec realpath {} + | grep -q "^$realpath_f$"; then
            echo "No link found for: $f"
            rm -f "$f"
            echo "Removed $f"
        fi
    done
}

# 1. Get the list of models to KEEP from config.yaml
# Format expected: unsloth/gemma-4-E4B-it-GGUF:Q5_K_M
KEEP_LIST_DISPLAY=$(cat ~/data/config.yaml | grep "\-hf" | sed 's|-hf||g' | tr -d ' \t#')

if [ -z "$KEEP_LIST_DISPLAY" ]; then
    echo "Error: Keep list is empty. Check your config.yaml or the grep pattern."
    exit 1
fi

# Prepare case-insensitive comparison arrays
declare -a KEEP_REPOS_LOWER
declare -a KEEP_QUANTS_LOWER
while read -r item; do
    [ -z "$item" ] && continue
    repo="${item%%:*}"
    quant="${item#*:}"
    KEEP_REPOS_LOWER+=("${repo,,}")
    KEEP_QUANTS_LOWER+=("${quant,,}")
done <<< "$KEEP_LIST_DISPLAY"

echo "--- Models to KEEP ---"
echo "$KEEP_LIST_DISPLAY"
echo "----------------------"

# 2. Find the HF cache directory
HF_CACHE_DIR="$HF_HUB_CACHE"

if [ -z "$HF_CACHE_DIR" ] || [ ! -d "$HF_CACHE_DIR" ]; then
    echo "Error: HF_HUB_CACHE is not set or the directory does not exist."
    exit 1
fi

echo "Scanning cache at $HF_CACHE_DIR..."

# We will track files to delete
# Key for associative arrays: "repo|revision"
declare -A FILES_TO_DELETE_BY_REV  # "repo|rev" -> "file1, file2"
declare -A REPO_BY_REV            # "repo|rev" -> repo_name
declare -a ALL_DELETE_PATHS       # List of absolute paths to rm

# 3. Iterate through the cache directory
for repo_dir in "$HF_CACHE_DIR"/models--*; do
    [ -e "$repo_dir" ] || continue
    
    repo_dir_name="${repo_dir##*/}"
    repo_raw="${repo_dir_name#models--}"
    # Normalize the repo name: convert '--' back to '/'
    repo_normalized=$(echo "$repo_raw" | sed 's|--|/|g')
    repo_normalized_lower="${repo_normalized,,}"

    for snapshot_dir in "$repo_dir"/snapshots/*; do
        [ -e "$snapshot_dir" ] || continue
        
        revision="${snapshot_dir##*/}"
        rev_key="$repo_normalized|$revision"
        
        for file in "$snapshot_dir"/*; do
            [ -e "$file" ] || continue
            filename=$(basename "$file")
            filename_lower=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
            if [[ "${filename_lower}" == "mmproj"* ]]; then
                continue
            fi
            
            is_kept=false
            # Check if this specific file matches any of our keep rules
            for i in "${!KEEP_REPOS_LOWER[@]}"; do
                if [[ "$repo_normalized_lower" == "${KEEP_REPOS_LOWER[$i]}" ]] && \
                   [[ "$filename_lower" == *"${KEEP_QUANTS_LOWER[$i]}"* ]]; then
                    is_kept=true
                    break
                fi
            done
            
            if [ "$is_kept" = false ]; then
                ALL_DELETE_PATHS+=("$file")
                
                # Group for display
                if [ -z "${FILES_TO_DELETE_BY_REV[$rev_key]}" ]; then
                    FILES_TO_DELETE_BY_REV[$rev_key]="$filename"
                else
                    FILES_TO_DELETE_BY_REV[$rev_key]="${FILES_TO_DELETE_BY_REV[$rev_key]}, $filename"
                fi
                REPO_BY_REV[$rev_key]="$repo_normalized"
            fi
        done
    done
done

# 4. Results and Confirmation
if [ ${#ALL_DELETE_PATHS[@]} -eq 0 ]; then
    clean_blob
    echo "No unnecessary files found in cache. Everything matches your keep list."
    exit 0
fi

echo ""
echo "--- THE FOLLOWING FILES WILL BE DELETED ---"
for rev_key in "${!FILES_TO_DELETE_BY_REV[@]}"; do
    # Extract repo and revision from key
    repo="${REPO_BY_REV[$rev_key]}"
    rev="${rev_key#*|}"
    echo "  - $repo (rev: $rev) [files: ${FILES_TO_DELETE_BY_REV[$rev_key]}]"
done
echo "--------------------------------------------"
echo "Total files to delete: ${#ALL_DELETE_PATHS[@]}"
echo ""
read -p "Are you sure you want to proceed with deletion? (y/N): " confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "Starting deletion..."
    for path in "${ALL_DELETE_PATHS[@]}"; do
        echo "Removing $path"
        rm "$path"
    done
    
    echo "Cleaning up unreferenced blobs (pruning)..."
    # We use your tool's prune command to free up actual disk space
    hf cache prune

    clean_blob

    echo "Cleanup complete."
else
    echo "Deletion cancelled."
fi

