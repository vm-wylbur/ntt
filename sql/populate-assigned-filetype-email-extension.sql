-- Author: PB and Claude
-- Date: 2025-12-03
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ---
-- ntt/sql/populate-assigned-filetype-email-extension.sql
--
-- Ultra-fast version using the new extension column with btree index.
-- Replaces slow LIKE queries on path_parts with indexed lookups.

BEGIN;

-- Track progress
DO $$
DECLARE
  total_marked INTEGER := 0;
  batch_count INTEGER;
BEGIN
  RAISE NOTICE 'Starting email blob categorization (extension-indexed version)...';

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

  -- 3. Mark by file extension using btree index (FAST!)
  -- All extension lookups use idx_paths_extension

  -- .eml files
  RAISE NOTICE 'Marking .eml files...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.extension = '.eml'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .eml blobs', batch_count;

  -- .emlx files (Apple Mail)
  RAISE NOTICE 'Marking .emlx files...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.extension = '.emlx'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .emlx blobs', batch_count;

  -- .mbox files
  RAISE NOTICE 'Marking .mbox files...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.extension = '.mbox'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .mbox blobs', batch_count;

  -- .mbx files (Eudora)
  RAISE NOTICE 'Marking .mbx files...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.extension = '.mbx'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .mbx blobs', batch_count;

  -- .msg files (Outlook)
  RAISE NOTICE 'Marking .msg files...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.extension = '.msg'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .msg blobs', batch_count;

  -- .emlxpart files (Apple Mail attachments)
  RAISE NOTICE 'Marking .emlxpart files...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.extension = '.emlxpart'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .emlxpart blobs', batch_count;

  -- .pst files (Outlook Personal Folders)
  RAISE NOTICE 'Marking .pst files...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.extension = '.pst'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .pst blobs', batch_count;

  -- .dbx files (Outlook Express)
  RAISE NOTICE 'Marking .dbx files...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.extension = '.dbx'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .dbx blobs', batch_count;

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
