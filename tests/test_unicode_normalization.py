#!/usr/bin/env python3
# Author: PB and Claude
# Date: 2025-11-24
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/tests/test_unicode_normalization.py
#
# Unit tests for Unicode path handling fix in parse_partition_path

import unicodedata
import tempfile
import os
from pathlib import Path


# Copy of the fixed function for testing (avoids blake3 dependency)
def parse_partition_path(path_bytes: bytes, medium_hash: str) -> Path:
    """Parse path from database (bytea) into filesystem path."""
    # BUG FIX: Decode as UTF-8 first, preserve original Unicode form
    if isinstance(path_bytes, bytes):
        try:
            path_str = path_bytes.decode('utf-8')
        except UnicodeDecodeError:
            path_str = path_bytes.decode('latin1')
    elif isinstance(path_bytes, memoryview):
        path_str = bytes(path_bytes).decode('utf-8')
    else:
        path_str = str(path_bytes)

    if path_str.startswith('/'):
        # Try as-is first (preserves original form from filesystem)
        result = Path(path_str)
        if result.exists():
            return result

        # Try NFC normalized
        nfc_path = unicodedata.normalize('NFC', path_str)
        if nfc_path != path_str:
            result_nfc = Path(nfc_path)
            if result_nfc.exists():
                return result_nfc

        # Try NFD normalized
        nfd_path = unicodedata.normalize('NFD', path_str)
        if nfd_path != path_str:
            result_nfd = Path(nfd_path)
            if result_nfd.exists():
                return result_nfd

        return result

    mount_base = Path(f"/mnt/ntt/{medium_hash}")
    if mount_base.exists():
        result = mount_base / path_str
        if result.exists():
            return result

        nfc_path = unicodedata.normalize('NFC', path_str)
        if nfc_path != path_str:
            result_nfc = mount_base / nfc_path
            if result_nfc.exists():
                return result_nfc

        nfd_path = unicodedata.normalize('NFD', path_str)
        if nfd_path != path_str:
            result_nfd = mount_base / nfd_path
            if result_nfd.exists():
                return result_nfd

        return result

    return Path(path_str)


def test_utf8_decoding():
    """Verify UTF-8 decoding produces correct string (not mojibake)."""
    # UTF-8 encoding of right single quote (U+2019)
    utf8_bytes = b"patrick\xe2\x80\x99s"

    # OLD (broken): latin1 decoding creates mojibake
    latin1_decoded = utf8_bytes.decode('latin1')
    print(f"  Latin1 decoded (mojibake): {repr(latin1_decoded)}")

    # NEW (fixed): UTF-8 decoding gets proper Unicode
    utf8_decoded = utf8_bytes.decode('utf-8')
    print(f"  UTF-8 decoded (correct): {repr(utf8_decoded)}")

    # Verify UTF-8 gives us the actual right single quote
    assert '\u2019' in utf8_decoded, "UTF-8 should decode to actual apostrophe"
    assert '\u2019' not in latin1_decoded, "Latin1 creates mojibake, not real apostrophe"

    # Verify the full function works correctly
    result = parse_partition_path(utf8_bytes, "dummy")
    result_str = str(result)
    assert '\u2019' in result_str, "Function should return proper Unicode"
    print(f"PASS: UTF-8 decoding produces correct string")


def test_nfd_fallback():
    """Test that NFD paths are found when filesystem stores NFD."""
    with tempfile.TemporaryDirectory() as tmpdir:
        # Create file with NFD name (e.g., e + combining circumflex)
        nfd_name = unicodedata.normalize('NFD', "café.txt")  # e + ́
        nfd_path = Path(tmpdir) / nfd_name
        nfd_path.touch()
        print(f"  Created NFD file: {repr(str(nfd_path))}")

        # Query with NFC form (database might store this)
        nfc_name = unicodedata.normalize('NFC', "café.txt")  # é as single char
        query_path = f"{tmpdir}/{nfc_name}".encode('utf-8')
        print(f"  Querying with NFC: {repr(nfc_name)}")

        result = parse_partition_path(query_path, "dummy")
        assert result.exists(), f"Should find file via NFD fallback: {result}"
        print(f"PASS: NFD fallback works")


def test_nfc_fallback():
    """Test that NFC paths are found when filesystem stores NFC."""
    with tempfile.TemporaryDirectory() as tmpdir:
        # Create file with NFC name
        nfc_name = unicodedata.normalize('NFC', "café.txt")
        nfc_path = Path(tmpdir) / nfc_name
        nfc_path.touch()
        print(f"  Created NFC file: {repr(str(nfc_path))}")

        # Query with NFD form
        nfd_name = unicodedata.normalize('NFD', "café.txt")
        query_path = f"{tmpdir}/{nfd_name}".encode('utf-8')
        print(f"  Querying with NFD: {repr(nfd_name)}")

        result = parse_partition_path(query_path, "dummy")
        assert result.exists(), f"Should find file via NFC fallback: {result}"
        print(f"PASS: NFC fallback works")


def test_exact_match():
    """Test that exact paths are returned when they exist."""
    with tempfile.TemporaryDirectory() as tmpdir:
        # Create file
        test_path = Path(tmpdir) / "simple.txt"
        test_path.touch()

        query_path = str(test_path).encode('utf-8')
        result = parse_partition_path(query_path, "dummy")

        assert result.exists(), "Should find exact match"
        assert str(result) == str(test_path), "Should return exact path"
        print(f"PASS: Exact match works")


def test_ascii_path():
    """Plain ASCII paths should work unchanged."""
    ascii_path = b"/data/test/simple/file.txt"
    result = parse_partition_path(ascii_path, "dummy_hash")

    assert str(result) == "/data/test/simple/file.txt"
    print(f"PASS: ASCII path unchanged")


if __name__ == "__main__":
    print("=== Unicode Path Handling Unit Tests ===\n")

    test_utf8_decoding()
    test_ascii_path()
    test_exact_match()
    test_nfc_fallback()
    test_nfd_fallback()

    print("\n=== ALL TESTS PASSED ===")
