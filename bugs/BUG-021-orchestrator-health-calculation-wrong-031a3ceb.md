<!--
Author: PB and Claude (prox-claude)
Date: Sun 20 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-021-orchestrator-health-calculation-wrong-031a3ceb.md
-->

# BUG-021: Orchestrator calculates health as <20% when actual recovery is 99.99%

**Filed:** 2025-10-20 19:30
**Filed by:** prox-claude
**Status:** open
**Affected media:** 031a3ceb (031a3ceb158fb23993c16de83fca6833)
**Phase:** mount

---

## Observed Behavior

Orchestrator refuses to mount image claiming health=failed (<20% rescued), but ddrescue log shows 99.99% recovery with only 512 bytes unreadable.

**Commands run:**
```bash
sudo bin/ntt-orchestrator --image /data/fast/img/031a3ceb158fb23993c16de83fca6833.img
```

**Output/Error:**
```
[2025-10-20T19:29:39-07:00] Using hash from filename: 031a3ceb158fb23993c16de83fca6833
[2025-10-20T19:29:39-07:00] Found existing medium: Maxtor_6H400F0_H80P2CWH
[2025-10-20T19:29:39-07:00] Identified as: Maxtor_6H400F0_H80P2CWH (hash: 031a3ceb158fb23993c16de83fca6833)
[2025-10-20T19:29:39-07:00] Inserting medium record to database...
[2025-10-20T19:29:39-07:00] === STATE-BASED PIPELINE START ===
[2025-10-20T19:29:39-07:00] STAGE: Mount
[2025-10-20T19:29:40-07:00] ERROR: Refusing to mount - health=failed (<20% rescued)
[2025-10-20T19:29:40-07:00] Mount stage: FAILED (cannot continue)
```

**Actual ddrescue recovery from log:**
```
pct rescued:   99.99%, read errors:         10, remaining time:         n/a
                               time since last successful read:         n/a
Retrying bad sectors... Retry 10 (backwards)
Finished
[2025-10-20T19:10:22-07:00] PHASE 3 COMPLETE: 1 sectors remaining (99.99% rescued)
[2025-10-20T19:10:22-07:00] ======================================
[2025-10-20T19:10:22-07:00] EXCELLENT: 99.99% rescued after Phase 3 (>99% threshold)
[2025-10-20T19:10:22-07:00] Skipping phases 4-7 (diminishing returns)
[2025-10-20T19:10:22-07:00] Total time: 1 hours
[2025-10-20T19:10:22-07:00] ======================================
```

**Map file details:**
```bash
# File size and stats
$ ls -lh /data/fast/img/031a3ceb158fb23993c16de83fca6833.img
-rw-r----- 1 root root 373G Oct 20 19:08 031a3ceb158fb23993c16de83fca6833.img

$ ls -lh /data/fast/img/031a3ceb158fb23993c16de83fca6833.map
-rw-r----- 1 root root 520 Oct 20 19:10 031a3ceb158fb23993c16de83fca6833.map
```

**Map file content:**
- rescued: 400088 MB (99.99%)
- bad-sector: 512 B (0.00013%)
- bad areas: 1
- Total size: ~373GB

**Database state:**
```sql
-- Query:
SELECT medium_hash, medium_human, health
FROM medium
WHERE medium_hash = '031a3ceb158fb23993c16de83fca6833';

-- Result shows health calculated as "failed"
```

---

## Expected Behavior

With 99.99% recovery (only 512 bytes bad out of 373GB), orchestrator should:
1. Calculate health as "ok" or "incomplete" (NOT "failed")
2. Allow mounting to proceed
3. Process the image normally

According to ntt-imager exit codes and thresholds:
- >99% recovery = EXCELLENT
- Should be mountable and processable
- Minor read errors (10 errors over 373GB) are expected and acceptable

---

## Impact

**Severity:** HIGH - blocks processing of excellent recovery images

**Workaround:** None currently - cannot override health check

**Affected:** Any media with minor read errors but excellent recovery percentage

---

## Success Condition

**How to verify fix:**

1. Run orchestrator on the same image:
   ```bash
   sudo bin/ntt-orchestrator --image /data/fast/img/031a3ceb158fb23993c16de83fca6833.img
   ```

2. Check health calculation in logs and database

3. Verify mount proceeds

**Fix is successful when:**
- [ ] Health calculated as "ok" or "incomplete" (NOT "failed") for 99.99% recovery
- [ ] Orchestrator allows mount to proceed
- [ ] Mount succeeds (may fail on RAID partitions, but partition 2 should mount)
- [ ] Enumeration runs on mountable partition(s)
- [ ] No false "health=failed" errors for images with >95% recovery

---

## Additional Context

**Drive details:**
- Maxtor 6H400F0 (373GB)
- Partition table: DOS/MBR
- Partitions:
  - sde1: 94MB Linux RAID (fd)
  - sde2: 7.5GB Linux (83) ← should be mountable
  - sde3: 973MB swap
  - sde5-7: RAID members (fd) ← expected to fail mount

**Expected outcome after fix:**
- Partition 2 (7.5GB regular Linux) should mount successfully
- RAID partitions (1, 5, 6, 7) expected to fail mount - this is OK
- Should enumerate the 7.5GB partition

**Recovery quality:**
- ddrescue ran 3 phases
- Only 1 bad sector (512 bytes)
- 10 read errors over 373GB = 0.0000027% error rate
- This is excellent recovery quality
