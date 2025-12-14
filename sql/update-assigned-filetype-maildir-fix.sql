-- Author: PB and Claude
-- Date: 2025-11-24
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ---
-- ntt/sql/update-assigned-filetype-maildir-fix.sql

-- FIX: Mark Maildir files WITHOUT :2, suffix as emails
-- The original populate script only marked files WITH :2, suffix
-- But Maildir files in 'new' directory often don't have this suffix yet
-- They only get it when moved to 'cur' directory

BEGIN;

DO $$
DECLARE
  total_marked INTEGER := 0;
BEGIN
  RAISE NOTICE 'Fixing Maildir email detection...';
  RAISE NOTICE 'Marking Maildir files without :2, suffix...';

  -- Mark all files in cur/new/tmp directories as emails
  -- even if they don't have the :2, suffix
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.path_parts && ARRAY['cur', 'new', 'tmp']::text[]
    -- Exclude obvious non-email files by extension
    AND p.path_parts[array_length(p.path_parts, 1)] NOT LIKE '%.png'
    AND p.path_parts[array_length(p.path_parts, 1)] NOT LIKE '%.jpg'
    AND p.path_parts[array_length(p.path_parts, 1)] NOT LIKE '%.jpeg'
    AND p.path_parts[array_length(p.path_parts, 1)] NOT LIKE '%.gif'
    AND p.path_parts[array_length(p.path_parts, 1)] NOT LIKE '%.bmp'
    AND p.path_parts[array_length(p.path_parts, 1)] NOT LIKE '%.pdf'
    AND p.path_parts[array_length(p.path_parts, 1)] NOT LIKE '%.zip'
    AND p.path_parts[array_length(p.path_parts, 1)] NOT LIKE '%.gz'
    AND p.path_parts[array_length(p.path_parts, 1)] NOT LIKE '%.tar'
    AND p.path_parts[array_length(p.path_parts, 1)] NOT LIKE '%.bz2'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS total_marked = ROW_COUNT;
  RAISE NOTICE '  Marked % additional Maildir blobs', total_marked;
  RAISE NOTICE '';
  RAISE NOTICE 'Maildir fix complete!';
END $$;

-- Verify results
SELECT
  'Maildir WITH :2, suffix' as category,
  COUNT(DISTINCT b.blobid) as count
FROM blobs b
JOIN paths p ON p.blobid = b.blobid
WHERE p.path_parts && ARRAY['cur', 'new', 'tmp']::text[]
  AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%:2,%'
  AND b.assigned_filetype = 1

UNION ALL

SELECT
  'Maildir WITHOUT :2, suffix (NOW marked)' as category,
  COUNT(DISTINCT b.blobid) as count
FROM blobs b
JOIN paths p ON p.blobid = b.blobid
WHERE p.path_parts && ARRAY['cur', 'new', 'tmp']::text[]
  AND p.path_parts[array_length(p.path_parts, 1)] NOT LIKE '%:2,%'
  AND b.assigned_filetype = 1

UNION ALL

SELECT
  'Total emails with assigned_filetype=1' as category,
  COUNT(*) as count
FROM blobs
WHERE assigned_filetype = 1;

COMMIT;
