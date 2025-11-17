<!--
Author: PB and Claude
Maintainer: PB
Original date: 2025.06.30
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/CLAUDE.md
-->

# NTT Project - AI Collaboration Guidelines

**IMPORTANT**: First read `~/dotfiles/ai/docs/meta-CLAUDE.md` for all general guidelines.

This document contains **NTT-specific** instructions only.

---

## NTT PROJECT DOCUMENTATION

### Before Starting Any Work

THINK and REFLECT and DISCUSS. Action comes after thinking. DO NOT JUMP STRAIGHT INTO CHANGES. 

**CRITICAL: Read these lessons first** - Never repeat these mistakes:
- `docs/lessons/lessons-learned-verifying-byhash-integrity-2025-10-04.md` - Don't assume, verify exhaustively
- `docs/lessons/partition-migration-postmortem-2025-10-05.md` - DETACH/ATTACH fails with parent-level FK, TRUNCATE CASCADE is dangerous
- `docs/lessons/lessons-learned-partition-drop-migration-2025-11-16.md` - Fast partition drop via rename strategy

### Project Overview

NTT is a disk image deduplication and archival system. Pipeline stages:
1. **Imaging** (`ntt-orchestrator`) - ddrescue disk images from physical media
2. **Enumeration** (`ntt-enum`) - Walk mounted filesystem, extract inode metadata
3. **Loading** (`ntt-loader`) - Import enumeration data into single unpartitioned `paths` table
4. **Copying** (`ntt-copier.py`) - Deduplicate files to by-hash storage with hardlinks
5. **Archiving** (`ntt-archiver`) - Compress and move to cold storage

### Key Reference Documents

Consult these when relevant to your work:

**Operational:**
- `ROLES.md` - **Multi-Claude workflow** (prox/dev/metrics roles, communication protocols)
- `media-processing-plan-2025-10-10.md` - Current processing plan with multi-Claude sections
- `docs/disk-read-checklist.md` - Diagnostic procedures for problematic disks (living doc)
- `docs/diagnostic-queries.md` - SQL queries for analyzing copier diagnostic data
- `docs/ignore-patterns-guide.md` - Path exclusion patterns (45 patterns, e5727c34 case study)

**Specifications:**
- `docs/hash-format.md` - BLAKE3 v2 hybrid format (SIZE|MODEL|SERIAL| + content)
- `docs/medium-columns-guide.md` - Database columns: health/problems/diagnostics/message
- `docs/sanity-checks.md` - Database integrity checks
- `docs/schema-evolution.md` - **Database schema history** (v1.0 → v1.5 partitioned → v2.0 unpartitioned)

**Architecture:**
- Schema: Unpartitioned `paths` + `blobs` tables (v2.0, Nov 2025) - See `sql/00-schema.sql` and `docs/schema-evolution.md`
- Diagnostics: DiagnosticService Phase 4 complete (commit 6c963c7)
- Copier: Claim-Analyze-Execute pattern (commit c63e2bf)

### Documentation Organization

- `docs/` - Active reference documentation
- `docs/lessons/` - Critical mistakes to avoid
- `docs/completed/` - Archived planning docs (implemented)
- `docs/partial/` - Incomplete work and ongoing planning

---

**Remember**: All general guidelines (communication, git workflow, approval, security, etc.) are in `~/dotfiles/ai/docs/meta-CLAUDE.md`
