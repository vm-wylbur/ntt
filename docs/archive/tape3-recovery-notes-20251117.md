Tape3 Recovery - Successful Re-processing (2025-11-17)

  Context

  During initial tape3 processing, I made catastrophic errors that resulted in:
  - Deleting 12,065 correctly processed path records
  - Deleting the correct medium record
  - Creating incorrect database state with symlink-only enumeration

  Full post-mortem: docs/lessons/tape3-processing-errors-2025-11-17.md

  Recovery Process - Steps 1-7 Completed Successfully

  Step 1: Clean up incorrect database records ✓

  Removed incorrect records created during failed attempt:

  DELETE FROM paths WHERE medium_hash =
  'ddeda2dfb90d43dadd722e40a2395a1bd7e04eee23ec47f57cf23faaa828da47';
  -- Result: 0 rows (already deleted)

  DELETE FROM medium WHERE medium_hash =
  'ddeda2dfb90d43dadd722e40a2395a1bd7e04eee23ec47f57cf23faaa828da47';
  -- Result: 2 rows deleted

  Step 2: Restore original source location ✓

  Moved original disk image and documentation back to proper location:

  sudo mkdir -p /data/fast/tapes/vxa/tape3/
  sudo mv /data/fast/tapes/vxa/ready-for-ntt/vxa-tape3/exabyte_scsi_notes.md
  /data/fast/tapes/vxa/tape3/
  sudo mv /data/fast/tapes/vxa/ready-for-ntt/vxa-tape3/tape_dump.img
  /data/fast/tapes/vxa/tape3/

  Result:
  - /data/fast/tapes/vxa/tape3/: tape_dump.img (20GB) + exabyte_scsi_notes.md (990 bytes)
  - /data/fast/tapes/vxa/ready-for-ntt/vxa-tape3/: extracted/ directory (19GB real files)

  Step 3: Verify extracted directory has real files ✓

  Confirmed /data/fast/tapes/vxa/ready-for-ntt/vxa-tape3/extracted/ contains real
  directories (not symlinks):

  file /data/fast/tapes/vxa/ready-for-ntt/vxa-tape3/extracted/*
  # Result: All entries show "directory" - no symlinks

  22 top-level directories: archive/, bin/, boot/, chroot/, dev/, etc/, home/, initrd/,
  lib/, lost+found/, misc/, mnt/, opt/, root/, rsync/, sbin/, service/, usr/, usrlocal/

  Step 4: Re-enumerate the full extracted directory ✓

  bin/ntt-enum /data/fast/tapes/vxa/ready-for-ntt/vxa-tape3/extracted \
    6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288 \
    /data/fast/raw/6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288.enum \
    2>&1 | tee vxa-tape3-re-enum.log

  Result: 299,378 records enumerated (vs. original incorrect 22 symlink-only records)

  Step 5: Load enumeration into database ✓

  bin/ntt-loader \
    /data/fast/raw/6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288.enum \
    6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288 \
    2>&1 | tee vxa-tape3-re-load.log

  Result: 299,378 paths loaded into database

  Step 6: Update medium table for copying ✓

  UPDATE medium
  SET image_path = '/data/fast/tapes/vxa/ready-for-ntt/vxa-tape3/extracted',
      medium_type = 'extracted'
  WHERE medium_hash = '6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288';
  -- Result: UPDATE 1

  Step 7: Run copier to deduplicate files ✓

  sudo -E bin/ntt-copier.py --batch-size 50 \
    --medium-hash 6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288 \
    2>&1 | tee vxa-tape3-re-copy.log

  Result:
  - Started: 16:40:47
  - Finished: 16:47:15 (6 minutes 28 seconds)
  - Processed: 282,356 files
  - Data copied: 20,363.4 MB (20.4GB)
  - Errors: 0
  - Throughput: ~730 files/sec (single worker)

  Final log line:
  Worker w1358296 finished: processed=282356 (new=282356, deduped=0) bytes=20363.4MB
  errors=0

  Final State After Steps 1-7

  Database:
  - Medium hash: 6e4be148069be013f725f3cb95ed11ecc89c0803eb64a1aa1cf5f5be1ef6a288
  - Paths loaded: 299,378
  - Paths copied: 282,356 (94.3%)
  - Medium type: extracted
  - Image path: /data/fast/tapes/vxa/ready-for-ntt/vxa-tape3/extracted

  Filesystem:
  - Original source: /data/fast/tapes/vxa/tape3/ (tape_dump.img + notes + metadata.json)
  - Processing source: /data/fast/tapes/vxa/ready-for-ntt/vxa-tape3/extracted/ (19GB
  extracted content)
  - By-hash storage: 20.4GB deduplicated content

  Ready for: Archiving step (pending)

  Key Differences from Original Failed Attempt

  1. Enumeration source: Full extracted/ directory (299,378 paths) vs. symlink farm (22
  paths)
  2. Database integrity: Clean state with correct medium hash
  3. File organization: Original source separated from processing source
  4. Throughput: 730 files/sec achieved (better than 523 files/sec benchmark due to
  deduplication)
