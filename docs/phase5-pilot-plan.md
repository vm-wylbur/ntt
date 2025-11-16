<!--
Author: PB and Claude
Date: Wed 6 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/phase5-pilot-plan.md
-->

# Phase 5 Plan: Pilot Run

**Target Date:** 2025-11-06 to 2025-11-11
**Status:** Ready to Execute
**Scope:** 1,000 blobs stratified by format

---

## Objectives

1. **Validate pipeline:** Confirm extraction works with real production data
2. **Measure performance:** Determine realistic processing rate (blobs/hour)
3. **Identify failures:** Find edge cases, corrupt archives, handler bugs
4. **Measure deduplication:** Actual dedup rate vs estimates
5. **Tune parameters:** Batch sizes, worker count, queue behavior
6. **Validate data quality:** Spot-check extracted files for correctness

---

## Pre-Flight Checklist

### System Requirements

- [ ] PostgreSQL has space for ~1000 new medium records + partitions
- [ ] Redis running and accessible
- [ ] `/data/fast/ntt/by-hash` has space (estimate: 100MB - 1GB)
- [ ] `/data/fast/tmp` has space for extraction temp files (estimate: 10GB)
- [ ] Log directory `/var/log/ntt/` writable

### Code Verification

- [ ] All 4 integration tests passing:
  ```bash
  ./tests/test-extraction-gzip.sh
  ./tests/test-extraction-tar.sh
  ./tests/test-extraction-zip.sh
  ./tests/test-extraction-tar-gz.sh
  ```

- [ ] ntt-extractor.py commands working:
  ```bash
  ./bin/ntt-extractor.py --help
  ./bin/ntt-extractor.py status
  ```

### Database State

- [ ] Check extractable blob count by format:
  ```sql
  SELECT mime_type, COUNT(*)
  FROM blobs
  WHERE mime_type IN (
    'application/gzip',
    'application/x-bzip2',
    'application/x-tar',
    'application/zip',
    'application/x-xz',
    'application/x-7z-compressed',
    'application/vnd.rar'
  )
  GROUP BY mime_type
  ORDER BY COUNT(*) DESC;
  ```

- [ ] Verify no orphaned extracted media from testing:
  ```sql
  SELECT COUNT(*)
  FROM medium
  WHERE medium_type = 'extracted';
  ```

---

## Sample Selection Strategy

### Stratified Random Sample

Goal: 1,000 blobs with balanced representation across formats

**Tested formats** (prioritize these):
- `application/gzip` - 250 blobs
- `application/x-tar` - 250 blobs
- `application/zip` - 250 blobs

**Untested formats** (smaller samples for discovery):
- `application/x-bzip2` - 50 blobs
- `application/x-xz` - 50 blobs
- `application/x-7z-compressed` - 50 blobs
- `application/vnd.rar` - 50 blobs
- Others - 50 blobs

### Selection Query

```sql
-- Create pilot sample
WITH stratified AS (
  SELECT
    blobid,
    mime_type,
    ROW_NUMBER() OVER (
      PARTITION BY mime_type
      ORDER BY RANDOM()
    ) as rn,
    CASE
      WHEN mime_type IN ('application/gzip', 'application/x-tar', 'application/zip')
        THEN 250
      ELSE 50
    END as target_count
  FROM blobs
  WHERE mime_type IN (
    'application/gzip',
    'application/x-bzip2',
    'application/x-tar',
    'application/zip',
    'application/x-xz',
    'application/x-7z-compressed',
    'application/vnd.rar'
  )
)
SELECT blobid, mime_type
FROM stratified
WHERE rn <= target_count
ORDER BY mime_type, rn;
```

**Save to file for reproducibility:**
```bash
psql -d copyjob -tAF',' -c "<query>" > /tmp/pilot-sample-1000.csv
```

---

## Execution Plan

### Step 1: Initialize Queue

```bash
# Reset any previous pilot state
redis-cli del "ntt:extraction:processed"
redis-cli del "ntt:extraction:priority"
redis-cli del "ntt:extraction:nested"

# Initialize from pilot sample
./bin/ntt-extractor.py init --limit 1000 \
  --format-filter "application/gzip,application/x-tar,application/zip"

# Check queue status
./bin/ntt-extractor.py status
```

