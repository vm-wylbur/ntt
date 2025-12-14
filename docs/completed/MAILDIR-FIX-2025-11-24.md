<!--
Author: PB and Claude
Date: 2025-11-24
License: (c) HRDAG, 2025, GPL-2 or newer

---
ntt/MAILDIR-FIX-2025-11-24.md
-->

# Maildir Email Detection Fix - 2025-11-24

## Summary

Fixed critical bug in `assigned_filetype` email detection that missed 101,558 Maildir emails without the `:2,` suffix flag.

## Problem

The original SQL at `sql/populate-assigned-filetype-email.sql:113-126` only marked Maildir files that had the `:2,` suffix:

```sql
-- BUGGY: Only marks files WITH :2, suffix
UPDATE blobs b SET assigned_filetype = 1
WHERE EXISTS (
  SELECT 1 FROM paths p
  WHERE p.blobid = b.blobid
  AND p.path_parts && ARRAY['cur', 'new', 'tmp']::text[]
  AND p.path_parts[array_length(p.path_parts, 1)] LIKE '%:2,%'  -- BUG HERE
)
```

**Why this is wrong:** Maildir files in the `new` directory don't have the `:2,` suffix yet. They only get it when moved to the `cur` directory after being read. This caused us to miss 134,486 valid Maildir emails.

## Maildir Format Background

Maildir structure:
- `new/` - Unread messages (NO `:2,` suffix)
- `cur/` - Read messages (WITH `:2,` suffix like `:2,S` for Seen)
- `tmp/` - Temporary files during delivery

Files move from `new/` → `cur/` and gain the `:2,` suffix with flags at that point.

## Investigation Results

**Before fix:**
```
Maildir WITH :2, suffix:     227,519 (marked)
Maildir WITHOUT :2, suffix:  134,486 (NOT marked)
  - Of which 32,171 were text/plain mime type
```

**After fix:**
```
Total emails: 1,272,656 (was 1,171,098, +101,558)

Maildir breakdown:
  WITH :2, suffix:    227,519
  WITHOUT :2, suffix: 268,820
  Total Maildir:      496,339
```

## Fix Applied

Created `/home/pball/projects/ntt/sql/update-assigned-filetype-maildir-fix.sql`:

```sql
-- Mark ALL files in cur/new/tmp directories as emails
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
```

**Result:** Marked 101,558 additional Maildir blobs successfully.

## Verification

After the fix, only 17 files remain unmarked in cur/new/tmp directories:
- All are the same `scikit-learn-logo.bmp` image file (mime_type = 'image/bmp')
- Located in `/tmp/scikit-learn/` build directories (NOT Maildir tmp)
- Correctly excluded as non-email files

## Lessons Learned

1. **MIME types are unreliable for Maildir:** Many Maildir files are detected as `text/plain` rather than `message/rfc822`

2. **Directory structure matters more than file naming:** For Maildir, presence in `cur/new/tmp` directories is the key indicator, not the `:2,` suffix

3. **Extension-based exclusion is necessary:** Maildir directories can contain non-email files (images, PDFs, archives). Must explicitly exclude by extension.

4. **Test with directory edge cases:** The `tmp` directory can exist in both Maildir contexts AND build/temp contexts. Need to distinguish.

## Next Steps

1. **Queue all 1.27M emails for Elasticsearch indexing** using `WHERE assigned_filetype = 1` instead of restrictive MIME type filters

2. **Process mbox container files:** Still have 5,769 .mbox files (769 GB) containing potentially millions of individual emails

3. **Update populate-assigned-filetype-email.sql:** Should incorporate this fix for future re-runs

## References

- Fix SQL: `sql/update-assigned-filetype-maildir-fix.sql`
- Original SQL: `sql/populate-assigned-filetype-email.sql:113-126`
- Elasticsearch client: `ntt-es/src/ntt_es/es_client.py` (Message-ID deduplication already working)
