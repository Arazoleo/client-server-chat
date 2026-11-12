#!/usr/bin/env bash
# Rede simulada dentro de um unico Linux (por exemplo, WSL2). Precisa de root.
#
# Cria dois "computadores virtuais" (namespaces de rede) ligados por um cabo
# virtual (veth) e limita a taxa do enlace com o tc (tbf), nos dois sentidos:
#
#   ns_srv (10.0.0.1)  <== veth, taxa limitada ==>  ns_cli (10.0.0.2)
#
# Uso:
#   sudo ./rede_simulada.sh setup <taxa> [burst]   ex.: setup 1gbit 1mb | setup 100mbit 128kb
#   sudo ./rede_simulada.sh show                   mostra a configuracao atual
#   sudo ./rede_simulada.sh teardown               remove tudo
#   sudo ./rede_simulada.sh exec srv|cli <comando> executa um comando dentro de um dos lados
#
# Exemplo de bateria:
#   sudo ./rede_simulada.sh setup 1gbit 1mb
#   sudo ./rede_simulada.sh exec srv ./chat_server 5000 > server.log &
#   sudo ./rede_simulada.sh exec cli ./run_bench.sh 10.0.0.1 5000 10 65536 5 10
#   sudo ./rede_simulada.sh teardown

set -eu

SRV=ns_srv
CLI=ns_cli
IP_SRV=10.0.0.1
IP_CLI=10.0.0.2
LATENCY=20ms   # fila maxima do tbf, em tempo de transmissao na taxa configurada

teardown() {
    ip netns del "$SRV" 2>/dev/null || true
    ip netns del "$CLI" 2>/dev/null || true
}

config_side() {
    local ns=$1 dev=$2 addr=$3 rate=$4 burst=$5
    ip -n "$ns" addr add "$addr/24" dev "$dev"
    ip -n "$ns" link set "$dev" up
    ip -n "$ns" link set lo up
    # Sem segmentacao por hardware/software, o tc enxerga pacotes de 1500 bytes,
    # como numa placa de rede real, e nao quadros agregados de 64 KiB.
    ip netns exec "$ns" ethtool -K "$dev" tso off gso off gro off >/dev/null 2>&1 || true
    ip netns exec "$ns" tc qdisc add dev "$dev" root tbf rate "$rate" burst "$burst" latency "$LATENCY"
}

setup() {
    local rate=${1:?informe a taxa, ex.: 1gbit} burst=${2:-1mb}
    teardown
    ip netns add "$SRV"
    ip netns add "$CLI"
    ip link add veth_srv type veth peer name veth_cli
    ip link set veth_srv netns "$SRV"
    ip link set veth_cli netns "$CLI"
    config_side "$SRV" veth_srv "$IP_SRV" "$rate" "$burst"
    config_side "$CLI" veth_cli "$IP_CLI" "$rate" "$burst"
    echo "Rede simulada pronta: $IP_CLI -> $IP_SRV a $rate (burst $burst, fila $LATENCY), MTU 1500."
}

show() {
    for ns in "$SRV" "$CLI"; do
        echo "== $ns =="
        ip -n "$ns" -br addr show
        ip netns exec "$ns" tc qdisc show
    done
}

[ "$(id -u)" -eq 0 ] || { echo "Rode como root (sudo)." >&2; exit 1; }

case "${1:-}" in
    setup) shift; setup "$@" ;;
    show) show ;;
    teardown) teardown ;;
    exec)
        case "${2:-}" in
            srv) ns=$SRV ;;
            cli) ns=$CLI ;;
            *) echo "Use: exec srv|cli <comando>" >&2; exit 1 ;;
        esac
        shift 2
        exec ip netns exec "$ns" "$@"
        ;;
    *) sed -n '2,20p' "$0" >&2; exit 1 ;;
esac
