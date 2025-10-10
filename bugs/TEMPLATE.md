<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/bugs/TEMPLATE.md
-->

# BUG-NNN: <Short Description>

**Filed:** YYYY-MM-DD HH:MM
**Filed by:** prox-claude
**Status:** open
**Affected media:** <hash_short> (<full_hash>)
**Phase:** pre-flight | enumeration | loading | copying | archive

---

## Observed Behavior

<What prox-claude observed - NO CODE READING, only process behavior>

**Commands run:**
```bash
<exact commands that were executed>
```

**Output/Error:**
```
<actual stdout/stderr showing the problem>
```

**Database state:**
```sql
-- Query run:
<query used to check state>

-- Result:
<query output showing unexpected state>
```

**Filesystem state:**
```bash
# Commands run:
<ls/mount/df commands>

# Output:
<filesystem output>
```

**System logs:**
```bash
# dmesg output:
<relevant dmesg entries if any>
```

---

## Expected Behavior

<What should have happened according to media-processing-plan.md or normal operation>

**Examples:**
- "Loader should complete in <10s per media-processing-plan.md"
- "Partition table inode_p_<hash> should exist after loading"
- "Mount should succeed for filesystem with >95% recovery"

---

## Success Condition

**How to verify fix (must be observable, reproducible, specific):**

1. <Specific test step 1>
2. <Specific test step 2>
3. <Specific test step 3>

**Fix is successful when:**
- [ ] <Concrete, testable criterion 1>
- [ ] <Concrete, testable criterion 2>
- [ ] <Concrete, testable criterion 3>
- [ ] Test case: `<exact command to run>` produces `<exact expected output>`

**Examples of good success conditions:**
- [ ] Running `time sudo bin/ntt-loader /tmp/579d3c3a.raw 579d3c3a...` completes in <10s
- [ ] Query `SELECT COUNT(*) FROM pg_tables WHERE tablename = 'inode_p_579d3c3a'` returns 1
- [ ] File `/tmp/579d3c3a.raw` exists and has size >0

---

## Impact

**Severity:** (assigned by metrics-claude after pattern analysis)
**Initial impact:** Blocks <N> media | Blocks processing entirely | Degrades performance
**Workaround available:** yes | no
**If workaround exists:** <describe manual workaround>

---

## Dev Notes

<!-- dev-claude appends investigation and fix details here -->

**Investigation:**
<What code was examined, what was discovered>

**Root cause:**
<Technical explanation of why the bug occurred>

**Changes made:**
- `file1.py:123` - <description of change>
- `file2.py:456` - <description of change>

**Testing performed:**
<What tests were run to verify the fix>

**Ready for testing:** YYYY-MM-DD HH:MM

---

## Fix Verification

<!-- prox-claude tests fix and documents results here -->

**Tested:** YYYY-MM-DD HH:MM
**Medium:** <hash> (or "synthetic test case")

**Results:**
- [ ] Success condition 1: <PASS|FAIL with details>
- [ ] Success condition 2: <PASS|FAIL with details>
- [ ] Success condition 3: <PASS|FAIL with details>

**Outcome:** VERIFIED - moving to bugs/fixed/ | REOPENED - issues found

**If reopened:**
<Details of what still doesn't work, additional findings>
