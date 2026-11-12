#!/usr/bin/env bash
# Perfil de CPU (vmstat 1) de rodadas isoladas, para a discussao de gargalos.
cd ~/bench || exit 1
rm -f perfil.txt
run() {
    local n=$1 tag=$2
    ./chat_server 5001 > srv_$tag.log 2>/dev/null &
    local spid=$!
    sleep 1
    vmstat 1 16 > vm_$tag.txt &
    local vpid=$!
    sleep 1
    local start_at=$(( $(date +%s) + 3 ))
    local pids=""
    for _ in $(seq 1 "$n"); do
        ./chat_client 127.0.0.1 5001 --bench 10 65536 --start-at "$start_at" > /dev/null &
        pids="$pids $!"
    done
    for p in $pids; do wait "$p"; done
    wait "$vpid"
    kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
    local bench
    bench=$(grep '^BENCH clients=' srv_$tag.log)
    # media de us, sy, id, st nas amostras em que a CPU esta ocupada (id < 80)
    local cpu
    cpu=$(awk 'NR==2 { for (i=1;i<=NF;i++) col[$i]=i }
               NR>2 && $col["id"] < 80 { us+=$col["us"]; sy+=$col["sy"]; id+=$col["id"]; st+=$col["st"]; k++ }
               END { if (k) printf "amostras=%d us=%.1f sy=%.1f id=%.1f st=%.1f", k, us/k, sy/k, id/k, st/k }' vm_$tag.txt)
    echo "n=$n $tag | $bench | $cpu" | tee -a perfil.txt
    sleep 2
}
run 1 a1
run 3 a3
for r in 1 2 3; do run 4 a4_$r; done
run 5 a5
run 10 a10
