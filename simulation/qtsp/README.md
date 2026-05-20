# Quick Start 

To install necessary packages, in main directory run:
```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

To simulate the process given a certain window size and werner parameter, run:

```bash
julia --project=. simulation/qtsp/run_qtsp_experiments.jl
```
Parameters can be set in run_qtsp_experiments.jl. The default output file is qtsp_results.txt.


To simulate the continuous update process, run:

```bash
julia --project=. simulation/qtsp/run_qtsp_window_update.jl
```

Parameters can be set in run_qtsp_window_update.jl. The default output file is qtsp_window_update_results.txt. 

To plot the result after window update, in qtsp directory run:
```bash
python3 plot_qtsp_window_results.py result.txt output.png
```
May consider to replace it with one based on julia.

# QTSP components

File roles:

- `qtsp_components.jl`: the core QTSP protocol. It defines the source and destination controllers, wrapped quantum channel, ACKs, control state, and log record types.
- `qtsp_window_update_protocol.jl`: the generic window-update protocol. It defines `QTSPWindowUpdateProtocol` and expects an already-built `sim`/`net` plus a `probe_runner`
- `qtsp_two_node_helpers.jl`:  two-node helpers. It builds a two-node
  QTSP network and provides `run_two_node_qtsp(...)` for simple two-node runs and probe simulations.
- `qtsp_window_update_two_node.jl`: the current two-node window-update convenience layer. It wires the generic protocol to the two-node helper, provides the default two-node probe runner, and defines `run_qtsp_window_update(...)`.

For now `qtsp_components.jl` and `qtsp_window_update_protocol.jl` are designed for one flow (from one source to one destination). More work is needed for multiflow and larger networks.

`qtsp_two_node_helpers.jl` and `qtsp_window_update_two_node.jl` are used to generate the network and create specific runner for two-node window update. If a different network is to be simulated, similar files need to be created. A generic network runner is needed in the future.

