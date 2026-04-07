#!/bin/bash

# This script is designed to run on a Proxmox VE server, on the host root shell directly
#
# It takes care of setting up the proper devices required for a container ROCm passthrough
# for amdgpu. It gets the proper group IDs and MajorID of devices and then
# patches the lxc config file of a given proxmox CT id to add the requires permissions
# and user id and group id mapping for an unprivileged container
# The script also creates a new CT based on the image listed bellow if the CT id does not
# exists in proxmox.
#
# This script should be relativelly safe, it is simple overall, and makes backup of lxc conf file
# in the current folder, and also ask confirmations before proceeding.
#
# The only thing it really does on the host itself is to assign the root user to groups "render" and "video"
# that is all, and create those groups if they don't already exists.
#
# The script currently ask for the video device to use, but that is mostly to set the proper MajorID
# in the cgroupv2, other than that, we currently cannot limit to one gpu, the entire /dev/dri
# has to be passed (tried with only /dev/dri/renderD128 for example, but that did not work, and anyway, it seems
# that /dev/kfd which is needed is enough for ROCm tools by itself to be aware of all GPUs, so this is just the way
# it has to be it seems. In the container itself, for llama-swap service, we limit to GPU #0 using ROCR_VISIBLE_DEVICES),
# this can be adjusted depending on use cases, those who can run multi GPU would probably want to have access to all
# of them anyway.

set -euo pipefail