### Step 2: Start Monitoring

**Terminal 1 - Log monitoring:**
```bash
tail -f /var/log/ntt/extractor.jsonl | jq -r '
  select(.level == "INFO" or .level == "ERROR") |
  "\(.time) | \(.level) | \(.message)"
'
```

**Terminal 2 - Progress tracking:**
```bash
watch -n 30 './bin/ntt-extractor.py status'
```

**Terminal 3 - Database metrics:**
```bash
watch -n 60 'psql -d copyjob -c "
  SELECT
    mime_type,
    COUNT(*) FILTER (WHERE extracted_at IS NOT NULL) as completed,
    COUNT(*) as total,
    ROUND(100.0 * COUNT(*) FILTER (WHERE extracted_at IS NOT NULL) / COUNT(*), 1) as pct_complete
  FROM blobs
  WHERE mime_type IN (
    '\''application/gzip'\'',
    '\''application/x-tar'\'',
    '\''application/zip'\''
  )
  GROUP BY mime_type
"'
```

### Step 3: Run Extraction

**Single worker test:**
```bash
# Start with 1 worker to catch any immediate issues
./bin/ntt-extractor.py run --max-jobs 10
```

**If successful, scale to multi-worker:**
```bash
# Run 4 workers in parallel
for i in {1..4}; do
  ./bin/ntt-extractor.py run --worker-id $i &
done

# Wait for completion
wait
```

### Step 4: Handle Errors

**If errors occur:**

1. Check error patterns in logs:
   ```bash
   tail -100 /var/log/ntt/extractor.jsonl | jq 'select(.level == "ERROR")'
   ```

2. Recover stuck jobs:
   ```bash
   ./bin/ntt-extractor.py recover
   ```

3. Check failed blobs:
   ```sql
   SELECT blobid, mime_type, extraction_error
   FROM blobs
   WHERE extraction_status = 'failed'
   LIMIT 10;
   ```

4. For persistent failures, mark format as problematic and skip:
   ```bash
   # Re-init without problematic format
   ./bin/ntt-extractor.py init --limit 1000 \
     --format-filter "application/gzip,application/x-tar"
   ```

---

## Metrics to Collect

### 1. Processing Performance

```sql
-- Overall processing rate
SELECT
  COUNT(*) as blobs_processed,
  MIN(extracted_at) as start_time,
  MAX(extracted_at) as end_time,
  EXTRACT(EPOCH FROM (MAX(extracted_at) - MIN(extracted_at))) / 3600 as hours,
  ROUND(COUNT(*) / NULLIF(EXTRACT(EPOCH FROM (MAX(extracted_at) - MIN(extracted_at))) / 3600, 0), 1) as blobs_per_hour
FROM blobs
WHERE extracted_at IS NOT NULL
  AND extracted_at > NOW() - INTERVAL '1 day';  -- Adjust timeframe
```

**Expected rate:** 50-200 blobs/hour (unknown, first run)

### 2. Success/Failure Rates

```sql
-- Success rate by format
SELECT
  mime_type,
  COUNT(*) FILTER (WHERE extracted_at IS NOT NULL) as completed,
  COUNT(*) FILTER (WHERE extraction_error IS NOT NULL) as failed,
  COUNT(*) as total,
  ROUND(100.0 * COUNT(*) FILTER (WHERE extracted_at IS NOT NULL) / COUNT(*), 1) as success_pct
FROM blobs
WHERE mime_type IN (
  'application/gzip',
  'application/x-tar',
  'application/zip'
)
GROUP BY mime_type
ORDER BY success_pct DESC;
```

**Target:** >95% success rate for tested formats

### 3. File Extraction Counts

```sql
-- Files extracted per archive
SELECT
  mime_type,
  COUNT(*) as archives,
  SUM(files_extracted) as total_files,
  ROUND(AVG(files_extracted), 1) as avg_files_per_archive,
  MAX(files_extracted) as max_files
FROM blobs
WHERE extracted_at IS NOT NULL
GROUP BY mime_type
ORDER BY archives DESC;
```

