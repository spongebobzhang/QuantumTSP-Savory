# Exp2: Random Initial `w` on SURFnet

This experiment studies QTSP window-update convergence from randomly sampled
initial Werner parameters. It uses one flow from SURFnet node 22 to node 9 with
hop-by-hop forwarding and A* routing. Entanglement swapping is not used.

## Run

From the repository root:

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. simulation/qtsp/experiment/exp2/run_random_initial_w.jl
```

Each process creates one timestamped batch. Every run in the batch receives a
separate seed and a uniformly sampled initial `w`.

## Scripts

- `run_random_initial_w.jl`: runs the experiment, saves raw data and a batch
  summary, and creates four 2D plots for each run.
- `plot_phase3d_trajectories.py`: creates 3D trajectories in
  `(w, W_run, throughput)` space.
- `update_summary_tail_mean_tp.py`: adds `final_mean_tp` to summaries using the
  final portion of each throughput trace.

Create normal 3D plots and a batch overlay:

```bash
python3 simulation/qtsp/experiment/exp2/plot_phase3d_trajectories.py \
  simulation/qtsp/experiment/exp2/result/result1
```

Create one start-to-end overlay:

```bash
python3 simulation/qtsp/experiment/exp2/plot_phase3d_trajectories.py \
  simulation/qtsp/experiment/exp2/result/result1 --endpoint-overlay
```

Create sampled trajectories:

```bash
python3 simulation/qtsp/experiment/exp2/plot_phase3d_trajectories.py \
  simulation/qtsp/experiment/exp2/result/result1 \
  --sampled-only --sample-step 50
```

Update a summary using the last 1% of each run:

```bash
python3 simulation/qtsp/experiment/exp2/update_summary_tail_mean_tp.py \
  simulation/qtsp/experiment/exp2/result/result1
```

Use `--tail-fraction 0.05` to average the last 5% instead. This script rewrites
the summary in place and removes `run_seed`, `output_txt`, and `run_dir`.

The 3D plotter reads every `*_run_*` directory under the supplied path; it does
not select runs from the summary. Keep only the intended batch in each result
directory when producing an overlay.

## Main parameters

Edit the constants at the top of `run_random_initial_w.jl`:

| Parameter | Meaning | Default |
| --- | --- | --- |
| `EXP2_RANDOM_MASTER_SEED` | Seed used to generate run seeds and initial `w` | `20260629` |
| `EXP2_RANDOM_RUN_COUNT` | Runs per batch | `20` |
| `EXP2_INITIAL_WERNER_RANGE` | Uniform range for initial `w` | `(0.01, 0.99)` |
| `EXP2_INITIAL_WINDOW_SIZE` | Initial window size | `5` |
| `EXP2_MAX_WINDOW_SIZE` | Maximum window size | `100` |
| `EXP2_TARGET_TP` | Target throughput | `1.2` |
| `EXP2_ITERATIONS` | Update iterations | `10000` |
| `EXP2_WINDOW_STATS_INTERVAL` | Duration of each update window | `300.0` |
| `EXP2_PROBE_REPEATS` | Repetitions for each plus/minus probe | `1` |
| `EXP2_SOURCE_NODE` | SURFnet source | `22` |
| `EXP2_DESTINATION_NODE` | SURFnet destination | `9` |

The update sequences are:

```julia
gamma(n) = 1 / (n + 100)^0.7
delta(n) = 0.05 / (n + 50)^0.15
```

`EXP2_USE_SURFNET_EDGE_DELAYS=true` enables distance-based classical delays.
`EXP2_SEND_RATE=nothing` derives the periodic sending rate from `chi`, `w`, and
the transmission model. `EXP2_DISTANCE_KM` belongs to that model and is not the
actual length of each SURFnet edge. Quantum links currently use the uniform
`EXP2_QUANTUM_DELAY`. The source is periodic, not Poisson.

The run seed currently samples only the initial `w`; the protocol runner uses
its own deterministic random-seed scheme for the main and probe simulations.

## Results

New batches are written directly under `exp2/result/`:

```text
result/
├── summary_<batch_id>.tsv
└── <batch_id>_run_001_seed_<seed>_w_<initial_w>/
    ├── config.txt
    ├── edge_classical_delays.tsv
    ├── window_update_results.txt
    └── window_update_results_*_wide.png
```

`result1`, `result2`, and `result3` are manually organized directories; the
experiment does not create or increment them automatically.

- `config.txt`: parameter snapshot for one run.
- `edge_classical_delays.tsv`: SURFnet edge distances and classical delays.
- `window_update_results.txt`: per-iteration values such as `W_run`, `w`, `tp`,
  probe throughput, sent/ACK/timeout counts, and next-step parameters.
- `window_update_results_*_wide.png`: throughput, step-size, window-size, and
  Werner-parameter plots.
- `window_update_results_phase3d*.png`: optional 3D trajectory plots.
- `summary_<batch_id>.tsv`: one row per run with initial and final values.


