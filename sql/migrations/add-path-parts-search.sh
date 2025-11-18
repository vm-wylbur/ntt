#!/usr/bin/env bash
# Author: PB and Claude
# Date: 2025-11-17
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/sql/migrations/add-path-parts-search.sh
#
# Add path_parts text[] column to paths table for fast GIN-indexed searching.
# Processes existing rows in batches by medium_hash with progress logging.
#
# Usage:
#   ./sql/migrations/add-path-parts-search.sh [--dry-run]
#
# Options:
#   --dry-run    Show what would be done without making changes
#
# Examples of usage after migration:
#
#   -- Find paths containing "README" (case-insensitive)
#   SELECT medium_hash, convert_from(path, 'UTF8') as path_text
#   FROM paths
#   WHERE path_parts && ARRAY['readme'];
#
#   -- Find paths in "Documents" directory
#   SELECT medium_hash, convert_from(path, 'UTF8') as path_text
#   FROM paths
#   WHERE 'documents' = ANY(path_parts);
#
#   -- Multi-term search (must contain ALL terms)
#   SELECT medium_hash, convert_from(path, 'UTF8') as path_text
#   FROM paths
#   WHERE path_parts @> ARRAY['home', 'user', 'documents'];
#
#   -- Find .doc files anywhere
#   SELECT medium_hash, convert_from(path, 'UTF8') as path_text
#   FROM paths
#   WHERE EXISTS (
#       SELECT 1 FROM unnest(path_parts) AS part
#       WHERE part LIKE '%.doc'
#   );
#
#   -- Find paths with specific extension using last element
#   SELECT medium_hash, convert_from(path, 'UTF8') as path_text
#   FROM paths
#   WHERE path_parts[array_length(path_parts, 1)] LIKE '%.pdf';
#
#   -- Count files by extension
#   SELECT
#       substring(path_parts[array_length(path_parts, 1)] from '\.([^.]+)$') as ext,
#       COUNT(*) as file_count
#   FROM paths
#   WHERE fs_type = 'f'
#     AND array_length(path_parts, 1) > 0
#   GROUP BY ext
#   ORDER BY file_count DESC
#   LIMIT 20;
#
#   -- Find duplicate filenames across different directories
#   SELECT
#       path_parts[array_length(path_parts, 1)] as filename,
#       COUNT(*) as occurrences,
#       array_agg(DISTINCT medium_hash) as mediums
#   FROM paths
#   WHERE fs_type = 'f'
#   GROUP BY filename
#   HAVING COUNT(*) > 10
#   ORDER BY occurrences DESC;

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"

# shellcheck source=../../lib/bash-logger.sh
source "$LIB_DIR/bash-logger.sh"
log_init || exit 1

DB_URL=${NTT_DB_URL:-postgres:///copyjob}
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run]"
            exit 1
            ;;
    esac
done

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "DRY RUN MODE - no changes will be made"
fi

# ---------- Step 1: Add column ----------
log_info "Step 1: Adding path_parts column"

if [[ "$DRY_RUN" == "false" ]]; then
    sudo -u postgres psql "$DB_URL" -c "
        ALTER TABLE paths ADD COLUMN IF NOT EXISTS path_parts text[];
    " || {
        log_error "Failed to add path_parts column"
        exit 1
    }
    log_info "Column added successfully"
else
    log_info "Would add: ALTER TABLE paths ADD COLUMN path_parts text[]"
fi

# ---------- Step 2: Create batch processing function ----------
log_info "Step 2: Creating batch processing function"

if [[ "$DRY_RUN" == "false" ]]; then
    sudo -u postgres psql "$DB_URL" -c "
        CREATE OR REPLACE FUNCTION populate_path_parts_batch(batch_hash text)
        RETURNS bigint AS \$\$
        DECLARE
            row_count bigint;
        BEGIN
            UPDATE paths SET path_parts =
                string_to_array(
                    lower(  -- lowercase everything for case-insensitive search
                        regexp_replace(
                            convert_from(path, 'LATIN1'),  -- Always succeeds, handles all byte sequences
                            '[/\\\\]+',  -- Normalize path separators (/ or \\)
                            '/',
                            'g'
                        )
                    ),
                    '/'  -- Split on forward slash
                )
            WHERE medium_hash = batch_hash
              AND path_parts IS NULL;

            GET DIAGNOSTICS row_count = ROW_COUNT;
            RETURN row_count;
        END;
        \$\$ LANGUAGE plpgsql;
    " || {
        log_error "Failed to create batch function"
        exit 1
    }
    log_info "Function created successfully"
else
    log_info "Would create function: populate_path_parts_batch(text)"
