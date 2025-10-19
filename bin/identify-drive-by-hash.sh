#!/usr/bin/env bash
# Author: PB and Claude
# Date: Fri 18 Oct 2025
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/identify-drive-by-hash.sh
#
# Identify disk drive by computing both v1 and v2 hash formats
# Logs all results to drive-identification.jsonl for building drive database

set -euo pipefail

# Config
LOG_JSON="/var/log/ntt/drive-identification.jsonl"
mkdir -p "$(dirname "$LOG_JSON")"
chmod 755 "$(dirname "$LOG_JSON")" 2>/dev/null || true

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run with sudo or as root" >&2
   echo "Usage: sudo $0 /dev/sdX" >&2
   exit 1
fi

# Auto-detect device from dmesg if no argument provided
if [[ $# -eq 0 ]]; then
  echo "No device specified, checking dmesg for recently connected drives..."
  echo ""

  # Get dmesg output from last 90 seconds with timestamps
  # dmesg -T shows human-readable timestamps, --since uses systemd time format
  RECENT_DMESG=$(dmesg -T --since '90 seconds ago' 2>/dev/null | grep -E '\[sd[a-z]+\]' || dmesg -T | tail -100 | grep -E '\[sd[a-z]+\]')

  if [[ -z "$RECENT_DMESG" ]]; then
    echo "No recent block devices found in dmesg."
    echo ""
    echo "Usage: sudo $0 <device>"
    echo "Example: sudo $0 /dev/sdb"
    exit 1
  fi

  # Extract most recent device name (e.g., sdb)
  DETECTED_DEVICE=$(echo "$RECENT_DMESG" | grep -oP '\[sd[a-z]+\]' | tail -1 | tr -d '[]')

  if [[ -z "$DETECTED_DEVICE" ]]; then
    echo "Could not parse device name from dmesg."
    echo ""
    echo "Usage: sudo $0 <device>"
    echo "Example: sudo $0 /dev/sdb"
    exit 1
  fi

  # Show recent dmesg output for this device
  echo "Recent dmesg output for detected device:"
  echo "========================================"
  echo "$RECENT_DMESG"
  echo "========================================"
  echo ""
  echo "Detected device: /dev/$DETECTED_DEVICE"
  echo ""
  read -p "Identify this device? (Y/n): " -r RESPONSE
  RESPONSE=${RESPONSE:-Y}

  if [[ ! "$RESPONSE" =~ ^[Yy] ]]; then
    echo "Cancelled. Specify device manually: sudo $0 /dev/sdX"
    exit 0
  fi

  DEVICE="/dev/$DETECTED_DEVICE"
  echo ""

elif [[ $# -eq 1 ]]; then
  DEVICE="$1"
else
  cat <<EOF
Usage: sudo $0 [device]

Auto-detection mode (no arguments):
  sudo $0
  Detects recently connected drive from dmesg and prompts for confirmation.

Manual mode:
  sudo $0 /dev/sdb
  Identifies the specified device directly.

Output shows:
  - Hardware: SIZE, MODEL, SERIAL
  - Partition table type (GPT, MBR, none)
  - Partitions with filesystems and labels
  - Hash (v0/legacy buggy) - matches Oct 7-9, 2025 database (oflag=append bug)
  - Hash (v1/content-only) - correct first+last 1MB hash (for reference)
  - Hash (v2/hybrid) - matches Oct 10+, 2025 database (SIZE|MODEL|SERIAL + content)

Match v0 hash against Oct 7-9 media, v2 hash against Oct 10+ media.
EOF
  exit 1
fi

# Validate device exists
if [[ ! -e "$DEVICE" ]]; then
  echo "Error: Device $DEVICE not found" >&2
  exit 2
fi

if [[ ! -b "$DEVICE" ]]; then
  echo "Error: $DEVICE is not a block device" >&2
  exit 2
fi

# ---------- Hardware Info Functions ----------
get_real_hardware_info() {
  # Get actual drive hardware info, bypassing USB bridges
  # Sets global variables: MODEL, SERIAL
  #
  # Args: $1 = device path (e.g., /dev/sdd)
  #
  # Strategy (copied from ntt-orchestrator):
  #   1. Try smartctl with USB-SAT protocols (bypasses USB/SATA bridges)
  #   2. Fallback to hdparm (also bypasses bridges)
  #   3. Final fallback to lsblk (may show bridge info)

  local dev="$1"
  MODEL=""
  SERIAL=""

  # Try smartctl first - attempt multiple USB bridge protocols
  if command -v smartctl &>/dev/null; then
    # Try direct access first (works for native SATA)
    local smart_model=$(smartctl -i "$dev" 2>/dev/null | grep "Device Model:" | awk '{$1=$2=""; print $0}' | xargs)
    local smart_serial=$(smartctl -i "$dev" 2>/dev/null | grep "Serial Number:" | awk '{$1=$2=""; print $0}' | xargs)

    # Check if we got real drive info (not USB bridge/adapter)
    if [[ -n "$smart_model" ]] && [[ ! "$smart_model" =~ (Dual|USB|Bridge|Adapter) ]]; then
      MODEL=$(echo "$smart_model" | tr -s ' ' '_' | tr -cd '[:alnum:]_-' | cut -c1-64)
      SERIAL=$(echo "$smart_serial" | tr -s ' ' '_' | tr -cd '[:alnum:]_-' | cut -c1-64)
      return 0
    fi

    # Try USB-SAT protocols (for USB-attached drives)
    for protocol in "sat" "sat,12" "sat,16" "usbsunplus" "usbcypress" "usbjmicron"; do
      smart_model=$(smartctl -d "$protocol" -i "$dev" 2>/dev/null | grep "Device Model:" | awk '{$1=$2=""; print $0}' | xargs)
      smart_serial=$(smartctl -d "$protocol" -i "$dev" 2>/dev/null | grep "Serial Number:" | awk '{$1=$2=""; print $0}' | xargs)

      # Check if we got real drive info
      if [[ -n "$smart_model" ]] && [[ ! "$smart_model" =~ (Dual|USB|Bridge|Adapter) ]]; then
        MODEL=$(echo "$smart_model" | tr -s ' ' '_' | tr -cd '[:alnum:]_-' | cut -c1-64)
        SERIAL=$(echo "$smart_serial" | tr -s ' ' '_' | tr -cd '[:alnum:]_-' | cut -c1-64)
        return 0
      fi
    done
  fi

  # Fallback to hdparm
  if command -v hdparm &>/dev/null; then
    local hdparm_model=$(hdparm -I "$dev" 2>/dev/null | grep "Model Number:" | awk -F: '{print $2}' | xargs)
    local hdparm_serial=$(hdparm -I "$dev" 2>/dev/null | grep "Serial Number:" | awk -F: '{print $2}' | xargs)

    if [[ -n "$hdparm_model" ]]; then
      MODEL=$(echo "$hdparm_model" | tr -s ' ' '_' | tr -cd '[:alnum:]_-' | cut -c1-64)
      SERIAL=$(echo "$hdparm_serial" | tr -s ' ' '_' | tr -cd '[:alnum:]_-' | cut -c1-64)
      return 0
    fi
  fi

  # Final fallback to lsblk (may show USB bridge for USB-attached drives)
  MODEL=$(lsblk -no MODEL "$DEVICE" 2>/dev/null | tr -s ' ' '_' | tr -cd '[:alnum:]_-' | cut -c1-64)
  SERIAL=$(lsblk -no SERIAL "$DEVICE" 2>/dev/null | tr -s ' ' '_' | tr -cd '[:alnum:]_-' | cut -c1-64)
}

# ---------- Hash Computation ----------
echo "Reading device: $DEVICE"

# Get device size
DEV_SECTORS=$(blockdev --getsz "$DEVICE" 2>/dev/null || echo "2048")
DEV_SIZE_BYTES=$(blockdev --getsize64 "$DEVICE" 2>/dev/null || echo "0")
DEV_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$DEV_SIZE_BYTES" 2>/dev/null || echo "${DEV_SIZE_BYTES} bytes")

# Get hardware info
get_real_hardware_info "$DEVICE"

# Create signature file for v1 (content-only)
SIG_FILE_V1="/tmp/ntt-sig-v1-$$"
dd if="$DEVICE" bs=512 count=2048 conv=noerror,sync status=none 2>/dev/null > "$SIG_FILE_V1" || true

# Append last 1MB
SKIP_SECTORS=$((DEV_SECTORS - 2048))
if [[ $SKIP_SECTORS -lt 0 ]]; then
  SKIP_SECTORS=0
fi
dd if="$DEVICE" bs=512 skip=$SKIP_SECTORS count=2048 conv=noerror,sync status=none 2>/dev/null >> "$SIG_FILE_V1" || true

# Compute v1 hash (content-only)
HASH_V1=$(b3sum < "$SIG_FILE_V1" | cut -d' ' -f1 | cut -c1-32)
rm -f "$SIG_FILE_V1"

# Create signature file for v2 (hybrid with metadata)
SIG_FILE_V2="/tmp/ntt-sig-v2-$$"
HASH_METADATA="SIZE:${DEV_SIZE_BYTES}|MODEL:${MODEL:-unknown}|SERIAL:${SERIAL:-unknown}|"
echo -n "$HASH_METADATA" > "$SIG_FILE_V2"

# Append first 1MB
dd if="$DEVICE" bs=512 count=2048 conv=noerror,sync status=none 2>/dev/null >> "$SIG_FILE_V2" || true

# Append last 1MB
dd if="$DEVICE" bs=512 skip=$SKIP_SECTORS count=2048 conv=noerror,sync status=none 2>/dev/null >> "$SIG_FILE_V2" || true

# Compute v2 hash (hybrid)
HASH_V2=$(b3sum < "$SIG_FILE_V2" | cut -d' ' -f1 | cut -c1-32)
rm -f "$SIG_FILE_V2"

# ---------- v0 Legacy Hash (Oct 7-9 buggy format) ----------
# This reproduces the bug where oflag=append with conv=noerror,sync
# only wrote the first 1MB instead of first 1MB + last 1MB
# We need this to match media processed Oct 7-9, 2025
SIG_FILE_V0="/tmp/ntt-sig-v0-$$"
dd if="$DEVICE" of="$SIG_FILE_V0" bs=512 count=2048 conv=noerror,sync status=none 2>/dev/null || true
# Second dd with oflag=append+conv=noerror,sync fails to append, creating buggy 1MB-only file
dd if="$DEVICE" of="$SIG_FILE_V0" bs=512 skip=$SKIP_SECTORS count=2048 conv=noerror,sync oflag=append status=none 2>/dev/null || true

# Compute v0 hash (buggy legacy)
HASH_V0=$(b3sum < "$SIG_FILE_V0" | cut -d' ' -f1 | cut -c1-32)
rm -f "$SIG_FILE_V0"

# ---------- Partition Layout and Filesystems ----------
# Get partition table type
PTABLE_TYPE=$(blkid -s PTTYPE -o value "$DEVICE" 2>/dev/null || echo "none")

# Get partition info using lsblk with more fields for better detection
# Use -b for bytes to avoid confusion with size units
PARTITIONS_INFO=$(lsblk -J -b -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,TYPE "$DEVICE" 2>/dev/null | jq -c '.blockdevices[0].children // []')

# Also get blkid info for all partitions (more reliable for filesystem detection)
BLKID_OUTPUT=$(blkid "${DEVICE}"* 2>/dev/null || true)

# Build human-readable partition summary
PARTITION_SUMMARY=""
TOTAL_PART_SIZE=0
if [[ "$PARTITIONS_INFO" != "[]" ]]; then
  PARTITION_COUNT=$(echo "$PARTITIONS_INFO" | jq 'length')
  PARTITION_SUMMARY="$PARTITION_COUNT partition(s):"

  for i in $(seq 0 $((PARTITION_COUNT - 1))); do
    PART_NAME=$(echo "$PARTITIONS_INFO" | jq -r ".[$i].name")
    PART_SIZE_BYTES=$(echo "$PARTITIONS_INFO" | jq -r ".[$i].size")
    PART_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$PART_SIZE_BYTES" 2>/dev/null || echo "$PART_SIZE_BYTES bytes")
    PART_TYPE=$(echo "$PARTITIONS_INFO" | jq -r ".[$i].type // \"part\"")
    PART_FSTYPE=$(echo "$PARTITIONS_INFO" | jq -r ".[$i].fstype // \"unknown\"")
    PART_LABEL=$(echo "$PARTITIONS_INFO" | jq -r ".[$i].label // \"\"")
    PART_PARTLABEL=$(echo "$PARTITIONS_INFO" | jq -r ".[$i].partlabel // \"\"")

    # Track total partition size for sanity check
    TOTAL_PART_SIZE=$((TOTAL_PART_SIZE + PART_SIZE_BYTES))

    # If lsblk doesn't show filesystem, try to get it from blkid
    if [[ "$PART_FSTYPE" == "unknown" ]] || [[ "$PART_FSTYPE" == "null" ]]; then
      PART_FSTYPE=$(echo "$BLKID_OUTPUT" | grep "/dev/$PART_NAME:" | grep -oP 'TYPE="\K[^"]+' || echo "unknown")
    fi

    # Use label if available, otherwise partlabel
    LABEL_STR=""
    if [[ -n "$PART_LABEL" ]]; then
      LABEL_STR=" [$PART_LABEL]"
    elif [[ -n "$PART_PARTLABEL" ]]; then
      LABEL_STR=" [$PART_PARTLABEL]"
    fi

    PARTITION_SUMMARY="${PARTITION_SUMMARY}
  $PART_NAME: $PART_SIZE_HUMAN, $PART_FSTYPE$LABEL_STR"
  done

  # Sanity check: warn if partitions are much smaller than disk
  # Allow for some overhead (MBR, gaps, etc) - warn if <50% utilized
  if [[ $DEV_SIZE_BYTES -gt 0 ]] && [[ $TOTAL_PART_SIZE -lt $((DEV_SIZE_BYTES / 2)) ]]; then
    PART_PERCENT=$((TOTAL_PART_SIZE * 100 / DEV_SIZE_BYTES))
    PARTITION_SUMMARY="${PARTITION_SUMMARY}
  WARNING: Partitions only use ${PART_PERCENT}% of disk ($(numfmt --to=iec-i --suffix=B $TOTAL_PART_SIZE) / $DEV_SIZE_HUMAN)
  This may indicate a corrupted or obsolete partition table."
  fi
else
  PARTITION_SUMMARY="No partitions detected (may be unpartitioned or have non-standard layout)"
fi

# ---------- Log to JSON ----------
jq -cn \
  --arg ts "$(date -Iseconds)" \
  --arg device "$DEVICE" \
  --arg hash_v0 "$HASH_V0" \
  --arg hash_v1 "$HASH_V1" \
  --arg hash_v2 "$HASH_V2" \
  --arg size "$DEV_SIZE_BYTES" \
  --arg model "${MODEL:-unknown}" \
  --arg serial "${SERIAL:-unknown}" \
  --arg ptable "$PTABLE_TYPE" \
  --argjson partitions "$PARTITIONS_INFO" \
  '{
    timestamp: $ts,
    device: $device,
    hash_v0_legacy_buggy: $hash_v0,
    hash_v1_content_correct: $hash_v1,
    hash_v2_hybrid: $hash_v2,
    size_bytes: ($size | tonumber),
    model: $model,
    serial: $serial,
    partition_table: $ptable,
    partitions: $partitions
  }' >> "$LOG_JSON"

chmod 644 "$LOG_JSON" 2>/dev/null || true

# ---------- Database Lookup ----------
# Check if v0 or v2 hash matches any existing medium records
DB_MATCH_V0=""
DB_MATCH_V2=""

if command -v psql &>/dev/null; then
  # Query for v0 hash match
  DB_MATCH_V0=$(sudo -u postgres psql -d copyjob -tAc "
    SELECT medium_hash, medium_human, health, problems
    FROM medium
    WHERE medium_hash = '$HASH_V0';
  " 2>/dev/null || true)

  # Query for v2 hash match
  DB_MATCH_V2=$(sudo -u postgres psql -d copyjob -tAc "
    SELECT medium_hash, medium_human, health, problems
    FROM medium
    WHERE medium_hash = '$HASH_V2';
  " 2>/dev/null || true)
fi

# ---------- Print Human-Readable Output ----------
echo ""
echo "======================================"
echo "Drive Identification Results"
echo "======================================"
echo "Device:      $DEVICE"
echo "Size:        $DEV_SIZE_BYTES bytes ($DEV_SIZE_HUMAN)"
echo "Model:       ${MODEL:-unknown}"
echo "Serial:      ${SERIAL:-unknown}"
echo ""
echo "Partition Table: $PTABLE_TYPE"
echo "$PARTITION_SUMMARY"
echo ""
echo "Hash (v0/legacy buggy Oct 7-9):   $HASH_V0"
echo "Hash (v1/content-only correct):   $HASH_V1"
echo "Hash (v2/hybrid Oct 10+):         $HASH_V2"
echo ""

# Display database match results
if [[ -n "$DB_MATCH_V0" ]]; then
  IFS='|' read -r db_hash db_human db_health db_problems <<< "$DB_MATCH_V0"
  echo "Database: MATCH v0 (${HASH_V0:0:6})"
  echo ""
elif [[ -n "$DB_MATCH_V2" ]]; then
  IFS='|' read -r db_hash db_human db_health db_problems <<< "$DB_MATCH_V2"
  echo "Database: MATCH v2 (${HASH_V2:0:6})"
  echo ""
else
  echo "Database: No match found"
  echo ""
fi

echo "Logged to: $LOG_JSON"
echo "======================================"
