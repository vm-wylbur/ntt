<!--
Author: PB and Claude
Date: Wed 6 Nov 2025
License: (c) HRDAG, 2025, GPL-2 or newer

------
ntt/docs/phase5-pilot-report.md
-->

# Phase 5 Pilot Report: Real Data Extraction

**Start Date:** 2025-11-06
**Status:** In Progress
**Approach:** Manual testing of individual blobs before automated pilot

---

## Methodology

Instead of immediately processing 1000 blobs, we're testing individual real archives manually to:
- Understand actual data characteristics
- Find edge cases early
- Validate extraction quality manually
- Document issues as we find them

Each blob tested gets a detailed case study below.

---

## Case Study 1: tools.tar.gz

**Date:** 2025-11-06 09:40
**Blob ID:** `f756b91e07393f2b05dc332a9c1cf8cc10ca051f91d85cfaecd13b968d809fc6`

### Selection Criteria

- Smallest .tar.gz in database (2.1 KB)
- From physical medium: `4b871132e06f8337`
- Original path: `/mnt/ntt/4b871132e06f83375c42fd7f8e5cd437/p10/archives/archives.mina/archives/CDs/done/CD_files_2000-2002/Data-2001/pytools/archive/tools.tar.gz`
- Last modified: Fri Sep 28 04:53:44 2001

### File Characteristics

```bash
$ file <by-hash-path>
gzip compressed data, was "tools.tar", last modified: Fri Sep 28 04:53:44 2001,
from Unix, original size modulo 2^32 10240

$ ls -lh <by-hash-path>
-r--r--r-- 1 pball pball 2.1K May  7  2002
```

**Notes:**
- File is 23 years old (from 2001-2002 CD archive)
- Original tar was 10KB uncompressed
- Good test case for nested extraction (gzip → tar → files)

### Extraction Test

**Setup:**
```bash
# Queue single blob for extraction
redis-cli del "ntt:extraction:processed"
redis-cli zadd "ntt:extraction:priority" 2048 \
  '{"blobid": "f756b91e07393f2b05dc332a9c1cf8cc10ca051f91d85cfaecd13b968d809fc6",
    "mime_type": "application/gzip"}'
```

**Execution:**
```bash
./bin/ntt-extractor.py run --max-jobs 2 2>&1 | tee /tmp/pilot-case1.log
```

### Results

**Extraction Status:**
- [x] Gzip decompression successful
- [x] Tar extraction successful
- [x] Files stored in by-hash
- [x] Database records created
- [x] Manual verification passed

**Extraction Chain:**

1. **Gzip decompression** (medium: `2b24dfb918a85022`)
   - Decompressed blobid: `3f6a71444528e6dc1d83ae02e9f9fe2c1a0648deb47269bd39747f49159ca395`
   - Result: 1 file (tools.tar, ~10KB)
   - Automatically detected as nested archive and queued

2. **Tar extraction** (medium: `efd4324717096583`)
   - Source: decompressed tar from step 1
   - Result: 4 files extracted

**Files Extracted:**

| Path | Size | MIME Type |
|------|------|-----------|
| `/tools/__init__.py` | 0 bytes | application/x-empty |
| `/tools/csv2dict.py` | 2,115 bytes | text/x-script.python |
| `/tools/delimited.py` | 1,882 bytes | text/x-script.python |
| `/tools/walktree.py` | 891 bytes | text/plain |

**Total:** 4 files, 4,888 bytes of Python code

### Manual Verification

**Verified walktree.py content:**
```python
def walktree(object):
    #number of items of name_of_attr
    #total size of items
    #type of item

    data_members = [item for item in dir(object)
                    if not callable(getattr(object,item))]
    ...
```

**Observations:**
- Code is authentic Python 2 from 2001 (print statements without parentheses)
- All files successfully stored in by-hash
- Paths correctly preserved (/tools/ directory structure)
- MIME types accurate (python scripts detected)
- Empty `__init__.py` correctly identified

**Issues Found:** None

**Success:** ✅ Complete end-to-end extraction with nested archive processing

---

## Summary Statistics

**Total Blobs Tested:** 1
**Successful:** 1 (100%)
**Failed:** 0
**Nested Archives Processed:** 1 (gzip→tar)
**Files Extracted:** 4

---

## Issues Discovered

[Will be populated as we test]

---

## Next Steps

1. Complete Case Study 1 (tools.tar.gz)
2. Select next test case (different format or size)
3. Continue manual testing until confident
4. Then proceed with automated pilot
