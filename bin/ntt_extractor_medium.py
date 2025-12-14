#!/usr/bin/env python3
# Author: PB and Claude
# Date: 2025-11-05
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt_extractor_medium.py
#
# Medium and partition management for extracted archives

import hashlib
from datetime import datetime, timezone
from io import StringIO
from typing import List, Tuple, Optional

import blake3
from loguru import logger
import psycopg


class ExtractionMediumManager:
    """
    Manages extracted media and their partitioned tables.

    Handles:
    - Creating extracted medium records
    - Creating partitioned inode/path tables
    - Generating synthetic inodes (hash-based)
    - Bulk COPY inserts for performance
    """

    def __init__(self, db: psycopg.Connection):
        self.db = db

    def create_extracted_medium(
        self,
        source_blobid: str,
        extraction_method: str,
        medium_human: Optional[str] = None
    ) -> str:
        """
        Create extracted medium record and partitions.

        Args:
            source_blobid: The blobid of the archive
            extraction_method: Handler name (e.g., 'gzip', 'tar', 'zip')
            medium_human: Optional human-readable label

        Returns:
            medium_hash for the new extracted medium
        """
        cursor = self.db.cursor()

        # Generate medium_hash from source_blobid + extraction_method
        # This ensures one extraction per unique blob
        combined = f"{source_blobid}:{extraction_method}"
        medium_hash = blake3.blake3(combined.encode()).hexdigest()[:16]

        if not medium_human:
            medium_human = f"extracted-{source_blobid[:8]}-{extraction_method}"

        now = datetime.now(timezone.utc)

        # Insert extracted medium record
        cursor.execute("""
            INSERT INTO medium (
                medium_hash,
                medium_human,
                medium_type,
                source_blobid,
                extraction_method,
                extracted_at
            )
            VALUES (%s, %s, 'extracted', %s, %s, %s)
            ON CONFLICT (source_blobid)
            WHERE medium_type = 'extracted'
            DO UPDATE SET
                extracted_at = EXCLUDED.extracted_at
            RETURNING medium_hash
        """, [medium_hash, medium_human, source_blobid, extraction_method, now])

        result = cursor.fetchone()
        medium_hash = result['medium_hash']  # Dict row, not tuple

        self.db.commit()

        logger.info(
            f"Created extracted medium",
            medium_hash=medium_hash,
            source_blobid=source_blobid,
            method=extraction_method
        )

        return medium_hash

    def generate_synthetic_inode(self, medium_hash: str, path: str) -> int:
        """
        Generate synthetic inode number from hash(medium_hash || path).

        Uses first 8 bytes of BLAKE3 hash as signed int64.
        Ensures uniqueness per medium while being deterministic.
        """
        combined = f"{medium_hash}:{path}"
        hash_bytes = blake3.blake3(combined.encode()).digest()[:8]
        # Convert to signed int64
        inode = int.from_bytes(hash_bytes, byteorder='big', signed=True)
        return inode

    def bulk_insert_files(
        self,
        medium_hash: str,
        files: List[Tuple]
    ) -> int:
        """
        Bulk insert files into paths table using COPY.

        Post-partition-elimination schema stores all file metadata in paths.
        Note: mime_type is stored in blobs table, not paths.

        Args:
            medium_hash: Target medium
            files: List of tuples: (dev, ino, path, mtime, size, blobid)

        Returns:
            Number of rows inserted
        """
        if not files:
            return 0

        cursor = self.db.cursor()

        buf = StringIO()
        for dev, ino, path, mtime, size, blobid in files:
            # Encode path as hex for bytea COPY format
            path_hex = '\\x' + path.encode('utf-8').hex()
            buf.write(f"{medium_hash}\t{dev}\t{ino}\t{path_hex}\t{mtime}\t{size}\t{blobid}\n")

        buf.seek(0)

        with cursor.copy("""
            COPY paths (medium_hash, dev, ino, path, mtime, size, blobid)
            FROM STDIN
        """) as copy:
            copy.write(buf.read())

        count = len(files)
        logger.debug(f"Bulk inserted {count:,} files for {medium_hash}")

        return count

    def mark_extraction_complete(
        self,
        blobid: str,
        files_extracted: int,
        medium_hash: str
    ):
        """Mark blob extraction as complete."""
        cursor = self.db.cursor()

        now = datetime.now(timezone.utc)

        cursor.execute("""
            UPDATE blobs
            SET extraction_status = 'completed',
                extracted_at = %s,
                files_extracted = %s
            WHERE blobid = %s
        """, [now, files_extracted, blobid])

        self.db.commit()

        logger.info(
            f"Marked extraction complete",
            blobid=blobid,
            files=files_extracted,
            medium_hash=medium_hash
        )

    def mark_extraction_failed(
        self,
        blobid: str,
        error: str
    ):
        """Mark blob extraction as failed."""
        cursor = self.db.cursor()

        now = datetime.now(timezone.utc)

        cursor.execute("""
            UPDATE blobs
            SET extraction_status = 'failed',
                extracted_at = %s,
                extraction_error = %s
            WHERE blobid = %s
        """, [now, error, blobid])

        self.db.commit()

        logger.warning(
            f"Marked extraction failed",
            blobid=blobid,
            error=error
        )

    def register_intermediate(
        self,
        intermediate_blobid: str,
        parent_blobid: str
    ):
        """
        Register an intermediate blob (e.g., .tar from .tar.gz).

        Intermediates are marked for later cleanup.
        """
        cursor = self.db.cursor()

        cursor.execute("""
            UPDATE blobs
            SET is_intermediate = TRUE,
                intermediate_of = %s
            WHERE blobid = %s
        """, [parent_blobid, intermediate_blobid])

        self.db.commit()

        logger.debug(
            f"Registered intermediate blob",
            intermediate=intermediate_blobid,
            parent=parent_blobid
        )
