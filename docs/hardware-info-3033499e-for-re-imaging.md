<!--
Author: PB and Claude (prox-claude)
Date: Fri 18 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/hardware-info-3033499e-for-re-imaging.md
-->

# Hardware Info for 3033499e - Needs Re-Imaging

**Medium Hash**: `3033499e89e2efe1f2057c571aeb793a`

## Physical Disk Characteristics

### Content Identification
- **Label**: "xt's MacBook Pro" Time Machine Backup
- **Backup Date**: 2013-02-07-115910 (February 7, 2013 at 11:59:10)
- **Filesystem**: HFS+ (Mac OS Extended)
- **Mount Point** (during original enumeration): `/mnt/tmp3`

### Data Statistics
- **Total Files**: 5,040,408 (from raw file count)
- **Total Data Size**: ~283 GB (303,492,014,251 bytes)
- **Highest Inode**: 1,548,291,243
- **File Date Range**:
  - Oldest: 1969-12-31 (likely epoch/metadata files)
  - Newest: 2019-01-23

### Enumeration Metadata
- **Enumerated**: October 2, 2025 at 14:16
- **Raw File Size**: 830 MB (870,247,855 bytes)
- **Old Hash Format**: permissions-based (775, 644) instead of filetype (d, f, l)

## Time Machine Backup Structure

Sample paths from enumeration:
```
/mnt/tmp3/Backups.backupdb/xt's MacBook Pro/2013-02-07-115910/Macintosh HD/Applications/Calendar.app
/mnt/tmp3/Backups.backupdb/xt's MacBook Pro/2013-02-07-115910/Macintosh HD/Applications/FaceTime.app
/mnt/tmp3/Backups.backupdb/xt's MacBook Pro/2013-02-07-115910/Macintosh HD/Applications/Image Capture.app
/mnt/tmp3/Backups.backupdb/xt's MacBook Pro/2013-02-07-115910/Macintosh HD/Applications/MailMate.app
/mnt/tmp3/Backups.backupdb/xt's MacBook Pro/2013-02-07-115910/Macintosh HD/Applications/Notes.app
/mnt/tmp3/Backups.backupdb/xt's MacBook Pro/2013-02-07-115910/Macintosh HD/Applications/Reggy.app
/mnt/tmp3/Backups.backupdb/xt's MacBook Pro/2013-02-07-115910/Macintosh HD/Applications/Sublime Text 2.app
```

## Disk Identification Workflow

### How to Find the Physical Disk

**3033499e was enumerated on Oct 2, 2025** → uses **v1 hash format** (content-only, pre-Oct 10)

**Identification procedure:**

1. **Connect candidate drive** in external USB housing
2. **Run identification script**:
   ```bash
   sudo bin/identify-drive-by-hash.sh /dev/sdX
   ```
3. **Watch for v1 hash match**: `3033499e89e2efe1f2057c571aeb793a`
4. **Expected characteristics** (for reference):
   - **Size**: ~300GB (283GB of data)
   - **Content**: HFS+ filesystem with `Backups.backupdb/xt's MacBook Pro/2013-02-07-115910/`
   - **Era**: Disk from ~2013 or earlier

### What the Script Does

- Computes **both** hash formats:
  - **v1 (content-only)**: BLAKE3(first_1MB + last_1MB) — matches 3033499e
  - **v2 (hybrid)**: BLAKE3(SIZE:|MODEL:|SERIAL:| + first_1MB + last_1MB) — new format
- Extracts hardware: SIZE, MODEL, SERIAL
- Analyzes partitions: table type (GPT/MBR/none), filesystems, labels
- **Logs to `/var/log/ntt/drive-identification.jsonl`** (builds drive database with all metadata)
- **Prints to stdout** (human-readable)

For 3033499e, expect:
- Partition table: GPT or MBR
- Filesystem: **hfsplus** (HFS+ / Mac OS Extended)
- Possible label: "Time Machine" or similar

### When Match Found

All drive scans are logged to `/var/log/ntt/drive-identification.jsonl` for future reference.

## Database Status

```sql
medium_hash: 3033499e89e2efe1f2057c571aeb793a
medium_human: orphaned_3033499e
health: incomplete
problems: {
  "need_re_imaging": true,
  "reason": "IMG file deleted before loading - need to locate physical disk for re-imaging",
  "enumerated_files": 5040408,
  "old_raw_file": "/data/fast/raw/3033499e89e2efe1f2057c571aeb793a.raw",
  "content": "xt MacBook Pro Time Machine 2013-02-07",
  "old_mount_point": "/mnt/tmp3"
}
```

## Re-Imaging Procedure (when disk is found)

1. **Verify v1 hash matches**: `3033499e89e2efe1f2057c571aeb793a`

2. **Image with ntt-imager**:
   ```bash
   sudo bin/ntt-imager /dev/sdX \
     /data/fast/img/3033499e89e2efe1f2057c571aeb793a.img \
     /data/fast/img/3033499e89e2efe1f2057c571aeb793a.map
   ```
   - **Critical**: Name IMG file with the **old hash** (3033499e...)
   - This ensures orchestrator recognizes existing raw file and database records
   - ntt-imager runs 7-phase progressive ddrescue (see `bin/ntt-imager` for details)

3. **Process with orchestrator**:
   ```bash
   sudo bin/ntt-orchestrator --image /data/fast/img/3033499e89e2efe1f2057c571aeb793a.img
   ```
   - Orchestrator detects hash in filename (line 398-408)
   - Uses existing hash instead of recomputing (preserves link to raw file)
   - Runs full pipeline: mount → enum → load → copy → archive

4. **Verify completion**:
   ```sql
   SELECT medium_hash, enum_done, copy_done, health, problems
   FROM medium
   WHERE medium_hash = '3033499e89e2efe1f2057c571aeb793a';
   ```
   - Should show `enum_done` and `copy_done` timestamps
   - Check `health` status (ok/incomplete/corrupt/failed)
   - Verify `problems` is NULL or acceptable

5. **Update medium record**:
   ```sql
   -- Remove orphan status and update message
   UPDATE medium
   SET
     medium_human = '<MODEL>_<SERIAL>',  -- Update with real hardware info
     health = 'ok',  -- or actual health from imaging
     problems = NULL,
     message = 'Re-imaged 2025-10-18: xt MacBook Pro Time Machine 2013-02-07'
   WHERE medium_hash = '3033499e89e2efe1f2057c571aeb793a';
   ```

## Notes

- **Hash format**: 3033499e uses v1 (content-only) from Oct 2, 2025 enumeration
- **Enumeration format**: Old raw file format uses permissions (775, 644) instead of filetype (d, f, l)
- **Re-enumeration**: Will happen automatically when orchestrator processes the re-imaged disk
- **Time Machine backup characteristics**:
  - Many hardlinks (Time Machine hardlinks unchanged files across snapshots)
  - Possible multiple backup snapshots if disk wasn't dedicated to single backup
  - Standard Mac applications and user data structure
- **Drive identification log**: All candidate drive scans logged to `/var/log/ntt/drive-identification.jsonl`

## References

- Investigation session: `docs/sessions/orphaned-raw-investigation-2025-10-18.md`
- Raw file preserved at: `/data/fast/raw/3033499e89e2efe1f2057c571aeb793a.raw`
- Hash format documentation: `docs/hash-format.md`
- Identification script: `bin/identify-drive-by-hash.sh`
- Identification log: `/var/log/ntt/drive-identification.jsonl`
