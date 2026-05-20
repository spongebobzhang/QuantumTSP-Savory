# QTSP single-hop state transmission

This simulation is intentionally different from QTCP:

- there is one source node and one destination node;
- there is one default flow, identified by `flow_uuid`;
- the source keeps creating `(flow_uuid, seq_num)` state transmissions until
  the configured simulation time ends;
- up to `window_size` states can be in flight;
- the transmitted qubit actually goes through a wrapped `qchannel(net, 1=>2)`;
- if the window is full, the source waits for ACKs before sending more states.

The default state is a two-qubit Werner pair. For each `(flow_uuid, seq_num)`, the source
keeps one qubit in a retained source slot and sends the other qubit as the
payload of a `QTSPQuantumWrapper`. The wrapper carries `flow_uuid`, `seq_num`,
`pair_id`, the packet's Werner parameter `werner_w`, source/destination nodes,
the retained source slot, and send time
together with the temporary channel register, so the receive event knows which
packet metadata belongs to the arriving quantum payload. The destination records
the delivery time and pair fidelity, sends a classical `QTSPAck` back to the
source, and releases the destination slot. The source releases the retained slot
when it receives the ACK or when the state times out.

The source can also summarize events in fixed time windows of length
`window_stats_interval = T_W`. Each `QTSPWindowInfo` record covers one local
time bucket and records only the sent, ACKed, timed-out, and late-ACK sequence
numbers that occurred inside that bucket.

The wrapper is a simulator-level Q-datagram: the quantum payload still moves as a
register through the quantum channel, while the wrapper metadata is carried in
the same delayed packet to avoid matching by arrival order. `QTSPStateInfo`
records the flow id, sequence number, pair id, source node, destination node,
slots, timing, detection outcome, and fidelity.

Run:

```bash
julia --project=. simulation/qtsp/run_qtsp_experiments.jl
```

For the continuous window-update experiment:

```bash
julia --project=. simulation/qtsp/run_qtsp_window_update.jl
```

or directly:

```bash
julia --project=. simulation/qtsp/qtsp_two_node.jl
```

The direct script's first positional argument is `sim_time`; `state_count` is no
longer the default traffic driver. Set `QTSP_STATE_COUNT` only if you want an
optional finite cap for debugging.

The main timing fields are:

- `quantum_delivery_time`: destination receive time minus source send time;
- `rtt`: source ACK time minus source send time;
- `meanTx`: average `quantum_delivery_time`;
- `meanRTT`: average `rtt`.
- `T_W`: source window sampling interval;
- `meanSent`, `meanAck`, `meanTout`: average per-time-window source events.
