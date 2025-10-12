<!--
Author: PB and Claude
Date: Fri 11 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-013-loader-special-chars-43fda374.md
-->

# BUG-013: Loader fails on filenames with special characters

**Filed:** 2025-10-11 17:00
**Filed by:** prox-claude
**Status:** open
**Affected media:** 43fda374c788bdf3a007fc8bf8aa10d8 (Hitachi 750GB RAID1), likely others
**Phase:** loading

---

## Observed Behavior

PostgreSQL COPY command fails during ntt-loader when processing filenames containing special characters. Loader successfully processes 2,492,006 records but fails on line 2,492,007 out of 3,000,636 total.

**Commands run:**
```bash
sudo bin/ntt-orchestrator --image /data/fast/img/43fda374c788bdf3a007fc8bf8aa10d8.img
```

**Error output:**
```
[2025-10-11T17:00:34-07:00] PostgreSQL COPY command failed
PostgreSQL COPY error:
Pager usage is off.
SET
ERROR:  extra data after last expected column
CONTEXT:  COPY raw_2188123, line 2492007: "f2309221515921409601361059776/mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/p1/floppies/0029/__G___..."
Error: Failed to load raw data into temp table
[2025-10-11T17:00:34-07:00] ERROR: Loader failed
[2025-10-11T17:00:34-07:00] Load stage: FAILED
```

**Timeline:**
1. Enumeration: SUCCESS (3,000,636 records → 3MB .raw file)
2. Loader creates partitions and working tables successfully
3. PostgreSQL COPY starts processing .raw file
4. Processing succeeds for first 2,492,006 records (83% complete)
5. Fails at line 2,492,007 with "extra data after last expected column"
6. Remaining 508,630 records not processed

---

## Root Cause Analysis

**Issue:** PostgreSQL COPY command interprets special characters in filenames as field delimiters or escape sequences, breaking the expected column count.

**Suspected problematic filename:**
```
/mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/p1/floppies/0029/__G___...
```

The filename contains `__G___` which may include:
- Control characters (newlines, tabs, carriage returns)
- Quote characters disrupting CSV/TSV parsing
- Escape sequences interpreted by PostgreSQL COPY

**Current loader behavior:**
```bash
# From ntt-loader output:
[2025-10-11T16:59:16-07:00] Starting data conversion (escape CR/LF, null → LF)...
[2025-10-11T16:59:16-07:00] Running PostgreSQL COPY command...
```

The loader attempts to escape CR/LF characters but the transformation is insufficient for all special characters that can appear in filenames.

**Evidence:**
- Failure at specific line (2,492,007) suggests data-dependent issue, not systematic problem
- Error message "extra data after last expected column" indicates field parsing failure
- Path `/floppies/0029/__G___` suggests old floppy disk with potentially corrupted filename metadata

---

## Expected Behavior

**Loader should handle ALL possible filename characters:**

1. **Escape special characters** that PostgreSQL COPY interprets as delimiters:
   - Tabs (field delimiter)
   - Newlines (record delimiter)
   - Backslashes (escape character)
   - Quotes (text qualifiers)
   - Null bytes

2. **Use robust COPY format** that handles binary/unusual data:
   - Consider PostgreSQL binary COPY format
   - Or use CSV format with proper QUOTE and ESCAPE settings
   - Or pre-process to hex-encode problematic fields

3. **Validate and sanitize** filenames during enumeration:
   - Flag files with unusual characters
   - Provide option to skip or special-handle them
   - Log problematic filenames for review

4. **Partial load recovery:**
   - Resume from failure point instead of failing entire load
   - Mark problematic records as EXCLUDED with diagnostic info
   - Continue processing remaining records

---

## Impact

**Severity:** Medium (blocks processing of specific media, but workarounds available)

**Current state:**
- 43fda374: 2.5M files successfully loaded (83%), 508K files not loaded
- Data loss: 17% of files from this disk not accessible via database
- Workaround: Manual file access via mount point works

**Affected operations:**
- Loading: Fails on media with unusual filenames
- Copying: Cannot proceed (depends on loaded inode records)
- Archiving: Cannot proceed without successful copy phase

**Not blocking:**
- Enumeration: Works correctly (all 3M files enumerated)
- Mounting: Works correctly (filesystem accessible)
- Manual file access: All files accessible via mount point

---

## Workaround

**Temporary manual access:**
```bash
# Mount still exists - files can be accessed directly
ls -la /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/p1/floppies/0029/

# Identify problematic file
find /mnt/ntt/43fda374c788bdf3a007fc8bf8aa10d8/p1/floppies/0029/ -name '*G*' -ls

# Can copy individual files manually if needed
```

**Partial database access:**
```sql
-- 2.5M files ARE accessible via database
SELECT COUNT(*) FROM inode WHERE medium_hash = '43fda374c788bdf3a007fc8bf8aa10d8';
-- Should return ~2,492,000

-- Can query successfully loaded files
SELECT * FROM path WHERE medium_hash = '43fda374c788bdf3a007fc8bf8aa10d8' LIMIT 10;
```

---

## Recommended Fix

**Short-term (patch):**

