<!--
Author: PB and Claude
Date: Sat 16 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/lessons/lessons-learned-partition-drop-migration-2025-11-16.md
-->

# Lessons Learned: PostgreSQL Partition Drop Migration (2025-11-16)

## Executive Summary

**The Objective:** Migrate from partitioned schema (488,362 partition tables) to unpartitioned schema (3 tables: paths, blobs, medium) with minimal user impact.

**What Actually Happened:** We spent hours solving increasingly complex technical problems without questioning whether we were working toward the right objective.

**The Simple Solution:** Create new database, copy 3 tables (~160GB, 30-60 min), drop old database (1 second), rename new database (1 second). Total: ~1 hour.

**What We Did Instead:** Debated 9 different approaches across 5 AI systems for 4 hours, implemented a "fast cutover" that left background cleanup running for 3+ hours with no end in sight (would have taken 52+ hours), then killed it all and started over with the simple solution.

**The Core Lesson:** We repeatedly solved stated technical problems (make DROP faster, minimize cutover downtime) without stepping back to ask: **"What's the actual objective, and what's the simplest path to achieve it?"**

Every "solution" we tried optimized for a narrower and narrower framing of the problem. The human finally cut through all of it and said: "Just copy what we need and drop the rest."

---

## The Objective (What We Should Have Started With)

### Business Goal
**Users need to start using the new unpartitioned schema immediately and never see the old partitioned schema again.**

That's it. That's the entire goal.

### Constraints
- 488,362 partition tables exist (path partitions: 244,181, inode partitions: 244,181)
- New schema already prepared: `paths_provisional` (231M rows, 146GB), `blobs_provisional` (ready)
- ~160GB of data we want to keep
- Everything else is garbage

### Success Criteria
1. Users can query new schema
2. Old schema cannot be queried (prevent accidents)
3. Minimal total time (users care about "when is it done?" not "how long was downtime?")

### Working Backward From The Objective

**If those are the goals, what's the simplest solution?**
1. Create new database with new schema
2. Copy data we need
3. Switch users to new database
4. Delete old database

**Estimated time:** ~1 hour (mostly data copy)

**Risks:** Low (standard operations, well-tested, reversible until final DROP)

**That's the solution.** Everything we actually did was a detour.

---

## The Journey: How We Got Lost

### Wrong Path #1: "Make DROP TABLE CASCADE Faster"

**The Narrow Framing:** "We need to drop 488K partition tables. DROP TABLE CASCADE takes 1-2 hours. How do we make it faster?"

**Why This Framing Was Too Narrow:**
- Assumed dropping individual tables was necessary
- Focused on optimizing one operation (DROP)
- Never questioned whether we could avoid DROP entirely

**What We Tried:**

#### Claude's TRUNCATE Optimization
**Logic:** "TRUNCATE removes data faster than DELETE. Empty tables might DROP faster."

```sql
TRUNCATE TABLE path CASCADE;    -- Remove data first
TRUNCATE TABLE inode CASCADE;
DROP TABLE path CASCADE;         -- Then drop empty tables
DROP TABLE inode CASCADE;
```

**Why It Failed:**
- **Narrow assumption:** TRUNCATE behavior on single tables → must apply to partitioned tables
- **Reality:** TRUNCATE on 244K partitions still iterates partition-by-partition for catalog updates
- **Bottleneck misidentified:** Thought it was data, but it's actually catalog operations
- **No benefit**, just moved work around

**User's Response:** "ok stop the script pls" (after observing it go partition-by-partition)

#### Kimi's Parallel DROP
**Logic:** "PostgreSQL serializes DROP operations. Parallelize with Python threads."

```python
from concurrent.futures import ThreadPoolExecutor

def drop_partition(partition_name):
    conn = psycopg2.connect("dbname=copyjob")
    cur.execute(f"DROP TABLE {partition_name};")

with ThreadPoolExecutor(max_workers=10) as executor:
    executor.map(drop_partition, partition_names)
```

**Why This Was Too Narrow:**
- **Narrow assumption:** Parallelism always helps
- **Ignored:** Catalog locks serialize anyway (pg_class, pg_inherits updates)
- **Optimization bias:** "Make X faster" instead of "Do we need X?"

#### Gemini's Parallel Shell Approach
**Logic:** "Generate DROP commands, execute in parallel shell processes."

