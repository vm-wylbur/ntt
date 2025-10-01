#!/usr/bin/env -S /home/pball/.local/bin/uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "psycopg[binary]",
#     "blake3-py",
#     "pyyaml",
#     "structlog",
#     "python-magic",
# ]
# ///
"""
================================================================================
DEPRECATED - DO NOT USE
================================================================================

This file implements a Chain of Responsibility pattern that has critical bugs
and architectural flaws. It is being replaced by a new Claim-Analyze-Execute
architecture.

CRITICAL BUGS IN THIS CODE:
1. _get_all_paths_for_hash() queries by hash instead of by inode, causing:
   - Processing 100 inodes creates hardlinks for 12k+ paths (violates --limit)
   - Only current inode gets by_hash_created=true flag
   - expected_hardlinks never populated
   - Inconsistent database state

2. Scattered database commits throughout processor chain release locks early,
   creating race conditions

3. No transactional integrity - partial updates possible

This file is kept for reference only while migrating logic to the new
architecture. See design docs for the Claim-Analyze-Execute pattern.

DO NOT MODIFY THIS FILE - Extract needed logic and move to new strategy module.
================================================================================

Modified processor chain for ntt-copier with enhanced tracking.

Key changes:
1. Track by_hash_created in inode table
2. Batch update n_hardlinks in blobs table  
3. Support --re-hardlink mode
"""

import os
import shutil
from pathlib import Path
from typing import Optional, List, Dict
from dataclasses import dataclass, field
import blake3
import magic

@dataclass
class InodeContext:
    """Context passed through the processor chain."""
    row: dict
    source_path: Path
    fs_type: Optional[str] = None
    mime_type: Optional[str] = None
    temp_path: Optional[Path] = None
    hash_value: Optional[str] = None
    should_process: bool = True
    skip_reason: Optional[str] = None
    
    # New: Track hardlinks created in this operation
    hardlinks_created: List[str] = field(default_factory=list)


class Processor:
    """Base processor class."""
    
    def __init__(self, next_processor=None):
        self.next = next_processor
    
    def process(self, context: InodeContext, worker):
        """Process and pass to next."""
        context = self.handle(context, worker)
        if self.next and context.should_process:
            return self.next.process(context, worker)
        return context
    
    def handle(self, context: InodeContext, worker):
        """Override in subclasses."""
        return context


class FilesystemTypeDetector(Processor):
    """Detect filesystem object type if not already known."""
    
    def handle(self, context: InodeContext, worker):
        """Detect filesystem type for legacy inodes."""
        if context.fs_type:
            # Already has fs_type, skip
            return context
        
        # Detect fs_type for legacy inodes
        worker.logger.debug(f"Detecting fs_type for legacy inode",
                          path=str(context.source_path))
        
        # Note: Check symlinks BEFORE exists() because broken symlinks
        # return False for exists() but we still want to process them
        if context.source_path.is_symlink():
            context.fs_type = 'l'
        elif not context.source_path.exists():
            # Now we know it's not a symlink and truly doesn't exist
            context.should_process = False
            context.skip_reason = "Source not found"
            return context
        elif context.source_path.is_dir():
            context.fs_type = 'd'
        elif context.source_path.is_file():
            context.fs_type = 'f'
        elif context.source_path.is_block_device():
            context.fs_type = 'b'
        elif context.source_path.is_char_device():
            context.fs_type = 'c'
        elif context.source_path.is_fifo():
            context.fs_type = 'p'
        elif context.source_path.is_socket():
            context.fs_type = 's'
        else:
            worker.logger.warning(f"Unknown fs_type for {context.source_path}",
                                ino=context.row['ino'])
            context.should_process = False
            context.skip_reason = "Unknown filesystem type"
            return context
        
        # Update database with detected fs_type
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


class DirectoryProcessor(Processor):
    """Handle directories."""
    
    def handle(self, context: InodeContext, worker):
        """Process directories."""
        if context.fs_type != 'd':
            return context
        
        # Create directory in archive
        archive_path = worker.ARCHIVE_ROOT / context.source_path.relative_to('/')
        if not worker.dry_run:
            archive_path.mkdir(parents=True, exist_ok=True)
            
            with worker.conn.cursor() as cur:
                cur.execute("""
                    UPDATE inode
                    SET mime_type = 'inode/directory',
                        copied = true,
                        by_hash_created = true,
                        processed_at = NOW()
                    WHERE medium_hash = %s AND dev = %s AND ino = %s
                """, (context.row['medium_hash'],
                      context.row['dev'],
                      context.row['ino']))
            worker.conn.commit()
        
        worker.logger.debug(f"Created directory", path=str(archive_path))
        context.should_process = False
        context.skip_reason = "Directory processed"
        return context


