# NTT Copier Refactor: Implementation Design

## Overview

Complete redesign of `ntt-copier.py` from buggy Chain of Responsibility pattern to robust Claim-Analyze-Execute architecture.

**This will OVERWRITE the existing ntt-copier.py** (git preserves history).

## Critical Bugs Being Fixed

1. **`_get_all_paths_for_hash()` queries by hash instead of inode**
   - Processing 100 inodes created hardlinks for 12k+ paths
   - Violated --limit flag
   - Left inconsistent database state

2. **Scattered database commits release locks early**
   - Race conditions between workers
   - No transactional integrity

3. **No separation of concerns**
   - Analysis mixed with execution
   - Hard to test, debug, or reason about

## Architecture: Claim-Analyze-Execute

### Phase 0: Claim Work (0.5ms)

**Single atomic transaction:**

```sql
WITH candidate AS (
    SELECT medium_hash, dev, ino
    FROM inode
    TABLESAMPLE SYSTEM_ROWS(%(sample_size)s)
    WHERE copied = false 
      AND (claimed_by IS NULL OR claimed_at < NOW() - INTERVAL '1 hour')
    ORDER BY RANDOM()
    LIMIT 1
),
claimed AS (
    UPDATE inode i
    SET claimed_by = %(worker_id)s, claimed_at = NOW()
    FROM candidate c
    WHERE (i.medium_hash, i.dev, i.ino) = (c.medium_hash, c.dev, c.ino)
      AND i.claimed_by IS NULL
    RETURNING i.*
)
SELECT c.*,
       (SELECT array_agg(p.path)
        FROM path p
        WHERE (p.medium_hash, p.dev, p.ino) = (c.medium_hash, c.dev, c.ino)) as paths
FROM claimed c;
```

**Returns:**
- Work unit: `{'inode_row': {...}, 'paths': ['/path1', '/path2', ...]}`
- Or empty set if claim failed (race condition - retry)

**Auto-commits immediately** - no lock held.

### Phase 1: Analyze (No transaction)

**Goal:** Gather all information needed to execute, with NO database writes.

**Implementation:**

```python
def analyze_inode(self, work_unit: dict) -> dict:
    """Analyze an inode and create execution plan."""
    inode_row = work_unit['inode_row']
    paths = work_unit['paths']
    source_path = Path(paths[0])  # Use first path for analysis
    
    fs_type = inode_row.get('fs_type')
    if not fs_type:
        fs_type = strategies.detect_fs_type(source_path)
        # Store for later DB update
    
    # Strategy dispatch
    if fs_type == 'f':
        return self.analyze_file(work_unit, source_path)
    elif fs_type == 'd':
        return self.analyze_directory(work_unit, source_path)
    elif fs_type == 'l':
        return self.analyze_symlink(work_unit, source_path)
    elif fs_type in ['b', 'c', 'p', 's']:
        return self.analyze_special(work_unit, fs_type)
    else:
        return {'action': 'skip', 'reason': f'Unknown fs_type: {fs_type}'}


def analyze_file(self, work_unit: dict, source_path: Path) -> dict:
    """Analyze regular file - copy to temp and hash."""
    inode_row = work_unit['inode_row']
    size = inode_row['size']
    
    # Empty file special case
    if size == 0:
        return {
            'action': 'handle_empty_file',
            'hash': strategies.EMPTY_FILE_HASH,
            'paths_to_link': work_unit['paths'],
            'inode_row': inode_row,
            'mime_type': 'application/x-empty'
        }
    
    # Copy to temp and hash
    temp_path = self.get_temp_path(inode_row)
    try:
        strategies.copy_file_to_temp(source_path, temp_path, size)
        hash_value = strategies.hash_file(temp_path)
    except Exception as e:
        if temp_path.exists():
            temp_path.unlink()
        raise AnalysisError(f"Failed to copy/hash: {e}")
    
    # Detect MIME type
    mime_type = strategies.detect_mime_type(self.mime_detector, source_path)
    
    # Check if blob already exists (deduplication)
    blob_exists = self.check_blob_exists(hash_value)
    
    if blob_exists:
        temp_path.unlink()  # No longer needed
        return {
            'action': 'link_existing_file',
            'hash': hash_value,
            'paths_to_link': work_unit['paths'],
            'inode_row': inode_row,
            'mime_type': mime_type
        }
    else:
        return {
            'action': 'copy_new_file',
            'hash': hash_value,
            'paths_to_link': work_unit['paths'],
            'temp_file_path': temp_path,
            'inode_row': inode_row,
            'mime_type': mime_type
        }
```

