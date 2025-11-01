#!/bin/bash
# Author: PB and Claude
# Date: 2025-10-31
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/lib/backup-find-diff.sh
#
# Find-based diff approach for determining what files need backup

# Capture list of files from local directory
# Args: root_dir, output_file
# Output: Sorted list of relative paths with sizes (path<TAB>size, one per line)
capture_file_list() {
    local root_dir="$1"
    local output_file="$2"

    log "INFO: Capturing file list from $root_dir..."

    # Use find to get relative paths with sizes, sorted
    # -type f: only files
    # -printf '%P\t%s\n': relative path <TAB> size in bytes
    # LC_ALL=C ensures consistent byte-order sorting for join compatibility
    if find "$root_dir" -type f -printf '%P\t%s\n' 2>/dev/null | LC_ALL=C sort > "$output_file"; then
        local count=$(wc -l < "$output_file")
        log "INFO: Captured $count files from $root_dir"
        return 0
    else
        log "ERROR: Failed to capture file list from $root_dir"
        return 1
    fi
}

# Capture list of files from remote directory via SSH (streaming)
# Args: ssh_host, remote_dir, output_file
# Output: Sorted list of relative paths with sizes (path<TAB>size, one per line)
capture_remote_file_list() {
    local ssh_host="$1"
    local remote_dir="$2"
    local output_file="$3"

    log "INFO: Capturing remote file list from $ssh_host:$remote_dir..."

    # Stream through SSH - find and sort on remote, stream results back
    # Single SSH command is much faster than multiple round-trips
    # LC_ALL=C ensures consistent byte-order sorting for join compatibility
    if ssh "$ssh_host" "LC_ALL=C find '$remote_dir' -type f -printf '%P\t%s\n' 2>/dev/null | LC_ALL=C sort" > "$output_file"; then
        local count=$(wc -l < "$output_file")
        log "INFO: Captured $count files from remote"
        return 0
    else
        log "ERROR: Failed to capture remote file list"
        return 1
    fi
}

# Diff two sorted file lists and validate sizes
# Args: source_list, dest_list, missing_list, [force_overwrite]
# Output: List of files to copy (path<TAB>size)
# CRITICAL: Fails immediately if same file has different sizes (corruption!)
#   unless force_overwrite=true, in which case corrupted files are added to missing_list
diff_and_validate_lists() {
    local source_list="$1"
    local dest_list="$2"
    local missing_list="$3"
    local force_overwrite="${4:-false}"

    log "INFO: Computing diff between source and destination..."

    # First, check for files in both locations with size mismatches (CORRUPTION!)
    # join on first field (path), compare sizes
    # LC_ALL=C ensures consistent collation order
    local corrupted=$(LC_ALL=C join -t $'\t' "$source_list" "$dest_list" | awk -F'\t' '$2 != $3 {print}')

    if [ -n "$corrupted" ]; then
        local corrupt_count=$(echo "$corrupted" | wc -l)
        log "WARNING: SIZE MISMATCH DETECTED - $corrupt_count files have different sizes"
        log "WARNING: Mismatched files:"
        echo "$corrupted" | while IFS=$'\t' read -r path src_size dst_size; do
            log "WARNING:   $path: source=$src_size bytes, dest=$dst_size bytes"
        done

        if [[ "$force_overwrite" != "true" ]]; then
            log "ERROR: Refusing to continue - use --force to overwrite mismatched files"
            return 1
        fi

        log "WARNING: Force mode enabled - adding mismatched files to copy list"
        # Extract just the path and source size from corrupted files
        echo "$corrupted" | awk -F'\t' '{print $1 "\t" $2}' > "$missing_list"
    else
        # No corrupted files, start with empty missing list
        > "$missing_list"
    fi

    # Find files only in source (missing from destination)
    # join -v1: only lines from file 1 (source) with no match in file 2 (dest)
    # Append to missing_list (which may already have corrupted files)
    # LC_ALL=C ensures consistent collation order
    if LC_ALL=C join -t $'\t' -v1 "$source_list" "$dest_list" >> "$missing_list"; then
        local count=$(wc -l < "$missing_list")
        log "INFO: Found $count files to copy"
        return 0
    else
        log "ERROR: Failed to diff file lists"
        return 1
    fi
}

# Calculate total size from file list (path<TAB>size format)
# Args: file_list
# Output: Total size in bytes
calculate_total_size() {
    local file_list="$1"

    awk -F'\t' '{sum+=$2} END {print sum}' "$file_list"
}

# Rsync files from list
# Args: file_list, source_root, dest_root, [ssh_host]
# If ssh_host provided, destination is remote
# Set DRY_RUN=true environment variable for dry-run mode
rsync_from_list() {
    local file_list="$1"
    local source_root="$2"
    local dest_root="$3"
    local ssh_host="${4:-}"  # Optional

    local count=$(wc -l < "$file_list")

    if [ "$count" -eq 0 ]; then
        log "INFO: No files to copy, destination is up to date"
        return 0
    fi

    # Calculate total size
    local total_bytes=$(calculate_total_size "$file_list")
    local total_gb=$(awk "BEGIN {printf \"%.2f\", $total_bytes / 1024 / 1024 / 1024}")

    # Build destination path
    local dest_path="$dest_root"
    if [ -n "$ssh_host" ]; then
        dest_path="$ssh_host:$dest_root"
    fi

    # Dry-run mode: just report what would be copied
    if [ "${DRY_RUN:-false}" = "true" ]; then
        log "INFO: DRY-RUN: Would copy $count files ($total_gb GB) to $dest_path"
        return 0
    fi

    log "INFO: Copying $count files ($total_gb GB)..."
    if [ -n "$ssh_host" ]; then
        log "INFO: Destination: $dest_path (remote)"
    else
        log "INFO: Destination: $dest_path (local)"
    fi

    # Extract just paths for rsync (drop size column)
    local paths_only=$(mktemp)
    cut -f1 "$file_list" > "$paths_only"

    # rsync options:
    # -a: archive mode
    # -v: verbose
    # --files-from: read file list
    # --relative: preserve directory structure from paths in list
    # --partial: keep partial files on interruption
    if rsync -av \
        --relative \
        --partial \
        --files-from="$paths_only" \
        "$source_root/" \
        "$dest_path/" \
        2>&1 | tee -a "${LOG_FILE:-/dev/stderr}"; then
        rm -f "$paths_only"
        log "INFO: rsync completed successfully"
        return 0
    else
        local exit_code=$?
        rm -f "$paths_only"
        log "ERROR: rsync failed with exit code $exit_code"
        return $exit_code
    fi
}

# Cleanup temporary files
cleanup_temp_files() {
    local temp_dir="$1"

    if [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir"
        log "INFO: Cleaned up temp directory: $temp_dir"
    fi
}
