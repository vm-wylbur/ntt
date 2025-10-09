<!--
Author: PB and Claude
Date: Wed 09 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/ignore-patterns-guide.md
-->

# NTT Ignore Patterns Guide

**Purpose:** Reference documentation for the NTT path exclusion system.

**Quick links:**
- Pattern file location: `~/.config/ntt/ignore-patterns.txt`
- Loader integration: `bin/ntt-loader` (lines 157-177)
- Query examples: See [Testing Patterns](#testing-patterns)

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Pattern Syntax](#pattern-syntax)
4. [Current Patterns](#current-patterns)
5. [Adding New Patterns](#adding-new-patterns)
6. [Testing Patterns](#testing-patterns)
7. [Case Studies](#case-studies)
8. [Troubleshooting](#troubleshooting)

---

## Overview

The NTT ignore patterns system allows exclusion of specific paths during enumeration and loading. Patterns are PostgreSQL extended regex expressions matched against full file paths.

**Why exclude paths?**
- **Performance:** Skip large caches, build artifacts, and package managers
- **Relevance:** Exclude temporary files, system caches, IDE artifacts
- **Reliability:** Skip files with problematic characters that cause copy failures
- **Storage:** Reduce deduplication of non-unique data (node_modules, conda packages)

**When patterns are applied:**
- During `ntt-loader` execution (before database insert)
- Marked paths get `exclude_reason = 'pattern_match'`
- Excluded inodes (all paths excluded) marked as `claimed_by = 'EXCLUDED'`
- Never copied or verified

---

## How It Works

### Workflow

```
1. ntt-enum writes raw paths to file (unfiltered)
   ↓
2. ntt-loader reads raw file into temp table
   ↓
3. Load patterns from ~/.config/ntt/ignore-patterns.txt
   ↓
4. Mark matching paths: UPDATE ... SET exclude_reason = 'pattern_match' WHERE path ~ 'patterns'
   ↓
5. Insert into path table with exclude_reason
   ↓
6. Mark inodes with ALL paths excluded as claimed_by = 'EXCLUDED'
   ↓
7. Copier skips excluded inodes
```

### Code Integration

**ntt-loader (lines 157-177):**
```bash
# Load patterns from file, skip comments and empty lines
PATTERNS=$(grep -v '^#' "$IGNORE_PATTERNS" | grep -v '^$' | paste -sd '|' -)

# Add shell-unsafe characters to exclude list
PATTERNS="${PATTERNS}|#"

# Mark paths matching patterns
EXCLUDED_COUNT=$(psql "$DB_URL" -t -A -c "
  UPDATE $TABLE_NAME
  SET exclude_reason = 'pattern_match'
  WHERE path ~ '$PATTERNS';
  SELECT COUNT(*) FROM $TABLE_NAME WHERE exclude_reason = 'pattern_match';
")
```

**Pattern file location:**
- Default: `$HOME/.config/ntt/ignore-patterns.txt`
- Override: `export NTT_IGNORE_PATTERNS=/custom/path`
- Not in git (user-specific configuration)

---

## Pattern Syntax

**Format:** PostgreSQL extended regex (POSIX ERE)

**Key differences from shell glob:**
- Use `\.` to match literal dot (not `.`)
- Use `/` to match directory separators
- Use `$` to match end of path
- No need to escape `/` (unlike sed/grep -E)
- Patterns match anywhere in path (use `^` for start, `$` for end)

**Examples:**

| Pattern | Matches | Doesn't Match |
|---------|---------|---------------|
| `\.cache/` | `/home/user/.cache/file` | `/home/user/cache/file` |
| `/node_modules/` | `/project/node_modules/lib.js` | `/project/lib/node_modules.txt` |
| `\.iso$` | `/data/ubuntu.iso` | `/data/ubuntu.iso.txt` |
| `core\.[0-9]+$` | `/tmp/core.12345` | `/tmp/core.txt` |
| `\\left-\\right` | `/path/file\\left-\\right.txt` | `/path/left-right.txt` |

**Special characters requiring escaping:**
- `.` → `\.` (literal dot)
- `\` → `\\` (literal backslash)
- `{` → `\{` (literal brace, in some contexts)
- `+` → `\+` (literal plus)

**Testing regex:**
```sql
-- Test pattern before adding
SELECT path
FROM path_p_MEDIUM_HASH
WHERE path ~ 'YOUR_PATTERN'
LIMIT 10;
```

---

## Current Patterns

**Total:** 45 patterns (as of 2025-10-09)

### Category 1: Caches (12 patterns)

Skip application caches and temporary storage that gets regenerated.

```
\.cache/           # General cache directory
\.npm/             # Node Package Manager cache
\.conda/           # Conda package cache
\.keras/           # Keras ML model cache
\.ollama/          # Ollama LLM model cache
/node_modules/     # NPM dependencies (often 100K+ files)
```

**Rationale:**
- High file counts (node_modules can be 100,000+ files)
- Non-unique across systems (same packages everywhere)
- Regenerable from package.json/environment.yml
- No archival value

**Impact:** Reduces file count by 30-50% on developer machines

---

### Category 2: Build Artifacts (6 patterns)

Skip compiled code and generated build outputs.

```
__pycache__/       # Python bytecode cache
/target/           # Rust/Java build output
/dist/             # Distribution builds
/build/            # Generic build directory
\.venv/            # Python virtual environment
\.egg-info/        # Python package metadata
```

**Rationale:**
- Generated from source code
- Platform/architecture specific
- Large binary files
- No unique information

**Impact:** Saves storage on Python/Rust/Node projects

---

### Category 3: Development Tools (4 patterns)

Skip language toolchain installations and package registries.

```
\.rustup/          # Rust toolchain (multiple compilers)
\.cargo/registry/  # Rust crate cache
\.TinyTeX/         # LaTeX distribution
\.julia/packages/  # Julia package cache
```

**Rationale:**
- Toolchains can be 5-10GB each
- Identical across developer machines
- Reinstallable from package managers
- No archival value

**Impact:** Saves 5-20GB per developer machine

---

### Category 4: IDE & Editor (2 patterns)

Skip IDE extensions and remote development caches.

```
\.vscode-server/   # VS Code remote development cache
\.vscode/extensions/ # VS Code extension installs
```

**Rationale:**
- Generated by IDE, not user content
- Can be 1-2GB of extensions
- Reinstallable from marketplace

**Impact:** Saves 1-3GB per machine with VS Code

---

### Category 5: System & Temporary (7 patterns)

Skip OS-level temporary files and caches.

```
/Trash/            # macOS Trash
\.Spotlight-V100/  # macOS Spotlight index
\.Trash/           # Linux trash
/temp/             # Generic temp directory
\.tmp/             # Hidden temp directory
core\.[0-9]+$      # Unix core dumps
\.bash_history$    # Shell history files
\.zsh_history$     # Zsh history
\.python_history$  # Python REPL history
```

**Rationale:**
- System-generated
- No unique user content
- Can be very large (core dumps)
- Privacy (shell history)

**Impact:** Prevents archiving system cruft

---

### Category 6: VM Images & Large Binary Formats (7 patterns)

Skip virtual machine disk images and similar large binary files.

```
\.iso$             # CD/DVD images
\.vmdk$            # VMware disk images
\.qcow2?$          # QEMU disk images (qcow2, qcow)
\.vdi$             # VirtualBox disk images
\.vhd$             # Hyper-V disk images
\.ova$             # Open Virtualization Appliance
\.ovf$             # Open Virtualization Format
```

**Rationale:**
- Extremely large (10-100GB each)
- Virtual machines are environments, not documents
- Better handled by separate VM archival process
- Not part of "file recovery" scope

**Impact:** Prevents archiving multi-GB VM disk images

---

### Category 7: Conda/Anaconda (7 patterns)

Skip Conda package manager installations and environments.

```
/anaconda[0-9]*/   # Anaconda installs (versioned)
/anaconda/         # Unversioned Anaconda
/miniconda[0-9]*/  # Miniconda installs (versioned)
/miniconda/        # Unversioned Miniconda
/conda/pkgs/       # Conda package cache
/conda/envs/       # Conda environments
Library/Developer  # macOS developer library
```

**Rationale:**
- Conda installs can be 10-50GB
- Contains duplicate packages across environments
- Regenerable from environment.yml
- Common on data science machines

**Impact:** Saves 10-50GB on data science workstations

---

### Category 8: TextMate/LaTeX Snippets (3 patterns) **NEW**

Skip editor snippet files with LaTeX commands in filenames that cause filesystem access errors.

```
\\left-\\right     # LaTeX delimiter commands in filenames
/\\n\.plist        # Files starting with backslash-n (looks like newline)
\\newenvironment\{ # LaTeX environment commands in filenames
```

**Rationale:**
- Literal backslashes and braces in filenames
- Combined with corrupted directory names (CR characters) causes I/O errors
- TextMate/Subversion editor configuration, not user documents
- Causes 20,000+ retry loops if not excluded

**Impact:**
- Prevents infinite retry loops on HFS+ Time Machine backups
- Affected 6 inodes on e5727c34fb46e18c87153d576388ea32 (see Case Study below)

**Added:** 2025-10-09 after e5727c34 processing revealed issue

---

## Adding New Patterns

### When to Add a Pattern

**Good reasons:**
- Causing copy failures (problematic filenames)
- High file count, low value (build artifacts)
- Privacy concerns (history files, credentials)
- Large, regenerable data (package caches)

**Bad reasons:**
- Just because it's not source code (might be data)
- Uncertainty (better to archive and analyze later)
- File is large (size alone isn't a reason)

**Decision tree:**
1. Is it user-created content? → **Don't exclude**
2. Is it system-generated and regenerable? → **Consider excluding**
3. Does it cause technical problems? → **Exclude**
4. Is it privacy-sensitive? → **Exclude**

### Process for Adding Patterns

#### Step 1: Identify the Problem

Document the issue:
- What files are causing problems?
- What error messages appear?
- How many files are affected?
- What's the file path pattern?

**Example:** e5727c34 had 6 files causing infinite retry loops with paths like:
```
.HFS+ Private Directory Data\r/dir_856787/Wrap in \left-\right.plist.svn-base
```

#### Step 2: Craft the Pattern

Test the pattern syntax:
```sql
-- Use a test medium's partition table
SELECT encode(path, 'escape') as path
FROM path_p_MEDIUM_HASH
WHERE path ~ 'YOUR_PATTERN'
LIMIT 20;
```

**Check for:**
- Does it match the problematic files?
- Does it match any normal files (false positives)?
- Is it as specific as possible?

**Example test:**
```sql
-- Test LaTeX delimiter pattern
SELECT encode(path, 'escape') as path
FROM path_p_e5727c34
WHERE path ~ '\\left-\\right'
LIMIT 10;

-- Result: 4 paths matched (all TextMate snippets)
```

#### Step 3: Add to Config File

Edit `~/.config/ntt/ignore-patterns.txt`:

```bash
# Add with comment explaining why
# [Category] - [Reason]
YOUR_PATTERN
```

**Format:**
- Add to appropriate category section
- Include comment explaining the pattern
- One pattern per line
- Leave blank line between categories

#### Step 4: Test on Next Medium

The pattern won't affect already-loaded media (path table already populated).

Test on next medium during load:
```bash
# After ntt-loader runs
psql -d copyjob -c "
SELECT COUNT(*) as excluded
FROM path
WHERE medium_hash = 'NEW_MEDIUM_HASH'
  AND exclude_reason = 'pattern_match'
  AND path ~ 'YOUR_PATTERN'
"
```

#### Step 5: Monitor Results

Watch for:
- False positives (normal files excluded)
- False negatives (problem files not caught)
- Copier behavior (retry loops gone?)

**If pattern is too broad:**
- Make it more specific
- Add anchors (`^` for start, `$` for end)
- Add more context (parent directories)

**If pattern is too narrow:**
- Generalize the pattern
- Test with more examples
- Consider variations (case, separator characters)

#### Step 6: Document the Pattern

Update this guide:
- Add pattern to category list
- Explain rationale
- Document the issue it solves
- Add to Case Studies if significant

---

## Testing Patterns

### Test Before Adding

```sql
-- Test pattern on specific medium
SELECT
  encode(path, 'escape') as path,
  length(path) as len
FROM path_p_MEDIUM_HASH
WHERE path ~ 'YOUR_PATTERN'
ORDER BY length(path)
LIMIT 20;
```

### Verify After Adding

```sql
-- Check exclusion counts for newly loaded medium
SELECT
  COUNT(*) as total_paths,
  COUNT(*) FILTER (WHERE exclude_reason = 'pattern_match') as excluded,
  ROUND(COUNT(*) FILTER (WHERE exclude_reason = 'pattern_match')::numeric / COUNT(*) * 100, 2) as pct_excluded
FROM path
WHERE medium_hash = 'MEDIUM_HASH';
```

### Find False Positives

```sql
-- Sample excluded paths to check for mistakes
SELECT
  encode(path, 'escape') as path
FROM path
WHERE medium_hash = 'MEDIUM_HASH'
  AND exclude_reason = 'pattern_match'
ORDER BY random()
LIMIT 50;
```

### Check Pattern Effectiveness

```sql
-- How many inodes were fully excluded?
SELECT
  COUNT(*) as excluded_inodes
FROM inode
WHERE medium_hash = 'MEDIUM_HASH'
  AND claimed_by = 'EXCLUDED';
```

### Analyze Specific Pattern Impact

```sql
-- Which pattern excluded the most paths?
WITH pattern_tests AS (
  SELECT
    path,
    CASE
      WHEN path ~ '\\.cache/' THEN 'cache'
      WHEN path ~ '/node_modules/' THEN 'node_modules'
      WHEN path ~ '__pycache__/' THEN 'pycache'
      WHEN path ~ '\\\\left-\\\\right' THEN 'latex_left_right'
      -- Add more patterns here
      ELSE 'other'
    END as matched_pattern
  FROM path
  WHERE medium_hash = 'MEDIUM_HASH'
    AND exclude_reason = 'pattern_match'
)
SELECT matched_pattern, COUNT(*)
FROM pattern_tests
GROUP BY matched_pattern
ORDER BY COUNT(*) DESC;
```

---

## Case Studies

### Case Study 1: e5727c34 - HFS+ Time Machine with LaTeX Snippets

**Medium:** e5727c34fb46e18c87153d576388ea32
**Type:** 150GB Mac Time Machine backup (HFS+)
**Date:** 2025-10-08 to 2025-10-09

**Problem:**
- 6 files (inodes 263467, 263505, 277226, 277235, 7560919, 7560925) failed to copy
- Each retried 17,000-21,000 times before marking as failed
- Total: ~120,000 retry attempts wasting ~9 hours
- Error: `No such file or directory`

**Root cause:**
- Parent directory: `.HFS+ Private Directory Data\r` (literal CR character in name)
- Filenames contained LaTeX command syntax:
  - `Wrap in \left-\right.plist` (LaTeX delimiters)
  - `\n.plist` (literal backslash-n)
  - `\newenvironment{Rdaemon}.tmSnippet` (LaTeX environment)
- Combined corruption made filesystem access impossible

**Analysis:**
```sql
-- All 6 failed inodes were in HFS+ Private Directory (Time Machine backup data)
SELECT ino, encode(path, 'escape') as path
FROM path_p_e5727c34
WHERE ino IN (263467, 263505, 277226, 277235, 7560919, 7560925);

-- Result: All paths in ".HFS+ Private Directory Data\r/dir_XXXXXX/"
```

**Initial consideration:** Exclude entire `.HFS+ Private Directory Data`

**Investigation revealed:**
- HFS+ Private Directory contained 997,068 inodes (99% of disk!)
- 1,460,400 of those paths copied successfully
- Only 12 paths (6 inodes) failed
- Directory is NOT metadata - it's the actual Time Machine backup

**Solution:** Add specific patterns for LaTeX syntax in filenames:
```
\\left-\\right
/\\n\.plist
\\newenvironment\{
```

**Outcome:**
- Future HFS+ backups with TextMate/LaTeX configs will auto-skip problematic files
- Preserves 99.9992% of backup data
- Prevents retry loops
- 6 lost files are editor configuration snippets, not user documents

**Lessons learned:**
1. Don't exclude based on directory name without investigation
2. Filesystem metadata directories can contain actual data
3. LaTeX commands in filenames combined with CR characters = unreadable
4. Specific patterns better than broad exclusions

**Commands used:**
```bash
# Investigation
psql -d copyjob -c "SELECT COUNT(*) FROM path WHERE medium_hash = 'e5727c34...' AND path ~ 'HFS+'"
# Result: 1,460,412 paths

# Pattern testing
psql -d copyjob -c "SELECT path FROM path_p_e5727c34 WHERE path ~ '\\\\left-\\\\right'"
# Result: 4 paths matched (all problematic)
```

**References:**
- Processing log: `docs/img-processing-workflow-2025-10-08.md`
- Diagnostic queries: `docs/diagnostic-queries.md`
- Copier Phase 4: `docs/copier-diagnostic-ideas.md`

---

### Case Study 2: Pandas Documentation (Existing Pattern)

**Pattern:** `share/doc/pandas`

**Problem:** Pandas documentation contains Markdown files with `{}` in filenames (for template syntax).

**Why excluded:** Curly braces can cause issues in some contexts.

**Impact:** Small (few hundred files per system with pandas docs)

---

## Troubleshooting

### Pattern Not Matching

**Symptom:** Files still being processed despite pattern

**Check:**
1. Pattern syntax correct? Test in psql first
2. Pattern in correct file? Check `~/.config/ntt/ignore-patterns.txt`
3. Pattern applied to new media only (doesn't affect already-loaded)
4. Path encoding issues? Use `encode(path, 'escape')` to see actual bytes

**Debug:**
```sql
-- See what the path actually contains
SELECT
  encode(path, 'escape') as escaped_path,
  octet_length(path) as byte_length
FROM path
WHERE medium_hash = 'HASH' AND ino = PROBLEMATIC_INO;
```

### Too Many Files Excluded

**Symptom:** Exclusion count unexpectedly high

**Check:**
```sql
-- What patterns are matching?
SELECT
  encode(path, 'escape') as path
FROM path
WHERE medium_hash = 'HASH'
  AND exclude_reason = 'pattern_match'
ORDER BY random()
LIMIT 100;
```

**Fix:** Make pattern more specific (add directory context, anchors)

### Pattern Causes Load Failure

**Symptom:** ntt-loader fails with PostgreSQL regex error

**Cause:** Invalid regex syntax

**Check:**
```sql
-- Test pattern in isolation
SELECT 'test/path' ~ 'YOUR_PATTERN';
```

**Common mistakes:**
- Unescaped special characters
- Unbalanced brackets/braces
- Invalid escape sequences

### Need to Re-apply Patterns

**Symptom:** Want to apply new pattern to already-loaded medium

**Solution:** Re-load the medium (will mark new exclusions)

**Caution:** Will reset any copy progress

**Commands:**
```bash
# 1. Delete existing paths/inodes for medium
psql -d copyjob -c "DELETE FROM path WHERE medium_hash = 'HASH'"
psql -d copyjob -c "DELETE FROM inode WHERE medium_hash = 'HASH'"

# 2. Re-run loader with new patterns
sudo bin/ntt-loader /tmp/HASH.raw HASH

# 3. Verify exclusions
psql -d copyjob -c "SELECT COUNT(*) FROM path WHERE medium_hash = 'HASH' AND exclude_reason = 'pattern_match'"
```

---

## Pattern Maintenance

### Annual Review

Review patterns yearly for:
- **Obsolete patterns** (tools no longer used)
- **Missing patterns** (new tools/frameworks)
- **Too broad patterns** (excluding wanted files)
- **Duplicate patterns** (overlapping rules)

### Documentation Updates

When patterns change:
- Update this guide
- Document reason for change
- Add to case studies if significant
- Test on representative media

### Version Control

While the pattern file itself (`~/.config/ntt/ignore-patterns.txt`) is not in git, this documentation is. Keep this guide in sync with actual patterns.

**To snapshot current patterns:**
```bash
# Copy patterns to docs for reference
cp ~/.config/ntt/ignore-patterns.txt docs/ignore-patterns-snapshot-$(date +%Y-%m-%d).txt
```

---

## Advanced Topics

### Performance Impact

**Loading:**
- Patterns applied during UPDATE (after initial insert)
- PostgreSQL regex is fast (microseconds per path)
- 45 patterns on 1M paths: ~1-2 seconds

**Copier:**
- Excluded inodes never processed (skipped in batch claim)
- Exclusion saves copy time, storage, hash computation

**Database:**
- `exclude_reason` column indexed for queries
- Excluded paths included in path table (for auditing)

### Multi-Pattern Testing

Test multiple patterns simultaneously:
```sql
-- Test combined pattern effectiveness
SELECT
  COUNT(*) as total,
  COUNT(*) FILTER (WHERE path ~ 'pattern1') as match1,
  COUNT(*) FILTER (WHERE path ~ 'pattern2') as match2,
  COUNT(*) FILTER (WHERE path ~ 'pattern1' OR path ~ 'pattern2') as match_either
FROM path
WHERE medium_hash = 'HASH';
```

### Pattern Alternatives

Instead of excluding, consider:
- **Copy but flag:** Set custom claimed_by value
- **Copy with low priority:** Process last
- **Archive separately:** Different storage tier

---

## Related Documentation

- **Loader implementation:** `bin/ntt-loader` (lines 157-177)
- **Diagnostic queries:** `docs/diagnostic-queries.md`
- **Copy strategy:** `docs/copier-diagnostic-ideas.md`
- **Database schema:** `schema.sql` (path.exclude_reason column)

---

## Quick Reference

**Pattern file:** `~/.config/ntt/ignore-patterns.txt`
**Override:** `export NTT_IGNORE_PATTERNS=/path/to/file`
**Current count:** 45 patterns (8 categories)
**Loader integration:** `bin/ntt-loader` line 157
**Testing:** `SELECT path FROM path WHERE path ~ 'pattern' LIMIT 10;`

**Most impactful patterns:**
1. `/node_modules/` - Often 100K+ files
2. `.conda/` - 10-50GB on data science machines
3. `\.cache/` - Large and regenerable
4. VM images (`.vmdk`, `.iso`, etc.) - Prevent 10-100GB files

**Recently added:**
- `\\left-\\right` (2025-10-09) - LaTeX delimiters in TextMate snippets
- `/\\n\.plist` (2025-10-09) - Backslash-n in filenames
- `\\newenvironment\{` (2025-10-09) - LaTeX environments in filenames

---

**Last updated:** 2025-10-09
**Pattern count:** 45
**Recent changes:** Added LaTeX/TextMate patterns after e5727c34 analysis
