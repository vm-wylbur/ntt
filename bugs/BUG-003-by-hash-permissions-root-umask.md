<!--
Author: PB and Claude
Date: Fri 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/BUG-003-by-hash-permissions-root-umask.md
-->

# BUG-003: By-hash files not world-readable (inherit root umask)

**Filed:** 2025-10-10 13:07
**Filed by:** PB
**Status:** open
**Affected media:** All media processed by ntt-copier
**Phase:** copying

---

## Observed Behavior

Files created in `/data/cold/by-hash/` inherit root's umask instead of being explicitly set to world-readable.

**Filesystem state:**
```bash
# Commands run:
ls -la /data/cold/by-hash/2b/8c/2b8c94f3d945595d85d91ea25772d56868b996e4b2e7ec69f532d4a3ead4c7c0

# Output:
-rwxr-x--- 2 root root 2066 Dec 31  2001 /data/cold/by-hash/2b/8c/2b8c94f3d945595d85d91ea25772d56868b996e4b2e7ec69f532d4a3ead4c7c0
```

Permissions are `0750` (rwxr-x---) - **not world-readable**.

This occurs because `shutil.move()` at `ntt-copier.py:1475` preserves the source file's permissions (which come from temp file created with root's umask), and no explicit chmod is performed after the move.

---

## Expected Behavior

By-hash files should be world-readable (`0644` or `rw-r--r--`) so:
1. Non-root users can access archived content
2. Hardlinks in `/data/cold/archived/` are readable by the original user (pball)
3. Archive tar files can be read/verified by non-root users

Per standard archive design:
- Content files should be readable by all users
- Only write access should be restricted to root
- Execute bit should not be set on regular files

---

## Success Condition

**How to verify fix:**

1. Process a test medium through copier
2. Check permissions on created by-hash files
3. Verify non-root user can read the files

**Fix is successful when:**
- [ ] Query `ls -l /data/cold/by-hash/*/*/<hash>` shows `-rw-r--r--` (0644)
- [ ] Non-root user can read by-hash files: `sudo -u pball cat /data/cold/by-hash/2b/8c/2b8c... | head` succeeds
- [ ] New files created after fix have mode 0644
- [ ] Test case: Process fresh medium, verify `stat -c %a /data/cold/by-hash/*/*/<new_hash>` returns `644`

---

## Impact

**Initial impact:** Affects all media processed by ntt-copier
**Workaround available:** yes
**Workaround:** Manually chmod files: `sudo find /data/cold/by-hash -type f -exec chmod 644 {} \;`

**Severity:** Medium
- Blocks non-root access to archived content
- Does not prevent processing (copier still works)
- Simple workaround available
- Affects data accessibility, not data integrity

---

---

## Severity Assessment (metrics-claude)

**Analysis date:** 2025-10-10 13:10

**Media affected:** All media processed by ntt-copier (5 confirmed: 579d3c3a, 2b48bdc7, ff9313ea, c8714b2c, 92f92600)

**Pattern frequency:**
- Systemic issue affecting 100% of media
- Reported by PB after reviewing by-hash file permissions
- Affects all historical archived content
- Will continue to affect all future media until fixed

**Workaround availability:** Yes (manual chmod)

**Workaround:**
```bash
sudo find /data/cold/by-hash -type f -exec chmod 644 {} \;
```

**Impact scope:**
- Blocks non-root access to archived content
- Does not prevent processing (copier continues to work)
- Does not affect data integrity
- Does not cause data loss
- Affects data accessibility/usability

**Severity: MEDIUM** (confirmed)

**Rationale:**
- Affects 100% of media, but does not block processing
- Simple workaround available (one-time chmod fix for existing files)
- Does not affect data integrity or cause data loss
- Accessibility issue, not a correctness issue
- Not marked as **HIGH** because:
  - Processing can continue (not blocking the pipeline)
  - Workaround is simple and effective
  - Can be fixed retroactively for all historical files
  - No risk of data corruption or loss

**Resolution status:**
- Awaiting dev-claude investigation and fix
- Once fixed, existing files can be corrected with one-time chmod
- Future files will have correct permissions

**Recommendations:**
- Apply fix to copier code to set explicit permissions
- Run one-time chmod on all existing by-hash files after fix
- Consider adding permission verification to success criteria

---

## Dev Notes

### Root Cause (2025-10-10)

`shutil.move()` at `ntt-copier.py:1475` preserves source file permissions from temp file created with root's umask (0750). No explicit chmod was performed after move, resulting in by-hash files inheriting wrong permissions.

### Fix Applied (2025-10-10)

**Change:** Added explicit `os.chmod()` after `shutil.move()` in `ntt-copier.py`

```python
# Line 1475-1477
shutil.move(str(temp_file), str(hash_path))
# Make world-readable (overrides root's umask)
os.chmod(hash_path, 0o644)
```

**Verification status:** 2025-10-11 11:05

Fix is present in code at `ntt-copier.py:1544`. Verification attempted but recent copier runs only deduplicated to existing files (high link counts), so no NEW files were created to test permissions.

**Next verification:**
1. Monitor for next medium that creates a unique (non-deduplicated) file
2. Check permissions immediately: `stat -c %a /data/cold/by-hash/*/*/<hash>` should return `644`
3. Verify non-root read access: `sudo -u pball cat /data/cold/by-hash/.../<hash> | head`

**Existing files workaround:**
```bash
sudo find /data/cold/by-hash -type f -exec chmod 644 {} \;
```

This one-time command will fix all existing by-hash files created before the fix.

**Status:** FIXED (code deployed, awaiting production verification)
