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

# Validate arguments
if [[ $# -ne 1 ]]; then
  cat <<EOF
Usage: sudo $0 <device>

Identifies a disk drive by computing both hash formats and extracting hardware info.
Results are logged to $LOG_JSON and printed to stdout.

Example:
  sudo $0 /dev/sdb

Output shows:
  - Hardware: SIZE, MODEL, SERIAL
  - Partition table type (GPT, MBR, none)
  - Partitions with filesystems and labels
  - Hash (v1/content-only) - for pre-Oct 10 media
  - Hash (v2/hybrid) - for Oct 10+ media

Look for v1 hash matching orphaned media (e.g., 3033499e89e2efe1f2057c571aeb793a).
EOF
  exit 1
fi

DEVICE="$1"

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

# ---------- Partition Layout and Filesystems ----------
# Get partition table type
PTABLE_TYPE=$(blkid -s PTTYPE -o value "$DEVICE" 2>/dev/null || echo "none")

# Get partition info using lsblk (NAME, SIZE, FSTYPE, LABEL)
# Filter to only partitions of this device, not the device itself
PARTITIONS_INFO=$(lsblk -J -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$DEVICE" 2>/dev/null | jq -c '.blockdevices[0].children // []')

# Build human-readable partition summary
PARTITION_SUMMARY=""
if [[ "$PARTITIONS_INFO" != "[]" ]]; then
  PARTITION_COUNT=$(echo "$PARTITIONS_INFO" | jq 'length')
  PARTITION_SUMMARY="$PARTITION_COUNT partition(s):"

  for i in $(seq 0 $((PARTITION_COUNT - 1))); do
    PART_NAME=$(echo "$PARTITIONS_INFO" | jq -r ".[$i].name")
    PART_SIZE=$(echo "$PARTITIONS_INFO" | jq -r ".[$i].size")
    PART_FSTYPE=$(echo "$PARTITIONS_INFO" | jq -r ".[$i].fstype // \"unknown\"")
    PART_LABEL=$(echo "$PARTITIONS_INFO" | jq -r ".[$i].label // \"\"")
    PART_PARTLABEL=$(echo "$PARTITIONS_INFO" | jq -r ".[$i].partlabel // \"\"")

    # Use label if available, otherwise partlabel
    LABEL_STR=""
    if [[ -n "$PART_LABEL" ]]; then
      LABEL_STR=" [$PART_LABEL]"
    elif [[ -n "$PART_PARTLABEL" ]]; then
      LABEL_STR=" [$PART_PARTLABEL]"
    fi

    PARTITION_SUMMARY="${PARTITION_SUMMARY}
  $PART_NAME: $PART_SIZE, $PART_FSTYPE$LABEL_STR"
  done
else
  PARTITION_SUMMARY="No partitions (unpartitioned disk)"
fi

# ---------- Log to JSON ----------
jq -cn \
  --arg ts "$(date -Iseconds)" \
  --arg device "$DEVICE" \
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
    hash_v1: $hash_v1,
    hash_v2: $hash_v2,
    size_bytes: ($size | tonumber),
    model: $model,
    serial: $serial,
    partition_table: $ptable,
    partitions: $partitions
  }' >> "$LOG_JSON"

chmod 644 "$LOG_JSON" 2>/dev/null || true

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
echo "Hash (v1/content-only): $HASH_V1"
echo "Hash (v2/hybrid):       $HASH_V2"
echo ""
echo "Logged to: $LOG_JSON"
echo "======================================"
