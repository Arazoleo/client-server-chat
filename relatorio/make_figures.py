#!/usr/bin/env python3
"""Gera figuras e tabelas do relatorio a partir dos logs da bateria.

Entradas (em relatorio/dados/):
  summary.csv      saida de: ./run_bench.sh --summary server.log clients.log
  results.csv      saida de: ./run_bench.sh --csv server.log clients.log
  server.log       log do servidor (linhas BENCH_CLIENT: bytes por cliente)
  perfil/          rodadas isoladas com `vmstat 1` (vm_*.txt) e log do servidor (srv_*.log)

Saidas:
  relatorio/figuras/throughput.pdf, divisao.pdf
  relatorio/tabela_resultados.tex, tabela_divisao.tex, tabela_cpu.tex

Uso: python relatorio/make_figures.py
"""
import csv
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

AQUI = Path(__file__).resolve().parent
DADOS = AQUI / "dados"
FIGS = AQUI / "figuras"
AZUL, VERMELHO = "#1f4e9c", "#c0392b"


def pt(valor, casas=2):
    """Numero com virgula decimal e espaco fino como separador de milhar."""
    texto = f"{valor:,.{casas}f}"
    return texto.replace(",", "\\,").replace(".", ",")


def escrever_linhas(caminho, linhas):
    """Linhas de tabela separadas por '\\\\'. A ultima NAO leva '\\\\':
    o relatorio.tex a fecha depois do \\input."""
    with open(caminho, "w", encoding="utf-8", newline="\n") as f:
        # sem "\n" no fim: um espaco sobrando deslocaria a ultima celula
        f.write(" \\\\\n".join(linhas))


def ler_resumo(pasta=DADOS):
    with open(pasta / "summary.csv", newline="") as f:
        return [
            {
                "n": int(r["clients"]),
                "reps": int(r["reps"]),
                "media": float(r["mean_mbps"]),
                "desvio": float(r["stddev_mbps"]),
                "min": float(r["min_mbps"]),
                "max": float(r["max_mbps"]),
            }
            for r in csv.DictReader(f)
        ]


def ler_rodadas(pasta=DADOS):
    """Mbit/s de cada repeticao, por numero de clientes."""
    por_n = defaultdict(list)
    with open(pasta / "results.csv", newline="") as f:
        for r in csv.DictReader(f):
            por_n[int(r["clients"])].append(float(r["mbps"]))
    return por_n


def figura_throughput(res, rodadas):
    ns = [r["n"] for r in res]
    medias = [r["media"] / 1000 for r in res]
    erros = [r["desvio"] / 1000 for r in res]

    fig, ax = plt.subplots(figsize=(7.5, 4.2), constrained_layout=True)
    for n in ns:
        ax.scatter([n] * len(rodadas[n]), [v / 1000 for v in rodadas[n]], s=16,
                   color="#8aa4d6", zorder=2,
                   label="Cada repetição" if n == ns[0] else None)
    ax.errorbar(ns, medias, yerr=erros, fmt="o-", color=AZUL, capsize=3, zorder=3,
                label="Média ± desvio padrão (5 repetições)")
    ax.set_xticks(ns)
    ax.set_xlabel("Clientes simultâneos")
    ax.set_ylabel("Throughput agregado (Gbit/s)")
    ax.set_ylim(bottom=0)
    ax.grid(alpha=0.3)
    ax.legend(loc="upper right", fontsize=9)
    fig.savefig(FIGS / "throughput.pdf")
    fig.savefig(FIGS / "throughput.png", dpi=150)
    plt.close(fig)


def tabela_principal(res):
    base = res[0]["media"]
    linhas = []
    for r in res:
        linhas.append(
            f"{r['n']} & {pt(r['media'])} & {pt(r['desvio'])} & {pt(r['min'])} & "
            f"{pt(r['max'])} & {pt(r['media'] / 8000, 2)} & "
            f"{pt(r['media'] / r['n'], 0)} & {pt(r['media'] / base, 2)}"
        )
    escrever_linhas(AQUI / "tabela_resultados.tex", linhas)


def ler_bytes_por_cliente(caminho):
    """Lista de (clientes, [bytes de cada cliente]) por rodada.

    O servidor imprime as BENCH_CLIENT de uma rodada e fecha com a linha
    BENCH clients=...; as pendentes pertencem a proxima linha BENCH.
    """
    rodadas, pendentes = [], []
    for linha in Path(caminho).read_text(encoding="utf-8", errors="replace").splitlines():
        if linha.startswith("BENCH_CLIENT "):
            campos = dict(p.split("=", 1) for p in linha.split()[1:])
            pendentes.append(int(campos["bytes"]))
        elif linha.startswith("BENCH clients="):
            campos = dict(p.split("=", 1) for p in linha.split()[1:])
            rodadas.append((int(campos["clients"]), pendentes))
            pendentes = []
    return rodadas


