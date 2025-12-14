-- Author: PB and Claude
-- Date: 2025-11-22
-- License: (c) HRDAG, 2025, GPL-2 or newer
--
-- ---
-- ntt/sql/populate-elasticsearch-exclusions.sql

-- Populate Elasticsearch exclusion metadata in blobs table
-- Run after: sql/add-elasticsearch-exclusion-fields.sql

\timing on

-- ===================================================================
-- 1. Mark archive files (from paths.mime_type)
-- ===================================================================
\echo ''
\echo '1. Marking archive files...'

UPDATE blobs SET
  exclude_from_index = true,
  exclusion_reason = 'archive'
WHERE EXISTS (
  SELECT 1 FROM paths p
  WHERE p.blobid = blobs.blobid
  AND p.mime_type IN (
    -- Compression formats
    'application/gzip',
    'application/x-bzip2',
    'application/x-xz',
    'application/x-compress',
    'application/x-lzip',
    -- Archive formats
    'application/x-tar',
    'application/zip',
    'application/x-archive',
    'application/vnd.rar',
    'application/vnd.ms-cab-compressed',
    'application/x-7z-compressed',
    -- Compound formats
    'application/x-gzip',
    'application/x-bzip',
    'application/x-lzma'
  )
);

-- ===================================================================
-- 2. Mark zero-byte files
-- ===================================================================
\echo ''
\echo '2. Marking zero-byte files...'

UPDATE blobs SET
  exclude_from_index = true,
  exclusion_reason = 'zero_byte'
WHERE size = 0;

-- ===================================================================
-- 3. Mark orphaned blobs (from /tmp/missing_blobids.log)
-- ===================================================================
\echo ''
\echo '3. Marking orphaned blobs...'

UPDATE blobs SET
  exclude_from_index = true,
  exclusion_reason = 'orphaned'
WHERE blobid IN (
  '02ef6a55a3558a2b7bee5280db965cf8cd4b12cb017a6c07278569ae4c4e8a8f',
  '05072d5e49b0ca165886513ab022508e05bc2d7cb8873272cd757b41a3362ea2',
  '05758e3e55f85616ff79e6f2bb08292d6f741d850ba149ea860f2cc031175f03',
  '0b18cd045a7188fd937372b008414a84291622625b3e490b694eb5870da26a01',
  '16ab11f0f91b934950d5c2a6a643288521ff10d56d03fce6df5a556a31d94d4f',
  '2983c8aab7100e382925e8c6521d21af5a00e1997a62838f025a4dde47a8f798',
  '2a6d5c801eebcd4c6b079226e4e23283c1168473e8f96863587f114f4d590cae',
  '2e554ccac080ccaff78b5576366b12d9b18aeca165df318f154b85a812cd1941',
  '2ebace1f8705cb326e844bfc956bbb12141f5cb1b7f23957d50f2bd264f05fdf',
  '2f8473d148c8ce76afba01d21f2b92eb644947b6bd04292495c5bd3bc9da6e6a',
  '3355c49e5bd975b0b7cad6a83bdfdd7cd0fea9aff8b565e7533b8142361f1be0',
  '341ade46ccb34f4d70d22abd0e2cbed0ae94a1899c14451494e3ce6b9f2c7289',
  '3ccb3a3db5057eaf15e242f37ec49fd664b71b59d81425dac2cdd0da40e7134c',
  '50102302b720b36ebf2ed6b9f59ede4a94e3e2820a9057a7a0e3b0c5ed1d83b8',
  '503d204c190af9ff8f945497b257aa608b7e42a71cd666609849026943d275bd',
  '50eb9fa1f1cdf1d8162cac3005a78b63a62058eda64bd964dcd498176aed7f17',
  '552095278cc23b73fab04975a856773d7d902388f85c3d7aadcf02a725a7e0a6',
  '572a9b98830fafcecb7f663d1d2a09a0441e8fb41b1ef38200b105c6ab7bf9e1',
  '6ad5c77cf6f6736d0cb360c92c1aaf81f4e2ef29766ba273753119b7c2f31eea',
  '717a1f33aec1939927b5f2f2184663c91be926fea226c638c912a8512ac814c2',
  '78c3d2663d5910eace7f55cd4a04ff4e24fea8fef1bfcae80f4951c3356e0904',
  '917e7dd17ff7b2af6111acd1be8eca48f7d8bbf43bdb1ce8f7f8b219f0eb85b6',
  '93db506fe48c418095fe72d0270d04bf75a8b4669dba3d224dfae17fd3981527',
  '9971bffbb71ec0a95bf3c0d1a28dfde721b5e3c78eec167d5e407884ff95673c',
  'a08debbd15afe6e16c43c21c5cce8cf60d87d17ff14695f870ff9a999d40ee15',
  'a0f33490079c0a8e685fdb6b68fd7bb5682c4f037c2ca4a9cada237ea1e40f25',
  'a72b94cd71b0940965f56e4dfee67d32a9ce74138f8854ea3c11f16dff715add',
  'b68cbccead5a61560cc66741a25f93507091886493284433a8dafae86c884f1e',
  'c3d8ada971d23e950d2e98f1864631085d24da86f945223c734a9b9ad8cdc87d',
  'd0efaaaf5589e90a454e9d143d4be9bef03e0499309b713bb2bf2cd08f5120b3',
  'f89a315106e2c52ad65515af626041696a93d7a7acc9afc9bab54c3352544801',
  'f8e6c9205f168f8a285eee2f509a403429556a50e1457aeccd56a6677726b7a7'
);

