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
2. **Run identification script** (auto-detects from dmesg):
   ```bash
   sudo bin/identify-drive-by-hash.sh
   ```
   - Script detects recently connected drive from dmesg
   - Shows dmesg output and detected device
   - Prompts: "Identify this device? (Y/n)"
   - Or specify device manually: `sudo bin/identify-drive-by-hash.sh /dev/sdX`

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

## Database Status - CRITICAL DATA LOSS RISK

**URGENCY**: This is the most critical orphaned media case - complete data loss without physical disk recovery.

**Current state (as of 2025-10-18):**
```sql
medium_hash: 3033499e89e2efe1f2057c571aeb793a
medium_human: orphaned_3033499e
enum_done: NULL
copy_done: NULL

-- Database records: ZERO
SELECT COUNT(*) FROM inode WHERE medium_hash = '3033499e...';  -- 0 rows
SELECT COUNT(*) FROM path WHERE medium_hash = '3033499e...';   -- 0 rows
SELECT COUNT(*) FROM old_enum_3033499e;                        -- 0 rows (table exists but empty)
```

**What we have:**
- Raw enumeration file: `/data/fast/raw/3033499e89e2efe1f2057c571aeb793a.raw` (830 MB, 5,040,408 files)
- Medium record with orphaned status
- Metadata: "xt's MacBook Pro" Time Machine backup from 2013-02-07

**What we DON'T have:**
- ❌ IMG file (deleted before loading phase)
- ❌ Database records (raw file was NEVER loaded into inode/path tables)
- ❌ Any blobids
- ❌ Any actual file data

**Result**: Without finding and re-imaging the physical disk, 5+ million files are permanently lost.

## Search Status (2025-10-19)

**CRITICAL DISCOVERY**: Hash `3033499e` is a PARTITION hash, not a whole-drive hash!

**Evidence**:
- Manual mount point `/mnt/tmp3` (not standard `/mnt/ntt/[hash]` pattern)
- Enumerated Oct 2, 2025 from manually mounted partition
- All whole-drive scans found no match because we hashed drives, not partitions

**Scanned drives:** 21 total (18 SATA via USB + 3 IDE/ATAPI)
- None matched when hashing WHOLE DRIVES
- But `3033499e` is a PARTITION hash - need to check partitions in IMG files

**Candidate drives with HFS+ partitions (250-500GB range) - IMG files available:**

1. **ST3300631AS** (Serial: 5NF1EW1Q) - 279GB
   - medium_hash: `94e154e3b3095a3b2b9cea9cf3c15bed`
   - Partition: HFS+ 279GB labeled "bigpig"
   - IMG: `/data/fast/img/94e154e3b3095a3b2b9cea9cf3c15bed.img`

2. **ST3400633AS** (Serial: 3NF1QT4B) - 372GB
   - medium_hash: `5cb0dafa977e17bf7e5f8f54a32690cd`
   - Partition: HFS+ 372GB labeled "Untitled 1"
   - IMG: `/data/fast/img/5cb0dafa977e17bf7e5f8f54a32690cd.img`

3. **Maxtor 6H400F0** (Serial: H80R4WPH) - 372GB
   - medium_hash: `b5bc63f6e7ed181f3ca876fefb69cf69`
   - Partition: HFS+ 372GB labeled "Untitled 1"
   - IMG: `/data/fast/img/b5bc63f6e7ed181f3ca876fefb69cf69.img`

**Other drives checked (no IMG available):**

4. **Hitachi HTS545050B9A300** (Serial: 090713PB4400Q7HB7ASG) - 465GB
   - v2 hash: `d6c63baf2ab797fbb7cc8a744d01e861`
   - Partition: HFS+ 465GB labeled "Time Machine Backups"
   - Status: Unreadable/damaged - not processed

5. **Hitachi HTS545050B9A300** (Serial: 090713PB4400Q7HB2E2G) - 465GB
   - v0 hash: `488de202f73bd976de4e7048f4e1f39a`
   - No HFS+ partition - not a candidate

**Next step:** Mount IMG files as loopback devices and hash partitions to find which contains 3033499e partition

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

- **CRITICAL**: Data is completely inaccessible without physical disk - no database records exist
- **Hash format**: 3033499e uses v1 (content-only) from Oct 2, 2025 enumeration
- **Enumeration format**: Old raw file format uses permissions (775, 644) instead of filetype (d, f, l)
- **Processing gap**: Raw file created Oct 2, but IMG was deleted before loading phase, so data never reached database
- **Re-enumeration**: Will happen automatically when orchestrator processes the re-imaged disk
- **Time Machine backup characteristics**:
  - Many hardlinks (Time Machine hardlinks unchanged files across snapshots)
  - Possible multiple backup snapshots if disk wasn't dedicated to single backup
  - Standard Mac applications and user data structure
- **Drive identification log**: All candidate drive scans logged to `/var/log/ntt/drive-identification.jsonl`
- **Search priority**: HIGH - only 3 IDE drives remain as candidates, must check them

## References

- Investigation session: `docs/sessions/orphaned-raw-investigation-2025-10-18.md`
- Raw file preserved at: `/data/fast/raw/3033499e89e2efe1f2057c571aeb793a.raw`
- Hash format documentation: `docs/hash-format.md`
- Identification script: `bin/identify-drive-by-hash.sh`
- Identification log: `/var/log/ntt/drive-identification.jsonl`
