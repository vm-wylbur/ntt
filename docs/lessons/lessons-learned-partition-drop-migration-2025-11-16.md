<!--
Author: PB and Claude
Date: Sat 16 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/lessons/lessons-learned-partition-drop-migration-2025-11-16.md
-->

# Lessons Learned: PostgreSQL Partition Drop Migration (2025-11-16)

## Executive Summary

**The Situation:** Migrating from partitioned schema (488,362 partition tables) to unpartitioned schema with minimal downtime.

**What We Asked:** "How do we drop these partition tables faster?"

**What We Got:** Multiple approaches to optimize DROP operations, plus one approach to defer DROP to background.

**What We Should Have Asked:** "What's the fastest way to have users on new schema without the old database?"

**The Lesson:** We asked for a solution instead of stating the problem. AIs answered what we asked, not what we needed.

---

## What Actually Happened

### The Original Question
"DROP TABLE CASCADE on 244K partitions takes 52+ hours. How do we make it faster?"

### The Responses
- Claude: TRUNCATE first, then DROP (didn't help, same O(n) catalog updates)
- Kimi: Parallel Python threads (catalog locks would serialize anyway)
- Gemini: Parallel shell processes (same serialization issue)
- ChatGPT: Rename for instant cutover, DROP in background (solved downtime problem)
- Web-Claude: Multiple options including DETACH approaches

### What We Implemented
ChatGPT's rename approach:
```sql
-- Instant cutover (5-10 seconds)
ALTER TABLE path RENAME TO path_old_to_drop;
ALTER TABLE inode RENAME TO inode_old_to_drop;
ALTER TABLE paths_provisional RENAME TO paths;
ALTER TABLE blobs_provisional RENAME TO blobs;

-- Background cleanup
DROP TABLE path_old_to_drop CASCADE;  -- Would take 52+ hours
DROP TABLE inode_old_to_drop CASCADE;
```

**Result:** Cutover in seconds ✅, but cleanup running indefinitely in background.

### What We Eventually Did
User's suggestion after 3 hours of background DROP:
```bash
# Create new database, copy 3 tables, drop old database
createdb cj_new
pg_dump -t medium -t blobs -t paths copyjob | psql cj_new
dropdb copyjob
ALTER DATABASE cj_new RENAME TO copyjob;
```

**Result:** ~1 hour total, clean slate.

---

## The Real Problem: We Asked For A Solution

### What We Said
"How do we speed up dropping 488,362 partitioned tables?"

**This framing assumes:**
- We must drop these specific tables
- The database must remain
- Speed of DROP is the constraint

### What We Should Have Said
"We need users on new schema ASAP. Old schema has 244K partition tables we don't need anymore. What's the fastest path?"

**This framing asks:**
- What's the end state?
- What are we willing to trade?
- Are there alternative approaches?

### Why This Matters

**Question 1:** "How do I make DROP faster?"
- Answer space: TRUNCATE, parallelism, DETACH, catalog manipulation
- All answers assume DROP is necessary
- AIs optimize the stated operation

**Question 2:** "What's fastest way to new schema without old database?"
- Answer space: rename tables, copy database, dual databases, etc.
- Broader solution space
- Includes "don't DROP at all"

**The lesson:** This is standard consulting frustration. Client asks for solution instead of stating problem. Consultant answers what was asked, not what was needed.

---

## Evaluating The Approaches

### Rename Approach (ChatGPT)

**What it solved:**
- ✅ Minimal downtime (5-10 seconds)
- ✅ Users on new schema immediately
- ✅ Simple, reversible (just rename back)

**What it didn't solve:**
- ❌ 52+ hour background cleanup
- ❌ Database remains bloated until cleanup completes
- ❌ Running process consuming resources indefinitely

**Was this "wrong"?** No. It solved the stated problem (minimize downtime). The 52-hour cleanup is annoying but doesn't impact operations if you have disk space and aren't in a hurry.

**When to use it:** You have disk space, background cleanup is acceptable, you want simple rollback.

### Database Copy Approach (User's suggestion)

**What it solves:**
- ✅ Fast total time (~1 hour)
- ✅ Clean slate, no partition baggage
- ✅ Old database fully gone

**What it doesn't solve / introduces:**
- ❌ Requires 2x disk space temporarily (160GB × 2 = 320GB)
- ❌ Risk of data drift if writes happen during copy
- ❌ More complex rollback (can't just un-rename)
- ❌ Loses audit trail/history in system catalogs
- ❌ Must recreate permissions, extensions, settings
- ❌ Connection strings must be updated

**Was this "obviously better"?** No. It trades disk space and complexity for speed. Different tradeoff.

**When to use it:** You need cleanup done fast, have disk space for copy, don't need rollback, can afford one-time migration complexity.

### Parallel DROP Approaches (Kimi, Gemini)

**What they tried to solve:**
- Make DROP faster through parallelism

**Why they likely wouldn't help:**
- Catalog updates serialize (pg_class, pg_inherits, pg_constraint locks)
- Might get some speedup, but not linear
- Added complexity for uncertain gain

**Were they "wrong"?** No. They're reasonable approaches to try. Would need benchmarking to know actual speedup.

**When to try it:** You've committed to DROP, have time to test, and can measure actual parallelism benefit.

---

## What We Measured

### DROP TABLE CASCADE Performance
- **Rate:** ~78 partitions/minute
- **Total partitions:** 244,181
- **Estimated time:** 244,181 ÷ 78 ≈ 3,130 minutes ≈ **52 hours**

This is the useful data point. This tells you "don't even try" if you're in a hurry.

### Why Our Initial Estimate Was Wrong
- Ran for 52 minutes before cancellation
- Extrapolated to "1-2 hours"
- **Didn't measure rate**, just guessed
- Actual measurement showed 25-50x longer

**Lesson:** Measure rates, don't guess durations.

---

## The Actual Lessons (Without The Drama)

### 1. Ask For Outcomes, Not Solutions

**What happened:**
- We asked: "How do we speed up DROP?"
- AIs answered that question
- We later realized we wanted: "How do we get to new schema fastest?"

**Better approach:**
- State the problem: "Need users on new schema ASAP, old schema is 244K partitions"
- State constraints: "Have X disk space, Y time budget, Z rollback requirements"
- Ask: "What are the options?"

**This isn't an AI failure.** This is normal consulting dynamics. You ask for X, you get X. If you needed Y, ask for Y.

### 2. Different Objectives, Different Solutions

**Minimize downtime:** Rename approach is great (5-10 seconds)

**Minimize total time:** Database copy might be better (~1 hour)

**Minimize disk usage:** Accept the 52-hour cleanup, it's in background

**Maximize rollback simplicity:** Rename approach (just rename back)

These are different objectives with different optimal solutions. The "best" answer depends on what you're optimizing for.

### 3. Stated Problem ≠ Actual Problem

**Stated:** "DROP partition tables faster"

**Actual:** "Get off old schema onto new schema"

DROP was a means to an end, not the end itself. When the means proves impractical, question whether it's necessary.

**This happens everywhere:**
- "Make this query faster" → maybe cache it instead
- "Fix this bug" → maybe remove the feature
- "Optimize this code" → maybe don't run it

**The pattern:** When optimization seems hard, question if you're solving the right problem.

### 4. Measure, Don't Guess

**We guessed:** "1-2 hours for cleanup"

**We measured:** 78 partitions/minute → 52 hours

**Orders of magnitude matter.** 2 hours is "annoying," 52 hours is "never finishes." Measurement revealed this wasn't viable.

### 5. Trade-offs, Not "Wrong" vs "Right"

**Rename approach trades:**
- ✅ Minimal downtime, simple rollback
- ❌ Long cleanup time, bloated database

**Database copy trades:**
- ✅ Fast total time, clean slate
- ❌ 2x disk space, complex migration

Neither is "right" or "wrong." They optimize for different things. Choose based on your constraints.

---

## What The AIs Did Well

### ChatGPT
- Separated downtime from cleanup time
- Provided simple, tested approach (rename)
- Explicitly stated what it optimized for (user impact)

### Gemini
- Explained WHY operations are slow (catalog overhead)
- Correctly identified bottleneck
- Warned against filesystem manipulation

### Kimi
- Provided working code
- Identified parallelism as potential approach

### Web-Claude
- Multiple options with tradeoffs
- Warned about risks (when I presented catalog manipulation)

### Claude (me)
- Empirical testing (ran the migration, observed behavior)
- Measured actual rate (78 partitions/min)
- Created comparison analysis

---

## What The AIs (Including Me) Could Have Done Better

### 1. Question The Framing
None of us said: "Wait, why do you need to DROP these tables? What's the actual goal?"

We all accepted the framing and optimized within it.

### 2. Propose Database Copy Earlier
When the problem is "old database is bloated with stuff we don't need," database copy is an obvious option. None of us suggested it until the user did.

**Why we missed it:**
- Focused on table-level operations (the stated problem)
- Didn't think to question database-level architecture
- Assumed "already created new tables" meant we were committed to that approach

### 3. Be More Explicit About Tradeoffs
Responses presented solutions without clearly stating what they optimize for and what they sacrifice.

**Better:** "Rename optimizes for minimal downtime but accepts long cleanup. Database copy optimizes for total time but requires 2x disk space."

---

## The Honest Assessment

### Was The Rename Approach Wrong?
**No.** It solved the stated problem (minimize downtime). The 52-hour cleanup is a resource consumption issue, not an operational failure.

### Was The Database Copy Approach Obviously Better?
**No.** It's better for *our specific constraints* (wanted cleanup done, had disk space). Different constraints would favor different approaches.

### Did The AIs "Fail"?
**No.** They answered the question that was asked. When we reframed to "could we create a new database," the response was "yes, here's how."

### What's The Real Lesson?
**Ask for outcomes, not solutions.**

State your problem and constraints, not the solution you think you need. Let the solution space be explored.

This isn't an AI-specific lesson. This is how consulting has always worked.

---

## Recommendations For Next Time

### When Asking For Help

1. **State the problem:** "Need to migrate to new schema with minimal user impact"
2. **State constraints:** "Have 200GB disk space, 2-hour time budget, need rollback option"
3. **Ask open-ended:** "What are the options?"
4. **Don't assume solution:** Not "how do I make DROP faster" but "how do I achieve X"

### When Evaluating Proposals

1. **Check what they optimize for:** Downtime? Total time? Disk space? Complexity?
2. **Ask about tradeoffs:** What does this sacrifice to achieve that benefit?
3. **Measure, don't guess:** Get actual rates, calculate actual times
4. **Consider alternatives:** Are there different operations that achieve the same goal?

### When Something Seems Hard

1. **Question the operation:** Do we need to do this at all?
2. **Question the level:** Are we operating at the wrong level? (table vs database)
3. **Question the framing:** Is this the actual problem or a means to an end?
4. **Measure the difficulty:** Is this "slow" or "impossible in reasonable time"?

---

## Technical Data Points (Useful For Future)

### PostgreSQL Partition DROP Performance
- **Rate:** 78 partitions/minute (measured on our system)
- **Bottleneck:** Catalog updates (pg_class, pg_inherits, pg_constraint)
- **Parallelism:** Unlikely to help significantly (catalog locks serialize)
- **Scale:** 244K partitions → 52+ hours
- **Recommendation:** Don't create 100K+ partition tables

### Database Copy Performance
- **Size:** 160GB (3 tables: medium, blobs, paths)
- **Time:** ~30-60 minutes (pg_dump | psql)
- **Disk requirement:** 2x space temporarily
- **Schema migration:** Straightforward (pg_dump --schema-only)

### Rename Performance
- **Cutover time:** 5-10 seconds (just metadata updates)
- **Risk:** Very low (atomic, reversible)
- **Limitation:** Old database remains until manual cleanup

---

## Conclusion

**What we asked:** "How do we drop partition tables faster?"

**What we got:** Several approaches to optimize DROP, plus one approach to defer it.

**What we needed:** "Fastest path to clean database with new schema."

**What we learned:**
1. Ask for outcomes, not solutions
2. Different objectives → different optimal solutions
3. Measure, don't guess
4. When optimization seems impossibly hard, question if you're solving the right problem

**The database copy approach is good for our constraints.** But it's not "obviously right" — it trades disk space and migration complexity for speed.

**The rename approach wasn't wrong.** It solved the stated problem. We just hadn't thought through the consequences of 52-hour cleanup.

**The AIs answered what was asked.** Not an AI failure, just standard "client asked for solution instead of stating problem" dynamics.

**The real insight:** This is a lesson in problem framing, not AI limitations or PostgreSQL quirks.

---

## References

- Comprehensive comparison: `docs/partition-drop-solutions-comparison.md`
- PostgreSQL docs: https://www.postgresql.org/docs/current/ddl-partitioning.html
- Related: `docs/lessons/lessons-learned-verifying-byhash-integrity-2025-10-04.md` (measure, don't assume)
- Related: `docs/lessons/partition-migration-postmortem-2025-10-05.md` (test PostgreSQL assumptions)

---

**Date:** 2025-11-16
**Incident:** PostgreSQL partition drop migration
**Key measurement:** 78 partitions/minute DROP rate → 52+ hours for 244K partitions
**Approaches:** Rename (minimize downtime) vs Database copy (minimize total time)
**Lesson:** Ask for outcomes, not solutions. State problems, not implementation.
