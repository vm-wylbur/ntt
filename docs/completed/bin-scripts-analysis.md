# NTT bin/ Scripts: Analysis & Recommendations

**Analysis Date:** 2025-10-11
**Analyst:** dev-claude
**Total Scripts Analyzed:** 27
**Total Lines:** ~13,800

---

## Executive Summary

The NTT toolchain has grown organically over time, resulting in:
- ✅ **Strengths:** Modular design, clear separation of concerns in pipeline
- ⚠️ **Issues:** Multiple loader versions, duplicated code patterns, unclear deprecation status
- 🎯 **Opportunity:** ~25% reduction in codebase through consolidation

**Recommended Actions:**
1. Remove 3 deprecated loader scripts (-700 lines)
2. Extract shared code to common library (-~500 lines)
3. Consolidate worker management scripts (-~200 lines)
4. Improve testing infrastructure (new code)

---

## Critical Findings

### 1. Multiple Loader Versions ✅ RESOLVED (2025-10-11)

**Problem:** Four loader scripts with overlapping functionality but unclear deprecation status.

**Resolution:** Moved superseded loaders to `bin/deprecated/`:
- `ntt-loader-old` (176 lines) - Pre-partitioning architecture
- `ntt-loader-partitioned` (200 lines) - Merged into ntt-loader
- `ntt-loader-detach` (325 lines) - Experimental, incompatible with FK constraints

**Active loader:** `bin/ntt-loader` (326 lines) - Production, used by orchestrator

**Actions taken:**
```bash
# Moved deprecated loaders:
git mv bin/ntt-loader-old bin/deprecated/
git mv bin/ntt-loader-partitioned bin/deprecated/
git mv bin/ntt-loader-detach bin/deprecated/

# Created documentation:
bin/deprecated/README.md - Explains why each script was deprecated
```

**Result:** -700 lines removed from active codebase, clear single loader for production

**Updated documentation:**
- `bin/README.md` - Updated loader section
- `bin/deprecated/README.md` - Explains deprecation reasons

---

### 2. Worker Management Duplication

**Problem:** Worker lifecycle management split across multiple scripts.

**Scripts:**
- `ntt-copy-workers` (302 lines) - Launches workers, handles ^C
- `ntt-stop-workers` (159 lines) - Stops workers from PID file
- `ntt-dashboard` (1391 lines) - Monitors workers, shows status

**Duplication patterns:**
1. **PID file handling:**
   - ntt-copy-workers: Writes to `/tmp/ntt-workers.pids`
   - ntt-stop-workers: Reads from `/tmp/ntt-workers.pids`
   - ntt-dashboard: Reads from `/tmp/ntt-workers.pids`

2. **Signal handling:**
   - ntt-copy-workers: SIGINT → clean shutdown
   - ntt-stop-workers: SIGTERM → wait → SIGKILL

3. **Worker status checking:**
   - ntt-dashboard: Queries database for active workers
   - Could be shared function

**Recommendation:** 🟡 MEDIUM PRIORITY
- Extract to `bin/ntt_worker_utils.sh` (bash functions):
  - `write_pids_file()`
  - `read_pids_file()`
  - `shutdown_workers()` (TERM → KILL pattern)
  - `check_worker_status()`
- Source from all three scripts
- Estimated savings: ~100-150 lines

---

### 3. Database Connection Boilerplate

**Problem:** Every Python script repeats database connection setup.

**Pattern found in 11 scripts:**
```python
# Configuration from environment
DB_URL = os.environ.get('NTT_DB_URL', 'postgresql:///copyjob')

# Set PostgreSQL user
if os.geteuid() == 0:  # Running as root
    original_user = os.environ.get('SUDO_USER', os.environ.get('USER', 'pball'))
    if 'user=' not in DB_URL and '@' not in DB_URL.split('://')[1]:
        DB_URL = f"{DB_URL}?user={original_user}"

# Connect
conn = psycopg.connect(DB_URL)
```

**Scripts with this pattern:**
- ntt-copier.py
- ntt-dashboard
- ntt-list-media
- ntt-verify.py
- ntt-re-hardlink.py
- ntt-mark-excluded
- ntt-recover-failed
- ntt-parse-verify-log.py
- oneoff-count-hardlinks.py

