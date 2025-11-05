# TODO: Multi-Partition Image Identification

**Status:** Pending (waiting for archive-staging-dirs.sh to complete)
**Date:** 2025-10-10
**Author:** PB and Claude

## Context

The NTT system has archives in `/data/cold/img-read/*.tar.zst` that may contain disk image files (`.img`) with multiple partitions. Previously, we only processed single-partition images. We need to:

1. Identify which `.img` files have 2+ partitions
2. Extract those multi-partition images for reprocessing
3. Delete single-partition images (already processed correctly)

## Background

Recent changes to `ntt-orchestrator` and `ntt-mount-helper` now support multi-partition disk images:
- `ntt-mount-helper` detects partition layouts and mounts each partition separately
- `stage_enum()` merges enumeration from all partitions into a single `.raw` file
- Paths are prefixed with partition info for tracking

However, older `.img` files in archives may not have been processed with this logic and need to be rerun.

## Preconditions

**MUST WAIT FOR:**
1. `/data/staging/archive-staging-dirs.sh` to complete (archiving 4 subdirectories)
2. `/data/staging` subdirectories to be cleared (after archives verified)
3. Sufficient free space in `/data/staging` (check `df -h`)

**SKIP ARCHIVES:**
- The 4 staging directory archives (not disk images):
  - `2ae4eb92379b9892ba93693e49f42e08.tar.zst` (archives-2019)
  - `1d7c9dc81a26c871ccafc71ab284b4aa.tar.zst` (dump-2019)
  - `983dbb7dfb2a6ea867e233653a64f9d6.tar.zst` (osxgather)
  - `236d5e0d89eb0e5e78edadf040a7a934.tar.zst` (unknown-tree)

## Process Overview

### Phase 1: Identification (Automated Script)

Script: `/data/staging/check-multipart-imgs.sh`

**Selection Criteria:**
- Only check `.tar.zst` archives > 1GB (optimization)
- Skip the 4 staging directory archives listed above
- Process smallest archives first (faster iteration/testing)

**For Each Archive:**
1. Check disk space (`df -h /data/staging`) - abort if < 20% free
2. Extract to `/data/staging/tmp/${hash}/`
3. Find all `.img` files > 1GB in extracted content
4. For each large `.img`:
   - Mount as loop device (read-only)
   - Check partition count via `fdisk -l` or `parted`
   - **Decision:**
     - 1 partition → Delete `.img` file (already correctly processed)
     - 2+ partitions → **KEEP** `.img` file for reprocessing
5. Clean up all non-`.img` files from temp directory
6. If no multi-partition images remain, remove temp directory
7. Log all actions to `/var/log/ntt/multipart-check.jsonl`

**Safety Features:**
- Process one archive at a time (avoid disk space issues)
- Monitor disk space before each extraction
- Immediate cleanup of single-partition images
- Detach loop devices after checking
- Extensive logging for audit trail

**Expected Output:**
- `/data/staging/tmp/${hash}/*.img` - Only multi-partition images (2+)
- `/var/log/ntt/multipart-check.jsonl` - Complete log
- Summary report at script completion

### Phase 2: Reprocessing (Manual)

Once multi-partition images are identified and extracted:

**For each multi-partition `.img` file:**
```bash
sudo ntt-orchestrator --image /data/staging/tmp/${hash}/${filename}.img
```

This will:
- Re-identify the image (hash from filename if 32 hex chars)
- Mount with partition detection via `ntt-mount-helper`
- Enumerate each partition separately
- Merge partition enumerations into single `.raw` file
- Load into database with partition-prefixed paths
- Copy files with deduplication
- Archive the processed image

**Note on Hash Preservation:**
- If `.img` filename is 32 hex chars (e.g., `af1349b9f5f9a1a6a0404dea36dcc949.img`), it's treated as the original `medium_hash`
- The `identify_image()` function will look up existing medium metadata from database
- This preserves the original device identification and hardware diagnostics

## Script Specification

### Input Parameters
- None (all config hardcoded for safety)

