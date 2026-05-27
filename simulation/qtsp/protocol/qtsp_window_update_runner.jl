isdefined(@__MODULE__, :QTSPWindowUpdateProtocol) ||
    include(joinpath(@__DIR__, "qtsp_window_update_protocol.jl"))
include(joinpath(@__DIR__, "..", "qtsp_topologies.jl"))

function qtsp_materialize_topology(topology)
    if topology isa Graphs.AbstractGraph
        return topology
    end

    topology isa Function || throw(ArgumentError(
        "topology must be a Graphs.AbstractGraph or a function returning one.",
    ))
    graph = topology()
    graph isa Graphs.AbstractGraph || throw(ArgumentError(
        "topology() must return a Graphs.AbstractGraph. Got $(typeof(graph)).",
    ))

    graph
end

function build_qtsp_network_from_topology(; topology=qtsp_grid4x4_graph,
        memory_slots=QTSP_DEFAULT_MEMORY_SLOTS,
        classical_delay=QTSP_DEFAULT_CLASSICAL_DELAY,
        quantum_delay=QTSP_DEFAULT_QUANTUM_DELAY)
    graph = qtsp_materialize_topology(topology)
    registers = [Register(memory_slots) for _ in Graphs.vertices(graph)]
    net = RegisterNet(graph, registers; classical_delay, quantum_delay)
    sim = get_time_tracker(net)

    sim, net, graph
end

function run_qtsp_window_update_network_probe(;
        # default parameters
        topology=qtsp_grid4x4_graph,
        source_node=QTSP_SOURCE_NODE,
        destination_node=nothing,
        werner_w=QTSP_WINDOW_UPDATE_DEFAULT_CASE.werner_w,
        window_size=QTSP_WINDOW_UPDATE_DEFAULT_CASE.initial_window_size,
        sim_time=QTSP_WINDOW_UPDATE_DEFAULT_CASE.window_stats_interval,
        flow_uuid=QTSP_WINDOW_UPDATE_DEFAULT_CASE.flow_uuid,
        chi=QTSP_WINDOW_UPDATE_DEFAULT_CASE.chi,
        send_rate=QTSP_WINDOW_UPDATE_DEFAULT_CASE.send_rate,
        distance_km=QTSP_WINDOW_UPDATE_DEFAULT_CASE.distance_km,
        a_eta=QTSP_WINDOW_UPDATE_DEFAULT_CASE.a_eta,
        beta_per_km=QTSP_WINDOW_UPDATE_DEFAULT_CASE.beta_per_km,
        detector_a_p=QTSP_WINDOW_UPDATE_DEFAULT_CASE.detector_a_p,
        detection_prob=QTSP_WINDOW_UPDATE_DEFAULT_CASE.detection_prob,
        memory_slots=QTSP_WINDOW_UPDATE_DEFAULT_CASE.memory_slots,
        classical_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.classical_delay,
        quantum_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.quantum_delay,
        initial_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.initial_delay,
        source_ack_timeout=QTSP_WINDOW_UPDATE_DEFAULT_CASE.source_ack_timeout,
        rng=Random.default_rng())
    window_size = qtsp_update_runnable_window_size(window_size)
    source_retain_start_slot = QTSP_SOURCE_RETAIN_START_SLOT
    source_send_slot = source_retain_start_slot + window_size
    forward_slot = QTSP_DESTINATION_RECEIVE_START_SLOT
    memory_slots = something(memory_slots,
        max(QTSP_DEFAULT_MEMORY_SLOTS, source_send_slot,
            QTSP_DESTINATION_RECEIVE_START_SLOT, forward_slot))
    sim, net, graph = build_qtsp_network_from_topology(; topology, memory_slots,
        classical_delay, quantum_delay)
    destination_node = something(destination_node, Graphs.nv(graph))

    run_network_qtsp(;
        net,
        source_node,
        destination_node,
        state_count=nothing,
        flow_uuid,
        werner_w,
        window_size,
        chi,
        send_rate,
        distance_km,
        a_eta,
        beta_per_km,
        detector_a_p,
        detection_prob,
        source_retain_slots=window_size,
        source_retain_start_slot,
        source_send_slot,
        destination_receive_start_slot=QTSP_DESTINATION_RECEIVE_START_SLOT,
        forward_slot,
        initial_delay,
        source_ack_timeout,
        window_stats_interval=Inf,
        rng,
        sim_time,
    )
end

function qtsp_update_summarize_probe_results(results)
    (;
        throughput=qtsp_update_mean_value(qtsp_update_empirical_tp(result)
            for result in results),
        acked_states=qtsp_update_mean_value(result.acked_states for result in results),
        sent_states=qtsp_update_mean_value(result.sent_states for result in results),
        source_timeouts=qtsp_update_mean_value(result.source_timeouts
            for result in results),
        failed_detections=qtsp_update_mean_value(result.failed_detections
            for result in results),
    )
