# tcp-throughput-benchmark

Trabalho de Redes de Computadores. Adaptamos o chat TCP multithread visto em aula para medir a **capacidade efetiva de recepção do servidor**: quantos Mbit/s ele recebe, no total, quando de 1 a 10 clientes enviam dados ao mesmo tempo. O chat continua funcionando como antes; a diferença é que agora existe um modo de benchmark (`/bench`).

**Autores:** Thiago Roberto Fernandes Rocha, Leonardo Arazo de O. Araujo e Gabriel Leal Bonavina.

O relatório completo, com metodologia, tabelas, gráficos e análise dos gargalos, está em [`relatorio/relatorio.pdf`](relatorio/relatorio.pdf).

## Resultados em resumo

Todas as medições foram feitas num único notebook (WSL2 com Ubuntu), com servidor e clientes na mesma máquina. Detalhes do ambiente estão no relatório.

| Cenário | Resultado |
|---|---|
| *Loopback* (`127.0.0.1`) | O total cresce de 51,4 Gbit/s (1 cliente) até um pico de 159,6 Gbit/s (3 clientes), fica instável com 4 e se estabiliza em cerca de 68 a 73 Gbit/s de 5 a 10 clientes. Com 10 clientes, a média foi de 68,9 Gbit/s. O gargalo é a CPU, gasta quase toda em modo kernel na pilha TCP. |
| Rede simulada de 1 Gbit/s | Total constante, cerca de 957 Mbit/s, de 1 a 10 clientes. O enlace é o gargalo. |
| Rede simulada de 100 Mbit/s | Total constante, cerca de 95,7 Mbit/s, de 1 a 10 clientes. |

Como não há placa de rede física no caminho, os resultados em *loopback* medem o software (servidor e pilha TCP do sistema operacional), e não a capacidade de um enlace real.

## Estrutura do repositório

| Caminho | O que é |
|---|---|
| `chat_server.c` | Servidor do chat, com o modo `/bench` |
| `chat_client.c` | Cliente do chat, com o modo `--bench` |
| `run_bench.sh` | Automação das baterias, geração de tabelas e verificação dos logs |
| `rede_simulada.sh` | Cria uma rede simulada (namespaces + `tc`) com taxa limitada |
| `tests/test_bench.sh` | Testes automatizados, em *loopback* |
| `relatorio/` | Relatório em LaTeX (`relatorio.tex`, PDF), script das figuras e tabelas e os dados brutos em `relatorio/dados/` |

## Como o servidor funciona

Quando um cliente conecta, o servidor lê a primeira linha. No chat normal, essa linha é o nome do usuário. Se ela for `/bench`, a conexão não entra no chat: o servidor só recebe os dados com `recv()`, num buffer de 256 KiB, e conta os bytes, sem repassar nada para ninguém.

Cada thread conta os seus bytes numa variável própria, sem mutex dentro do laço, e anota o horário do primeiro e do último byte recebido. Quando a conexão termina, a thread soma o que recebeu num total global, usando mutex. A última thread da rodada calcula a taxa agregada e imprime uma linha assim:

```
BENCH clients=3 bytes=3000000000 seconds=6.731 mbps=3565.60
```

Também sai uma linha `BENCH_CLIENT` por conexão, com os bytes que ela recebeu.

A taxa é calculada assim:

```
Mbps = 8 × (bytes recebidos por todas as threads) / (tempo entre o primeiro e o último byte × 10^6)
```

O tempo vai do primeiro byte de qualquer cliente até o último byte de qualquer cliente. Assim, o tempo de conexão e a espera antes de começar não entram na conta.

O `listen()` passou de 10 para 128, para que 10 clientes conectando juntos não dependam do tamanho da fila.

## Protocolo entre cliente e servidor

