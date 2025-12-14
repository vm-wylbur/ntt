<!--
Author: PB and Claude
Date: 2025-11-24
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/lessons/gmail-mbox-unnecessary-workflow-2025-11-24.md
-->

<!-- lesson: Always verify database state before executing workflows; metadata summaries are not authoritative -->

# Lessons Learned: Wasted 1.5 Hours on Already-Processed Gmail Mbox

**Date:** 2025-11-24
**Context:** Processing a 19.4 GB Gmail Takeout mbox file
**Impact:** ~1.5 hours wasted, significant token consumption, user frustration

## Executive Summary

**What happened:** Claude executed a multi-step workflow (DAR extraction, enumeration, database loading) for a file that was already fully processed with an existing blobid.

**The core failure:** Trusted session context summary metadata (`enum_done=NULL`) without verifying actual database state in `paths` and `blobs` tables.

**What should have happened:** Before ANY action, query: "Does this blobid already exist?" That single check would have saved 1.5 hours.

---

## The Situation

### Session Context Provided
The session began with a continuation summary stating:
- Medium hash: `4a98678d8b42337f7129b17cd202a26b`
- File: `gmail-20251113-002.mbox` (19.4 GB)
- Stored as DAR archive at `/mnt/ntt-images/4a98678d8b42337f7129b17cd202a26b.1.dar`
- Medium table entry showing:
  - `enum_done: NULL` ← **This was the trap**
  - `copy_done: NULL`
  - `medium_type: extracted`
  - `image_path: /data/fast/img/gmail-20251113-002.mbox`

### What I Did (Wrongly)
1. Accepted `enum_done=NULL` as proof the file wasn't processed
2. Created a 5-step workflow plan:
   - Extract from DAR archive
   - Run ntt-enum
   - Load with ntt-loader
   - Run ntt-copier
   - Study mbox structure
3. Executed the extraction (unnecessary - file was already there)
4. Ran ntt-enum on wrong directory (scanned 800K files in archives-2019)
5. Fixed ntt-enum to scan correct directory
6. Struggled with /tmp permission issues in ntt-loader
7. Manually inserted a paths entry
8. Only THEN queried to check if a blobid existed
9. Discovered 5 existing paths entries with `copied=t` and valid blobid

### What Already Existed (That I Never Checked)
```sql
-- The query I should have run FIRST:
SELECT blobid, copied FROM paths
WHERE medium_hash = '4a98678d8b42337f7129b17cd202a26b';

-- Would have shown:
   ino    |                              blobid                              | copied
----------+------------------------------------------------------------------+--------
        1 | 0d8b0d40618cf18f9a2683a45d1b5605ee13f51d23aeb2b625e905053330cf83 | t
        1 | 0d8b0d40618cf18f9a2683a45d1b5605ee13f51d23aeb2b625e905053330cf83 | t
        1 | 0d8b0d40618cf18f9a2683a45d1b5605ee13f51d23aeb2b625e905053330cf83 | t
        1 | 0d8b0d40618cf18f9a2683a45d1b5605ee13f51d23aeb2b625e905053330cf83 | t
        1 | 0d8b0d40618cf18f9a2683a45d1b5605ee13f51d23aeb2b625e905053330cf83 | t
```

The file was **already fully processed**:
- Blobid: `0d8b0d40618cf18f9a2683a45d1b5605ee13f51d23aeb2b625e905053330cf83`
- MIME type: `application/mbox`
- File in by-hash storage: `/data/fast/ntt/by-hash/0d/8b/0d8b0d40618cf18f9a2683a45d1b5605ee13f51d23aeb2b625e905053330cf83`

---

## Root Cause Analysis

### 1. Trusted Summary Metadata as Authoritative

**What I did:** The session context summary said `enum_done=NULL`. I treated this as authoritative proof that the file hadn't been processed.

**Why this was wrong:**
- Session summaries are snapshots, potentially stale
- `enum_done` is one metadata field, not the source of truth
- The actual processing state lives in `paths` and `blobs` tables
- Metadata can be inconsistent (enum_done not updated but paths entries exist)

**The cognitive error:** I conflated "metadata says not enumerated" with "file not processed." These are not the same thing.

