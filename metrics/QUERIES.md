<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/metrics/QUERIES.md
-->

# Standard Database Queries for Metrics

**Purpose:** Reference for metrics-claude when collecting statistics

---

## Available Media Candidates

**Purpose:** What media are ready to process (for understanding workload)

```sql
SELECT
  medium_hash,
  medium_human,
  CASE
    WHEN copy_done IS NOT NULL THEN 'archived'
    WHEN enum_done IS NOT NULL THEN 'loaded'
    ELSE 'ready'
  END as status,
  problems IS NOT NULL as has_problems
FROM medium
WHERE enum_done IS NULL
  AND copy_done IS NULL
  AND problems IS NULL
ORDER BY medium_human;
```

---

## Per-Medium Metrics

### Inode Counts

```sql
SELECT
  COUNT(*) as total_inodes,
  COUNT(*) FILTER (WHERE copied = true) as copied,
  COUNT(*) FILTER (WHERE copied = false AND skip_reason IS NULL) as unclaimed,
  COUNT(*) FILTER (WHERE skip_reason IS NOT NULL) as skipped,
  COUNT(*) FILTER (WHERE skip_reason LIKE '%DIAGNOSTIC_SKIP%') as diagnostic_skips,
  COUNT(*) FILTER (WHERE type = 'f') as files,
  COUNT(*) FILTER (WHERE type = 'd') as directories,
  COUNT(*) FILTER (WHERE type = 'l') as symlinks
FROM inode
WHERE medium_hash = '<hash>';
```

### Path Counts

```sql
SELECT
  COUNT(*) as total_paths,
  COUNT(DISTINCT inode_id) as unique_inodes
FROM path
WHERE medium_hash = '<hash>';
```

**Note:** If paths > unique_inodes, there are hardlinks

### Deduplication Rate

```sql
SELECT
  COUNT(DISTINCT i.hash) as unique_file_hashes,
  COUNT(*) as total_files,
  (1.0 - COUNT(DISTINCT i.hash)::float / COUNT(*)::float) * 100 as dedup_rate_percent
FROM inode i
WHERE medium_hash = '<hash>'
  AND copied = true
  AND type = 'f';
```

**Interpretation:**
- dedup_rate = 0%: All files are unique
- dedup_rate = 50%: Half the files were already in by-hash/
- dedup_rate = 90%: Only 10% new unique content

### Skip Reasons Breakdown

```sql
SELECT
  skip_reason,
  COUNT(*) as count
FROM inode
WHERE medium_hash = '<hash>'
  AND skip_reason IS NOT NULL
GROUP BY skip_reason
ORDER BY count DESC;
```

### File Size Distribution

```sql
SELECT
  CASE
    WHEN size = 0 THEN 'empty'
    WHEN size < 1024 THEN '<1KB'
    WHEN size < 1024*1024 THEN '1KB-1MB'
    WHEN size < 1024*1024*10 THEN '1MB-10MB'
    WHEN size < 1024*1024*100 THEN '10MB-100MB'
    ELSE '>100MB'
  END as size_range,
  COUNT(*) as count,
  SUM(size) as total_bytes
FROM inode
WHERE medium_hash = '<hash>' AND type = 'f'
GROUP BY 1
ORDER BY
  CASE
    WHEN size_range = 'empty' THEN 1
    WHEN size_range = '<1KB' THEN 2
    WHEN size_range = '1KB-1MB' THEN 3
    WHEN size_range = '1MB-10MB' THEN 4
    WHEN size_range = '10MB-100MB' THEN 5
    ELSE 6
  END;
```

### Problems Recorded

```sql
SELECT jsonb_pretty(problems)
FROM medium
WHERE medium_hash = '<hash>' AND problems IS NOT NULL;
```

---

## Aggregate Metrics

### Overall Success Rate

```sql
SELECT
  COUNT(*) FILTER (WHERE copy_done IS NOT NULL) as archived,
  COUNT(*) FILTER (WHERE enum_done IS NOT NULL AND copy_done IS NULL) as loaded,
  COUNT(*) FILTER (WHERE enum_done IS NULL) as not_started,
  COUNT(*) FILTER (WHERE problems IS NOT NULL) as with_problems,
  COUNT(*) FILTER (WHERE copy_done IS NOT NULL)::float / NULLIF(COUNT(*), 0) * 100 as success_rate
FROM medium;
```

### Problem Pattern Analysis

```sql
SELECT
  CASE
    WHEN problems ? 'fat_errors' THEN 'FAT errors'
    WHEN problems ? 'io_errors' THEN 'I/O errors'
    WHEN problems ? 'boot_sector_corruption' THEN 'Boot sector bad'
    WHEN problems ? 'erased_disk' THEN 'Erased/unformatted'
    WHEN problems ? 'enum_failed' THEN 'Enumeration failed'
    ELSE 'Other'
  END as problem_type,
  COUNT(*) as count
FROM medium
WHERE problems IS NOT NULL
GROUP BY 1
ORDER BY count DESC;
```

### Average Processing Metrics

```sql
SELECT
  COUNT(*) as media_processed,
  AVG(EXTRACT(EPOCH FROM (copy_done - enum_done))) as avg_processing_seconds,
  MIN(EXTRACT(EPOCH FROM (copy_done - enum_done))) as min_seconds,
  MAX(EXTRACT(EPOCH FROM (copy_done - enum_done))) as max_seconds
FROM medium
WHERE copy_done IS NOT NULL AND enum_done IS NOT NULL;
```

**Note:** This assumes enum_done and copy_done timestamps bracket the processing time

### Deduplication Summary

