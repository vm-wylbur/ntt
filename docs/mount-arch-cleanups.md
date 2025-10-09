<!--
Author: PB and Claude
Date: Mon 08 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/mount-arch-cleanups.md
-->

# Mount Architecture Cleanup Plan

## Problem Statement

Investigation of FAT filesystem errors in dmesg revealed serious architectural issues with mount management:

```
FAT-fs (loop29): error, fat_bmap_cluster: request beyond EOF (i_pos 308)
```

### Root Causes Discovered

1. **Mount Race Condition**: 9 workers simultaneously mounted same medium, creating mount stack
2. **Stale Loop Devices**: Loop devices referencing deleted image inodes after ddrescue restarts
3. **No Health Tracking**: Workers mount corrupt/incomplete images (48.88% rescued) without checking
4. **Overmount Accumulation**: Multiple mounts stacked on single path consuming loop devices

### Impact

- **Mount leak**: 9+ stale mounts on `/mnt/ntt/af1349b9f5f9a1a6a0404dea36dcc949`
- **Loop device exhaustion**: 10 loop devices for one medium (loop0,1,2,7,9,14,22,25,28,29)
- **Kernel spam**: Hundreds of FAT errors flooding dmesg
- **Worker failures**: Reading from deleted/corrupt inodes → data corruption risk
- **Resource waste**: Multiple workers mounting same medium independently

## Current Architecture

```
Component Boundaries:
==================

ntt-orchestrator (bash)
  ├─> ntt-imager (ddrescue wrapper)
  ├─> ntt-enum (mount + walk filesystem once)
  └─> ntt-loader (SQL import)

ntt-copier.py (Python, long-running)
  ├─> CopyWorker.__init__()
  ├─> ensure_medium_mounted(medium_hash)
  │   ├─> Check cache (_mounted_media set)
  │   ├─> findmnt check
  │   └─> Call ntt-mount-helper
  └─> process_batch()

ntt-mount-helper (bash, sudo wrapper)
  ├─> do_mount(medium_hash, image_path)
  │   ├─> findmnt check (line 53)
  │   ├─> losetup -f --show (line 63)
  │   └─> mount -t <fs_type> (line 76)
  ├─> do_unmount(medium_hash)
  └─> do_status(medium_hash)
```

### Current Mount Flow (Broken)

```
Worker A                  Worker B                  Mount Helper
--------                  --------                  ------------
ensure_medium_mounted()
  cache miss
  findmnt → not mounted
                          ensure_medium_mounted()
                            cache miss
                            findmnt → not mounted

  call mount-helper       call mount-helper
                                                    do_mount()
                                                      findmnt → OK
                                                      exit 0

                                                    do_mount()
                                                      findmnt → not mounted
                                                      losetup loop0
                                                      mount loop0

  cache.add(medium)
                          cache.add(medium)

  ← both workers think they own the mount
  ← loop0 mounted
                                                      losetup loop1
                                                      mount loop1 (OVERMOUNT!)
```

**Race window**: Between `findmnt` check and actual mount operation.

### Architectural Issues

**Problem 1: Wrong Responsibility Assignment**
- Mount coordination logic belongs in **application layer** (copier)
- Currently scattered across copier (cache) + mount-helper (findmnt)
- No serialization between workers

**Problem 2: Sudo Boundary Too High**
- Mount-helper does coordination logic (findmnt check)
- Should only do privileged syscalls (losetup, mount, umount)
- Violates "keep sudo surface minimal" principle

**Problem 3: No Lifecycle Management**
- Loop devices created but never tracked
- No cleanup when image file recreated (new inode)
- Stale references accumulate indefinitely

**Problem 4: Missing Health Checks**
- Database has `medium.health` column but unused
- Workers blindly mount incomplete images
- Results in data corruption and kernel errors

## Clean Architecture Design

### Principle: Separation of Concerns

