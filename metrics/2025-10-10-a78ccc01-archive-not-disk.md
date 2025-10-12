<!--
Author: PB and Claude
Date: Thu 10 Oct 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/metrics/2025-10-10-a78ccc01-archive-not-disk.md
-->

# Medium a78ccc01 - Archive Misidentified as Disk Image

**Medium**: a78ccc01a5019a08651d6db3faf82abc
**Label**: Unknown
**Issue**: .img file is actually a tar.bz2 archive, not a disk image

## Discovery

The .img file (386MB) failed to mount. Investigation revealed:

```bash
$ file -s /data/fast/img/a78ccc01a5019a08651d6db3faf82abc.img
bzip2 compressed data, block size = 900k

$ bzcat /data/fast/img/a78ccc01a5019a08651d6db3faf82abc.img | head -c 512 | xxd | head -20
00000000: 7573 7461 7200 3030 3030 3030 3030 3030  ustar.0000000000
...
```

First sector shows tar archive with "ustar" header containing path `home/pball/Maildir/`

## Root Cause

This is NOT a disk image - it's a **tar.bz2 archive** that was incorrectly stored with .img extension.

## Processing Approach

Since this is a bespoke case, used manual extraction workflow:

1. Renamed .img to .tar.bz2 for clarity
2. Extracted to `/data/fast/img/tar/extract-a78ccc01a5019a08651d6db3faf82abc/`
3. Enumerated extracted files with ntt-enum
4. **Critical path issue**: ntt-enum recorded absolute paths like:
   - `/data/fast/img/tar/extract-a78ccc01a5019a08651d6db3faf82abc/home/pball/Maildir/...`
5. Copier expected relative paths, causing double-prefixing error:
   - `/mnt/ntt/a78ccc01/data/fast/img/tar/extract-a78ccc01/home/pball/Maildir/...` (WRONG)
6. Fixed with SQL UPDATE to strip extraction directory prefix:
   ```sql
   UPDATE path_p_a78ccc01
   SET path = convert_to(
     regexp_replace(
       convert_from(path, 'UTF8'),
       '^/data/fast/img/tar/extract-a78ccc01a5019a08651d6db3faf82abc',
       ''
     ),
     'UTF8'
   )
   WHERE convert_from(path, 'UTF8') LIKE '/data/fast/img/tar/extract-%';
   ```
7. Created bind mount: `/mnt/ntt/a78ccc01` → `/data/fast/img/tar/extract-a78ccc01/`
8. Running ntt-copier.py on corrected paths

## Files Recovered

- **Enumerated**: 49,129 records
- **Loaded**: 49,129 paths
- **Excluded**: 460 paths (ignore patterns)
- **Non-files**: 400 inodes (directories, symlinks)
- **Copying**: In progress

## Archive Contents

Maildir format email archive from `/home/pball/Maildir/` with subdirectories:
- INBOX/In-Archives/ (dated subfolders In-2000, etc.)
- Multiple mailbox folders

## ntt-mount-helper Enhancement

**Detection phase**: Add `file -s` check to detect non-disk formats:
- If bzip2/gzip/tar detected → flag as archive, not disk image
- Requires bespoke handling (not standard mount workflow)

## Database Updates

Need to update medium.problems with:
```json
{
  "issue_type": "archive_not_disk",
  "file_type": "tar.bz2",
  "contents": "Maildir email archive",
  "comment": "File misidentified as disk image; actually tar.bz2 archive of home/pball/Maildir/"
}
```

## Lessons Learned

1. **Path handling**: ntt-enum on extracted directories creates absolute paths; need relative paths for copier
2. **File detection**: Should validate disk image format before assuming .img extension means disk image
3. **Archive handling**: tar.bz2 archives need extraction workflow, not mount workflow
4. **Path correction**: Can fix path prefixes with SQL regex update when needed
