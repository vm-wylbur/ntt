# Deprecated Backup Scripts

These scripts have been replaced by `ntt-backup-remote-scp-nocontrol`.

## Deprecated Scripts

### ntt-backup-remote
- **Method:** rsync
- **Performance:** 9.2 MB/s
- **Reason for deprecation:** 16% slower than tar streaming
- **Date deprecated:** 2025-10-18

### ntt-backup-remote-scp  
- **Method:** tar streaming with SSH ControlMaster
- **Performance:** Not fully tested
- **Reason for deprecation:** Unnecessary complexity, ControlMaster doesn't improve performance
- **Date deprecated:** 2025-10-18

### ntt-backup-remote-wrapper.sh
- **Method:** Bash wrapper calling ntt-backup-remote (rsync)
- **Performance:** 9.2 MB/s
- **Reason for deprecation:** Wraps deprecated rsync implementation
- **Date deprecated:** 2025-10-18

## Active Script

**ntt-backup-remote-scp-nocontrol** - tar streaming without ControlMaster
- Performance: 10.7 MB/s (89% of network ceiling)
- Simple, reliable, well-tested
- Error handling fixed 2025-10-18
