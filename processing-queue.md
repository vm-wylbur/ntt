<!--
Author: PB and Claude (prox-claude)
Date: Sun 20 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/processing-queue.md
-->

# Media Processing Log

**Last updated:** 2025-10-20

**IMPORTANT:** This is a log of processing history, NOT a plan.

prox-claude re-evaluates next medium from database on each iteration. External factors change availability: ddrescue completion, bug fixes, storage space, new media added.

---

## Currently Processing

| Hash (short) | Phase | Started | Worker | Notes |
|--------------|-------|---------|--------|-------|
| (none) | - | - | - | All available media processed or blocked |

---

## Completed Recently

| Hash (short) | Completed | Duration | Issues Hit | Size | Notes |
|--------------|-----------|----------|------------|------|-------|
| ed885de4 | 2025-10-20 17:48 | - | (none) | 30MiB | Zip 100, processed automatically, archived |
| 30ebff49 | 2025-10-20 16:33 | 2s | (none) | 92MiB | Zip 250, 4 inodes, clean completion |

---

## Blocked (Waiting on Bug Fixes)

| Hash (short) | Blocked By | Filed | Size | Notes |
|--------------|------------|-------|------|-------|
| 031a3ceb | BUG-021 | 2025-10-20 19:30 | 373GB | Maxtor, 99.99% recovery but orchestrator calculates health as <20%, refuses to mount |

---

## Failed (Archived with Problems)

| Hash (short) | Reason | Problem Type | Archived | Notes |
|--------------|--------|--------------|----------|-------|
| 24f9ecb5 | No recognizable filesystem | MOUNT_FAILED | 2025-10-20 16:35 | Zip 250, blank or severely corrupted, partial ddrescue recovery |
| d6c63baf | Drive unreadable | UNREADABLE | 2025-10-20 17:42 | 465GB Hitachi, ddrescue errors at ~2%, severe read errors, partial IMG archived (2.0GB compressed) |

---

## Database Cleanup (2025-10-20 17:42)

**Deleted orphaned records:**
- 0e7e445b, 3fdf653a - CD-ROM records misidentified as floppies, IMG files lost, likely re-imaged later

**Updated:**
- d6c63baf - Marked as unreadable, partial IMG archived

## Available Candidates (Database Query 2025-10-20 17:42)

Fresh query results:
- **ed885de4** (IOMEGA_ZIP_100) - 96M, currently being imaged by ddrescue
- **031a3ceb** (Maxtor 373GB) - currently being imaged, ~2h estimated
- **f9b9c0a0** (orphaned) - no IMG file

---

## Status Legend

**Currently Processing:**
- phase: pre-flight | enumeration | loading | copying | archiving
- worker: Worker ID for processing

**Completed:**
- duration: Total time from start to archive completion
- issues: Bug numbers encountered (if any)

**Blocked:**
- blocked_by: Bug number(s) preventing processing

**Failed:**
- problem_type: Category from medium.problems JSONB