# Configuration
DEFAULT_IMAGE="/var/lib/vz/template/cache/llama-lxc_latest.tar"
DEFAULT_STORAGE="local-zfs"
ZFS_POOL_NAME="rpool"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_HOSTNAME_PATTERN="CT-llama-swap"
CONF_DIR="/etc/pve/lxc"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Phase 1: Host Initialization
setup_host() {
    log_info "Checking and creating required groups..."
    
    # Create video group if missing
    VIDEO_GID=$(getent group | grep video | cut -d: -f3)
    if [[ ! $VIDEO_GID ]] ; then
        groupadd video
        VIDEO_GID=$(getent group | grep video | cut -d: -f3)
        log_info "Created video group (GID $VIDEO_GID)"
    else
        log_info "Video group GID: $VIDEO_GID"
    fi

    RENDER_GID=$(getent group | grep render | cut -d: -f3)
    if [[ ! $RENDER_GID ]] ; then
        groupadd render
        RENDER_GID=$(getent group | grep render | cut -d: -f3)
        log_info "Created render group (GID $RENDER_GID)"
    else
        log_info "Render group GID: $RENDER_GID"
    fi

    # Add root to groups
    if ! groups root | grep -q 'render\|video'; then
        usermod -aG render,video root
        log_info "Added root to render and video groups"
    fi
    
    # Discover device IDs
    log_info "Discovering device IDs..."
    
    # Find kfd device
    if [[ -e /dev/kfd ]]; then
        major=$(stat -c '%t' /dev/kfd)
        KFD_MAJOR=$((16#$major)) # 511
        KFD_MINOR=0
        log_info "Found /dev/kfd (major $KFD_MAJOR)"
    else
        log_error "/dev/kfd not found!"
        return 1
    fi
    
    # Find render devices
    RENDER_DEVICES=()
    for dev in /dev/dri/renderD*; do
        if [[ -e "$dev" ]]; then
            major=$(stat -c '%t' "$dev")
            minor=$(stat -c '%T' "$dev")
            major_dec=$((16#$major))
            minor_dec=$((16#$minor))
            RENDER_DEVICES+=("$dev:$major_dec:$minor_dec")
            log_info "Found $dev (major $major_dec, minor $minor_dec)"
        fi
    done
    
    if [[ ${#RENDER_DEVICES[@]} -eq 0 ]]; then
        log_error "No render devices found!"
        return 1
    fi
    
    # Store values in global variables
    VIDEO_GID_VAR="$VIDEO_GID"
    RENDER_GID_VAR="$RENDER_GID"
    KFD_MAJOR_VAR="$KFD_MAJOR"
    RENDER_DEVICES_VAR=("${RENDER_DEVICES[@]}")
    
    log_info "Host setup complete"
}

# Phase 2: Check existing container
check_existing_config() {
    local id=$1
    local conf_file="$CONF_DIR/${id}.conf"
    
    if [[ -f "$conf_file" ]]; then
        log_warn "Container config exists: $conf_file"
        echo "The container ID $id already exists, proceeding with only the container configuration update, do you want to continue? [Y/n]"
        read -r -n 1 -p "" confirm
        echo
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Operation cancelled"
            exit 0
        fi
        return 0  # Config exists
    fi
    return 1  # No config exists
}

# Phase 3: GPU Selection
select_gpu() {
    log_info "Selecting AMD GPU device..."
    
    # Display available devices
    log_info "Available render devices:"
    local idx=1
    for dev_entry in "${RENDER_DEVICES_VAR[@]}"; do
        local dev_path major minor
        dev_path=$(echo "$dev_entry" | cut -d: -f1)
        sys_dev=/sys/class/drm/$(basename $dev_path)/
        pci_id=$(ls -l $sys_dev | grep device | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]')
        dev_info=$(lspci -s $pci_id)
        major=$(echo "$dev_entry" | cut -d: -f2)
        minor=$(echo "$dev_entry" | cut -d: -f3)
        log_info "  [$idx] $dev_path (major $major, minor $minor)"
        log_info "      ↳$dev_info"
        ((idx++))
    done
    
    # Get user selection
    while true; do
        echo -n "Select device index (default: 1): "
        read -r selection
        
        if [[ -z "$selection" ]]; then
            RENDER_PATH_VAR="${RENDER_DEVICES_VAR[0]}"
            return
        fi
        
        # Validate input is a positive integer
        if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
            log_error "Invalid input. Please enter a positive integer."
            continue
        fi
        
        # Device index must be at least 1 (1-based)
        if [[ "$selection" -lt 1 ]]; then
            log_error "Invalid input. Please enter a positive integer."
            continue
        fi
        
        local idx=$((selection - 1))
        if [[ $idx -ge 0 && $idx -lt ${#RENDER_DEVICES_VAR[@]} ]]; then
            RENDER_PATH_VAR="${RENDER_DEVICES_VAR[$idx]}"
            return
        else
            log_error "Invalid selection. Please try again."
        fi
    done
}

# Phase 4: Generate configuration
generate_config() {
    local id=$1
    local render_path=$2
    local render_major_num=$3
    local kfd_major_num=$4
    local video_gid=$5
    local render_gid=$6
   
    log_info "Generating container configuration..."
    
    # Backup existing config if it exists
    local conf_file="$CONF_DIR/${id}.conf"
    if [[ -f "$conf_file" ]]; then
        backup_conf=~/CT-${id}.conf.bak.$(date +%Y%m%d_%H%M%S)
        cp $conf_file $backup_conf
        log_info "Backed up existing config in $backup_conf"
    fi
    
    # Create temp file
    local temp_file=$(mktemp)
    
    # Read existing config and filter out specialized configs that are not standard in pve
    # and that we use is our customization
    # Make sure there isn't extra snapshot sections, otherwise we just cancel.
    local existing_section=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[.*\].* ]]; then
            log_error "The container has at least one snapshot! You must remove all snapshots in order to perform this task. Operation cancelled."
            exit 1
        fi
        if [[ "$line" =~ ^lxc.cgroup2.*|lxc.mount.*|lxc.idmap.* ]]; then
            existing_section=true
        fi
        
        if [[ $existing_section == true && "$line" =~ ^[[:space:]]*# && ! "$line" =~ ^#.*AMD.*GPU.*passthrough.*for.*ROCm ]]; then
            existing_section=false
        fi
        
        if [[ $existing_section == false ]]; then
            echo "$line" >> "$temp_file"
        fi
    done < "$conf_file"

    # Hard coded for now, these (must!) match what we created in 
    # our Dockerfile
    video_gid_ct=555
    render_gid_ct=777

    if(( video_gid_ct < render_gid_ct)); then
        low_gid=$video_gid
        high_gid=$render_gid
        low_gid_ct=$video_gid_ct
        high_gid_ct=$render_gid_ct
    else
        low_gid=$render_gid
        high_gid=$video_gid
        low_gid_ct=$render_gid_ct
        high_gid_ct=$video_gid_ct
    fi

    low_count=${low_gid_ct}
    mid_start=$((low_gid_ct + 1))
    mid_start_ct=$((mid_start + 100000))
    mid_count=$((high_gid_ct - mid_start))
    high_start=$((high_gid_ct + 1))
    high_start_ct=$((high_start + 100000))
    high_count=$((65536 - high_start))

    # Append new configuration
    cat >> "$temp_file" << EOF
lxc.cgroup2.devices.allow: c ${render_major_num}:* rwm
lxc.cgroup2.devices.allow: c ${kfd_major_num}:* rwm
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.idmap: u 0 100000 65536
lxc.idmap: g 0 100000 ${low_count}
lxc.idmap: g ${low_gid_ct} ${low_gid} 1
lxc.idmap: g ${mid_start} ${mid_start_ct} ${mid_count}
lxc.idmap: g ${high_gid_ct} ${high_gid} 1
lxc.idmap: g ${high_start} ${high_start_ct} ${high_count}
EOF
    # Copy file to final location
    cp "$temp_file" "$conf_file"
    rm -f $temp_file
    log_info "Configuration written to $conf_file"
}

# Phase 5: Create container
create_container() {
    local id=$1
    local image=$2
    local hostname=$3
    local authorized_keys=$5
    local password=$6

    
    log_info "Creating container..."
    
    # Validate devices exist
    if [[ ! -e /dev/kfd ]]; then
        log_error "/dev/kfd does not exist! Cannot proceed."
        return 1
    fi
    
    # Run pct create

    if [[ -f $authorized_keys ]]; then
        SSH_KEY_OPTION="--ssh-public-keys $authorized_keys"
    else
        log_info "$authorized_keys not present, skipping"
        SSH_KEY_OPTION=""
    fi
    if [[ "$password" == "yes" ]]; then
        PASSWORD_OPT="--password"
    else
        PASSWORD_OPT=""
    fi
    pct create "$id" "$image" \
        --hostname "$hostname" \
        --storage "$DEFAULT_STORAGE" \
        $SSH_KEY_OPTION \
        $PASSWORD_OPT \
        --rootfs 16 \
        --cores 8 \
        --memory 16384 \
        --swap 0 \
        --net0 name=eth0,bridge="$DEFAULT_BRIDGE",ip=dhcp,ip6=dhcp
    
    log_info "Container created successfully"
}

# Phase 6: Update container config
update_container() {
    local id=$1
    local render_device=$2
    
    local render_major_num render_minor_num
    render_path=$(echo "$render_device" | cut -d: -f1)
    render_major_num=$(echo "$render_device" | cut -d: -f2)
    
    local kfd_major_num=$KFD_MAJOR_VAR
    
    log_info "Updating container $id configuration..."
    
    # Generate new config
    generate_config "$id" "$render_path" "$render_major_num" "$kfd_major_num" "$VIDEO_GID_VAR" "$RENDER_GID_VAR"
    
    log_info "Container $id configuration updated"
}

# Phase 7: Confirm creation parameters
confirm_creation() {
    local id=$1
    local image=$2
    local hostname=$3
    local authorized_keys=$4
    local need_password=$5
    
    echo ""
    log_info "Confirming container creation:"
    echo "  ID: $id"
    echo "  Hostname: $hostname"
    echo "  Image: $image"
    echo "  CPU: 8 cores"
    echo "  Memory: 16GB Swap: 0"
    echo "  Storage: 16GB (rootfs)"
    echo "  SSH keys file: $authorized_keys"
    echo "  Set root password? $need_password"
    read -r -n 1 -p "Proceed with creation? [Y/n] " confirm
    echo
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Creation cancelled"
        exit 0
    fi
}

optimize_container() {
    local CTID=$1
    echo "==================================================================================="
    log_info "The following optimizations only set ZFS options for your container subvolumes"
    log_warn "If you don't have zfs, say NO"
    log_warn "If your main local-zfs pool is not called $ZFS_POOL_NAME or mounted under /$ZFS_POOL_NAME, say NO..."
    log_info "This will assume you have a volume 0 (rootfs) and volume 1 for model data"
    read -p "Apply ZFS performance optimizations for AI models? (y/n): " zfs_tune
    if [[ $zfs_tune == "y" ]]; then
        if [ -d "/$ZFS_POOL_NAME/data/subvol-$CTID-disk-1" ]; then
            zfs set xattr=sa atime=off $ZFS_POOL_NAME/data/subvol-$CTID-disk-1
            zfs set recordsize=1M $ZFS_POOL_NAME/data/subvol-$CTID-disk-1
            log_info "ZFS optimizations applied to data volume."
        else
            echo "$ZFS_POOL_NAME/data/subvol-$CTID-disk-1 does not exists. You should rerun this script after you created it."
        fi
        if [ -d "/$ZFS_POOL_NAME/data/subvol-$CTID-disk-0" ]; then
            zfs set xattr=sa $ZFS_POOL_NAME/data/subvol-$CTID-disk-0
            log_info "ZFS optimizations applied to rootfs volume."
        else
            echo "$ZFS_POOL_NAME/data/subvol-$CTID-disk-0 does not exists! This is unexpected."
        fi
    fi

}

# Main execution
main() {
    log_info "=== Llama ROCm LXC Container Setup ==="
    
    # Phase 1: Setup host
    setup_host || exit 1
    
    # Phase 2: Check existing
    if check_existing_config "$1"; then
        # Update existing
        select_gpu
        log_info "Updating existing container..."
    else
        # Create new
        local image hostname
        
        # Get image (default)
        image="$DEFAULT_IMAGE"
        
        # Get hostname
        hostname="$DEFAULT_HOSTNAME_PATTERN" #-$(date +%Y%m%d)"
        
        echo -n "Enter ssh authorized_keys file to use: (default: authorized_keys): "
        read -r authorized_keys
        if [[ -z "$authorized_keys" ]]; then
            authorized_keys="authorized_keys"
        fi

        echo -n "Setup root password for new container? (Y/n): "
        read -r -n 1 -p "" confirm
        echo
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            password="yes"
        else
            password="no"
        fi


        # Confirm parameters
        confirm_creation "$1" "$image" "$hostname" "$authorized_keys" "$password"
        
        # Select GPU
        select_gpu
        
        # Create container
        create_container "$1" "$image" "$hostname" "$RENDER_DEVICES_VAR" "$authorized_keys" "$password"

    fi
    update_container "$1" "$RENDER_DEVICES_VAR"
    optimize_container "$1"

    log_info "=== Setup Complete ==="
}

main "$1"
