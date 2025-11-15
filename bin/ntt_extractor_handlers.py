#!/usr/bin/env python3
# Author: PB and Claude
# Date: 2025-11-05
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt_extractor_handlers.py
#
# Extraction handlers for archives and compression formats

import os
import subprocess
import tempfile
from pathlib import Path
from typing import List, Tuple, Optional
import sys

from loguru import logger
import psycopg

from ntt_extractor_medium import ExtractionMediumManager

# Import common pipeline functions
from ntt_pipeline_common import (
    hash_file_and_detect_mime,
    get_byhash_path,
    copy_to_byhash,
    EXTRACTION_TEMP_DIR
)


# =============================================================================
# HANDLER REGISTRY - Single source of truth for supported formats
# =============================================================================

MIME_HANDLERS = {
    # Compression formats (single file -> single file)
    'application/gzip': 'decompress_gzip',
    'application/x-bzip2': 'decompress_bzip2',
    'application/x-xz': 'decompress_xz',
    'application/x-compress': 'decompress_compress',
    'application/x-lzip': 'decompress_lzip',

    # Archive formats (single file -> many files)
    'application/x-tar': 'extract_tar',
    'application/zip': 'extract_zip',
    'application/x-archive': 'extract_ar',
    'application/vnd.rar': 'extract_rar',
    'application/vnd.ms-cab-compressed': 'extract_cab',
    'application/x-7z-compressed': 'extract_7z',

    # Compound formats (compression + archive)
    'application/x-gzip': 'extract_tar_gz',  # .tar.gz
    'application/x-bzip': 'extract_tar_bz2',  # .tar.bz2
    'application/x-lzma': 'extract_tar_xz',  # .tar.xz
}


def get_supported_mime_types() -> List[str]:
    """Get list of all supported MIME types."""
    return list(MIME_HANDLERS.keys())


# =============================================================================
# COMMON INFRASTRUCTURE
# =============================================================================
#
# NOTE: Common functions now imported from lib/ntt_pipeline_common.py:
# - hash_file_and_detect_mime() - Combined hash + MIME in single pass
# - get_byhash_path() - By-hash path calculation
# - copy_to_byhash() - Copy with hardlink optimization
# - EXTRACTION_TEMP_DIR - Temp directory on same filesystem as by-hash

# Files to skip during extraction (archive metadata, unreadable files, etc.)
SKIP_FILES = {
    '__.SYMDEF',      # ar archive symbol table (ranlib metadata)
    '__.SYMDEF SORTED',  # sorted variant
}


def walk_and_hash_directory(
    extract_dir: Path,
    medium_manager: ExtractionMediumManager,
    medium_hash: str
) -> Tuple[int, List[Tuple[str, str]]]:
    """
    Walk extracted directory, hash files, copy to by-hash.

    Returns:
        (file_count, nested_archives) where nested_archives is [(blobid, mime_type), ...]
    """
    inodes_batch = []
    paths_batch = []
    nested_archives = []
    file_count = 0

    for root, dirs, files in os.walk(extract_dir):
        for filename in files:
            # Skip archive metadata files
            if filename in SKIP_FILES:
                logger.debug(f"Skipping metadata file: {filename}")
                continue

            file_path = Path(root) / filename

            # Skip if not a regular file
            if not file_path.is_file():
                continue

            # Get relative path from extract_dir
            rel_path = file_path.relative_to(extract_dir)
            path_str = f"/{rel_path}"  # Leading slash for absolute-like paths

            # Hash file and detect MIME in single pass
            blobid, mime_type = hash_file_and_detect_mime(file_path)

            # Copy to by-hash
            copy_to_byhash(file_path, blobid)

            # Get file stats
            stat_info = file_path.stat()
            size = stat_info.st_size
            mtime = int(stat_info.st_mtime)

            # Generate synthetic inode (dev=0 for extracted archives)
            dev = 0
            ino = medium_manager.generate_synthetic_inode(medium_hash, path_str)

            # Add to batches
            inodes_batch.append((dev, ino, blobid, mime_type, size, mtime))
            paths_batch.append((dev, ino, blobid, path_str))

            file_count += 1

            # Check if this is a nested archive
            if mime_type in MIME_HANDLERS:
                logger.debug(f"Detected nested archive: {path_str} ({mime_type})")
                nested_archives.append((blobid, mime_type))

            # Bulk insert every 1000 rows
            if len(inodes_batch) >= 1000:
                medium_manager.bulk_insert_inodes(medium_hash, inodes_batch)
                medium_manager.bulk_insert_paths(medium_hash, paths_batch)
                inodes_batch.clear()
                paths_batch.clear()

    # Insert remaining rows
    if inodes_batch:
        medium_manager.bulk_insert_inodes(medium_hash, inodes_batch)
        medium_manager.bulk_insert_paths(medium_hash, paths_batch)

    return file_count, nested_archives