**Recommendation:** 🟡 MEDIUM PRIORITY
- Create `bin/ntt_db.py` library module:
  ```python
  def get_db_connection():
      """Standard NTT database connection with sudo user handling"""
      # ... centralized logic
  ```
- Import in all scripts: `from ntt_db import get_db_connection`
- Estimated savings: ~15 lines × 11 scripts = ~165 lines

---

### 4. Path Configuration Duplication

**Problem:** Storage paths hardcoded/repeated across scripts.

**Pattern:**
```python
IMAGE_ROOT = '/data/fast/img'
RAW_ROOT = '/data/fast/raw'
BYHASH_ROOT = '/data/cold/by-hash'
ARCHIVE_ROOT = '/data/cold/archives'
ARCHIVED_ROOT = '/data/cold/archived'
```

**Found in:**
- ntt-copier.py
- ntt-archiver
- ntt-verify.py
- ntt-re-hardlink.py
- ntt-orchestrator
- ntt-cleanup-mounts

**Current workaround:** Environment variables, but not consistently used

**Recommendation:** 🟡 MEDIUM PRIORITY
- Create `bin/ntt_config.py`:
  ```python
  import os

  class NTTConfig:
      IMAGE_ROOT = os.getenv('IMAGE_ROOT', '/data/fast/img')
      RAW_ROOT = os.getenv('RAW_ROOT', '/data/fast/raw')
      BYHASH_ROOT = os.getenv('BYHASH_ROOT', '/data/cold/by-hash')
      ARCHIVE_ROOT = os.getenv('ARCHIVE_ROOT', '/data/cold/archives')
      ARCHIVED_ROOT = os.getenv('ARCHIVED_ROOT', '/data/cold/archived')
      DB_URL = os.getenv('NTT_DB_URL', 'postgresql:///copyjob')
  ```
- Import: `from ntt_config import NTTConfig`
- Estimated savings: ~10-15 lines per script, more importantly: **single source of truth**

---

### 5. Hash Computation Duplication

**Problem:** BLAKE3 hashing implemented in multiple places.

**Implementations:**
1. **ntt_copier_strategies.py** (lines 15-50):
   - Hybrid hash: SIZE|MODEL|SERIAL| + content
   - Used by copier

2. **ntt-verify.py** (lines 200-250):
   - Similar hybrid hash logic
   - Used by verifier

3. **ntt-re-hardlink.py**:
   - References hash but doesn't recompute

**Difference:** Copier writes during copy, Verifier reads for verification

**Recommendation:** 🟡 MEDIUM PRIORITY
- Extract to `bin/ntt_hash.py`:
  ```python
  def compute_blake3_hybrid(file_path: Path, dev: int, inode: int) -> str:
      """Compute NTT hybrid BLAKE3 hash (SIZE|MODEL|SERIAL| + content)"""
      # Centralized implementation
  ```
- Import in strategies and verify
- Ensures hash algorithm consistency
- Estimated savings: ~30-40 lines

---

### 6. Environment Wrapper Pattern

**Problem:** Sudo environment preservation handled inconsistently.

**Current:**
- `ntt-verify-sudo` (14 lines) - Wrapper for ntt-verify.py
- ntt-copier.py: Requires `sudo -E` in documentation
- ntt-orchestrator: Requires sudo

**Inconsistency:**
- Some scripts have dedicated wrappers
- Others document `sudo -E` requirement
- Risk of forgetting -E flag

**Recommendation:** 🟢 LOW PRIORITY (works, but inconsistent)
- Option A: Create wrappers for all sudo-required scripts
- Option B: Document `sudo -E` consistently
- Option C: Check environment inside scripts, error if missing

**Recommendation: Option C**
```python
def require_ntt_env():
    required = ['IMAGE_ROOT', 'BYHASH_ROOT']
    missing = [v for v in required if v not in os.environ]
    if missing:
        sys.stderr.write(f"Error: Missing environment variables: {missing}\n")
        sys.stderr.write("Run with: sudo -E {script} ...\n")
        sys.exit(1)
```