```
Layer           Component              Responsibilities
=====           =========              ================
Application     ntt-copier.py          - Business logic (health checks)
                                       - Coordination (flock)
                                       - Detection (overmounts, stale state)
                                       - Recovery decisions

Trust Boundary  ntt-mount-helper       - Pure system operations only
(sudo)                                 - losetup, mount, umount
                                       - Cleanup ITS OWN resources
                                       - NO coordination logic
                                       - NO health checks

Persistence     PostgreSQL             - Source of truth (medium.health)
                                       - Worker coordination (claims)
```

### Design Principles Applied

**1. Single Responsibility**
- Health tracking → Database query in copier
- Race prevention → flock in copier
- Loop cleanup → mount-helper (created them)
- Overmount recovery → copier (app policy)

**2. Minimal Sudo Surface**
- mount-helper: Only syscalls requiring root
- copier: All coordination and business logic
- Keeps security-critical code small and auditable

**3. Just-In-Time Cleanup**
- Don't rely on cron/daemon to cleanup
- Cleanup when mounting (guaranteed to run)
- Self-healing system

## Implementation Plan

### Fix 1: Add Per-Medium Locking (Application Layer)

**File**: `bin/ntt-copier.py`
**Location**: `ensure_medium_mounted()` method (currently line ~297)
**Priority**: HIGH (prevents overmounts)

**Current Code** (lines 297-318):
```python
def ensure_medium_mounted(self, medium_hash: str) -> str:
    # Check cache first
    if medium_hash in self._mounted_media:
        return f"/mnt/ntt/{medium_hash}"

    mount_point = f"/mnt/ntt/{medium_hash}"

    # Check if already mounted using findmnt
    result = subprocess.run(['findmnt', mount_point],
                          capture_output=True, text=True)

    if result.returncode == 0:
        # Already mounted
        self._mounted_media.add(medium_hash)
        return mount_point

    # ... rest of mount logic
```

**New Code**:
```python
def ensure_medium_mounted(self, medium_hash: str) -> str:
    """Ensure medium is mounted, with proper locking to prevent races.

    Uses flock per medium_hash to serialize mount operations across workers.
    Only one worker can mount a given medium at a time.
    """
    import fcntl

    # Quick cache check (no lock needed)
    if medium_hash in self._mounted_media:
        return f"/mnt/ntt/{medium_hash}"

    mount_point = f"/mnt/ntt/{medium_hash}"

    # Per-medium lock file (prevents races between workers)
    lock_dir = Path('/var/lock/ntt')
    lock_dir.mkdir(parents=True, exist_ok=True, mode=0o755)
    lock_file = lock_dir / f'mount-{medium_hash}.lock'

    # Acquire exclusive lock (blocks other workers for this medium)
    with open(lock_file, 'w') as lock_fd:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)

        # Double-check cache (another worker may have mounted while we waited)
        if medium_hash in self._mounted_media:
            return mount_point

        # Check if already mounted (another worker may have mounted)
        result = subprocess.run(['findmnt', mount_point],
                              capture_output=True, text=True)

        if result.returncode == 0:
            # Already mounted by another worker
            self._mounted_media.add(medium_hash)
            logger.info(f"Medium {medium_hash} already mounted (found after lock)")
            return mount_point

        # Check for overmounts before mounting
        overmount_count = self._detect_and_cleanup_overmounts(mount_point)
        if overmount_count > 0:
            logger.warning(f"Cleaned up {overmount_count} overmounts at {mount_point}")

        # Check medium health before mounting
        health = self._get_medium_health(medium_hash)
        if health and health != 'ok':
            raise Exception(
                f"Medium {medium_hash} health={health}, refusing to mount. "
                f"Mark inodes as EXCLUDED via mark_max_retries_exceeded()."
            )

        # ... existing mount logic (get image_path, call mount-helper, etc.)
        # ... (lines 336-351 unchanged)

        # Cache the mount
        self._mounted_media.add(medium_hash)
        return mount_point
```

