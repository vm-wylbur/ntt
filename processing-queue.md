<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/processing-queue.md
-->

# Media Processing Log

**Last updated:** 2025-10-10 (initialized)

**IMPORTANT:** This is a log of processing history, NOT a plan.

prox-claude re-evaluates next medium from database on each iteration. External factors change availability: ddrescue completion, bug fixes, storage space, new media added.

---

## Currently Processing

| Hash (short) | Phase | Started | Worker | Notes |
|--------------|-------|---------|--------|-------|
| (none) | - | - | - | Ready to start Phase 1 |

---

## Completed Today

| Hash (short) | Completed | Duration | Issues Hit | Size | Notes |
|--------------|-----------|----------|------------|------|-------|
| (none yet) | - | - | - | - | - |

---

## Blocked (Waiting on Bug Fixes)

| Hash (short) | Blocked By | Filed | Size | Notes |
|--------------|------------|-------|------|-------|
| (none) | - | - | - | - |

---

## Failed (Archived with Problems)

| Hash (short) | Reason | Problem Type | Archived | Notes |
|--------------|--------|--------------|----------|-------|
| (none) | - | - | - | - |

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
