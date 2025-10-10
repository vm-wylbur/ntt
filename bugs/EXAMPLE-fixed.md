<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/EXAMPLE-fixed.md
-->

# BUG-001: Loader timeout on 56G ext3 disk

**Filed:** 2025-10-10 14:30
**Filed by:** prox-claude
**Status:** fixed
**Affected media:** 579d3c3a (579d3c3a476185f524b77b286c5319f5)
**Phase:** loading

---

## Observed Behavior

Loader has been running for 8 minutes with no output since "Deduplication started". Expected completion in <10s per media-processing-plan.md, 5min timeout should have fired but didn't.

**Commands run:**
```bash
time sudo bin/ntt-loader /tmp/579d3c3a.raw 579d3c3a476185f524b77b286c5319f5
```

**Output/Error:**
```
Loading raw file: /tmp/579d3c3a.raw
Medium hash: 579d3c3a476185f524b77b286c5319f5
Creating partitions...
Partition inode_p_579d3c3a476185f524b77b286c5319f5 created
Partition path_p_579d3c3a476185f524b77b286c5319f5 created
Importing data...
Imported 1,847,293 inodes
Imported 2,103,567 paths
Deduplication started...
<hangs here - no output for 8+ minutes>
^C (killed after 8 minutes)
```

**Database state:**
```sql
-- Query run:
SELECT COUNT(*) FROM inode WHERE medium_hash = '579d3c3a476185f524b77b286c5319f5';

-- Result:
 count
---------
 1847293
(1 row)

-- Partitions exist but deduplication query never completed
```

**Filesystem state:**
```bash
# Raw file size:
-rw-r--r-- 1 root root 234M Oct 10 14:25 /tmp/579d3c3a.raw

# Partitions created:
inode_p_579d3c3a476185f524b77b286c5319f5 | 1847293 rows
path_p_579d3c3a476185f524b77b286c5319f5  | 2103567 rows
```

---

## Expected Behavior

Per media-processing-plan.md section "Phase 2: Loading":
- Log should show "Deduplication completed in Xs"
- Should complete in <10s for most media
- 5min statement timeout should abort if issues

---

## Success Condition

**How to verify fix:**

1. Drop existing partitions and reload
2. Run loader command
3. Observe timing and output

**Fix is successful when:**
- [ ] Loader completes in <10s for this medium (1.8M inodes)
- [ ] Log shows "Deduplication completed in Xs" message
- [ ] FK indexes are created successfully
- [ ] Test case: `time sudo bin/ntt-loader /tmp/579d3c3a.raw 579d3c3a...` completes in <10s

---

## Impact

**Severity:** high (assigned by metrics-claude)
**Initial impact:** Blocks 1 medium, potentially all medium/large disks
**Workaround available:** no
**Pattern:** Likely affects any medium >1M inodes

---

## Dev Notes

**Investigation:**
Examined bin/ntt-loader deduplication section (lines 230-250). Found deduplication query runs without:
1. ANALYZE after bulk import (planner has no stats)
2. Statement timeout set in session (only set globally)

**Root cause:**
After importing 1.8M inodes, PostgreSQL query planner has no statistics on new partition. Without ANALYZE, planner chooses sequential scan instead of index scan, causing 8+ minute query time.

**Changes made:**
- `bin/ntt-loader:234` - Added `ANALYZE inode_p_{hash}; ANALYZE path_p_{hash};` after import
- `bin/ntt-loader:237` - Added `SET statement_timeout = '5min';` before deduplication query
- `bin/ntt-loader:242` - Added timing log: `Deduplication completed in {elapsed}s`

**Testing performed:**
- Created test partition with 1M synthetic inodes
- Without ANALYZE: 4min 23s
- With ANALYZE: 2.1s
- Verified timeout works by setting to 1s (aborts as expected)

**Ready for testing:** 2025-10-10 16:45

---

## Fix Verification

**Tested:** 2025-10-10 17:00
**Medium:** 579d3c3a476185f524b77b286c5319f5 (56G ext3, 1.8M inodes)

**Results:**
- [x] Loader completed in 3.2s (SUCCESS - well under 10s)
- [x] Log shows "Deduplication completed in 3.2s" (SUCCESS)
- [x] FK indexes present: `path_p_579d3c3a476185f524b77b286c5319f5_fk_idx` exists (SUCCESS)
- [x] Test case passed: `time sudo bin/ntt-loader...` took 3.2s real time (SUCCESS)

**Verification steps:**
```bash
# Dropped old partitions
DROP TABLE inode_p_579d3c3a476185f524b77b286c5319f5 CASCADE;
DROP TABLE path_p_579d3c3a476185f524b77b286c5319f5 CASCADE;

# Re-ran loader
time sudo bin/ntt-loader /tmp/579d3c3a.raw 579d3c3a476185f524b77b286c5319f5

# Output:
Loading raw file: /tmp/579d3c3a.raw
...
Deduplication completed in 3.2s
Creating FK indexes...
Loader completed successfully

real    0m3.245s
user    0m0.023s
sys     0m0.012s

# Verified indexes
SELECT indexname FROM pg_indexes
WHERE tablename = 'path_p_579d3c3a476185f524b77b286c5319f5'
  AND indexname LIKE '%fk%';

        indexname
------------------------------------------
 path_p_579d3c3a476185f524b77b286c5319f5_fk_idx
```

**Outcome:** VERIFIED - All success conditions met, moving to bugs/fixed/

**Additional notes:**
Fix dramatically improved performance (8min → 3s). Should benefit all medium/large disks going forward.
