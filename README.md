# NTT – ingest & copy with hash-based dedupe

## Quick start
1. create DB
```
   createdb copyjob
   psql copyjob < bin/sql/00-schema.sql
```

3. set env (edit ~/.config/ntt/ntt.env)
   `export NTT_DB_URL="postgres:///copyjob"`
   `export NTT_IMAGE_ROOT="/data/fast/images"`
   `export NTT_RAW_ROOT="/data/fast/raw"`
   `export NTT_DST_ROOT="/data/cold/dst"`
   `export NTT_LOG_JSON="/var/log/ntt/orchestrator.jsonl"`

4. source it
   `source ~/.config/ntt/ntt.env`

5. run first disk
   `sudo ./bin/ntt-orchestrator /dev/sdX`

6. watch JSON
   `jq -c . /var/log/ntt/orchestrator.jsonl`

<!-- done -->
