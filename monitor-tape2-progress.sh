#!/usr/bin/env bash
# Monitor tape2 copy progress across multiple workers
# Usage: ./monitor-tape2-progress.sh [interval_seconds]

INTERVAL=${1:-30}
MEDIUM_HASH="897c9f0be5af8b98314a773a9f85cdfb9d33903d985ae49d774f1fc36ec24bab"

echo "Monitoring tape2 copy progress (${INTERVAL}s intervals)"
echo "Time,Total,Copied,Pending,PercentDone,Rate(paths/sec)"

LAST_COPIED=0
LAST_TIME=$(date +%s)

while true; do
    CURRENT_TIME=$(date +%s)
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Query database
    RESULT=$(sudo -u postgres psql -d copyjob -t -c \
        "SELECT COUNT(*) as total,
                COUNT(*) FILTER (WHERE copied) as copied,
                COUNT(*) FILTER (WHERE NOT copied) as pending
         FROM paths
         WHERE medium_hash = '$MEDIUM_HASH';" | tr -s ' ' | sed 's/^ //')

    TOTAL=$(echo "$RESULT" | cut -d'|' -f1 | xargs)
    COPIED=$(echo "$RESULT" | cut -d'|' -f2 | xargs)
    PENDING=$(echo "$RESULT" | cut -d'|' -f3 | xargs)

    PERCENT=$(awk "BEGIN {printf \"%.1f\", ($COPIED / $TOTAL) * 100}")

    # Calculate rate
    if [ $LAST_COPIED -gt 0 ]; then
        ELAPSED=$((CURRENT_TIME - LAST_TIME))
        DELTA=$((COPIED - LAST_COPIED))
        RATE=$(awk "BEGIN {printf \"%.1f\", $DELTA / $ELAPSED}")
    else
        RATE="0.0"
    fi

    echo "$TIMESTAMP,$TOTAL,$COPIED,$PENDING,$PERCENT%,$RATE"

    LAST_COPIED=$COPIED
    LAST_TIME=$CURRENT_TIME

    sleep $INTERVAL
done
