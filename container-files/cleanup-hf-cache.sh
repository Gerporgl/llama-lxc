#!/bin/bash

# 1. Get the list of models to KEEP from config.yaml
# Format expected: unsloth/gemma-4-E4B-it-GGUF:Q5_K_M
KEEP_LIST=$(cat ~/data/config.yaml | grep "\-hf" | sed 's|-hf||g' | tr -d ' \t')

if [ -z "$KEEP_LIST" ]; then
    echo "Error: Keep list is empty. Check your config.yaml or the grep pattern."
    exit 1
fi

echo "--- Models to KEEP ---"
echo "$KEEP_LIST"
echo "----------------------"

# 2. Find the HF cache directory using the standard HF_HUB_CACHE env var
HF_CACHE_DIR="$HF_HUB_CACHE"

if [ -z "$HF_CACHE_DIR" ] || [ ! -d "$HF_CACHE_DIR" ]; then
    echo "Error: HF_HUB_CACHE is not set or the directory does not exist."
    exit 1
fi

echo "Scanning cache at $HF_CACHE_DIR..."

# We will track which cache entries (repo + revision) we have "accounted for"
declare -A CACHE_ENTRIES
declare -A FOUND_IN_KEEP
declare -A REVISION_FILES  # Stores the filenames found in each revision

# 3. Iterate through the cache directory to find what's actually there
# The structure is: $HF_CACHE_DIR/models--<repo>/snapshots/<revision>/<filename>
for repo_dir in "$HF_CACHE_DIR"/models--*; do
    [ -e "$repo_dir" ] || continue
    
    repo_dir_name="${repo_dir##*/}"
    repo_raw="${repo_dir_name#models--}"
    # Normalize the repo name: convert '--' back to '/'
    repo_normalized=$(echo "$repo_raw" | sed 's|--|/|g')

    for snapshot_dir in "$repo_dir"/snapshots/*; do
        [ -e "$snapshot_dir" ] || continue
        
        revision="${snapshot_dir##*/}"
        
        # Track filenames in this revision for display purposes
        current_rev_files=""
        
        for file in "$snapshot_dir"/*; do
            [ -e "$file" ] || continue
            filename=$(basename "$file")
            
            # Append filename to the list for this revision for the final report
            if [ -z "$current_rev_files" ]; then
                current_rev_files="$filename"
            else
                current_rev_files="$current_rev_files, $filename"
            fi
            
            while read -r keep_item; do
                [ -z "$keep_item" ] && continue
                repo_part="${keep_item%%:*}"
                quant_part="${keep_item#*:}"
                
                # Match repo (normalized) and quantization part in filename
                if [[ "${repo_normalized,,}" == "${repo_part,,}" ]] && [[ "${filename,,}" == *"${quant_part,,}"* ]]; then
                    FOUND_IN_KEEP["$repo_normalized|$revision"]=1
                fi
            done <<< "$KEEP_LIST"
        done
        
        # Register this specific revision
        CACHE_ENTRIES["$repo_normalized|$revision"]=1
        REVISION_FILES["$repo_normalized|$revision"]="$current_rev_files"
    done
done

# 4. Identify what to delete
TO_DELETE_REPOS=()
TO_DELETE_REVS=()
TO_DELETE_DISPLAY=()

for entry in "${!CACHE_ENTRIES[@]}"; do
    if [[ -z "${FOUND_IN_KEEP[$entry]}" ]]; then
        repo="${entry%|*}"
        rev="${entry#*|}"
        files="${REVISION_FILES[$entry]}"
        
        TO_DELETE_REPOS+=("$repo")
        TO_DELETE_REVS+=("$rev")
        # Show the repo, revision hash, and the files contained in that revision
        TO_DELETE_DISPLAY+=("$repo (rev: $rev) [files: $files]")
    fi
done

if [ ${#TO_DELETE_REPOS[@]} -eq 0 ]; then
    echo "No unnecessary models found in cache. Everything matches your keep list."
    exit 0
fi

echo "--- THE FOLLOWING MODELS WILL BE DELETED ---"
for i in "${!TO_DELETE_DISPLAY[@]}"; do
    echo "  - ${TO_DELETE_DISPLAY[$i]}"
done
echo "--------------------------------------------"
echo "Total items to delete: ${#TO_DELETE_REPOS[@]}"
echo ""
read -p "Are you sure you want to proceed with deletion? (y/N): " confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "Starting deletion..."
    for i in "${!TO_DELETE_REPOS[@]}"; do
        repo="${TO_DELETE_REPOS[$i]}"
        rev="${TO_DELETE_REVS[$i]}"
        
        echo "Deleting $repo (revision $rev)..."
        # hf cache rm only needs the revision hash
        hf cache rm "$rev" --yes
    done
    echo "Cleanup complete."
else
    echo "Deletion cancelled."
fi