**Helper Methods to Add**:

```python
def _get_medium_health(self, medium_hash: str) -> Optional[str]:
    """Check medium health status from database.

    Returns:
        'ok', 'incomplete', 'corrupt', 'failed', or None if not set
    """
    with self.conn.cursor() as cur:
        cur.execute("""
            SELECT health FROM medium WHERE medium_hash = %s
        """, (medium_hash,))
        result = cur.fetchone()
        return result['health'] if result else None

def _detect_and_cleanup_overmounts(self, mount_point: str) -> int:
    """Detect and cleanup overmounts (multiple mounts stacked on same path).

    Returns:
        Number of overmounts detected and cleaned up
    """
    # Get all mount sources for this path
    result = subprocess.run(
        ['findmnt', '-n', '-o', 'SOURCE', mount_point],
        capture_output=True, text=True
    )

    if result.returncode != 0:
        return 0  # Not mounted

    sources = [s.strip() for s in result.stdout.strip().split('\n') if s.strip()]

    if len(sources) <= 1:
        return 0  # Normal single mount

    # Overmount detected - unmount all layers
    logger.warning(f"Overmount detected at {mount_point}: {len(sources)} mounts")
    logger.warning(f"Sources: {sources}")

    # Unmount all layers (from top to bottom)
    for i in range(len(sources)):
        try:
            subprocess.run(
                ['sudo', 'umount', mount_point],
                check=True,
                capture_output=True,
                timeout=5
            )
            logger.info(f"Unmounted layer {i+1}/{len(sources)} from {mount_point}")
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            logger.error(f"Failed to unmount layer {i+1}: {e}")
            # Continue trying to unmount remaining layers

    return len(sources)
```

**Rationale**:
- **flock** serializes mount operations per medium (not global)
- Allows parallel mounts of different media
- Double-check pattern prevents redundant mounts
- Health check fails fast (before mounting corrupt images)
- Overmount cleanup is self-healing

**Testing**:
```bash
# Terminal 1-10: Run 10 workers simultaneously on same medium
for i in {1..10}; do
  sudo -E bin/ntt-copier.py --medium-hash=af1349b9 --worker-id=w$i --limit=1 &
done

# Expected: Only 1 mount in findmnt output
findmnt /mnt/ntt/af1349b9* | wc -l
# Should show: 2 lines (header + 1 mount)

# Check loop devices
losetup -l | grep af1349b9 | wc -l
# Should show: 1 loop device
```

---

### Fix 2: Cleanup Stale Loop Devices (Sudo Boundary)

**File**: `bin/ntt-mount-helper`
**Location**: Insert new function before `do_mount()`, call in `do_mount()`
**Priority**: HIGH (prevents loop exhaustion)

**Insert at line 38** (before `do_mount`):
```bash
# Cleanup stale loop devices pointing to deleted inodes
cleanup_stale_loops() {
  local medium_hash="$1"
  local image_path="$2"
  local mount_point="/mnt/ntt/$medium_hash"

  # Find all loop devices for this image (including deleted inodes)
  # Format: /dev/loop29  0  0  0  1  /data/fast/img/HASH.img (deleted)  0  512
  losetup -l | grep "$(basename "$image_path")" | while read -r line; do
    local loop_dev=$(echo "$line" | awk '{print $1}')
    local status=$(echo "$line" | grep -o "(deleted)" || echo "")

    # Only cleanup deleted inodes (active image is fine)
    if [[ -n "$status" ]]; then
      echo "Cleaning up stale loop device: $loop_dev (deleted inode)" >&2

      # Try to unmount if it's mounted at our mount point
      if findmnt -S "$loop_dev" "$mount_point" >/dev/null 2>&1; then
        echo "  Unmounting $loop_dev from $mount_point" >&2
        umount "$mount_point" 2>/dev/null || echo "  Warning: umount failed" >&2
      fi

      # Detach loop device
      if losetup -d "$loop_dev" 2>/dev/null; then
        echo "  Detached $loop_dev" >&2
      else
        echo "  Warning: Could not detach $loop_dev (may be in use)" >&2
      fi
    fi
  done
}
```

