# Quick Start 

To install necessary packages, in main directory run:
```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

**Added Components:** Network component is added into QTSP and window_update runnner is refined to be a generic one. For now the states will be forwarded hop by hop along the path without any swapping, and the path finding is based on A* algorithm.

**Usage:** In qtsp_topologies.jl edges_list can be set to create a network. Source and destination can set in run_qtsp_experiments.jl/run_qtsp_window_update.jl for two kinds of experiments. 

For SURFnet, `surfnet_graph()` builds the topology from the Topology Zoo
GraphML data in `data/Surfnet.graphml`. `surfnet_classical_delay_map()` uses
node latitude/longitude and great-circle distance to create per-link classical
delays. Pass it as `edge_classical_delays=surfnet_classical_delay_map()`;
otherwise the scalar `classical_delay` is used for every link.
Use `graphml_to_qtsp_topology.py` to extract another GraphML file into Julia
topology helper functions.


**The run command remains unchanged:**

To simulate the process with fixed window size and werner parameter, run:

```bash
julia --project=. simulation/qtsp/run_qtsp_experiments.jl
```
Parameters can be set in run_qtsp_experiments.jl. The default output file is qtsp_results.txt.

To simulate the continuous update process on a network, run:

```bash
julia --project=. simulation/qtsp/run_qtsp_window_update.jl
```

Parameters can be set in run_qtsp_window_update.jl. The default output file is
qtsp_window_update_results.txt.

To plot the result after window update, in qtsp directory run:
```bash
python3 plot_qtsp_window_results.py result/dir1/result.txt
```
This writes four plots: observed throughput, gamma/delta, window size, and
Werner parameter. The plots are written next to the result file using the result
filename as the prefix.
May consider to replace it with one based on julia.


# QTSP components

File roles:

- `protocol/qtsp_components.jl`: the core QTSP protocol. It defines the source,
  destination, and network router controllers, wrapped quantum channels, ACKs,
  control state, log record types, and `run_network_qtsp(...)` for routed
  hop-by-hop forwarding.
- `qtsp_topologies.jl`: topology builders used by scripts and examples.
- `protocol/qtsp_window_update_protocol.jl`: the generic window-update protocol. It defines `QTSPWindowUpdateProtocol` and expects an already-built `sim`/`net` plus a `probe_runner`
- `protocol/qtsp_window_update_runner.jl`: the generic network window-update runner. It
  builds a `RegisterNet` from a topology, uses routed probes, and defines
  `run_qtsp_window_update(...)` for network runs.


For now `protocol/qtsp_components.jl` and
`protocol/qtsp_window_update_protocol.jl` are designed for one flow (from one
source to one destination). It supports one routed flow
with hop-by-hop forwarding. More work is needed for multiflow, routing policy,
and repeater-style swapping.
