<!--
Author: PB and Claude
Date: Fri 11 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/tests/TEST-EXECUTION-BUG-007.md
-->

# BUG-007 Test Execution Guide

**Bug:** DiagnosticService Status Model Conflates Success and Failure
**Fix Date:** 2025-10-11
**Tester:** _________
**Test Date:** _________

## Pre-Test Checklist

- [ ] Backup production database (or use test database)
- [ ] Code changes reviewed and understood
- [ ] All test scripts executable: `chmod +x tests/*.py tests/*.sh`
- [ ] Database connection configured: `echo $NTT_DB_URL`
- [ ] Clean git state for potential rollback

## Test Environment

**Database:** ________________________
**Test Medium Hash:** ________________
**Worker Host:** _____________________

---

## Phase 1: Code Review (Manual)

### 1.1 Review Changes

**Files to review:**
- [ ] `sql/03-add-status-model.sql` - Migration script
- [ ] `bin/ntt_copier_diagnostics.py` - Error classification
- [ ] `bin/ntt-copier.py` - Status tracking in batch processing
- [ ] `bin/ntt-recover-failed` - Recovery tool

**Verification:**
- [ ] SQL syntax correct (no typos, valid PostgreSQL)
- [ ] CHECK constraints cover all expected values
- [ ] Python logic handles all error types
- [ ] No hardcoded values or test data

---

## Phase 2: Error Classification Unit Tests

### 2.1 Run Unit Tests

```bash
cd /home/pball/projects/ntt
python3 tests/test_error_classification.py
```

**Expected output:**
```
BUG-007 Error Classification Tests
======================================================================

Path Errors:
----------------------------------------------------------------------
✓ FileNotFoundError classified as path_error
✓ File name too long classified as path_error
✓ OSError(ENOENT) classified as path_error

I/O Errors:
----------------------------------------------------------------------
✓ Input/output error message classified as io_error
✓ Beyond EOF classified as io_error
✓ OSError(EIO) classified as io_error

[...more tests...]

Results: 7 passed, 0 failed
```

**Result:** [ ] PASS  [ ] FAIL
**Notes:**
```


```

---

## Phase 3: Database Migration Testing

### 3.1 Backup Database

```bash
# Production backup (if testing on production)
pg_dump copyjob > /tmp/copyjob-backup-$(date +%Y%m%d).sql

# Or create test database
createdb copyjob_test
pg_dump copyjob | psql copyjob_test
```

**Backup location:** _____________________
**Backup verified:** [ ] YES  [ ] NO

### 3.2 Run Migration

```bash
psql -d copyjob -f sql/03-add-status-model.sql
```

**Expected output:**
- `ALTER TABLE` commands succeed
- `CREATE INDEX` commands succeed
- `UPDATE` commands show row counts
- `COMMIT` successful

**Result:** [ ] PASS  [ ] FAIL
**Error messages (if any):**
```


```

### 3.3 Validate Migration

```bash
psql -d copyjob -f tests/test_migration_validation.sql
```

**Check all tests:**
- [ ] TEST 1: Columns exist (status, error_type)
- [ ] TEST 2: CHECK constraints present
- [ ] TEST 3: Indexes created (3 new indexes)
- [ ] TEST 4: Data migration correct
- [ ] TEST 5: No invalid states (0 rows)
- [ ] TEST 6: Status distribution reasonable
- [ ] TEST 7: Error types mostly 'unknown' (old data)
- [ ] TEST 8: Constraint enforcement works

**Result:** [ ] PASS  [ ] FAIL
**Notes:**
```


```

---

## Phase 4: Recovery Tool Testing

### 4.1 List Failures (Baseline)

```bash
./bin/ntt-recover-failed list-failures -m <test_medium_hash>
```

**Record baseline counts:**
- Retryable: _______
- Permanent: _______
- By error_type:
  - path_error: _______
  - io_error: _______
  - unknown: _______

### 4.2 Test Dry-Run

```bash
./bin/ntt-recover-failed reset-failures \
  -m <test_medium_hash> \
  --error-type path_error \
  --dry-run
```

**Expected:**
- Shows affected count
- Shows "DRY RUN - No changes made"
- Re-run list-failures shows same counts

**Result:** [ ] PASS  [ ] FAIL

### 4.3 Test Execution (Small Scale)

```bash
# Reset a small number of failures
./bin/ntt-recover-failed reset-failures \
  -m <test_medium_hash> \
  --error-type path_error \
  --execute
```

**Verify database changes:**
```sql
SELECT status, error_type, COUNT(*)
FROM inode
WHERE medium_hash = '<test_medium_hash>'
GROUP BY status, error_type;
```

**Expected:**
- path_error count reduced
- pending count increased by same amount
- errors[] arrays cleared for reset inodes

**Result:** [ ] PASS  [ ] FAIL

---

## Phase 5: Integration Testing

### 5.1 Create Test Scenarios (Optional)

If test medium has no failures, create some:

```bash
psql -d copyjob -f tests/setup_test_scenarios.sql
# Edit file to set test_medium variable
# Uncomment UPDATE statements
# Change ROLLBACK to COMMIT
```

### 5.2 Run Integration Test

```bash
./tests/test_recovery_workflow.sh <test_medium_hash>
```

**Check all tests pass:**
- [ ] TEST 1: Failures detected
- [ ] TEST 2: list-failures works
- [ ] TEST 3: Dry-run doesn't modify DB
- [ ] TEST 4: Database state verified
- [ ] TEST 6: Query correctness
- [ ] TEST 7: Documentation exists