### 4. Deduplication Rate

```sql
-- How many extracted files were duplicates?
WITH extracted_files AS (
  SELECT i.blobid, COUNT(*) as occurrence_count
  FROM inode i
  JOIN medium m ON m.medium_hash = i.medium_hash
  WHERE m.medium_type = 'extracted'
    AND m.extracted_at > NOW() - INTERVAL '1 day'
  GROUP BY i.blobid
)
SELECT
  COUNT(*) as total_unique_blobs,
  SUM(occurrence_count) as total_file_instances,
  SUM(occurrence_count) - COUNT(*) as duplicate_instances,
  ROUND(100.0 * (SUM(occurrence_count) - COUNT(*)) / SUM(occurrence_count), 1) as dedup_pct
FROM extracted_files;
```

**Expected:** 10-40% deduplication (archives often contain similar files)

### 5. Nested Archive Processing

```sql
-- How many archives contained nested archives?
SELECT
  COUNT(DISTINCT parent.source_blobid) as archives_with_nested,
  COUNT(DISTINCT child.medium_hash) as nested_archives_found,
  ROUND(AVG(child_count), 1) as avg_nested_per_archive
FROM medium parent
JOIN inode i ON i.medium_hash = parent.medium_hash
JOIN medium child ON child.source_blobid = i.blobid
JOIN (
  SELECT source_blobid, COUNT(*) as child_count
  FROM medium
  WHERE medium_type = 'extracted'
  GROUP BY source_blobid
) counts ON counts.source_blobid = parent.source_blobid
WHERE parent.medium_type = 'extracted'
  AND child.medium_type = 'extracted';
```

### 6. Storage Impact

```sql
-- Total storage used for extracted files
SELECT
  pg_size_pretty(SUM(i.size)::bigint) as total_extracted_size,
  COUNT(DISTINCT i.blobid) as unique_files,
  pg_size_pretty(AVG(i.size)::bigint) as avg_file_size
FROM inode i
JOIN medium m ON m.medium_hash = i.medium_hash
WHERE m.medium_type = 'extracted'
  AND m.extracted_at > NOW() - INTERVAL '1 day';
```

### 7. Intermediate Overhead

```sql
-- How much temporary storage was created? (tar from tar.gz, etc)
-- Note: is_intermediate column needs to be added if tracking this
SELECT
  COUNT(*) as total_blobs_created,
  COUNT(*) FILTER (WHERE blobid IN (
    SELECT DISTINCT source_blobid FROM medium WHERE medium_type = 'extracted'
  )) as intermediate_blobs,
  ROUND(100.0 * COUNT(*) FILTER (WHERE blobid IN (
    SELECT DISTINCT source_blobid FROM medium WHERE medium_type = 'extracted'
  )) / COUNT(*), 1) as intermediate_pct
FROM inode i
JOIN medium m ON m.medium_hash = i.medium_hash
WHERE m.medium_type = 'extracted';
```

---

## Manual Validation

### Spot Check Samples

Select 10 random extracted files and verify content:

```bash
# Get random sample
psql -d copyjob -tAc "
  SELECT i.blobid, i.mime_type, encode(p.path, 'escape') as path
  FROM inode i
  JOIN path p ON p.medium_hash = i.medium_hash AND p.ino = i.ino
  JOIN medium m ON m.medium_hash = i.medium_hash
  WHERE m.medium_type = 'extracted'
    AND m.extracted_at > NOW() - INTERVAL '1 day'
  ORDER BY RANDOM()
  LIMIT 10
" > /tmp/validation-sample.txt

# For each, check:
# 1. File exists in by-hash
# 2. MIME type detection matches
# 3. File is readable/valid

# Example:
BLOBID="<from sample>"
ls -lh /data/fast/ntt/by-hash/${BLOBID:0:2}/${BLOBID:2:2}/${BLOBID}
file /data/fast/ntt/by-hash/${BLOBID:0:2}/${BLOBID:2:2}/${BLOBID}
```

### Verify Nested Archive Processing

Check a tar.gz extraction manually:

