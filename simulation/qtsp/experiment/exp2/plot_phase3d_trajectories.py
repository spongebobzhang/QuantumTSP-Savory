#!/usr/bin/env python3
"""Plot 3D QTSP phase trajectories for exp2 results.

Each run is plotted as an ordered line in (w, W_run, tp). Runs are also grouped
by batch id and overlaid so different initial Werner parameters can be compared.
"""

from __future__ import annotations

import argparse
import os
import re
import site
import warnings
from collections import defaultdict
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", "/tmp/matplotlib-qtsp")
warnings.filterwarnings("ignore", message="Unable to import Axes3D.*")

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import mpl_toolkits
from matplotlib.ticker import MaxNLocator

USER_MPL_TOOLKITS = Path(site.getusersitepackages()) / "mpl_toolkits"
if USER_MPL_TOOLKITS.exists():
    mpl_toolkits.__path__ = [
        str(USER_MPL_TOOLKITS),
        *[path for path in mpl_toolkits.__path__ if path != str(USER_MPL_TOOLKITS)],
    ]
from mpl_toolkits.mplot3d import Axes3D  # noqa: F401 - registers the 3D projection
from matplotlib.projections import register_projection

register_projection(Axes3D)


DEFAULT_RESULT_DIR = Path(__file__).resolve().parent / "result" / "result1"


def parse_window_update_table(path: Path) -> dict[str, list[float]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    header_index = next(
        (index for index, line in enumerate(lines) if re.match(r"^\s*iter\s*\|", line)),
        None,
    )
    if header_index is None:
        raise ValueError(f"Could not find window-update table header in {path}.")

    header = [cell.strip() for cell in lines[header_index].split("|")]
    required = {"iter", "w", "W_run", "tp"}
    missing = required.difference(header)
    if missing:
        raise ValueError(f"{path} is missing columns: {', '.join(sorted(missing))}")

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
                int(cell) if column in {"iter", "W_run", "Wrun_n", "sent", "acked", "timeout"}
                else float(cell)
                for column, cell in zip(header, cells)
            ]
        except ValueError:
            continue
        for column, value in zip(header, values):
            table[column].append(value)

    if not table["iter"]:
        raise ValueError(f"No data rows were parsed from {path}.")

    return table


def read_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        if " = " not in line:
            continue
        key, value = line.split(" = ", 1)
        values[key.strip()] = value.strip()
    return values


def parse_batch_id(run_dir: Path) -> str:
    match = re.match(r"(.+)_run_\d{3}_", run_dir.name)
    if match:
        return match.group(1)
    return "unknown_batch"


def parse_run_index(run_dir: Path) -> str:
    match = re.search(r"_run_(\d{3})_", run_dir.name)
    return match.group(1) if match else "?"


def parse_initial_w(run_dir: Path) -> float | None:
    config = read_key_values(run_dir / "config.txt")
    if "initial_werner_w" in config:
        return float(config["initial_werner_w"])

    match = re.search(r"_w_([0-9]+p[0-9]+)", run_dir.name)
    if match:
        return float(match.group(1).replace("p", "."))
    return None


def parse_target_tp(run_dir: Path) -> float | None:
    config = read_key_values(run_dir / "config.txt")
    if "target_tp" in config:
        return float(config["target_tp"])
    return None


def set_common_axes(ax, title: str, *, title_fontsize: int = 14) -> None:
    ax.set_title(title, fontsize=title_fontsize)
    ax.set_xlabel("w", labelpad=9)
    ax.set_ylabel("W_run", labelpad=9)
    ax.set_zlabel("Throughput", labelpad=9)
    ax.set_xlim(0.0, 1.0)
    ax.yaxis.set_major_locator(MaxNLocator(integer=True))
    ax.grid(True, alpha=0.35)
    ax.view_init(elev=24, azim=35)


def draw_target_tp_reference(ax, table: dict[str, list[float]],
        target_tp: float | None) -> None:
    if target_tp is None:
        return

    w_min = min(table["w"])
    w_max = max(table["w"])
    for window in sorted(set(table["W_run"])):
        ax.plot(
            [w_min, w_max],
            [window, window],
            [target_tp, target_tp],
            color="crimson",
            linestyle="--",
            linewidth=0.85,
            alpha=0.28,
        )