**Other analyze functions:**

```python
def analyze_directory(self, work_unit, source_path):
    return {
        'action': 'create_directory',
        'paths': work_unit['paths'],
        'inode_row': work_unit['inode_row']
    }

def analyze_symlink(self, work_unit, source_path):
    target = strategies.read_symlink_target(source_path)
    return {
        'action': 'create_symlink',
        'target': target,
        'paths': work_unit['paths'],
        'inode_row': work_unit['inode_row']
    }

def analyze_special(self, work_unit, fs_type):
    return {
        'action': 'record_special',
        'fs_type': fs_type,
        'inode_row': work_unit['inode_row']
    }
```

### Phase 2: Execute (Fast transaction)

**Core Principle:** Filesystem first, database last.

**Implementation:**

```python
def execute_plan(self, plan: dict):
    """Execute plan - filesystem first, then database transaction."""
    
    by_hash_created_by_this_worker = False
    
    # ========================================
    # STEP 1: FILESYSTEM (outside transaction)
    # ========================================
    try:
        if plan['action'] == 'copy_new_file':
            by_hash_created_by_this_worker = self.execute_copy_new_file_fs(plan)
        
        elif plan['action'] == 'link_existing_file':
            self.execute_link_existing_file_fs(plan)
        
        elif plan['action'] == 'handle_empty_file':
            self.execute_empty_file_fs(plan)
        
        elif plan['action'] == 'create_directory':
            self.execute_directory_fs(plan)
        
        elif plan['action'] == 'create_symlink':
            self.execute_symlink_fs(plan)
        
        elif plan['action'] == 'record_special':
            pass  # No filesystem work for special files
    
    except (OSError, PermissionError) as e:
        # Filesystem failure - release claim for retry
        self.release_claim(plan['inode_row'])
        raise ExecutionError(f"Filesystem failed: {e}")
    
    # ========================================
    # STEP 2: DATABASE (atomic transaction)
    # ========================================
    try:
        with self.conn.transaction():
            if plan['action'] in ['copy_new_file', 'link_existing_file', 'handle_empty_file']:
                self.update_db_for_file(
                    plan['inode_row'],
                    plan['hash'],
                    by_hash_created_by_this_worker,
                    len(plan['paths_to_link']),
                    plan.get('mime_type')
                )
            
            elif plan['action'] == 'create_directory':
                self.update_db_for_directory(plan['inode_row'])
            
            elif plan['action'] == 'create_symlink':
                self.update_db_for_symlink(plan['inode_row'])
            
            elif plan['action'] == 'record_special':
                self.update_db_for_special(plan['inode_row'], plan['fs_type'])
    
    except Exception as e:
        # DB failure - filesystem is correct, claim stays set
        # Next run will fix DB state
        raise ExecutionError(f"Database failed: {e}")
    
    # Update stats
    self.update_stats(plan, by_hash_created_by_this_worker)


def execute_copy_new_file_fs(self, plan: dict) -> bool:
    """Filesystem operations for new file. Returns True if we created by-hash."""
    hash_val = plan['hash']
    hash_path = self.BY_HASH_ROOT / hash_val[:2] / hash_val[2:4] / hash_val
    
    hash_path.parent.mkdir(parents=True, exist_ok=True)
    
    try:
        # Atomic move
        shutil.move(str(plan['temp_file_path']), str(hash_path))
        by_hash_created = True
    except FileExistsError:
        # RACE: Another worker created it between analysis and now
        plan['temp_file_path'].unlink()
        by_hash_created = False
    
    # Create hardlinks (idempotent)
    strategies.create_hardlinks_idempotent(
        hash_path, 
        plan['paths_to_link'],
        self.ARCHIVE_ROOT
    )
    
    return by_hash_created


def execute_link_existing_file_fs(self, plan: dict):
    """Filesystem operations for deduplicated file."""
    hash_val = plan['hash']
    hash_path = self.BY_HASH_ROOT / hash_val[:2] / hash_val[2:4] / hash_val
    
    strategies.create_hardlinks_idempotent(
        hash_path,
        plan['paths_to_link'],
        self.ARCHIVE_ROOT
    )


def execute_empty_file_fs(self, plan: dict):
    """Filesystem operations for empty file."""
    hash_path = self.BY_HASH_ROOT / plan['hash'][:2] / plan['hash'][2:4] / plan['hash']
    hash_path.parent.mkdir(parents=True, exist_ok=True)
    hash_path.touch(exist_ok=True)
    
    strategies.create_hardlinks_idempotent(
        hash_path,
        plan['paths_to_link'],
        self.ARCHIVE_ROOT
    )
```