### 2. Planned Before Verifying

**What I did:** Created an elaborate 5-step workflow plan, then started executing it.

**Why this was wrong:**
- Step 0 should always be: "Verify this work is needed"
- I jumped to "how to process" before confirming "needs processing"
- Every subsequent step built on the unverified assumption

**The cognitive error:** Action bias. I wanted to show progress and help, so I started doing things instead of verifying whether to do them.

### 3. Wrong Mental Model of Processing State

**What I assumed:** `enum_done=NULL` in medium table → file hasn't entered the pipeline

**What's actually true:** Processing can happen through multiple paths:
- Manual insertion of paths entries
- Direct ntt-copier runs
- Previous session work
- The medium table metadata may not be updated consistently

**The cognitive error:** I assumed a single-path pipeline when the system has multiple entry points.

### 4. Database Is Source of Truth, Not Metadata

**What I should know:** For "has this been processed?", the authoritative answer is:
```sql
SELECT COUNT(*) FROM paths WHERE medium_hash = '...' AND blobid IS NOT NULL;
SELECT COUNT(*) FROM blobs WHERE blobid IN (SELECT blobid FROM paths WHERE medium_hash = '...');
```

**What I checked instead:** Medium table metadata field (`enum_done`)

**The cognitive error:** Checked a status indicator instead of checking actual state.

### 5. Cascading Errors Without Checkpoints

**The cascade:**
1. Assumed not processed → planned extraction
2. Extraction "succeeded" (file already existed, DAR just overwrote) → continued
3. ntt-enum scanned wrong directory → fixed and continued
4. ntt-loader failed → worked around it
5. Only at database insert did I check existing state

**What was missing:** Any checkpoint that asked "wait, should I be doing this?"

Each problem encountered was treated as "obstacle to overcome" rather than "signal that assumptions might be wrong."

---

## Why This Mistake Was Made (Honest Self-Analysis)

### Context Handoff Problem
This session continued from a previous conversation. The summary was created when the file genuinely hadn't been processed. But by the time this session started, someone (previous session? user manually?) had already processed it. I trusted the stale summary.

### CLAUDE.md Violation
My instructions explicitly state:
> **DON'T GUESS, ASSUME, OR FILL GAPS**
> When information is missing:
> - STOP
> - ASK for specifics
> - WAIT for answer

I violated this. When I saw `enum_done=NULL`, I should have asked: "The metadata shows enum_done=NULL, but let me verify - does a blobid already exist for this medium?"

Instead, I assumed and acted.

### Desire to Show Progress
The user asked about processing a large file. I wanted to demonstrate competence by creating a clear plan and executing it. This action bias led me to skip verification.

### Tool Selection Failure
I reached for filesystem tools (dar, ntt-enum, ntt-loader) before database tools. The correct order:
1. Database query to verify state
2. Only then, if needed, filesystem operations

I inverted this because I was mentally committed to "process this file" before confirming it needed processing.

---

## Timeline of Waste

| Time | Action | Waste |
|------|--------|-------|
| 0:00 | Session starts, read context summary | - |
| 0:05 | Plan created assuming file not processed | Should have verified here |
| 0:10 | DAR extraction started (unnecessary) | 5 minutes |
| 0:15 | DAR extraction completes | - |
| 0:20 | ntt-enum started on /data/fast/img | - |
| 0:25 | ntt-enum scanning 800K files (wrong!) | 15 minutes |
| 0:40 | User interrupts, points out problem | - |
| 0:45 | Code-explore ntt-enum | 10 minutes |
| 0:55 | ntt-enum on correct directory | - |
| 1:00 | ntt-loader permission issues | 15 minutes |
| 1:15 | Manual paths insert workaround | - |
| 1:20 | Finally query existing paths | **Discovery** |
| 1:25 | Blobid already exists | - |

**Total waste:** ~1.5 hours, hundreds of thousands of tokens

**Cost of verification query:** ~30 seconds

---

## The Query That Would Have Saved Everything

```sql
-- Run this FIRST for any "process this file" request
SELECT
    p.medium_hash,
    p.blobid,
    p.copied,
    b.mime_type,
    p.size
FROM paths p
LEFT JOIN blobs b ON p.blobid = b.blobid
WHERE p.medium_hash = '4a98678d8b42337f7129b17cd202a26b'
  AND p.blobid IS NOT NULL;
```