---

### 7. Logging Setup Duplication

**Problem:** Loguru configuration repeated in Python scripts.

**Pattern in 6 scripts:**
```python
from loguru import logger

logger.remove()  # Remove default handler
logger.add(
    sys.stderr,
    format="<green>{time:YYYY-MM-DD HH:mm:ss.SSS}</green> | <level>{level: <8}</level> | <level>{message}</level>",
    level="INFO"
)
```

**Scripts:**
- ntt-copier.py
- ntt-verify.py
- ntt-re-hardlink.py
- ntt-dashboard
- (others use basic logging)

**Recommendation:** 🟢 LOW PRIORITY
- Extract to `bin/ntt_logging.py`:
  ```python
  def setup_logger(level="INFO"):
      """Standard NTT logger configuration"""
      # ... centralized setup
  ```
- Estimated savings: ~10 lines per script

---

## Deprecated/Candidate for Removal

### High Confidence - Can Remove:

1. **ntt-loader-old** (176 lines)
   - Pre-partitioning architecture
   - Not referenced by any active script
   - Superseded by ntt-loader
   - **Action:** Move to bin/deprecated/

2. **ntt-loader-detach** (325 lines)
   - Experimental DETACH/ATTACH pattern
   - Documented as broken (partition-migration-postmortem)
   - Not used in production
   - **Action:** Move to bin/deprecated/

3. **ntt-loader-partitioned** (200 lines)
   - **IF** identical to ntt-loader (needs verification)
   - Not referenced by orchestrator
   - **Action:** Verify with diff, then remove if duplicate

### Medium Confidence - Investigate:

4. **oneoff-count-hardlinks.py** (217 lines)
   - Name suggests one-time use
   - No references from other scripts
   - **Action:** Ask PB if still needed, otherwise move to scripts/oneoff/

5. **ntt-parse-verify-log.py** (215 lines)
   - Utility for parsing verify logs
   - Could be integrated into ntt-verify.py as --analyze-log flag
   - **Action:** Ask PB about usage frequency

6. **ntt-raw-tail** (20 lines)
   - Simple utility, rarely used?
   - Could be `ntt-loader --tail` subcommand
   - **Action:** Keep (small enough to maintain)

### Low Confidence - Keep:

7. **diagnose-loader-hang.sql** (194 lines)
   - Diagnostic tool, useful for troubleshooting
   - **Action:** Keep, move to scripts/diagnostics/

---

## Code Quality Issues

### 1. Hardcoded Absolute Paths

**Problem:** Many scripts have hardcoded absolute paths to other scripts.

**Example from ntt-orchestrator:**
```bash
/home/pball/projects/ntt/bin/ntt-mount-helper
/home/pball/projects/ntt/bin/ntt-loader
/home/pball/projects/ntt/bin/ntt-archiver
```

**Why bad:**
- Not portable to other users/systems
- Breaks if project moves
- Makes testing difficult

**Recommendation:** 🔴 HIGH PRIORITY
```bash
# At top of each script:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Then use:
"$SCRIPT_DIR/ntt-mount-helper" ...
```

**Alternative for Python:**
```python
SCRIPT_DIR = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent
```

**Estimated effort:** ~30 minutes per script, affects 8+ scripts

---

### 2. No Shared Test Infrastructure

**Problem:** No test suite, no test utilities.

**Current state:**
- Manual integration testing only
- Bug tracking in bugs/ directory
- No unit tests, no integration test framework

**Impact:**
- Bugs caught late (production)
- Difficult to refactor with confidence
- Knowledge locked in PB's head

**Recommendation:** 🟡 MEDIUM PRIORITY (long-term)
- Create `tests/` directory structure:
  ```
  tests/
    unit/          # Unit tests for individual functions
    integration/   # Full pipeline tests
    fixtures/      # Test data
    conftest.py    # Shared pytest fixtures
  ```
- Start with high-value tests:
  - ntt_copier_strategies (hash computation)
  - ntt_copier_diagnostics (error classification)
  - Database connection handling
