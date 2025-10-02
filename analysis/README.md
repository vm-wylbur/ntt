# Cross-Medium Deduplication Analysis

Static/infrequent analysis of cross-medium blob sharing patterns in the NTT dedup system.

## Purpose

This analysis reveals:
- **n_hardlinks distribution** - How frequently blobs are duplicated
- **Cross-medium sharing** - Which media pairs save the most storage
- **Jaccard similarity** - Content similarity for clustering analysis  
- **Network topology** - Hub/satellite relationships
- **UpSet patterns** - Intersection visualization

Run **quarterly** or when adding new media (not for daily dashboard metrics).

## Directory Structure

```
analysis/
├── cross-medium-dedup.sql      # SQL queries → exports to /tmp/
├── cross-medium-dedup.Rmd      # R Markdown report template
├── README.md                   # This file
├── helpers/
│   └── (future Python/R helper scripts)
└── output/
    └── dup-analysis-*.{md,html}  # Generated reports
```

## Workflow

### 1. Run SQL Analysis (generates data files)

```bash
cd ~/projects/ntt/analysis
./cross-medium-dedup.sql
```

**Outputs to /tmp/:**
- `nhardlinks.json` - n_hardlinks distribution histogram
- `sharing_matrix.csv` - Pairwise sharing (blobs + storage)
- `jaccard.json` - Per-medium blob counts
- `upset_data.csv` - UpSet visualization data

**Runtime:** ~5-10 minutes for 3.4M blobs, 4 media

### 2. Generate R Markdown Report (optional)

```bash
# Requires R + rmarkdown + ggplot2 + dplyr
Rscript -e "rmarkdown::render('cross-medium-dedup.Rmd')"
```

**Output:** `cross-medium-dedup.html` with interactive visualizations

**If R not available:** Use the existing markdown doc in `output/`

### 3. Review Results

- **HTML report:** Open `cross-medium-dedup.html` in browser
- **Raw data:** Inspect `/tmp/*.{json,csv}` files
- **Previous runs:** Check `output/dup-analysis-*.md`

## Key Findings (Last Run: 2025-10-01)

- **4 media** with duplicated files (star topology)
- **236d as hub:** 83% of all blobs involve it
- **188 GB savings** from top 2 medium pairs
- **Bimodal distribution:** 2-3 copies (52%) and 32-63 copies (12%)
- **Low Jaccard (<6%):** Media are independent content collections

## Performance Notes

### Critical Lessons

1. **ANALYZE is mandatory** after creating `blob_media_matrix`
   - Queries timeout without statistics
   - Cost: 30+ min debugging vs 1 second to run ANALYZE

2. **INTERSECT > self-join** for set operations
   - Self-join on 1.6M rows: timeout
   - INTERSECT on same data: <1 second

3. **Avoid 100M row scans** 
   - Path pattern analysis (original goal) times out
   - Focus on blob-level analysis instead

### When NOT to Run

- ❌ During active worker operations (competes for DB resources)
- ❌ For real-time dashboard metrics (use live queries instead)
- ❌ More than quarterly (results don't change frequently)

## Dependencies

### Required
- PostgreSQL 17+ (with `blob_media_matrix` access)
- Bash (for SQL script)
- `jq` (for JSON formatting in SQL script)

### Optional
- R + rmarkdown + ggplot2 + dplyr + tidyr (for HTML report)
- UpSetR package (for intersection visualization)
- Python 3 (for UpSet data export in SQL script)

## Troubleshooting

**Query timeouts:**
```sql
-- Did you ANALYZE?
ANALYZE blob_media_matrix;

-- Check if indexes exist
\d blob_media_matrix
```

**GROUP BY hangs:**
- Use INTERSECT method instead (see SQL script)
- Process per medium, not all at once

**No UpSet data:**
- Requires Python 3 for `/tmp/upset_data.csv`
- Skip visualization if not available

## Future Enhancements

- [ ] Automate monthly runs via cron
- [ ] Add temporal analysis (media age correlation)
- [ ] Identify top duplicated files (the 40K-copy blob)
- [ ] Compare with last run (delta analysis)
- [ ] Email report to stakeholders
