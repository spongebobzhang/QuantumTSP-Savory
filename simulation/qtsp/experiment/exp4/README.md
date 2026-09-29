# Exp4: target-throughput sweep

Exp4 tests whether QTSP can stabilize the ACK throughput at several target
rates on the SURFnet route (node 22 to node 9). For each target, the script
uses independent random initial Werner parameters.

## Run

From the repository root:

```bash
julia --project=. simulation/qtsp/experiment/exp4/run_target_sweep.jl
```

The default experiment has 5 target values, 20 random starts per target, and
100 maximum network runs (20 per target); a run stops early after convergence:

```text
target_tp = {0.4, 0.6, 0.8, 1.0, 1.2}
```

Each run writes its raw update trace and configuration under `result/`. The
batch summary is `summary_target_sweep_<batch_id>.tsv`. The summary records the
actual number of iterations and `convergence_detected_iteration`.

## Plot

After the run completes:

```bash
python3 simulation/qtsp/experiment/exp4/plot_target_sweep.py \
  simulation/qtsp/experiment/exp4/result/summary_target_sweep_<batch_id>.tsv
```

This creates:

- `target_sweep_convergence_<batch_id>.html`: mean throughput and 90% run interval;
- `target_sweep_convergence_3d_<batch_id>.html`: iteration, target, and mean throughput;
- `target_sweep_summary_<batch_id>.html`: per-run tail throughput versus target.

The 3-D figure is the main visualization for target tracking. The summary
plot is the main quantitative check: points should lie near `tail mean = target`.

## Main parameters

Edit the constants at the top of `run_target_sweep.jl`:

- `EXP4_TARGET_VALUES`: target rates to test;
- `EXP4_RUNS_PER_TARGET`: random starts per target;
- `EXP4_INITIAL_WERNER_RANGE`: range used to sample initial `w`;
- `EXP4_ITERATIONS`: maximum update iterations per run (default `5000`);
- `EXP4_CONVERGENCE_MIN_ITERATIONS`: minimum windows before detection;
- `EXP4_CONVERGENCE_HOLD_WINDOWS`: stable windows required for detection;
- `EXP4_POST_CONVERGENCE_ITERATIONS`: extra iterations after detection (default `300`);
- `EXP4_CONVERGENCE_TP_TOL`, `EXP4_CONVERGENCE_TP_STD_TOL`: throughput tolerances;
- `EXP4_CONVERGENCE_WINDOW_DELTA_TOL`, `EXP4_CONVERGENCE_WERNER_DELTA_TOL`: control-state tolerances;
- `EXP4_INITIAL_WINDOW_SIZE`, `EXP4_MAX_WINDOW_SIZE`: window bounds;
- `EXP4_SOURCE_NODE`, `EXP4_DESTINATION_NODE`: SURFnet route.

The experiment uses the existing hop-by-hop QTSP model with SURFnet edge
classical delays. It does not use entanglement swapping.