```sql
SELECT 'DROP TABLE ' || tablename || ' CASCADE;' FROM pg_tables WHERE ...
```
```bash
split -l 10000 drop_commands.sql chunk_*
for chunk in chunk_*; do psql -f $chunk & done
```

**Why This Was Too Narrow:**
- **Narrow assumption:** Shell parallelism bypasses catalog locks
- **Same bottleneck:** Still serialized by PostgreSQL internally
- **Complex implementation** for no actual benefit

**Pattern:** All three approaches accepted "we must DROP these tables" and optimized for DROP speed. None questioned whether DROP was the right operation.

---

### Wrong Path #2: "Minimize Cutover Downtime" (Partial Success)

**The Slightly Broader Framing:** "Dropping during cutover causes hours of downtime. How do we minimize downtime?"

**This Was Better:** Separated user-facing impact (downtime) from background work (cleanup).

#### ChatGPT's Rename Approach ⭐
**Logic:** "Rename tables for instant cutover, drop old tables later."

```sql
-- Instant cutover (seconds)
BEGIN;
ALTER TABLE path RENAME TO path_old_to_drop;
ALTER TABLE inode RENAME TO inode_old_to_drop;
ALTER TABLE paths_provisional RENAME TO paths;
ALTER TABLE blobs_provisional RENAME TO blobs;
COMMIT;

-- Background cleanup (hours, but users don't see it)
DROP TABLE path_old_to_drop CASCADE;
DROP TABLE inode_old_to_drop CASCADE;
```

**Why This Was Better:**
- **Broader thinking:** Decoupled cutover from cleanup
- **Business-focused:** Optimized for user impact, not total time
- **Simple:** Standard SQL, low risk

**What We Got Right:**
- ✅ Cutover WAS instant (5-10 seconds)
- ✅ Users saw new schema immediately
- ✅ Downtime minimized

**What We Got Wrong:**
- ❌ Assumed background DROP would "eventually finish" (1-2 hours)
- ❌ Didn't validate cleanup time estimate
- ❌ **Still accepted that we must DROP 244K individual tables**

---

### The Reality Check: Rename Was Only 90% Right

**What Actually Happened:**
- Cutover: ✅ 5-10 seconds (perfect)
- Background cleanup: Started `DROP TABLE inode_old_to_drop CASCADE;`
- After 3 hours: Still running, no end in sight
- After killing it: Would have taken **52+ hours** (244K partitions at ~78/min)

**Why Our Estimate Was Wrong:**
- Initial test ran 52 minutes before cancellation
- We extrapolated to "1-2 hours"
- **Reality:** 244,181 partitions ÷ 78 partitions/min = **3,130 minutes = 52 hours**
- Our estimate was off by **25-50x**

**What This Revealed:**
Even the "correct" solution (rename approach) still carried a hidden assumption: **"Eventually we must DROP these 244K tables."**

That assumption was never questioned by any of the 5 AI systems.

---

### The Actual Solution: Don't DROP What You Can Avoid

**The Human's Insight:** "we're going to create a new db cj_new. we'll copy the paths, blobs, and medium table to it. we'll drop copyjob. we'll rename cj_new."

**Why This Works:**
```
Operation                    Old Approach              New Approach
─────────────────────────────────────────────────────────────────────
Remove partition tables      DROP 244K tables          DROP 1 database
                            (52+ hours, never ends)    (1 second)

Keep needed data             Already in new tables     Copy 3 tables
                            (done, but old DB bloated) (~30-60 min)

Total time                   52+ hours                 ~30-60 minutes
Risk                         Medium (long-running)     Low (standard ops)
```

**The Simplicity:**
1. Create cj_new database: `<1 second`
2. Copy schema: `pg_dump --schema-only | psql cj_new` (~5 seconds)
3. Copy data: `pg_dump --data-only | psql cj_new` (~30-60 min for 160GB)
4. Drop copyjob: `DROP DATABASE copyjob;` (~1 second)
5. Rename: `ALTER DATABASE cj_new RENAME TO copyjob;` (~1 second)

**Why We Didn't Think Of This:**

1. **Table-level thinking:** All AIs focused on table operations (DROP TABLE, ALTER TABLE)
   - **Database-level thinking:** The human thought "just make a new database"

2. **Sunk cost bias:** We already created new tables inside existing database
   - **Fresh start:** Database copy ignores sunk costs

