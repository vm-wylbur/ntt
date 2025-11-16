<!--
Author: PB and Claude
Date: Sat 16 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/lessons/lessons-learned-partition-drop-migration-2025-11-16.md
-->

# Lessons Learned: PostgreSQL Partition Drop Migration (2025-11-16)

## Executive Summary

**Problem:** Need to drop 488,362 partitioned tables during schema migration, but `DROP TABLE CASCADE` takes 1-2 hours.

**Initial attempts:** Multiple failed "optimizations" (TRUNCATE, parallel DETACH, catalog manipulation) before discovering the correct solution.

**Correct solution:** Rename tables for instant cutover (seconds), drop old tables in background later (no user impact).

**Key lesson:** When multiple AI systems independently propose complex solutions to a simple problem, step back and question whether you're solving the right problem. We optimized cleanup speed when we should have eliminated cleanup from the critical path.

---

## Original Problem Statement

### Context
Migration from partitioned to unpartitioned schema in PostgreSQL:
- **Old schema:** `path` table with 244,181 partitions, `inode` table with 244,181 partitions
- **New schema:** `paths_provisional` (231,628,765 rows, 146 GB), `blobs_provisional` (ready)
- **Constraint:** Foreign key relationships between each `path_*` and `inode_*` partition pair
- **Goal:** Minimize downtime during cutover

### Initial Observations
1. `DROP TABLE path CASCADE` ran for 52+ minutes before we cancelled it
2. Estimated total time: 1-2 hours for both tables
3. Performance: ~78 partitions/minute
4. Bottleneck: Serial catalog updates (pg_class, pg_inherits, pg_constraint, etc.), not I/O
5. CPU-bound, not disk-bound

### The Question
How do we speed up dropping 488,362 partitioned tables to minimize cutover downtime?

---

## Failed Attempts: Claude's Initial Proposals

### Attempt 1: TRUNCATE Before DROP
**Date:** 2025-11-16 (during Phase 4 cutover)

**Reasoning:**
- TRUNCATE removes data quickly without DELETE overhead
- DROP on empty tables should be faster
- Two-step approach: TRUNCATE (fast), then DROP (fast on empty)

**Implementation:**
```sql
TRUNCATE TABLE path CASCADE;
TRUNCATE TABLE inode CASCADE;
DROP TABLE path CASCADE;
DROP TABLE inode CASCADE;
```

**What Actually Happened:**
- TRUNCATE TABLE path CASCADE ran, eventually completed
- TRUNCATE TABLE inode CASCADE started, ran for 1.5+ minutes
- User noticed: "really seems the inode truncate is going partition-by-partition"
- Verification showed all 244,182 partitions still existed (just empty)

**Why It Failed:**
- **Wrong assumption:** TRUNCATE would be faster than DROP on partitioned tables
- **Reality:** Both TRUNCATE and DROP iterate through partitions one-by-one for catalog updates
- **Bottleneck misidentified:** Thought it was data removal, but it's actually catalog operations
- TRUNCATE on partitioned tables: O(n) where n = partition count
- DROP on partitioned tables: Also O(n)
- No performance benefit, just moved work around

**User feedback:** "ok stop the script pls" (cancelled after discovering no benefit)

### Attempt 2: Optimized Phase 4 Script
**After cancellation, created "optimized" script with TRUNCATE approach**

**File created:** `migrations/eliminate-partitions-phase4-cutover-optimized.sql`

**User feedback:** "no the other one is already running!" (confusion about which script)

**Action taken:** Deleted redundant script file

**Lesson:** Creating new files in response to failed approach compounds confusion. Should have analyzed first, acted second.

### Attempt 3: Analysis Request
**User:** "what's the *progress*?"

**My response:** Claimed TRUNCATE approach was "optimized" and "much faster"

**Reality check:** User observed partition-by-partition iteration, proving optimization claim was false

**Lesson:** Made claims about performance without verifying. Should have measured, not assumed.

---

## External AI Proposals

We consulted 4 different AI systems (Kimi, Gemini, ChatGPT, Web-Claude) for solutions. Here's what each proposed:

### Kimi's Proposal
**Strategy:** Parallel DROP using Python ThreadPoolExecutor

**Core idea:**
```python
from concurrent.futures import ThreadPoolExecutor
import psycopg2

def drop_partition(partition_name):
    conn = psycopg2.connect("dbname=copyjob")
    cur = conn.cursor()
    cur.execute(f"DROP TABLE {partition_name};")
    conn.commit()

with ThreadPoolExecutor(max_workers=10) as executor:
    executor.map(drop_partition, partition_names)
```

**Strengths:**
- Correctly identifies parallelism as potential solution
- Provides working Python code
- Uses multiple connections to avoid client serialization

**Problems:**
- Doesn't handle FK constraint ordering (must drop path before inode)
- Missing CASCADE in DROP statements
- SQL injection risk via f-string (minor, but present)
- No error handling/reporting
- **Doesn't question whether DROP speed is the right problem to solve**

**Category:** Technical solution to wrong problem

---

### Gemini's Proposal
**Strategy:** Generate DROP commands from system catalogs, execute in parallel shell processes

**Core idea:**
```sql
SELECT 'DROP TABLE IF EXISTS ' || quote_ident(nmsp_child.nspname) || '.' ||
       quote_ident(child.relname) || ' CASCADE;'
FROM pg_inherits
JOIN pg_class child ON pg_inherits.inhrelid = child.oid
-- ... (more joins)
WHERE parent.relname = 'path';
```

```bash
# Split and execute in parallel
split -l 10000 drop_commands.sql chunk_
for chunk in chunk_*; do
    psql -d copyjob -f $chunk &
done
```

**Strengths:**
- Excellent explanation of WHY operations are slow (catalog overhead)
- Uses proper `quote_ident()` for safety
- Queries system catalogs (more robust than pattern matching)
- Correctly warns against filesystem manipulation
- Correctly identifies DETACH as having same bottleneck

**Problems:**
- Incomplete implementation (conceptual description, no full script)
- Doesn't specify FK ordering
- No guidance on optimal parallelism level
- **Optimizes cleanup speed without questioning whether cleanup must block cutover**

**Category:** Thorough technical analysis, but solving wrong problem

---

### ChatGPT's Proposal ⭐
**Strategy:** Fast rename cutover, background cleanup

**Core idea:**
```sql
-- Phase 1: Fast cutover (seconds)
BEGIN;
ALTER TABLE path RENAME TO path_old;
ALTER TABLE inode RENAME TO inode_old;
ALTER TABLE paths_provisional RENAME TO path;
ALTER TABLE blobs_provisional RENAME TO blobs;
COMMIT;

-- Phase 2: Background cleanup (run separately, hours later)
DROP TABLE path_old CASCADE;
DROP TABLE inode_old CASCADE;
```

**Key insight:**
> "You don't need to accept 1–2 hours of downtime, you just need to accept 1–2 hours of background cleanup while the new schema is already live."

**Why this is different:**
- **Reframes the problem:** Cutover ≠ Cleanup
- **Decouples concerns:** User-visible downtime vs background maintenance
- **Solves business problem:** Minimize impact to users, not total operation time
- **Simple and safe:** Standard pattern, low risk, well-tested

**Strengths:**
- Identifies the actual goal (minimize user impact)
- Provides pragmatic solution
- Acknowledges 244K partitions is far beyond recommended limits
- Clear on what's mandatory vs optional
- Honest about limitations (1-2h cleanup is unavoidable)

**This is the correct solution.**

**Category:** Business-focused problem reframing

---

### Web-Claude's Proposals
**Strategy:** 4 different options presented

#### Option 1: Parallel DETACH PARTITION CONCURRENTLY
```bash
# Generate DETACH commands
psql -At -c "SELECT 'ALTER TABLE path DETACH PARTITION ' || tablename || ' CONCURRENTLY;'
             FROM pg_tables WHERE tablename LIKE 'path_%'" > detach_commands.sql

# Run in parallel
parallel -j 16 psql -d copyjob -c {} :::: detach_commands.sql
```