end

function run_qtsp_repeated_probe(case, n, label_offset, repeats)
    results = Vector{Any}(undef, repeats)

    for repeat_index in 1:repeats
        results[repeat_index] = run_qtsp_window_update_network_probe(;
            case...,
            rng=Random.MersenneTwister(qtsp_update_seed_for(label_offset, n,
                repeat_index)),
        )
    end

    qtsp_update_summarize_probe_results(results)
end

function run_qtsp_probe_pair(plus_case, minus_case, n; repeats=QTSP_PROBE_REPEATS)
    repeats > 0 || throw(ArgumentError("repeats must be positive. Got $(repeats)."))

    if QTSP_PARALLEL_WITHIN_ITERATION && Threads.nthreads() >= 2
        plus_task = Threads.@spawn run_qtsp_repeated_probe(plus_case, n,
            100_000_000, repeats)
        minus_task = Threads.@spawn run_qtsp_repeated_probe(minus_case, n,
            200_000_000, repeats)

        fetch(plus_task), fetch(minus_task)
    else
        plus_result = run_qtsp_repeated_probe(plus_case, n, 100_000_000, repeats)
        minus_result = run_qtsp_repeated_probe(minus_case, n, 200_000_000, repeats)

        plus_result, minus_result
    end
end

function network_qtsp_window_update_probe_runner(prot::QTSPWindowUpdateProtocol,
        plus_w, minus_w, n, window_info; topology, memory_slots,
        classical_delay, quantum_delay)
    window_used = prot.control.window_size
    probe_case = (;
        topology,
        source_node=prot.source_node,
        destination_node=prot.destination_node,
        flow_uuid=prot.flow_uuid,
        window_size=window_used,
        sim_time=prot.window_stats_interval,
        chi=prot.chi,
        send_rate=prot.send_rate,
        distance_km=prot.distance_km,
        a_eta=prot.a_eta,
        beta_per_km=prot.beta_per_km,
        detector_a_p=prot.detector_a_p,
        detection_prob=prot.detection_prob,
        memory_slots,
        classical_delay,
        quantum_delay,
        initial_delay=0.0,
        source_ack_timeout=prot.source_ack_timeout,
    )
    plus_case = merge(probe_case, (; werner_w=plus_w))
    minus_case = merge(probe_case, (; werner_w=minus_w))

    run_qtsp_probe_pair(plus_case, minus_case, n; repeats=prot.probe_repeats)
end

function build_network_qtsp_window_update_protocol(;
        topology=qtsp_grid4x4_graph,
        source_node=QTSP_SOURCE_NODE,
        destination_node=nothing,
        target_tp=QTSP_TARGET_TP,
        iterations=QTSP_UPDATE_ITERS,
        initial_window_size=QTSP_INITIAL_WINDOW_SIZE,
        initial_werner_w=QTSP_INITIAL_WERNER_W,
        max_window_size=QTSP_WINDOW_UPDATE_DEFAULT_CASE.max_window_size,
        sim_time=nothing,
        probe_repeats=QTSP_PROBE_REPEATS,
        flow_uuid=QTSP_WINDOW_UPDATE_DEFAULT_CASE.flow_uuid,
        chi=QTSP_WINDOW_UPDATE_DEFAULT_CASE.chi,
        send_rate=QTSP_WINDOW_UPDATE_DEFAULT_CASE.send_rate,
        distance_km=QTSP_WINDOW_UPDATE_DEFAULT_CASE.distance_km,
        a_eta=QTSP_WINDOW_UPDATE_DEFAULT_CASE.a_eta,
        beta_per_km=QTSP_WINDOW_UPDATE_DEFAULT_CASE.beta_per_km,
        detector_a_p=QTSP_WINDOW_UPDATE_DEFAULT_CASE.detector_a_p,
        detection_prob=QTSP_WINDOW_UPDATE_DEFAULT_CASE.detection_prob,
        memory_slots=QTSP_WINDOW_UPDATE_DEFAULT_CASE.memory_slots,
        classical_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.classical_delay,
        quantum_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.quantum_delay,
        initial_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.initial_delay,
        source_ack_timeout=QTSP_WINDOW_UPDATE_DEFAULT_CASE.source_ack_timeout,
        window_stats_interval=QTSP_WINDOW_UPDATE_DEFAULT_CASE.window_stats_interval,
        update_stepsize=qtsp_update_stepsize,
        werner_perturbation=qtsp_update_werner_perturbation,
        rng=Random.MersenneTwister(qtsp_update_seed_for(300_000_000, 0, 1)),
        on_update=nothing)
    source_retain_start_slot = QTSP_SOURCE_RETAIN_START_SLOT
    source_retain_slots = qtsp_update_runnable_window_size(max_window_size)
    source_send_slot = source_retain_start_slot + source_retain_slots
    forward_slot = QTSP_DESTINATION_RECEIVE_START_SLOT
    memory_slots = something(memory_slots,
        max(QTSP_DEFAULT_MEMORY_SLOTS, source_send_slot,
            QTSP_DESTINATION_RECEIVE_START_SLOT, forward_slot))
    sim, net, graph = build_qtsp_network_from_topology(; topology, memory_slots,
        classical_delay, quantum_delay)
    destination_node = something(destination_node, Graphs.nv(graph))
    probe_runner = (prot, plus_w, minus_w, n, window_info) ->
        network_qtsp_window_update_probe_runner(prot, plus_w, minus_w, n,
            window_info; topology, memory_slots, classical_delay, quantum_delay)

    build_qtsp_window_update_protocol(;
        sim,
        net,
        source_node,
        destination_node,
        target_tp,
        iterations,
        initial_window_size,
        initial_werner_w,
        max_window_size,
        sim_time,
        probe_repeats,
        probe_runner,
        flow_uuid,
        chi,
        send_rate,
        distance_km,
        a_eta,
        beta_per_km,
        detector_a_p,
        detection_prob,
        classical_delay,
        quantum_delay,
        initial_delay,
        source_ack_timeout,
        window_stats_interval,
        source_retain_start_slot,
        source_retain_slots,
        source_send_slot,
        destination_receive_start_slot=QTSP_DESTINATION_RECEIVE_START_SLOT,
        forward_slot,
        update_stepsize,
        werner_perturbation,
        rng,
        on_update,
    )
