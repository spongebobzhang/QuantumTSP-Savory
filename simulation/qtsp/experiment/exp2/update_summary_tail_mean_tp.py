#!/usr/bin/env python3
"""Clean exp2 summaries and add tail-mean throughput.

For each summary_*.tsv under result/result*, this script:
- adds/recomputes final_mean_tp from the last 1% rows of each run result;
- removes run_seed, output_txt, and run_dir.

If a result directory has run folders but no summary, a new summary is created.
"""

from __future__ import annotations

import argparse
import csv
import math
import re
from collections import defaultdict
from pathlib import Path


DROP_COLUMNS = {"run_seed", "output_txt", "run_dir"}
TAIL_MEAN_COLUMN = "final_mean_tp"
DEFAULT_COLUMNS = [
    "run_index",
    "initial_werner_w",
    "iterations",
    "final_observed_tp",
    "final_window_estimate",
    "final_window_used",
    "final_werner_w",
    "final_send_rate",
    TAIL_MEAN_COLUMN,
]


def read_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if " = " not in line:
            continue
        key, value = line.split(" = ", 1)
        values[key.strip()] = value.strip()
    return values


def parse_window_table(path: Path) -> list[dict[str, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    header_index = next(
        (index for index, line in enumerate(lines) if re.match(r"^\s*iter\s*\|", line)),
        None,
    )
    if header_index is None:
        raise ValueError(f"Could not find window-update table header in {path}")

    header = [cell.strip() for cell in lines[header_index].split("|")]
    rows: list[dict[str, str]] = []
    for line in lines[header_index + 1 :]:
        stripped = line.strip()
        if not stripped or stripped.startswith("-") or "|" not in line:
            continue
        cells = [cell.strip() for cell in line.split("|")]
        if len(cells) != len(header):
            continue
        try:
            float(cells[header.index("tp")])
        except (ValueError, IndexError):
            continue
        rows.append(dict(zip(header, cells)))

    if not rows:
        raise ValueError(f"No data rows parsed from {path}")
    return rows


def tail_mean_tp(path: Path, tail_fraction: float) -> float:
    rows = parse_window_table(path)
    tail_count = max(1, math.ceil(len(rows) * tail_fraction))
    tail = rows[-tail_count:]
    return sum(float(row["tp"]) for row in tail) / len(tail)


def format_float(value: float) -> str:
    return f"{value:.12g}"


def summary_batch_id(summary_path: Path) -> str:
    return summary_path.stem.removeprefix("summary_")


def run_index_text(row: dict[str, str]) -> str:
    return f"{int(row['run_index']):03d}"


def find_result_file(summary_path: Path, row: dict[str, str]) -> Path:
    batch_id = summary_batch_id(summary_path)
    run_index = run_index_text(row)
    candidates = sorted(
        summary_path.parent.glob(f"{batch_id}_run_{run_index}_*/window_update_results.txt")
    )
    if len(candidates) == 1:
        return candidates[0]

    for key in ("output_txt", "run_dir"):
        value = row.get(key, "")
        if not value:
            continue
        path = Path(value)
        if key == "run_dir":
            path = path / "window_update_results.txt"
        if path.exists():
            return path

    candidates = sorted(summary_path.parent.glob(f"*_run_{run_index}_*/window_update_results.txt"))
    if len(candidates) == 1:
        return candidates[0]

    raise FileNotFoundError(
        f"Could not uniquely find window_update_results.txt for run {row['run_index']} "
        f"in {summary_path.parent}"
    )


def update_summary(summary_path: Path, tail_fraction: float) -> None:
    with summary_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if reader.fieldnames is None:
            raise ValueError(f"Empty summary: {summary_path}")
        rows = list(reader)

    output_columns = [
        column
        for column in reader.fieldnames
        if column not in DROP_COLUMNS and column != TAIL_MEAN_COLUMN
    ]
    output_columns.append(TAIL_MEAN_COLUMN)

    for row in rows:
        result_file = find_result_file(summary_path, row)
        row[TAIL_MEAN_COLUMN] = format_float(tail_mean_tp(result_file, tail_fraction))

    tmp_path = summary_path.with_suffix(summary_path.suffix + ".tmp")
    with tmp_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=output_columns, delimiter="\t",
            lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in output_columns})
    tmp_path.replace(summary_path)
    print(f"updated {summary_path}")


def batch_id_from_run_dir(run_dir: Path) -> str | None:
    match = re.match(r"(.+)_run_\d{3}_", run_dir.name)
    return match.group(1) if match else None


def create_summary_from_runs(result_dir: Path, batch_id: str, run_dirs: list[Path],
        tail_fraction: float) -> Path:
    summary_path = result_dir / f"summary_{batch_id}.tsv"
    rows: list[dict[str, str]] = []

    for run_dir in sorted(run_dirs):
        result_file = run_dir / "window_update_results.txt"
        config_file = run_dir / "config.txt"
        if not result_file.exists():
            continue
        config = read_key_values(config_file) if config_file.exists() else {}
        table_rows = parse_window_table(result_file)
        final = table_rows[-1]
        rows.append(
            {
                "run_index": config.get("run_index", ""),
                "initial_werner_w": config.get("initial_werner_w", ""),
                "iterations": config.get("iterations", str(len(table_rows))),
                "final_observed_tp": final.get("tp", ""),
                "final_window_estimate": final.get("W_next", ""),
                "final_window_used": final.get("Wrun_n", ""),
                "final_werner_w": final.get("w_next", ""),
                "final_send_rate": final.get("rate_n", ""),
                TAIL_MEAN_COLUMN: format_float(tail_mean_tp(result_file, tail_fraction)),
            }
        )

    with summary_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=DEFAULT_COLUMNS, delimiter="\t",
            lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
    print(f"created {summary_path}")
    return summary_path


def create_missing_summaries(result_dir: Path, tail_fraction: float) -> None:
    run_groups: dict[str, list[Path]] = defaultdict(list)
    for run_dir in result_dir.glob("*_run_*"):
        if not run_dir.is_dir():
            continue
        batch_id = batch_id_from_run_dir(run_dir)
        if batch_id is not None:
            run_groups[batch_id].append(run_dir)

    for batch_id, run_dirs in sorted(run_groups.items()):
        create_summary_from_runs(result_dir, batch_id, run_dirs, tail_fraction)


def result_dirs(root: Path) -> list[Path]:
    children = sorted(path for path in root.iterdir() if path.is_dir() and path.name.startswith("result"))
    return children if children else [root]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Add final_mean_tp to exp2 summaries and remove display-only columns.",
    )
    parser.add_argument(
        "root",
        nargs="?",
        type=Path,
        default=Path(__file__).resolve().parent / "result",
        help="exp2 result root or a single result directory.",
    )
    parser.add_argument(
        "--tail-fraction",
        type=float,
        default=0.01,
        help="Fraction of final rows to average for final_mean_tp.",
    )
    args = parser.parse_args()

    if not (0 < args.tail_fraction <= 1):
        raise ValueError("--tail-fraction must be in (0, 1].")

    for directory in result_dirs(args.root):
        summaries = sorted(directory.glob("summary_*.tsv"))
        if summaries:
            for summary_path in summaries:
                update_summary(summary_path, args.tail_fraction)
        else:
            create_missing_summaries(directory, args.tail_fraction)


if __name__ == "__main__":
    main()
