#!/usr/bin/env -S /home/pball/.local/bin/uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "loguru",
# ]
# ///
#
# Author: PB and Claude
# Date: 2025-10-11
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/tests/test_error_classification.py
#
# Unit tests for BUG-007 error classification

import sys
import os

# Add parent directory to path to import diagnostics module
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'bin'))

from ntt_copier_diagnostics import DiagnosticService


class MockConnection:
    """Mock database connection for testing."""
    pass


def test_classify_error_path_errors():
    """Test classification of path-related errors."""
    conn = MockConnection()
    diag = DiagnosticService(conn, "test_medium", "test_worker")

    # Test file not found
    exc = FileNotFoundError("No such file or directory: /long/path/to/file.txt")
    result = diag.classify_error(exc)
    assert result == 'path_error', f"Expected 'path_error', got '{result}'"
    print("✓ FileNotFoundError classified as path_error")

    # Test path too long
    exc = OSError("[Errno 36] File name too long: '/very/long/path...'")
    result = diag.classify_error(exc)
    assert result == 'path_error', f"Expected 'path_error', got '{result}'"
    print("✓ File name too long classified as path_error")

    # Test OSError with errno 2 (ENOENT)
    exc = OSError(2, "No such file or directory")
    exc.errno = 2
    result = diag.classify_error(exc)
    assert result == 'path_error', f"Expected 'path_error', got '{result}'"
    print("✓ OSError(ENOENT) classified as path_error")


def test_classify_error_io_errors():
    """Test classification of I/O errors from bad media."""
    conn = MockConnection()
    diag = DiagnosticService(conn, "test_medium", "test_worker")

    # Test I/O error message
    exc = OSError("Input/output error reading /mnt/ntt/abc123/file")
    result = diag.classify_error(exc)
    assert result == 'io_error', f"Expected 'io_error', got '{result}'"
    print("✓ I/O error message classified as io_error")

    # Test beyond EOF
    exc = OSError("attempt to access beyond end of device")
    result = diag.classify_error(exc)
    assert result == 'io_error', f"Expected 'io_error', got '{result}'"
    print("✓ Beyond EOF classified as io_error")

    # Test OSError with errno 5 (EIO)
    exc = OSError(5, "Input/output error")
    exc.errno = 5
    result = diag.classify_error(exc)
    assert result == 'io_error', f"Expected 'io_error', got '{result}'"
    print("✓ OSError(EIO) classified as io_error")


def test_classify_error_permission_errors():
    """Test classification of permission errors."""
    conn = MockConnection()
    diag = DiagnosticService(conn, "test_medium", "test_worker")

    # Test PermissionError
    exc = PermissionError("Permission denied: '/restricted/file'")
    result = diag.classify_error(exc)
    assert result == 'permission_error', f"Expected 'permission_error', got '{result}'"
    print("✓ PermissionError classified as permission_error")

    # Test OSError with errno 13 (EACCES)
    exc = OSError(13, "Permission denied")
    exc.errno = 13
    result = diag.classify_error(exc)
    assert result == 'permission_error', f"Expected 'permission_error', got '{result}'"
    print("✓ OSError(EACCES) classified as permission_error")


def test_classify_error_hash_errors():
    """Test classification of hash computation errors."""
    conn = MockConnection()
    diag = DiagnosticService(conn, "test_medium", "test_worker")

    exc = Exception("BLAKE3 hash computation failed")
    result = diag.classify_error(exc)
    assert result == 'hash_error', f"Expected 'hash_error', got '{result}'"
    print("✓ Hash error classified as hash_error")


def test_classify_error_unknown():
    """Test classification of unknown errors."""
    conn = MockConnection()
    diag = DiagnosticService(conn, "test_medium", "test_worker")

    exc = Exception("Some unexpected error")
    result = diag.classify_error(exc)
    assert result == 'unknown', f"Expected 'unknown', got '{result}'"
    print("✓ Unknown error classified as unknown")


def test_determine_failure_status():
    """Test failure status determination."""
    conn = MockConnection()
    diag = DiagnosticService(conn, "test_medium", "test_worker")

    # IO errors should be permanent
    exc = OSError("Input/output error")
    status, error_type = diag.determine_failure_status(exc)
    assert status == 'failed_permanent', f"Expected 'failed_permanent', got '{status}'"
    assert error_type == 'io_error', f"Expected 'io_error', got '{error_type}'"
    print("✓ IO error determined as failed_permanent")

    # Path errors should be retryable
    exc = FileNotFoundError("[Errno 2] No such file or directory: '/path/to/file'")
    status, error_type = diag.determine_failure_status(exc)
    assert status == 'failed_retryable', f"Expected 'failed_retryable', got '{status}'"
    assert error_type == 'path_error', f"Expected 'path_error', got '{error_type}'"
    print("✓ Path error determined as failed_retryable")

    # Unknown errors should be retryable
    exc = Exception("Something weird")
    status, error_type = diag.determine_failure_status(exc)
    assert status == 'failed_retryable', f"Expected 'failed_retryable', got '{status}'"
    assert error_type == 'unknown', f"Expected 'unknown', got '{error_type}'"
    print("✓ Unknown error determined as failed_retryable")


def test_real_error_messages():
    """Test with actual error messages from logs."""
    conn = MockConnection()
    diag = DiagnosticService(conn, "test_medium", "test_worker")

    # Real error from a78ccc01 case (absolute path issue)
    exc = FileNotFoundError(
        "[Errno 2] No such file or directory: "
        "'/mnt/ntt/a78c/data/fast/img/tar/extract-a78c.../home/pball/Maildir/...'"
    )
    result = diag.classify_error(exc)
    assert result == 'path_error', f"Expected 'path_error', got '{result}'"
    print("✓ Real path error (a78ccc01 case) classified correctly")

    # Real FAT beyond EOF error
    exc = OSError("FAT-fs: request beyond EOF")
    result = diag.classify_error(exc)
    assert result == 'io_error', f"Expected 'io_error', got '{result}'"
    print("✓ Real FAT beyond EOF classified correctly")


def run_all_tests():
    """Run all test suites."""
    print("=" * 70)
    print("BUG-007 Error Classification Tests")
    print("=" * 70)
    print()

    test_suites = [
        ("Path Errors", test_classify_error_path_errors),
        ("I/O Errors", test_classify_error_io_errors),
        ("Permission Errors", test_classify_error_permission_errors),
        ("Hash Errors", test_classify_error_hash_errors),
        ("Unknown Errors", test_classify_error_unknown),
        ("Failure Status", test_determine_failure_status),
        ("Real Error Messages", test_real_error_messages),
    ]

    passed = 0
    failed = 0

    for suite_name, test_func in test_suites:
        print(f"\n{suite_name}:")
        print("-" * 70)
        try:
            test_func()
            passed += 1
        except AssertionError as e:
            print(f"✗ FAILED: {e}")
            failed += 1
        except Exception as e:
            print(f"✗ ERROR: {e}")
            failed += 1

    print()
    print("=" * 70)
    print(f"Results: {passed} passed, {failed} failed")
    print("=" * 70)

    return failed == 0


if __name__ == "__main__":
    success = run_all_tests()
    sys.exit(0 if success else 1)
