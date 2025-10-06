<!--
Author: PB and Claude
Date: Mon 06 Oct 2025 10:46
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/realistic-postgres-assessment-20251006T1046.md
-->

# Realistic PostgreSQL Performance Assessment

## The Problem with AI Guessing

**Initial estimates given (all wrong):**
- "5-10 minutes"
- "another 5-10 minutes (total 20-25 min)"
- "30-40 minutes total"
- "if it's 50% done: another ~40 minutes"

**None of these had any engineering basis.** They were guesses based on:
- Vague intuition about "big database operations"
- Pattern matching to previous (unrelated) operations
- Making up percentages with no data ("50% done")

## What Actually Works: Engineering-Based Analysis

### Step 1: Identify the Operation

```sql
SELECT pid, query, state, wait_event_type, wait_event
FROM pg_stat_activity
WHERE query LIKE '%INSERT INTO path%';
```

**Finding:** PID 554727, INSERT INTO path FROM path_old, running for 43 minutes

### Step 2: Determine Data Volume

```sql
SELECT
    pg_size_pretty(pg_total_relation_size('path_old')) as total_size,
    pg_size_pretty(pg_relation_size('path_old')) as table_size,
    pg_total_relation_size('path_old') as bytes_total
FROM ...;
```

**Finding:**
- Table data: 39 GB
- Total with indexes: 106 GB
- Rows: 123.6M

### Step 3: Check I/O Bottlenecks

```bash
iostat -x 2 2
```

**Finding:**
- nvme1n1: Reading 22 MB/s (source: path_old)
- nvme2n1: Writing 588 MB/s (destination: path partitions)
- sdb: 100% util (irrelevant - not PostgreSQL)

**Initial wrong conclusion:** "Bottlenecked on sdb"

**Correction after checking mounts:**
```bash
df -h | grep postgres
zpool status fastpool
```

- PostgreSQL on ZFS mirror (nvme1n1 + nvme2n1)
- sdb unrelated to this operation
- Actual I/O is fast NVMe

### Step 4: Check CPU vs I/O Bound

```bash
top -b -n 1
ps -p 554727 -o pid,%cpu,time,stat,command
```

**Finding:**
- PID 554727: 48% CPU, 20:36 CPU time consumed
- wait_event: NULL (CPU-bound, not I/O-bound)
- State: Rs (Running)

**Conclusion:** Operation is **CPU-bound**, not I/O-bound. Processing rows, routing to partitions, checking FK constraints.

### Step 5: Acknowledge What We Don't Know

**Cannot determine progress because:**
1. Transaction hasn't committed - `SELECT COUNT(*) FROM path` shows 0
2. `pg_stat_user_tables.n_tup_ins` might be stale
3. No PostgreSQL progress tracking for INSERT SELECT operations
4. Can't see into the transaction's internal state

**What we know:**
- Running for 43 minutes
- Consumed 20:36 CPU time
- Still actively running (48% CPU)
- Processing 123.6M rows from 39 GB table

**What we DON'T know:**
- % complete
- How many rows processed so far
- Estimated time remaining

### Step 6: Accept Uncertainty

**Honest answer:** "I don't know when it will finish. It's been running 43 minutes, still actively processing at 48% CPU. Could finish in 5 minutes or could take another hour. No way to know without progress visibility."

## Key Lessons

### 1. Don't Guess - Gather Data

**Wrong approach:**
- "This seems like it should take X minutes"
- "It's probably Y% done"
- "Usually operations like this take Z time"

**Right approach:**
- Measure actual I/O rates
- Check CPU utilization
- Identify bottlenecks (CPU vs I/O vs lock contention)
- Acknowledge when you can't measure progress

### 2. Distinguish Between Bottlenecks

**I/O-bound operation:**
- `wait_event`: DataFileRead, DataFileWrite
- Low CPU usage
- High disk utilization
- Progress predictable from I/O rate

**CPU-bound operation:**
- `wait_event`: NULL
- High CPU usage
- Modest disk utilization
- Progress unpredictable without row count

**Lock-bound operation:**
- `wait_event`: Lock, transactionid
- Low CPU usage
- Waiting on other transaction
- Progress depends on lock holder

### 3. Know Your System Architecture

**Wrong assumption:** "sdb at 100% util must be the bottleneck"

**Reality check:**
```bash
df -h | grep postgres          # Where is data mounted?
zpool status                   # What devices in the pool?
mount | grep sdb               # Is sdb even involved?
```

**Actual architecture:**
- PostgreSQL on ZFS mirror
- Fast NVMe drives (not sdb)
- sdb unrelated to this operation

### 4. Accept "I Don't Know"

When you can't measure progress, say so:

**Bad:** "It's 50% done, should finish in 40 minutes"

**Good:** "I can't measure progress because the transaction hasn't committed. It's been running 43 minutes and is CPU-bound at 48% CPU. No ETA available."

## Tools Used for Proper Analysis

### PostgreSQL Queries
```sql
-- What's running?
SELECT pid, query, state, wait_event_type, wait_event, now() - query_start
FROM pg_stat_activity
WHERE state = 'active';

-- How much data?
SELECT pg_size_pretty(pg_relation_size('table_name'));

-- What's it waiting on?
SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = X;
```

### System Tools
```bash
# Disk I/O
iostat -x 2 2

# CPU usage
top -b -n 1
ps -p PID -o pid,%cpu,time,stat,command

# Filesystem layout
df -h
mount
zpool status

# What's using a device?
lsof | grep device_name
```

### What NOT to Use
```bash
# NEVER use watch - breaks terminal (per CLAUDE.md)
watch -n 5 "some command"
```

## Summary

**Time spent guessing:** 0 value, misleading

**Time spent gathering data:**
- 2 minutes to run queries
- Clear understanding of bottleneck
- Honest answer about what we don't know

**Result:** Can't predict completion time, but know exactly why (CPU-bound row processing, no progress visibility in uncommitted transaction).

---

**Timestamp:** 2025-10-06 10:46 AM
**Operation:** INSERT INTO path SELECT FROM path_old (123.6M rows, 39 GB)
**Elapsed:** 43 minutes
**Status:** Running, CPU-bound, no ETA available