def jain(valores):
    soma = sum(valores)
    return soma * soma / (len(valores) * sum(v * v for v in valores))


def figura_e_tabela_divisao(caminho):
    por_n = defaultdict(list)
    for n, bytes_clientes in ler_bytes_por_cliente(caminho):
        por_n[n].append(bytes_clientes)

    fig, ax = plt.subplots(figsize=(7.5, 4.2), constrained_layout=True)
    linhas = []
    for n in sorted(por_n):
        todas = por_n[n]
        medias = [sum(r) / len(r) / 1e9 for r in todas]
        for r in todas:
            ax.scatter([n] * len(r), [b / 1e9 for b in r], s=12, alpha=0.5,
                       color=AZUL, zorder=3)
        ax.scatter([n], [statistics.mean(medias)], marker="_", s=300,
                   color=VERMELHO, zorder=4)
        indices = [jain(r) for r in todas]
        razao = [max(r) / min(r) for r in todas if min(r) > 0]
        linhas.append(
            f"{n} & {len(todas)} & {pt(statistics.mean(medias), 1)} & "
            f"{pt(min(indices), 3)} & {pt(max(razao), 2)}"
        )
    ax.set_xticks(sorted(por_n))
    ax.set_xlabel("Clientes simultâneos")
    ax.set_ylabel("Dados recebidos por cliente (GB)")
    ax.set_yscale("log")
    ax.grid(alpha=0.3, which="both")
    fig.savefig(FIGS / "divisao.pdf")
    fig.savefig(FIGS / "divisao.png", dpi=150)
    plt.close(fig)
    escrever_linhas(AQUI / "tabela_divisao.tex", linhas)


def tabela_cpu():
    """CPU (vmstat) nas amostras em que a maquina esta ocupada, por rodada isolada."""
    pasta = DADOS / "perfil"
    linhas = []
    ordem = lambda p: (int(p.stem.split("_")[1][1:]), p.stem)  # noqa: E731
    for vm in sorted(pasta.glob("vm_a*.txt"), key=ordem):
        tag = vm.stem.split("_", 1)[1]
        srv = pasta / f"srv_{tag}.log"
        bench = next((l for l in srv.read_text().splitlines()
                      if l.startswith("BENCH clients=")), None)
        if bench is None:
            continue
        campos = dict(p.split("=", 1) for p in bench.split()[1:])
        linhas_vm = vm.read_text().splitlines()
        cabecalho = linhas_vm[1].split()
        col = {nome: i for i, nome in enumerate(cabecalho)}
        amostras = []
        for l in linhas_vm[2:]:
            v = l.split()
            if len(v) == len(cabecalho) and int(v[col["us"]]) + int(v[col["sy"]]) > 5:
                amostras.append(v)
        if not amostras:
            continue
        media = lambda nome: statistics.mean(int(v[col[nome]]) for v in amostras)  # noqa: E731
        linhas.append(
            f"{campos['clients']} & {pt(float(campos['mbps']), 0)} & {len(amostras)} & "
            f"{pt(media('us'), 1)} & {pt(media('sy'), 1)} & {pt(media('id'), 1)}"
        )
    escrever_linhas(AQUI / "tabela_cpu.tex", linhas)
    return len(linhas)


# Cenarios em rede simulada (tc tbf): nome da pasta, taxa em Mbit/s, rotulo.
CENARIOS_SIM = [("sim_1gbit", 1000.0, "1 Gbit/s"), ("sim_100mbit", 100.0, "100 Mbit/s")]


def cenario_simulado(nome, taxa):
    pasta = DADOS / nome
    res = ler_resumo(pasta)
    por_n = defaultdict(list)
    for n, bytes_clientes in ler_bytes_por_cliente(pasta / "server.log"):
        por_n[n].append(bytes_clientes)
    linhas = []
    for r in res:
        todas = por_n[r["n"]]
        razao = [max(x) / min(x) for x in todas if min(x) > 0]
        linhas.append(
            f"{r['n']} & {pt(r['media'])} & {pt(r['desvio'])} & {pt(r['min'])} & "
            f"{pt(r['max'])} & {pt(r['media'] / r['n'], 1)} & {pt(max(razao), 2)}"
        )
    escrever_linhas(AQUI / f"tabela_{nome}.tex", linhas)
    return res, ler_rodadas(pasta)