**Modify `do_mount()` at line 62** (before losetup call):
```bash
do_mount() {
  local medium_hash="$1"
  local image_path="$2"

  validate_hash "$medium_hash"

  if [[ ! -f "$image_path" ]]; then
    echo "Error: Image file not found: $image_path" >&2
    exit 1
  fi

  local mount_point="/mnt/ntt/$medium_hash"

  # Check if already mounted
  if findmnt "$mount_point" >/dev/null 2>&1; then
    echo "Already mounted at $mount_point"
    exit 0
  fi

  # NEW: Cleanup stale loop devices before mounting
  cleanup_stale_loops "$medium_hash" "$image_path"

  # Create mount point
  mkdir -p "$mount_point"

  # Create loop device (read-only)
  local loop_device
  loop_device=$(losetup -f --show -r "$image_path")

  # ... rest of existing mount logic unchanged ...
}
```

**Rationale**:
- mount-helper created loop devices, it should clean them up
- Just-in-time cleanup (runs when needed, not via cron)
- Only cleans deleted inodes (active mounts stay untouched)
- Has sudo privileges to detach
- Idempotent (safe to run multiple times)

**Edge Cases Handled**:
1. **Multiple deleted inodes**: Loops through all, cleans each
2. **Unmount fails**: Continues to try detach anyway
3. **Detach fails**: Logs warning but doesn't abort mount
4. **Active mounts**: Skips cleanup (no "deleted" marker)

**Testing**:
```bash
# Simulate stale loops: Kill worker mid-mount
sudo bin/ntt-copier.py --medium-hash=test123 --limit=1 &
WORKER_PID=$!
sleep 2
sudo kill -9 $WORKER_PID

# Check for stale loops
losetup -l | grep test123
# Should show loop device with (deleted) marker

# Run mount again - should cleanup
sudo bin/ntt-mount-helper mount test123 /data/fast/img/test123.img

# Verify cleanup happened
losetup -l | grep test123 | grep deleted
# Should show: no results (all cleaned)
```

---

### Fix 3: Add Health Column to Schema

**File**: `sql/00-schema.sql` (or create new migration)
**Priority**: MEDIUM (enables health tracking for future)

**Option A: Modify schema directly** (if no production data yet):
```sql
-- In sql/00-schema.sql, modify medium table:
CREATE TABLE medium (
    medium_hash  text PRIMARY KEY,
    medium_human text,
    added_at     timestamptz DEFAULT now(),
    health       text DEFAULT 'ok',  -- NEW: 'ok', 'incomplete', 'corrupt', 'failed'
    image_path   text,
    enum_done    timestamptz,
    copy_done    timestamptz
);
```

**Option B: Create migration** (if production data exists):
```sql
-- File: sql/add-medium-health.sql
-- Author: PB and Claude
-- Date: 2025-10-08
-- License: (c) HRDAG, 2025, GPL-2 or newer

-- Add health tracking to medium table

ALTER TABLE medium ADD COLUMN IF NOT EXISTS health text DEFAULT 'ok';

-- Document valid values (check constraint)
ALTER TABLE medium ADD CONSTRAINT medium_health_valid
  CHECK (health IN ('ok', 'incomplete', 'corrupt', 'failed', NULL));

-- Create index for health queries
CREATE INDEX IF NOT EXISTS idx_medium_health ON medium(health)
  WHERE health != 'ok';

COMMENT ON COLUMN medium.health IS
  'Image health status: ok (ready), incomplete (ddrescue < 100%), corrupt (mount errors), failed (unusable)';
```

**Health Value Semantics**:
- `'ok'`: Image complete and mountable (default)
- `'incomplete'`: ddrescue < 100% rescued (still mountable but may have errors)
- `'corrupt'`: Mount attempted but failed with errors
- `'failed'`: Completely unusable (ddrescue failed)

