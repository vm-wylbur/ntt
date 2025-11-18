#!/usr/bin/env python3
# Author: PB and Claude
# Date: 2025-11-16
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt_copier_diagnostics.py
#
# Diagnostic service for ntt-copier intelligent error handling
#

import json
from typing import Optional, Dict, Tuple
from loguru import logger


class DiagnosticService:
    """
    Tracks failures and provides diagnostic analysis for copier errors.

    Phase 4: Minimal implementation for v2.0 schema migration testing.
    Full implementation deferred until copier is working with Redis queue.
    """

    def __init__(self, db_conn, medium_hash: Optional[str], worker_id: str):
        """
        Initialize diagnostic service.

        Args:
            db_conn: PostgreSQL connection (psycopg)
            medium_hash: Medium hash for this worker (optional for global queue)
            worker_id: Worker identifier
        """
        self.conn = db_conn
        self.medium_hash = medium_hash
        self.worker_id = worker_id

        # Track retry counts per inode (in-memory)
        # Key: (medium_hash, ino), Value: retry_count
        self._failure_counts = {}

    def track_failure(self, medium_hash: str, ino: int) -> int:
        """
        Track failure for an inode and return retry count.

        Args:
            medium_hash: Medium hash
            ino: Inode number

        Returns:
            Retry count (starts at 1 for first failure)
        """
        key = (medium_hash, ino)
        self._failure_counts[key] = self._failure_counts.get(key, 0) + 1
        return self._failure_counts[key]

    def diagnose_at_checkpoint(self, medium_hash: str, ino: int, exception: Exception) -> Dict:
        """
        Run diagnostic checks when retry count reaches checkpoint.

        Args:
            medium_hash: Medium hash
            ino: Inode number
            exception: Exception that caused failure

        Returns:
            Findings dictionary with diagnostic results
        """
        findings = {
            'retry_count': self._failure_counts.get((medium_hash, ino), 0),
            'exception_type': type(exception).__name__,
            'exception_msg': str(exception),
            'checks_performed': ['checkpoint'],
            'worker_id': self.worker_id,
        }

        # TODO: Add real diagnostic checks:
        # - Check if file is beyond EOF
        # - Check if medium is degraded
        # - Check filesystem health
        # - Pattern matching on error messages

        return findings

    def should_skip_permanently(self, findings: Dict) -> bool:
        """
        Determine if findings indicate unrecoverable error.

        Args:
            findings: Diagnostic findings from diagnose_at_checkpoint()

        Returns:
            True if error is unrecoverable and should be skipped
        """
        # TODO: Implement real diagnostic logic
        # For now, never skip (conservative approach)
        # Future: detect BEYOND_EOF, bad sectors, etc.
        return False

    def determine_failure_status(self, exception: Exception) -> Tuple[str, str]:
        """
        Classify exception to determine if retryable.

        Args:
            exception: Exception that caused failure

        Returns:
            Tuple of (status, error_type)
            status: 'failed_permanent' or 'failed_retryable'
            error_type: Classification of error (e.g., 'IO_ERROR', 'PERMISSION_DENIED')
        """
        exception_type = type(exception).__name__
        exception_msg = str(exception).lower()

        # Classify based on exception type and message
        if 'permission denied' in exception_msg or 'operation not permitted' in exception_msg:
            return ('failed_permanent', 'PERMISSION_DENIED')
        elif 'no such file' in exception_msg or 'filenotfounderror' in exception_type.lower():
            return ('failed_permanent', 'FILE_NOT_FOUND')
        elif 'io error' in exception_msg or 'ioerror' in exception_type.lower():
            return ('failed_retryable', 'IO_ERROR')
        elif 'timeout' in exception_msg:
            return ('failed_retryable', 'TIMEOUT')
        else:
            # Unknown error - mark as retryable to be conservative
            return ('failed_retryable', 'UNKNOWN')

    def record_diagnostic_event_no_commit(
        self,
        medium_hash: str,
        ino: int,
        findings: Dict,
        action: str
    ):
        """
        Record diagnostic event to database (no commit).

        Args:
            medium_hash: Medium hash
            ino: Inode number
            findings: Diagnostic findings dictionary
            action: Action taken (e.g., 'skipped', 'continuing')
        """
        # TODO: Implement when diagnostic_events table is created
        # For now, just log the event
        logger.debug(
            f"Diagnostic event: medium={medium_hash[:8]} ino={ino} "
            f"action={action} findings={json.dumps(findings)}"
        )

        # Future implementation will INSERT into diagnostic_events table:
        # cur = self.conn.cursor()
        # cur.execute("""
        #     INSERT INTO diagnostic_events (medium_hash, ino, findings, action, worker_id, recorded_at)
        #     VALUES (%s, %s, %s, %s, %s, NOW())
        # """, (medium_hash, ino, json.dumps(findings), action, self.worker_id))

        pass
