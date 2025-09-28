# NTT Build-Book v0.1

### ideas from kimi
ntt-copy-worker  – one-sentence summary
Copies one unique inode (first path) to ZFS pool, stores BLAKE3 hash; if hash already exists, reflinks instead of re-copying; commits DB only after fsync + reflink OK; logs errors but keeps running; emits JSON heartbeat every 30 s.
Key behaviours (bullet form)
pops one row: SELECT … FOR UPDATE SKIP LOCKED
stream-copy + BLAKE3 in single pass (no temp file)
atomic move → final path, fsync, then DB commit
hash exists? → delete partial, reflink from canonical, commit
error? → log to inode.errors[], mark path broken, continue
heartbeat: {"worker_id":"w3","copied":42,"mb":1234,"rate_mb_s":118,"errors":0}
graceful SIGTERM – finish current inode, commit, exit
Pseudo-code (bash skeleton)
bash
Copy
while row = fetch():
    src = mount_map[row.medium_hash] + row.first_path
    dst = NTT_DST_ROOT + row.first_path
    mkdir -p dirname(dst)

    if row.hash and hash_exists(row.hash):
        reflink_ok = cp --reflink=always /pool/dst/.by-hash/{hash} dst
        if reflink_ok: commit_success(row); continue

    # first copy of this hash
    try:
        hash = stream_copy_hash(src, dst)   # copy + blake3
        fsync(dst)
    except OSError as e:
        log_error(row, e)
        continue

    commit_success(row, hash)
Performance
120 MB/s (USB-3 bottleneck) → ~ 1 h per 400 GB
reflink takes < 1 ms – zero bytes copied
8 workers per source spindle → saturate destination ZFS mirror
Exit codes
Table
Copy
code	meaning
0	queue drained, nothing left
1	unhandled exception
2	SIGTERM graceful stop