**Population Strategy** (future work):
```sql
-- Set health based on ddrescue success rate
-- (Run after each imaging operation)
UPDATE medium
SET health = CASE
  WHEN rescued_pct = 100 THEN 'ok'
  WHEN rescued_pct >= 95 THEN 'incomplete'
  WHEN rescued_pct >= 50 THEN 'corrupt'
  ELSE 'failed'
END
WHERE medium_hash = 'af1349b9f5f9a1a6a0404dea36dcc949';
```

**Rationale**:
- Defaults to 'ok' (backward compatible)
- Workers can check before mounting
- Orchestrator can populate based on ddrescue results
- Enables smart retry logic

---

### Fix 4: Orchestrator Health Updates (Future Enhancement)

**File**: `bin/ntt-orchestrator` (or `bin/ntt-imager`)
**Priority**: LOW (enhancement, not critical)

**After ddrescue completes** (parse ddrescue log):
```bash
# Parse ddrescue log for rescue percentage
RESCUED_PCT=$(grep "pct rescued" "$MAPFILE.log" | tail -1 | grep -o '[0-9.]*%' | tr -d '%')

# Update medium.health based on rescue success
if (( $(echo "$RESCUED_PCT == 100" | bc -l) )); then
  HEALTH="ok"
elif (( $(echo "$RESCUED_PCT >= 95" | bc -l) )); then
  HEALTH="incomplete"
elif (( $(echo "$RESCUED_PCT >= 50" | bc -l) )); then
  HEALTH="corrupt"
else
  HEALTH="failed"
fi

sudo -u "${SUDO_USER:-$USER}" psql "$DB_URL" -c "
  UPDATE medium
  SET health = '$HEALTH'
  WHERE medium_hash = '$MEDIUM_HASH'
"
```

**Rationale**:
- Orchestrator owns imaging lifecycle
- Natural place to update health after imaging
- Workers read health, don't write it

---

## Rollout Strategy

### Phase 1: Critical Fixes (Immediate)

1. **Schema Migration**
   ```bash
   sudo -u pball psql postgres:///copyjob -f sql/add-medium-health.sql
   ```

2. **Mount Helper Cleanup**
   - Add `cleanup_stale_loops()` to ntt-mount-helper
   - Call in `do_mount()` before creating new loop
   - Test with manual mount operations

3. **Copier Locking**
   - Add flock to `ensure_medium_mounted()`
   - Add `_get_medium_health()` method
   - Add `_detect_and_cleanup_overmounts()` method
   - Test with 10 parallel workers

### Phase 2: Cleanup Current Mess

```bash
# Find all stale loop devices
sudo losetup -l | grep deleted

# For each stale loop:
# 1. Unmount if mounted
# 2. Detach loop device

# Script to automate:
sudo losetup -l | grep deleted | awk '{print $1}' | while read loop; do
  echo "Cleaning $loop"
  sudo umount $loop 2>/dev/null || true
  sudo losetup -d $loop 2>/dev/null || true
done

# Verify cleanup
sudo losetup -l | grep deleted
# Should show: no results
```

### Phase 3: Health Population (Optional)

```bash
# Mark af1349b9 as corrupt (48.88% rescued)
sudo -u pball psql postgres:///copyjob -c "
  UPDATE medium
  SET health = 'corrupt'
  WHERE medium_hash = 'af1349b9f5f9a1a6a0404dea36dcc949'
"

# Workers will now refuse to mount it
```

### Phase 4: Orchestrator Integration (Future)

- Modify ntt-imager to parse ddrescue results
- Update medium.health after imaging completes
- Add orchestrator logs for health transitions

---

## Testing Plan

### Test 1: Mount Race Prevention

