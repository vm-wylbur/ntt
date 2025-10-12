<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/metrics/2025-10-10-b74dff65-fat-corruption.md
-->

# Reprocessing Report: b74dff654f21db1e0976b8b2baaed0af (FAT Corruption)

**Date:** 2025-10-10
**Medium:** b74dff654f21db1e0976b8b2baaed0af (floppy_20251005_191638_b74dff65)
**Type:** 1.5MB floppy disk
**Reason:** Archived but 0 blobids, problems="duplicate_paths"

---

## Initial State

- **Database:** 0 inodes, enum_done=NULL, copy_done=NULL
- **Problems:** "Enumeration found duplicate paths (ASC-LET.WP, ASC-PRSP.DOC, ASC-PRSP.WP), cannot load into database"
- **Image:** 1.5MB at `/data/fast/img/b74dff654f21db1e0976b8b2baaed0af.img`

---

## Root Cause: FAT Filesystem Corruption

### Evidence

**Mounted filesystem listing showed:**
```
-rwxr-x--- 1 root root 2303 Feb 24 1995 ASC-LET.WP
-rwxr-x--- 1 root root 2303 Feb 24 1995 ASC-LET.WP    # DUPLICATE
-rwxr-x--- 1 root root 19968 Feb 24 1995 ASC-PRSP.DOC
-rwxr-x--- 1 root root 19968 Feb 24 1995 ASC-PRSP.DOC  # DUPLICATE
-rwxr-x--- 1 root root 22307 Feb 24 1995 ASC-PRSP.WP
-rwxr-x--- 1 root root 22307 Feb 24 1995 ASC-PRSP.WP   # DUPLICATE
-rwxr-x--- 1 root root 13770 Feb 24 1995 PDB-CV.WP
-rwxr-x--- 1 root root 13770 Feb 24 1995 PDB-CV.WP     # DUPLICATE
```

**Plus corrupted entries:**
```
-rwxr-x--- 1 root root 4190369916 Jan 4 2042 ;|s?6.|?      # 4GB file on 1.5MB floppy!
-rwxr-x--- 1 root root 2857697280 Aug 31 2021 ady         # 2.8GB!
d????????? ? ? ? ? ? PRQ?:.??                                # Corrupted directory
```

**Total:** 36 directory entries enumerated, 5 duplicates + 6+ garbage entries

---

## Recovery Process

### Step 1: Re-enumerate

```bash
sudo bin/ntt-enum /mnt/ntt/b74dff654f21db1e0976b8b2baaed0af \
  b74dff654f21db1e0976b8b2baaed0af \
  /data/fast/raw/b74dff654f21db1e0976b8b2baaed0af.raw
```

**Result:** 36 records captured (including duplicates and garbage)

### Step 2: Deduplicate .raw File

```bash
cat /data/fast/raw/b74dff654f21db1e0976b8b2baaed0af.raw | sort -z -u \
  > /tmp/dedup.raw
mv /tmp/dedup.raw /data/fast/raw/b74dff654f21db1e0976b8b2baaed0af.raw
```

**Result:** 36 records → 31 unique records (5 duplicates removed)

**Format preserved:**
- Records: `type\034device\034inode\034nlink\034size\034mtime\034path\0`
- Used `sort -z -u` to deduplicate null-terminated records

### Step 3: Load Deduplicated Data

```bash
sudo bin/ntt-loader /data/fast/raw/b74dff654f21db1e0976b8b2baaed0af.raw \
  b74dff654f21db1e0976b8b2baaed0af
```

**Result:**
- 32 paths loaded
- 3 directories, 29 files
- No duplicate path errors

### Step 4: Copy Files

```bash
sudo bin/ntt-copier.py --medium-hash b74dff654f21db1e0976b8b2baaed0af
```

**Result:**
- **29 files successfully copied** (0.6MB total)
- **6 files auto-skipped** (BEYOND_EOF - garbage entries)
- DiagnosticService correctly handled unrecoverable corruption

**Skipped files (corrupted):**
1. WINTUNE.ZIP (claimed to be 651KB, actual corruption)
2. 5 garbage entries with impossible sizes/names

---

## Findings

### FAT Corruption Types

1. **Duplicate directory entries:** 5 files had double entries in FAT
2. **Garbage entries:** 6+ entries with:
   - Impossible file sizes (GB on 1.5MB floppy)
   - Corrupted filenames (binary garbage)
   - Invalid dates (2042, 2101)
   - Corrupted directory structures

3. **Recoverable data:** 29 legitimate files successfully extracted

---

## Success Criteria: ✓ ALL MET

- ✓ Manual deduplication of .raw file successful
- ✓ 29 files recovered to by-hash
- ✓ DiagnosticService auto-skipped corrupted entries
- ✓ Database timestamps set correctly
- ✓ FAT corruption documented in medium.problems

---

## Lessons Learned

### For ntt-loader Enhancement

**Current behavior:** Fails on duplicate paths (primary key violation)

**Enhancement needed:**
- **Option A:** Auto-deduplicate during load (keep first occurrence)
- **Option B:** Warn but continue (mark duplicates in diagnostics)
- **Option C:** Provide `--allow-duplicates` flag for manual handling

**Recommendation:** Option A (auto-deduplicate) since FAT corruption is common on old media.

### For ntt-mount-helper Enhancement

**Detection opportunity:** Could detect FAT corruption early:
```bash
# Count directory entries vs unique paths
find /mnt/... | sort | uniq -d
# If duplicates found, warn user about FAT corruption
```

---

## Final State

- **29 files recovered** from corrupted floppy
- **6 garbage entries** auto-skipped by DiagnosticService
- **FAT corruption handled** through manual .raw deduplication
- **Database state:** enum_done + copy_done set, medium complete

---

## Pattern for Future Media

**If encountering duplicate_paths error:**

1. Re-run ntt-enum to get fresh .raw file
2. Deduplicate: `cat file.raw | sort -z -u > file.raw`
3. Drop partitions and reload
4. Copy files (DiagnosticService will handle garbage)
5. Document in medium.problems

**Better solution:** Enhance ntt-loader to auto-deduplicate (see dev-claude)
