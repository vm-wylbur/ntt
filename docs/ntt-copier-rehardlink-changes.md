# Changes Required for ntt-copier --re-hardlink Mode

## Summary
Add `--re-hardlink` mode to efficiently recreate missing hardlinks without re-reading file content.

## Command Line Changes

Add to ntt-copier.py main():
```python
@click.option('--re-hardlink', is_flag=True, 
              help='Re-create missing hardlinks for existing by-hash files')
def main(workers, dry_run, re_hardlink):
    if re_hardlink:
        # Special mode - process all blobs that need hardlinks
        run_re_hardlink_mode(dry_run)
    else:
        # Normal copy mode
        run_normal_mode(workers, dry_run)
```

## Database Schema (Already Created)

```sql
-- In inode table
ALTER TABLE inode 
  ADD COLUMN by_hash_created BOOLEAN DEFAULT FALSE;

-- In blobs table  
ALTER TABLE blobs
  ADD COLUMN n_hardlinks INTEGER DEFAULT 0;
```

## Key Implementation Points

### 1. Normal Mode Changes

Update the FileProcessor in ntt-copier-processors.py:

- When creating by-hash file: Set `by_hash_created = true`
- After creating hardlinks: Update `n_hardlinks` count in blobs table (batch update)
- Track all paths for each hash to ensure complete hardlinking

### 2. Re-hardlink Mode

New function for re-hardlink mode:
```python
def run_re_hardlink_mode(dry_run):
    """Process all blobs and create missing hardlinks."""
    
    # Query blobs that may need hardlinks
    blobs = query_all_blobs()
    
    for blob in blobs:
        # Check if by-hash exists
        by_hash_path = construct_by_hash_path(blob)
        if not by_hash_path.exists():
            logger.error(f"By-hash missing for {blob}")
            continue
        
        # Get all expected paths
        paths = get_paths_for_blob(blob)
        
        # Create missing hardlinks
        for path in paths:
            archive_path = construct_archive_path(path)
            if not archive_path.exists():
                create_hardlink(by_hash_path, archive_path)
                increment_n_hardlinks(blob)
```

### 3. Batch Updates for n_hardlinks

Instead of updating after each hardlink:
```python
# Collect all hardlinks created for a blob
hardlinks_created = []
for path in paths:
    if create_hardlink(...):
        hardlinks_created.append(path)

# Single update for the blob
if hardlinks_created:
    UPDATE blobs SET n_hardlinks = n_hardlinks + %s 
    WHERE blobid = %s
```

## Testing Steps

1. Apply schema changes:
```bash
sudo -u postgres psql -d copyjob < /home/pball/projects/ntt/sql/add_hardlink_tracking.sql
```

2. Count existing hardlinks:
```bash
sudo /home/pball/projects/ntt/bin/ntt-count-hardlinks.py --limit 100 --dry-run
```

3. Run re-hardlink mode:
```bash
sudo /home/pball/projects/ntt/bin/ntt-copier.py --re-hardlink --dry-run
```

4. Verify with ntt-verify:
```bash
sudo /home/pball/projects/ntt/bin/ntt-verify.py --count 100 --mode never
```

## Benefits

- **Efficient**: No re-reading of file content
- **Safe**: Idempotent - can run multiple times
- **Trackable**: n_hardlinks shows progress
- **Verifiable**: ntt-verify confirms correctness