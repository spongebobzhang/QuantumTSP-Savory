isdefined(@__MODULE__, :QTSPSourceController) || include("qtsp_components.jl")

function qtsp_default_memory_slots(window_size)
    max(QTSP_DEFAULT_MEMORY_SLOTS, window_size + 1)
end

function estimated_qtsp_completion_time(; state_count, quantum_delay, classical_delay,
        send_interval, initial_delay, source_ack_timeout)
    initial_delay + state_count *
        (max(source_ack_timeout, quantum_delay + classical_delay) + send_interval)
end

function build_two_node_qtsp_network(; memory_slots=QTSP_DEFAULT_MEMORY_SLOTS,
        classical_delay=QTSP_DEFAULT_CLASSICAL_DELAY,
        quantum_delay=QTSP_DEFAULT_QUANTUM_DELAY,
        distance_km=QTSP_DEFAULT_DISTANCE_KM,
        a_eta=QTSP_DEFAULT_A_ETA,
        beta_per_km=QTSP_DEFAULT_BETA_PER_KM)
    registers = [Register(memory_slots), Register(memory_slots)]
    net = RegisterNet(path_graph(2), registers; classical_delay, quantum_delay)
    qtsp_install_wrapped_qchannel!(net, QTSP_SOURCE_NODE, QTSP_DESTINATION_NODE)
    sim = get_time_tracker(net)
    transmissivity = qtsp_transmissivity_from_distance(distance_km, a_eta, beta_per_km)

    net[(QTSP_SOURCE_NODE, QTSP_DESTINATION_NODE), :classical_delay] = classical_delay
    net[(QTSP_SOURCE_NODE, QTSP_DESTINATION_NODE), :quantum_delay] = quantum_delay
    net[(QTSP_SOURCE_NODE, QTSP_DESTINATION_NODE), :distance_km] = distance_km
    net[(QTSP_SOURCE_NODE, QTSP_DESTINATION_NODE), :a_eta] = a_eta
    net[(QTSP_SOURCE_NODE, QTSP_DESTINATION_NODE), :beta_per_km] = beta_per_km
    net[(QTSP_SOURCE_NODE, QTSP_DESTINATION_NODE), :transmissivity] = transmissivity

    sim, net
end

function mean_or_nan(values)
    collected = collect(values)
    isempty(collected) ? NaN : sum(collected) / length(collected)
end

