#!/usr/bin/env python3
"""
NTT Copier Processor Chain - Chain of Responsibility pattern for inode processing

This module implements a clean pipeline for processing inodes with different types
(files, directories, symlinks) and handles both legacy data (13M+ records with
NULL fs_type) and new data from updated enumeration.

Architecture Overview:
=====================
The processor chain works like a linked list of handlers. Each processor:
1. Performs its specific task (detect type, skip directories, detect MIME, etc.)
2. Passes the context to the next processor if should_process=True
3. Can short-circuit the chain by setting should_process=False

Pipeline Construction:
    FileTypeDetector(
        DirectoryHandler(
            SymlinkHandler(
                MimeTypeDetector(
                    FileProcessor()))))

Creates this chain:
    FileTypeDetector → DirectoryHandler → SymlinkHandler → MimeTypeDetector → FileProcessor

Processing Flow:
1. Context enters with inode data
2. FileTypeDetector: Detects fs_type if NULL (legacy data)
3. DirectoryHandler: If directory, marks and exits
4. SymlinkHandler: If symlink, marks and exits
5. MimeTypeDetector: Detects MIME type for files
6. FileProcessor: Actually copies/hashes/dedupes the file

Early Exit Example:
- If DirectoryHandler detects a directory, it sets should_process=False
- The chain stops immediately, later processors never run
- This prevents wasted processing on non-files

Author: PB and Claude
Date: 2025-09-28
License: (c) HRDAG, 2025, GPL-2 or newer
"""

import os
import shutil
from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
import blake3


@dataclass
class InodeContext:
    """Carries all context through the processing pipeline."""
    row: dict
    source_path: Path
    fs_type: Optional[str] = None
    mime_type: Optional[str] = None
    should_process: bool = True
    skip_reason: Optional[str] = None
    hash_value: Optional[str] = None
    temp_path: Optional[Path] = None


class InodeProcessor(ABC):
    """Base processor in the chain."""

    def __init__(self, next_processor: Optional['InodeProcessor'] = None):
        self.next = next_processor

    def process(self, context: InodeContext, worker) -> InodeContext:
        """Process and pass to next in chain."""
        context = self.handle(context, worker)
        if self.next and context.should_process:
            return self.next.process(context, worker)
        return context

    @abstractmethod
    def handle(self, context: InodeContext, worker) -> InodeContext:
        """Handle this step of processing."""
        pass


class FileTypeDetector(InodeProcessor):
    """Detects filesystem type if unknown (for 13M+ legacy records)."""

    def handle(self, context: InodeContext, worker) -> InodeContext:
        # If fs_type already known (new data), use it
        if context.row.get('fs_type'):
            context.fs_type = context.row['fs_type']
            return context

        # Legacy data - detect type from filesystem
        # Note: Check symlinks BEFORE exists() because broken symlinks
        # return False for exists() but we still want to process them
        if context.source_path.is_symlink():
            context.fs_type = 'l'
        elif not context.source_path.exists():
            # Now we know it's not a symlink and truly doesn't exist
            context.should_process = False
            context.skip_reason = "Source not found"
            worker.stats['errors'] += 1
            worker.logger.error("Source file not found",
                              path=str(context.source_path),
                              ino=context.row['ino'])
            return context
        # Detect filesystem type for existing non-symlinks
        elif context.source_path.is_dir():
            context.fs_type = 'd'
        elif context.source_path.is_file():
            context.fs_type = 'f'
        elif context.source_path.is_socket():
            context.fs_type = 's'
        elif context.source_path.is_fifo():
            context.fs_type = 'p'
        elif context.source_path.is_block_device():
            context.fs_type = 'b'
        elif context.source_path.is_char_device():
            context.fs_type = 'c'
        else:
            context.fs_type = 'u'  # unknown

        # Update database with detected type (don't commit yet)
        if not worker.dry_run:
            with worker.conn.cursor() as cur:
                cur.execute("""
                    UPDATE inode SET fs_type = %s
                    WHERE medium_hash = %s AND dev = %s AND ino = %s
                """, (context.fs_type,
                      context.row['medium_hash'],
                      context.row['dev'],
                      context.row['ino']))

        worker.logger.debug(f"Detected fs_type={context.fs_type} for legacy inode",
                          ino=context.row['ino'])
        return context


