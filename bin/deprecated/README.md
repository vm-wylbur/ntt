# Deprecated Scripts

These scripts are superseded and kept for historical reference only.

## ntt-loader-old (176 lines)
**Deprecated:** 2025-10-11
**Reason:** Pre-partitioning architecture, replaced by ntt-loader
**Superseded by:** bin/ntt-loader

## ntt-loader-partitioned (200 lines)
**Deprecated:** 2025-10-11
**Reason:** Functionality merged into ntt-loader
**Superseded by:** bin/ntt-loader

## ntt-loader-detach (325 lines)
**Deprecated:** 2025-10-11
**Reason:** Experimental DETACH/ATTACH pattern incompatible with parent-level foreign keys
**Issue:** See docs/lessons/partition-migration-postmortem-2025-10-05.md
**Superseded by:** bin/ntt-loader (uses standard partition operations)

---

**Do not use these scripts in production.**

If you need to reference historical loader implementations, these files are preserved here.