function run_two_node_qtsp(; state_count=nothing,
        flow_uuid=QTSP_DEFAULT_FLOW_UUID,
        werner_w=QTSP_DEFAULT_WERNER_W,
        window_size=QTSP_DEFAULT_WINDOW_SIZE,
        memory_slots=nothing,
        chi=QTSP_DEFAULT_CHI,
        send_rate=nothing,
        distance_km=QTSP_DEFAULT_DISTANCE_KM,
        a_eta=QTSP_DEFAULT_A_ETA,
        beta_per_km=QTSP_DEFAULT_BETA_PER_KM,
        detector_a_p=QTSP_DEFAULT_DETECTOR_A_P,
        detection_prob=nothing,
        classical_delay=QTSP_DEFAULT_CLASSICAL_DELAY,
        quantum_delay=QTSP_DEFAULT_QUANTUM_DELAY,
        source_retain_slots=nothing,
        source_retain_start_slot=QTSP_SOURCE_RETAIN_START_SLOT,
        source_send_slot=QTSP_SOURCE_SEND_SLOT,
        destination_receive_start_slot=QTSP_DESTINATION_RECEIVE_START_SLOT,
        send_interval=nothing,
        initial_delay=QTSP_DEFAULT_INITIAL_DELAY,
        source_ack_timeout=QTSP_DEFAULT_SOURCE_ACK_TIMEOUT,
        window_stats_interval=QTSP_DEFAULT_WINDOW_STATS_INTERVAL,
        rng=Random.default_rng(),
        sim_time=QTSP_DEFAULT_SIM_TIME)
    !isnothing(state_count) && state_count > 0 || isnothing(state_count) ||
        throw(ArgumentError("state_count must be positive or nothing. Got $(state_count)."))
    window_size > 0 || throw(ArgumentError("window_size must be positive. Got $(window_size)."))
    distance_km >= 0 || throw(ArgumentError("distance_km must be non-negative. Got $(distance_km)."))
    a_eta >= 0 || throw(ArgumentError("a_eta must be non-negative. Got $(a_eta)."))
    beta_per_km >= 0 || throw(ArgumentError("beta_per_km must be non-negative. Got $(beta_per_km)."))
    detector_a_p >= 0 || throw(ArgumentError("detector_a_p must be non-negative. Got $(detector_a_p)."))
    classical_delay >= 0 || throw(ArgumentError("classical_delay must be non-negative. Got $(classical_delay)."))
    quantum_delay >= 0 || throw(ArgumentError("quantum_delay must be non-negative. Got $(quantum_delay)."))
    source_retain_slots = something(source_retain_slots, window_size)
    source_retain_slots >= window_size || throw(ArgumentError(
        "source_retain_slots must be at least window_size. Got source_retain_slots=$(source_retain_slots), window_size=$(window_size).",
    ))
    initial_delay >= 0 || throw(ArgumentError("initial_delay must be non-negative. Got $(initial_delay)."))
    source_ack_timeout > 0 || throw(ArgumentError("source_ack_timeout must be positive. Got $(source_ack_timeout)."))
    window_stats_interval > 0 || throw(ArgumentError("window_stats_interval must be positive. Got $(window_stats_interval)."))
    transmissivity = qtsp_transmissivity_from_distance(distance_km, a_eta, beta_per_km)
    detection_prob = something(detection_prob,
        qtsp_detector_success_probability(detector_a_p, werner_w))
    0 <= detection_prob <= 1 || throw(ArgumentError("detection_prob must be in [0, 1]. Got $(detection_prob)."))

    if isnothing(send_rate)
        isnothing(chi) && throw(ArgumentError("Provide either chi or send_rate."))
        chi >= 0 || throw(ArgumentError("chi must be non-negative. Got $(chi)."))
        send_rate = qtsp_source_generation_rate(chi, werner_w; distance_km, a_eta,
            beta_per_km)
    end
    send_rate > 0 || throw(ArgumentError(
        "The send rate must be positive. Got $(send_rate) for chi=$(chi), w=$(werner_w).",
    ))
    send_interval = something(send_interval, 1 / send_rate)
    send_interval >= 0 || throw(ArgumentError("send_interval must be non-negative. Got $(send_interval)."))
    run_until = if isnothing(sim_time)
        isnothing(state_count) ?
            QTSP_DEFAULT_SIM_TIME :
            estimated_qtsp_completion_time(;
                state_count,
                quantum_delay,
                classical_delay,
                send_interval,
                initial_delay,
                source_ack_timeout,
            ) + 1e-9
    else
        sim_time
    end
    run_until > 0 || throw(ArgumentError("sim_time must be positive. Got $(run_until)."))

    memory_slots = something(memory_slots, max(qtsp_default_memory_slots(source_retain_slots),
        source_send_slot, destination_receive_start_slot))
    sim, net = build_two_node_qtsp_network(; memory_slots, classical_delay, quantum_delay,
        distance_km, a_eta, beta_per_km)

    send_log = QTSPStateInfo[]
    receive_log = QTSPStateInfo[]
    ack_log = QTSPStateInfo[]
    timeout_log = QTSPStateInfo[]
    late_ack_log = QTSPStateInfo[]
    failure_log = QTSPStateInfo[]
    window_log = QTSPWindowInfo[]

    @process QTSPDestinationController(;
        sim,
        net,
        source_node=QTSP_SOURCE_NODE,
        destination_node=QTSP_DESTINATION_NODE,
        flow_uuid,
        state_count,
        window_size,
        source_retain_start_slot,
        destination_receive_start_slot,
        detector_a_p,
        detection_prob,
        rng,
        receive_log,
        failure_log,
    )()

    @process QTSPSourceController(;
        sim,
        net,
        source_node=QTSP_SOURCE_NODE,
        destination_node=QTSP_DESTINATION_NODE,
        flow_uuid,
        state_count,
        source_stop_time=run_until,
        window_size,
        source_retain_slots,
        werner_w,
        source_retain_start_slot,
        source_send_slot,
        send_interval,
        initial_delay,
        source_ack_timeout,
        window_stats_interval,
        send_log,
        ack_log,
        timeout_log,
        late_ack_log,
        window_log,
    )()

    sim_run_until = run_until + 1e-9
    run(sim, sim_run_until)

    send_by_key = Dict(qtsp_state_key(entry) => entry for entry in send_log)
    receive_by_key = Dict(qtsp_state_key(entry) => entry for entry in receive_log)
    ack_by_key = Dict(qtsp_state_key(entry) => entry for entry in ack_log)
    timeout_by_key = Dict(qtsp_state_key(entry) => entry for entry in timeout_log)
    failure_by_key = Dict(qtsp_state_key(entry) => entry for entry in failure_log)

    state_seq_nums = sort!(unique(vcat(
        Int[entry.seq_num for entry in send_log],
        Int[entry.seq_num for entry in receive_log],
        Int[entry.seq_num for entry in ack_log],
        Int[entry.seq_num for entry in timeout_log],
        Int[entry.seq_num for entry in late_ack_log],
        Int[entry.seq_num for entry in failure_log],
    )))
    state_records = map(state_seq_nums) do seq_num
        key = qtsp_state_key(flow_uuid, seq_num)
        sent = get(send_by_key, key, nothing)
        received = get(receive_by_key, key, nothing)
        acked = get(ack_by_key, key, nothing)
        timed_out = get(timeout_by_key, key, nothing)
        failed = get(failure_by_key, key, nothing)
        quantum_delivery_time = if !isnothing(sent) && !isnothing(received)
            received.receive_time - sent.send_time
        else
            NaN
        end

        QTSPStateInfo(;
            flow_uuid,
            seq_num,
            pair_id=isnothing(sent) ? missing : sent.pair_id,
            source_node=QTSP_SOURCE_NODE,
            destination_node=QTSP_DESTINATION_NODE,
            source_retain_slot=isnothing(sent) ? missing : sent.source_retain_slot,
            source_send_slot=isnothing(sent) ? missing : sent.source_send_slot,
            destination_slot=isnothing(received) ? missing : received.destination_slot,
            send_time=isnothing(sent) ? NaN : sent.send_time,
            receive_time=isnothing(received) ? NaN : received.receive_time,
            ack_time=isnothing(acked) ? NaN : acked.ack_time,
            timeout_time=isnothing(timed_out) ? NaN : timed_out.timeout_time,
            quantum_delivery_time,
            rtt=isnothing(acked) ? NaN : acked.rtt,
            sent=!isnothing(sent),
            received=!isnothing(received),
            acked=!isnothing(acked),
            detected=!isnothing(received) && isnothing(failed),
            failed_detection=!isnothing(failed),
            timed_out=!isnothing(timed_out),
            observed_fidelity=isnothing(received) ? NaN : received.observed_fidelity,
        )
    end

    acked_records = filter(record -> record.acked, state_records)
    received_records = filter(record -> record.received, state_records)
    fidelity_records = filter(record -> record.received && !isnan(record.observed_fidelity), state_records)

    completion_times = [
        (entry.ack_time for entry in ack_log)...,
        (entry.timeout_time for entry in timeout_log)...,
    ]
    total_time = isnothing(state_count) ? run_until :
        (isempty(completion_times) ? now(sim) : maximum(completion_times))

    (;
        state_count,
        flow_uuid,
        werner_w,
        window_size,
        expected_fidelity=qtsp_fidelity_from_werner(werner_w),
        chi,
        send_rate,
        distance_km,
        a_eta,
        beta_per_km,
        transmissivity,
        detection_prob,
        detector_a_p,
        memory_slots,
        source_retain_slots,
        source_retain_start_slot,
        source_send_slot,
        destination_receive_start_slot,
        classical_delay,
        quantum_delay,
        send_interval,
        initial_delay,
        source_ack_timeout,
        window_stats_interval,
        sim_time=run_until,
        total_time,
        sent_states=length(send_log),
        received_states=length(receive_log),
        acked_states=length(ack_log),
        failed_detections=length(failure_log),
        source_timeouts=length(timeout_log),
        late_acks=length(late_ack_log),
        unacked_at_source=length(send_log) - length(ack_log) - length(timeout_log),
        delivery_throughput=isempty(receive_log) ? 0.0 : length(receive_log) / total_time,
        acked_throughput=isempty(ack_log) ? 0.0 : length(ack_log) / total_time,
        mean_quantum_delivery_time=mean_or_nan(record.quantum_delivery_time for record in received_records),
        mean_rtt=mean_or_nan(record.rtt for record in acked_records),
        mean_observed_fidelity=mean_or_nan(record.observed_fidelity for record in fidelity_records),
        send_log,
        receive_log,
        ack_log,
        timeout_log,
        late_ack_log,
        failure_log,
        window_log,
        window_samples=length(window_log),
        mean_window_sent=mean_or_nan(entry.sent_count for entry in window_log),
        mean_window_acked=mean_or_nan(entry.acked_count for entry in window_log),
        mean_window_timeouts=mean_or_nan(entry.timeout_count for entry in window_log),
        state_records,
        sim,
        net,
    )
end
