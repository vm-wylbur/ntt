<!--
Author: PB and Claude
Date: Thu 09 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/medium-columns-guide.md
-->

# Medium Table Columns - Usage Guide

## Overview

The `medium` table tracks metadata for disk images throughout the NTT pipeline. It has four narrative/metadata columns that serve different purposes. This guide clarifies when to use each column and who owns it.

---

## Column Responsibilities

### 1. `health` - Imaging Quality Status

**Owner:** Orchestrator (ntt-orchestrator, ntt-imager)
**Data Type:** text (enum)
**Purpose:** Quick status check for ddrescue imaging success

**Valid Values:**
- `'ok'` - 100% rescued, fully mountable (DEFAULT)
- `'incomplete'` - 90-99% rescued, mountable but may have data gaps
- `'corrupt'` - 20-89% rescued, mountable but significant data loss expected
- `'failed'` - <20% rescued, refused to mount (too degraded)

**Set By:**
- Orchestrator after ddrescue completes (parses mapfile for rescue percentage)
- ntt-copy-workers script (sets to 'ok' for compatibility)

**Read By:**
- Copier before mounting (refuses to mount only if == 'failed', allows 'ok'/'incomplete'/'corrupt')
- Dashboard for filtering (`WHERE health = 'ok'`)
- Reports for imaging success metrics

**Example Usage:**
```sql
-- Orchestrator sets after imaging
UPDATE medium
SET health = 'ok'
WHERE medium_hash = 'abc123';

-- Copier checks before mounting
SELECT health
FROM medium
WHERE medium_hash = 'abc123';
-- If health == 'failed' → refuse to mount, mark all inodes as EXCLUDED
-- If health == 'incomplete' or 'corrupt' → allow mount with warning
```

**Design Decision:**
- Simple enum (not JSONB) for fast filtering
- Defaults to 'ok' for backward compatibility
- Check constraint enforces valid values only

---

### 2. `problems` - Runtime Copier Diagnostic Data

**Owner:** Copier (ntt-copier.py, DiagnosticService)
**Data Type:** jsonb
**Purpose:** Rich diagnostic data about copying failures and runtime issues

**Structure:**
```json
{
  "diagnostic_events": [
    {
      "ino": 3455,
      "retry_count": 10,
      "checks": ["detected_beyond_eof", "dmesg:beyond_eof"],
      "action": "diagnostic_skip",
      "timestamp": "2025-10-09T10:15:30",
      "worker_id": "w1",
      "exception_type": "OSError",
      "exception_msg": "Input/output error"
    }
  ],
  "beyond_eof_detected": true,
  "high_error_rate": {
    "rate_percent": 15.3,
    "detected_at_count": 1000
  }
}
```

**Set By:**
- Copier during batch processing (Phase 4 deferred writes)
- DiagnosticService when errors are detected at retry checkpoints

**Read By:**
- Analytics queries (which media had BEYOND_EOF errors?)
- Troubleshooting (why did this medium fail to copy?)
- Reports (error patterns across media)

**Example Usage:**
```sql
-- Find media with BEYOND_EOF problems
SELECT medium_hash, medium_human
FROM medium
WHERE problems->'beyond_eof_detected' = 'true';

-- Count diagnostic events by medium
SELECT
    medium_hash,
    jsonb_array_length(problems->'diagnostic_events') as event_count
FROM medium
WHERE problems->'diagnostic_events' IS NOT NULL
ORDER BY event_count DESC;

-- Find media with high error rates
SELECT
    medium_hash,
    (problems->'high_error_rate'->>'rate_percent')::numeric as error_rate
FROM medium
WHERE problems->'high_error_rate' IS NOT NULL
ORDER BY error_rate DESC;
```

**Design Decision:**
- JSONB for flexible structure (new diagnostic types can be added)
- Separate events array for per-inode diagnostics
- Medium-level summaries for quick queries
- Written with deferred pattern to preserve FOR UPDATE SKIP LOCKED

---

