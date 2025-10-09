<!--
Author: PB and Claude
Date: Wed 09 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/diagnostic-queries.md
-->

# NTT Diagnostic Queries

SQL queries for analyzing diagnostic data collected by the DiagnosticService.

**Related documentation:**
- `copier-diagnostic-ideas.md` - Diagnostic system design and implementation
- `disk-read-checklist.md` - Manual diagnostic procedures

---

## Table of Contents

1. [Diagnostic Events](#diagnostic-events)
2. [Medium-Level Summaries](#medium-level-summaries)
3. [Error Pattern Analysis](#error-pattern-analysis)
4. [Worker Performance](#worker-performance)
5. [Investigation Workflows](#investigation-workflows)

---

## Diagnostic Events

Diagnostic events are stored in `medium.problems->'diagnostic_events'` as a JSONB array.

Each event contains:
```json
{
  "ino": 3455,
  "retry_count": 10,
  "checks": ["detected_beyond_eof", "dmesg:beyond_eof", "mount_check:ok"],
  "action": "diagnostic_skip",
  "timestamp": "2025-10-08T14:23:45.123456",
  "worker_id": "worker-1",
  "exception_type": "OSError",
  "exception_msg": "Input/output error"
}
```

### Query 1: List all media with diagnostic events

```sql
-- See which media have triggered diagnostics
SELECT
    medium_hash,
    medium_human,
    jsonb_array_length(problems->'diagnostic_events') as event_count,
    enum_done,
    copy_done
FROM medium
WHERE problems->'diagnostic_events' IS NOT NULL
ORDER BY event_count DESC;
```

### Query 2: View diagnostic events for a specific medium

```sql
-- Expand all diagnostic events for a medium
SELECT
    medium_hash,
    medium_human,
    event->>'ino' as inode,
    event->>'retry_count' as retry_count,
    event->>'action' as action,
    event->>'timestamp' as timestamp,
    event->>'checks' as checks,
    event->>'exception_type' as exception_type,
    event->>'exception_msg' as exception_msg
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE medium_hash = 'f95834a4b718f54edc7b549ca854aef8'
ORDER BY event->>'timestamp';
```

### Query 3: Count events by action type

```sql
-- See what actions diagnostics have taken
SELECT
    event->>'action' as action,
    COUNT(*) as count,
    COUNT(DISTINCT medium_hash) as affected_media
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE problems->'diagnostic_events' IS NOT NULL
GROUP BY 1
ORDER BY count DESC;
```

**Expected actions:**
- `diagnostic_skip` - Inode permanently skipped (BEYOND_EOF)
- `continuing` - Diagnostics run, but continued retrying
- `max_retries` - Hit retry limit (50+), gave up
- `remounted` - Attempted remount (Phase 3, not yet implemented)

### Query 4: Find media with BEYOND_EOF errors

```sql
-- Media where we detected BEYOND_EOF errors
SELECT
    medium_hash,
    medium_human,
    COUNT(*) as beyond_eof_count
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE event->'checks' @> '["detected_beyond_eof"]'
   OR event->'checks' @> '["dmesg:beyond_eof"]'
GROUP BY medium_hash, medium_human
ORDER BY beyond_eof_count DESC;
```

### Query 5: Timeline of diagnostic events

```sql
-- See when diagnostics were triggered across all media
SELECT
    DATE(event->>'timestamp') as date,
    event->>'action' as action,
    COUNT(*) as events,
    COUNT(DISTINCT medium_hash) as media_count
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE problems->'diagnostic_events' IS NOT NULL
GROUP BY 1, 2
ORDER BY date DESC, events DESC;
```

---

## Medium-Level Summaries

Medium-level problems are recorded at the top level of `medium.problems` JSONB.

**Possible fields:**
- `beyond_eof_detected: true` - At least one BEYOND_EOF error detected
- `high_error_rate: {"rate_percent": 15.2, "detected_at_count": 500}` - >10% error rate
- `enum_failed: true` - Enumeration failed (manual entry)
- `mount_failed: true` - Mount failed (manual entry)

### Query 6: Media with BEYOND_EOF flag

```sql
-- See media with BEYOND_EOF detection (medium-level)
SELECT
    medium_hash,
    medium_human,
    problems->'beyond_eof_detected' as beyond_eof,
    (SELECT COUNT(*)
     FROM inode
     WHERE inode.medium_hash = medium.medium_hash
       AND claimed_by LIKE 'DIAGNOSTIC_SKIP:%') as skipped_inodes,
    (SELECT COUNT(*)
     FROM inode
     WHERE inode.medium_hash = medium.medium_hash) as total_inodes
FROM medium
WHERE problems->'beyond_eof_detected' = 'true'::jsonb;
```

### Query 7: Media with high error rates

```sql
-- See media with high error rates (>10%)
SELECT
    medium_hash,
    medium_human,
    (problems->'high_error_rate'->>'rate_percent')::numeric as error_rate,
    (problems->'high_error_rate'->>'detected_at_count')::int as sample_size,
    copy_done
FROM medium
WHERE problems->'high_error_rate' IS NOT NULL
ORDER BY error_rate DESC;
```

### Query 8: All medium-level problems summary

```sql
-- Get a summary of all problem types
SELECT
    medium_hash,
    medium_human,
    CASE
        WHEN problems->'beyond_eof_detected' = 'true'::jsonb THEN 'beyond_eof'
        ELSE NULL
    END as beyond_eof_flag,
    CASE
        WHEN problems->'high_error_rate' IS NOT NULL
        THEN (problems->'high_error_rate'->>'rate_percent') || '%'
        ELSE NULL
    END as error_rate,
    CASE
        WHEN problems->'diagnostic_events' IS NOT NULL
        THEN jsonb_array_length(problems->'diagnostic_events')
        ELSE 0
    END as event_count,
    copy_done
FROM medium
WHERE problems IS NOT NULL
ORDER BY copy_done DESC NULLS FIRST;
```

---

## Error Pattern Analysis

Queries for understanding error patterns across the entire corpus.

### Query 9: Exception types across all media

```sql
-- What types of exceptions are we seeing?
SELECT
    event->>'exception_type' as exception_type,
    COUNT(*) as count,
    COUNT(DISTINCT medium_hash) as media_affected,
    array_agg(DISTINCT event->>'action') as actions_taken
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE problems->'diagnostic_events' IS NOT NULL
GROUP BY 1
ORDER BY count DESC;
```

### Query 10: Check patterns detected

```sql
-- What diagnostic checks are triggering?
SELECT
    jsonb_array_elements_text(event->'checks') as check_pattern,
    COUNT(*) as count,
    COUNT(DISTINCT medium_hash) as media_affected
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE problems->'diagnostic_events' IS NOT NULL
GROUP BY 1
ORDER BY count DESC;
```

### Query 11: Correlation between checks and actions

```sql
-- Which checks lead to which actions?
SELECT
    event->>'action' as action,
    jsonb_array_elements_text(event->'checks') as check_pattern,
    COUNT(*) as count
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE problems->'diagnostic_events' IS NOT NULL
GROUP BY 1, 2
ORDER BY action, count DESC;
```

### Query 12: Problematic inodes per medium

```sql
-- Media with most diagnostic interventions
SELECT
    m.medium_hash,
    m.medium_human,
    COUNT(DISTINCT (event->>'ino')::int) as problem_inodes,
    (SELECT COUNT(*) FROM inode WHERE medium_hash = m.medium_hash) as total_inodes,
    ROUND(
        COUNT(DISTINCT (event->>'ino')::int)::numeric /
        NULLIF((SELECT COUNT(*) FROM inode WHERE medium_hash = m.medium_hash), 0) * 100,
        2
    ) as problem_percentage
FROM medium m,
     jsonb_array_elements(m.problems->'diagnostic_events') as event
WHERE m.problems->'diagnostic_events' IS NOT NULL
GROUP BY m.medium_hash, m.medium_human
HAVING COUNT(DISTINCT (event->>'ino')::int) > 0
ORDER BY problem_percentage DESC;
```

---

## Worker Performance

Queries for monitoring worker behavior and diagnostic overhead.

### Query 13: Diagnostic events by worker

```sql
-- Which workers are encountering diagnostics?
SELECT
    event->>'worker_id' as worker_id,
    COUNT(*) as events,
    COUNT(DISTINCT medium_hash) as media_processed,
    array_agg(DISTINCT event->>'action') as actions_taken
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE problems->'diagnostic_events' IS NOT NULL
GROUP BY 1
ORDER BY events DESC;
```

### Query 14: Recent diagnostic activity

```sql
-- What diagnostics have run in the last 24 hours?
SELECT
    event->>'timestamp' as timestamp,
    medium_hash,
    event->>'ino' as inode,
    event->>'action' as action,
    event->>'retry_count' as retry_count,
    event->>'exception_type' as exception
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE (event->>'timestamp')::timestamp > NOW() - INTERVAL '24 hours'
ORDER BY event->>'timestamp' DESC;
```

### Query 15: Diagnostic checkpoint effectiveness

```sql
-- How often are diagnostics preventing infinite loops?
SELECT
    CASE
        WHEN event->>'action' = 'diagnostic_skip' THEN 'Prevented infinite loop (skipped)'
        WHEN event->>'action' = 'continuing' THEN 'Logged but continued'
        WHEN event->>'action' = 'max_retries' THEN 'Hit max retries (failed)'
        ELSE event->>'action'
    END as outcome,
    COUNT(*) as count,
    ROUND(COUNT(*)::numeric / SUM(COUNT(*)) OVER () * 100, 2) as percentage
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE problems->'diagnostic_events' IS NOT NULL
GROUP BY event->>'action'
ORDER BY count DESC;
```

---

## Investigation Workflows

Queries for investigating specific media or error patterns.

### Query 16: Full diagnostic report for a medium

```sql
-- Complete diagnostic summary for a specific medium
WITH event_summary AS (
    SELECT
        medium_hash,
        jsonb_array_length(problems->'diagnostic_events') as event_count,
        COUNT(DISTINCT (event->>'ino')::int) as problem_inodes,
        array_agg(DISTINCT event->>'action') as actions_taken,
        array_agg(DISTINCT event->>'exception_type') as exception_types
    FROM medium,
         jsonb_array_elements(problems->'diagnostic_events') as event
    WHERE medium_hash = 'f95834a4b718f54edc7b549ca854aef8'
    GROUP BY medium_hash
)
SELECT
    m.medium_hash,
    m.medium_human,
    m.problems->'beyond_eof_detected' as beyond_eof_flag,
    m.problems->'high_error_rate'->>'rate_percent' as error_rate,
    e.event_count,
    e.problem_inodes,
    e.actions_taken,
    e.exception_types,
    (SELECT COUNT(*) FROM inode WHERE medium_hash = m.medium_hash) as total_inodes,
    (SELECT COUNT(*) FROM inode WHERE medium_hash = m.medium_hash AND copied = true) as copied_inodes,
    m.enum_done,
    m.copy_done
FROM medium m
LEFT JOIN event_summary e ON m.medium_hash = e.medium_hash
WHERE m.medium_hash = 'f95834a4b718f54edc7b549ca854aef8';
```

### Query 17: Compare diagnostic vs non-diagnostic inodes

```sql
-- For a medium, see which inodes triggered diagnostics vs copied cleanly
SELECT
    'Diagnostic intervention' as category,
    COUNT(DISTINCT (event->>'ino')::int) as count
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE medium_hash = 'f95834a4b718f54edc7b549ca854aef8'

UNION ALL

SELECT
    'Copied cleanly' as category,
    COUNT(*) as count
FROM inode
WHERE medium_hash = 'f95834a4b718f54edc7b549ca854aef8'
  AND copied = true
  AND claimed_by NOT LIKE 'DIAGNOSTIC_SKIP:%'

UNION ALL

SELECT
    'Pending/Failed' as category,
    COUNT(*) as count
FROM inode
WHERE medium_hash = 'f95834a4b718f54edc7b549ca854aef8'
  AND copied = false;
```

### Query 18: Find similar error patterns across media

```sql
-- Media with similar diagnostic patterns
WITH pattern_summary AS (
    SELECT
        medium_hash,
        array_agg(DISTINCT jsonb_array_elements_text(event->'checks')) as check_patterns,
        array_agg(DISTINCT event->>'action') as actions
    FROM medium,
         jsonb_array_elements(problems->'diagnostic_events') as event
    WHERE problems->'diagnostic_events' IS NOT NULL
    GROUP BY medium_hash
)
SELECT
    p1.medium_hash as medium_1,
    p2.medium_hash as medium_2,
    p1.check_patterns as common_checks,
    p1.actions as common_actions
FROM pattern_summary p1
JOIN pattern_summary p2 ON p1.medium_hash < p2.medium_hash
    AND p1.check_patterns && p2.check_patterns  -- Overlapping arrays
WHERE array_length(p1.check_patterns, 1) > 1
ORDER BY p1.medium_hash, p2.medium_hash;
```

### Query 19: Inodes with persistent errors

```sql
-- Inodes that triggered diagnostics and what happened
SELECT
    i.medium_hash,
    i.ino,
    i.size_bytes,
    i.copied,
    i.claimed_by,
    array_length(i.errors, 1) as error_count,
    event->>'retry_count' as diagnostic_retry,
    event->>'action' as diagnostic_action,
    event->>'timestamp' as diagnostic_time,
    event->>'checks' as checks_performed
FROM inode i
JOIN medium m ON i.medium_hash = m.medium_hash
CROSS JOIN LATERAL jsonb_array_elements(m.problems->'diagnostic_events') as event
WHERE (event->>'ino')::int = i.ino
  AND i.medium_hash = 'f95834a4b718f54edc7b549ca854aef8'
ORDER BY i.ino;
```

### Query 20: Export diagnostic data for analysis

```sql
-- Export all diagnostic data as JSON for external analysis
COPY (
    SELECT
        medium_hash,
        medium_human,
        problems
    FROM medium
    WHERE problems IS NOT NULL
) TO '/tmp/diagnostic_export.json';
```

Or as CSV for spreadsheet analysis:

```sql
-- Export flattened diagnostic events as CSV
COPY (
    SELECT
        medium_hash,
        medium_human,
        event->>'ino' as inode,
        event->>'retry_count' as retry_count,
        event->>'action' as action,
        event->>'timestamp' as timestamp,
        event->>'exception_type' as exception_type,
        event->>'exception_msg' as exception_msg,
        event->>'checks' as checks
    FROM medium,
         jsonb_array_elements(problems->'diagnostic_events') as event
    WHERE problems->'diagnostic_events' IS NOT NULL
) TO '/tmp/diagnostic_events.csv' CSV HEADER;
```

---

## Common Investigation Patterns

### Pattern 1: "Why is this medium failing to copy?"

```sql
-- Quick diagnostic check for a medium
SELECT
    m.medium_hash,
    m.medium_human,
    -- Basic stats
    (SELECT COUNT(*) FROM inode WHERE medium_hash = m.medium_hash) as total_inodes,
    (SELECT COUNT(*) FROM inode WHERE medium_hash = m.medium_hash AND copied = true) as copied,
    (SELECT COUNT(*) FROM inode WHERE medium_hash = m.medium_hash AND copied = false) as unclaimed,
    -- Problem flags
    m.problems->'beyond_eof_detected' as beyond_eof,
    m.problems->'high_error_rate'->>'rate_percent' as error_rate,
    -- Diagnostic events
    jsonb_array_length(m.problems->'diagnostic_events') as diagnostic_events,
    -- Timestamps
    m.enum_done,
    m.copy_done
FROM medium m
WHERE m.medium_hash = 'YOUR_MEDIUM_HASH';
```

### Pattern 2: "What errors are most common right now?"

```sql
-- Recent error patterns (last 7 days)
SELECT
    event->>'exception_type' as exception,
    COUNT(*) as occurrences,
    COUNT(DISTINCT medium_hash) as media_affected,
    array_agg(DISTINCT event->>'action') as actions_taken
FROM medium,
     jsonb_array_elements(problems->'diagnostic_events') as event
WHERE (event->>'timestamp')::timestamp > NOW() - INTERVAL '7 days'
GROUP BY 1
ORDER BY occurrences DESC
LIMIT 10;
```

### Pattern 3: "Is the diagnostic system working correctly?"

```sql
-- Sanity check: diagnostics should be rare on healthy media
SELECT
    'Total media' as metric,
    COUNT(*) as count
FROM medium
WHERE enum_done IS NOT NULL

UNION ALL

SELECT
    'Media with diagnostics' as metric,
    COUNT(*) as count
FROM medium
WHERE problems->'diagnostic_events' IS NOT NULL

UNION ALL

SELECT
    'Media with BEYOND_EOF' as metric,
    COUNT(*) as count
FROM medium
WHERE problems->'beyond_eof_detected' = 'true'::jsonb

UNION ALL

SELECT
    'Media with high error rate' as metric,
    COUNT(*) as count
FROM medium
WHERE problems->'high_error_rate' IS NOT NULL;
```

---

## Performance Considerations

### Index Recommendations

For better query performance on large datasets:

```sql
-- GIN index for JSONB queries
CREATE INDEX idx_medium_problems_gin ON medium USING gin(problems);

-- Partial index for media with diagnostics
CREATE INDEX idx_medium_with_diagnostics
ON medium (medium_hash)
WHERE problems->'diagnostic_events' IS NOT NULL;

-- Partial index for media with BEYOND_EOF
CREATE INDEX idx_medium_beyond_eof
ON medium (medium_hash)
WHERE problems->'beyond_eof_detected' = 'true'::jsonb;
```

**Note:** Evaluate actual query patterns before adding indexes. JSONB queries are generally fast enough without indexes for our dataset size.

---

## Maintenance Queries

### Clean up test data

```sql
-- Remove diagnostic events from test runs
UPDATE medium
SET problems = problems - 'diagnostic_events'
WHERE medium_hash IN (
    SELECT medium_hash
    FROM medium,
         jsonb_array_elements(problems->'diagnostic_events') as event
    WHERE event->>'worker_id' LIKE 'test-%'
);
```

### Archive old diagnostic events

```sql
-- Move old diagnostics to archive table (if needed)
CREATE TABLE IF NOT EXISTS medium_diagnostic_archive (
    archived_at timestamp DEFAULT NOW(),
    medium_hash varchar(64),
    medium_human varchar(256),
    problems jsonb
);

-- Archive diagnostics older than 90 days
INSERT INTO medium_diagnostic_archive (medium_hash, medium_human, problems)
SELECT
    medium_hash,
    medium_human,
    problems
FROM medium
WHERE problems->'diagnostic_events' IS NOT NULL
  AND copy_done < NOW() - INTERVAL '90 days';
```

---

## References

- **DiagnosticService implementation:** `bin/ntt_copier_diagnostics.py`
- **Worker integration:** `bin/ntt-copier.py`
- **Design documentation:** `docs/copier-diagnostic-ideas.md`
- **PostgreSQL JSONB docs:** https://www.postgresql.org/docs/current/datatype-json.html

---

**Last updated:** 2025-10-09
**Status:** Production-ready (Phase 4 complete)
