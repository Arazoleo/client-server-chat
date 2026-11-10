#!/usr/bin/env bash
# Testes de ponta a ponta do modo --bench, sempre com o chat_server real.
# Uso: tests/test_bench.sh [trecho_do_nome_do_teste]

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
CLIENT="$ROOT/chat_client"
SERVER_PID=""
PORT=""
SERVER_LOG=""

stop_server() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
        SERVER_PID=""
    fi
}

cleanup() {
    stop_server
    rm -rf "$WORK"
}
trap cleanup EXIT

start_server() {
    PORT=$((20000 + RANDOM % 30000))
    SERVER_LOG="$WORK/server_$PORT.log"
    "$ROOT/chat_server" "$PORT" >"$SERVER_LOG" 2>&1 &
    SERVER_PID=$!

    local i
    for i in $(seq 1 50); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
    echo "servidor nao subiu na porta $PORT"
    return 1
}

fail() {
    echo "  falhou: $1"
    return 1
}

# Valor de um campo chave=valor numa linha de log.
field_of() {
    printf '%s\n' "$1" | tr ' ' '\n' | grep "^$2=" | cut -d= -f2
}

# Valor de um campo da ultima linha agregada do servidor.
server_field() {
    field_of "$(grep '^BENCH clients=' "$SERVER_LOG" | tail -n 1)" "$1"
}

# Espera todos os PIDs e falha se algum cliente saiu com erro.
wait_all() {
    local pid status=0
    for pid in "$@"; do
        wait "$pid" || status=1
    done
    [ "$status" -eq 0 ] || fail "cliente saiu com erro"
}

expect_server_clients() {
    [ "$(server_field clients)" = "$1" ] ||
        fail "esperava clients=$1, log: $(cat "$SERVER_LOG")"
}

# Escreve os logs de servidor e de clientes usados pelos testes de validacao.
write_logs() {
    printf '%s\n' "$1" >"$WORK/server.log"
    printf '%s\n' "$2" >"$WORK/clients.log"
}

# A extracao deve recusar os logs, sem emitir CSV, citando o motivo.
expect_rejected() {
    local out
    if out=$("$ROOT/run_bench.sh" --csv "$WORK/server.log" "$WORK/clients.log" 2>"$WORK/err"); then
        fail "logs invalidos foram aceitos: $out"
        return 1
    fi
    [ -z "$out" ] || fail "emitiu CSV mesmo recusando: $out" || return 1
    grep -q "$1" "$WORK/err" || fail "mensagem sem '$1': $(cat "$WORK/err")"
}

VALID_SERVER_LOG="Chat TCP ativo na porta 5000.
BENCH_CLIENT bytes=100 seconds=1.000
BENCH clients=1 bytes=100 seconds=1.000 mbps=100.00
BENCH_CLIENT bytes=100 seconds=1.000
BENCH clients=1 bytes=100 seconds=1.000 mbps=300.00
BENCH_CLIENT bytes=100 seconds=1.000
BENCH_CLIENT bytes=100 seconds=1.000
BENCH clients=2 bytes=200 seconds=1.000 mbps=500.00
BENCH_CLIENT bytes=100 seconds=1.000
BENCH_CLIENT bytes=100 seconds=1.000
BENCH clients=2 bytes=200 seconds=1.000 mbps=500.00"

VALID_CLIENTS_LOG="ROUND clients=1 rep=1
BENCH_SENT bytes=100 seconds=1.000
ROUND clients=1 rep=2
BENCH_SENT bytes=100 seconds=1.000
ROUND clients=2 rep=1
BENCH_SENT bytes=100 seconds=1.000
BENCH_SENT bytes=100 seconds=1.000
ROUND clients=2 rep=2
BENCH_SENT bytes=100 seconds=1.000
BENCH_SENT bytes=100 seconds=1.000"

test_tres_clientes_aparecem_juntos_no_servidor() {
    start_server || return 1

    local pids=""
    for _ in 1 2 3; do
        "$CLIENT" 127.0.0.1 "$PORT" --bench 0.5 65536 >/dev/null &
        pids="$pids $!"
    done
    wait_all $pids || return 1

    expect_server_clients 3 || return 1
    [ "$(server_field bytes)" -gt 0 ] || fail "servidor nao recebeu bytes"
}

test_bytes_enviados_sao_os_bytes_recebidos() {
    start_server || return 1

    local output sent
    output=$("$CLIENT" 127.0.0.1 "$PORT" --bench 0.5 4096) ||
        fail "cliente saiu com erro" || return 1
    sent=$(field_of "$(printf '%s\n' "$output" | grep '^BENCH_SENT')" bytes)

    [ -n "$sent" ] || fail "cliente nao informou BENCH_SENT: $output" || return 1
    [ "$sent" -gt 0 ] || fail "cliente nao enviou nada" || return 1
    [ $((sent % 4096)) -eq 0 ] || fail "$sent nao e multiplo do bloco" || return 1
    [ "$sent" = "$(server_field bytes)" ] ||
        fail "cliente enviou $sent, servidor recebeu $(server_field bytes)"
}