**Database update functions:**

```python
def update_db_for_file(self, inode_row, hash_val, by_hash_created, num_links, mime_type):
    """Single atomic DB transaction for file."""
    with self.conn.cursor() as cur:
        # Update inode
        cur.execute("""
            UPDATE inode
            SET hash = %s,
                copied = true,
                by_hash_created = %s,
                mime_type = COALESCE(%s, mime_type),
                processed_at = NOW(),
                claimed_by = NULL,
                claimed_at = NULL
            WHERE medium_hash = %s AND dev = %s AND ino = %s
        """, (hash_val, by_hash_created, mime_type,
              inode_row['medium_hash'], inode_row['dev'], inode_row['ino']))
        
        # Upsert blob (atomic increment)
        cur.execute("""
            INSERT INTO blobs (blobid, n_hardlinks)
            VALUES (%s, %s)
            ON CONFLICT (blobid) DO UPDATE
            SET n_hardlinks = blobs.n_hardlinks + EXCLUDED.n_hardlinks
        """, (hash_val, num_links))


def update_db_for_directory(self, inode_row):
    """Update DB for directory."""
    with self.conn.cursor() as cur:
        cur.execute("""
            UPDATE inode
            SET copied = true,
                by_hash_created = true,
                mime_type = 'inode/directory',
                processed_at = NOW(),
                claimed_by = NULL,
                claimed_at = NULL
            WHERE medium_hash = %s AND dev = %s AND ino = %s
        """, (inode_row['medium_hash'], inode_row['dev'], inode_row['ino']))
```

### Main Worker Loop

```python
def run(self):
    """Main worker loop."""
    while not self.shutdown:
        if self.limit > 0 and self.processed_count >= self.limit:
            break
        
        work_unit = self.fetch_and_claim_work_unit()
        if not work_unit:
            time.sleep(5)  # No work available
            continue
        
        self.process_work_unit(work_unit)
        self.processed_count += 1


def process_work_unit(self, work_unit: dict):
    """Process one work unit through Claim-Analyze-Execute."""
    plan = None
    temp_file_path = None
    inode_row = work_unit['inode_row']
    
    try:
        # PHASE 1: ANALYSIS
        plan = self.analyze_inode(work_unit)
        temp_file_path = plan.get('temp_file_path')
        
        if plan['action'] == 'skip':
            self.logger.info("Skipping", reason=plan['reason'])
            self.release_claim(inode_row)
            return
        
        if self.dry_run:
            self.logger.info("[DRY-RUN] Would execute plan", plan=plan)
            self.release_claim(inode_row)
            return
        
        # PHASE 2: EXECUTION
        self.execute_plan(plan)
        
    except AnalysisError as e:
        self.logger.error("Analysis failed", error=str(e))
        self.release_claim(inode_row)
        self.stats['errors'] += 1
    
    except ExecutionError as e:
        self.logger.error("Execution failed", error=str(e))
        # Don't release claim - timeout will trigger retry
        self.stats['errors'] += 1
    
    finally:
        # Cleanup temp file
        if temp_file_path and temp_file_path.exists():
            temp_file_path.unlink(missing_ok=True)
```

## File Structure Changes

### Files to Modify

