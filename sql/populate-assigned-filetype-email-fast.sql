-- Author: PB and Claude
-- Date: 2025-12-03
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ---
-- ntt/sql/populate-assigned-filetype-email-fast.sql
--
-- Fast version using temp tables instead of correlated subqueries.
-- Extension matching still requires seq scan on paths, but avoids
-- repeated lookups per blob.

BEGIN;

-- Track progress
DO $$
DECLARE
  total_marked INTEGER := 0;
  batch_count INTEGER;
BEGIN
  RAISE NOTICE 'Starting email blob categorization (fast version)...';

  -- 1. Mark blobs with email MIME types (uses blobs index, fast)
  RAISE NOTICE 'Marking blobs by MIME type...';
  UPDATE blobs SET assigned_filetype = 1
  WHERE mime_type IN (
    'message/rfc822',
    'application/mbox',
    'message/news',
    'application/x-ms-dbx',
    'application/vnd.ms-tnef',
    'application/vnd.ms-outlook'
  )
  AND assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % blobs by MIME type', batch_count;

  -- 2. Mark maildir format files (uses GIN index via && operator)
  RAISE NOTICE 'Marking maildir format files (GIN-accelerated)...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.path_parts && ARRAY['cur', 'new', 'tmp']::text[]
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % maildir blobs', batch_count;

  -- 3. Batch process file extensions via temp tables
  -- This does ONE scan of paths for each extension pattern

  -- .eml files
  RAISE NOTICE 'Marking .eml files...';
  CREATE TEMP TABLE tmp_eml_blobs AS
  SELECT DISTINCT p.blobid
  FROM paths p
  JOIN blobs b ON b.blobid = p.blobid
  WHERE b.assigned_filetype IS NULL
    AND p.blobid IS NOT NULL
    AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%.eml';

  UPDATE blobs b SET assigned_filetype = 1
  FROM tmp_eml_blobs t
  WHERE b.blobid = t.blobid;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .eml blobs', batch_count;
  DROP TABLE tmp_eml_blobs;

  -- .emlx files (Apple Mail)
  RAISE NOTICE 'Marking .emlx files...';
  CREATE TEMP TABLE tmp_emlx_blobs AS
  SELECT DISTINCT p.blobid
  FROM paths p
  JOIN blobs b ON b.blobid = p.blobid
  WHERE b.assigned_filetype IS NULL
    AND p.blobid IS NOT NULL
    AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%.emlx';

  UPDATE blobs b SET assigned_filetype = 1
  FROM tmp_emlx_blobs t
  WHERE b.blobid = t.blobid;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .emlx blobs', batch_count;
  DROP TABLE tmp_emlx_blobs;

  -- .mbox files
  RAISE NOTICE 'Marking .mbox files...';
  CREATE TEMP TABLE tmp_mbox_blobs AS
  SELECT DISTINCT p.blobid
  FROM paths p
  JOIN blobs b ON b.blobid = p.blobid
  WHERE b.assigned_filetype IS NULL
    AND p.blobid IS NOT NULL
    AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%.mbox';

  UPDATE blobs b SET assigned_filetype = 1
  FROM tmp_mbox_blobs t
  WHERE b.blobid = t.blobid;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .mbox blobs', batch_count;
  DROP TABLE tmp_mbox_blobs;

  -- .mbx files (Eudora)
  RAISE NOTICE 'Marking .mbx files...';
  CREATE TEMP TABLE tmp_mbx_blobs AS
  SELECT DISTINCT p.blobid
  FROM paths p
  JOIN blobs b ON b.blobid = p.blobid
  WHERE b.assigned_filetype IS NULL
    AND p.blobid IS NOT NULL
    AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%.mbx';

  UPDATE blobs b SET assigned_filetype = 1
  FROM tmp_mbx_blobs t
  WHERE b.blobid = t.blobid;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .mbx blobs', batch_count;
  DROP TABLE tmp_mbx_blobs;

  -- .msg files (Outlook)
  RAISE NOTICE 'Marking .msg files...';
  CREATE TEMP TABLE tmp_msg_blobs AS
  SELECT DISTINCT p.blobid
  FROM paths p
  JOIN blobs b ON b.blobid = p.blobid
  WHERE b.assigned_filetype IS NULL
    AND p.blobid IS NOT NULL
    AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%.msg';

  UPDATE blobs b SET assigned_filetype = 1
  FROM tmp_msg_blobs t
  WHERE b.blobid = t.blobid;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .msg blobs', batch_count;
  DROP TABLE tmp_msg_blobs;

  -- .emlxpart files (Apple Mail attachments)
  RAISE NOTICE 'Marking .emlxpart files...';
  CREATE TEMP TABLE tmp_emlxpart_blobs AS
  SELECT DISTINCT p.blobid
  FROM paths p
  JOIN blobs b ON b.blobid = p.blobid
  WHERE b.assigned_filetype IS NULL
    AND p.blobid IS NOT NULL
    AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%.emlxpart';

  UPDATE blobs b SET assigned_filetype = 1
  FROM tmp_emlxpart_blobs t
  WHERE b.blobid = t.blobid;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .emlxpart blobs', batch_count;
  DROP TABLE tmp_emlxpart_blobs;

  -- Summary
  RAISE NOTICE '';
  RAISE NOTICE 'Email blob categorization complete!';
  RAISE NOTICE 'Total blobs marked with assigned_filetype=1: %', total_marked;
END $$;

-- Verify results
SELECT
  assigned_filetype,
  COUNT(*) as blob_count,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) as percentage
FROM blobs
GROUP BY assigned_filetype
ORDER BY assigned_filetype NULLS LAST;

COMMIT;