-- ===================================================================
-- 4. Mark ALL corrupted files (with clean alternative when available)
-- ===================================================================
\echo ''
\echo '4. Marking corrupted files...'

UPDATE blobs SET
  exclude_from_index = true,
  exclusion_reason = 'corrupted',
  clean_blobid_alternative = ca.other_blobid
FROM dd4918_corruption_analysis ca
WHERE blobs.blobid = ca.dd_blobid;

-- ===================================================================
-- 5. Mark system/OS metadata files
-- ===================================================================
\echo ''
\echo '5. Marking system metadata files...'

UPDATE blobs SET
  exclude_from_index = true,
  exclusion_reason = 'system_metadata'
WHERE EXISTS (
  SELECT 1 FROM paths p
  WHERE p.blobid = blobs.blobid
  AND (
    -- macOS metadata
    path_parts @> ARRAY['.DS_Store'] OR
    path_parts @> ARRAY['.AppleDouble'] OR
    path_parts @> ARRAY['.TemporaryItems'] OR
    path_parts @> ARRAY['.Trashes'] OR
    path_parts @> ARRAY['.fseventsd'] OR
    path_parts @> ARRAY['.Spotlight-V100'] OR
    path_parts @> ARRAY['._'] OR  -- AppleDouble resource fork files

    -- Windows metadata
    path_parts @> ARRAY['Thumbs.db'] OR
    path_parts @> ARRAY['desktop.ini'] OR
    path_parts @> ARRAY['$RECYCLE.BIN'] OR

    -- Version control metadata
    path_parts @> ARRAY['.git'] OR
    path_parts @> ARRAY['.svn', 'pristine'] OR
    path_parts @> ARRAY['.hg'] OR
    path_parts @> ARRAY['.bzr'] OR

    -- IDE/editor metadata
    path_parts @> ARRAY['.vscode'] OR
    path_parts @> ARRAY['.idea'] OR
    path_parts @> ARRAY['.eclipse'] OR
    path_parts @> ARRAY['__pycache__'] OR
    path_parts @> ARRAY['.pyc'] OR

    -- Build artifacts
    path_parts @> ARRAY['node_modules'] OR
    path_parts @> ARRAY['.npm'] OR
    path_parts @> ARRAY['.cache']
  )
);

-- ===================================================================
-- Summary report
-- ===================================================================
\echo ''
\echo '=== EXCLUSION SUMMARY ==='
SELECT
  exclusion_reason,
  COUNT(*) as blob_count,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) as pct_of_excluded,
  ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM blobs), 2) as pct_of_total_blobs
FROM blobs
WHERE exclude_from_index = true
GROUP BY exclusion_reason
ORDER BY blob_count DESC;

\echo ''
\echo 'Total blobs excluded from indexing:'
SELECT COUNT(*) FROM blobs WHERE exclude_from_index = true;

\echo ''
\echo 'Total blobs eligible for indexing:'
SELECT COUNT(*) FROM blobs WHERE exclude_from_index IS NULL OR exclude_from_index = false;

\echo ''
\echo '=== DONE ==='