**Result:** [ ] PASS  [ ] FAIL

---

## Phase 6: End-to-End Recovery Workflow

### 6.1 Simulate Actual Recovery (a78ccc01 scenario)

**Step 1: Identify failures**
```bash
./bin/ntt-recover-failed list-failures -m <test_medium>
```

**Step 2: Fix root cause** (example: path issues)
```sql
-- Example: Fix absolute paths (simulate a78ccc01 fix)
UPDATE path
SET path = regexp_replace(path, '^/data/fast/img/tar/extract-[^/]+/', '/')
WHERE medium_hash = '<test_medium>'
  AND path LIKE '/data/fast/img/tar/extract-%';
```

**Step 3: Reset failures**
```bash
./bin/ntt-recover-failed reset-failures \
  -m <test_medium> \
  --error-type path_error \
  --execute
```

**Step 4: Re-run copier**
```bash
sudo -E bin/ntt-copier.py -m <test_medium> --limit 100
```

**Step 5: Verify success**
```sql
-- Check files now copied
SELECT
  COUNT(*) FILTER (WHERE status = 'success') as succeeded,
  COUNT(*) FILTER (WHERE status = 'failed_retryable') as still_failed
FROM inode
WHERE medium_hash = '<test_medium>'
  AND ino IN (/* list of reset inos */);
```

**Results:**
- Files reset: _______
- Successfully copied after retry: _______
- Still failing: _______

**Result:** [ ] PASS  [ ] FAIL

---

## Phase 7: Regression Testing

### 7.1 Normal Copy Operations

**Test:** Run copier on medium without failures

```bash
sudo -E bin/ntt-copier.py -m <healthy_medium> --limit 100
```

**Verify:**
- [ ] Files copy successfully
- [ ] Status set to 'success'
- [ ] blobid populated
- [ ] No errors in logs
- [ ] Performance unchanged

**Result:** [ ] PASS  [ ] FAIL

### 7.2 Backward Compatibility

**Test:** Existing queries still work

```sql
-- Old-style query (should still work)
SELECT COUNT(*)
FROM inode
WHERE copied = false AND medium_hash = '<medium>';

-- New-style query (better)
SELECT COUNT(*)
FROM inode
WHERE status = 'pending' AND medium_hash = '<medium>';
```

**Verify:** Both return same count

**Result:** [ ] PASS  [ ] FAIL

---

## Phase 8: Performance Testing

### 8.1 Query Performance

```sql
-- Test work queue query performance
EXPLAIN ANALYZE
SELECT id, ino, size
FROM inode
WHERE medium_hash = '<test_medium>'
  AND status IN ('pending', 'failed_retryable')
  AND claimed_by IS NULL
LIMIT 100;
```

**Expected:** Uses idx_inode_status_queue, <10ms execution

**Result:** [ ] PASS  [ ] FAIL
**Execution time:** _______ ms

### 8.2 Batch Processing Performance

Monitor copier logs for batch timing:
```bash
sudo -E bin/ntt-copier.py -m <test_medium> --batch-size 100 --limit 500 2>&1 | grep TIMING_BATCH
```

**Expected:** No significant slowdown vs baseline

**Result:** [ ] PASS  [ ] FAIL

---

## Test Summary

### Results Overview

| Phase | Status | Notes |
|-------|--------|-------|
| 1. Code Review | [ ] PASS [ ] FAIL | |
| 2. Unit Tests | [ ] PASS [ ] FAIL | |
| 3. Migration | [ ] PASS [ ] FAIL | |
| 4. Recovery Tool | [ ] PASS [ ] FAIL | |
| 5. Integration | [ ] PASS [ ] FAIL | |
| 6. E2E Workflow | [ ] PASS [ ] FAIL | |
| 7. Regression | [ ] PASS [ ] FAIL | |
| 8. Performance | [ ] PASS [ ] FAIL | |

### Overall Result

**Status:** [ ] ALL PASS - Ready for production
           [ ] SOME FAIL - Needs fixes
           [ ] BLOCKED - Cannot proceed

### Issues Found

1. _______________________________________________
2. _______________________________________________
3. _______________________________________________

---

## Post-Test Actions

### If All Tests Pass

- [ ] Mark BUG-007 as "ready for testing" → "ready for production"
- [ ] Document any edge cases discovered
- [ ] Update ROLES.md if needed
- [ ] Create deployment checklist
- [ ] Schedule production deployment

### If Tests Fail

- [ ] Document failure details
- [ ] Create rollback plan
- [ ] Fix issues
- [ ] Re-run affected tests
- [ ] Update dev notes in bug report

---

## Rollback Procedure

If major issues found:

```bash
# 1. Stop all workers
sudo systemctl stop ntt-copier@*  # or kill processes

# 2. Rollback database
psql -d copyjob << 'SQL'
BEGIN;
DROP INDEX IF EXISTS idx_inode_status_queue;
DROP INDEX IF EXISTS idx_inode_error_type;
DROP INDEX IF EXISTS idx_inode_failed_by_type;
ALTER TABLE inode DROP COLUMN IF EXISTS status;
ALTER TABLE inode DROP COLUMN IF EXISTS error_type;
COMMIT;
SQL

# 3. Restore code
git checkout HEAD~1 bin/ntt-copier.py bin/ntt_copier_diagnostics.py bin/ntt-recover-failed

# 4. Restart workers
sudo systemctl start ntt-copier@*
```

---

## Sign-off

**Tester:** ___________________
**Date:** _____________________
**Approved by:** ______________
**Deployment date:** ___________
