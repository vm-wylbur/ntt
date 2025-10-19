<!--
Author: PB and Claude (prox-claude)
Date: Fri 18 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/sessions/bug-016-remediation-session-2025-10-18.md
-->

# BUG-016 Remediation Session - 2025-10-18

## Summary

Large-scale cleanup of media with missing `enum_done` and `copy_done` timestamps due to BUG-016 (orchestrator not setting timestamps before Oct 14 fix). Also discovered orphaned raw enumeration files with no corresponding database records.

## What We Did

### Phase 1: Individual Media Remediation (15 media)

**Pattern**: Media processed before BUG-016 fix (Oct 8-17) had NULL timestamps despite complete processing and archiving.

**Fixed manually**:
1. **eba88f0c** (vfat floppy, 1.5MB) - 35 files, archived Oct 8
2. **6d89ac9f** (black Maxell floppy) - 1 file, archived Oct 8
3. **647bf9a8** (floppy) - 1 file, archived Oct 17
4. **caec1f63** (floppy, 5200 files) - archived Oct 10
5. **3b894fd7** (floppy, 1104 files, incomplete health) - archived Oct 10
6. **1d7c9dc8** (474K files, 169GB archive) - archived Oct 10
7. **536a933b** (ST3000DM001, 292K files, 26GB archive) - archived Oct 11
8. **5cb0dafa** (ST3400633AS, 1.67M files, 112GB archive) - archived Oct 11
9. **60f3f319** (ST3400633AS, 783K files, 233GB archive) - archived Oct 10
10. **beb2a986** (Time Machine, 2.63M files) - IMG not archived
11. **c2676ab2** (1.79M files) - IMG not archived
12. **cd3b7aec** (1 file) - IMG not archived
13. **cff53715** (Time Machine, 3.45M files) - IMG not archived
14. **5b64bb9c** (ST3300831A truncated) - archived Oct 18
15. **d9549175** (Time Machine, 3.45M files, 99.9998% success) - IMG not archived, 4 HFS+ orphan files pending

**Method**:
- Used archive modification time as `copy_done`
- Subtracted 10 minutes for `enum_done` estimate
- Added notes for IMG files not archived (deleted before archiving standardized)
- Removed corresponding `.raw` enumeration files

### Phase 2: Batch Cleanup Script

Created `bin/cleanup-completed-raw-files.sh` to automate raw file cleanup for completed media.

**Results**:
- 69 raw files removed in batch
- 13GiB freed
- 30 already missing (from manual cleanup)

### Phase 3: Additional Missing Timestamps (8 media)

**Pattern**: Media with `copy_done` set but missing `enum_done` (same BUG-016 cause).

**Fixed via timestamp backfill**:
1. **236d5e0d** (10.4M files) - enum Sep 27, copy Oct 10
2. **2ae4eb92** (629K files) - enum Sep 27, copy Oct 10
3. **2c8cc675** (Kosovo archive, 4195 files) - enum Oct 10, copy Oct 10
4. **7359b739** (floppy) - enum Oct 8, copy Oct 10
5. **983dbb7d** (8GB raw file!) - enum Sep 27, copy Oct 10
6. **bb226d2a** (sdc1-snowball-raid, 2GB raw file!) - enum Oct 7, copy Oct 10
7. **bb98aeca** (ZIP_250, incomplete) - enum Oct 11, copy Oct 13
8. **c84c8780** (floppy) - enum Oct 10, copy Oct 10

**Additional fixes**:
- **b0e5017a** (Project files 1997-2001, 1516 files, incomplete) - enum Oct 10, copy Oct 10
- **f43ecd69** (Docs 1996-2000, 3105 files, incomplete) - enum Oct 14, copy Oct 13

**Total raw files removed in this phase**: 13 files (~11GB including 8GB and 2GB monsters)

## Results

### Before
- 99 completed media (with timestamps)
- 101 raw enumeration files (13GB+)
- 26 media with NULL timestamps

### After
- **109 completed media** (with timestamps)
- **11 raw enumeration files** (legitimate incomplete work)
- **23 media remediated** (15 manual + 8 backfill)
- **77 raw files removed** (~24GB freed)

### Remaining Raw Files (11)

**LVM1 volumes (2)** - Need special VM recovery per `docs/todo-lvm1-recovery.md`:
- `473edca9` (233GB, WDC_WD2500JB-00GVA0) - VGslow, VGfast
- `4474de00` (280GB, ST3300831A) - VGfast (multi-disk)

**Not yet processed (5)**:
- `4c2d175a` - NOT_PROCESSED
- `6bb11732` - NOT_PROCESSED
- `9c5156cf` - NOT_PROCESSED
- `a78ccc01` - NOT_PROCESSED
- `carved_sda_20251013` - NOT_PROCESSED

