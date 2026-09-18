#!/bin/sh
# Regression gate for the UML vec0 NAPI budget fix (uml-guest-3).
#
# The bug: the old kernel's vector_poll completed NAPI on a full-budget
# poll, descheduling it, so the :443 Send-Q crawled and goose agent turns
# timed out. The fixed kernel must drain.
#
# Run INSIDE a fresh UML guest console:
#
#   . /root/endpoint.env      # your endpoint vars for goose; never commit these
#   sh /root/goose-repro.sh <label> [ntasks] [port]
#
#   label  run marker written into /root/task-note.txt by each agent task
#   ntasks concurrent agent turns (default 2)
#   port   destination port of the AI endpoint flow (default 443)
#
# Passes (exit 0) iff:
#   - every task appends its "<label> done" line (all completed)
#   - Send-Q never holds above 10000 for 3 consecutive 5s samples (no crawl)
#   - dmesg gains no "Budget exceeded" vector NAPI lines
# Monitor samples print as "c=N wall=... upt=... sq=[...]" in /root/repro.mon
# (wall vs upt is also the CPU-starvation drift check: equal deltas = none).

label=${1:?usage: goose-repro.sh <label> [ntasks] [port]}
n=${2:-2}
port=${3:-443}

cd /root || exit 2

# Defensive net bring-up (uml-guest-3 rootfs does this at sysinit).
ifconfig vec0 up 2>/dev/null
ifconfig vec0 | grep -q 'inet addr' || udhcpc -i vec0 -n -q

note=/root/task-note.txt
rm -f "$note" /root/repro.mon /root/repro.log.* /root/repro.rc.*

( i=0; while [ $i -lt 48 ]; do
    d=$(date +%s); u=$(cut -d. -f1 /proc/uptime)
    q=$(netstat -tn 2>/dev/null | awk -v p=":$port " '$0 ~ p {printf "%s/%s ",$2,$3}')
    echo "c=$i wall=$d upt=$u sq=[$q]"
    i=$((i+1)); sleep 5
  done > /root/repro.mon ) &

i=1
while [ $i -le "$n" ]; do
    timeout 240 goose run -t "Read $note. Append exactly the line '$label done' to it. Then reply with a two-word confirmation." \
        > "/root/repro.log.$i" 2>&1 &
    i=$((i+1))
done
wait

fail=0
got=$(grep -c "$label done" "$note" 2>/dev/null)
[ "$got" = "$n" ] || { echo "FAIL: $got/$n tasks completed"; fail=1; }

if awk -F'sq=|]' '{ n=split($2,p," "); hi=0
    for (j=1;j<=n;j++) { split(p[j],q,"/"); if (q[2]+0>10000) hi=1 }
    if (hi) c++; else c=0
    if (c>=3) { print "FAIL: Send-Q crawl from sample " $1; exit 1 } }' /root/repro.mon; then :; else fail=1; fi

be=$(dmesg 2>/dev/null | grep -c 'Budget exhausted')
[ "$be" = 0 ] || { echo "FAIL: $be 'Budget exhausted' dmesg lines"; fail=1; }

[ $fail = 0 ] && echo "PASS: $label — $n/$n tasks completed, Send-Q drained, no NAPI budget warnings"
exit $fail