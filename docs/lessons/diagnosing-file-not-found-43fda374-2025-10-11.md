<!-- lesson: Don't diagnose data loss without verifying files actually missing; path mismatches are more likely than corruption -->

# Lessons Learned: Diagnosing "File Not Found" Errors

**Date:** 2025-10-11
**Context:** Investigating 21,801 `ENOENT` errors during copying phase for medium 43fda374c788bdf3a007fc8bf8aa10d8
**Affected:** Disk image copy performance diagnosis (initially appeared as 214 inodes/sec vs expected 2000+)

## The Mistake

When investigating copy performance issues, I encountered 21,801 files returning `[Errno 2] No such file or directory` and made critical diagnostic errors:

### 1. **Jumped to filesystem corruption conclusion**
- Saw mass `ENOENT` errors from copier
- Noted ddrescue reported "zero errors"
- Immediately concluded: **"filesystem corruption predates imaging"**
- Proposed the disk was "already corrupted when imaged"
- **Should have:** Verified even ONE file was actually missing before declaring corruption

### 2. **Ignored contradictory evidence**
- **fls successfully enumerated 2.3M files** - if filesystem was corrupt, how did enumeration succeed?
- **ddrescue 100% success** - zero bad sectors across entire 750GB disk
- **All errors identical** - every error was `ENOENT`, no I/O errors, no permission errors, no corruption signatures
- **Errors localized** - concentrated in one directory subtree (`raid-archives.mina/archives/CDs/`)
- **Recent mount changes** - bind mount workaround applied for BUG-014 just before copying started
- **Should have:** Questioned why enumeration succeeded if filesystem was corrupt

### 3. **Trusted error messages without verification**
- Copier reported files at paths like: `/mnt/ntt/43fda374.../p1/raid-archives.mina/.../file.doc`
- Accepted `ENOENT` as proof files didn't exist
- Never checked if files existed at alternate paths
- **Should have:** Manually tested if ONE file existed somewhere on the filesystem

### 4. **Proposed giving up on 21,801 files**
- Suggested continuing to process "corrupted" disk
- Accepted 21K files as unrecoverable
- Moved toward next steps instead of exhaustive diagnosis
- **Should have:** Recognized that in data recovery, "lost data" is the LAST conclusion

## The Reality Check

User asked: "ddrescue reported zero errors, where did these errors come from?"

This forced systematic investigation:
```bash
# Check if file actually exists
sudo ls -la /mnt/ntt/43fda374.../raid-archives.mina/archives/CDs/CD3/my-documents/CEH_files/PB_cmts__gen_02.doc
# Result: EXISTS

# Check at path copier was looking
sudo test -e "/mnt/ntt/43fda374.../p1/raid-archives.mina/.../PB_cmts__gen_02.doc"
# Result: No such file or directory
```

**The file existed at base path, but copier looked for it with `/p1/` prefix.**

## Root Cause: Path Mismatch from BUG-014

### What Actually Happened:

**Enumeration phase (earlier):**
- mount-helper mounted at: `/mnt/ntt/43fda374.../p1/`
- Enumeration stored paths with `p1/` prefix: `p1/raid-archives.mina/.../file.doc`