def phase_point_text(label: str, table: dict[str, list[float]], index: int) -> str:
    return (
        f"{label}: "
        f"(w={table['w'][index]:.4f}, "
        f"W={table['W_run'][index]:g}, "
        f"tp={table['tp'][index]:.4f})"
    )


def sampled_table(table: dict[str, list[float]], sample_step: int) -> dict[str, list[float]]:
    sample_step > 0 or (_ for _ in ()).throw(ValueError("sample_step must be positive."))
    row_count = len(table["iter"])
    selected = {0, row_count - 1}

    for index, iteration in enumerate(table["iter"]):
        if iteration % sample_step == 0:
            selected.add(index)

    indices = sorted(selected)
    return {
        column: [values[index] for index in indices]
        for column, values in table.items()
    }


def plot_integer_window_trajectory(ax, table: dict[str, list[float]], *,
        color, linewidth, alpha, label: str | None = None) -> None:
    ax.plot(
        table["w"],
        table["W_run"],
        table["tp"],
        color=color,
        linewidth=linewidth,
        alpha=alpha,
        marker="o",
        markersize=1.15,
        markeredgewidth=0.0,
        label=label,
    )


def mark_endpoint(ax, table: dict[str, list[float]], index: int, *,
        label: str, color: str) -> None:
    ax.scatter(
        [table["w"][index]],
        [table["W_run"][index]],
        [table["tp"][index]],
        color=color,
        edgecolor="black",
        linewidth=0.65,
        s=74,
        depthshade=True,
        zorder=10,
    )
    ax.text(
        table["w"][index],
        table["W_run"][index],
        table["tp"][index],
        "  " + label,
        color=color,
        fontsize=10,
        weight="bold",
        zorder=11,
    )


def merged_tables(tables: list[dict[str, list[float]]]) -> dict[str, list[float]]:
    if not tables:
        return {}

    columns = tables[0].keys()
    return {
        column: [
            value
            for table in tables
            for value in table[column]
        ]
        for column in columns
    }


def plot_start_end_arrow(ax, table: dict[str, list[float]], *,
        color, label: str) -> None:
    start = (
        table["w"][0],
        table["W_run"][0],
        table["tp"][0],
    )
    end = (
        table["w"][-1],
        table["W_run"][-1],
        table["tp"][-1],
    )

    ax.plot(
        [start[0], end[0]],
        [start[1], end[1]],
        [start[2], end[2]],
        color=color,
        linestyle="--",
        linewidth=1.15,
        alpha=0.92,
        label=label,
    )

    dx = end[0] - start[0]
    dy = end[1] - start[1]
    dz = end[2] - start[2]
    if abs(dx) + abs(dy) + abs(dz) > 1e-12:
        arrow_fraction = 0.10
        ax.quiver(
            end[0] - arrow_fraction * dx,
            end[1] - arrow_fraction * dy,
            end[2] - arrow_fraction * dz,
            arrow_fraction * dx,
            arrow_fraction * dy,
            arrow_fraction * dz,
            color=color,
            linewidth=0.75,
            arrow_length_ratio=0.28,
            normalize=False,
            alpha=0.92,
        )

    ax.scatter(
        [start[0]],
        [start[1]],
        [start[2]],
        marker="o",
        color="darkgreen",
        edgecolor="black",
        linewidth=0.45,
        s=45,
        depthshade=True,
        zorder=10,
    )
    ax.scatter(
        [end[0]],
        [end[1]],
        [end[2]],
        marker="^",
        color="crimson",
        edgecolor="black",
        linewidth=0.45,
        s=58,
        depthshade=True,
        zorder=11,
    )


