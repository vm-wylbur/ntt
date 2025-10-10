# NTT Medium Hash Format

## Overview

NTT uses BLAKE3 hashing to generate unique identifiers (`medium_hash`) for physical media (disks, USB drives, optical media). This document describes the hash format and why it includes hardware metadata.

## Current Hash Format (v2 - 2025-10-09)

**Input to hash function:**
```
BLAKE3(metadata_string + first_1MB_content + last_1MB_content)
```

**Metadata string format:**
```
SIZE:${device_bytes}|MODEL:${model}|SERIAL:${serial}|
```

**Example:**
```
SIZE:300069052416|MODEL:A1|SERIAL:20250315|
```

This metadata string is prepended to the device content signature (first 1MB + last 1MB) before hashing.

## Why Metadata is Included

### The Problem

On 2025-10-09, we discovered two different physical devices generated the same hash:
- Device 1: 466GB FAT USB drive
- Device 2: 280GB ext3+LVM USB drive
- **Both generated hash:** `488de202f73bd976de4e7048f4e1f39a`

**Root cause:** The original hash only used `BLAKE3(first_1MB + last_1MB)`, which collided when devices had similar boot sectors and padding patterns.

### The Solution

We adopted a **hybrid approach** (Option 4 from design discussion):
- Include **SIZE** - exact device byte count from `blockdev --getsize64`
- Include **MODEL** - hardware model identifier
- Include **SERIAL** - hardware serial number

This ensures different physical devices always generate different hashes, even if their content signatures are similar.

## Hardware Detection Strategy

The implementation tries multiple methods to get real hardware info (bypassing USB bridges):

1. **smartctl direct** - Works for native SATA/ATA drives
2. **smartctl with USB-SAT protocols** - Penetrates USB-to-SATA bridges
   - Protocols tried: `sat`, `sat,12`, `sat,16`, `usbsunplus`, `usbcypress`, `usbjmicron`
3. **hdparm** - Alternative hardware query tool
4. **lsblk** - Final fallback (may show USB bridge info for USB-attached drives)

When hardware detection fails, the hash uses `MODEL:unknown|SERIAL:unknown|` but still includes the SIZE, which prevents collisions for devices of different capacities.

## Implementation Details

### Code Location
- `ntt-orchestrator`: `get_real_hardware_info()` function (lines 99-160)
- `ntt-orchestrator`: `identify_device()` function (lines 305-335)

### Signature File Construction
```bash
# 1. Write metadata header
echo -n "SIZE:${bytes}|MODEL:${model}|SERIAL:${serial}|" > /tmp/sig-file

# 2. Append first 1MB (2048 sectors of 512 bytes)
dd if=/dev/sdX bs=512 count=2048 conv=noerror,sync >> /tmp/sig-file

# 3. Append last 1MB (skip to end - 1MB)
skip_sectors=$((total_sectors - 2048))
dd if=/dev/sdX bs=512 skip=$skip_sectors count=2048 conv=noerror,sync >> /tmp/sig-file

# 4. Generate hash (truncated to 32 hex chars = 128 bits)
medium_hash=$(b3sum < /tmp/sig-file | cut -d' ' -f1 | cut -c1-32)
```

**Note:** Shell redirection (`>>`) is used instead of `dd oflag=append` because the latter doesn't work correctly with `conv=noerror,sync`.

## Hash Properties

- **Length**: 32 hexadecimal characters (128 bits of BLAKE3 hash)
- **Collision resistance**: Extremely high due to BLAKE3 + metadata
- **Reproducibility**: Same physical device always generates same hash (deterministic)
- **Uniqueness**: Different devices generate different hashes (even with similar content)

## Migration Notes

### Old vs New Hashes

- **Old format (v1):** `BLAKE3(first_1MB + last_1MB)` - content-only
- **New format (v2):** `BLAKE3(SIZE|MODEL|SERIAL| + first_1MB + last_1MB)` - hybrid

### Backward Compatibility

- Existing media in the database retain their old hashes (no migration needed)
- New media ingested after 2025-10-09 use the new format
- Hash collision was rare, so old hashes are generally still valid
- If a collision is discovered in old data, re-imaging the device will generate a new unique hash

### Forensic Analysis

The metadata string is also stored in the `medium.diagnostics` field for forensic analysis:
```
=== HASH METADATA ===
SIZE:300069052416|MODEL:A1|SERIAL:20250315|
```

This allows post-hoc verification of which metadata was used to generate each hash.

## Related Files

- `ntt-orchestrator` - Main implementation
- `docs/workplan-2025-10-08.md` - Original design discussion
- `/var/log/ntt/orchestrator.jsonl` - Logs showing hash metadata for each device

## See Also

- BLAKE3 specification: https://github.com/BLAKE3-team/BLAKE3-specs/blob/master/blake3.pdf
- `blockdev(8)` - Get device size
- `smartctl(8)` - Query disk hardware info
- `hdparm(8)` - Get/set SATA/IDE device parameters
