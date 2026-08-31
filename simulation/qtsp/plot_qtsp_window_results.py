#!/usr/bin/env python3
"""Plot QTSP window-update results.

This parses the pipe-delimited window-update table written by
run_qtsp_window_update.jl and plots observed throughput, update steps,
window size, and Werner parameter.
"""

from __future__ import annotations

import argparse
import os
import re
import warnings
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", "/tmp/matplotlib-qtsp")
warnings.filterwarnings("ignore", message="Unable to import Axes3D.*")

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_TARGET_THROUGHPUT = 2.4
DEFAULT_WIDE = True


def set_iteration_xlim(ax, iterations: list[float]) -> None:
    first = iterations[0]
    last = iterations[-1]
    if first == last:
        ax.set_xlim(first - 0.5, last + 0.5)
    else:
        ax.set_xlim(first, last)


def parse_qtsp_window_update_table(path: Path) -> dict[str, list[float]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    header_index = next(
        (index for index, line in enumerate(lines) if re.match(r"^\s*iter\s*\|", line)),
        None,
    )
    if header_index is None:
        raise ValueError(f"Could not find the window-update table header in {path}.")

    header = [cell.strip() for cell in lines[header_index].split("|")]
    if "iter" not in header:
        raise ValueError("The table must contain an iter column.")

    table: dict[str, list[float]] = {column: [] for column in header}
    for line in lines[header_index + 1 :]:
        stripped = line.strip()
        if not stripped or stripped.startswith("-") or "|" not in line:
            continue

        cells = [cell.strip() for cell in line.split("|")]
        if len(cells) != len(header):
            continue

        try:
            values = [
                int(cell) if column == "iter" else float(cell)
                for column, cell in zip(header, cells)
            ]
        except ValueError:
            print(f"Skipping non-data table row: {line}")
            continue

        for column, value in zip(header, values):
            table[column].append(value)

    if not table["iter"]:
        raise ValueError(f"No data rows were parsed from {path}.")

    return table


def parse_target_throughput(path: Path) -> float | None:
    pattern = re.compile(r"^\s*target_tp\s*=\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)")
    for line in path.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            return float(match.group(1))
    return None


def plot_qtsp_throughput(
    table: dict[str, list[float]],
    output_path: Path,
    *,
    target_throughput: float = DEFAULT_TARGET_THROUGHPUT,
    title: str = "QTSP throughput by update iteration",
    wide: bool = False,
) -> None:
    iterations = table["iter"]
    throughputs = table["tp"]
    figsize = (22, 6.5) if wide else (11, 6.5)
    fig, ax = plt.subplots(figsize=figsize, dpi=200)

    ax.plot(
        iterations,
        throughputs,
        color="steelblue",
        linewidth=1.25 if wide else 1.5,
        label="observed throughput",
    )
    ax.axhline(
        target_throughput,
        color="crimson",
        linestyle="--",
        linewidth=2.5,
        label=f"target throughput = {target_throughput:g}",
    )

    ax.set_xlabel("Iteration", fontsize=18)
    ax.set_ylabel("Throughput", fontsize=18)
    ax.set_title(title, fontsize=18)
    ax.grid(True)
    ax.tick_params(labelsize=14)
    set_iteration_xlim(ax, iterations)

    half_span = max(
        max(abs(value - target_throughput) for value in throughputs) * 1.08,
        target_throughput * 0.15,
        0.1,
    )
    ax.set_ylim(target_throughput - half_span, target_throughput + half_span)
    ax.legend(loc="upper right", fontsize=14)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(output_path)
    plt.close(fig)


def plot_qtsp_gamma_delta(
    table: dict[str, list[float]],
    output_path: Path,
    *,
    title: str = "QTSP gamma and delta by update iteration",
    wide: bool = False,
) -> None:
    figsize = (22, 6.5) if wide else (11, 6.5)
    fig, ax = plt.subplots(figsize=figsize, dpi=200)

    ax.plot(table["iter"], table["gamma"], color="darkgreen", linewidth=1.5, label="gamma")
    ax.plot(table["iter"], table["delta"], color="darkorange", linewidth=1.5, label="delta")
    ax.set_xlabel("Iteration", fontsize=18)
    ax.set_ylabel("Value", fontsize=18)
    ax.set_title(title, fontsize=18)
    ax.grid(True)
    ax.tick_params(labelsize=14)
    set_iteration_xlim(ax, table["iter"])
    ax.legend(loc="upper right", fontsize=14)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(output_path)
    plt.close(fig)


def plot_qtsp_window_size(
    table: dict[str, list[float]],
    output_path: Path,
    *,
    title: str = "QTSP window size by update iteration",
    wide: bool = False,
) -> None:
    figsize = (22, 6.5) if wide else (11, 6.5)
    fig, ax = plt.subplots(figsize=figsize, dpi=200)

    ax.step(table["iter"], table["W_run"], where="post", color="crimson", linewidth=1.5, label="W_run")
    ax.set_xlabel("Iteration", fontsize=18)
    ax.set_ylabel("Window size", fontsize=18)
    ax.set_title(title, fontsize=18)
    ax.grid(True)
    ax.tick_params(labelsize=14)
    set_iteration_xlim(ax, table["iter"])
    ax.legend(loc="upper left", fontsize=14)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(output_path)
    plt.close(fig)


def plot_qtsp_werner_parameter(
    table: dict[str, list[float]],
    output_path: Path,
    *,
    title: str = "QTSP Werner parameter by update iteration",
    wide: bool = False,
) -> None:
    figsize = (22, 6.5) if wide else (11, 6.5)
    fig, ax = plt.subplots(figsize=figsize, dpi=200)

    ax.plot(table["iter"], table["w"], color="steelblue", linewidth=1.5, label="w")
    ax.set_xlabel("Iteration", fontsize=18)
    ax.set_ylabel("Werner parameter", fontsize=18)
    ax.set_title(title, fontsize=18)
    ax.grid(True)
    ax.tick_params(labelsize=14)
    set_iteration_xlim(ax, table["iter"])
    ax.set_ylim(-0.05, 1.05)
    ax.legend(loc="upper right", fontsize=14)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(output_path)
    plt.close(fig)


def default_output_path(input_path: Path, kind: str, wide: bool) -> Path:
    suffix = f"_{kind}_wide.png" if wide else f"_{kind}.png"
    return input_path.with_name(input_path.stem + suffix)


def output_paths(input_path: Path, wide: bool) -> dict[str, Path]:
    return {
        "throughput": default_output_path(input_path, "throughput", wide),
        "gamma_delta": default_output_path(input_path, "gamma_delta", wide),
        "window_size": default_output_path(input_path, "window_size", wide),
        "werner_w": default_output_path(input_path, "werner_w", wide),
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Plot QTSP window-update metrics from a result file.",
    )
    parser.add_argument("input_path", type=Path, help="QTSP window-update result .txt file.")
    parser.add_argument("--target-throughput", type=float, help="Override the target throughput read from the result file.")
    parser.add_argument("--wide", action="store_true", dest="wide", help="Render a wide 4400x1300 PNG.")
    parser.add_argument("--compact", action="store_false", dest="wide", help="Render a compact 2200x1300 PNG.")
    parser.set_defaults(wide=DEFAULT_WIDE)
    args = parser.parse_args()

    paths = output_paths(args.input_path, args.wide)
    target_throughput = (
        args.target_throughput
        if args.target_throughput is not None
        else parse_target_throughput(args.input_path) or DEFAULT_TARGET_THROUGHPUT
    )

    table = parse_qtsp_window_update_table(args.input_path)
    plot_qtsp_throughput(
        table,
        paths["throughput"],
        target_throughput=target_throughput,
        title=f"QTSP throughput from {args.input_path.name}",
        wide=args.wide,
    )
    plot_qtsp_gamma_delta(
        table,
        paths["gamma_delta"],
        title=f"QTSP gamma and delta from {args.input_path.name}",
        wide=args.wide,
    )
    plot_qtsp_window_size(
        table,
        paths["window_size"],
        title=f"QTSP window size from {args.input_path.name}",
        wide=args.wide,
    )
    plot_qtsp_werner_parameter(
        table,
        paths["werner_w"],
        title=f"QTSP Werner parameter from {args.input_path.name}",
        wide=args.wide,
    )

    print(f"Parsed {len(table['iter'])} rows from {args.input_path}")
    for path in paths.values():
        print(f"Wrote {path}")


if __name__ == "__main__":
    main()