### Output Files
- `/data/staging/tmp/${hash}/*.img` - Multi-partition images only
- `/var/log/ntt/multipart-check.jsonl` - JSONL log format

### Log Format
```json
{"ts": "2025-10-10T14:00:00Z", "stage": "script_start", "total_archives": 38}
{"ts": "...", "stage": "archive_start", "hash": "...", "size_gb": 123, "rank": 1}
{"ts": "...", "stage": "extraction_start", "hash": "...", "dest": "/data/staging/tmp/..."}
{"ts": "...", "stage": "img_found", "hash": "...", "img": "foo.img", "size_gb": 45}
{"ts": "...", "stage": "partition_check", "hash": "...", "img": "foo.img", "partitions": 1, "action": "deleted"}
{"ts": "...", "stage": "partition_check", "hash": "...", "img": "bar.img", "partitions": 3, "action": "KEPT", "path": "/data/staging/tmp/.../bar.img"}
{"ts": "...", "stage": "cleanup", "hash": "...", "removed_files": 123, "kept_imgs": 1}
{"ts": "...", "stage": "archive_complete", "hash": "...", "multipart_imgs": 1, "disk_free_pct": 45}
{"ts": "...", "stage": "script_complete", "total_multipart": 5, "archives_checked": 15}
```

### Exit Codes
- 0 = Success (script completed, multi-partition images identified)
- 1 = Error (disk space, extraction failure, etc.)

## Disk Space Management

**Critical:** `/data/staging` can easily fill up.

**Mitigation:**
- Check `df -h /data/staging` before each extraction
- Abort if < 20% free space
- Delete single-partition images immediately after checking
- Remove all non-.img files after checking each archive
- Process archives sequentially (not in parallel)

**Manual Monitoring:**
```bash
watch -n 5 'df -h /data/staging'
```

## Testing Strategy

1. **Dry Run:** Test on smallest archive first (verify logic works)
2. **Verify Partition Detection:** Manually check first multi-partition image found
3. **Space Monitoring:** Watch disk usage throughout
4. **Log Review:** Check JSON log for any errors/warnings

## Expected Timeline

- **Phase 1 (Identification):** 1-3 hours (depends on archive sizes)
- **Phase 2 (Reprocessing):** Variable (depends on number of multi-partition images found)

## Known Edge Cases

1. **Archive contains multiple .img files:**
   - Unlikely (each archive should be one medium)
   - Script will check all `.img` files > 1GB
   - Log WARNING if multiple found

2. **Unreadable/corrupt .img:**
   - Loop device creation will fail
   - Log error and skip
   - Leave file for manual inspection

3. **Partition detection fails:**
   - `fdisk -l` may not work on some filesystems
   - Fallback to `parted print`
   - Log error if both fail

## Next Steps After Completion

1. Review `/var/log/ntt/multipart-check.jsonl` for summary
2. List all kept images: `find /data/staging/tmp/ -name "*.img"`
3. For each multi-partition image:
   - Run through `ntt-orchestrator --image`
   - Verify partition enumeration works
   - Check database for partition-prefixed paths
4. After successful reprocessing, remove temp images
5. Update this TODO with completion status

## Questions/Decisions

- [x] Database filtering approach: Try mounting each archive (skip DB queries)
- [x] Processing order: Smallest archives first
- [x] Output location: `/data/staging/tmp/`
- [x] Partition threshold: Keep images with 2+ partitions only
- [x] Map files: Don't extract (only need .img files)

## Related Files

- `/data/staging/check-multipart-imgs.sh` - Implementation script
- `/home/pball/projects/ntt/bin/ntt-orchestrator` - Reprocessing tool
- `/home/pball/projects/ntt/bin/ntt-mount-helper` - Partition detection
- `/home/pball/projects/ntt/docs/hash-format.md` - Hash collision fix
- `/var/log/ntt/multipart-check.jsonl` - Execution log

## References

- Original discussion: 2025-10-10 planning session
- Hash collision fix: 2025-10-09 (Option 4 - Hybrid Approach)
- Multi-partition support: Recent `ntt-orchestrator` changes