test_clientes_iniciados_em_momentos_diferentes_largam_juntos() {
    start_server || return 1

    local start_at=$(($(date +%s) + 3))
    local pids="" delay
    for delay in 0 0.4 0.8; do
        (sleep "$delay"; exec "$CLIENT" 127.0.0.1 "$PORT" --bench 0.5 65536 \
            --start-at "$start_at" >/dev/null) &
        pids="$pids $!"
    done
    wait_all $pids || return 1

    expect_server_clients 3 || return 1

    # Sem a largada combinada, a janela do servidor chegaria a 1.3 s.
    awk -v s="$(server_field seconds)" 'BEGIN { exit !(s >= 0.4 && s < 0.8) }' ||
        fail "janela de medicao inesperada: $(server_field seconds) s"
}

test_cliente_que_acorda_depois_da_largada_sai_com_erro() {
    start_server || return 1

    local start_at=$(($(date +%s) + 2))
    "$CLIENT" 127.0.0.1 "$PORT" --bench 0.3 4096 --start-at "$start_at" \
        >/dev/null 2>"$WORK/late.err" &
    local pid=$!

    # Congela o cliente enquanto ele dorme e so o solta bem depois da largada.
    sleep 0.3
    kill -STOP "$pid"
    while [ "$(date +%s)" -le "$start_at" ]; do
        sleep 0.1
    done
    sleep 0.3
    kill -CONT "$pid"

    if wait "$pid"; then
        fail "cliente atrasado nao saiu com erro"
        return 1
    fi
    grep -q 'largada' "$WORK/late.err" || fail "mensagem inesperada: $(cat "$WORK/late.err")"
}

test_script_roda_cada_cenario_e_gera_uma_linha_por_repeticao() {
    start_server || return 1

    (cd "$WORK" && BENCH_PAUSE=0 "$ROOT/run_bench.sh" 127.0.0.1 "$PORT" 0.2 65536 2 3) ||
        fail "run_bench.sh saiu com erro" || return 1

    local csv
    csv=$("$ROOT/run_bench.sh" --csv "$SERVER_LOG" "$WORK/clients.log" | cut -d, -f1,2)
    local expected="clients,rep
1,1
1,2
2,1
2,2
3,1
3,2"
    [ "$csv" = "$expected" ] || fail "csv inesperado: $csv"
}

test_resumo_mostra_media_desvio_e_maximo_por_quantidade_de_clientes() {
    write_logs "$VALID_SERVER_LOG" "$VALID_CLIENTS_LOG"

    local summary expected="clients,reps,mean_mbps,stddev_mbps,min_mbps,max_mbps
1,2,200.00,141.42,100.00,300.00
2,2,500.00,0.00,500.00,500.00"
    summary=$("$ROOT/run_bench.sh" --summary "$WORK/server.log" "$WORK/clients.log")

    [ "$summary" = "$expected" ] || fail "resumo inesperado: $summary"
}

test_recusa_rodada_em_que_um_cliente_nao_terminou() {
    # Um dos dois clientes da ultima rodada chegou atrasado e nao enviou nada.
    write_logs "$VALID_SERVER_LOG" "$(printf '%s\n' "$VALID_CLIENTS_LOG" | sed '$d')"
    expect_rejected "rodada 4"
}

test_recusa_rodada_com_cliente_que_nem_conectou() {
    # O servidor so viu 1 dos 2 clientes da ultima rodada.
    write_logs "$(printf '%s\n' "$VALID_SERVER_LOG" | sed '$d')
BENCH clients=1 bytes=100 seconds=1.000 mbps=100.00" "$VALID_CLIENTS_LOG"
    expect_rejected "rodada 4"
}

test_recusa_rodada_em_que_o_servidor_recebeu_menos_que_o_enviado() {
    write_logs "$(printf '%s\n' "$VALID_SERVER_LOG" | sed '$d')
BENCH clients=2 bytes=150 seconds=1.000 mbps=500.00" "$VALID_CLIENTS_LOG"
    expect_rejected "rodada 4"
}

test_recusa_log_do_servidor_com_duas_baterias() {
    write_logs "$VALID_SERVER_LOG
$VALID_SERVER_LOG" "$VALID_CLIENTS_LOG"
    expect_rejected "rodadas"
}

test_recusa_bateria_com_repeticoes_desiguais() {
    # A bateria foi interrompida depois da primeira repeticao com 2 clientes.
    write_logs "$(printf '%s\n' "$VALID_SERVER_LOG" | sed '$d' | sed '$d' | sed '$d')" \
        "$(printf '%s\n' "$VALID_CLIENTS_LOG" | sed '$d' | sed '$d' | sed '$d')"
    expect_rejected "repeticoes diferente"
}

if ! gcc -O2 -w "$ROOT/chat_server.c" -o "$ROOT/chat_server" -pthread ||
   ! gcc -O2 -Wall -Wextra "$ROOT/chat_client.c" -o "$ROOT/chat_client" -pthread; then
    echo "erro de compilacao"
    exit 1
fi

failures=0
for name in $(declare -F | awk '{print $3}' | grep '^test_' | grep -- "${1:-}"); do
    echo "== $name"
    if "$name"; then
        echo "  ok"
    else
        failures=$((failures + 1))
    fi
    stop_server
done

echo "falhas: $failures"
[ "$failures" -eq 0 ]
