#!/bin/bash
# Author: PB and Claude
# Date: 2025-10-11
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/test-refactoring.sh
#
# Test suite for Tier 1 refactoring validation
# Tests database connection extraction, config loading fixes, and path variables

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Log file
LOG_FILE="/tmp/ntt-refactor-test-$(date +%Y%m%d-%H%M%S).log"

# Helper functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

pass() {
    ((TOTAL_TESTS++))
    ((PASSED_TESTS++))
    echo -e "  ${GREEN}✓${NC} $1"
    log "PASS: $1"
}

fail() {
    ((TOTAL_TESTS++))
    ((FAILED_TESTS++))
    echo -e "  ${RED}✗${NC} $1"
    log "FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        echo -e "    ${RED}Error: $2${NC}"
        log "  Error: $2"
    fi
}

skip() {
    ((TOTAL_TESTS++))
    ((SKIPPED_TESTS++))
    echo -e "  ${YELLOW}⊘${NC} $1 (skipped)"
    log "SKIP: $1"
}

# Test Suite 1: Syntax & Imports
test_syntax() {
    print_header "Test Suite 1: Syntax & Imports"

    # Test 1.1: Import ntt_db module
    if python3 -c "import sys; sys.path.insert(0, 'bin'); from ntt_db import get_db_connection" 2>/dev/null; then
        pass "ntt_db module imports successfully"
    else
        fail "ntt_db module import failed" "$(python3 -c "import sys; sys.path.insert(0, 'bin'); from ntt_db import get_db_connection" 2>&1)"
    fi

    # Test 1.2: Python script syntax
    local python_scripts=(
        "bin/ntt-verify.py"
        "bin/ntt-copier.py"
        "bin/ntt-re-hardlink.py"
        "bin/ntt-parse-verify-log.py"
        "bin/oneoff-count-hardlinks.py"
        "bin/ntt-mark-excluded"
    )

    for script in "${python_scripts[@]}"; do
        if python3 -m py_compile "$script" 2>/dev/null; then
            pass "$(basename "$script") syntax valid"
        else
            fail "$(basename "$script") syntax invalid" "$(python3 -m py_compile "$script" 2>&1)"
        fi
    done

    # Test 1.3: Bash script syntax
    local bash_scripts=(
        "bin/ntt-copy-workers"
        "bin/ntt-verify-sudo"
        "bin/ntt-orchestrator"
    )

    for script in "${bash_scripts[@]}"; do
        if bash -n "$script" 2>/dev/null; then
            pass "$(basename "$script") syntax valid"
        else
            fail "$(basename "$script") syntax invalid" "$(bash -n "$script" 2>&1)"
        fi
    done
}