class SymlinkProcessor(Processor):
    """Handle symbolic links."""
    
    def handle(self, context: InodeContext, worker):
        """Process symlinks."""
        if context.fs_type != 'l':
            return context
        
        # Read symlink target
        try:
            target = os.readlink(context.source_path)
        except Exception as e:
            worker.logger.error(f"Failed to read symlink: {e}",
                              path=str(context.source_path))
            context.should_process = False
            context.skip_reason = f"Cannot read symlink: {e}"
            return context
        
        # Create symlink in archive
        archive_path = worker.ARCHIVE_ROOT / context.source_path.relative_to('/')
        if not worker.dry_run:
            archive_path.parent.mkdir(parents=True, exist_ok=True)
            if archive_path.exists() or archive_path.is_symlink():
                archive_path.unlink()
            archive_path.symlink_to(target)
            
            with worker.conn.cursor() as cur:
                cur.execute("""
                    UPDATE inode
                    SET mime_type = 'inode/symlink',
                        copied = true,
                        by_hash_created = true,
                        processed_at = NOW()
                    WHERE medium_hash = %s AND dev = %s AND ino = %s
                """, (context.row['medium_hash'],
                      context.row['dev'],
                      context.row['ino']))
            worker.conn.commit()
        
        worker.logger.debug(f"Created symlink to {target}",
                          path=str(archive_path))
        context.should_process = False
        context.skip_reason = "Symlink processed"
        return context


class SpecialFileProcessor(Processor):
    """Handle special files."""
    
    def handle(self, context: InodeContext, worker):
        """Skip special files."""
        if context.fs_type not in ['b', 'c', 'p', 's']:
            return context
        
        type_names = {
            'b': 'block device',
            'c': 'character device',
            'p': 'named pipe',
            's': 'socket'
        }
        
        type_name = type_names.get(context.fs_type, 'special file')
        
        if context.fs_type in ['b', 'c']:
            mime_type = f'inode/{type_name.replace(" ", "-")}'
            
            if not worker.dry_run:
                with worker.conn.cursor() as cur:
                    cur.execute("""
                        UPDATE inode
                        SET mime_type = %s,
                            copied = true,
                            by_hash_created = true,
                            processed_at = NOW()
                        WHERE medium_hash = %s AND dev = %s AND ino = %s
                    """, (mime_type,
                          context.row['medium_hash'],
                          context.row['dev'],
                          context.row['ino']))
                worker.conn.commit()
        
        worker.logger.debug(f"Skipping {type_name}",
                          path=str(context.source_path))
        context.should_process = False
        context.skip_reason = f"{type_name} - skipped"
        return context


class MimeTypeDetector(Processor):
    """Detect MIME type if not already known."""
    
    def __init__(self, next_processor=None):
        super().__init__(next_processor)
        self.mime = magic.Magic(mime=True)
    
    def handle(self, context: InodeContext, worker):
        """Detect MIME type."""
        if context.mime_type:
            # Already has MIME type
            return context
        
        if context.fs_type != 'f':
            # Only detect for regular files
            return context
        
        try:
            # Use python-magic to detect MIME type
            context.mime_type = self.mime.from_file(str(context.source_path))
        except Exception as e:
            worker.logger.warning(f"Failed to detect MIME type: {e}",
                                path=str(context.source_path))
            # Continue without MIME type
            context.mime_type = None
        
        # Update database if detected
        if context.mime_type and not worker.dry_run:
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


