#!/bin/bash
# Thermal + memory soak for the KR260, run on the board as root:
#   sudo ./soak.sh [minutes] [memtester_size]      (defaults: 20, 2500M)
# Logs temperature/power/CPU clock every minute to ./soak.log while stress-ng loads
# all 4 cores and memtester runs one pass. Look for: no throttling (CPU stays at
# 1333 MHz), stress-ng "failed: 0", memtester all "ok".
set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }
minutes="${1:-20}"
memsize="${2:-2500M}"
log=./soak.log
: > "$log"

( while true; do
    echo "== $(date +%T)"
    xmutil xlnx_platformstats -a | grep -E "SOM total power|temperature|CPU0\s*:.*MHz"
    echo "fan pwm: $(cat /sys/class/hwmon/hwmon*/pwm1 2>/dev/null)"
    sleep 60
  done ) >> "$log" 2>&1 &
mon=$!

stress-ng --cpu 4 --cpu-method matrixprod --timeout "${minutes}m" --metrics-brief > ./stress.log 2>&1 &
st=$!
memtester "$memsize" 1 > ./memtester.log 2>&1
echo "memtester exit: $?" >> "$log"
wait "$st"; echo "stress-ng exit: $?" >> "$log"
kill "$mon"

awk '/SOM total power/{p=$(NF-1); if (p>mp) mp=p}
     /LPD temp|FPD temp/{t=$(NF-1); if (t>mt) mt=t}
     /PL temp/{t=$(NF-1); if (t>ml) ml=t}
     END {print "peak power " mp " mW, peak PS " mt " C, peak PL " ml " C"}' "$log" | tee -a "$log"
echo SOAK_DONE >> "$log"
