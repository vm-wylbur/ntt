-- Author: PB and Claude
-- Date: 2025-10-06
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ------
-- ntt/sql/optimize-queue-stats-trigger.sql
--
-- Convert row-level update_queue_stats trigger to statement-level with transition tables
-- Expected benefit: 10-100x faster for bulk INSERT/UPDATE operations
--
-- Based on Web-Claude's recommendation from integrated analysis

-- Step 1: Create statement-level trigger function
CREATE OR REPLACE FUNCTION public.update_queue_stats_batch()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Aggregate all inserted rows by medium_hash
        INSERT INTO queue_stats (medium_hash, unclaimed_count, total_count)
        SELECT medium_hash, COUNT(*) as cnt, COUNT(*) as cnt
        FROM new_rows
        GROUP BY medium_hash
        ON CONFLICT (medium_hash) DO UPDATE
        SET unclaimed_count = queue_stats.unclaimed_count + EXCLUDED.unclaimed_count,
            total_count = queue_stats.total_count + EXCLUDED.total_count,
            last_updated = NOW();

    ELSIF TG_OP = 'UPDATE' THEN
        -- Count rows that changed from copied=false to copied=true
        UPDATE queue_stats qs
        SET unclaimed_count = GREATEST(0, qs.unclaimed_count - cnt),
            last_updated = NOW()
        FROM (
            SELECT medium_hash, COUNT(*) as cnt
            FROM old_rows o
            JOIN new_rows n USING (medium_hash, ino)
            WHERE o.copied = false AND n.copied = true
            GROUP BY medium_hash
        ) changes
        WHERE qs.medium_hash = changes.medium_hash;

    ELSIF TG_OP = 'DELETE' THEN
        -- Decrement counts for deleted inodes
        UPDATE queue_stats qs
        SET unclaimed_count = GREATEST(0, qs.unclaimed_count - cnt),
            total_count = GREATEST(0, qs.total_count - cnt),
            last_updated = NOW()
        FROM (
            SELECT medium_hash, COUNT(*) as cnt
            FROM old_rows
            GROUP BY medium_hash
        ) deletions
        WHERE qs.medium_hash = deletions.medium_hash;
    END IF;

    RETURN NULL;
END;
$function$;

-- Step 2: Drop existing row-level triggers from all inode partitions
DO $$
DECLARE
    partition_rec RECORD;
BEGIN
    FOR partition_rec IN
        SELECT c.relname as partition_name
        FROM pg_class c
        JOIN pg_inherits i ON i.inhrelid = c.oid
        JOIN pg_class parent ON parent.oid = i.inhparent
        WHERE parent.relname = 'inode'
        AND c.relispartition
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trigger_queue_stats ON %I;',
                      partition_rec.partition_name);
        RAISE NOTICE 'Dropped row-level trigger from %', partition_rec.partition_name;
    END LOOP;
END $$;

-- Also drop from parent table if exists
DROP TRIGGER IF EXISTS trigger_queue_stats ON inode;

-- Step 3: Create statement-level triggers on all inode partitions
DO $$
DECLARE
    partition_rec RECORD;
BEGIN
    FOR partition_rec IN
        SELECT c.relname as partition_name
        FROM pg_class c
        JOIN pg_inherits i ON i.inhrelid = c.oid
        JOIN pg_class parent ON parent.oid = i.inhparent
        WHERE parent.relname = 'inode'
        AND c.relispartition
    LOOP
        -- Create INSERT trigger
        EXECUTE format(
            'CREATE TRIGGER trigger_queue_stats_insert
             AFTER INSERT ON %I
             REFERENCING NEW TABLE AS new_rows
             FOR EACH STATEMENT
             EXECUTE FUNCTION update_queue_stats_batch();',
            partition_rec.partition_name
        );

        -- Create UPDATE trigger
        EXECUTE format(
            'CREATE TRIGGER trigger_queue_stats_update
             AFTER UPDATE ON %I
             REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
             FOR EACH STATEMENT
             EXECUTE FUNCTION update_queue_stats_batch();',
            partition_rec.partition_name
        );

        -- Create DELETE trigger
        EXECUTE format(
            'CREATE TRIGGER trigger_queue_stats_delete
             AFTER DELETE ON %I
             REFERENCING OLD TABLE AS old_rows
             FOR EACH STATEMENT
             EXECUTE FUNCTION update_queue_stats_batch();',
            partition_rec.partition_name
        );

        RAISE NOTICE 'Created statement-level triggers on %', partition_rec.partition_name;
    END LOOP;
END $$;

-- Step 4: Verify triggers were created
SELECT
    c.relname as table_name,
    t.tgname as trigger_name,
    CASE
        WHEN t.tgtype::int & 1 = 1 THEN 'ROW'
        ELSE 'STATEMENT'
    END as level,
    CASE
        WHEN t.tgtype::int & 2 = 2 THEN 'BEFORE'
        WHEN t.tgtype::int & 4 = 4 THEN 'AFTER'
    END as timing,
    CASE
        WHEN t.tgtype::int & 4 = 4 THEN 'INSERT'
        WHEN t.tgtype::int & 8 = 8 THEN 'DELETE'
        WHEN t.tgtype::int & 16 = 16 THEN 'UPDATE'
    END as operation
FROM pg_trigger t
JOIN pg_class c ON t.tgrelid = c.oid
WHERE c.relname LIKE 'inode_p_%'
AND t.tgname LIKE 'trigger_queue_stats%'
AND NOT t.tgisinternal
ORDER BY c.relname, t.tgname;
