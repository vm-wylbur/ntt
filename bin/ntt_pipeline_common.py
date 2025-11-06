#!/usr/bin/env -S /home/pball/.local/bin/uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "blake3",
#     "python-magic",
#     "loguru",
# ]
# ///
#
# Author: PB and Claude
# Date: 2025-11-06
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/lib/ntt_pipeline_common.py
#
# Shared pipeline functions for NTT tools (copier, extractor, etc.)

import os
from pathlib import Path
from typing import Tuple

import blake3
import magic
from loguru import logger


# =============================================================================
# CONFIGURATION
# =============================================================================

# By-hash storage base (configurable via environment)
BY_HASH_BASE = Path(os.environ.get('NTT_BY_HASH_BASE', '/data/fast/ntt/by-hash'))

# Extraction temp directory (must be same filesystem as by-hash for hardlinks)
# Default: /data/fast/tmp (not derived from by-hash, separate location)
EXTRACTION_TEMP_DIR = Path(os.environ.get(
    'NTT_EXTRACTION_TEMP',
    '/data/fast/tmp'
))


# =============================================================================
# HASHING AND MIME DETECTION
# =============================================================================

def hash_file_and_detect_mime(path: Path) -> Tuple[str, str]:
    """
    Hash file with BLAKE3 and detect MIME type in single pass.

    Reads file once in 64KB chunks:
    - First chunk used for MIME detection
    - All chunks used for hashing

    Args:
        path: Path to file

    Returns:
        (blobid, mime_type) tuple

    Raises:
        IOError: If file cannot be read
        OSError: If file access fails

    Notes:
        - Empty files return (hash, 'application/x-empty')
        - MIME detection falls back to 'application/octet-stream' on error
        - This prevents MIME errors from blocking file processing
    """
    hasher = blake3.blake3()
    mime_buffer = None

    try:
        with open(path, 'rb') as f:
            # Read first chunk (used for both hashing and MIME detection)
            first_chunk = f.read(65536)  # 64KB
            if not first_chunk:
                # Empty file - still compute hash of empty content
                pass  # hasher is already initialized with empty state
            else:
                mime_buffer = first_chunk
                hasher.update(first_chunk)

                # Read remaining chunks (hashing only)
                while chunk := f.read(65536):
                    hasher.update(chunk)
    except (IOError, OSError) as e:
        raise IOError(f"Failed to read file {path}: {e}")

    blobid = hasher.hexdigest()

    # Detect MIME type
    if mime_buffer is None:
        # Empty file
        mime_type = 'application/x-empty'
    else:
        try:
            mime_type = magic.from_buffer(mime_buffer, mime=True)
        except Exception as e:
            # Fallback if MIME detection fails (corrupted magic DB, etc.)
            logger.warning(f"MIME detection failed for {path}: {e}, using fallback")
            mime_type = 'application/octet-stream'

    return blobid, mime_type


def hash_file(path: Path) -> str:
    """
    Hash file with BLAKE3 (MIME-agnostic version).

    Use this when you don't need MIME type.
    For efficiency, prefer hash_file_and_detect_mime() if you need both.

    Args:
        path: Path to file

    Returns:
        BLAKE3 hex digest

    Raises:
        IOError: If file cannot be read
    """
    blobid, _ = hash_file_and_detect_mime(path)
    return blobid


def detect_mime_type_via_magic(magic_detector, path: Path) -> str:
    """
    Detect MIME type using python-magic (for ntt-copier.py compatibility).

    Args:
        magic_detector: Reusable magic.Magic() instance
        path: File path

    Returns:
        MIME type string, or 'application/octet-stream' on error

    Notes:
        - ntt-copier.py reuses Magic() instance for performance
        - Falls back to 'application/octet-stream' if detection fails
        - Does NOT read file for hashing
    """
    try:
        return magic_detector.from_file(str(path))
    except Exception:
        return 'application/octet-stream'


# =============================================================================
# BY-HASH STORAGE
# =============================================================================

def get_byhash_path(blobid: str) -> Path:
    """
    Get by-hash path for a blobid.

    Format: $BY_HASH_BASE/AB/CD/ABCD...
    Default: /data/fast/ntt/by-hash/AB/CD/ABCD...

    Args:
        blobid: BLAKE3 hex digest

    Returns:
        Full path to blob in by-hash storage

    Raises:
        ValueError: If blobid is invalid (length < 4)

    Notes:
        - Configurable via NTT_BY_HASH_BASE environment variable
        - Does NOT check if file exists
    """
    if len(blobid) < 4:
        raise ValueError(f"Invalid blobid (too short): {blobid}")

    return BY_HASH_BASE / blobid[:2] / blobid[2:4] / blobid


def copy_to_byhash(source: Path, blobid: str) -> Path:
    """
    Copy file to by-hash storage.

    Strategy:
    1. Check if blob already exists (idempotent)
    2. Create directory structure if needed
    3. Try hardlink first (same filesystem, fast)
    4. Fall back to copy if hardlink fails

    Args:
        source: Source file path (should be in EXTRACTION_TEMP_DIR for hardlinks)
        blobid: BLAKE3 hex digest

    Returns:
        Destination path (by-hash location)

    Raises:
        ValueError: If blobid invalid
        IOError: If mkdir or copy fails
        OSError: If filesystem operations fail

    Notes:
        - Idempotent: Returns existing path if blob already exists
        - Hardlink preferred over copy for same-filesystem efficiency
        - For hardlinks to work, source must be on same filesystem as BY_HASH_BASE
    """
    dest = get_byhash_path(blobid)

    # Already exists - idempotent
    if dest.exists():
        return dest

    # Create directory structure
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        raise IOError(f"Failed to create by-hash directory {dest.parent}: {e}")

    # Try hardlink first (same filesystem)
    try:
        os.link(source, dest)
        logger.debug(f"Hardlinked {source.name} to by-hash: {blobid[:8]}")
        return dest
    except OSError as e:
        # Hardlink failed (different filesystem or not supported)
        logger.debug(f"Hardlink failed ({e}), falling back to copy")

    # Fall back to copy
    try:
        import shutil
        shutil.copy2(source, dest)
        logger.debug(f"Copied {source.name} to by-hash: {blobid[:8]}")
        return dest
    except (IOError, OSError) as e:
        raise IOError(f"Failed to copy {source} to {dest}: {e}")