# =============================================================================
# EXTRACTION HANDLER BASE CLASS
# =============================================================================

class ExtractionResult:
    """Result of an extraction operation."""

    def __init__(self, medium_hash: str, files_extracted: int, nested_archives: List[Tuple[str, str]]):
        self.medium_hash = medium_hash
        self.files_extracted = files_extracted
        self.nested_archives = nested_archives  # List of (blobid, mime_type)


class ExtractionHandler:
    """Base class for extraction handlers."""

    def __init__(self, db: psycopg.Connection):
        self.db = db
        self.medium_manager = ExtractionMediumManager(db)

    def extract(self, blobid: str, mime_type: str) -> ExtractionResult:
        """
        Extract archive/compressed file.

        To be implemented by subclasses.
        """
        raise NotImplementedError()


# =============================================================================
# DECOMPRESSION HANDLERS (single file -> single file)
# =============================================================================

def _decompress_generic(
    db: psycopg.Connection,
    blobid: str,
    command: List[str],
    method_name: str
) -> ExtractionResult:
    """Generic decompression handler."""
    logger.debug(f"Starting {method_name} decompression for {blobid[:8]}...")
    medium_manager = ExtractionMediumManager(db)

    # Get source file from by-hash
    source_path = get_byhash_path(blobid)
    logger.debug(f"Source path: {source_path}, exists: {source_path.exists()}")

    # Use EXTRACTION_TEMP_DIR for hardlink optimization
    with tempfile.TemporaryDirectory(dir=EXTRACTION_TEMP_DIR) as tmpdir:
        tmpdir_path = Path(tmpdir)
        output_file = tmpdir_path / "decompressed"
        logger.debug(f"Temp directory: {tmpdir}, output: {output_file}")

        # Decompress
        logger.debug(f"Running command: {' '.join(command + [str(source_path)])}")
        with open(output_file, 'wb') as out:
            result = subprocess.run(
                command + [str(source_path)],
                stdout=out,
                stderr=subprocess.PIPE,
                check=True
            )
        logger.debug(f"Decompression complete, output size: {output_file.stat().st_size}")

        # Hash and detect MIME in single pass
        logger.debug(f"Hashing and detecting MIME...")
        decompressed_blobid, mime_type = hash_file_and_detect_mime(output_file)
        logger.debug(f"Decompressed blobid: {decompressed_blobid[:8]}..., mime: {mime_type}")

        # Copy to by-hash (hardlink will work - same filesystem)
        logger.debug(f"Copying to by-hash...")
        copy_to_byhash(output_file, decompressed_blobid)

        # Create extracted medium
        medium_hash = medium_manager.create_extracted_medium(
            source_blobid=blobid,
            extraction_method=method_name
        )

        # Get file info
        stat_info = output_file.stat()
        size = stat_info.st_size
        mtime = int(stat_info.st_mtime)

        # Generate synthetic inode (dev=0 for extracted archives)
        path_str = "/decompressed"
        dev = 0
        ino = medium_manager.generate_synthetic_inode(medium_hash, path_str)

        # Insert inode and path
        medium_manager.bulk_insert_inodes(
            medium_hash,
            [(dev, ino, decompressed_blobid, mime_type, size, mtime)]
        )
        medium_manager.bulk_insert_paths(
            medium_hash,
            [(dev, ino, decompressed_blobid, path_str)]
        )

        # Check if decompressed file is a nested archive
        nested = []
        if mime_type in MIME_HANDLERS:
            logger.debug(f"Decompressed file is nested archive: {mime_type}")
            nested.append((decompressed_blobid, mime_type))

        return ExtractionResult(
            medium_hash=medium_hash,
            files_extracted=1,
            nested_archives=nested
        )