**Setup**:
```bash
# Reset test medium
sudo umount /mnt/ntt/test_race 2>/dev/null || true
sudo rm -rf /mnt/ntt/test_race
sudo rm /var/lock/ntt/mount-test_race.lock 2>/dev/null || true
```

**Test**:
```bash
# Launch 20 workers simultaneously
for i in {1..20}; do
  sudo -E bin/ntt-copier.py --medium-hash=test_race --worker-id=w$i --limit=1 &
done

# Wait for all to complete
wait

# Verify: Only 1 mount, 1 loop device
findmnt | grep test_race | wc -l  # Expected: 1
losetup -l | grep test_race | wc -l  # Expected: 1
```

**Expected Result**: All workers serialize on lock, only 1 mount created.

### Test 2: Stale Loop Cleanup

**Setup**:
```bash
# Create stale loop manually
sudo losetup -f --show /data/fast/img/test_stale.img
# Note the loop device (e.g., loop30)

# Delete the image file (creates deleted inode)
sudo rm /data/fast/img/test_stale.img
sudo touch /data/fast/img/test_stale.img  # New inode

# Verify stale loop exists
sudo losetup -l | grep test_stale | grep deleted
```

**Test**:
```bash
# Mount via helper (should cleanup stale loop)
sudo bin/ntt-mount-helper mount test_stale /data/fast/img/test_stale.img
```

**Expected Result**:
- Old loop detached automatically
- New loop created for new inode
- Mount succeeds

### Test 3: Health Check Enforcement

**Setup**:
```bash
# Mark medium as corrupt
sudo -u pball psql postgres:///copyjob -c "
  UPDATE medium SET health = 'corrupt' WHERE medium_hash = 'test_health'
"
```

**Test**:
```bash
# Try to mount
sudo -E bin/ntt-copier.py --medium-hash=test_health --limit=1
```

**Expected Result**:
- Worker reads health='corrupt'
- Raises exception before mount attempt
- No mount created
- Worker marks inodes as EXCLUDED

---

## Monitoring and Debugging

### Key Metrics to Track

```bash
# Current overmounts
findmnt | awk '{print $1}' | sort | uniq -d | wc -l

# Stale loop devices
sudo losetup -l | grep deleted | wc -l

# Lock contention (workers waiting for locks)
ls -la /var/lock/ntt/*.lock | wc -l

# Unhealthy media
sudo -u pball psql postgres:///copyjob -c "
  SELECT health, COUNT(*)
  FROM medium
  GROUP BY health
"
```

### Debug Commands

```bash
# Show all mounts for a medium
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /mnt/ntt/HASH

# Show all loop devices for an image
sudo losetup -l | grep HASH

# Check lock file age (workers hung?)
stat /var/lock/ntt/mount-HASH.lock

# Force cleanup of specific medium
sudo bin/ntt-mount-helper unmount HASH
```

---

## Architectural Decisions Record

### Decision 1: flock vs Database Locking

**Options**:
- A) flock on /var/lock files (CHOSEN)
- B) Database advisory locks
- C) Redis/external lock service

**Rationale**:
- flock is simpler (no external dependencies)
- Automatically released on process death
- Per-medium locking allows parallelism
- Database locks would add query overhead

### Decision 2: Just-In-Time vs Background Cleanup

**Options**:
- A) Cleanup in mount-helper when mounting (CHOSEN)
- B) Cron job to cleanup stale loops
- C) Separate cleanup daemon

**Rationale**:
- Just-in-time is self-healing
- No cron scheduling complexity
- Runs only when needed (mount operation)
- mount-helper has sudo privileges already

### Decision 3: Health in Database vs Filesystem

**Options**:
- A) medium.health column in database (CHOSEN)
- B) .health file next to image
- C) xattr on image file

**Rationale**:
- Database is already source of truth
- Workers query database for image_path anyway
- No filesystem permission issues
- Easy to query/report on health

### Decision 4: Application vs Helper Responsibility

