#!/bin/bash
# setup_test_env.sh
# Creates isolated test environment for ntt-copier testing
#
# Safety: Uses dedicated test user with NO access to public schema
# This prevents any possibility of corrupting production data

set -euo pipefail

readonly TEST_DB="copyjob"
readonly TEST_SCHEMA="copyjob_test"
readonly TEST_USER="copyjob_test_user"
readonly TEST_PASSWORD="insecure_test_password"
readonly TEST_ROOT="/tmp/copyjob_test"

echo "============================================================"
echo "NTT Test Environment Setup"
echo "============================================================"

# --- Teardown previous environment ---
echo "--- Cleaning up previous test environment ---"
psql "${TEST_DB}" -v ON_ERROR_STOP=1 <<-EOF 2>/dev/null || true
    -- Prevent new connections from test user
    REVOKE CONNECT ON DATABASE "${TEST_DB}" FROM "${TEST_USER}";

    -- Terminate any active test user sessions
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE usename = '${TEST_USER}';

    -- Drop test schema and all its objects
    DROP SCHEMA IF EXISTS "${TEST_SCHEMA}" CASCADE;

    -- Drop test user
    DROP ROLE IF EXISTS "${TEST_USER}";
EOF

echo "✓ Previous environment cleaned"

# --- Create new environment ---
echo "--- Creating new test environment ---"
psql "${TEST_DB}" -v ON_ERROR_STOP=1 <<-EOF
    -- Create dedicated test user
    CREATE ROLE "${TEST_USER}" WITH LOGIN PASSWORD '${TEST_PASSWORD}';

    -- Create test schema owned by test user
    CREATE SCHEMA "${TEST_SCHEMA}" AUTHORIZATION "${TEST_USER}";

    -- CRITICAL SAFETY RAIL: Revoke ALL access to public schema
    -- This prevents accidental production data access/modification
    REVOKE ALL ON SCHEMA public FROM "${TEST_USER}";

    -- Grant USAGE on public schema for extensions (read-only)
    -- Required for TABLESAMPLE and other extensions
    GRANT USAGE ON SCHEMA public TO "${TEST_USER}";

    -- Grant CONNECT to test database
    GRANT CONNECT ON DATABASE "${TEST_DB}" TO "${TEST_USER}";

    -- Grant usage on test schema (redundant but explicit)
    GRANT ALL ON SCHEMA "${TEST_SCHEMA}" TO "${TEST_USER}";
EOF

echo "✓ Test user and schema created"

# --- Copy schema structure ---
echo "--- Copying schema structure from production ---"
pg_dump -s --schema=public "${TEST_DB}" \
    | sed "s/CREATE SCHEMA public;/CREATE SCHEMA IF NOT EXISTS ${TEST_SCHEMA};/" \
    | sed "s/ALTER SCHEMA public OWNER TO .*/ALTER SCHEMA ${TEST_SCHEMA} OWNER TO ${TEST_USER};/" \
    | sed -E "s/SET search_path = public/SET search_path = ${TEST_SCHEMA}/" \
    | sed -E "s/ public\./ ${TEST_SCHEMA}./g" \
    | psql -v ON_ERROR_STOP=1 "${TEST_DB}" > /dev/null

# Grant permissions on all tables to test user
psql "${TEST_DB}" -v ON_ERROR_STOP=1 <<-EOF > /dev/null
    GRANT ALL ON ALL TABLES IN SCHEMA "${TEST_SCHEMA}" TO "${TEST_USER}";
    GRANT ALL ON ALL SEQUENCES IN SCHEMA "${TEST_SCHEMA}" TO "${TEST_USER}";

    -- Install required extensions
    CREATE EXTENSION IF NOT EXISTS tsm_system_rows;
EOF

echo "✓ Schema structure copied and extensions installed"

# --- Setup test filesystem ---
echo "--- Setting up test filesystem ---"
rm -rf "${TEST_ROOT}"
mkdir -p "${TEST_ROOT}"/{source,archive,by-hash}
chmod 755 "${TEST_ROOT}"

echo "✓ Test filesystem created at ${TEST_ROOT}"

# --- Generate test data ---
echo "--- Generating test data ---"
if [ -f "$(dirname "$0")/setup_test_data.py" ]; then
    export PGPASSWORD="${TEST_PASSWORD}"
    "$(dirname "$0")/setup_test_data.py" \
        --db-url="postgresql://${TEST_USER}@localhost/${TEST_DB}" \
        --schema="${TEST_SCHEMA}" \
        --source="${TEST_ROOT}/source"
    echo "✓ Test data generated"
else
    echo "⚠ Warning: setup_test_data.py not found - skipping data generation"
    echo "  You'll need to populate test data manually"
fi

# --- Print usage instructions ---
echo ""
echo "============================================================"
echo "Test Environment Ready"
echo "============================================================"
echo ""
echo "Database: ${TEST_DB}"
echo "Schema:   ${TEST_SCHEMA}"
echo "User:     ${TEST_USER}"
echo "Root:     ${TEST_ROOT}"
echo ""
echo "To run tests:"
echo "  export PGPASSWORD='${TEST_PASSWORD}'"
echo "  NTT_DB_URL='postgresql://${TEST_USER}@localhost/${TEST_DB}?options=-c search_path=${TEST_SCHEMA}' \\"
echo "  NTT_ARCHIVE_ROOT=${TEST_ROOT}/archive \\"
echo "  NTT_BY_HASH_ROOT=${TEST_ROOT}/by-hash \\"
echo "  python ntt-copier.py --limit=10 --workers=1"
echo ""
echo "To inspect test database:"
echo "  PGPASSWORD='${TEST_PASSWORD}' psql -U ${TEST_USER} ${TEST_DB} -c 'SET search_path = ${TEST_SCHEMA}; SELECT COUNT(*) FROM inode;'"
echo ""
echo "To cleanup:"
echo "  ./setup_test_env.sh  (re-run this script)"
echo ""
