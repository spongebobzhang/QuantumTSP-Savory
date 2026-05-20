#!/usr/bin/env python3
"""Plot QTSP window-update throughput results.

This is the Python equivalent of plot_qtsp_throughput.jl. It parses the
pipe-delimited window-update table in result*.txt files and plots the observed
throughput against update iteration.
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
DEFAULT_RESULT_PATH = SCRIPT_DIR / "result1.txt"
DEFAULT_OUTPUT_PATH = SCRIPT_DIR / "result1_throughput.png"
DEFAULT_TARGET_THROUGHPUT = 2.4


def parse_qtsp_window_update_table(path: Path) -> tuple[list[int], list[float]]:
    lines = path.read_text().splitlines()
    header_index = next(
        (index for index, line in enumerate(lines) if re.match(r"^\s*iter\s*\|", line)),
        None,
    )
    if header_index is None:
        raise ValueError(f"Could not find the window-update table header in {path}.")

    header = [cell.strip() for cell in lines[header_index].split("|")]
    try:
        iter_column = header.index("iter")
        tp_column = header.index("tp")
    except ValueError as err:
        raise ValueError("The table must contain both iter and tp columns.") from err

    iterations: list[int] = []
    throughputs: list[float] = []
    for line in lines[header_index + 1 :]:
        stripped = line.strip()
        if not stripped or stripped.startswith("-") or "|" not in line:
            continue

        cells = [cell.strip() for cell in line.split("|")]
        if len(cells) <= max(iter_column, tp_column):
            continue

        try:
            iterations.append(int(cells[iter_column]))
            throughputs.append(float(cells[tp_column]))
        except ValueError:
            print(f"Skipping non-data table row: {line}")

    if not iterations:
        raise ValueError(f"No throughput rows were parsed from {path}.")

    return iterations, throughputs


def parse_target_throughput(path: Path) -> float | None:
    pattern = re.compile(r"^\s*target_tp\s*=\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)")
    for line in path.read_text().splitlines():
        match = pattern.match(line)
        if match:
            return float(match.group(1))
    return None


def plot_qtsp_throughput(
    iterations: list[int],
    throughputs: list[float],
    output_path: Path,
    *,
    target_throughput: float = DEFAULT_TARGET_THROUGHPUT,
    title: str = "QTSP throughput by update iteration",
    wide: bool = False,
) -> None:
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
    ax.set_xlim(iterations[0], iterations[-1])

    half_span = max(
        max(abs(value - target_throughput) for value in throughputs) * 1.08,
        target_throughput * 0.15,
        0.1,
    )
    ax.set_ylim(target_throughput - half_span, target_throughput + half_span)
    ax.legend(loc="upper right", fontsize=14)

    fig.tight_layout()
    fig.savefig(output_path)
    plt.close(fig)


def default_output_path(input_path: Path, wide: bool) -> Path:
    if input_path == DEFAULT_RESULT_PATH:
        return SCRIPT_DIR / ("result1_throughput_wide.png" if wide else "result1_throughput.png")
    suffix = "_throughput_wide.png" if wide else "_throughput.png"
    return input_path.with_name(input_path.stem + suffix)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Plot QTSP observed throughput from a window-update result file.",
    )
    parser.add_argument("input_path", nargs="?", type=Path, default=DEFAULT_RESULT_PATH)
    parser.add_argument("output_path", nargs="?", type=Path)
    parser.add_argument("target_throughput", nargs="?", type=float)
    parser.add_argument("--wide", action="store_true", help="Render a wide 4400x1300 PNG.")
    args = parser.parse_args()

    output_path = args.output_path or default_output_path(args.input_path, args.wide)
    target_throughput = (
        args.target_throughput
        if args.target_throughput is not None
        else parse_target_throughput(args.input_path) or DEFAULT_TARGET_THROUGHPUT
    )

    iterations, throughputs = parse_qtsp_window_update_table(args.input_path)
    plot_qtsp_throughput(
        iterations,
        throughputs,
        output_path,
        target_throughput=target_throughput,
        title=f"QTSP throughput from {args.input_path.name}",
        wide=args.wide,
    )

    print(f"Parsed {len(iterations)} rows from {args.input_path}")
    print(f"Wrote {output_path}")


if __name__ == "__main__":
    main()