class DirectoryHandler(InodeProcessor):
    """Handles directories - marks them and skips."""

    def handle(self, context: InodeContext, worker) -> InodeContext:
        if context.fs_type != 'd':
            return context

        context.should_process = False
        context.skip_reason = "Directory"
        context.mime_type = 'inode/directory'

        # Mark directory as processed
        if not worker.dry_run:
            with worker.conn.cursor() as cur:
                cur.execute("""
                    UPDATE inode
                    SET mime_type = 'inode/directory',
                        copied = true,
                        processed_at = NOW()
                    WHERE medium_hash = %s AND dev = %s AND ino = %s
                """, (context.row['medium_hash'],
                      context.row['dev'],
                      context.row['ino']))
            worker.conn.commit()
        else:
            worker.logger.info("[DRY-RUN] Would mark directory as processed",
                             path=str(context.source_path))
        worker.stats['skipped'] += 1
        worker.processed_count += 1  # Count all processed items for limit
        return context


class SymlinkHandler(InodeProcessor):
    """Handles symlinks - marks them and skips."""

    def handle(self, context: InodeContext, worker) -> InodeContext:
        if context.fs_type != 'l':
            return context

        context.should_process = False
        context.skip_reason = "Symlink"
        context.mime_type = 'inode/symlink'

        # Mark symlink as processed
        if not worker.dry_run:
            with worker.conn.cursor() as cur:
                cur.execute("""
                    UPDATE inode
                    SET mime_type = 'inode/symlink',
                        copied = true,
                        processed_at = NOW()
                    WHERE medium_hash = %s AND dev = %s AND ino = %s
                """, (context.row['medium_hash'],
                      context.row['dev'],
                      context.row['ino']))
            worker.conn.commit()
        else:
            worker.logger.info("[DRY-RUN] Would mark symlink as processed",
                             path=str(context.source_path))
        worker.stats['skipped'] += 1
        worker.processed_count += 1  # Count all processed items for limit
        return context


class NonFileHandler(InodeProcessor):
    """Handles other non-file types (sockets, pipes, devices)."""

    def handle(self, context: InodeContext, worker) -> InodeContext:
        # Skip any non-regular files not already handled
        if context.fs_type not in ('f', None):
            context.should_process = False

            # Map fs_type to mime type
            mime_map = {
                's': 'inode/socket',
                'p': 'inode/fifo',
                'b': 'inode/blockdevice',
                'c': 'inode/chardevice',
                'u': 'inode/unknown'
            }

            context.mime_type = mime_map.get(context.fs_type, 'inode/unknown')
            context.skip_reason = f"Non-file type: {context.fs_type}"

            # Mark as processed
            if not worker.dry_run:
                with worker.conn.cursor() as cur:
                    cur.execute("""
                        UPDATE inode
                        SET mime_type = %s,
                            copied = true,
                            processed_at = NOW()
                        WHERE medium_hash = %s AND dev = %s AND ino = %s
                    """, (context.mime_type,
                          context.row['medium_hash'],
                          context.row['dev'],
                          context.row['ino']))
                worker.conn.commit()
            else:
                worker.logger.info(f"[DRY-RUN] Would mark {context.fs_type} as processed",
                                 path=str(context.source_path))
            worker.stats['skipped'] += 1
            worker.processed_count += 1  # Count all processed items for limit

        return context


class MimeTypeDetector(InodeProcessor):
    """Detects MIME type for regular files."""

    def handle(self, context: InodeContext, worker) -> InodeContext:
        # Only process regular files
        if context.fs_type != 'f':
            return context

        # Use existing MIME type if available
        if context.row.get('mime_type'):
            context.mime_type = context.row['mime_type']
            return context

        # Detect MIME type
        context.mime_type = self._detect_mime(
            context.source_path,
            context.row['size'],
            worker
        )

        # Update database (don't commit yet - will commit after processing)
        if not worker.dry_run:
            with worker.conn.cursor() as cur:
                cur.execute("""
                    UPDATE inode SET mime_type = %s
                    WHERE medium_hash = %s AND dev = %s AND ino = %s
                """, (context.mime_type,
                      context.row['medium_hash'],
                      context.row['dev'],
                      context.row['ino']))

        worker.logger.debug(f"Detected MIME type: {context.mime_type}",
                          ino=context.row['ino'])
        return context

    def _detect_mime(self, path: Path, size: int, worker) -> str:
        """Detect MIME type using python-magic."""
        if size == 0:
            return 'application/x-empty'

        try:
            import magic

            # For small files, read into memory for detection
            if size < 8192:
                with open(path, 'rb') as f:
                    content = f.read()
                return magic.from_buffer(content, mime=True)
            else:
                # For larger files, let libmagic read the file efficiently
                return magic.from_file(str(path), mime=True)

        except ImportError:
            worker.logger.warning("python-magic not available, using default MIME type")
            return 'application/octet-stream'
        except Exception as e:
            worker.logger.warning(f"MIME detection failed: {e}", path=str(path))
            return 'application/octet-stream'