**Critical misunderstanding:**
- `DETACH PARTITION CONCURRENTLY` may not exist in stable PostgreSQL
- Even if it exists, CONCURRENTLY means "don't block reads," NOT "parallel execution"
- DETACH still requires O(n) catalog operations per partition
- No faster than DROP CASCADE

**Category:** Misconception about PostgreSQL feature semantics

#### Option 2: Rename and Background Drop
**Identical to ChatGPT's approach.** ✅ Correct.

#### Option 3: Direct Catalog Manipulation 🚫
```sql
SET session_replication_role = 'replica';
BEGIN;
DELETE FROM pg_inherits WHERE inhparent IN (...);
DROP TABLE path;
DROP TABLE inode;
-- Delete directly from pg_class
DELETE FROM pg_class WHERE relname IN (...);
COMMIT;
```

**Why this is catastrophically wrong:**
- Bypasses all dependency checking
- Leaves orphaned files on disk (no cleanup without proper DROP)
- Breaks catalog referential integrity
- Missing cleanup of: pg_attribute, pg_constraint, pg_index, pg_depend, pg_statistic, pg_toast, etc.
- `session_replication_role = 'replica'` disables triggers, doesn't make catalog manipulation safe
- Will create undefined database state that may corrupt later

**Category:** Dangerous hack that will corrupt database

#### Option 4: pg_repack
```bash
pg_repack -d copyjob -t paths_provisional -t blobs_provisional
```

**Why this is irrelevant:**
- pg_repack reclaims bloat from existing tables
- Doesn't help with dropping partitions
- Targets wrong tables (paths_provisional is already the clean destination)

**Category:** Tool misapplication

**Web-Claude's Recommendation:** Option 2 (correct), but presenting Option 3 as "aggressive" rather than "never do this" is dangerous.

---

## Analysis and Synthesis

### Comparison Document Created
**File:** `docs/partition-drop-solutions-comparison.md` (63KB comprehensive analysis)

**Structure:**
1. Detailed breakdown of each approach
2. Technical analysis of why most don't work
3. Comparison matrix (cutover time, cleanup time, complexity, risk)
4. Implementation recommendations

**Key findings:**
- 5 out of 9 approaches were wrong, dangerous, or irrelevant
- Only 2 approaches (ChatGPT, Web-Claude Option 2) were correct
- 3 approaches (mine, Kimi's, Gemini's) optimized the wrong thing
- 1 approach (Web-Claude Option 3) would corrupt the database

### Multi-LLM Responses

After sharing the comparison document, got feedback from all 4 external AIs:

#### Web-Claude's Response
- Acknowledged TRUNCATE suggestion was wrong
- Confirmed catalog manipulation is "catastrophically dangerous"
- Agreed parallel drops optimize cleanup, not cutover
- Suggested `ANALYZE` after rename (good addition)
- **Key quote:** "You've correctly identified the winner"

#### Kimi's Response
- Acknowledged FK ordering and CASCADE issues in original proposal
- Agreed with comprehensive analysis structure
- Confirmed rename approach as recommended
- Supported "make the slow thing irrelevant" insight

#### ChatGPT's Response
**Provided critical structural feedback:**

1. **Framing issue:** Document conflates "cutover strategy" with "cleanup strategy"
   - Should separate: ONE cutover method (rename) vs MULTIPLE cleanup options
   - Current structure makes it look like competing strategies

2. **Missing details on rename approach:**
   - Must handle views that reference old tables
   - Must handle FKs FROM other tables TO path/inode
   - Must handle triggers/functions
   - Must handle grants/permissions
   - Need explicit lock semantics explanation

3. **Naming consistency:** Clarify inode → blobs transition

4. **Parallel DROP positioning:** More conservative on expectations (lock contention may negate benefit)

5. **DETACH PARTITION CONCURRENTLY:** May not exist in stable PostgreSQL versions

6. **Recommended structure change:**
   ```
   Part 1: The Cutover Strategy (THE ANSWER)
   Part 2: The Cleanup Problem (BACKGROUND TASK)
   Part 3: What Doesn't Work
   Part 4: Implementation Plan
   ```