```sql
WITH media_dedup AS (
  SELECT
    i.medium_hash,
    COUNT(DISTINCT i.hash) as unique_hashes,
    COUNT(*) as total_files
  FROM inode i
  JOIN medium m ON i.medium_hash = m.medium_hash
  WHERE m.copy_done IS NOT NULL
    AND i.copied = true
    AND i.type = 'f'
  GROUP BY i.medium_hash
)
SELECT
  COUNT(*) as media_count,
  SUM(total_files) as total_files_all_media,
  SUM(unique_hashes) as total_unique_hashes,
  (1.0 - SUM(unique_hashes)::float / SUM(total_files)::float) * 100 as overall_dedup_rate
FROM media_dedup;
```

### Storage Efficiency

```sql
SELECT
  m.medium_hash,
  m.medium_human,
  SUM(i.size) as total_file_bytes,
  COUNT(*) FILTER (WHERE i.copied = true) as files_copied
FROM medium m
JOIN inode i ON i.medium_hash = m.medium_hash
WHERE m.copy_done IS NOT NULL AND i.type = 'f'
GROUP BY m.medium_hash, m.medium_human
ORDER BY total_file_bytes DESC;
```

---

## Phase-Specific Queries

### Phase Progress

```sql
-- Assuming Phase 1 media hashes are known
WITH phase1_media AS (
  SELECT unnest(ARRAY[
    '579d3c3a476185f524b77b286c5319f5',
    '6ddf5caa4ec53c156d4f0052856ffc49',
    '6d89ac9f96d4cd174d0e9d11e19f24a8'
  ]) as hash
)
SELECT
  p.hash as medium_hash,
  m.medium_human,
  m.copy_done IS NOT NULL as completed,
  m.problems IS NOT NULL as has_problems
FROM phase1_media p
LEFT JOIN medium m ON m.medium_hash = p.hash;
```

### Recently Completed

```sql
SELECT
  medium_hash,
  medium_human,
  copy_done,
  EXTRACT(EPOCH FROM (copy_done - enum_done)) as processing_seconds
FROM medium
WHERE copy_done >= NOW() - INTERVAL '7 days'
ORDER BY copy_done DESC;
```

---

## Diagnostic Analysis

### Retry Patterns (from problems JSONB)

```sql
SELECT
  m.medium_hash,
  m.medium_human,
  m.problems->'io_errors' as io_error_count,
  m.problems->'fat_errors' as fat_error_count,
  jsonb_array_length(m.problems->'error_files') as error_file_count
FROM medium m
WHERE m.problems IS NOT NULL
  AND (
    m.problems ? 'io_errors'
    OR m.problems ? 'fat_errors'
  )
ORDER BY
  COALESCE((m.problems->'io_errors')::text::int, 0) +
  COALESCE((m.problems->'fat_errors')::text::int, 0) DESC;
```

### Partition Sizes

```sql
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables
WHERE tablename LIKE 'inode_p_%' OR tablename LIKE 'path_p_%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;
```

---

## Log Parsing Commands

### Loader Timing

```bash
# From loader output (usually stdout)
grep "Deduplication completed" <log_file> | awk '{print $NF}'

# Example output: "3.2s"
```

### Copier Diagnostics

```bash
# Find diagnostic checkpoints for a specific medium
sudo grep "DIAGNOSTIC CHECKPOINT" /var/log/ntt-copier.log | grep <hash>

# Count auto-skips
sudo grep "SKIPPED.*DIAGNOSTIC_SKIP" /var/log/ntt-copier.log | grep <hash> | wc -l

# Error patterns
sudo grep "BEYOND_EOF\|IO_ERROR\|FAT_ERROR" /var/log/ntt-copier.log | grep <hash>
```

### Copy Throughput Calculation

```bash
# Total size of archived files
total_bytes=$(sudo du -sb /data/cold/archived/<hash>/ | awk '{print $1}')

# Copy duration from processing-queue.md or logs
# Calculate: throughput = total_bytes / duration_seconds

# Example:
# 5.2GB copied in 180 seconds = 5.2*1024^3 / 180 = 30.1 MB/s
```

### Archive Compression Ratio

```bash
# Original size (before archiving)
original=$(ls -l /data/fast/img/<hash>.img | awk '{print $5}')

# Compressed size
compressed=$(ls -l /data/cold/img-read/<hash>.tar.zst | awk '{print $5}')

# Ratio
echo "scale=2; $original / $compressed" | bc
```

---

## Polling Processing Queue

### Check for New Completions

```bash
# Last completion timestamp in queue
grep "Completed:" processing-queue.md | tail -1

# Compare to database
psql -d copyjob -tc "
  SELECT medium_hash, copy_done
  FROM medium
  WHERE copy_done IS NOT NULL
  ORDER BY copy_done DESC
  LIMIT 5"

# If database has newer completions, generate metrics for those
```

### Frequency Guidance

- **Active processing:** Poll every 5-10 minutes
- **Between phases:** Poll every hour
- **Idle periods:** Poll daily
- **On explicit request:** Immediate

---

## Tips for metrics-claude

1. **Always use read-only queries** - never UPDATE or DELETE
2. **Check for NULL values** - use COALESCE() or FILTER where appropriate
3. **Pretty-print JSONB** - use jsonb_pretty() for problems column
4. **Handle empty results** - if COUNT(*) = 0, note "No data yet" in report
5. **Cross-reference logs and DB** - DB shows final state, logs show process
6. **Use pg_size_pretty()** - for human-readable sizes in partition queries

---

**References:**
- Database schema: `input/schema.sql`
- Processing workflow: `media-processing-plan-2025-10-10.md`
- Metrics template: `metrics/TEMPLATE.md`