### 3. `diagnostics` - Image Metadata

**Owner:** Orchestrator (ntt-orchestrator)
**Data Type:** jsonb
**Purpose:** Technical metadata about the disk image for provenance

**Structure:**
```json
{
  "content_hash": "d9549175fb3638efbc919bdc01cb3310",
  "image_size_bytes": 2000009895936,
  "file_signature": "Apple HFS Plus version 4 (mounted) last modified 2019-01-24",
  "blkid": "UUID=16bdedfc-0c5e-307a-a9a3-f1c182998f1e BLOCK_SIZE=4096 LABEL=Backup TYPE=hfsplus"
}
```

**Set By:**
- Orchestrator after imaging completes
- Collected via `file` command, `blkid`, SHA256 hash

**Read By:**
- Provenance reports
- Filesystem type analysis
- Deduplication detection (content_hash)

**Example Usage:**
```sql
-- Find all HFS+ images
SELECT medium_hash, medium_human
FROM medium
WHERE diagnostics->>'blkid' LIKE '%TYPE=hfsplus%';

-- Find duplicate images by content hash
SELECT
    diagnostics->>'content_hash' as content_hash,
    array_agg(medium_hash) as duplicates,
    COUNT(*) as duplicate_count
FROM medium
WHERE diagnostics->>'content_hash' IS NOT NULL
GROUP BY diagnostics->>'content_hash'
HAVING COUNT(*) > 1;

-- Show image sizes
SELECT
    medium_hash,
    pg_size_pretty((diagnostics->>'image_size_bytes')::bigint) as size
FROM medium
WHERE diagnostics->>'image_size_bytes' IS NOT NULL
ORDER BY (diagnostics->>'image_size_bytes')::bigint DESC
LIMIT 10;
```

**Design Decision:**
- Separate from `problems` (imaging metadata != runtime issues)
- Content hash enables deduplication detection
- Filesystem type helps with mount troubleshooting

---

### 4. `message` - Human-Readable Description

**Owner:** User / Orchestrator
**Data Type:** text
**Purpose:** Human-readable label for the physical medium

**Examples:**
- "FoxTalk Companion 1995"
- "PB Data and Software AAAS 1996-2000"
- "CIIDH misc dbs 1995"
- "beige blank Sony"
- "2.5in HDD marked linux"

**Set By:**
- User when manually inserting medium
- Orchestrator from physical label (if readable)
- Can be updated manually for clarity

**Read By:**
- Dashboard displays
- Reports
- Manual troubleshooting

**Example Usage:**
```sql
-- Search by label
SELECT medium_hash, message
FROM medium
WHERE message ILIKE '%pakistan%';

-- Update description
UPDATE medium
SET message = 'HRW Pakistan Reports 1990-1995'
WHERE medium_hash = 'abc123';
```

**Design Decision:**
- Plain text (no structure needed)
- User-friendly, not machine-parseable
- Can contain dates, content descriptions, physical attributes

---

## Column Comparison Table

| Column | Owner | Type | Purpose | Example Value |
|--------|-------|------|---------|---------------|
| `health` | Orchestrator | text enum | Imaging success | 'ok', 'incomplete', 'corrupt', 'failed' |
| `problems` | Copier | jsonb | Runtime diagnostics | `{"beyond_eof_detected": true}` |
| `diagnostics` | Orchestrator | jsonb | Image metadata | `{"blkid": "TYPE=hfsplus"}` |
| `message` | User | text | Human description | "FoxTalk Companion 1995" |

---

## Common Query Patterns

### Find problematic media

**Imaging issues:**
```sql
SELECT medium_hash, medium_human, health, message
FROM medium
WHERE health != 'ok' AND health IS NOT NULL
ORDER BY added_at DESC;
```

**Copying issues:**
```sql
SELECT
    medium_hash,
    medium_human,
    problems->'beyond_eof_detected' as beyond_eof,
    jsonb_array_length(problems->'diagnostic_events') as diagnostic_events
FROM medium
WHERE problems IS NOT NULL
ORDER BY added_at DESC;
```