def decompress_gzip(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Decompress gzip file."""
    return _decompress_generic(db, blobid, ['gzip', '-dc'], 'gzip')


def decompress_bzip2(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Decompress bzip2 file."""
    return _decompress_generic(db, blobid, ['bzip2', '-dc'], 'bzip2')


def decompress_xz(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Decompress xz file."""
    return _decompress_generic(db, blobid, ['xz', '-dc'], 'xz')


def decompress_compress(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Decompress compress (.Z) file."""
    return _decompress_generic(db, blobid, ['uncompress', '-c'], 'compress')


def decompress_lzip(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Decompress lzip file."""
    return _decompress_generic(db, blobid, ['lzip', '-dc'], 'lzip')


# =============================================================================
# ARCHIVE HANDLERS (single file -> many files)
# =============================================================================

def extract_tar(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Extract tar archive."""
    medium_manager = ExtractionMediumManager(db)

    # Get source file from by-hash
    source_path = get_byhash_path(blobid)

    # Use EXTRACTION_TEMP_DIR for hardlink optimization
    with tempfile.TemporaryDirectory(dir=EXTRACTION_TEMP_DIR) as tmpdir:
        extract_dir = Path(tmpdir) / "extracted"
        extract_dir.mkdir()

        # Extract tar
        subprocess.run(
            ['tar', '-xf', str(source_path), '-C', str(extract_dir)],
            check=True,
            stderr=subprocess.PIPE
        )

        # Create extracted medium
        medium_hash = medium_manager.create_extracted_medium(
            source_blobid=blobid,
            extraction_method='tar'
        )

        # Walk directory, hash files, insert into DB
        file_count, nested = walk_and_hash_directory(
            extract_dir,
            medium_manager,
            medium_hash
        )

        return ExtractionResult(
            medium_hash=medium_hash,
            files_extracted=file_count,
            nested_archives=nested
        )


def extract_zip(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Extract zip archive."""
    medium_manager = ExtractionMediumManager(db)

    source_path = get_byhash_path(blobid)

    # Use EXTRACTION_TEMP_DIR for hardlink optimization
    with tempfile.TemporaryDirectory(dir=EXTRACTION_TEMP_DIR) as tmpdir:
        extract_dir = Path(tmpdir) / "extracted"
        extract_dir.mkdir()

        # Extract zip
        subprocess.run(
            ['unzip', '-q', str(source_path), '-d', str(extract_dir)],
            check=True,
            stderr=subprocess.PIPE
        )

        medium_hash = medium_manager.create_extracted_medium(
            source_blobid=blobid,
            extraction_method='zip'
        )

        file_count, nested = walk_and_hash_directory(
            extract_dir,
            medium_manager,
            medium_hash
        )

        return ExtractionResult(
            medium_hash=medium_hash,
            files_extracted=file_count,
            nested_archives=nested
        )


def extract_ar(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Extract ar archive."""
    medium_manager = ExtractionMediumManager(db)

    source_path = get_byhash_path(blobid)

    # Use EXTRACTION_TEMP_DIR for hardlink optimization
    with tempfile.TemporaryDirectory(dir=EXTRACTION_TEMP_DIR) as tmpdir:
        extract_dir = Path(tmpdir) / "extracted"
        extract_dir.mkdir()

        # Extract ar (change to extract dir first)
        subprocess.run(
            ['ar', 'x', str(source_path)],
            cwd=extract_dir,
            check=True,
            stderr=subprocess.PIPE
        )

        medium_hash = medium_manager.create_extracted_medium(
            source_blobid=blobid,
            extraction_method='ar'
        )

        file_count, nested = walk_and_hash_directory(
            extract_dir,
            medium_manager,
            medium_hash
        )

        return ExtractionResult(
            medium_hash=medium_hash,
            files_extracted=file_count,
            nested_archives=nested
        )


def extract_rar(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Extract rar archive."""
    medium_manager = ExtractionMediumManager(db)

    source_path = get_byhash_path(blobid)

    # Use EXTRACTION_TEMP_DIR for hardlink optimization
    with tempfile.TemporaryDirectory(dir=EXTRACTION_TEMP_DIR) as tmpdir:
        extract_dir = Path(tmpdir) / "extracted"
        extract_dir.mkdir()

        # Extract rar
        subprocess.run(
            ['unrar', 'x', '-inul', str(source_path), str(extract_dir)],
            check=True,
            stderr=subprocess.PIPE
        )

        medium_hash = medium_manager.create_extracted_medium(
            source_blobid=blobid,
            extraction_method='rar'
        )

        file_count, nested = walk_and_hash_directory(
            extract_dir,
            medium_manager,
            medium_hash
        )

        return ExtractionResult(
            medium_hash=medium_hash,
            files_extracted=file_count,
            nested_archives=nested
        )


def extract_cab(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Extract cab archive."""
    medium_manager = ExtractionMediumManager(db)

    source_path = get_byhash_path(blobid)

    # Use EXTRACTION_TEMP_DIR for hardlink optimization
    with tempfile.TemporaryDirectory(dir=EXTRACTION_TEMP_DIR) as tmpdir:
        extract_dir = Path(tmpdir) / "extracted"
        extract_dir.mkdir()

        # Extract cab
        subprocess.run(
            ['cabextract', '-q', '-d', str(extract_dir), str(source_path)],
            check=True,
            stderr=subprocess.PIPE
        )

        medium_hash = medium_manager.create_extracted_medium(
            source_blobid=blobid,
            extraction_method='cab'
        )

        file_count, nested = walk_and_hash_directory(
            extract_dir,
            medium_manager,
            medium_hash
        )

        return ExtractionResult(
            medium_hash=medium_hash,
            files_extracted=file_count,
            nested_archives=nested
        )


def extract_7z(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Extract 7z archive."""
    medium_manager = ExtractionMediumManager(db)

    source_path = get_byhash_path(blobid)

    # Use EXTRACTION_TEMP_DIR for hardlink optimization
    with tempfile.TemporaryDirectory(dir=EXTRACTION_TEMP_DIR) as tmpdir:
        extract_dir = Path(tmpdir) / "extracted"
        extract_dir.mkdir()

        # Extract 7z
        subprocess.run(
            ['7z', 'x', '-o' + str(extract_dir), str(source_path)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE
        )

        medium_hash = medium_manager.create_extracted_medium(
            source_blobid=blobid,
            extraction_method='7z'
        )

        file_count, nested = walk_and_hash_directory(
            extract_dir,
            medium_manager,
            medium_hash
        )

        return ExtractionResult(
            medium_hash=medium_hash,
            files_extracted=file_count,
            nested_archives=nested
        )


# =============================================================================
# COMPOUND HANDLERS (compression + archive)
# =============================================================================

def extract_tar_gz(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Extract tar.gz (compound format)."""
    medium_manager = ExtractionMediumManager(db)

    source_path = get_byhash_path(blobid)

    # Use EXTRACTION_TEMP_DIR for hardlink optimization
    with tempfile.TemporaryDirectory(dir=EXTRACTION_TEMP_DIR) as tmpdir:
        extract_dir = Path(tmpdir) / "extracted"
        extract_dir.mkdir()

        # Extract tar.gz directly (tar handles gzip)
        subprocess.run(
            ['tar', '-xzf', str(source_path), '-C', str(extract_dir)],
            check=True,
            stderr=subprocess.PIPE
        )

        medium_hash = medium_manager.create_extracted_medium(
            source_blobid=blobid,
            extraction_method='tar.gz'
        )

        file_count, nested = walk_and_hash_directory(
            extract_dir,
            medium_manager,
            medium_hash
        )

        return ExtractionResult(
            medium_hash=medium_hash,
            files_extracted=file_count,
            nested_archives=nested
        )


def extract_tar_bz2(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Extract tar.bz2 (compound format)."""
    medium_manager = ExtractionMediumManager(db)

    source_path = get_byhash_path(blobid)

    # Use EXTRACTION_TEMP_DIR for hardlink optimization
    with tempfile.TemporaryDirectory(dir=EXTRACTION_TEMP_DIR) as tmpdir:
        extract_dir = Path(tmpdir) / "extracted"
        extract_dir.mkdir()

        # Extract tar.bz2 directly (tar handles bzip2)
        subprocess.run(
            ['tar', '-xjf', str(source_path), '-C', str(extract_dir)],
            check=True,
            stderr=subprocess.PIPE
        )

        medium_hash = medium_manager.create_extracted_medium(
            source_blobid=blobid,
            extraction_method='tar.bz2'
        )

        file_count, nested = walk_and_hash_directory(
            extract_dir,
            medium_manager,
            medium_hash
        )

        return ExtractionResult(
            medium_hash=medium_hash,
            files_extracted=file_count,
            nested_archives=nested
        )


def extract_tar_xz(db: psycopg.Connection, blobid: str) -> ExtractionResult:
    """Extract tar.xz (compound format)."""
    medium_manager = ExtractionMediumManager(db)

    source_path = get_byhash_path(blobid)

    # Use EXTRACTION_TEMP_DIR for hardlink optimization
    with tempfile.TemporaryDirectory(dir=EXTRACTION_TEMP_DIR) as tmpdir:
        extract_dir = Path(tmpdir) / "extracted"
        extract_dir.mkdir()

        # Extract tar.xz directly (tar handles xz)
        subprocess.run(
            ['tar', '-xJf', str(source_path), '-C', str(extract_dir)],
            check=True,
            stderr=subprocess.PIPE
        )

        medium_hash = medium_manager.create_extracted_medium(
            source_blobid=blobid,
            extraction_method='tar.xz'
        )

        file_count, nested = walk_and_hash_directory(
            extract_dir,
            medium_manager,
            medium_hash
        )

        return ExtractionResult(
            medium_hash=medium_hash,
            files_extracted=file_count,
            nested_archives=nested
        )