1. **`ntt-copier.py`** - Complete rewrite (OVERWRITE)
   - Remove processor chain
   - Implement Claim-Analyze-Execute
   - Add --dry-run flag
   - Add --sample-size parameter

2. **`ntt_copier_strategies.py`** - New file (already created)
   - Pure functions extracted from processors
   - Testable in isolation

### Files to Mark Deprecated

1. **`ntt-copier-processors-updated.py`** - Already marked DEPRECATED
2. **`ntt-copier-processors.py`** - Mark DEPRECATED

## Command Line Interface

**Unchanged options:**
- `--limit N` - Process at most N inodes
- `--workers N` - Number of concurrent workers

**New options:**
- `--dry-run` - Log what would be done, make no changes
- `--sample-size N` - TABLESAMPLE size for work selection (default: 1000)

**Example usage:**
```bash
# Dry run test
sudo -E ntt-copier.py --dry-run --limit=10 --workers=1

# Real run
sudo -E ntt-copier.py --limit=100 --workers=5
```

## Error Handling Strategy

### Analysis Errors
- Log error
- Release claim (`claimed_by = NULL`)
- Move to next inode
- Inode remains available for retry

### Execution Errors

**Filesystem errors:**
- Log error
- Release claim
- Inode available for immediate retry

**Database errors:**
- Log error
- **Don't release claim**
- Filesystem is correct
- Claim timeout (1 hour) triggers retry
- Next worker fixes DB state

### Worker Crash
- Claim remains set with timestamp
- After 1 hour timeout, another worker can claim
- Filesystem operations are idempotent
- Retry completes successfully

## Testing Strategy

### Phase 1: Unit Tests
- Test `ntt_copier_strategies.py` functions
- No database/filesystem needed
- Fast feedback

### Phase 2: Dry-Run
```bash
./setup_test_env.sh
export PGPASSWORD='insecure_test_password'
NTT_DB_URL='postgresql://copyjob_test_user@localhost/copyjob?options=-c search_path=copyjob_test' \
NTT_ARCHIVE_ROOT=/tmp/copyjob_test/archive \
NTT_BY_HASH_ROOT=/tmp/copyjob_test/by-hash \
python ntt-copier.py --dry-run --limit=10 --workers=1
```

Verify: No database or filesystem changes

### Phase 3: Single Worker Test
```bash
# Same environment, remove --dry-run
python ntt-copier.py --limit=10 --workers=1

# Verify
psql ... -c 'SET search_path = copyjob_test; SELECT COUNT(*) FROM inode WHERE copied = true;'
# Should be 10
```

### Phase 4: Multi-Worker Test
```bash
python ntt-copier.py --limit=20 --workers=2

# Check for race conditions
# Verify blob n_hardlinks consistency
```

### Phase 5: Failure Injection
- Kill worker mid-execution
- Disk full test
- Verify recovery

## Migration Plan

1. **Backup current code** (git handles this)
2. **Complete implementation** of new ntt-copier.py
3. **Run Phase 1-2 tests** (unit tests + dry-run)
4. **Run Phase 3 test** (--limit=10, single worker)
5. **If successful:** Gradually increase limits
6. **If issues:** Git revert, analyze, fix, retry

## Success Criteria

Before production use:
- ✓ Unit tests pass
- ✓ Dry-run shows correct logic
- ✓ Single worker --limit=100 passes all verification
- ✓ Multi-worker --limit=100 handles concurrency
- ✓ Failure recovery works
- ✓ --limit=1000 completes successfully

## Implementation Checklist

- [ ] Complete ntt-copier.py rewrite
- [ ] Add --dry-run flag
- [ ] Add --sample-size parameter
- [ ] Implement all analyze_* functions
- [ ] Implement all execute_* functions
- [ ] Implement all update_db_* functions
- [ ] Add comprehensive logging
- [ ] Mark old processors as DEPRECATED
- [ ] Run Phase 1 tests
- [ ] Run Phase 2 dry-run test
- [ ] Run Phase 3 single-worker test
- [ ] Run Phase 4 multi-worker test
- [ ] Run Phase 5 failure injection
- [ ] Document results
- [ ] Production deployment (if all tests pass)
