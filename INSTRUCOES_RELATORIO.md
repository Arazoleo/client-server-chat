# Instruções para o relatório

Este arquivo junta o que já descobrimos sobre a bateria com cabo entre os dois PCs, para quem for escrever o relatório. A conclusão principal é que o throughput ficou travado em uns 934 Mbit/s porque esse é o limite do Gigabit Ethernet, não do nosso código.

## Unidade: é megabit, não megabyte

O campo `mbps` do `server.log` está em **megabits por segundo**. A conta no `chat_server.c` é:

```c
mbps = bytes * 8.0 / secs / 1e6;
```

Então 934 Mbit/s equivalem a uns **117 MB/s** (934 / 8). No relatório, escrevam sempre "Mbit/s" para não confundir.

## Parâmetros da bateria

- 2 PCs ligados por cabo: um rodando o `chat_server`, o outro rodando o `run_bench.sh`.
- De 1 a 10 clientes, com 5 repetições para cada quantidade, totalizando 50 rodadas.
- 10 s de envio por rodada.
- Bloco de envio: conferir com quem rodou o script (o padrão é 65536 bytes).

## Resultados

Tabela tirada das 50 linhas `BENCH clients=` do `server.log`:

| Clientes | Média (Mbit/s) | Desvio | Mínimo | Máximo | Média (MB/s) |
|---:|---:|---:|---:|---:|---:|
| 1 | 933,37 | 0,61 | 932,58 | 934,04 | 116,7 |
| 2 | 934,01 | 0,17 | 933,76 | 934,23 | 116,8 |
| 3 | 934,15 | 0,21 | 933,87 | 934,33 | 116,8 |
| 4 | 934,36 | 0,15 | 934,13 | 934,47 | 116,8 |
| 5 | 934,44 | 0,01 | 934,43 | 934,45 | 116,8 |
| 6 | 934,45 | 0,01 | 934,44 | 934,46 | 116,8 |
| 7 | 934,45 | 0,01 | 934,44 | 934,45 | 116,8 |
| 8 | 934,45 | 0,01 | 934,44 | 934,46 | 116,8 |
| 9 | 934,45 | 0,01 | 934,43 | 934,46 | 116,8 |
| 10 | 934,46 | 0,01 | 934,45 | 934,46 | 116,8 |

Para gerar os CSVs oficiais, copiem o `server.log` e o `clients.log` para a mesma pasta e rodem:

```bash
./run_bench.sh --csv server.log clients.log > results.csv
./run_bench.sh --summary server.log clients.log > summary.csv
```

O `summary.csv` deve bater com a tabela acima.

## O que os dados mostram

1. **O total não muda com o número de clientes.** De 1 a 10 clientes, o throughput agregado fica entre 932,6 e 934,5 Mbit/s. Se o servidor (CPU, threads, buffer) fosse o gargalo, o total mudaria quando mudasse o número de clientes.
2. **A banda é só dividida.** Pelas linhas `BENCH_CLIENT`, 1 cliente recebe uns 1,17 GB em 10 s, 2 clientes recebem uns 586 MB cada, 4 recebem uns 293 MB cada e 10 recebem uns 118 MB cada. A soma é sempre a mesma.
3. **A variação é muito pequena.** O desvio padrão fica abaixo de 1 Mbit/s em todos os casos e cai para 0,01 a partir de 5 clientes. Com mais conexões, o enlace fica sempre cheio.
4. **Uma rodada dividiu a banda de forma desigual.** Numa das repetições com 5 clientes, 3 conexões receberam uns 293 MB e 2 receberam uns 147 MB. O total continuou igual, então não é bug. É um exemplo de que o TCP não garante divisão perfeitamente justa entre conexões, e vale um comentário curto no relatório.

## Por que 934 e não 1000

O link Ethernet é de 1000 Mbit/s, mas parte desses bits é gasta com cabeçalhos e com o intervalo entre quadros. Com MTU de 1500 bytes:

