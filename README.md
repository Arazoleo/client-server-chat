# tcp-throughput-benchmark

Trabalho de Redes de Computadores. Pegamos o chat TCP multithread visto em aula e adaptamos para medir quanto o servidor consegue receber quando vários clientes mandam dados ao mesmo tempo, de 1 a 10 clientes. O chat continua funcionando como antes, a diferença é que agora existe um modo de benchmark.

## Situação atual

O servidor, o cliente de benchmark e o script dos experimentos estão prontos. Faltam as medições com cabo e o relatório.

| Parte | Responsável | Situação |
|---|---|---|
| `chat_server.c` | Leonardo | pronto |
| `chat_client.c` (modo `--bench`) | Bonavina | pronto |
| `run_bench.sh` | Bonavina | pronto |
| Relatório, tabelas e gráficos | Thiago | a fazer |

## Como o servidor funciona

Quando um cliente conecta, o servidor lê a primeira linha. No chat normal, essa linha é o nome do usuário. Se ela for `/bench`, a conexão não entra no chat: o servidor só recebe os dados com `recv()`, num buffer de 256 KiB, e conta ram, sem repassar nada para ninguém.

Cada thread conta os seus bytes numa variável própria, sem mutex dentro do laço, e anota o horário do primeiro e do último byte recebido. Quando a conexão termina, a thread soma o que recebeu num total global, e aí sim usando mutex. A última thread da rodada calcula a taxa agregada e imprime uma linha assim:

```
BENCH clients=3 bytes=3000000000 seconds=6.731 mbps=3565.60
```

Também sai uma linha `BENCH_CLIENT` por conexão. Vamos usar essas linhas para ver se a banda foi dividida por igual entre os clientes.

A taxa é calculada assim:

```
Mbps = 8 × (bytes recebidos por todas as threads) / (tempo entre o primeiro e o último byte × 10^6)
```

O tempo vai do primeiro byte de qualquer cliente até o último byte de qualquer cliente. Assim, o tempo de conexão e a espera antes de começar não entram na conta.

Também mudamos o `listen()` de 10 para 128, para que 10 clientes conectando juntos não dependam do tamanho da fila.

## Combinado entre cliente e servidor

Para quem for escrever o cliente:

1. Conectar e mandar `/bench\n` como primeira linha.
2. Depois disso, mandar só dados, com qualquer conteúdo.
3. Para terminar, chamar `shutdown(fd, SHUT_WR)`. O servidor vê `recv() == 0`, fecha a conta e fecha a conexão.
4. O cliente pode esperar o próprio `recv()` devolver 0 para saber que o servidor terminou.

## Compilar e rodar o servidor

```bash
gcc -O2 -Wall -Wextra chat_server.c -o chat_server -pthread
./chat_server 5000 | tee server.log
```

Enquanto o cliente não fica pronto, dá para testar o servidor com o `nc`. Este comando abre 3 conexões de benchmark ao mesmo tempo, cada uma mandando 1 GB:

```bash
for i in 1 2 3; do (printf '/bench\n'; head -c 1000000000 /dev/zero) | nc -w 1 127.0.0.1 5000 & done; wait
```

O servidor deve mostrar `clients=3` e `bytes=3000000000`. Testamos no MacBook Air do Leonardo e funcionou, o chat normal também continua funcionando com um benchmark rodando ao mesmo tempo. A taxa que aparece nesse teste é limitada pelo próprio `nc`, então não serve como resultado do trabalho.

## Cliente de benchmark

```bash
gcc -O2 -Wall -Wextra chat_client.c -o chat_client -pthread
./chat_client <IP> <porta> --bench <segundos> <bloco_em_bytes> [--start-at <epoch>]
```

O cliente conecta, manda `/bench\n`, espera o horário de `--start-at`, se ele foi passado, e envia blocos sem parar até o tempo acabar. Depois chama `shutdown(fd, SHUT_WR)`, espera o servidor fechar a conexão e imprime `BENCH_SENT bytes=... seconds=...`. Se o horário de largada já tiver passado, ou se o cliente acordar mais de 0,1 s depois dele, o cliente sai com erro, porque aquela rodada não seria comparável.

Sem o modo `--bench`, `./chat_client <IP> <porta>` continua sendo o chat normal.

## Rodar os experimentos

O servidor é iniciado à parte, e o script roda na máquina dos clientes:

```bash
# na máquina do servidor
./chat_server 5000 | tee server.log

# na máquina dos clientes (IP, porta, segundos, bloco, repetições, máximo de clientes)
./run_bench.sh 192.168.0.10 5000 10 65536 5 10
```

Em cada rodada, o script escolhe um horário 2 a 3 segundos à frente e passa o mesmo `--start-at` para todos os clientes. A pausa entre as rodadas muda com a variável `BENCH_PAUSE` (padrão 2 s). Os clientes de uma rodada rodam todos na mesma máquina, então o relógio deles é o mesmo. Para espalhar clientes por várias máquinas, os relógios precisariam estar sincronizados por NTP.

O script registra cada rodada e os bytes que cada cliente enviou em `clients.log`, na pasta onde ele foi rodado. Se algum cliente falhar, o script para e avisa. Nesse caso, reinicie o servidor e rode tudo de novo, porque o `server.log` ficou com uma rodada inválida.

No final, copie o `server.log` para a mesma pasta do `clients.log` e gere as tabelas:

```bash
./run_bench.sh --csv server.log clients.log > results.csv       # uma linha por rodada
./run_bench.sh --summary server.log clients.log > summary.csv   # média, desvio, mínimo e máximo por quantidade de clientes
```

Antes de gerar qualquer tabela, o script confere os dois logs rodada por rodada. Ele recusa os logs, sem gerar nada, quando o servidor viu menos clientes do que o script disparou, quando algum cliente não terminou, quando o servidor recebeu um total de bytes diferente do que os clientes enviaram, quando o `server.log` tem rodadas de outra bateria, ou quando as quantidades de clientes têm números de repetições diferentes. Por isso, use um `server.log` novo para cada bateria.

## Testes

```bash
tests/test_bench.sh
```

Os testes usam o `chat_server` real em `127.0.0.1`, então os valores de Mbps deles não servem como resultado do trabalho.

## O que falta

- Rodar os experimentos de verdade, com cabo, nas máquinas do grupo.
- Relatório: ficha das máquinas, parâmetros dos testes, tabela de clientes × Mbps, gráfico e discussão dos gargalos.