```sql
-- Find a tar.gz that was extracted
SELECT
  parent.medium_hash as gzip_medium,
  parent.source_blobid as original_targz,
  child.medium_hash as tar_medium,
  child.source_blobid as intermediate_tar,
  COUNT(i.blobid) as files_in_tar
FROM medium parent
JOIN inode pi ON pi.medium_hash = parent.medium_hash
JOIN medium child ON child.source_blobid = pi.blobid
JOIN inode i ON i.medium_hash = child.medium_hash
WHERE parent.extraction_method = 'gzip'
  AND child.extraction_method = 'tar'
GROUP BY parent.medium_hash, parent.source_blobid, child.medium_hash, child.source_blobid
LIMIT 1;
```

Manually verify the chain: original .tar.gz → intermediate .tar → final files

---

## Success Criteria

### Must Pass

- [ ] >95% success rate for tested formats (gzip, tar, zip)
- [ ] No database corruption or partition errors
- [ ] No Redis data loss
- [ ] Processing completes in <24 hours for 1000 blobs
- [ ] Spot-check validation: 10/10 files correct

### Should Pass

- [ ] >80% success rate for untested formats (bzip2, xz, 7z, rar)
- [ ] Nested archive processing works (tar.gz → tar → files)
- [ ] Deduplication rate 10-40%
- [ ] No memory leaks or runaway processes

### Nice to Have

- [ ] Processing rate >100 blobs/hour
- [ ] Multi-worker coordination works smoothly
- [ ] Graceful handling of corrupt archives

---

## Rollback Plan

### If Pilot Fails

1. **Stop extraction:**
   ```bash
   pkill -f ntt-extractor.py
   redis-cli flushall  # Clear queue
   ```

2. **Assess damage:**
   ```sql
   -- Count extracted media
   SELECT COUNT(*) FROM medium WHERE medium_type = 'extracted';

   -- Check for orphaned partitions
   SELECT tablename FROM pg_tables
   WHERE tablename LIKE 'inode_%' OR tablename LIKE 'path_%';
   ```

3. **Clean up if needed:**
   ```sql
   -- Delete all extracted media from pilot
   DO $$
   DECLARE
     med RECORD;
   BEGIN
     FOR med IN
       SELECT medium_hash
       FROM medium
       WHERE medium_type = 'extracted'
         AND extracted_at > NOW() - INTERVAL '1 day'
     LOOP
       EXECUTE format('DELETE FROM inode WHERE medium_hash = %L', med.medium_hash);
       EXECUTE format('DELETE FROM path WHERE medium_hash = %L', med.medium_hash);
       EXECUTE format('DROP TABLE IF EXISTS inode_%I', med.medium_hash);
       EXECUTE format('DROP TABLE IF EXISTS path_%I', med.medium_hash);
       DELETE FROM medium WHERE medium_hash = med.medium_hash;
     END LOOP;
   END $$;
   ```

4. **Preserve debugging info:**
   ```bash
   # Save logs
   cp /var/log/ntt/extractor.jsonl /tmp/pilot-failure-$(date +%Y%m%d-%H%M%S).jsonl

   # Save failed blobs list
   psql -d copyjob -c "COPY (
     SELECT blobid, mime_type, extraction_error
     FROM blobs
     WHERE extraction_status = 'failed'
   ) TO '/tmp/pilot-failures.csv' CSV HEADER"
   ```

5. **Document issues and adjust plan**

---

## Post-Pilot Actions

### If Successful

1. Document findings in `docs/phase5-pilot-report.md`
2. Update estimates for full production run (Phase 7)
3. Identify any handler bugs to fix
4. Tune parameters (batch size, worker count)
5. Plan Phase 6 validation

### If Issues Found

1. Fix critical bugs
2. Re-run pilot with fixes
3. Adjust scope if needed (skip problematic formats)
4. Update risk assessment

---

## Timeline

**Day 1:** Pre-flight checks, sample selection
**Day 2:** Run pilot (1000 blobs)
**Day 3:** Collect metrics, manual validation
**Day 4:** Analyze results, document findings
**Day 5:** Fix any issues, re-test if needed

**Total:** 3-5 days depending on results