**Options**:
- A) Coordination in copier, syscalls in helper (CHOSEN)
- B) All logic in helper
- C) All logic in copier (no helper)

**Rationale**:
- Minimizes sudo surface (security)
- Application layer best for coordination
- Helper stays simple and auditable
- Clear separation of concerns

---

## Future Enhancements

### 1. Mount Pool Management

Instead of each worker mounting independently, use a shared mount pool:

```python
class MountPool:
    """Shared mount pool to reduce redundant mounts."""

    def __init__(self, max_concurrent_mounts=10):
        self.max_concurrent_mounts = max_concurrent_mounts
        self.semaphore = threading.Semaphore(max_concurrent_mounts)

    def mount(self, medium_hash):
        with self.semaphore:
            # Only allow N concurrent mount operations
            return ensure_medium_mounted(medium_hash)
```

**Benefit**: Limits total mounts across all workers.

### 2. Lazy Unmount on Worker Exit

Currently mounts persist after worker dies. Could add cleanup:

```python
def __del__(self):
    """Cleanup mounts on worker shutdown."""
    for medium_hash in self._mounted_media:
        subprocess.run(['sudo', 'bin/ntt-mount-helper', 'unmount', medium_hash])
```

**Tradeoff**: Unmount may interfere with other workers.

### 3. Health Monitoring Daemon

Periodic health checks could detect corruption:

```bash
# Check mounted filesystems for errors
dmesg -T | grep -E "(FAT-fs|ext4-fs|error)" | while read line; do
  # Parse mount point from error
  # Update medium.health = 'corrupt'
done
```

**Benefit**: Proactive corruption detection.

### 4. Metrics Export

Export mount metrics to Prometheus:

```python
# ntt_mounts_active{medium_hash="HASH"} 1
# ntt_mount_races_total 42
# ntt_stale_loops_cleaned_total 17
```

**Benefit**: Better operational visibility.

---

## Success Criteria

After implementing these fixes:

1. **No Overmounts**
   - `findmnt` shows max 1 mount per medium
   - losetup shows max 1 loop per medium

2. **No Stale Loops**
   - `losetup -l | grep deleted` shows 0 results
   - Old loop devices auto-cleanup before new mounts

3. **No Corrupt Mounts**
   - Workers refuse to mount health != 'ok'
   - FAT errors eliminated from dmesg

4. **Deterministic Behavior**
   - 10 workers mounting same medium = 1 mount
   - Repeated runs show consistent results

5. **Clean Logs**
   - "Overmount detected" appears 0 times
   - "Stale loop cleaned" appears during transitions only

---

## References

- Investigation: `/home/pball/projects/ntt/docs/loader-hang-investigation-2025-10-07.md`
- Current schema: `/home/pball/projects/ntt/sql/00-schema.sql`
- Mount helper: `/home/pball/projects/ntt/bin/ntt-mount-helper`
- Copy worker: `/home/pball/projects/ntt/bin/ntt-copier.py`

---

## Implementation Checklist

For the next Claude implementing these fixes:

- [ ] Read this entire document carefully
- [ ] Understand current architecture (mount flow diagram)
- [ ] Review current code: ntt-mount-helper, ntt-copier.py
- [ ] Create SQL migration: add medium.health column
- [ ] Modify ntt-mount-helper: add cleanup_stale_loops()
- [ ] Modify ntt-copier.py: add flock, health checks, overmount detection
- [ ] Test mount races (10 concurrent workers)
- [ ] Test stale loop cleanup (create deleted inode scenario)
- [ ] Test health enforcement (mark medium corrupt, verify refusal)
- [ ] Cleanup current stale loops on production system
- [ ] Monitor dmesg for FAT errors (should be 0)
- [ ] Document any deviations from this plan

**Estimated Implementation Time**: 2-3 hours

**Risk Level**: Medium (touching critical mount path, requires careful testing)

**Rollback Plan**: Keep ntt-mount-helper.bak, can revert if issues arise
