# tcp-throughput-benchmark

Trabalho de Redes de Computadores. Pegamos o chat TCP multithread visto em aula e adaptamos para medir quanto o servidor consegue receber quando vários clientes mandam dados ao mesmo tempo, de 1 a 10 clientes. O chat continua funcionando como antes, a diferença é que agora existe um modo de benchmark.

## Situação atual

O servidor está pronto e testado. O cliente de benchmark, o script dos experimentos e o relatório ainda estão em andamento.

| Parte | Responsável | Situação |
|---|---|---|
| `chat_server.c` | Leonardo | pronto |
| `chat_client.c` (modo `--bench`) | Bonavina | a fazer |
| `run_bench.sh` | Bonavina | a fazer |
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

## O que falta

- Cliente com o modo `--bench <segundos>  em laço até o tempo acabar, com largada combinada entre todos os clientes.
- Script que roda de 1 a 10 clientes, com várias repetições cada.
- Rodar os experimentos de verdade, com cabo, nas máquinas do grupo.
- Relatório: ficha das máquinas, parâmetros dos testes, tabela de clientes × Mbps, gráfico e discussão dos gargalos.
- Completar este README com as instruções do cliente e do script.