3. **Optimization mindset:** "How do we optimize this operation?"
   - **Replacement mindset:** "What if we do a different operation entirely?"

4. **PostgreSQL internals focus:** Debated catalog updates, partition pruning, parallelism
   - **Simple operations:** Copy, drop, rename - things we do every day

5. **Complex before simple:** Assumed simple solution must have been considered and rejected
   - **Occam's Razor:** Simplest solution is often correct

---

## Why ALL The AIs Got It Wrong

### Five AI Systems Consulted
- Claude (me): TRUNCATE optimization, analysis
- ChatGPT: Rename approach (90% right)
- Gemini: Parallel shell drops
- Kimi: Parallel Python drops
- Web-Claude: 4 options including catalog manipulation

### What They All Proposed
| AI System   | Approach                              | Framing                    |
|-------------|---------------------------------------|----------------------------|
| Claude      | TRUNCATE then DROP                    | Make DROP faster           |
| Kimi        | Parallel Python threads               | Make DROP faster           |
| Gemini      | Parallel shell + generated SQL        | Make DROP faster           |
| Web-Claude  | DETACH CONCURRENTLY + parallel        | Make DROP faster           |
| ChatGPT     | Rename, background DROP               | Defer DROP (best so far)   |

### What NONE Of Them Proposed
**"Create new database, copy what you need, drop old database."**

### Root Causes (Why We All Missed It)

#### 1. Problem Framing Determined Solution Space

**How question was framed:** "How do we speed up dropping 488,362 partitioned tables?"

**What this framing assumes:**
- We must drop these specific tables
- Speed is the metric
- Table-level operations are the domain

**Better framing:** "How do we get users onto new schema with minimal total time?"

**What this opens up:**
- Maybe we don't drop old tables, we drop old database
- Total time is the metric
- Any operation is fair game

**The Lesson:** Questions contain hidden assumptions. AI systems tend to solve the question as-stated rather than questioning the framing.

#### 2. Technical Optimization Bias

**All AIs immediately jumped to:**
- How do we make X faster?
- Can we parallelize?
- What's the bottleneck?
- How do we optimize?

**None asked:**
- Why are we doing X?
- What's the actual goal?
- Is there a different operation that achieves the same goal?
- What's the simplest solution?

**The Bias:** Technical sophistication feels like intelligence. Simple solutions feel like we're not trying hard enough.

#### 3. Domain Expertise Can Blind

**What we knew about PostgreSQL:**
- Partition internals
- Catalog structure
- Lock contention
- DETACH vs DROP semantics
- Parallel execution models

**What this knowledge did:**
- Made us focus on PostgreSQL-specific optimizations
- Made us think in terms of table operations
- Made us miss the obvious database-level operation

**The Lesson:** Expertise can create tunnel vision. Sometimes the solution is outside your domain.

#### 4. Complexity Bias

**Order in which solutions were proposed:**
1. TRUNCATE optimization (medium complexity)
2. Parallel Python threads (high complexity)
3. Parallel shell with generated SQL (medium-high complexity)
4. DETACH PARTITION CONCURRENTLY (high complexity, feature may not exist)
5. Direct catalog manipulation (very high complexity, dangerous)
6. Rename approach (low complexity) ← took longest to propose
7. Database copy (lowest complexity) ← never proposed by AI

**The Pattern:** Complex solutions came first. Simple solution came last (and simplest never came at all).

**Why:**
- Complex feels intelligent
- Simple feels like it must be flawed ("surely someone thought of that")
- We're primed to showcase technical knowledge

**The Lesson:** Default to simplest solution, escalate to complexity only when simple fails.

#### 5. Consensus On Complexity

**When 4 AIs independently proposed parallel drops:**
- Felt like validation ("multiple systems agree!")
- Created groupthink
- Reinforced the framing

**When 1 AI proposed rename approach:**
- Was different, worth investigating
- Still accepted core assumption (must DROP tables eventually)

**The Lesson:** Consensus on complexity should trigger skepticism, not confidence. Diversity of approaches is valuable.

#### 6. Lack of Objective Grounding

**None of the AI proposals explicitly stated:**
"The objective is: users query new schema, never see old schema, minimize total time."

**All proposals implicitly optimized for:**
- Cutover speed
- DROP speed
- Catalog efficiency
- Parallel throughput

