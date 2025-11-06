#!/usr/bin/env python3
# Author: PB and Claude
# Date: 2025-11-05
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt_extractor_queue.py
#
# Redis-backed extraction queue with persistence and multi-worker support

import json
import os
import socket
from typing import Optional, Tuple, List

import redis
from loguru import logger


class RedisExtractionQueue:
    """
    Redis-backed extraction queue.

    Features:
    - Persistent across crashes
    - Priority queue (sorted by size)
    - Depth-first (LIFO) for nested archives
    - Multi-worker safe (atomic operations)
    - Deduplication tracking
    """

    # Redis keys
    PRIORITY = 'ntt:extraction:priority'      # Sorted set: {blobid: size}
    NESTED = 'ntt:extraction:nested'          # List: nested archives (LIFO)
    PROCESSED = 'ntt:extraction:processed'    # Set: completed blobids
    IN_PROGRESS = 'ntt:extraction:in_progress'  # Hash: {blobid: worker_id}
    STATS = 'ntt:extraction:stats'            # Hash: counters
    WORKERS = 'ntt:extraction:workers'        # Hash: {worker_id: pid}

    def __init__(self, redis_url: str, worker_id: Optional[int] = None):
        self.redis = redis.from_url(redis_url, decode_responses=True)

        if worker_id:
            self.worker_id = f"{socket.gethostname()}-w{worker_id}-{os.getpid()}"
            # Register worker
            self.redis.hset(self.WORKERS, self.worker_id, os.getpid())
        else:
            self.worker_id = f"{socket.gethostname()}-{os.getpid()}"

    def initialize_from_db(
        self,
        db,
        mime_types: List[str],
        format_filter: Optional[str] = None,
        limit: Optional[int] = None
    ) -> int:
        """
        Seed queue from PostgreSQL.

        Query extractable blobs and push to Redis priority queue.

        Args:
            db: Database connection
            mime_types: List of MIME types to extract (from handler registry)
            format_filter: Optional specific MIME type to filter
            limit: Optional limit on number of blobs
        """
        query = """
            SELECT DISTINCT b.blobid, i.mime_type, MIN(i.size) as size
            FROM blobs b
            JOIN inode i ON i.blobid = b.blobid
            WHERE b.extraction_status = 'pending'
              AND i.mime_type = ANY(%s)
        """

        params = [mime_types]

        if format_filter:
            query += " AND i.mime_type = %s"
            params.append(format_filter)

        query += " GROUP BY b.blobid, i.mime_type ORDER BY size ASC"

        if limit:
            query += " LIMIT %s"
            params.append(limit)

        cursor = db.execute(query, params)
        results = cursor.fetchall()

        # Batch insert with pipeline
        pipe = self.redis.pipeline()

        for row in results:
            blobid = row['blobid']
            mime_type = row['mime_type']
            size = row['size']

            item = json.dumps({'blobid': blobid, 'mime_type': mime_type})
            pipe.zadd(self.PRIORITY, {item: size})

        pipe.execute()

        count = len(results)
        self.redis.hincrby(self.STATS, 'queued', count)

        logger.info(f"Initialized queue with {count:,} blobs")
        return count

    def pop(self) -> Optional[Tuple[str, str]]:
        """
        Get next blob to process.

        Priority:
        1. Nested archives (depth-first)
        2. Smallest blob from priority queue

        Returns: (blobid, mime_type) or None
        """
        # Check nested archives first (depth-first)
        nested = self.redis.rpop(self.NESTED)
        if nested:
            item = json.loads(nested)
            blobid = item['blobid']

            # Check dedup
            if self.redis.sismember(self.PROCESSED, blobid):
                return self.pop()  # Skip, try next

            # Mark in-progress
            self.redis.hset(self.IN_PROGRESS, blobid, self.worker_id)
            return item['blobid'], item['mime_type']

        # Get from priority queue (atomic)
        result = self.redis.zpopmin(self.PRIORITY, 1)
        if not result:
            return None  # Queue empty

        item_json, score = result[0]
        item = json.loads(item_json)
        blobid = item['blobid']

        # Check dedup
        if self.redis.sismember(self.PROCESSED, blobid):
            return self.pop()  # Skip, try next

        # Mark in-progress
        self.redis.hset(self.IN_PROGRESS, blobid, self.worker_id)
        return item['blobid'], item['mime_type']

    def push_nested(self, blobid: str, mime_type: str) -> bool:
        """Add nested archive to queue (depth-first)."""
        # Check dedup
        if self.redis.sismember(self.PROCESSED, blobid):
            return False

        item = json.dumps({'blobid': blobid, 'mime_type': mime_type})
        self.redis.rpush(self.NESTED, item)
        self.redis.hincrby(self.STATS, 'queued', 1)
        return True

    def mark_complete(self, blobid: str):
        """Mark blob successfully processed."""
        pipe = self.redis.pipeline()
        pipe.hdel(self.IN_PROGRESS, blobid)
        pipe.sadd(self.PROCESSED, blobid)
        pipe.hincrby(self.STATS, 'processed', 1)
        pipe.execute()

    def mark_failed(self, blobid: str, error: str):
        """Mark blob as failed."""
        pipe = self.redis.pipeline()
        pipe.hdel(self.IN_PROGRESS, blobid)
        pipe.sadd(self.PROCESSED, blobid)
        pipe.hincrby(self.STATS, 'failed', 1)
        pipe.execute()

    def queue_size(self) -> int:
        """Total items in queue."""
        return self.redis.zcard(self.PRIORITY) + self.redis.llen(self.NESTED)

    def in_progress_count(self) -> int:
        """Items currently being processed."""
        return self.redis.hlen(self.IN_PROGRESS)

    def get_stats(self) -> dict:
        """Get extraction statistics."""
        stats = self.redis.hgetall(self.STATS)
        return {k: int(v) for k, v in stats.items()}

    def get_in_progress_workers(self) -> dict:
        """Get workers with in-progress items."""
        return self.redis.hgetall(self.WORKERS)

    def recover_stuck_jobs(self) -> int:
        """Recover jobs stuck in-progress (crashed workers)."""
        in_progress = self.redis.hgetall(self.IN_PROGRESS)

        # Just clear them - will be re-queried from DB if needed
        if in_progress:
            self.redis.delete(self.IN_PROGRESS)

        return len(in_progress)

    def clear_all(self):
        """Clear entire queue (for reset)."""
        keys = [
            self.PRIORITY,
            self.NESTED,
            self.PROCESSED,
            self.IN_PROGRESS,
            self.STATS,
            self.WORKERS
        ]
        self.redis.delete(*keys)
        logger.info("Cleared all queue data from Redis")