**Category:** Meta-analysis of how to present solutions

#### Gemini's Response
- Called analysis "absolutely outstanding"
- Agreed rename approach is "industry-standard, lowest-risk"
- Acknowledged parallel drop suggestion "fails to address primary goal"
- Confirmed: **"You have correctly identified not just the best technical solution, but the best business solution"**
- Offered to help with execution

---

## Root Cause Analysis: Why So Many Bad Proposals?

### 1. Solving the Stated Problem vs The Real Problem

**What was asked:** "How do we speed up dropping 488,362 partitioned tables?"

**What was heard by AIs:**
- Claude (me): Make TRUNCATE/DROP faster
- Kimi: Parallelize DROP operations
- Gemini: Parallelize DROP operations
- Web-Claude: Multiple technical approaches to faster drops

**What should have been asked:** "How do we minimize downtime during schema cutover?"

**The disconnect:**
- Question implied DROP speed was the constraint
- Most AIs optimized for that constraint
- Only ChatGPT questioned whether DROP must happen during cutover

**Lesson:** **Question framing determines solution space.** A poorly framed question gets technically correct but pragmatically useless answers.

### 2. Technical Optimization Bias

**Pattern observed:** 4 out of 5 AIs (including me) immediately went to technical optimization:
- "Make X faster" → parallelize, optimize, hack
- Assumed the operation must be done, focus on efficiency
- Never questioned whether operation is necessary at that time

**ChatGPT's approach:**
- "Why does X need to be fast?" → because downtime
- "Does X cause downtime?" → only if we do it during cutover
- "Can we move X out of cutover?" → yes, rename tables
- **Result:** Made X's speed irrelevant

**Cognitive bias:** **Solution-first thinking** (how to solve stated problem) vs **problem-first thinking** (why is this a problem?)

### 3. Assumption Propagation

**My TRUNCATE approach:**
1. **Assumption:** TRUNCATE is faster than DELETE (generally true)
2. **Inference:** TRUNCATE partitioned table will be faster than DROP partitioned table
3. **Implementation:** TRUNCATE then DROP
4. **Reality:** Both iterate partitions, no benefit

**Failure mode:** Generalized from "TRUNCATE faster than DELETE on single tables" to "TRUNCATE faster on partitioned tables" without checking.

**Lesson:** **Domain-specific knowledge doesn't always transfer.** Partitioned tables have different performance characteristics.

### 4. Insufficient Questioning of Priors

**What I should have asked BEFORE proposing TRUNCATE:**
- "Does TRUNCATE on partitioned tables also iterate partition-by-partition?"
- "What's the actual bottleneck: data removal or catalog updates?"
- "Will removing data first actually help if catalog work remains?"

**What I actually did:**
- Assumed TRUNCATE would help
- Implemented without verification
- Made performance claims without measurement

**Lesson:** **Test assumptions, especially when making optimization claims.**

### 5. Complexity Bias

**Observation:** More complex solutions were proposed before simpler ones:
- Parallel Python threads (complex)
- Shell scripting with parallel (medium complexity)
- Direct catalog manipulation (very complex and dangerous)
- **Simple rename** (only ChatGPT proposed this first)

**Why complexity bias exists:**
- Complex solutions feel more "intelligent"
- Simple solutions seem too obvious ("surely someone thought of that")
- Technical challenge is engaging
- **Forgetting:** Best solution is often the boring one

**Lesson:** **Occam's Razor applies to operations.** Simplest solution that achieves goal is usually best.

### 6. Dangerous "Aggressive Options"

**Web-Claude Option 3** presented direct catalog manipulation as an "aggressive" option "for the brave."

**Why this framing is wrong:**
- Suggests it's a valid trade-off (speed vs risk)
- **Reality:** It's not faster AND it corrupts the database
- "Aggressive" implies "risky but might work"
- **Truth:** "Will definitely break, question is when"

**Proper framing:** "This will corrupt your database. Never do this."