**Both imaging AND copying issues:**
```sql
SELECT
    medium_hash,
    medium_human,
    health,
    problems->'beyond_eof_detected' as has_eof_problems
FROM medium
WHERE health != 'ok'
  AND problems->'beyond_eof_detected' IS NOT NULL;
```

### Imaging success rate

```sql
SELECT
    COALESCE(health, 'unknown') as health,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) as percentage
FROM medium
GROUP BY health
ORDER BY count DESC;
```

### Error pattern analysis

```sql
-- Media with high error rates
SELECT
    medium_hash,
    medium_human,
    (problems->'high_error_rate'->>'rate_percent')::numeric as error_rate,
    (problems->'high_error_rate'->>'detected_at_count')::int as sample_size
FROM medium
WHERE problems->'high_error_rate' IS NOT NULL
ORDER BY error_rate DESC;

-- Count of BEYOND_EOF detections
SELECT COUNT(*) as beyond_eof_count
FROM medium
WHERE problems->'beyond_eof_detected' = 'true';
```

### Filesystem type distribution

```sql
SELECT
    diagnostics->>'blkid' ~ 'TYPE=([^ ]+)' as has_fs,
    substring(diagnostics->>'blkid' from 'TYPE=([^ ]+)') as fs_type,
    COUNT(*) as count
FROM medium
WHERE diagnostics->>'blkid' IS NOT NULL
GROUP BY fs_type
ORDER BY count DESC;
```

---

## When to Use Which Column

**Use `health`:**
- ✅ Checking if medium is safe to mount
- ✅ Filtering dashboard by imaging quality
- ✅ Reports on ddrescue success rates
- ✅ Quick status checks

**Use `problems`:**
- ✅ Investigating why files failed to copy
- ✅ Analyzing error patterns across media
- ✅ Troubleshooting runtime copier issues
- ✅ Querying which media had specific error types

**Use `diagnostics`:**
- ✅ Provenance tracking (content hashes)
- ✅ Filesystem type analysis
- ✅ Image metadata for reports
- ✅ Detecting duplicate images

**Use `message`:**
- ✅ Human-readable displays in UI
- ✅ Searching by content description
- ✅ Physical media tracking

---

## Implementation Notes

### Check Constraint

```sql
ALTER TABLE medium
ADD CONSTRAINT medium_health_valid
CHECK (health IN ('ok', 'incomplete', 'corrupt', 'failed', NULL));
```

This prevents invalid health values from being inserted.

### Partial Index

```sql
CREATE INDEX idx_medium_health_not_ok
ON medium(health)
WHERE health IS NOT NULL AND health != 'ok';
```

This speeds up queries looking for problematic media (only indexes non-ok values).

### Default Value

The `health` column defaults to NULL initially. The orchestrator sets it to 'ok', 'incomplete', 'corrupt', or 'failed' after imaging based on rescue percentage. The copier only refuses mounting if `health == 'failed'` (<20% rescued).

---

## Migration History

- **2025-10-09:** Adjusted health thresholds (incomplete: 90-99%, corrupt: 20-89%, failed: <20%)
- **2025-10-09:** Fixed health format (converted "true" to "ok", added constraint)
- **2025-10-08:** Added `problems` column for Phase 4 diagnostic recording
- **Earlier:** Added `diagnostics` column for image metadata

---

## Related Documentation

- **Diagnostic System:** `docs/copier-diagnostic-ideas.md`
- **Mount Architecture:** `docs/mount-arch-cleanups.md`
- **Diagnostic Queries:** `docs/diagnostic-queries.md`

---

## Questions?

If unsure which column to use:

1. **Is it about imaging quality?** → `health`
2. **Is it about copying runtime errors?** → `problems`
3. **Is it technical image metadata?** → `diagnostics`
4. **Is it a human label?** → `message`

When in doubt, use `problems` for anything related to file copying errors.