1. **Enhance data conversion step in ntt-loader:**
   ```bash
   # Current (insufficient):
   sed -e $'s/\r/\\r/g' -e $'s/\n/\\n/g' -e $'s/\x00/\\n/g'

   # Improved (escape all COPY-special chars):
   sed -e $'s/\\\\/\\\\\\\\/g' \     # Escape backslashes first
       -e $'s/\t/\\\\t/g' \          # Escape tabs (field delimiter)
       -e $'s/\r/\\\\r/g' \          # Escape carriage returns
       -e $'s/\n/\\\\n/g' \          # Escape newlines
       -e $'s/\x00/\\\\N/g'          # Convert nulls to \N (NULL marker)
   ```

2. **Add error recovery:**
   ```bash
   # If COPY fails, log problematic line and continue
   # Use ON_ERROR_STOP=off or wrap in transaction with savepoints
   ```

**Long-term (robust solution):**

1. **Switch to PostgreSQL CSV format with proper quoting:**
   ```sql
   COPY raw_table FROM '/path/to/file'
   WITH (FORMAT CSV, QUOTE '"', ESCAPE '\\', ENCODING 'UTF8');
   ```

2. **Or use binary COPY format:**
   ```sql
   COPY raw_table FROM '/path/to/file' WITH (FORMAT BINARY);
   ```

3. **Or pre-encode problematic fields:**
   - Base64 or hex-encode the full path field
   - Decode in application layer when retrieving

4. **Add validation during enumeration:**
   - Flag files with unusual characters in diagnostics
   - Provide option to exclude or special-handle them
   - Store original path + sanitized version for database

---

## Success Condition

**How to verify fix:**

1. **Process 43fda374 completely:**
   ```bash
   # Re-run loader with fix
   sudo bin/ntt-orchestrator --image /data/fast/img/43fda374c788bdf3a007fc8bf8aa10d8.img

   # Should complete without errors
   # All 3,000,636 records should load
   ```

2. **Verify record counts:**
   ```sql
   -- Check inode count matches enumeration
   SELECT COUNT(*) FROM inode WHERE medium_hash = '43fda374c788bdf3a007fc8bf8aa10d8';
   -- Expected: 3,000,636

   -- Check path records exist
   SELECT COUNT(*) FROM path WHERE medium_hash = '43fda374c788bdf3a007fc8bf8aa10d8';
   -- Expected: 3,000,636

   -- Verify problematic file is present
   SELECT * FROM path
   WHERE medium_hash = '43fda374c788bdf3a007fc8bf8aa10d8'
     AND path LIKE '%floppies/0029%';
   -- Should return records including the problematic file
   ```

3. **Test with other media containing special characters:**
   - Create test case with intentionally problematic filenames
   - Process through full pipeline
   - Verify all files load successfully

**Fix is successful when:**
- [ ] 43fda374 loads all 3M records without errors
- [ ] Problematic file at line 2,492,007 is accessible in database
- [ ] Pipeline completes through copying and archiving stages
- [ ] Test cases with intentional special characters process cleanly
- [ ] No regression on media with normal filenames

---

## Technical Notes

**PostgreSQL COPY format details:**
- Default format: TEXT with tab delimiter
- Escape character: backslash (`\`)
- Special escape sequences: `\t` (tab), `\n` (newline), `\r` (carriage return), `\\` (backslash)
- `\N` represents SQL NULL
- Control characters must be escaped or format must handle them

**Filename character risks:**
- POSIX allows any byte except NULL and `/` in filenames
- FAT/VFAT legacy filesystems may have unusual encodings
- Old floppy disks may have corrupted directory entries
- Zip disks (common in this dataset) used FAT32 with various codepages

**Data preservation priority:**
- Must not skip or lose files due to special characters
- Original filenames must be preserved exactly (forensic requirement)
- If encoding needed, must be reversible

---

## Related Issues

**Similar problems:**
- BUG-002: SQL ambiguity in copier (fixed - different issue)
- This is first time loader has encountered filenames that break COPY

**Architectural consideration:**
- Long-term: Consider switching entire .raw format to JSON or binary
- Would eliminate CSV parsing issues entirely
- Trade-off: Larger .raw files, but more robust

---

## Files Requiring Modification

**Primary: bin/ntt-loader**
- **Location:** Data conversion step before COPY command
- **Change:** Enhanced escaping of special characters in path field
- **Lines:** Around where "Starting data conversion" is logged

**Test data:**
- Create test .raw file with problematic filenames
- Verify escaping handles all edge cases

---

## Dev Notes

**Analysis by:** prox-claude
**Date:** 2025-10-11 17:00

This is first loader failure encountered in production use. 43fda374 is significant because it's a large archive disk (688GB, 3M files, spanning 2005-2013) with varied historical media (CDs, floppies, various filesystem formats).

The failure at 83% completion (2.5M/3M files) demonstrates that most filenames are fine - only specific problematic cases cause issues. This suggests targeted escaping enhancement will resolve the issue without major architectural changes.

Priority: Medium-High - blocks processing of valuable historical archive data, but workarounds exist for manual access.

**Recommendation:** Implement short-term patch (enhanced escaping) immediately to unblock 43fda374 processing. Plan long-term robust solution (CSV/binary format) for future resilience.
