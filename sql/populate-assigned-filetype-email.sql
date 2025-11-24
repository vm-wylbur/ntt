-- Author: PB and Claude
-- Date: 2025-11-22
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ---
-- ntt/sql/populate-assigned-filetype-email.sql

-- Mark all email-related blobs with assigned_filetype=1
-- Uses both MIME type detection and path-based file extension analysis

-- Strategy:
-- 1. Update blobs with email MIME types (fastest)
-- 2. Update blobs with email file extensions in paths table
-- 3. Update blobs in email-related directories (maildir, Eudora)

BEGIN;

-- Track progress
DO $$
DECLARE
  total_marked INTEGER := 0;
  batch_count INTEGER;
BEGIN
  RAISE NOTICE 'Starting email blob categorization...';

  -- 1. Mark blobs with email MIME types
  RAISE NOTICE 'Marking blobs by MIME type...';
  UPDATE blobs SET assigned_filetype = 1
  WHERE mime_type IN (
    'message/rfc822',           -- Standard email format
    'application/mbox',         -- Unix mbox format
    'message/news',             -- USENET messages
    'application/x-ms-dbx',     -- Outlook Express
    'application/vnd.ms-tnef',  -- winmail.dat
    'application/vnd.ms-outlook' -- Outlook .msg
  )
  AND assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % blobs by MIME type', batch_count;

  -- 2. Mark blobs with .eml extension
  RAISE NOTICE 'Marking .eml files...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%.eml'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .eml blobs', batch_count;

  -- 3. Mark blobs with .emlx extension (Apple Mail)
  RAISE NOTICE 'Marking .emlx files (Apple Mail)...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%.emlx'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .emlx blobs', batch_count;

  -- 4. Mark blobs with .mbox extension
  RAISE NOTICE 'Marking .mbox files...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%.mbox'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .mbox blobs', batch_count;

  -- 5. Mark blobs with .mbx extension (Eudora/Outlook Express)
  RAISE NOTICE 'Marking .mbx files (Eudora)...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%.mbx'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .mbx blobs', batch_count;

  -- 6. Mark blobs with .msg extension (Outlook)
  RAISE NOTICE 'Marking .msg files (Outlook)...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%.msg'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .msg blobs', batch_count;

  -- 7. Mark maildir format files (ALL files in cur/new/tmp dirs, not just :2, suffix)
  -- Fixed 2025-11-24: Original only caught files WITH :2, suffix, missing 101K emails in new/ directory
  RAISE NOTICE 'Marking maildir format files...';
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

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % maildir blobs', batch_count;

  -- 8. Mark Apple Mail .emlxpart files (attachments)
  RAISE NOTICE 'Marking .emlxpart files (Apple Mail attachments)...';
  UPDATE blobs b SET assigned_filetype = 1
  WHERE EXISTS (
    SELECT 1 FROM paths p
    WHERE p.blobid = b.blobid
    AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%.emlxpart'
  )
  AND b.assigned_filetype IS NULL;

  GET DIAGNOSTICS batch_count = ROW_COUNT;
  total_marked := total_marked + batch_count;
  RAISE NOTICE '  Marked % .emlxpart blobs', batch_count;

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