**Orphaned raw files - NO DB RECORDS (3)** ⚠️:
- `3033499e89e2efe1f2057c571aeb793a.raw` - 830MB, Oct 2
- `369372383055cdf9b0c19d17d055df93.raw` - 2.2GB, Oct 7 (has -PREVIOUS backup too!)
- `f9b9c0a0062f15ac48c173c15a3871d9.raw` - 491MB, Oct 2

**Total orphaned raw data**: ~3.5GB of enumeration data with no database records

## What We Found

### Discovery: Orphaned Enumeration Data

Three large raw files exist with **no corresponding medium records in database**:

1. **3033499e89e2efe1f2057c571aeb793a.raw**
   - Size: 830MB
   - Created: Oct 2 14:16
   - Status: No medium record found

2. **369372383055cdf9b0c19d17d055df93.raw**
   - Size: 2.2GB
   - Created: Oct 7 08:19
   - **Also has**: `369372383055cdf9b0c19d17d055df93.raw-PREVIOUS` (2.2GB, Oct 4 18:22)
   - Status: No medium record found
   - Notes: Two versions exist - suggests re-enumeration occurred

3. **f9b9c0a0062f15ac48c173c15a3871d9.raw**
   - Size: 491MB
   - Created: Oct 2 13:45
   - Status: No medium record found

### Hypothesis

These raw files were created during enumeration but:
- Medium records were never created in database, OR
- Medium records were deleted/corrupted, OR
- Hash mismatch between raw filename and medium_hash in DB

### Critical Point

**ALL img files have data worth recovering** - these are NOT garbage to delete, they represent real media that need to be loaded and copied.

## What We're About to Do

### Recovery Plan for Orphaned Raw Files

**Goal**: Load enumeration data from raw files into database and copy files to by-hash storage.

**Steps**:
1. Verify raw file format and integrity
2. Check if corresponding IMG files exist
3. For each raw file:
   a. Create/verify medium record in database
   b. Run `ntt-loader` to import enumeration data
   c. Mount IMG file (if exists)
   d. Run `ntt-copy-workers` to deduplicate files
   e. Archive IMG file
   f. Remove raw file

**Priority order**:
1. `f9b9c0a0` (491MB) - smallest, quickest to process
2. `3033499e` (830MB) - medium size
3. `36937238` (2.2GB) - largest, has backup version

**Expected challenges**:
- Finding corresponding IMG files (may be in unprocessed or already archived)
- Hash verification (raw filename may not match actual medium hash)
- Missing metadata (medium_human, message, health status)

## Tools Used

- `bin/cleanup-completed-raw-files.sh` - NEW: Batch raw file cleanup
- SQL queries for timestamp backfill
- `stat` for archive modification timestamps
- Manual verification of by-hash storage

## Lessons Learned

1. **BUG-016 affected 23+ media** (likely more exist in completed set)
2. **Batch processing saves time** - cleanup script removed 69 files in seconds
3. **Large raw files exist** - 8GB and 2GB files were sitting around unnecessarily
4. **Orphaned data needs investigation** - 3.5GB of enumeration data found with no DB records
5. **IMG archiving became standard mid-project** - early media have IMG deleted without archives

## References

- `bugs/BUG-016-orchestrator-missing-timestamp-updates.md` - Original bug report
- `PROX-CLAUDE-CHECKLIST.md` lines 411-418 - Remediation pattern
- `docs/todo-lvm1-recovery.md` - LVM1 recovery plan for 473edca9/4474de00

---

## Phase 1-4: Orphaned Raw File Investigation Results

### f9b9c0a0062f15ac48c173c15a3871d9.raw (491MB, 64K records)

**Status**: ✅ **MATCHED**

**Findings**:
- Raw format: Old permissions-based format (775, 644 vs. d, f, l)
- Mount point: `/mnt/tmp` (old)
- Content: Mac Spotlight database files, Time Machine 2014-04-09
- Sample paths:
  ```
  /mnt/tmp/.Spotlight-V100/Store-V2/02818120-5438-4D8A-A342-1946BF71C798/store.db
  /mnt/tmp/.Spotlight-V100/Store-V2/4B0BFEF5-FB55-45DA-9369-067DDE6F4797/0.indexHead
  ```

**Matched to**: **beb2a986607940cd63f246292efdf0b8**
- Medium name: (empty, but message says "Time Machine 2014-04-09")
- Mount point: `/mnt/ntt/tm-partition2/old-time-machine/...`
- Inode count: 2,632,897 
- Status: All files copied, timestamps set (2025-10-03/2025-10-04)
- Note: IMG not archived (deleted before archiving standardized)

**Conclusion**: Data was re-enumerated correctly as beb2a986. Raw file is duplicate/obsolete.

---

### 3033499e89e2efe1f2057c571aeb793a.raw (830MB, 5.04M records)

**Status**: ❌ **NO MATCH - TRULY ORPHANED**

**Findings**:
- Raw format: Old permissions-based format
- Mount point: `/mnt/tmp3` (old)
- Content: Time Machine backup "xt's MacBook Pro" from 2013-02-07
- Sample paths:
  ```
  /mnt/tmp3/Backups.backupdb/xt's MacBook Pro/2013-02-07-115910/Macintosh HD/Applications/Calendar.app
  /mnt/tmp3/Backups.backupdb/xt's MacBook Pro/2013-02-07-115910/Macintosh HD/Library/Python
  ```