**Lesson:** **When something is fundamentally broken, don't present it as an option.** Clear warnings prevent disasters.

### 7. Failure to Consider Business Context

**Technical mindset:** "488K partitions need to be dropped, this is slow, make it fast"

**Business mindset:** "Users need to use new schema, old schema should stop being used, cleanup can happen anytime"

**Only ChatGPT explicitly connected technical solution to business goal:**
- Downtime affects users
- Cleanup doesn't affect users (if done after cutover)
- Therefore: minimize downtime, don't minimize cleanup time

**Lesson:** **Always trace technical constraints back to business impact.** The real constraint is often different than stated.

---

## What We Got Right

### 1. Empirical Testing
- Ran Phase 4 cutover to observe actual behavior
- Cancelled when performance didn't match expectations
- Measured partition-by-partition iteration
- **Didn't assume, verified**

### 2. Seeking Multiple Perspectives
- Consulted 4 different AI systems
- Got diverse approaches
- Allowed comparison and pattern recognition

### 3. Critical Analysis
- Didn't accept first solution
- Created detailed comparison document
- Analyzed failure modes
- Questioned proposals

### 4. User Intervention
**Critical moments where user stopped bad path:**
- "cancel and start over" (stopped slow DROP)
- "just remove the confirmation pls" (simplified when complexity wasn't helping)
- "no the other one is already running!" (caught redundant script creation)
- "ok stop the script pls" (stopped ineffective TRUNCATE)
- "we're not working on the problem now, we're working on why we got so many bad proposals" ⭐

**Lesson:** **Human oversight is essential.** AI can generate solutions, but human judgment catches systemic errors.

---

## Key Takeaways

### For AI Systems (Including Me)

1. **Question the question**
   - "How do I make X faster?" might not be the right question
   - Ask "Why does X need to be fast?" and "Does X need to happen at all?"
   - **Reframe before optimizing**

2. **Separate technical constraints from business constraints**
   - DROP takes 2 hours (technical constraint)
   - Downtime affects users (business constraint)
   - These can be decoupled (rename approach)

3. **Test assumptions before implementation**
   - "TRUNCATE will be faster" → verify on partitioned tables first
   - "Parallel will help" → confirm catalog locks don't serialize
   - **Measure, don't assume**

4. **Prefer simple solutions**
   - Complex (parallel Python) came before simple (rename)
   - **Default to simplest approach that achieves goal**

5. **Domain knowledge has boundaries**
   - Single table optimizations ≠ partitioned table optimizations
   - **Check whether knowledge transfers to new context**

6. **Never present dangerous options as "aggressive alternatives"**
   - Catalog manipulation will corrupt database
   - Not a risk/reward trade-off, just risk
   - **Clear warnings prevent disasters**

### For Humans Working with AI

1. **Frame questions carefully**
   - "Speed up X" biases toward optimization
   - "Minimize impact of Y" opens solution space
   - **Ask for outcomes, not methods**

2. **Demand empirical verification**
   - "Will this be faster?" → "Test it"
   - Performance claims need measurement
   - **Trust, but verify**

3. **Watch for solution convergence vs divergence**
   - 4 AIs proposing parallel drops → groupthink possible
   - 1 AI proposing different approach → investigate why
   - **Diversity of approaches is signal**

4. **Intervene when complexity escalates**
   - Multiple scripts, versions, approaches → stop and reset
   - **Simplicity is a feature**

5. **Separate analysis from execution**
   - "Stop acting, start analyzing" (what user did)
   - Prevents action-before-understanding
   - **Think, then act**

### Technical Lessons

1. **PostgreSQL partitioning limits**
   - 244K partitions is ~250x recommended limit (~1000)
   - Many operations are O(n) in partition count
   - **Design constraint: don't create 100K+ partitions**

2. **DROP/TRUNCATE on partitioned tables**
   - Both iterate partitions for catalog updates
   - No performance difference
   - **Bottleneck is catalog, not data**

3. **Rename is atomic and fast**
   - Updates parent table metadata only
   - Doesn't walk partitions
   - **Seconds instead of hours**

4. **Catalog operations are serial**
   - pg_class, pg_inherits, pg_constraint updates serialize
   - Parallelism may not help due to lock contention
   - **Test before assuming parallelism helps**

---

## Comparison to Previous Lessons Learned

### Similarities to "Verifying By-Hash Integrity" (2025-10-04)
- **Same pattern:** Assumed something worked, didn't verify exhaustively
- **Same lesson:** Test assumptions before declaring success
- **Previous:** Assumed byhash storage was correct
- **This time:** Assumed TRUNCATE would be faster

### Similarities to "Partition Migration Postmortem" (2025-10-05)
- **Same pattern:** Incomplete understanding of PostgreSQL behavior
- **Same lesson:** Don't assume, read docs and test
- **Previous:** DETACH/ATTACH fails with parent-level FK
- **This time:** TRUNCATE/DROP both iterate partitions

### Meta-Pattern Emerging
**We keep making assumptions about PostgreSQL behavior without testing.**

**Root cause:** PostgreSQL has complex behavior that doesn't always match intuition:
- Partitioning (declarative vs inheritance)
- FK constraints (parent-level vs partition-level)
- Catalog operations (serial vs parallel)

**Solution:** **Default to "verify first" when dealing with PostgreSQL internals.**

---

## Action Items

### Immediate
- [x] Document this lesson learned
- [ ] Review comparison document structure (per ChatGPT feedback)
- [ ] Verify actual schema before cutover (inode vs blobs clarification)

### Future Prevention
- [ ] When proposing optimization, explicitly verify assumption on small test case first
- [ ] When solving performance problem, ask "does this operation need to be in critical path?"
- [ ] When multiple AIs agree on complex solution, check if simpler solution exists
- [ ] For PostgreSQL operations on partitioned tables, consult docs first

### Documentation
- [ ] Add to project guidelines: "Question performance problems before optimizing them"
- [ ] Update CLAUDE.md: "For PostgreSQL partitioned tables, verify behavior before assuming"

---

## Conclusion

**The Problem:** 488K partitioned tables take 1-2 hours to drop

**Wrong question:** "How do we make DROP faster?"
- Led to: TRUNCATE optimization, parallel drops, catalog manipulation

**Right question:** "How do we minimize user-facing downtime?"
- Led to: Rename approach (seconds of downtime, cleanup happens later)

**Core insight:** "The right solution often isn't 'make the slow thing fast' but 'make the slow thing irrelevant to users.'"

**Why we got it wrong:**
1. Solved stated problem instead of questioning it
2. Technical optimization bias (make X faster)
3. Assumed without testing (TRUNCATE, parallelism)
4. Complexity bias (complex before simple)
5. Failed to connect technical constraint to business goal

**Why ChatGPT got it right:**
1. Questioned whether DROP must block cutover
2. Separated business goal (minimize downtime) from technical constraint (DROP is slow)
3. Proposed simple solution (rename) before complex ones
4. Explicitly connected solution to user impact

**Meta-lesson for AI collaboration:**
When multiple AI systems independently propose complex solutions to a simple problem, the human should:
1. Stop and question the problem framing
2. Ask "what's the actual goal here?"
3. Look for the simple solution everyone missed
4. **Be skeptical of consensus on complexity**

---

## References

- Original problem statement: `docs/partition-drop-performance-problem.md` (removed)
- Comprehensive comparison: `docs/partition-drop-solutions-comparison.md`
- PostgreSQL partitioning docs: https://www.postgresql.org/docs/current/ddl-partitioning.html
- Related lesson: `docs/lessons/lessons-learned-verifying-byhash-integrity-2025-10-04.md`
- Related lesson: `docs/lessons/partition-migration-postmortem-2025-10-05.md`

---

**Date:** 2025-11-16
**Incident:** PostgreSQL partition drop migration planning
**Duration:** ~4 hours of analysis across 5 AI systems
**Outcome:** Correct solution identified (rename approach), comprehensive analysis of failure modes documented
**Status:** Ready for implementation when needed