class FileProcessor(Processor):
    """Process regular files with enhanced tracking."""
    
    def handle(self, context: InodeContext, worker):
        """Process regular files."""
        if context.fs_type != 'f':
            return context
        
        size = context.row['size']
        
        # Check for empty file
        if size == 0:
            context.hash_value = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            self._update_empty_file(context, worker)
            context.should_process = False
            context.skip_reason = "Empty file processed"
            return context
        
        # Check if re-hardlink mode
        if getattr(worker, 're_hardlink_mode', False):
            # In re-hardlink mode, check if by-hash already exists
            if context.row.get('hash'):
                hash_value = context.row['hash']
                if isinstance(hash_value, bytes):
                    hash_value = hash_value.hex()
                context.hash_value = hash_value
                
                by_hash_path = worker.BY_HASH_ROOT / hash_value[:2] / hash_value[2:4] / hash_value
                if by_hash_path.exists():
                    # By-hash exists, just create hardlinks
                    self._create_hardlinks_only(context, worker)
                    context.should_process = False
                    context.skip_reason = "Re-hardlinked"
                    return context
        
        # Normal processing: copy to temp and hash
        context.temp_path = worker.get_temp_path(context.row)
        
        # Copy file to temp location
        try:
            context.temp_path.parent.mkdir(parents=True, exist_ok=True)
            
            if size < 100 * 1024 * 1024:  # 100MB
                shutil.copy2(context.source_path, context.temp_path)
            else:
                # For large files, use streaming copy with progress
                copied = 0
                with open(context.source_path, 'rb') as src:
                    with open(context.temp_path, 'wb') as dst:
                        while chunk := src.read(64 * 1024 * 1024):  # 64MB chunks
                            dst.write(chunk)
                            copied += len(chunk)
                            if copied % (500 * 1024 * 1024) == 0:  # Log every 500MB
                                worker.logger.info(f"Progress: {copied / (1024**3):.1f}GB / {size / (1024**3):.1f}GB")
                
                # Preserve metadata
                shutil.copystat(context.source_path, context.temp_path)
            
            # Hash the temp file
            hasher = blake3.blake3()
            with open(context.temp_path, 'rb') as f:
                while chunk := f.read(64 * 1024 * 1024):  # 64MB chunks
                    hasher.update(chunk)
            context.hash_value = hasher.hexdigest()
            
        except Exception as e:
            worker.logger.error(f"Failed to process file: {e}",
                              path=str(context.source_path))
            worker.stats['errors'] += 1
            if context.temp_path and context.temp_path.exists():
                context.temp_path.unlink()
            context.should_process = False
            context.skip_reason = f"Copy failed: {e}"
            return context
        
        # Move to final destination and create hardlinks
        self._finalize_copy(context, worker)
        
        # Update stats
        worker.stats['copied'] += 1
        worker.stats['bytes'] += size
        
        context.should_process = False
        context.skip_reason = "File processed"
        return context
    
    def _update_empty_file(self, context: InodeContext, worker):
        """Handle empty file update with new tracking."""
        if not worker.dry_run:
            # Create empty file at hash location if needed
            hash_path = worker.BY_HASH_ROOT / context.hash_value[:2] / context.hash_value[2:4] / context.hash_value
            by_hash_created = False
            
            if not hash_path.exists():
                hash_path.parent.mkdir(parents=True, exist_ok=True)
                hash_path.touch()
                by_hash_created = True
            
            # Get all paths for this inode's hash
            paths = self._get_all_paths_for_hash(context, worker)
            
            # Create hardlinks
            hardlinks_created = []
            for path in paths:
                archive_path = worker.ARCHIVE_ROOT / path.lstrip('/')
                if not archive_path.exists():
                    archive_path.parent.mkdir(parents=True, exist_ok=True)
                    os.link(hash_path, archive_path)
                    hardlinks_created.append(path)
            
            # Update database
            with worker.conn.cursor() as cur:
                # Update inode
                cur.execute("""
                    UPDATE inode
                    SET hash = %s,
                        copied = true,
                        by_hash_created = %s,
                        copied_to = %s,
                        mime_type = COALESCE(mime_type, 'application/x-empty'),
                        processed_at = NOW()
                    WHERE medium_hash = %s AND dev = %s AND ino = %s
                """, (context.hash_value,
                      by_hash_created or context.row.get('by_hash_created', False),
                      str(hash_path),
                      context.row['medium_hash'],
                      context.row['dev'],
                      context.row['ino']))
                
                # Insert into blobs if new
                if by_hash_created:
                    cur.execute("""
                        INSERT INTO blobs (blobid, last_checked, n_hardlinks)
                        VALUES (%s, NULL, %s)
                        ON CONFLICT (blobid) DO UPDATE
                        SET n_hardlinks = blobs.n_hardlinks + %s
                    """, (context.hash_value, len(hardlinks_created), len(hardlinks_created)))
                elif hardlinks_created:
                    # Update hardlink count
                    cur.execute("""
                        UPDATE blobs
                        SET n_hardlinks = n_hardlinks + %s
                        WHERE blobid = %s
                    """, (len(hardlinks_created), context.hash_value))
                    
            worker.conn.commit()
    
    def _finalize_copy(self, context: InodeContext, worker):
        """Move temp file to hash location and create hardlinks with tracking."""
        if worker.dry_run:
            worker.logger.info("[DRY-RUN] Would move temp to hash and hardlink",
                             hash=context.hash_value[:8])
            return
        
        # Set up paths
        hash_path = worker.BY_HASH_ROOT / context.hash_value[:2] / context.hash_value[2:4] / context.hash_value
        
        # Track if we created the by-hash file
        by_hash_created = False
        
        # Move temp to hash location if not exists
        if not hash_path.exists():
            hash_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(context.temp_path), str(hash_path))
            by_hash_created = True
        else:
            # Hash already exists - this is deduplication
            context.temp_path.unlink()
            worker.stats['deduped'] += 1
        
        # Get all paths that need this hash
        paths = self._get_all_paths_for_hash(context, worker)
        
        # Create hardlinks for all paths
        hardlinks_created = []
        for path in paths:
            archive_path = worker.ARCHIVE_ROOT / path.lstrip('/')
            if not archive_path.exists():
                archive_path.parent.mkdir(parents=True, exist_ok=True)
                os.link(hash_path, archive_path)
                hardlinks_created.append(path)
        
        # Update database with batch tracking
        with worker.conn.cursor() as cur:
            # Update inode
            cur.execute("""
                UPDATE inode
                SET hash = %s,
                    copied = true,
                    by_hash_created = %s,
                    copied_to = %s,
                    mime_type = COALESCE(mime_type, %s),
                    processed_at = NOW()
                WHERE medium_hash = %s AND dev = %s AND ino = %s
            """, (context.hash_value,
                  by_hash_created or context.row.get('by_hash_created', False),
                  str(hash_path),
                  context.mime_type or 'application/octet-stream',
                  context.row['medium_hash'],
                  context.row['dev'],
                  context.row['ino']))
            
            # Handle blob tracking
            if by_hash_created:
                # New blob - insert with initial count
                cur.execute("""
                    INSERT INTO blobs (blobid, last_checked, n_hardlinks)
                    VALUES (%s, NULL, %s)
                    ON CONFLICT (blobid) DO UPDATE
                    SET n_hardlinks = blobs.n_hardlinks + %s
                """, (context.hash_value, len(hardlinks_created), len(hardlinks_created)))
            elif hardlinks_created:
                # Existing blob - increment count
                cur.execute("""
                    UPDATE blobs
                    SET n_hardlinks = n_hardlinks + %s
                    WHERE blobid = %s
                """, (len(hardlinks_created), context.hash_value))
                
        worker.conn.commit()
        context.hardlinks_created = hardlinks_created
    
    def _create_hardlinks_only(self, context: InodeContext, worker):
        """Create missing hardlinks for existing by-hash file."""
        if worker.dry_run:
            worker.logger.info("[DRY-RUN] Would create hardlinks",
                             hash=context.hash_value[:8])
            return
        
        hash_path = worker.BY_HASH_ROOT / context.hash_value[:2] / context.hash_value[2:4] / context.hash_value
        
        # Get all paths for this hash
        paths = self._get_all_paths_for_hash(context, worker)
        
        # Create missing hardlinks
        hardlinks_created = []
        for path in paths:
            archive_path = worker.ARCHIVE_ROOT / path.lstrip('/')
            if not archive_path.exists():
                archive_path.parent.mkdir(parents=True, exist_ok=True)
                os.link(hash_path, archive_path)
                hardlinks_created.append(path)
                worker.logger.debug(f"Created hardlink: {path}")
        
        # Update hardlink count if any were created
        if hardlinks_created:
            with worker.conn.cursor() as cur:
                cur.execute("""
                    UPDATE blobs
                    SET n_hardlinks = n_hardlinks + %s
                    WHERE blobid = %s
                """, (len(hardlinks_created), context.hash_value))
            worker.conn.commit()
        
        worker.logger.info(f"Created {len(hardlinks_created)} hardlinks",
                         hash=context.hash_value[:8])
    
    def _get_all_paths_for_hash(self, context: InodeContext, worker) -> List[str]:
        """Get all paths associated with this hash."""
        with worker.conn.cursor() as cur:
            cur.execute("""
                SELECT DISTINCT p.path
                FROM path p
                JOIN inode i ON p.dev = i.dev AND p.ino = i.ino
                WHERE i.hash = %s
                ORDER BY p.path
            """, (context.hash_value,))
            return [row['path'] for row in cur.fetchall()]