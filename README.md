# NTT – ingest & copy with hash-based dedupe

## Quick start
1. create DB
```
   createdb copyjob
   psql copyjob < bin/sql/00-schema.sql
```

3. set env (edit ~/.config/ntt/ntt.env)
```
   export NTT_DB_URL="postgres:///copyjob"
   export NTT_IMAGE_ROOT="/data/fast/img"
   export NTT_RAW_ROOT="/data/fast/raw"
   export NTT_DST_ROOT="/data/cold/dst"
   export NTT_LOG_JSON="/var/log/ntt/orchestrator.jsonl"
```
4. source it
```
   source ~/.config/ntt/ntt.env
```

5. run first disk
```
   sudo ./bin/ntt-orchestrator /dev/sdX
```

6. watch JSON
```
   jq -c . /var/log/ntt/orchestrator.jsonl
```

## Troubleshooting

### Slow HFS+ Enumeration (< 1000 files/s)

**CRITICAL**: If HFS+ enumeration is extremely slow with constant stalls, **STOP immediately** and run fsck.hfsplus to repair catalog corruption:

```bash
# Stop enumeration if slow
sudo umount /mnt/ntt/${HASH}

# Rebuild catalog from alternate copy
sudo fsck.hfsplus -r /data/fast/img/${HASH}.img

# Re-run enumeration
sudo ./bin/ntt-orchestrator --force --image /data/fast/img/${HASH}.img
```

**Why this matters**: Catalog corruption can hide 60-70% of accessible data. Without fsck repair, you'll lose access to files even though their data blocks are readable.

**Evidence**: 8e61cad2 recovered 43M paths (vs 7M before fsck) with 57x faster enumeration.

See: `docs/disk-read-checklist.md` section 4.1 and `docs/lessons/hfs-catalog-corruption-fsck-recovery-8e61cad2-2025-10-12.md`

### Ingesting PhotoRec Carved Files

**Use case**: PhotoRec recovered files from damaged disk, but no filesystem metadata (paths/timestamps/inodes). Need to ingest into NTT with synthetic metadata.

**Quick reference**:
```bash
# See script header for setup
bin/ntt-enum-carved --help

# Full workflow
docs/carved-ingestion-workflow.md
```

**Key concepts**:
- Organize carved files under `/data/cold/carved-sources/${SOURCE}/`
- Create symlink: `/mnt/ntt/${MEDIUM_HASH}` → physical location
- Database paths include source identifier for multi-source disambiguation
- Use `--src-root /mnt/ntt` consistently for copier

See: `bin/ntt-enum-carved` (script header) and `docs/carved-ingestion-workflow.md` (full workflow)

### Documentation

- **Full diagnostic guide**: `docs/disk-read-checklist.md`
- **Lessons learned**: `docs/lessons/`
- **Hash format spec**: `docs/hash-format.md`
- **Database columns**: `docs/medium-columns-guide.md`

<!-- done -->