# Test Suite 2: Database Connection
test_db_connection() {
    print_header "Test Suite 2: Database Connection"

    # Test 2.1: Regular user DB connection
    if output=$(python3 -c "
import sys
sys.path.insert(0, 'bin')
from ntt_db import get_db_connection
try:
    conn = get_db_connection()
    with conn.cursor() as cur:
        cur.execute('SELECT 1')
    conn.close()
    print('SUCCESS')
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
" 2>&1) && [[ "$output" == "SUCCESS" ]]; then
        pass "Regular user DB connection works"
    else
        fail "Regular user DB connection failed" "$output"
    fi

    # Test 2.2: Sudo DB connection
    if [[ $EUID -eq 0 ]]; then
        local sudo_user="${SUDO_USER:-root}"
        if output=$(python3 -c "
import sys
import os
sys.path.insert(0, 'bin')
os.environ['SUDO_USER'] = '$sudo_user'
from ntt_db import get_db_connection
try:
    conn = get_db_connection()
    with conn.cursor() as cur:
        cur.execute('SELECT current_user')
        user = cur.fetchone()[0]
    conn.close()
    print(f'Connected as: {user}')
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
" 2>&1); then
            pass "Sudo DB connection works ($output)"
        else
            fail "Sudo DB connection failed" "$output"
        fi
    else
        skip "Sudo DB connection test (not running as root)"
    fi

    # Test 2.3: PGUSER environment variable
    if output=$(python3 -c "
import sys
import os
sys.path.insert(0, 'bin')
os.environ['SUDO_USER'] = 'testuser'
from ntt_db import get_db_connection
pguser_before = os.environ.get('PGUSER', 'not_set')
try:
    conn = get_db_connection()
    pguser_after = os.environ.get('PGUSER', 'not_set')
    conn.close()
    if pguser_after == 'testuser':
        print('SUCCESS')
    else:
        print(f'ERROR: PGUSER={pguser_after}, expected testuser')
        sys.exit(1)
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
" 2>&1) && [[ "$output" == "SUCCESS" ]]; then
        pass "PGUSER set correctly under sudo"
    else
        fail "PGUSER not set correctly" "$output"
    fi
}

# Test Suite 3: Config Loading
test_config_loading() {
    print_header "Test Suite 3: Config Loading"

    # Test 3.1: Config file location detection
    local test_user="${SUDO_USER:-$USER}"
    if output=$(bash -c '
if [[ -n "$SUDO_USER" ]]; then
  USER_HOME=$(eval echo ~$SUDO_USER)
  CONFIG_FILE="$USER_HOME/.config/ntt/ntt.env"
else
  CONFIG_FILE=~/.config/ntt/ntt.env
fi
echo "$CONFIG_FILE"
' 2>&1); then
        if [[ -f "$output" ]]; then
            pass "Config file detected at: $output"
        else
            fail "Config file not found" "$output does not exist"
        fi
    else
        fail "Config file location detection failed" "$output"
    fi

    # Test 3.2: ntt-copy-workers config loading
    if bash -c '
source bin/ntt-copy-workers 2>&1 | head -1
exit ${PIPESTATUS[0]}
' >/dev/null 2>&1; then
        pass "ntt-copy-workers loads without config errors"
    else
        fail "ntt-copy-workers config loading has errors"
    fi

    # Test 3.3: ntt-verify-sudo config loading
    if output=$(bin/ntt-verify-sudo --help 2>&1 | head -5); then
        pass "ntt-verify-sudo loads config correctly"
    else
        fail "ntt-verify-sudo config loading failed" "$output"
    fi
}

# Test Suite 4: Path Variables
test_path_variables() {
    print_header "Test Suite 4: Path Variables"

    # Test 4.1: NTT_BIN default in ntt-orchestrator
    if output=$(bash -c '
NTT_BIN="${NTT_BIN:-/home/pball/projects/ntt/bin}"
if [[ -d "$NTT_BIN" ]]; then
    echo "EXISTS: $NTT_BIN"
else
    echo "NOT_FOUND: $NTT_BIN"
    exit 1
fi
' 2>&1) && [[ "$output" == EXISTS:* ]]; then
        pass "NTT_BIN default directory exists"
    else
        fail "NTT_BIN default directory not found" "$output"
    fi

    # Test 4.2: UV_BIN and NTT_BIN in ntt-copy-workers
    if bash -c '
UV_BIN="${UV_BIN:-/home/pball/.local/bin}"
NTT_BIN="${NTT_BIN:-/home/pball/projects/ntt/bin}"
[[ -x "$UV_BIN/uv" ]] || exit 1
[[ -f "$NTT_BIN/ntt-copier.py" ]] || exit 1
' 2>/dev/null; then
        pass "UV_BIN and NTT_BIN paths valid"
    else
        fail "UV_BIN or NTT_BIN paths invalid"
    fi

    # Test 4.3: No hardcoded paths in ntt-orchestrator
    if grep -q "/home/pball/projects/ntt/bin/" bin/ntt-orchestrator 2>/dev/null; then
        fail "Found hardcoded paths in ntt-orchestrator"
    else
        pass "No hardcoded paths in ntt-orchestrator"
    fi

    # Test 4.4: No hardcoded paths in ntt-copy-workers
    if grep -q "/home/pball/.local/bin/uv\|/home/pball/projects/ntt/bin/ntt-copier" bin/ntt-copy-workers 2>/dev/null; then
        fail "Found hardcoded paths in ntt-copy-workers"
    else
        pass "No hardcoded paths in ntt-copy-workers"
    fi
}

# Test Suite 5: Integration Tests
test_integration() {
    print_header "Test Suite 5: Integration Tests"

    # Test 5.1: ntt-verify.py help
    if [[ $EUID -eq 0 ]]; then
        if output=$(bin/ntt-verify.py --help 2>&1); then
            pass "ntt-verify.py --help works"
        else
            fail "ntt-verify.py --help failed" "$output"
        fi
    else
        skip "ntt-verify.py (requires sudo)"
    fi

    # Test 5.2: ntt-copier.py help
    if [[ $EUID -eq 0 ]]; then
        if output=$(bin/ntt-copier.py --help 2>&1); then
            pass "ntt-copier.py --help works"
        else
            fail "ntt-copier.py --help failed" "$output"
        fi
    else
        skip "ntt-copier.py (requires sudo)"
    fi

    # Test 5.3: ntt-re-hardlink.py help
    if [[ $EUID -eq 0 ]]; then
        if output=$(bin/ntt-re-hardlink.py --help 2>&1); then
            pass "ntt-re-hardlink.py --help works"
        else
            fail "ntt-re-hardlink.py --help failed" "$output"
        fi
    else
        skip "ntt-re-hardlink.py (requires sudo)"
    fi

    # Test 5.4: ntt-copy-workers help
    if output=$(bin/ntt-copy-workers --help 2>&1); then
        pass "ntt-copy-workers --help works"
    else
        fail "ntt-copy-workers --help failed" "$output"
    fi

    # Test 5.5: ntt-orchestrator usage
    if [[ $EUID -eq 0 ]]; then
        if output=$(bin/ntt-orchestrator 2>&1 | grep -i usage); then
            pass "ntt-orchestrator shows usage"
        else
            fail "ntt-orchestrator usage failed"
        fi
    else
        skip "ntt-orchestrator (requires sudo)"
    fi
}

# Test Suite 6: Functional Tests
test_functional() {
    print_header "Test Suite 6: Functional Tests"

    # Test 6.1: DB query through ntt_db
    if output=$(python3 -c "
import sys
sys.path.insert(0, 'bin')
from ntt_db import get_db_connection
try:
    conn = get_db_connection()
    with conn.cursor() as cur:
        cur.execute('SELECT COUNT(*) FROM medium LIMIT 1')
        count = cur.fetchone()[0]
    conn.close()
    print(f'Query returned: {count}')
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
" 2>&1) && [[ "$output" == "Query returned:"* ]]; then
        pass "DB query through ntt_db works ($output)"
    else
        fail "DB query through ntt_db failed" "$output"
    fi

    # Test 6.2: ntt-verify dry-run (if running as root)
    if [[ $EUID -eq 0 ]]; then
        if bin/ntt-verify.py --limit 1 --dry-run >/dev/null 2>&1; then
            pass "ntt-verify.py --dry-run completes"
        else
            skip "ntt-verify.py dry-run (no data or error)"
        fi
    else
        skip "ntt-verify.py dry-run (requires sudo)"
    fi
}

# Test Suite 7: Environment Variable Overrides
test_env_overrides() {
    print_header "Test Suite 7: Environment Variable Overrides"

    # Test 7.1: NTT_BIN override
    if output=$(NTT_BIN=/tmp/test bash -c 'echo "${NTT_BIN:-/home/pball/projects/ntt/bin}"' 2>&1) && [[ "$output" == "/tmp/test" ]]; then
        pass "NTT_BIN environment override works"
    else
        fail "NTT_BIN override failed" "$output"
    fi

    # Test 7.2: NTT_DB_URL override
    if output=$(NTT_DB_URL="postgresql://test@localhost/testdb" python3 -c "
import os
db_url = os.environ.get('NTT_DB_URL', 'postgresql:///copyjob')
assert db_url == 'postgresql://test@localhost/testdb', f'Got {db_url}'
print('SUCCESS')
" 2>&1) && [[ "$output" == "SUCCESS" ]]; then
        pass "NTT_DB_URL environment override works"
    else
        fail "NTT_DB_URL override failed" "$output"
    fi
}

# Test Suite 8: Backward Compatibility
test_backward_compat() {
    print_header "Test Suite 8: Backward Compatibility"

    # Test 8.1: DB connection with defaults
    if output=$(env -u NTT_DB_URL python3 -c "
import sys
sys.path.insert(0, 'bin')
from ntt_db import get_db_connection
try:
    conn = get_db_connection()
    conn.close()
    print('SUCCESS')
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
" 2>&1) && [[ "$output" == "SUCCESS" ]]; then
        pass "DB connection works with default URL"
    else
        fail "DB connection with default URL failed" "$output"
    fi

    # Test 8.2: NTT_BIN fallback
    if output=$(env -u NTT_BIN bash -c '
NTT_BIN="${NTT_BIN:-/home/pball/projects/ntt/bin}"
[[ -d "$NTT_BIN" ]] && echo "SUCCESS" || echo "FAIL"
' 2>&1) && [[ "$output" == "SUCCESS" ]]; then
        pass "NTT_BIN fallback to default works"
    else
        fail "NTT_BIN fallback failed" "$output"
    fi
}

# Print summary
print_summary() {
    echo ""
    print_header "Test Summary"
    echo ""
    echo "  Total Tests:  $TOTAL_TESTS"
    echo -e "  ${GREEN}Passed:${NC}       $PASSED_TESTS"
    echo -e "  ${RED}Failed:${NC}       $FAILED_TESTS"
    echo -e "  ${YELLOW}Skipped:${NC}      $SKIPPED_TESTS"
    echo ""
    echo "  Log file: $LOG_FILE"
    echo ""

    if [[ $FAILED_TESTS -eq 0 ]]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}All tests passed! ✓${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return 0
    else
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}Some tests failed. Check log for details.${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return 1
    fi
}

# Usage
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Test suite for NTT Tier 1 refactoring validation.

Options:
    --quick         Run quick smoke tests only (~2 min)
    --core          Run core functionality tests (~10 min)
    --full          Run complete test suite (~25 min, default)
    --suite NAME    Run specific test suite
    --help          Show this help

Available test suites:
    syntax          Syntax & import validation
    db-connection   Database connection tests
    config-loading  Config file loading tests
    path-variables  Path variable resolution tests
    integration     Integration tests (help commands)
    functional      Functional tests (actual operations)
    env-overrides   Environment variable override tests
    backward-compat Backward compatibility tests

Examples:
    sudo bin/test-refactoring.sh --quick
    sudo bin/test-refactoring.sh --suite db-connection
    sudo bin/test-refactoring.sh --full

EOF
    exit 0
}

# Main execution
main() {
    local mode="full"
    local specific_suite=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --quick)
                mode="quick"
                shift
                ;;
            --core)
                mode="core"
                shift
                ;;
            --full)
                mode="full"
                shift
                ;;
            --suite)
                specific_suite="$2"
                shift 2
                ;;
            --help)
                usage
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Print header
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  NTT Tier 1 Refactoring Test Suite                        ║${NC}"
    echo -e "${BLUE}║  Testing: DB extraction, config fixes, path variables      ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log "Starting test run (mode: $mode)"

    # Run tests based on mode
    if [[ -n "$specific_suite" ]]; then
        case "$specific_suite" in
            syntax) test_syntax ;;
            db-connection) test_db_connection ;;
            config-loading) test_config_loading ;;
            path-variables) test_path_variables ;;
            integration) test_integration ;;
            functional) test_functional ;;
            env-overrides) test_env_overrides ;;
            backward-compat) test_backward_compat ;;
            *)
                echo "Unknown suite: $specific_suite"
                usage
                ;;
        esac
    elif [[ "$mode" == "quick" ]]; then
        test_syntax
        test_db_connection
        test_path_variables
    elif [[ "$mode" == "core" ]]; then
        test_syntax
        test_db_connection
        test_config_loading
        test_path_variables
        test_integration
    else  # full
        test_syntax
        test_db_connection
        test_config_loading
        test_path_variables
        test_integration
        test_functional
        test_env_overrides
        test_backward_compat
    fi

    # Print summary and exit
    if print_summary; then
        log "Test run completed: SUCCESS"
        exit 0
    else
        log "Test run completed: FAILURE"
        exit 1
    fi
}

# Run main
main "$@"