**If we'd started with explicit objective:**
"Users need new schema available, don't care about old schema"
→ "So just give them a new database with new schema"
→ Database copy approach

**The Lesson:** Always explicitly state the objective. Technical optimization follows from objective, not vice versa.

---

## The Hierarchy of Solutions

Looking at all approaches, there's a clear hierarchy:

### Level 1: Avoid The Operation Entirely ⭐
**Database copy approach** (the human's solution)
- Don't DROP 244K tables
- DROP 1 database instead
- Copy what you need first
- **Time:** ~1 hour
- **Complexity:** Low
- **Risk:** Low

### Level 2: Move Operation Off Critical Path
**Rename approach** (ChatGPT)
- Don't DROP during cutover
- Rename for instant cutover
- DROP later in background
- **Time:** Seconds (cutover) + 52 hours (cleanup, but hidden)
- **Complexity:** Low
- **Risk:** Medium (cleanup must eventually finish)

### Level 3: Optimize The Operation
**Parallel drops** (Kimi, Gemini, Web-Claude)
- Accept we must DROP
- Try to make DROP faster
- Parallelize, optimize, tune
- **Time:** Maybe faster? (catalog locks likely serialize anyway)
- **Complexity:** Medium-High
- **Risk:** Medium

### Level 4: Accept The Operation
**Sequential DROP CASCADE** (original problem)
- Just run DROP TABLE CASCADE
- Wait for it to finish
- **Time:** 52+ hours
- **Complexity:** Low
- **Risk:** Low (but useless due to time)

**The Insight:** We kept descending the hierarchy (4→3→2) thinking each level was progress. We never ascended to Level 1.

The human went straight to Level 1: "Why are we dropping anything? Just make a new database."

---

## What We Got Right (In Retrospect)

### 1. Empirical Testing
- Ran the migration attempt
- Observed actual behavior
- Cancelled when results didn't match expectations
- Measured partition-by-partition iteration
- **Didn't just assume, we verified**

### 2. Multiple Perspectives
- Consulted 4 different AI systems
- Got diverse approaches
- Compared proposals systematically

### 3. Stopping When Lost
User intervention at critical moments:
- "cancel and start over" (stopped slow DROP)
- "ok stop the script pls" (stopped ineffective TRUNCATE)
- "we're not working on the problem now, we're working on why we got so many bad proposals" ⭐

### 4. Documentation
- Created comprehensive comparison document
- Analyzed failure modes
- This lessons-learned document

### What We Should Have Done Differently

**Before any implementation:**
1. Write down the objective: "Users need new schema, minimal total time"
2. Brainstorm from objective backward: "What operations achieve that?"
3. Database copy would appear on that list
4. Compare total time estimates
5. Choose simplest approach
6. Implement

**What we actually did:**
1. Observed problem: DROP is slow
2. Tried to optimize DROP
3. Hours later, realized we were solving wrong problem

---

## Key Takeaways

### For AI Systems (Including Me)

1. **Start with the objective, work backward**
   - Don't optimize the operation, question if operation is needed
   - "Make X faster" assumes X is necessary
   - Ask: "What's the actual goal? What's the simplest path?"

2. **Question the question**
   - Questions contain hidden assumptions
   - "How do I speed up X?" assumes X must happen
   - Ask: "Why do I need to speed up X? Do I need X at all?"

3. **Default to simplest solution**
   - Complex solutions first = bias
   - Simple solutions should be proposed first, escalate only if they fail
   - Occam's Razor applies to operations

4. **Be suspicious of consensus on complexity**
   - When multiple AIs propose complex solutions, step back
   - Ask: "Is there a simpler solution we all missed?"
   - Complexity consensus may indicate shared framing bias

5. **Domain expertise creates blind spots**
   - Deep knowledge of PostgreSQL internals → table-level thinking
   - Solution may be outside your domain (database-level operations)
   - Ask: "Am I solving this at the wrong level?"

6. **Verify assumptions, especially time estimates**
   - "1-2 hours" was off by 25-50x
   - Extrapolate from measurements, don't guess
   - Test claims before presenting them

### For Humans Working with AI

1. **Frame requests as objectives, not methods**
   - Bad: "How do I make DROP faster?"
   - Good: "Users need new schema with minimal total time"
   - Let AI work backward from objective

2. **Demand explicit objective statement**
   - Make AI write down what success looks like
   - Check if proposed solution actually achieves that
   - Don't let technical optimization obscure goal

3. **Watch for groupthink**
   - Multiple AIs agreeing on complex approach → question it
   - Lack of simple proposals → explicitly ask for them
   - Diversity is signal

4. **Intervene when complexity escalates**
   - Multiple scripts, versions, approaches → stop
   - Step back, restate objective, restart from simple

5. **Trust your instincts**
   - "This seems overly complicated" → it probably is
   - "Surely there's a simpler way" → there probably is
   - **Your insight about database copy was right, all the AIs were wrong**

### Technical Lessons

1. **PostgreSQL partition limits are real**
   - 244K partitions is ~250x recommended limit
   - Many operations are O(n) in partition count
   - Don't create 100K+ partitions

2. **DROP CASCADE on huge partition counts: impossible**
   - Not slow, actually impossible in reasonable time
   - 244K partitions at 78/min = 52 hours
   - Don't even try

3. **Database-level operations beat table-level**
   - `DROP DATABASE` is one catalog operation
   - `DROP TABLE CASCADE` on 244K partitions is 244K operations
   - Think in databases, not tables

4. **Copy is faster than drop**
   - Copying 160GB: ~30-60 minutes
   - Dropping 244K partitions: 52+ hours
   - When in doubt, copy what you need

---

## The Meta-Lesson

**The Pattern:**
1. We observed a problem (DROP is slow)
2. We optimized the operation (TRUNCATE, parallel)
3. We reframed slightly (defer with rename)
4. We never questioned the operation itself (why DROP at all?)
5. The human cut through everything: "Just copy what we need"

**The Core Insight:**

When you find yourself optimizing something that seems fundamentally hard, **stop and ask if you're solving the right problem.**

The right solution often isn't:
- "Make the slow thing fast" (parallel drops)
- "Move the slow thing off critical path" (rename)

It's: **"Don't do the slow thing at all"** (database copy)

**The Human's Contribution:**

After watching 5 AI systems debate increasingly complex solutions for hours, the human said:

> "we're going to create a new db cj_new. we'll copy the paths, blobs, and medium table to it. we'll drop copyjob. we'll rename cj_new."

Simple. Obvious in retrospect. None of the AIs suggested it.

**Why This Matters:**

This is not a PostgreSQL lesson. This is a **problem-solving lesson**.

The technical details (partitions, catalog operations, TRUNCATE vs DROP) were all correct. The analysis was thorough. The comparisons were comprehensive.

But we were solving the wrong problem.

**The ultimate lesson:** Start with the objective. Work backward. Question every assumption. And when a human says "this seems too complicated," listen.

---

## Conclusion

**What we set out to do:** Migrate to unpartitioned schema with minimal user impact

**What we spent 4 hours debating:**
- TRUNCATE optimizations
- Parallel drops
- Catalog manipulation
- Rename approaches
- 9 different technical solutions across 5 AI systems

**What we implemented:** Rename approach (correct for cutover, wrong for cleanup)

**What happened:** 3+ hours of background DROP CASCADE with no end in sight (would have been 52+ hours)

**What we should have done from the start:** Create new database, copy 3 tables, drop old database. 1 hour total.

**The lesson:** We solved increasingly complex technical problems without questioning whether we were working toward the right objective. Every "solution" optimized for a narrower framing. The human finally stepped back and asked: "What's the simplest path to the actual goal?"

The answer was: don't drop 244K things, drop 1 thing. Don't optimize, avoid.

**Final status:** Migration will complete via database copy approach (~1 hour) instead of any approach proposed by AI systems (52+ hours for the "best" AI solution).

---

## References

- Comprehensive comparison: `docs/partition-drop-solutions-comparison.md`
- PostgreSQL docs: https://www.postgresql.org/docs/current/ddl-partitioning.html
- Related: `docs/lessons/lessons-learned-verifying-byhash-integrity-2025-10-04.md` (don't assume, verify)
- Related: `docs/lessons/partition-migration-postmortem-2025-10-05.md` (DETACH/ATTACH fails)

---

**Date:** 2025-11-16
**Incident:** PostgreSQL partition drop migration
**Duration:** ~4 hours of AI analysis + 3+ hours of failed DROP + user sees simple solution in 30 seconds
**Outcome:** Comprehensive lesson in questioning assumptions and working backward from objectives
**Status:** In progress - database copy approach being executed