**Copying phase (after bind mount workaround):**
- Bind mount created at base: `/mnt/ntt/43fda374.../`
- Database paths still had `p1/` prefix
- Copier constructed: `/mnt/ntt/43fda374.../` + `p1/raid-archives.mina/.../file.doc`
- Result: `/mnt/ntt/43fda374.../p1/raid-archives.mina/.../file.doc` (doesn't exist)
- Actual file at: `/mnt/ntt/43fda374.../raid-archives.mina/.../file.doc`

### The Truth:
- **Zero files were lost**
- **Zero filesystem corruption**
- **All 21,801 "errors" were path mismatches**
- ddrescue was correct: zero disk errors
- Filesystem was healthy

## Root Causes of Error

1. **Catastrophic diagnosis without verification** - Declared corruption without checking if even one file actually missing
2. **Ignored contradictions** - Didn't question why enumeration succeeded if filesystem corrupt
3. **Trusted tools blindly** - Accepted `ENOENT` without considering path construction issues
4. **Forgot recent changes** - Didn't connect bind mount workaround to path issues
5. **Violated data recovery principle** - Assumed data loss instead of tool misconfiguration

## Lessons Learned

### DO:
- **Verify negative claims physically** - Before declaring files missing, check the filesystem directly
- **Test ONE case thoroughly** - Manually verify one file before generalizing to 21K files
- **Question contradictions** - If enumeration succeeded, how can files be "missing"?
- **Review recent changes** - Mount point changes often cause path issues
- **Check alternate paths** - Try base path, `/p1/` path, other mount points
- **Remember the context** - In data recovery, tool misconfiguration > actual data loss
- **Maintain healthy skepticism** - Especially of catastrophic diagnoses

### DON'T:
- **Don't diagnose corruption lightly** - "Filesystem corruption" requires strong evidence
- **Don't trust error messages blindly** - `ENOENT` means "at this path", not "anywhere"
- **Don't ignore enumeration success** - If fls found it, the data exists somewhere
- **Don't propose giving up** - Especially without exhausting path/mount alternatives
- **Don't overlook path construction** - Mount point + DB path must align
- **Don't forget Occam's Razor** - Path mismatch is simpler than mass corruption

## The Correct Diagnostic Sequence

When seeing "No such file or directory" errors:

```bash
# 1. Pick ONE file from error log
ERROR_PATH="/mnt/ntt/43fda374.../p1/raid-archives.mina/.../file.doc"

# 2. Check if file exists at reported path
sudo test -e "$ERROR_PATH" && echo "EXISTS" || echo "MISSING"

# 3. If missing, check alternate paths
sudo ls -la /mnt/ntt/43fda374.../raid-archives.mina/.../file.doc
sudo ls -la /mnt/ntt/43fda374.../p1/raid-archives.mina/.../file.doc

# 4. Check mount points
findmnt | grep 43fda374

# 5. Review recent mount/path changes
git log --oneline --grep="mount" --since="1 week ago"

# 6. Only if file genuinely missing: check filesystem health
sudo dmesg | grep -i "ext4\|error\|corrupt"
sudo fsck -n /dev/loop_device
```

**Decision tree:**
```
ENOENT error reported
├─ Does file exist at alternate path? → YES → Path mismatch (configuration issue)
│   └─ Check mount points, DB paths, recent changes
├─ Does file exist anywhere on mount? → YES → Wrong directory prefix
│   └─ Review enumeration vs copy mount paths
├─ Did enumeration find this file? → YES → Data exists, find WHERE
│   └─ Systematic search across mount tree
└─ File genuinely missing + I/O errors → THEN consider corruption
    └─ Check ddrescue log, filesystem journal, dmesg
```

## Prevention Checklist

Before declaring data loss:
- [ ] Verify ONE file actually missing by checking filesystem directly
- [ ] Try alternate paths (base path, partition paths, different mount points)
- [ ] Review recent mount/path configuration changes
- [ ] Check if enumeration succeeded (if yes, data exists somewhere)
- [ ] Examine error patterns (all ENOENT vs mixed errors suggests path issue)
- [ ] Review mount points (`findmnt`) and path construction logic
- [ ] Consider: Is path mismatch more likely than mass corruption?
- [ ] Test hypothesis: Copy one file manually with correct path

**Remember:** If enumeration succeeded, you're looking for WHERE data is, not accepting it's lost.

## Impact

**What would have happened if I'd continued:**
- Abandoned 21,801 recoverable files
- Marked medium as having "corruption" problems
- Moved to next disk without fixing path issue
- Lost ~1% of disk's enumerated files permanently

**Actual impact after correct diagnosis:**
- Zero files lost
- Path issue identified (mount-helper needs fix)
- All 21,801 files accessible
- BUG-014 root cause clarified

## The Core Principle

**In data recovery/archival work: "Lost data" is the LAST conclusion, not the FIRST.**

When a tool reports files missing:
1. **First assume:** Tool is looking in wrong place
2. **Then check:** Path construction, mount points, recent changes
3. **Only then:** Consider actual data loss (with strong evidence)

**Key insight:** If enumeration succeeded, the data exists. Your job is finding WHERE, not accepting it's gone.

## Status

**Lesson learned:** Before declaring 21K files corrupt/lost, check if even ONE is actually missing. Path mismatches are more common than mass corruption in working filesystems.

**Outcome:** Zero data loss. All errors were path mismatches from mount point configuration changes.