def figura_simulada():
    fig, eixos = plt.subplots(1, 2, figsize=(10, 3.8), constrained_layout=True)
    for ax, (nome, taxa, rotulo) in zip(eixos, CENARIOS_SIM):
        res, rodadas = cenario_simulado(nome, taxa)
        ns = [r["n"] for r in res]
        for n in ns:
            ax.scatter([n] * len(rodadas[n]), rodadas[n], s=14, color="#8aa4d6", zorder=2)
        ax.errorbar(ns, [r["media"] for r in res], yerr=[r["desvio"] for r in res],
                    fmt="o-", color=AZUL, capsize=3, zorder=3, label="Média ± desvio (5 rep.)")
        ax.axhline(taxa, color="#555555", ls=":", lw=1.2, label=f"Taxa configurada ({rotulo})")
        ax.set_ylim(0, taxa * 1.12)
        ax.set_xticks(ns)
        ax.set_xlabel("Clientes simultâneos")
        ax.set_ylabel("Throughput agregado (Mbit/s)")
        ax.set_title(f"Enlace simulado de {rotulo}")
        ax.grid(alpha=0.3)
        ax.legend(loc="lower right", fontsize=8)
    fig.savefig(FIGS / "throughput_simulado.pdf")
    fig.savefig(FIGS / "throughput_simulado.png", dpi=150)
    plt.close(fig)


def figura_e_tabela_repeticao():
    """Compara a bateria principal (dados/) com a repeticao (dados/rep2/)."""
    b1, b2 = ler_resumo(DADOS), ler_resumo(DADOS / "rep2")
    rod1, rod2 = ler_rodadas(DADOS), ler_rodadas(DADOS / "rep2")
    fig, ax = plt.subplots(figsize=(7.5, 4.2), constrained_layout=True)
    linhas = []
    for (r1, r2, cor, rotulo, desl, rod) in (
        (b1, None, AZUL, "Bateria principal", -0.08, rod1),
        (b2, None, VERMELHO, "Repetição", 0.08, rod2),
    ):
        ns = [r["n"] for r in r1]
        for n in ns:
            ax.scatter([n + desl] * len(rod[n]), [v / 1000 for v in rod[n]], s=10,
                       color=cor, alpha=0.35, zorder=2)
        ax.errorbar([n + desl for n in ns], [r["media"] / 1000 for r in r1],
                    yerr=[r["desvio"] / 1000 for r in r1], fmt="o-", color=cor,
                    capsize=3, ms=4, zorder=3, label=rotulo)
    for r1, r2 in zip(b1, b2):
        diff = 100 * (r2["media"] - r1["media"]) / r1["media"]
        sinal = "+" if diff > 0 else "$-$"
        linhas.append(
            f"{r1['n']} & {pt(r1['media'] / 1000, 1)} & {pt(r1['desvio'] / 1000, 1)} & "
            f"{pt(r2['media'] / 1000, 1)} & {pt(r2['desvio'] / 1000, 1)} & "
            f"{sinal}{pt(abs(diff), 1)}"
        )
    ax.set_xticks([r["n"] for r in b1])
    ax.set_xlabel("Clientes simultâneos")
    ax.set_ylabel("Throughput agregado (Gbit/s)")
    ax.set_ylim(bottom=0)
    ax.grid(alpha=0.3)
    ax.legend(loc="upper right", fontsize=9)
    fig.savefig(FIGS / "throughput_repeticao.pdf")
    fig.savefig(FIGS / "throughput_repeticao.png", dpi=150)
    plt.close(fig)
    escrever_linhas(AQUI / "tabela_repeticao.tex", linhas)


def main():
    FIGS.mkdir(exist_ok=True)
    figura_e_tabela_repeticao()
    print("throughput_repeticao.pdf e tabela_repeticao.tex gerados")
    figura_simulada()
    print("throughput_simulado.pdf e tabela_sim_*.tex gerados")
    res = ler_resumo()
    figura_throughput(res, ler_rodadas())
    tabela_principal(res)
    print(f"throughput.pdf e tabela_resultados.tex gerados ({len(res)} quantidades de clientes)")
    figura_e_tabela_divisao(DADOS / "server.log")
    print("divisao.pdf e tabela_divisao.tex gerados")
    print(f"tabela_cpu.tex gerada com {tabela_cpu()} rodadas")


if __name__ == "__main__":
    main()
