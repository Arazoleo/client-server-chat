#!/usr/bin/env bash
# Roda o benchmark de 1 a N clientes e extrai os resultados do log do servidor.
#
# O servidor e iniciado a parte, na outra maquina:
#   ./chat_server 5000 | tee server.log
#
# Variavel opcional:
#   BENCH_PAUSE  pausa em segundos entre as rodadas (padrao 2)

set -u

# Folga ate a largada de cada rodada. Como date +%s e inteiro, a folga real
# fica entre 2 e 3 s, tempo de sobra para todos os clientes conectarem.
LEAD_SECONDS=3
CLIENT_LOG="clients.log"

usage() {
    cat >&2 <<EOF
Uso: $0 <IP> <porta> [segundos=10] [bloco_em_bytes=65536] [repeticoes=5] [max_clientes=10]
     $0 --csv <server.log> <clients.log>
     $0 --summary <server.log> <clients.log>
EOF
    exit 1
}

is_positive_integer() {
    case "$1" in
        '' | *[!0-9]* | 0) return 1 ;;
        *) return 0 ;;
    esac
}

is_non_negative_number() {
    case "$1" in
        '' | . | *[!0-9.]* | *.*.*) return 1 ;;
        *) return 0 ;;
    esac
}

# Confere cada rodada do servidor com o que os clientes dizem ter enviado.
# Recusa rodadas com cliente faltando, bytes divergentes, rodadas a mais ou
# a menos (outra bateria no mesmo log) e repeticoes desiguais.
validate_logs() {
    awk -v clients_log="$2" '
        function field(name,   i, pair) {
            for (i = 1; i <= NF; i++) {
                split($i, pair, "=")
                if (pair[1] == name)
                    return pair[2] + 0
            }
            return ""
        }

        function reject(message) {
            print "Logs invalidos: " message > "/dev/stderr"
            rejected = 1
            exit 1
        }

        FILENAME == clients_log && /^ROUND / {
            sent_rounds++
            expected_clients[sent_rounds] = field("clients")
            next
        }

        FILENAME == clients_log && /^BENCH_SENT / {
            finished_clients[sent_rounds]++
            sent_bytes[sent_rounds] += field("bytes")
            next
        }

        FILENAME != clients_log && /^BENCH clients=/ {
            round++
            clients = field("clients")
            bytes = field("bytes")
            reps[clients]++

            if (round > sent_rounds)
                reject("o servidor tem mais rodadas que " clients_log \
                       " (use um server.log novo para cada bateria)")
            if (clients != expected_clients[round])
                reject("rodada " round ": o servidor viu " clients \
                       " cliente(s), o script disparou " expected_clients[round])
            if (finished_clients[round] != clients)
                reject("rodada " round ": so " finished_clients[round] + 0 " de " \
                       clients " cliente(s) terminaram sem erro")
            if (bytes != sent_bytes[round])
                reject("rodada " round ": os clientes enviaram " sent_bytes[round] \
                       " bytes, o servidor recebeu " bytes)
        }

        END {
            if (rejected)
                exit 1
            if (round != sent_rounds)
                reject("o servidor tem " round " rodadas e " clients_log " tem " sent_rounds)

            for (clients in reps) {
                if (expected_reps == "")
                    expected_reps = reps[clients]
                else if (reps[clients] != expected_reps)
                    reject("numero de repeticoes diferente entre as quantidades de clientes")
            }
        }
    ' "$2" "$1"
}

# Uma linha por rodada, na ordem em que aparecem no log do servidor.
print_csv() {
    awk '
        BEGIN { print "clients,rep,bytes,seconds,mbps" }
        /^BENCH clients=/ {
            for (i = 2; i <= NF; i++) {
                split($i, field, "=")
                value[field[1]] = field[2]
            }
            rep[value["clients"]]++
            print value["clients"] "," rep[value["clients"]] "," \
                  value["bytes"] "," value["seconds"] "," value["mbps"]
        }
    ' "$1"
}

# Estatisticas por quantidade de clientes, com desvio padrao amostral.
print_summary() {
    echo "clients,reps,mean_mbps,stddev_mbps,min_mbps,max_mbps"
    print_csv "$1" | awk -F, '
        NR > 1 {
            clients = $1
            mbps = $5 + 0
            n[clients]++
            sum[clients] += mbps
            squares[clients] += mbps * mbps
            if (n[clients] == 1 || mbps < low[clients]) low[clients] = mbps
            if (n[clients] == 1 || mbps > high[clients]) high[clients] = mbps
        }
        END {
            for (clients in n) {
                mean = sum[clients] / n[clients]
                variance = 0
                if (n[clients] > 1)
                    variance = (squares[clients] - n[clients] * mean * mean) / (n[clients] - 1)
                printf "%s,%d,%.2f,%.2f,%.2f,%.2f\n", clients, n[clients], mean,
                       sqrt(variance > 0 ? variance : 0), low[clients], high[clients]
            }
        }
    ' | sort -t, -k1,1n
}

run_experiments() {
    local ip=$1 port=$2 seconds=${3:-10} block=${4:-65536}
    local reps=${5:-5} max_clients=${6:-10}
    local pause=${BENCH_PAUSE:-2}
    local client
    client="$(cd "$(dirname "$0")" && pwd)/chat_client"

    is_positive_integer "$reps" && is_positive_integer "$max_clients" &&
        is_non_negative_number "$pause" || usage

    if [ ! -x "$client" ]; then
        echo "Compile antes: gcc -O2 -Wall -Wextra chat_client.c -o chat_client -pthread" >&2
        exit 1
    fi

    : >"$CLIENT_LOG"

    local clients rep start_at pids pid failed
    for clients in $(seq 1 "$max_clients"); do
        for rep in $(seq 1 "$reps"); do
            echo "Rodada: $clients cliente(s), repeticao $rep de $reps"
            echo "ROUND clients=$clients rep=$rep" >>"$CLIENT_LOG"

            start_at=$(($(date +%s) + LEAD_SECONDS))
            pids=""
            for _ in $(seq 1 "$clients"); do
                "$client" "$ip" "$port" --bench "$seconds" "$block" \
                    --start-at "$start_at" >>"$CLIENT_LOG" &
                pids="$pids $!"
            done

            failed=0
            for pid in $pids; do
                wait "$pid" || failed=1
            done

            if [ "$failed" -ne 0 ]; then
                echo "Falha na rodada de $clients cliente(s), repeticao $rep." >&2
                echo "O log do servidor ficou com uma rodada invalida: reinicie o servidor e rode de novo." >&2
                exit 1
            fi

            sleep "$pause"
        done
    done

    echo "Pronto. Copie o server.log do servidor para esta pasta e rode:"
    echo "  $0 --csv server.log $CLIENT_LOG > results.csv"
    echo "  $0 --summary server.log $CLIENT_LOG > summary.csv"
}

case "${1:-}" in
    --csv | --summary)
        [ $# -eq 3 ] || usage
        validate_logs "$2" "$3" || exit 1
        if [ "$1" = "--csv" ]; then
            print_csv "$2"
        else
            print_summary "$2"
        fi
        ;;
    -* | '')
        usage
        ;;
    *)
        [ $# -ge 2 ] && [ $# -le 6 ] || usage
        run_experiments "$@"
        ;;
esac