- **Espaço ocupado no fio por quadro:** 1500 + 14 (cabeçalho Ethernet) + 4 (FCS) + 8 (preâmbulo) + 12 (intervalo entre quadros) = **1538 bytes**.
- **Dado útil por quadro:** 1500 − 20 (IP) − 20 (TCP) − 12 (opção de timestamps do TCP) = **1448 bytes**.
- **Teto teórico de TCP:** 1448 / 1538 × 1000 Mbit/s ≈ **941 Mbit/s**.

Medimos 934 Mbit/s, ou seja, uns **99%** do teto teórico. A pequena diferença que sobra vem do início de cada conexão, quando o TCP ainda está aumentando a janela (slow start), e da forma como o tempo é medido.

## Prova de que o código não é o gargalo

Rodamos o mesmo servidor e cliente em loopback (`127.0.0.1`, sem placa de rede no meio), num Mac, com 1 cliente, 5 s e bloco de 64 KiB:

```
BENCH clients=1 bytes=31691898880 seconds=5.000 mbps=50708.19
```

Deu uns **50 Gbit/s**, mais de 50 vezes o que medimos entre os PCs. Esse número não é resultado do trabalho. Serve só para mostrar que o código aguenta muito mais do que 1 Gbit/s.

## Hardware de rede

Verificado no PC 1, na interface `eno1`, sem precisar de root:

```bash
cat /sys/class/net/eno1/speed    # 1000
cat /sys/class/net/eno1/duplex   # full
/usr/sbin/ethtool eno1           # maior "Supported link mode": 1000baseT/Full
```

A placa do PC 1 só suporta até 1 Gbit/s, e o link foi negociado em 1000 Mbit/s full-duplex. Isso já limita o caminho inteiro a 1 Gbit/s, seja qual for o PC 2, o switch ou o cabo.

Ainda falta, para a ficha das máquinas:

- [ ] Modelo da placa de rede de cada PC: `lspci | grep -i ethernet`.
- [ ] Nome da interface do PC 2 (`ip -br link`) e os mesmos comandos acima nele.
- [ ] Ligação direta entre os PCs ou via switch? Se for via switch, o modelo dele.
- [ ] Categoria do cabo (vem impressa nele, ex.: Cat5e, Cat6).
- [ ] CPU, memória e sistema operacional de cada PC: `lscpu`, `free -h`, `cat /etc/os-release`.
- [ ] Qual PC foi o servidor e qual rodou os clientes.
- [ ] (Opcional) Rodar `iperf3 -s` num PC e `iperf3 -c <IP>` no outro. Deve dar uns 940 Mbit/s também, o que reforça que o limite é a rede.

## Sugestão de estrutura

1. **Introdução:** o chat TCP da aula e o modo `/bench` (ver `README.md`).
2. **Metodologia:** como o servidor mede (do primeiro ao último byte, somando todas as threads), o `run_bench.sh`, a largada sincronizada com `--start-at` e os parâmetros da bateria.
3. **Ambiente:** a ficha das máquinas e da rede (lista acima).
4. **Resultados:** a tabela, um gráfico de clientes × Mbit/s com barras de desvio e uma linha horizontal no teto teórico de 941 Mbit/s, e um gráfico ou tabela da divisão por cliente (`BENCH_CLIENT`).
5. **Discussão:** o gargalo é o enlace de 1 Gbit/s (com a conta do overhead e o teste de loopback), a divisão da banda entre clientes e a rodada desigual com 5 clientes.
6. **Conclusão:** o servidor satura o Gigabit Ethernet já com 1 cliente. Para medir o limite do servidor em si, seria preciso uma rede de 2,5 ou 10 Gbit/s. Jumbo frames (MTU 9000) subiriam o teto só para uns 990 Mbit/s.

Frase pronta para a conclusão, se ajudar:

> O throughput agregado ficou estável em cerca de 934 Mbit/s (≈117 MB/s) de 1 a 10 clientes, o que corresponde a uns 99% do máximo teórico de TCP sobre Gigabit Ethernet com MTU 1500 (≈941 Mbit/s). O gargalo é o enlace de 1 Gbit/s, e não o servidor: em loopback, o mesmo código passou de 50 Gbit/s. Aumentar o número de clientes só divide a mesma banda entre as conexões.