- Use pytest + fixtures for database tests

---

### 3. Unclear Script Status

**Problem:** No indication which scripts are production vs experimental vs deprecated.

**Current state:**
- Comments sometimes say "experimental" or "Phase 2"
- No consistent marking
- File names give no hints

**Recommendation:** 🟢 LOW PRIORITY
- Directory structure:
  ```
  bin/
    production/    # Stable, actively used
    experimental/  # In development, use with caution
    deprecated/    # Old versions, kept for reference
  ```
- OR: Prefix naming:
  ```
  ntt-loader          # Production
  ntt-loader.exp      # Experimental
  ntt-loader-old      # Deprecated (obvious)
  ```
- OR: Just rely on git and good documentation (current approach, works OK)

---

## Consolidation Opportunities

### Tier 1: High Value, Low Risk

1. **Remove duplicate loaders** (-700 lines)
   - Effort: 1 hour
   - Risk: Low (after verification)
   - Value: Eliminates confusion

2. **Extract database connection** (-165 lines)
   - Effort: 2 hours
   - Risk: Low (pure extraction)
   - Value: Single source of truth

3. **Fix hardcoded paths** (0 lines saved, but improved portability)
   - Effort: 4 hours
   - Risk: Low (search & replace)
   - Value: Project becomes portable

### Tier 2: Medium Value, Medium Risk

4. **Extract path configuration** (-100 lines)
   - Effort: 3 hours
   - Risk: Medium (affects all scripts)
   - Value: Centralized config

5. **Extract worker management** (-150 lines)
   - Effort: 4 hours
   - Risk: Medium (bash functions tricky)
   - Value: Consistent worker handling

6. **Extract hash computation** (-40 lines)
   - Effort: 2 hours
   - Risk: Medium (critical path)
   - Value: Algorithm consistency

### Tier 3: Low Value or High Risk

7. **Consolidate verify wrapper** (-14 lines)
   - Effort: 1 hour
   - Risk: Low
   - Value: Low (works fine as-is)

8. **Extract logging setup** (-60 lines)
   - Effort: 2 hours
   - Risk: Low
   - Value: Low (cosmetic)

---

## Testing Recommendations

### Phase 1: Immediate (Protect Critical Paths)

**Priority:** Hash computation, error classification, database operations

**Tests to write:**
1. **ntt_copier_strategies tests:**
   ```python
   def test_compute_hash_deterministic():
       # Same file → same hash

   def test_compute_hash_hybrid_format():
       # Verify SIZE|MODEL|SERIAL| prefix

   def test_dedupe_strategy():
       # Hardlink vs new file logic
   ```

2. **ntt_copier_diagnostics tests:**
   ```python
   def test_classify_error_path_error():
       # "No such file" → path_error

   def test_classify_error_io_error():
       # I/O error → io_error

   def test_determine_failure_status():
       # io_error → failed_permanent
       # path_error → failed_retryable
   ```

**Effort:** 2-3 days
**Value:** Catch regressions in critical business logic

### Phase 2: Integration (Catch Pipeline Issues)

**Priority:** End-to-end workflows

**Tests to write:**
1. **Small test fixture:**
   - Create tiny test.img (10MB, 50 files)
   - Run through entire pipeline
   - Verify database state at each stage

2. **Error handling:**
   - Simulate mount failures
   - Simulate I/O errors
   - Verify proper status updates

**Effort:** 3-5 days
**Value:** Catch integration bugs before production

### Phase 3: Continuous (Prevent Regression)

**Priority:** Automated testing on every commit

**Infrastructure:**
1. GitHub Actions or similar CI
2. Test database (Docker?)
3. Automated fixture generation

**Effort:** 5-10 days
**Value:** Long-term quality, confidence in refactoring

---

## Architectural Observations

### Strengths:

1. **Clear Pipeline Stages:**
   - Image → Mount → Enum → Load → Copy → Archive
   - Each stage has dedicated tool
   - Easy to understand flow

2. **Modular Design:**
   - Scripts loosely coupled
   - Can run stages independently
   - Good for debugging/recovery

