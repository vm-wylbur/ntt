<!--
Author: PB and Claude
Date: Fri 25 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-022-loader-truncates-existing-partitions-ed3ae3ed.md
-->

# BUG-022: ntt-loader Silently Truncates Existing Partitions

**Filed:** 2025-10-26 10:30
**Filed by:** prox-claude
**Status:** open
**Affected media:** ed3ae3ed (ed3ae3eddf99bcc2a545c7dc483f1b70)
**Phase:** loading

---

## Observed Behavior

Loaded a second enumeration (.raw file) for an already-processed medium. The loader silently TRUNCATED the existing partitions, destroying 2,346,982 previously-loaded inode and path records.

**Commands run:**
```bash
# First enumeration (Oct 22) - original 2.3M records
sudo bin/ntt-loader /data/fast/raw/ed3ae3eddf99bcc2a545c7dc483f1b70.raw ed3ae3eddf99bcc2a545c7dc483f1b70

# Second enumeration (Oct 25) - attempting to append 46K recovered files
sudo bin/ntt-loader /data/fast/raw/ed3ae3eddf99bcc2a545c7dc483f1b70-recovered.raw ed3ae3eddf99bcc2a545c7dc483f1b70
```

**Output/Error:**
```
[2025-10-25T14:12:50-07:00] Creating partition for medium ed3ae3eddf99bcc2a545c7dc483f1b70...
NOTICE:  relation "inode_p_ed3ae3ed" already exists, skipping
NOTICE:  relation "path_p_ed3ae3ed" already exists, skipping
[... continues normally ...]
[2025-10-25T14:12:51-07:00] Deduplicating into final tables...
SET
SET
SET
SET
INSERT 0 0
DO
TRUNCATE TABLE    <--- ⚠️ SILENT DATA LOSS HERE
INSERT 0 46683
INSERT 0 46683
[2025-10-25T14:12:52-07:00] ✓ Loading complete: 46683 paths loaded for medium ed3ae3eddf99bcc2a545c7dc483f1b70
```

The loader output shows "TRUNCATE TABLE" but provides no warning that it's about to destroy 2.3M existing records.

**Database state:**
```sql
-- Before second load (Oct 22-25):
SELECT COUNT(*) FROM inode WHERE medium_hash = 'ed3ae3eddf99bcc2a545c7dc483f1b70';
-- Result: 2,346,982 rows

SELECT COUNT(*) FROM path WHERE medium_hash = 'ed3ae3eddf99bcc2a545c7dc483f1b70';
-- Result: 2,346,982+ rows

-- After second load (Oct 25):
SELECT COUNT(*) FROM inode WHERE medium_hash = 'ed3ae3eddf99bcc2a545c7dc483f1b70';
-- Result: 46,683 rows  ❌ LOST 2,300,299 RECORDS

SELECT COUNT(*) FROM path WHERE medium_hash = 'ed3ae3eddf99bcc2a545c7dc483f1b70';
-- Result: 46,683 rows  ❌ LOST 2,300,299+ RECORDS
```

**Context:**
- Original medium had I/O errors, was re-imaged as dd4918edc8a2cefaf6c3d0560cfc30d2
- Attempted to load additional 46K "io-error-files-recovered" into original ed3ae3ed partitions
- Loader silently destroyed all existing data
- Only caught because we had the re-imaged version with all data intact

---

## Expected Behavior

When loading into an existing partition, loader should either:

**Option A (Conservative):** Error and refuse to proceed
```
ERROR: Partition inode_p_ed3ae3ed already exists with 2,346,982 records
Cannot load into existing partition. Use --force-append or --force-replace flag.
```

**Option B (Safe append):** Append new records without truncating
- Check for inode number collisions
- Insert only new records
- Update existing records if needed

**Option C (Explicit replacement):** Only truncate if explicitly requested
```bash
sudo bin/ntt-loader --replace /data/fast/raw/file.raw hash
```

**NEVER:** Silently truncate without warning or explicit flag

---

## Success Condition

**How to verify fix (must be observable, reproducible, specific):**

1. Create test medium with 1000 records in partition
2. Run loader with second .raw file for same medium_hash
3. Verify loader either errors OR preserves original 1000 records

**Fix is successful when:**
- [ ] Running `sudo bin/ntt-loader <second-raw-file> <existing-hash>` either:
  - ERRORS with clear message about existing partition, OR
  - Successfully appends without data loss
- [ ] Test case with existing partition shows NO TRUNCATE in output unless `--replace` flag used
- [ ] Query `SELECT COUNT(*) FROM inode_p_<hash>` after second load shows original count + new count (if append mode)
- [ ] Loader documentation updated to explain behavior with existing partitions
- [ ] No silent data loss - user must explicitly request truncation

---

## Impact

**Severity:** (to be assigned by metrics-claude)
**Initial impact:** CRITICAL DATA LOSS - Lost 2.3M database records (paths→blobids mappings)
**Workaround available:** no (data is gone unless backup exists)
**Recovery:** Only possible because we had re-imaged the drive as dd4918ed with all files safely copied

**Note:** The actual files in `/data/fast/ntt/by-hash` are safe (content-addressed storage), but we lost the database index linking paths to blobids for ed3ae3ed. This makes it impossible to know which files came from which paths on the original medium.

---

## Dev Notes

<!-- dev-claude appends investigation and fix details here -->

---

## Fix Verification

<!-- prox-claude tests fix and documents results here -->