class FileProcessor(InodeProcessor):
    """Actually processes files (hash, copy, dedupe)."""

    def handle(self, context: InodeContext, worker) -> InodeContext:
        # Only process regular files that haven't been skipped
        if context.fs_type != 'f' or not context.should_process:
            return context

        # Check if already processed
        if context.row.get('hash') is not None and context.row.get('copied'):
            worker.logger.info("Skipping already copied file", ino=context.row['ino'])
            worker.stats['skipped'] += 1
            context.should_process = False
            context.skip_reason = "Already processed"
            return context

        size = context.row['size']

        # Handle empty files
        if size == 0:
            context.hash_value = worker.EMPTY_FILE_HASH
            self._update_empty_file(context, worker)
            return context

        # Get temp path for copying
        context.temp_path = worker.get_temp_path(context.row)

        # For dry-run mode, just calculate hash without copying
        if worker.dry_run:
            try:
                context.hash_value = self._hash_file(context.source_path, worker)
                worker.logger.info("[DRY-RUN] Would copy to temp",
                               source=str(context.source_path),
                               temp=str(context.temp_path),
                               size=size)
                # Increment dry-run counter
                worker.processed_count += 1
            except Exception as e:
                worker.logger.error(f"[DRY-RUN] Failed to hash: {e}",
                                  path=str(context.source_path))
                worker.stats['errors'] += 1
                worker.processed_count += 1  # Count errors too
                context.should_process = False
                context.skip_reason = f"Hash failed: {e}"
                return context
        else:
            # Check for existing temp file
            existing_hash = worker.handle_existing_temp(
                context.temp_path,
                context.source_path,
                size
            )

            if existing_hash:
                context.hash_value = existing_hash
            else:
                # Copy and hash the file
                try:
                    context.hash_value = self._hash_and_copy(
                        context.source_path,
                        context.temp_path,
                        worker
                    )
                except Exception as e:
                    worker.logger.error(f"Failed to copy: {e}",
                                      path=str(context.source_path))
                    worker.stats['errors'] += 1
                    if context.temp_path.exists():
                        context.temp_path.unlink()
                    context.should_process = False
                    context.skip_reason = f"Copy failed: {e}"
                    return context

            # Move to final destination and create hardlinks
            self._finalize_copy(context, worker)

        # Update stats
        worker.stats['copied'] += 1
        worker.stats['bytes'] += size
        worker.processed_count += 1  # Track for limit checking

        return context

    def _hash_file(self, path: Path, worker) -> str:
        """Calculate BLAKE3 hash of existing file."""
        hasher = blake3.blake3()

        with open(path, 'rb') as f:
            while chunk := f.read(worker.CHUNK_SIZE):
                hasher.update(chunk)

        return hasher.hexdigest()

    def _hash_and_copy(self, source: Path, dest: Path, worker) -> str:
        """Stream copy to dest while calculating BLAKE3 hash."""
        hasher = blake3.blake3()

        with open(source, 'rb') as src, open(dest, 'wb') as dst:
            while chunk := src.read(worker.CHUNK_SIZE):
                hasher.update(chunk)
                dst.write(chunk)

        return hasher.hexdigest()

    def _update_empty_file(self, context: InodeContext, worker):
        """Handle empty file update."""
        if not worker.dry_run:
            # Create empty file at hash location if needed
            hash_path = worker.BY_HASH_ROOT / context.hash_value[:2] / context.hash_value[2:4] / context.hash_value
            if not hash_path.exists():
                # Create parent directories and ALWAYS set ownership/permissions
                hash_path.parent.mkdir(parents=True, exist_ok=True)
                # Set ownership and permissions on the newly created directory chain
                if os.geteuid() == 0:  # Only if running as root
                    dir_to_chown = hash_path.parent
                    while dir_to_chown != worker.BY_HASH_ROOT and dir_to_chown.exists():
                        os.chown(dir_to_chown, 1000, 1000)
                        os.chmod(dir_to_chown, 0o755)  # drwxr-xr-x
                        dir_to_chown = dir_to_chown.parent
                        if dir_to_chown.exists() and dir_to_chown.stat().st_uid == 1000:
                            break  # Stop if we hit a dir already owned by pball
                hash_path.touch()
                # Set ownership to pball:pball (UID 1000, GID 1000)
                os.chown(hash_path, 1000, 1000)

            # Create archive hardlink
            archive_path = worker.ARCHIVE_ROOT / context.source_path.relative_to('/')
            if not archive_path.exists():
                # Create parent directories and ALWAYS set ownership/permissions
                archive_path.parent.mkdir(parents=True, exist_ok=True)
                # Set ownership and permissions on the newly created directory chain
                if os.geteuid() == 0:  # Only if running as root
                    dir_to_chown = archive_path.parent
                    while dir_to_chown != worker.ARCHIVE_ROOT and dir_to_chown.exists():
                        os.chown(dir_to_chown, 1000, 1000)
                        os.chmod(dir_to_chown, 0o755)  # drwxr-xr-x
                        dir_to_chown = dir_to_chown.parent
                        if dir_to_chown.exists() and dir_to_chown.stat().st_uid == 1000:
                            break  # Stop if we hit a dir already owned by pball
                os.link(hash_path, archive_path)
                # Hardlinks share ownership, but set it anyway for clarity
                os.chown(archive_path, 1000, 1000)

            # Update database
            with worker.conn.cursor() as cur:
                cur.execute("""
                    UPDATE inode
                    SET hash = %s,
                        copied = true,
                        copied_to = %s,
                        mime_type = COALESCE(mime_type, 'application/x-empty'),
                        processed_at = NOW()
                    WHERE medium_hash = %s AND dev = %s AND ino = %s
                """, (context.hash_value,
                      str(worker.BY_HASH_ROOT / context.hash_value[:2] / context.hash_value[2:4] / context.hash_value),
                      context.row['medium_hash'],
                      context.row['dev'],
                      context.row['ino']))
                
                # Insert into blobs table (ignore if already exists)
                cur.execute("""
                    INSERT INTO blobs (blobid, last_checked)
                    VALUES (%s, NULL)
                    ON CONFLICT (blobid) DO NOTHING
                """, (context.hash_value,))
            worker.conn.commit()
        else:
            worker.logger.info("[DRY-RUN] Would update database for empty file",
                             hash=context.hash_value,
                             ino=context.row['ino'])

    def _finalize_copy(self, context: InodeContext, worker):
        """Move temp file to hash location and create archive hardlink."""
        if worker.dry_run:
            worker.logger.info("[DRY-RUN] Would move temp to hash and hardlink",
                             hash=context.hash_value[:8])
            worker.logger.info("[DRY-RUN] Would update database",
                             ino=context.row['ino'])
            return

        # Set up paths
        hash_path = worker.BY_HASH_ROOT / context.hash_value[:2] / context.hash_value[2:4] / context.hash_value
        archive_path = worker.ARCHIVE_ROOT / context.source_path.relative_to('/')

        # Move temp to hash location if not exists
        if not hash_path.exists():
            # Create parent directories and set ownership
            if not hash_path.parent.exists():
                hash_path.parent.mkdir(parents=True, exist_ok=True)
                # Set ownership and permissions on the newly created directory chain
                dir_to_chown = hash_path.parent
                while dir_to_chown != worker.BY_HASH_ROOT and dir_to_chown.exists():
                    os.chown(dir_to_chown, 1000, 1000)
                    os.chmod(dir_to_chown, 0o755)  # drwxr-xr-x
                    dir_to_chown = dir_to_chown.parent
                    if dir_to_chown.exists() and dir_to_chown.stat().st_uid == 1000:
                        break  # Stop if we hit a dir already owned by pball
            shutil.move(str(context.temp_path), str(hash_path))
            # Set ownership to pball:pball (UID 1000, GID 1000)
            os.chown(hash_path, 1000, 1000)
        else:
            # Hash already exists - this is deduplication
            context.temp_path.unlink()
            worker.stats['deduped'] += 1

        # Create archive hardlink
        if not archive_path.exists():
            # Create parent directories and set ownership
            if not archive_path.parent.exists():
                archive_path.parent.mkdir(parents=True, exist_ok=True)
                # Set ownership and permissions on the newly created directory chain
                dir_to_chown = archive_path.parent
                while dir_to_chown != worker.ARCHIVE_ROOT and dir_to_chown.exists():
                    os.chown(dir_to_chown, 1000, 1000)
                    os.chmod(dir_to_chown, 0o755)  # drwxr-xr-x
                    dir_to_chown = dir_to_chown.parent
                    if dir_to_chown.exists() and dir_to_chown.stat().st_uid == 1000:
                        break  # Stop if we hit a dir already owned by pball
            os.link(hash_path, archive_path)
            # Hardlinks share ownership, but set it anyway for clarity
            os.chown(archive_path, 1000, 1000)

        # Update database
        with worker.conn.cursor() as cur:
            cur.execute("""
                UPDATE inode
                SET hash = %s,
                    copied = true,
                    copied_to = %s,
                    mime_type = COALESCE(mime_type, %s),
                    processed_at = NOW()
                WHERE medium_hash = %s AND dev = %s AND ino = %s
            """, (context.hash_value,
                  str(hash_path),
                  context.mime_type or 'application/octet-stream',
                  context.row['medium_hash'],
                  context.row['dev'],
                  context.row['ino']))
            
            # Insert into blobs table (ignore if already exists)
            cur.execute("""
                INSERT INTO blobs (blobid, last_checked)
                VALUES (%s, NULL)
                ON CONFLICT (blobid) DO NOTHING
            """, (context.hash_value,))
        worker.conn.commit()