3. **Separation of Concerns:**
   - Filesystem ops separate from database ops
   - Mounting separate from copying
   - Good boundaries

4. **Error Classification:**
   - DiagnosticService (BUG-007 fix)
   - Distinguishes retryable from permanent failures
   - Enables targeted recovery

### Weaknesses:

1. **No Shared Library:**
   - Every script reinvents DB connection, config, logging
   - ~500-700 lines of duplication
   - Inconsistent patterns

2. **Bash + Python Mix:**
   - Some logic in bash, some in Python
   - Harder to test bash components
   - Bash error handling less robust

3. **Hardcoded Paths:**
   - Not portable
   - Testing difficult
   - Can't easily change storage layout

4. **No Test Suite:**
   - Bugs caught late
   - Refactoring risky
   - Hard to onboard new developers

---

## Recommendations Summary

### Do Now (High Priority):

1. ✅ **Document scripts** (this document)
2. 🔴 **Remove duplicate loaders** (verify diff, then remove)
3. 🔴 **Fix hardcoded paths** (make portable)
4. 🟡 **Extract database connection** (single source of truth)

### Do Soon (Medium Priority):

5. 🟡 **Extract path configuration** (ntt_config.py)
6. 🟡 **Extract worker management** (ntt_worker_utils.sh)
7. 🟡 **Write critical path tests** (hash, error classification)

### Do Later (Nice to Have):

8. 🟢 **Extract hash computation** (ntt_hash.py)
9. 🟢 **Integration tests** (full pipeline)
10. 🟢 **CI/CD pipeline** (automated testing)

---

## Estimated Impact

**If all recommendations implemented:**

| Category | Current | After | Savings |
|----------|---------|-------|---------|
| Total lines | 13,800 | ~13,000 | -800 lines (6%) |
| Number of scripts | 27 | 23-24 | -3 to -4 scripts |
| Duplicated code | ~700 lines | ~0 | -700 lines |
| Maintainability | Medium | High | Clearer structure |
| Testability | Low | Medium | Test suite exists |
| Portability | Low | High | No hardcoded paths |

**Time investment:** ~30-40 hours of development work
**Risk level:** Low to Medium (mostly safe refactoring)
**Value:** High (clearer codebase, easier maintenance)

---

## Next Steps

**Recommend discussing with PB:**

1. **Verify loader situation:**
   ```bash
   diff bin/ntt-loader bin/ntt-loader-partitioned
   ```
   - If identical → remove one
   - If different → document differences

2. **Confirm deprecation status:**
   - ntt-loader-old: OK to archive?
   - ntt-loader-detach: OK to archive?
   - oneoff-count-hardlinks.py: Still needed?

3. **Prioritize improvements:**
   - Which recommendations align with current priorities?
   - What's blocking current work?
   - What would give most value?

4. **Plan consolidation:**
   - Implement Tier 1 improvements first (high value, low risk)
   - Add tests for critical paths
   - Gradually refactor shared code

---

## Questions for PB

1. **Loader scripts:** Are ntt-loader and ntt-loader-partitioned identical? Can we remove one?

2. **One-off scripts:** Are oneoff-count-hardlinks.py and ntt-parse-verify-log.py still needed?

3. **Priorities:** What's most painful right now? Testing? Maintenance? Onboarding?

4. **Testing appetite:** Would you use a test suite if it existed? Pytest OK?

5. **Bash vs Python:** Any preference for future scripts? Consider moving more to Python for testability?

6. **Hardcoded paths:** OK to make all paths relative to project root? Or keep absolute?

---

## Conclusion

The NTT toolchain is functional and modular, but has accumulated technical debt through organic growth. Main issues:

- **Multiple loader versions** creating confusion
- **Duplicated code** for database, config, logging
- **Hardcoded paths** limiting portability
- **No test suite** making refactoring risky

**Recommended approach:** Incremental improvement, starting with high-value, low-risk changes (remove duplicate loaders, extract shared code, fix hardcoded paths). Add tests as you go to prevent regression.

**Estimated effort:** 30-40 hours to implement all recommendations
**Expected outcome:** -800 lines, clearer structure, easier maintenance, better testability