fi

# ---------- Step 3: Process batches ----------
log_info "Step 3: Processing existing paths in batches"

# Get list of medium hashes to process
MEDIUM_HASHES=$(sudo -u postgres psql "$DB_URL" -t -A -c "
    SELECT DISTINCT medium_hash
    FROM paths
    WHERE path_parts IS NULL
    ORDER BY medium_hash;
" 2>/dev/null || echo "")

if [[ -z "$MEDIUM_HASHES" ]]; then
    log_info "No rows to process (path_parts already populated)"
else
    TOTAL_BATCHES=$(echo "$MEDIUM_HASHES" | wc -l)
    CURRENT_BATCH=0

    log_info "Found $TOTAL_BATCHES medium hashes to process"

    while IFS= read -r medium_hash; do
        CURRENT_BATCH=$((CURRENT_BATCH + 1))

        if [[ "$DRY_RUN" == "false" ]]; then
            ROWS_UPDATED=$(sudo -u postgres psql "$DB_URL" -t -A -c "
                SELECT populate_path_parts_batch('$medium_hash');
            " 2>/dev/null || echo "0")

            log_info "Batch $CURRENT_BATCH/$TOTAL_BATCHES: medium_hash=$medium_hash rows_updated=$ROWS_UPDATED"
        else
            log_info "Would process batch $CURRENT_BATCH/$TOTAL_BATCHES: medium_hash=$medium_hash"
        fi
    done <<< "$MEDIUM_HASHES"

    log_info "Batch processing complete: $TOTAL_BATCHES batches processed"
fi

# ---------- Step 4: Create GIN index ----------
log_info "Step 4: Creating GIN index (this may take a while)"

if [[ "$DRY_RUN" == "false" ]]; then
    # Check if index already exists
    INDEX_EXISTS=$(sudo -u postgres psql "$DB_URL" -t -A -c "
        SELECT COUNT(*)
        FROM pg_indexes
        WHERE tablename = 'paths'
          AND indexname = 'paths_parts_gin_idx';
    " 2>/dev/null || echo "0")

    if [[ "$INDEX_EXISTS" -eq "0" ]]; then
        log_info "Creating index (CONCURRENTLY to avoid blocking)"
        sudo -u postgres psql "$DB_URL" -c "
            CREATE INDEX CONCURRENTLY paths_parts_gin_idx
            ON paths USING gin(path_parts);
        " || {
            log_error "Failed to create GIN index"
            exit 1
        }
        log_info "GIN index created successfully"
    else
        log_info "GIN index already exists, skipping"
    fi
else
    log_info "Would create: CREATE INDEX CONCURRENTLY paths_parts_gin_idx ON paths USING gin(path_parts)"
fi

# ---------- Step 5: Cleanup ----------
log_info "Step 5: Cleaning up temporary function"

if [[ "$DRY_RUN" == "false" ]]; then
    sudo -u postgres psql "$DB_URL" -c "
        DROP FUNCTION IF EXISTS populate_path_parts_batch(text);
    " || {
        log_warn "Failed to drop temporary function (non-critical)"
    }
    log_info "Cleanup complete"
else
    log_info "Would drop function: populate_path_parts_batch(text)"
fi

# ---------- Step 6: Verification ----------
log_info "Step 6: Verification"

if [[ "$DRY_RUN" == "false" ]]; then
    TOTAL_ROWS=$(sudo -u postgres psql "$DB_URL" -t -A -c "
        SELECT COUNT(*) FROM paths;
    " 2>/dev/null || echo "0")

    POPULATED_ROWS=$(sudo -u postgres psql "$DB_URL" -t -A -c "
        SELECT COUNT(*) FROM paths WHERE path_parts IS NOT NULL;
    " 2>/dev/null || echo "0")

    log_info "Total rows: $TOTAL_ROWS"
    log_info "Rows with path_parts: $POPULATED_ROWS"

    if [[ "$TOTAL_ROWS" -eq "$POPULATED_ROWS" ]]; then
        log_info "✓ Migration complete: all rows populated"
    else
        MISSING=$((TOTAL_ROWS - POPULATED_ROWS))
        log_warn "⚠ Migration incomplete: $MISSING rows still missing path_parts"
    fi

    # Show sample data
    log_info "Sample path_parts data:"
    sudo -u postgres psql "$DB_URL" -c "
        SELECT
            convert_from(path, 'UTF8') as original_path,
            path_parts
        FROM paths
        WHERE path_parts IS NOT NULL
        LIMIT 5;
    " || true
else
    log_info "Would verify row counts and show samples"
fi

log_info "Migration script complete"
exit 0