end

function run_qtsp_window_update(;
        topology=qtsp_grid4x4_graph,
        source_node=QTSP_SOURCE_NODE,
        destination_node=nothing,
        target_tp=QTSP_TARGET_TP,
        iterations=QTSP_UPDATE_ITERS,
        initial_window_size=QTSP_INITIAL_WINDOW_SIZE,
        initial_werner_w=QTSP_INITIAL_WERNER_W,
        max_window_size=QTSP_WINDOW_UPDATE_DEFAULT_CASE.max_window_size,
        sim_time=nothing,
        probe_repeats=QTSP_PROBE_REPEATS,
        output_txt=QTSP_WINDOW_UPDATE_OUTPUT_TXT,
        flow_uuid=QTSP_WINDOW_UPDATE_DEFAULT_CASE.flow_uuid,
        chi=QTSP_WINDOW_UPDATE_DEFAULT_CASE.chi,
        send_rate=QTSP_WINDOW_UPDATE_DEFAULT_CASE.send_rate,
        distance_km=QTSP_WINDOW_UPDATE_DEFAULT_CASE.distance_km,
        a_eta=QTSP_WINDOW_UPDATE_DEFAULT_CASE.a_eta,
        beta_per_km=QTSP_WINDOW_UPDATE_DEFAULT_CASE.beta_per_km,
        detector_a_p=QTSP_WINDOW_UPDATE_DEFAULT_CASE.detector_a_p,
        detection_prob=QTSP_WINDOW_UPDATE_DEFAULT_CASE.detection_prob,
        memory_slots=QTSP_WINDOW_UPDATE_DEFAULT_CASE.memory_slots,
        classical_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.classical_delay,
        quantum_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.quantum_delay,
        initial_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.initial_delay,
        source_ack_timeout=QTSP_WINDOW_UPDATE_DEFAULT_CASE.source_ack_timeout,
        window_stats_interval=QTSP_WINDOW_UPDATE_DEFAULT_CASE.window_stats_interval,
        update_stepsize=qtsp_update_stepsize,
        werner_perturbation=qtsp_update_werner_perturbation)
    protocol = build_network_qtsp_window_update_protocol(;
        topology,
        source_node,
        destination_node,
        target_tp,
        iterations,
        initial_window_size,
        initial_werner_w,
        max_window_size,
        sim_time,
        probe_repeats,
        flow_uuid,
        chi,
        send_rate,
        distance_km,
        a_eta,
        beta_per_km,
        detector_a_p,
        detection_prob,
        memory_slots,
        classical_delay,
        quantum_delay,
        initial_delay,
        source_ack_timeout,
        window_stats_interval,
        update_stepsize,
        werner_perturbation,
        on_update=row -> begin
            qtsp_wu_print_update_row(stdout, row)
            flush(stdout)
        end,
    )

    qtsp_wu_print_header(stdout)
    flush(stdout)
    run_qtsp_window_update_protocol!(protocol)

    write_qtsp_window_update_results(output_txt, protocol.rows;
        target_tp,
        iterations,
        sim_time=protocol.source_stop_time,
        window_stats_interval,
        initial_window_size,
        initial_werner_w,
        max_window_size,
        probe_repeats,
        update_stepsize,
        werner_perturbation,
    )
    println("Wrote ", output_txt)

    protocol.rows
end
