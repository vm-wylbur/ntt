#!/usr/bin/env python3
# Author: PB and Claude
# Date: 2025-10-08
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt_copier_diagnostics.py
#
# Diagnostic service for ntt-copier error analysis and retry logic

import subprocess
from pathlib import Path
from loguru import logger


class DiagnosticService:
    """
    Handles error diagnosis and retry logic for NTT copy worker.

    Phase 1: Detection only - logs findings, no behavior change
    Future phases: auto-skip, auto-remount, problem recording

    Design rationale:
    - In-memory retry tracking (acceptable to reset on worker restart)
    - Diagnostic checkpoint at retry #10 (balances transient vs persistent)
    - Separated from Worker class for testability and maintainability
    """

    def __init__(self, db_conn, medium_hash: str, worker_id: str):
        """
        Initialize diagnostic service.

        Args:
            db_conn: psycopg connection (for future problem recording)
            medium_hash: Medium being processed
            worker_id: Worker ID for logging
        """
        self.conn = db_conn
        self.medium_hash = medium_hash
        self.worker_id = worker_id

        # In-memory retry tracking (reset on worker restart - that's OK)
        # Persistent tracking via inode.errors[] array in database
        self.retry_counts = {}  # {(medium_hash, ino): count}

        logger.info(f"DiagnosticService initialized for medium {medium_hash}")

    def track_failure(self, medium_hash: str, ino: int) -> int:
        """
        Track a failure and return current retry count.

        Args:
            medium_hash: Medium hash
            ino: Inode number

        Returns:
            Current retry count for this inode (1-indexed)
        """
        key = (medium_hash, ino)
        self.retry_counts[key] = self.retry_counts.get(key, 0) + 1
        return self.retry_counts[key]

    def diagnose_at_checkpoint(self, medium_hash: str, ino: int,
                               exception: Exception) -> dict:
        """
        Run diagnostics at checkpoint (retry #10).

        Phase 1: Detection only - returns findings dict, doesn't change behavior

        Performs:
        1. Exception message pattern matching
        2. dmesg scan for kernel errors
        3. Mount health check

        Args:
            medium_hash: Medium hash
            ino: Inode number
            exception: Exception that was raised

        Returns:
            dict with:
                - retry_count: int
                - exception_type: str
                - exception_msg: str (truncated to 200 chars)
                - checks_performed: list[str] (what we detected)
        """
        findings = {
            'retry_count': self.retry_counts.get((medium_hash, ino), 0),
            'exception_type': type(exception).__name__,
            'exception_msg': str(exception)[:200],
            'checks_performed': []
        }

        # Check 1: Parse exception message for known patterns
        exc_str = str(exception).lower()

        if 'beyond end of device' in exc_str or 'request beyond eof' in exc_str:
            findings['checks_performed'].append('detected_beyond_eof')
        elif 'i/o error' in exc_str:
            findings['checks_performed'].append('detected_io_error')
        elif 'no such file' in exc_str or 'file not found' in exc_str:
            findings['checks_performed'].append('detected_missing_file')
        elif 'permission denied' in exc_str:
            findings['checks_performed'].append('detected_permission_error')

        # Check 2: Quick dmesg scan for kernel errors
        dmesg_info = self._check_dmesg_simple()
        if dmesg_info:
            findings['checks_performed'].append(f'dmesg:{dmesg_info}')

        # Check 3: Mount health check
        mount_status = self._check_mount_status(medium_hash)
        findings['checks_performed'].append(f'mount_check:{mount_status}')

        return findings

    def _check_dmesg_simple(self) -> str | None:
        """
        Quick dmesg check for obvious filesystem errors.

        Looks for patterns in recent kernel log:
        - "beyond EOF" / "beyond end of device"
        - "FAT-fs" with "error"
        - "I/O error"

        Returns:
            Error type string ('beyond_eof', 'fat_error', 'io_error') or None
        """
        try:
            result = subprocess.run(
                ['dmesg'],
                capture_output=True,
                text=True,
                timeout=2
            )

            if result.returncode != 0:
                return None

            # Check recent lines for errors (last 50 lines)
            recent = result.stdout.split('\n')[-50:]

            for line in recent:
                if 'beyond EOF' in line or 'beyond end of device' in line:
                    return 'beyond_eof'
                if 'FAT-fs' in line and 'error' in line.lower():
                    return 'fat_error'
                if 'I/O error' in line:
                    return 'io_error'

            return None

        except subprocess.TimeoutExpired:
            logger.debug("dmesg check timed out")
            return None
        except Exception as e:
            logger.debug(f"dmesg check failed: {e}")
            return None

    def should_skip_permanently(self, findings: dict) -> bool:
        """
        Decide if we should permanently skip this inode.

        Phase 2: Auto-skip unrecoverable errors
        - BEYOND_EOF: FAT points to sector beyond image boundary
        - IO_ERROR: Stalled ddrescue, bad sectors, unreadable media

        Only skips when we're CERTAIN the error is unrecoverable.
        Requires both exception message AND dmesg kernel confirmation.

        Args:
            findings: dict from diagnose_at_checkpoint()

        Returns:
            True if should skip permanently, False otherwise
        """
        checks = findings['checks_performed']

        # BEYOND_EOF - confirmed unrecoverable
        if 'detected_beyond_eof' in checks or 'dmesg:beyond_eof' in checks:
            logger.info(f"BEYOND_EOF detected - unrecoverable")
            return True

        # I/O ERROR - only skip if confirmed by kernel (dmesg)
        # Requires both exception message AND kernel confirmation to avoid false positives
        if 'detected_io_error' in checks and 'dmesg:io_error' in checks:
            logger.info(f"I/O ERROR detected (confirmed by dmesg) - unrecoverable")
            return True

        return False

    def _check_mount_status(self, medium_hash: str) -> str:
        """
        Check if medium mount point exists and is accessible.

        Args:
            medium_hash: Medium hash

        Returns:
            'ok' - mount point exists and accessible
            'missing' - mount point doesn't exist
            'inaccessible' - mount point exists but can't stat
        """
        mount_point = Path(f"/mnt/ntt/{medium_hash}")

        if not mount_point.exists():
            return 'missing'

        try:
            mount_point.stat()
            return 'ok'
        except Exception:
            return 'inaccessible'

    def record_diagnostic_event_no_commit(self, medium_hash: str, ino: int,
                                          findings: dict, action_taken: str):
        """
        Record diagnostic event in medium.problems JSONB column WITHOUT committing.

        Caller is responsible for commit. This is critical to avoid breaking
        the FOR UPDATE SKIP LOCKED pattern in batch processing.

        Args:
            medium_hash: Medium being processed
            ino: Inode that failed
            findings: dict from diagnose_at_checkpoint()
            action_taken: 'skipped', 'remounted', 'continuing', 'max_retries'
        """
        from datetime import datetime
        import json

        entry = {
            'ino': ino,
            'retry_count': findings['retry_count'],
            'checks': findings['checks_performed'],
            'action': action_taken,
            'timestamp': datetime.now().isoformat(),
            'worker_id': self.worker_id,
            'exception_type': findings.get('exception_type'),
            'exception_msg': findings.get('exception_msg', '')[:100]
        }

        try:
            with self.conn.cursor() as cur:
                cur.execute("""
                    UPDATE medium
                    SET problems = COALESCE(problems, '{}'::jsonb) ||
                                  jsonb_build_object(
                                      'diagnostic_events',
                                      COALESCE(problems->'diagnostic_events', '[]'::jsonb) || %s::jsonb
                                  )
                    WHERE medium_hash = %s
                """, (json.dumps(entry), medium_hash))

            logger.debug(f"Recorded diagnostic event: {action_taken} for ino={ino}")

        except Exception as e:
            logger.error(f"Failed to record diagnostic event: {e}")
            raise
