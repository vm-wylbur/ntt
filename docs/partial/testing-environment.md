# NTT Copier Test Environment

## Overview

Isolated test environment for safely testing the new Claim-Analyze-Execute architecture without risk to production data.

## Safety Features

1. **Dedicated test user** (`copyjob_test_user`) with NO access to public schema
2. **Isolated test schema** (`copyjob_test`) - complete separation from production
3. **Test filesystem** (`/tmp/copyjob_test/`) - separate from production archive
4. **Explicit REVOKE** on public schema - prevents accidental production access

## Current Test Data

```
Database: copyjob
Schema:   copyjob_test
User:     copyjob_test_user
Root:     /tmp/copyjob_test

Test data:
  - 67 inodes in database
  - 70 paths in database  
  - 1 test medium
  - ~70 test files on disk
```

### Test File Variety

- **Empty files** (5) - tests 0-byte file handling
- **Duplicates** (10) - identical content for deduplication testing
- **Unique text files** (20) - various sizes
- **Binary files** (10) - non-text content
- **Directories** (10+) - including nested structures
- **Symlinks** (7) - 5 valid, 2 broken
- **Hardlinks** (4) - same inode, multiple paths

## Setup

```bash
cd /home/pball/projects/ntt/bin
./setup_test_env.sh
```

This script:
1. Drops previous test schema/user (if exists)
2. Creates new test user with restricted permissions
3. Copies production schema structure to test schema
4. Grants permissions on test schema only
5. Creates test filesystem structure
6. Generates diverse test files
7. Populates database with test records

## Running Tests

### Verify Test Environment

```bash
# Check database
PGPASSWORD='insecure_test_password' psql -U copyjob_test_user -h localhost copyjob -c \
  'SET search_path = copyjob_test; 
   SELECT COUNT(*) as inodes FROM inode;
   SELECT COUNT(*) as paths FROM path;'

# Check filesystem
ls -la /tmp/copyjob_test/source/
```

### Run Copier Tests

```bash
# Set environment for test mode
export PGPASSWORD='insecure_test_password'
export NTT_DB_URL='postgresql://copyjob_test_user@localhost/copyjob?options=-c search_path=copyjob_test'
export NTT_ARCHIVE_ROOT=/tmp/copyjob_test/archive
export NTT_BY_HASH_ROOT=/tmp/copyjob_test/by-hash

# Run copier (when implemented)
python ntt-copier.py --limit=10 --workers=1
```

## Verification Queries

After running tests, verify state:

```sql
-- Set search path
SET search_path = copyjob_test;

-- Check processing progress
SELECT 
    COUNT(*) FILTER (WHERE copied = true) as copied,
    COUNT(*) FILTER (WHERE copied = false) as uncoped,
    COUNT(*) FILTER (WHERE claimed_by IS NOT NULL) as claimed
FROM inode;

-- Check for orphaned claims
SELECT COUNT(*) FROM inode WHERE claimed_by IS NOT NULL;
-- Expected: 0 (after successful run)

-- Check blob consistency
SELECT b.blobid, b.n_hardlinks, COUNT(*) as actual
FROM blobs b
JOIN inode i ON i.hash = b.blobid
WHERE i.copied = true
GROUP BY b.blobid, b.n_hardlinks
HAVING b.n_hardlinks != COUNT(*);
-- Expected: 0 rows (perfect consistency)
```

## Cleanup

```bash
# Complete reset - re-run setup script
./setup_test_env.sh

# Or manual cleanup
psql copyjob -c "DROP SCHEMA IF EXISTS copyjob_test CASCADE;"
rm -rf /tmp/copyjob_test
```

## Next Steps

### Phase 1: Unit Tests
- Test individual functions in isolation
- `detect_fs_type()`, `hash_file()`, etc.
- No database/filesystem required

### Phase 2: Dry-Run Testing
- Implement `--dry-run` flag
- Test full pipeline without writes
- Verify logic correctness

### Phase 3: Controlled Wet Runs
- Start with `--limit=10 --workers=1`
- Verify all database state after each run
- Gradually increase to multi-worker tests

### Phase 4: Failure Injection
- Test crash recovery
- Test disk full scenarios
- Verify transaction rollback

## Success Criteria

Before production use:
- ✓ All unit tests pass
- ✓ Dry-run shows correct behavior
- ✓ Single worker runs pass all verification queries
- ✓ Multi-worker runs handle concurrency correctly
- ✓ Failure injection demonstrates proper recovery
- ✓ Scale test (--limit=1000, --workers=10) succeeds

## Notes

- Test environment is completely isolated from production
- Test user CANNOT access public schema (safety guarantee)
- Test data regenerated each setup (reproducible tests)
- Use `-h localhost` for psql to avoid peer auth issues