If this returns rows → file is already processed. Stop.
If this returns nothing → proceed with workflow.

---

## What This Reveals About Session Continuations

### The Handoff Problem
Session summaries capture state at a point in time. Between sessions:
- Work may have been completed
- Manual interventions may have happened
- Database state may have changed

**Summaries are starting points for verification, not authoritative state.**

### The Correct Pattern for Continued Sessions
1. Read the summary to understand context
2. **Verify current state** against the summary claims
3. Identify what has changed
4. Only then plan actions

I skipped step 2 entirely.

---

## Patterns to Recognize

### "Metadata says X" → Verify X
Any time a session summary or metadata field makes a claim about processing state, verify it against actual data.

- Summary says "not enumerated" → Query paths table
- Summary says "not copied" → Query blobs table
- Summary says "file doesn't exist" → Check filesystem

### Planning Without Verification Is Dangerous
A detailed plan based on assumptions amplifies the cost of wrong assumptions. Every step executed is wasted if the premise is wrong.

### Obstacles Encountered May Be Signals
When I hit problems (wrong directory, permission issues), these were opportunities to step back and ask "am I even doing the right thing?" Instead, I treated them as obstacles to overcome.

---

## Impact Assessment

### Time Wasted
- User time: ~1.5 hours of supervision, frustration, course correction
- Claude time: Same, plus cognitive overhead of complex unnecessary workflow
- Total: ~3 person-hours

### Tokens Consumed
- Multiple file reads (ntt-copier.py, ntt-enum, ntt-loader)
- Code exploration
- Multiple bash commands
- Plan iterations
- Error handling

Estimated: 50,000+ tokens on unnecessary operations

### Trust Erosion
User explicitly expressed frustration: "oh c'mon! why didn't you find this file when we looked before? Analyze your process, we've just wasted 1.5h!"

This damages the working relationship and confidence in Claude's ability to make good decisions.

---

## Comparison to Previous Lessons

### Similar to: lessons-learned-verifying-byhash-integrity-2025-10-04.md

That incident: Assumed files didn't exist in by-hash without verifying.
This incident: Assumed file wasn't processed without verifying.

**Common pattern:** Making negative claims ("doesn't exist", "not processed") without verification.

### Similar to: lessons-learned-partition-drop-migration-2025-11-16.md

That incident: Asked "how to drop tables faster" instead of "what's the actual goal?"
This incident: Asked "how to process this file" instead of "does this file need processing?"

**Common pattern:** Jumping to solutions without verifying the problem.

---

## Honest Assessment

### Was this a reasonable mistake?
**No.** The verification query is trivial. The cost of checking is near-zero. The cost of not checking was 1.5 hours.

### Were there warning signs?
**Yes.**
- The medium table showed `image_path` was already set to a specific location
- The file size (20GB) and complexity suggested significant prior work
- The DAR archive existing in ntt-images suggested intentional preservation

### Did I follow my own instructions?
**No.** CLAUDE.md says "DON'T GUESS, ASSUME, OR FILL GAPS" and "State explicitly: 'I need [specific information] before proceeding'". I did neither.

### What would a careful engineer have done?
Run `SELECT * FROM paths WHERE medium_hash = '...'` before anything else. Two seconds of work.

---

## The Fundamental Error

**I confused "planning to do something" with "verifying something needs to be done."**

A good plan for the wrong problem is worse than no plan. I built an elaborate workflow on an unverified assumption.

The user didn't ask me to "process this file." The user said it "requires special processing." My job was first to determine: does it? And I failed to ask that question.

---

## References

- Previous similar incident: `docs/lessons/lessons-learned-verifying-byhash-integrity-2025-10-04.md`
- Problem framing lesson: `docs/lessons/lessons-learned-partition-drop-migration-2025-11-16.md`
- CLAUDE.md: "DON'T GUESS, ASSUME, OR FILL GAPS"

---

**Summary:** Before executing any data processing workflow, verify the work hasn't already been done. The database is the source of truth, not metadata summaries. A 30-second query saves hours of wasted effort.
