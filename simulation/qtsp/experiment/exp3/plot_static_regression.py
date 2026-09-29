#!/usr/bin/env python3
"""Plot the grouped output of exp3/run_static_regression.jl."""

from __future__ import annotations

import argparse
import csv
import os
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", "/tmp/matplotlib-qtsp")

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


def read_grid(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if not rows:
        raise ValueError(f"No rows found in {path}")
    return rows


def plot_surface3d(
    matrix: list[list[float]],
    windows: list[int],
    werner: list[float],
    output_dir: Path,
) -> None:
    """Write a 3-D surface, using Plotly HTML if mplot3d is unavailable."""
    w_grid, window_grid = np.meshgrid(werner, windows)
    z_grid = np.asarray(matrix, dtype=float)

    try:
        # Importing this registers Matplotlib's ``3d`` projection.
        from mpl_toolkits.mplot3d import Axes3D  # noqa: F401

        fig = plt.figure(figsize=(11, 8), dpi=200)
        ax = fig.add_subplot(111, projection="3d")
        surface = ax.plot_surface(
            w_grid,
            window_grid,
            z_grid,
            cmap="viridis",
            linewidth=0,
            antialiased=True,
            alpha=0.88,
        )
        ax.scatter(
            w_grid.ravel(),
            window_grid.ravel(),
            z_grid.ravel(),
            color="black",
            s=9,
            alpha=0.55,
        )
        ax.set_xlabel("Werner parameter w", labelpad=10)
        ax.set_ylabel("Window size W", labelpad=10)
        ax.set_zlabel("Mean ACK throughput", labelpad=10)
        ax.set_title("Static QTSP throughput response surface")
        ax.view_init(elev=27, azim=-125)
        fig.colorbar(surface, ax=ax, shrink=0.62, pad=0.12,
                     label="Mean ACK throughput")
        fig.tight_layout()
        fig.savefig(output_dir / "static_regression_surface3d.png")
        plt.close(fig)
        return
    except (ImportError, ModuleNotFoundError, RuntimeError, ValueError) as error:
        print(f"Matplotlib 3-D unavailable ({error}); writing Plotly HTML instead.")

    try:
        import plotly.graph_objects as go

        figure = go.Figure(data=[go.Surface(
            x=werner,
            y=windows,
            z=z_grid,
            colorscale="Viridis",
            colorbar={"title": "Mean ACK throughput"},
        )])
        figure.update_layout(
            title="Static QTSP throughput response surface",
            scene={
                "xaxis_title": "Werner parameter w",
                "yaxis_title": "Window size W",
                "zaxis_title": "Mean ACK throughput",
            },
        )
        figure.write_html(
            output_dir / "static_regression_surface3d.html",
            include_plotlyjs=True,
        )
    except ImportError as error:
        raise RuntimeError(
            "Neither Matplotlib 3-D nor Plotly is available for the surface plot."
        ) from error


def plot_grid(rows: list[dict[str, str]], output_dir: Path) -> None:
    windows = sorted({int(row["window_size"]) for row in rows})
    werner = sorted({float(row["werner_w"]) for row in rows})
    values = {
        (int(row["window_size"]), float(row["werner_w"])):
        float(row["mean_acked_throughput"])
        for row in rows
    }

    matrix = [[values[(window, w)] for w in werner] for window in windows]
    fig, ax = plt.subplots(figsize=(11, 7), dpi=200)
    image = ax.imshow(matrix, origin="lower", aspect="auto", cmap="viridis")
    ax.set_xticks(range(len(werner)), [f"{w:.2f}" for w in werner], rotation=45)
    ax.set_yticks(range(len(windows)), [str(window) for window in windows])
    ax.set_xlabel("Werner parameter w")
    ax.set_ylabel("Window size W")
    ax.set_title("Static QTSP ACK-throughput regression")
    fig.colorbar(image, ax=ax, label="Mean ACK throughput")
    fig.tight_layout()
    fig.savefig(output_dir / "static_regression_heatmap.png")
    plt.close(fig)

    # The static regression is a response surface: (W, w) -> throughput.
    # Keep this as a separate figure so the 2-D heatmap remains easy to read.
    plot_surface3d(matrix, windows, werner, output_dir)

    fig, axes = plt.subplots(1, 2, figsize=(14, 5.5), dpi=200)
    for window in windows:
        selected = [row for row in rows if int(row["window_size"]) == window]
        selected.sort(key=lambda row: float(row["werner_w"]))
        x = [float(row["werner_w"]) for row in selected]
        y = [float(row["mean_acked_throughput"]) for row in selected]
        error = [float(row["std_acked_throughput"]) for row in selected]
        axes[0].errorbar(x, y, yerr=error, marker="o", capsize=2,
                         linewidth=1, label=f"W={window}")

    axes[0].set_xlabel("Werner parameter w")
    axes[0].set_ylabel("Mean ACK throughput")
    axes[0].set_title("Throughput versus w")
    axes[0].grid(alpha=0.25)
    axes[0].legend(ncol=2, fontsize=8)

    selected_w = werner
    for w in selected_w:
        selected = [row for row in rows if float(row["werner_w"]) == w]
        selected.sort(key=lambda row: int(row["window_size"]))
        x = [int(row["window_size"]) for row in selected]
        y = [float(row["mean_acked_throughput"]) for row in selected]
        axes[1].plot(x, y, marker="o", linewidth=1, label=f"w={w:.2f}")

    axes[1].set_xlabel("Window size W")
    axes[1].set_ylabel("Mean ACK throughput")
    axes[1].set_title("Throughput versus W")
    axes[1].set_xticks(windows)
    axes[1].grid(alpha=0.25)
    axes[1].legend(ncol=2, fontsize=8)
    fig.tight_layout()
    fig.savefig(output_dir / "static_regression_slices.png")
    plt.close(fig)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path,
                        help="exp3 batch directory or static_regression_grid.tsv")
    args = parser.parse_args()
    grid = args.path if args.path.is_file() else args.path / "static_regression_grid.tsv"
    output_dir = grid.parent
    plot_grid(read_grid(grid), output_dir)
    print(f"wrote plots next to {grid}")


if __name__ == "__main__":
    main()
