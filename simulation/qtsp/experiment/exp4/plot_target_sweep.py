#!/usr/bin/env python3
"""Plot exp4 target-throughput sweep results.

The script reads the TSV summary written by run_target_sweep.jl and the raw
per-iteration traces. It writes a 2-D convergence plot, a 3-D target-tracking
plot, and a final-error summary plot next to the summary file.
"""

from __future__ import annotations

import argparse
import csv
import math
import re
from collections import defaultdict
from pathlib import Path
from statistics import mean, median, pstdev


def parse_trace(path: Path) -> tuple[list[int], list[float]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    header_index = next(
        (i for i, line in enumerate(lines) if re.match(r"^\s*iter\s*\|", line)),
        None,
    )
    if header_index is None:
        raise ValueError(f"No update table found in {path}")
    header = [cell.strip() for cell in lines[header_index].split("|")]
    try:
        iter_index = header.index("iter")
        tp_index = header.index("tp")
    except ValueError as exc:
        raise ValueError(f"Trace {path} has no iter/tp columns") from exc

    iterations: list[int] = []
    throughput: list[float] = []
    for line in lines[header_index + 1 :]:
        if not line.strip() or line.lstrip().startswith("-") or "|" not in line:
            continue
        cells = [cell.strip() for cell in line.split("|")]
        if len(cells) != len(header):
            continue
        try:
            iterations.append(int(cells[iter_index]))
            throughput.append(float(cells[tp_index]))
        except ValueError:
            continue
    if not iterations:
        raise ValueError(f"No trace rows found in {path}")
    return iterations, throughput


def read_summary(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if not rows:
        raise ValueError(f"Empty summary: {path}")
    return rows


def trace_path(row: dict[str, str], summary_path: Path) -> Path:
    path = Path(row.get("output_txt") or "")
    if path.exists():
        return path
    run_dir = Path(row.get("run_dir") or "")
    path = run_dir / "window_update_results.txt"
    if path.exists():
        return path
    raise FileNotFoundError(f"Could not find trace for run {row.get('run_index')}")


def grouped_traces(rows: list[dict[str, str]], summary_path: Path):
    groups: dict[float, list[tuple[list[int], list[float]]]] = defaultdict(list)
    for row in rows:
        target = float(row["target_tp"])
        groups[target].append(parse_trace(trace_path(row, summary_path)))
    return dict(sorted(groups.items()))


def quantile(values: list[float], q: float) -> float:
    if len(values) == 1:
        return values[0]
    ordered = sorted(values)
    position = q * (len(ordered) - 1)
    low = math.floor(position)
    high = math.ceil(position)
    if low == high:
        return ordered[low]
    weight = position - low
    return ordered[low] * (1 - weight) + ordered[high] * weight


def aggregate(group):
    length = min(len(values) for _, values in group)
    iterations = group[0][0][:length]
    means = []
    lower = []
    upper = []
    for index in range(length):
        values = [trace[1][index] for trace in group]
        means.append(mean(values))
        lower.append(quantile(values, 0.05))
        upper.append(quantile(values, 0.95))
    return iterations, means, lower, upper


def write_plots(summary_path: Path) -> None:
    import plotly.graph_objects as go
    rows = read_summary(summary_path)
    groups = grouped_traces(rows, summary_path)
    output_dir = summary_path.parent
    stem = summary_path.stem.removeprefix("summary_")

    # 2-D convergence curves: mean and 90% interval for every target.
    figure = go.Figure()
    colors = ["#1565c0", "#2e7d32", "#ef6c00", "#6a1b9a", "#c62828"]
    for color, (target, group) in zip(colors, groups.items()):
        iterations, means, lower, upper = aggregate(group)
        figure.add_trace(go.Scatter(
            x=iterations, y=lower, mode="lines",
            line={"width": 0}, showlegend=False, hoverinfo="skip",
        ))
        rgba = f"rgba({int(color[1:3],16)},{int(color[3:5],16)},{int(color[5:7],16)},0.12)"
        figure.add_trace(go.Scatter(
            x=iterations, y=upper, mode="lines",
            line={"width": 0}, fill="tonexty", fillcolor=rgba,
            showlegend=False, hoverinfo="skip",
        ))
        figure.add_trace(go.Scatter(
            x=iterations, y=means, mode="lines",
            line={"color": color, "width": 3},
            name=f"target {target:g}",
            hovertemplate="iteration=%{x}<br>mean tp=%{y:.4f}<extra></extra>",
        ))
        figure.add_hline(y=target, line_dash="dash", line_color=color,
                         opacity=0.45, annotation_text=f"target {target:g}")
    figure.update_layout(
        title="QTSP target-throughput stabilization",
        xaxis_title="Update iteration",
        yaxis_title="ACK throughput",
        legend={"font": {"size": 10}},
        template="plotly_white",
        margin={"l": 60, "r": 20, "b": 55, "t": 65},
    )
    convergence_2d = output_dir / f"target_sweep_convergence_{stem}.html"
    figure.write_html(convergence_2d, include_plotlyjs=True)

    # 3-D view: iteration, target, and mean throughput.
    figure3d = go.Figure()
    for color, (target, group) in zip(colors, groups.items()):
        iterations, means, _, _ = aggregate(group)
        figure3d.add_trace(go.Scatter3d(
            x=iterations, y=[target] * len(iterations), z=means,
            mode="lines", line={"color": color, "width": 6},
            name=f"target {target:g}",
            hovertemplate=("iteration=%{x}<br>target=%{y:.2f}<br>"
                           "mean tp=%{z:.4f}<extra></extra>"),
        ))
    targets = list(groups)
    all_iterations = [trace[0][0] for group in groups.values() for trace in group]
    if targets and all_iterations:
        x_min, x_max = min(all_iterations), max(all_iterations)
        t_min, t_max = min(targets), max(targets)
        figure3d.add_trace(go.Surface(
            x=[x_min, x_max], y=[t_min, t_max],
            z=[[t_min, t_min], [t_max, t_max]],
            opacity=0.12, showscale=False,
            colorscale=[[0, "crimson"], [1, "crimson"]],
            name="target plane z=target", hoverinfo="skip",
        ))
    figure3d.update_layout(
        title="QTSP stabilization across target throughputs",
        scene={
            "xaxis_title": "Update iteration",
            "yaxis_title": "Target throughput",
            "zaxis_title": "Mean ACK throughput",
        },
        legend={"font": {"size": 10}},
        margin={"l": 0, "r": 0, "b": 0, "t": 55},
    )
    convergence_3d = output_dir / f"target_sweep_convergence_3d_{stem}.html"
    figure3d.write_html(convergence_3d, include_plotlyjs=True)

    # Final steady-state quality: each run is one point, plus y=x reference.
    summary_figure = go.Figure()
    targets = [float(row["target_tp"]) for row in rows]
    tail = [float(row["tail_mean_tp"]) for row in rows]
    summary_figure.add_trace(go.Scatter(
        x=targets, y=tail, mode="markers",
        marker={"size": 8, "color": targets, "colorscale": "Viridis",
                "cmin": min(targets), "cmax": max(targets),
                "colorbar": {"title": "target"}},
        text=[f"run {row['run_index']}" for row in rows],
        hovertemplate="target=%{x:.3f}<br>tail mean=%{y:.4f}<br>%{text}<extra></extra>",
        name="runs",
    ))
    bound = [min(targets + tail), max(targets + tail)]
    summary_figure.add_trace(go.Scatter(
        x=bound, y=bound, mode="lines", line={"color": "black", "dash": "dash"},
        name="ideal y=x",
    ))
    summary_figure.update_layout(
        title="Exp4 steady-state throughput versus target",
        xaxis_title="Target throughput",
        yaxis_title="Tail-mean ACK throughput",
        template="plotly_white",
        margin={"l": 60, "r": 20, "b": 55, "t": 65},
    )
    summary_output = output_dir / f"target_sweep_summary_{stem}.html"
    summary_figure.write_html(summary_output, include_plotlyjs=True)

    print(f"wrote {convergence_2d}")
    print(f"wrote {convergence_3d}")
    print(f"wrote {summary_output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", type=Path,
                        help="summary_target_sweep_<batch_id>.tsv")
    args = parser.parse_args()
    write_plots(args.summary)


if __name__ == "__main__":
    main()