1. O cliente conecta e manda `/bench\n` como primeira linha.
2. Depois disso, manda só dados, com qualquer conteúdo.
3. Para terminar, chama `shutdown(fd, SHUT_WR)`. O servidor vê `recv() == 0`, fecha a conta e fecha a conexão.
4. O cliente pode esperar o próprio `recv()` devolver 0 para saber que o servidor terminou.

## Compilar

```bash
gcc -O2 -Wall -Wextra chat_server.c -o chat_server -pthread
gcc -O2 -Wall -Wextra chat_client.c -o chat_client -pthread
```

O chat normal funciona com `./chat_server 5000` e `./chat_client <IP> 5000`.

## Rodar os experimentos

O servidor é iniciado à parte, e o script roda na máquina dos clientes:

```bash
# servidor
./chat_server 5000 | tee server.log

# clientes (IP, porta, segundos, bloco, repetições, máximo de clientes)
./run_bench.sh 127.0.0.1 5000 10 65536 5 10
```

Para usar duas máquinas, inicie o servidor em uma e rode o `run_bench.sh` na outra com o IP do servidor.

Em cada rodada, o script escolhe um horário 2 a 3 segundos à frente e passa o mesmo `--start-at` para todos os clientes, para que comecem juntos. A pausa entre as rodadas muda com a variável `BENCH_PAUSE` (padrão 2 s). Todos os clientes de uma rodada rodam na mesma máquina, então o relógio é o mesmo. Se o horário de largada já tiver passado, ou se o cliente acordar mais de 0,1 s depois dele, o cliente sai com erro, porque aquela rodada não seria comparável.

O script registra cada rodada e os bytes que cada cliente enviou em `clients.log`. Se algum cliente falhar, o script para e avisa. Nesse caso, reinicie o servidor e rode tudo de novo, porque o `server.log` ficou com uma rodada inválida.

Para gerar as tabelas:

```bash
./run_bench.sh --csv server.log clients.log > results.csv       # uma linha por rodada
./run_bench.sh --summary server.log clients.log > summary.csv   # média, desvio, mínimo e máximo por quantidade de clientes
```

Antes de gerar qualquer tabela, o script confere os dois logs rodada por rodada. Ele recusa os logs, sem gerar nada, quando o servidor viu menos clientes do que o script disparou, quando algum cliente não terminou, quando o total de bytes do servidor difere do que os clientes enviaram, quando o `server.log` tem rodadas de outra bateria, ou quando as quantidades de clientes têm números de repetições diferentes. Por isso, use um `server.log` novo para cada bateria.

### Cliente de benchmark sozinho

```bash
./chat_client <IP> <porta> --bench <segundos> <bloco_em_bytes> [--start-at <epoch>]
```

O cliente conecta, manda `/bench\n`, espera o horário de `--start-at` (se foi passado) e envia blocos sem parar até o tempo acabar. Depois chama `shutdown(fd, SHUT_WR)`, espera o servidor fechar a conexão e imprime `BENCH_SENT bytes=... seconds=...`.

### Rede simulada

O `rede_simulada.sh` cria dois namespaces de rede ligados por um par `veth`, com a taxa limitada pelo `tc` (`tbf`) nos dois sentidos. Precisa de root e de um Linux (inclusive WSL2):

```bash
sudo ./rede_simulada.sh setup 1gbit 1mb      # ou: setup 100mbit 128kb
sudo ./rede_simulada.sh exec srv ./chat_server 5000 > server.log &
sudo ./rede_simulada.sh exec cli ./run_bench.sh 10.0.0.1 5000 10 65536 5 10
sudo ./rede_simulada.sh teardown
```

## Testes

```bash
tests/test_bench.sh
```

Os testes usam o `chat_server` real em `127.0.0.1`, então os valores de Mbps deles não servem como resultado do trabalho.

## Gerar o relatório

As figuras e tabelas são geradas a partir dos logs em `relatorio/dados/`:

```bash
python relatorio/make_figures.py
cd relatorio && pdflatex relatorio.tex && pdflatex relatorio.tex
```

O script de figuras precisa de Python 3 com `matplotlib`.