def plot_single_run(result_file: Path, output_path: Path) -> None:
    table = parse_window_update_table(result_file)
    run_dir = result_file.parent
    initial_w = parse_initial_w(run_dir)
    target_tp = parse_target_tp(run_dir)

    fig = plt.figure(figsize=(10, 8), dpi=200)
    ax = fig.add_subplot(111, projection="3d")

    plot_integer_window_trajectory(ax, table,
        color="steelblue", linewidth=1.35, alpha=0.95)
    draw_target_tp_reference(ax, table, target_tp)

    initial_text = "" if initial_w is None else f", initial w = {initial_w:.4f}"
    set_common_axes(ax,
        f"3D phase trajectory run {parse_run_index(run_dir)}{initial_text}")
    ax.text2D(
        0.03,
        0.94,
        ("" if target_tp is None else f"target tp = {target_tp:g}\n") +
        phase_point_text("start", table, 0) + "\n" +
        phase_point_text("end", table, -1),
        transform=ax.transAxes,
        fontsize=9,
        verticalalignment="top",
        bbox={"boxstyle": "round,pad=0.35", "facecolor": "white",
              "edgecolor": "0.75", "alpha": 0.82},
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(output_path)
    plt.close(fig)


def plot_sampled_single_run(result_file: Path, output_path: Path, *,
        sample_step: int) -> None:
    full_table = parse_window_update_table(result_file)
    table = sampled_table(full_table, sample_step)
    run_dir = result_file.parent
    initial_w = parse_initial_w(run_dir)
    target_tp = parse_target_tp(run_dir)

    fig = plt.figure(figsize=(10, 8), dpi=200)
    ax = fig.add_subplot(111, projection="3d")

    ax.plot(
        table["w"],
        table["W_run"],
        table["tp"],
        color="steelblue",
        linewidth=1.55,
        alpha=0.88,
        marker="o",
        markersize=3.2,
        markerfacecolor="white",
        markeredgecolor="steelblue",
        markeredgewidth=0.75,
    )
    draw_target_tp_reference(ax, table, target_tp)
    mark_endpoint(ax, table, 0, label="START", color="darkgreen")
    mark_endpoint(ax, table, -1, label="END", color="crimson")

    initial_text = "" if initial_w is None else f", initial w = {initial_w:.4f}"
    set_common_axes(ax,
        f"3D sampled trajectory run {parse_run_index(run_dir)}{initial_text}")
    ax.text2D(
        0.03,
        0.94,
        ("" if target_tp is None else f"target tp = {target_tp:g}\n") +
        f"sample step = {sample_step} iterations\n" +
        phase_point_text("start", table, 0) + "\n" +
        phase_point_text("end", table, -1),
        transform=ax.transAxes,
        fontsize=9,
        verticalalignment="top",
        bbox={"boxstyle": "round,pad=0.35", "facecolor": "white",
              "edgecolor": "0.75", "alpha": 0.86},
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(output_path)
    plt.close(fig)


def plot_overlay(result_files: list[Path], output_path: Path, batch_id: str) -> None:
    fig = plt.figure(figsize=(11.5, 8.5), dpi=200)
    ax = fig.add_subplot(111, projection="3d")
    cmap = plt.get_cmap("tab10")

    for index, result_file in enumerate(sorted(result_files)):
        table = parse_window_update_table(result_file)
        run_dir = result_file.parent
        initial_w = parse_initial_w(run_dir)
        color = cmap(index % cmap.N)
        label = f"run {parse_run_index(run_dir)}"
        if initial_w is not None:
            label += f", w0={initial_w:.3f}"
        plot_integer_window_trajectory(ax, table,
            color=color, linewidth=1.35, alpha=0.9, label=label)

    set_common_axes(ax, f"3D phase trajectories overlay {batch_id}")
    ax.legend(loc="upper left", bbox_to_anchor=(1.02, 1.0), fontsize=8)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(output_path, bbox_inches="tight")
    plt.close(fig)


def plot_endpoint_overlay(result_files: list[Path], output_path: Path) -> None:
    by_batch: dict[str, list[Path]] = defaultdict(list)
    for result_file in result_files:
        by_batch[parse_batch_id(result_file.parent)].append(result_file)

    fig = plt.figure(figsize=(11.5, 8.5), dpi=200)
    ax = fig.add_subplot(111, projection="3d")
    cmap = plt.get_cmap("tab20")
    tables: list[dict[str, list[float]]] = []
    target_tps: set[float] = set()
    batch_count = len(by_batch)

    for index, result_file in enumerate(sorted(result_files)):
        table = parse_window_update_table(result_file)
        tables.append(table)
        run_dir = result_file.parent
        target_tp = parse_target_tp(run_dir)
        if target_tp is not None:
            target_tps.add(target_tp)

        initial_w = parse_initial_w(run_dir)
        run_index = parse_run_index(run_dir)
        label = f"run {run_index}"
        if batch_count > 1:
            label = f"{parse_batch_id(run_dir)} {label}"
        if initial_w is not None:
            label += f", w0={initial_w:.3f}"
        plot_start_end_arrow(
            ax,
            table,
            color=cmap(index % cmap.N),
            label=label,
        )

    merged = merged_tables(tables)
    for target_tp in sorted(target_tps):
        draw_target_tp_reference(ax, merged, target_tp)

    target_text = ", ".join(f"{target:g}" for target in sorted(target_tps))
    set_common_axes(ax, "Start-to-end overlay")
    ax.text2D(
        0.03,
        0.94,
        ("" if not target_text else f"target tp = {target_text}\n") +
        "green circle = start\nred triangle = end",
        transform=ax.transAxes,
        fontsize=9,
        verticalalignment="top",
        bbox={"boxstyle": "round,pad=0.35", "facecolor": "white",
              "edgecolor": "0.75", "alpha": 0.86},
    )
    ax.legend(loc="upper left", bbox_to_anchor=(1.02, 1.0), fontsize=8)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(output_path, bbox_inches="tight")
    plt.close(fig)


def find_result_files(result_dir: Path) -> list[Path]:
    return sorted(result_dir.glob("*_run_*/window_update_results.txt"))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Plot 3D QTSP phase trajectories from exp2 result directories.",
    )
    parser.add_argument(
        "result_dir",
        nargs="?",
        type=Path,
        default=DEFAULT_RESULT_DIR,
        help="Result directory such as simulation/qtsp/experiment/exp2/result/result1.",
    )
    parser.add_argument(
        "--skip-single",
        action="store_true",
        help="Only draw batch overlay plots.",
    )
    parser.add_argument(
        "--skip-overlay",
        action="store_true",
        help="Only draw per-run plots.",
    )
    parser.add_argument(
        "--sample-step",
        type=int,
        default=50,
        help="Iteration spacing for sampled per-run plots.",
    )
    parser.add_argument(
        "--sampled-only",
        action="store_true",
        help="Only draw sampled per-run plots named *_phase3d_sampledN.png.",
    )
    parser.add_argument(
        "--endpoint-overlay-grid",
        action="store_true",
        help="Alias for --endpoint-overlay.",
    )
    parser.add_argument(
        "--endpoint-overlay",
        action="store_true",
        help="Draw one combined overlay image with only start/end arrows per run.",
    )
    args = parser.parse_args()

    result_files = find_result_files(args.result_dir)
    if not result_files:
        raise FileNotFoundError(f"No window_update_results.txt files under {args.result_dir}")

    if args.endpoint_overlay or args.endpoint_overlay_grid:
        output_path = args.result_dir / "phase3d_overlay_start_end_all.png"
        plot_endpoint_overlay(result_files, output_path)
        print(f"wrote {output_path}")
        return

    if args.sampled_only:
        for result_file in result_files:
            output_path = result_file.with_name(
                result_file.stem + f"_phase3d_sampled{args.sample_step}.png"
            )
            plot_sampled_single_run(result_file, output_path,
                sample_step=args.sample_step)
            print(f"wrote {output_path}")
        return

    if not args.skip_single:
        for result_file in result_files:
            output_path = result_file.with_name(result_file.stem + "_phase3d.png")
            plot_single_run(result_file, output_path)
            print(f"wrote {output_path}")

    if not args.skip_overlay:
        by_batch: dict[str, list[Path]] = defaultdict(list)
        for result_file in result_files:
            by_batch[parse_batch_id(result_file.parent)].append(result_file)

        for batch_id, batch_files in sorted(by_batch.items()):
            output_path = args.result_dir / f"phase3d_overlay_{batch_id}.png"
            plot_overlay(batch_files, output_path, batch_id)
            print(f"wrote {output_path}")


if __name__ == "__main__":
    main()