- Record count: 5,040,408 enumeration records

**Search results**:
- No medium in database contains these specific paths
- Checked all Time Machine media (cff53715, d9549175, 983dbb7d)
- 983dbb7d has 8.26M inodes but contains osxgather CD data (unrelated)
- cff53715/d9549175 have 3.45M inodes but different content

**Conclusion**: This enumeration data represents a **lost medium**:
- IMG file was deleted before data could be loaded/copied
- ~5 million files enumerated but never processed
- Data is unrecoverable (IMG file gone)
- Raw file represents historical record only

---

### 369372383055cdf9b0c19d17d055df93.raw (2.2GB + 2.2GB PREVIOUS)

**Status**: ✅ **MATCHED** (BUG-016 case, already fixed)

**Findings**:
- Medium hash: 369372383055cdf9b0c19d17d055df93
- Medium name: mac-backups-2025
- Inode count: 4,267,704 (all copied)
- Timestamps: Set during earlier remediation (2025-10-04/2025-10-10)
- Current raw: Oct 7, 66M records
- PREVIOUS raw: Oct 4, 66M records (identical count)

**Issue**: Missing `enum_done` timestamp (BUG-016)

**Resolution**: Timestamp set to Oct 4 18:22 (PREVIOUS file date). Current raw file (Oct 7) renamed to `.raw-NEWER` for investigation - may contain additional data worth comparing.

---

## Key Learnings

1. **f9b9c0a0 was re-enumerated**: Old format data from `/mnt/tmp` was correctly re-processed as beb2a986 with proper mount point
   
2. **3033499e is truly lost**: ~5M files from "xt's MacBook Pro" 2013 backup were enumerated but never loaded due to IMG file deletion

3. **Old format distinguishing features**:
   - Field 1: Permissions (775, 644) instead of filetype (d, f, l)
   - Mount points: `/mnt/tmp`, `/mnt/tmp3` instead of `/mnt/ntt/{HASH}`
   - Otherwise identical 7-field structure

4. **Remediation not possible for 3033499e**: Without IMG file, cannot load or copy files. Raw file serves only as historical record of what was lost.

## Recommendations

**For f9b9c0a0**:
- ✅ Delete raw file (data exists as beb2a986)
- ✅ Update beb2a986 message to note old raw file

**For 3033499e**:
- ⚠️ Keep raw file as historical record
- ⚠️ Update orphan medium record with detailed loss note
- ⚠️ Mark as "data_loss" in problems field

**For 36937238 (mac-backups-2025)**:
- ✅ Delete PREVIOUS raw file (done)
- ⚠️ Investigate NEWER raw file (66M records vs 4.27M loaded) - may indicate incomplete initial enumeration

---

## Final Investigation Results

### f9b9c0a0062f15ac48c173c15a3871d9.raw
- **Status**: ✅ Deleted
- **Reason**: Duplicate of beb2a986607940cd63f246292efdf0b8 (all data already processed)

### 3033499e89e2efe1f2057c571aeb793a.raw
- **Status**: ❌ **DATA LOSS CONFIRMED**
- **Investigation**:
  - Checked all archived IMG files for size match: None found
  - Searched for "xt MacBook" paths in all media: No matches
  - 36937238 has similar inode count but completely different content (PB backups 2020-2025)
- **Conclusion**: IMG file was deleted before loading. 5.04M files from "xt's MacBook Pro" 2013-02-07 backup are **permanently lost**
- **Action**: Marked in database with `problems.data_loss = true`, health='incomplete'
- **Raw file status**: Kept as historical record at `/data/fast/raw/3033499e89e2efe1f2057c571aeb793a.raw`

### 369372383055cdf9b0c19d17d055df93.raw-NEWER
- **Status**: ⚠️ **INCOMPLETE RE-ENUMERATION**
- **Investigation**:
  - Oct 4 enumeration: 4.27M inodes loaded (complete)
  - Oct 7 re-enumeration: 6.3M total records
  - Unique inodes in newer: Only 2.67M (1.6M FEWER than database)
  - Duplicate paths: 3.65M (57.7% of records are hardlinks)
- **Conclusion**: Oct 7 re-enumeration was incomplete/partial. Database has correct complete data from Oct 4.
- **Action**: Updated message with analysis, can delete newer raw file safely
- **Raw file status**: Can be deleted - database has more complete data

### Recommendations

1. **Delete raw files**:
   - ✅ f9b9c0a0 (done)
   - ✅ 36937238 PREVIOUS (done)
   - [ ] 36937238 NEWER - safe to delete (database has more complete data)

2. **Keep raw file**:
   - [ ] 3033499e - historical record of data loss

3. **Database cleanup complete**: All media properly documented with loss/duplicate notes

