<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/processing-queue.md
-->

# Media Processing Log

**Last updated:** 2025-10-11

**IMPORTANT:** This is a log of processing history, NOT a plan.

prox-claude re-evaluates next medium from database on each iteration. External factors change availability: ddrescue completion, bug fixes, storage space, new media added.

---

## Currently Processing

| Hash (short) | Phase | Started | Worker | Notes |
|--------------|-------|---------|--------|-------|
| 43fda374 | imaging | 2025-10-11 ~10:00 | ddrescue | Hitachi 750GB (waiting for completion) |

---

## Completed Recently

### 2025-10-11

| Hash (short) | Completed | Duration | Issues Hit | Size | Notes |
|--------------|-----------|----------|------------|------|-------|
| 00404a56 | 2025-10-11 ~11:30 | ~15 min | BUG-008 (Zip mount offset), BUG-009 (partition FK) | 1.4M | Zip disk, both bugs fixed and verified |
| 5cb0dafa | 2025-10-11 ~12:00 | - | (none) | 112G | 1.67M files, completed earlier in session |
| bb98aeca | 2025-10-11 ~12:05 | ~5 min | 4 I/O errors (auto-skipped) | 71M | 646 files, DiagnosticService auto-skip working |
| 536a933b | 2025-10-11 12:32 | ~20 min | BUG-011 (ext4 noload, fixed) | 26G | 292,289 files, 3TB Seagate disk |

### 2025-10-10

| Hash (short) | Completed | Duration | Issues Hit | Size | Notes |
|--------------|-----------|----------|------------|------|-------|
| 579d3c3a | 2025-10-10 10:57 | - | (processed earlier) | 56G | Finished incomplete processing (added DB timestamps) |
| 2b48bdc7 | 2025-10-10 12:17 | ~4 min | BEYOND_EOF (1 file skipped) | 832K | First test run, DiagnosticService auto-skip confirmed working |
| ff9313ea | 2025-10-10 12:56 | ~35 min | BUG-002 (SQL ambiguity, fixed) | 640K | Fresh run, hit SQL bug during copying, fixed and completed |
| c8714b2c | 2025-10-10 13:04 | ~2 min | (none) | 49M | Fresh run, clean completion (1358 files) |
| 92f92600 | 2025-10-10 13:08 | ~2 min | (none) | 1.8G | Fresh run, sparse filesystem (2 large files) |

---

## Blocked (Waiting on Bug Fixes)

| Hash (short) | Blocked By | Filed | Size | Notes |
|--------------|------------|-------|------|-------|
| (none) | - | - | - | - |

---

## Failed (Archived with Problems)

| Hash (short) | Reason | Problem Type | Archived | Notes |
|--------------|--------|--------------|----------|-------|
| 031a3ceb | No recoverable filesystems | MOUNT_FAILED | 2025-10-11 | Maxtor 373GB RAID, mount attempts failed on all partitions |

---

## Phase 1 Candidates (Reference Only)

From media-processing-plan-2025-10-10.md - prox-claude will query DB fresh to confirm availability:

- **579d3c3a** (579d3c3a476185f524b77b286c5319f5) - 56G ext3, multi-partition, already mounted
- **6ddf5caa** (6ddf5caa4ec53c156d4f0052856ffc49) - Small floppy
- **6d89ac9f** (6d89ac9f96d4cd174d0e9d11e19f24a8) - Small floppy
- **3a4b9050** (3a4b905005daceaac21319747358517d) - Small floppy
- **782e1baf** (782e1baf7695c352e3e74470ce47146b) - Small floppy

**Note:** Actual processing order determined by fresh DB query + phase criteria, not this list.

---

## Status Legend

**Currently Processing:**
- phase: pre-flight | enumeration | loading | copying | archiving
- worker: Worker ID for copier (e.g., test-worker, worker-1)

**Completed:**
- duration: Total time from start to archive completion
- issues: Bug numbers encountered (if any)

**Blocked:**
- blocked_by: Bug number(s) preventing processing

**Failed:**
- problem_type: Category from medium.problems JSONB

---

## Maintenance

**prox-claude updates:**
- Add to "Currently Processing" when starting a medium
- Move to "Completed Today" when copy_done set in DB
- Move to "Blocked" when bug blocks progress
- Move to "Failed" when archiving with permanent problems

**Rotation:**
- "Completed Today" rotated to archive weekly (or when section grows large)
- Keep recent history (last 7 days) visible for metrics-claude

---

## Next Medium Selection

prox-claude does NOT read this file to decide what to process next.

**Instead, on each iteration:**
1. Query database for candidates (enum_done=NULL, copy_done=NULL, problems=NULL)
2. Check ddrescue status, IMG size, mount status, recovery %
3. Apply phase criteria from media-processing-plan
4. Select best candidate from current state
5. Process selected medium
6. Log outcome here

**This ensures:** Adaptive to ddrescue completion, bug fixes, storage changes, new media.

---

**References:**
- Workflow: `media-processing-plan-2025-10-10.md`
- Roles: `ROLES.md`
- Bug tracking: `bugs/`
- Metrics: `metrics/`
