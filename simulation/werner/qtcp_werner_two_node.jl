include("qtcp_werner_components.jl")

function build_two_node_qtcp_network(; memory_slots=DEFAULT_MEMORY_SLOTS, werner_w=DEFAULT_WERNER_W,
        success_prob=DEFAULT_SUCCESS_PROB, attempt_time=DEFAULT_ATTEMPT_TIME,
        distance_km=DEFAULT_DISTANCE_KM, a_eta=DEFAULT_A_ETA, beta_per_km=DEFAULT_BETA_PER_KM)
    registers = [Register(memory_slots), Register(memory_slots)]
    # no classical delay 
    net = RegisterNet(path_graph(2), registers)
    sim = get_time_tracker(net)
    transmissivity = transmissivity_from_distance(distance_km, a_eta, beta_per_km)

    net[(SOURCE_NODE, DESTINATION_NODE), :distance_km] = distance_km
    net[(SOURCE_NODE, DESTINATION_NODE), :a_eta] = a_eta
    net[(SOURCE_NODE, DESTINATION_NODE), :beta_per_km] = beta_per_km
    net[(SOURCE_NODE, DESTINATION_NODE), :transmissivity] = transmissivity

    @process EndNodeController(sim, net, SOURCE_NODE)()
    @process EndNodeController(sim, net, DESTINATION_NODE)()
    @process NetworkNodeController(sim, net, SOURCE_NODE)()
    @process NetworkNodeController(sim, net, DESTINATION_NODE)()
    @process WernerLinkController(;
        sim,
        net,
        nodeA=SOURCE_NODE,
        nodeB=DESTINATION_NODE,
        werner_w,
        success_prob,
        attempt_time,
    )()

    sim, net
end

function run_two_node_qtcp_werner(; werner_w=DEFAULT_WERNER_W,
        sim_time=DEFAULT_SIM_TIME, success_prob=DEFAULT_SUCCESS_PROB,
        attempt_time=DEFAULT_ATTEMPT_TIME, chi=DEFAULT_CHI,
        request_rate=nothing, memory_slots=nothing,
        distance_km=DEFAULT_DISTANCE_KM, a_eta=DEFAULT_A_ETA, beta_per_km=DEFAULT_BETA_PER_KM,
        initial_request_delay=DEFAULT_INITIAL_REQUEST_DELAY, detector_a_p=DEFAULT_DETECTOR_A_P,
        detection_prob=nothing,
        source_window_size=DEFAULT_SOURCE_WINDOW_SIZE,
        source_ack_timeout=DEFAULT_SOURCE_ACK_TIMEOUT, rng=Random.default_rng())
    distance_km >= 0 || throw(ArgumentError("distance_km must be non-negative. Got $(distance_km)."))
    a_eta >= 0 || throw(ArgumentError("a_eta must be non-negative. Got $(a_eta)."))
    beta_per_km >= 0 || throw(ArgumentError("beta_per_km must be non-negative. Got $(beta_per_km)."))
    detector_a_p >= 0 || throw(ArgumentError("detector_a_p must be non-negative. Got $(detector_a_p)."))
    detection_prob = something(detection_prob, detector_success_probability(detector_a_p, werner_w))
    0 <= detection_prob <= 1 || throw(ArgumentError("detection_prob must be in [0, 1]. Got $(detection_prob)."))
    source_window_size > 0 || throw(ArgumentError("source_window_size must be positive. Got $(source_window_size)."))
    source_ack_timeout > 0 || throw(ArgumentError("source_ack_timeout must be positive. Got $(source_ack_timeout)."))
    transmissivity = transmissivity_from_distance(distance_km, a_eta, beta_per_km)

    if isnothing(request_rate)
        isnothing(chi) && throw(ArgumentError("Provide either chi or request_rate."))
        chi >= 0 || throw(ArgumentError("chi must be non-negative. Got $(chi)."))
        request_rate = source_generation_rate(chi, werner_w; distance_km, a_eta, beta_per_km)
    end
    request_rate > 0 || throw(ArgumentError(
        "The request rate must be positive. Got $(request_rate) for chi=$(chi), w=$(werner_w).",
    ))

    memory_slots = something(memory_slots, max(DEFAULT_MEMORY_SLOTS,
        estimated_request_count(sim_time, request_rate, initial_request_delay) + 2))

    sim, net = build_two_node_qtcp_network(;
        memory_slots,
        werner_w,
        success_prob,
        attempt_time,
        distance_km,
        a_eta,
        beta_per_km,
    )

    @process DestinationDetector(;
        sim,
        net,
        source_node=SOURCE_NODE,
        destination_node=DESTINATION_NODE,
        detection_prob,
        rng,
    )()

    source_sent_log = NamedTuple[]
    source_ack_log = NamedTuple[]
    source_timeout_log = NamedTuple[]
    source_late_ack_log = NamedTuple[]
    @process SourceWindowController(;
        sim,
        net,
        request_rate,
        source_window_size,
        source_ack_timeout,
        initial_delay=initial_request_delay,
        source_node=SOURCE_NODE,
        destination_node=DESTINATION_NODE,
        uuid_start=FLOW_UUID_START,
        sent_log=source_sent_log,
        ack_log=source_ack_log,
        timeout_log=source_timeout_log,
        late_ack_log=source_late_ack_log,
    )()
    run(sim, sim_time)

    source_mb = messagebuffer(net, SOURCE_NODE)
    destination_mb = messagebuffer(net, DESTINATION_NODE)

    begin_slots = Dict{Tuple{Int,Int},NamedTuple}()
    while true
        pair_begin_msg = querydelete!(source_mb, QTCPPairBegin, ❓, SOURCE_NODE, ❓, ❓, ❓, ❓)
        isnothing(pair_begin_msg) && break

        _, flow_uuid, _, _, seq_num, source_slot, start_time = pair_begin_msg.tag
        begin_slots[(flow_uuid, seq_num)] = (source_slot=source_slot, start_time=start_time)
    end

    ack_slots = Dict{Tuple{Int,Int},NamedTuple}()
    for ack in source_ack_log
        ack_slots[(ack.flow_uuid, ack.seq_num)] = (;
            destination_slot=ack.destination_slot,
            send_time=ack.send_time,
            ack_time=ack.ack_time,
            rtt=ack.rtt,
        )
    end

    failure_slots = Dict{Tuple{Int,Int},NamedTuple}()
    while true
        failure_msg = querydelete!(destination_mb, QTCP_DETECTION_FAILURE, ❓, SOURCE_NODE, DESTINATION_NODE, ❓, ❓)
        isnothing(failure_msg) && break

        _, flow_uuid, _, _, seq_num, destination_slot = failure_msg.tag
        failure_slots[(flow_uuid, seq_num)] = (;
            destination_slot,
        )
    end

    detector_outcome_keys = sort(collect(union(keys(ack_slots), keys(failure_slots))))

    pairs = map(detector_outcome_keys) do (flow_uuid, seq_num)
        key = (flow_uuid, seq_num)
        detected = haskey(ack_slots, key)
        outcome = detected ? ack_slots[key] : failure_slots[key]
        source_slot = haskey(begin_slots, key) ? begin_slots[key].source_slot : missing
        observed_fidelity = if detected && !ismissing(source_slot)
            real(observable(
                [net[SOURCE_NODE], net[DESTINATION_NODE]],
                [source_slot, outcome.destination_slot],
                projector(perfect_pair),
            ))
        else
            NaN
        end
        (;
            flow_uuid,
            seq_num,
            source_slot,
            destination_slot=outcome.destination_slot,
            start_time=detected ? outcome.send_time : (haskey(begin_slots, key) ? begin_slots[key].start_time : NaN),
            ack_time=detected ? outcome.ack_time : NaN,
            rtt=detected ? outcome.rtt : NaN,
            detected,
            acked_at_source=detected,
            observed_fidelity,
        )
    end

    observed_pairs = filter(pair -> pair.detected && !isnan(pair.observed_fidelity), pairs)
    mean_observed_fidelity = isempty(observed_pairs) ? NaN : sum(pair.observed_fidelity for pair in observed_pairs) / length(observed_pairs)
    mean_rtt = isempty(source_ack_log) ? NaN : sum(ack.rtt for ack in source_ack_log) / length(source_ack_log)
    sent_requests_estimate = estimated_request_count(sim_time, request_rate, initial_request_delay)

    (;
        werner_w,
        expected_fidelity=fidelity_from_werner(werner_w),
        chi,
        request_rate,
        distance_km,
        a_eta,
        beta_per_km,
        transmissivity,
        success_prob,
        attempt_time,
        detection_prob,
        detector_a_p,
        source_window_size,
        source_ack_timeout,
        memory_slots,
        sent_requests_estimate,
        sent_requests=length(source_sent_log),
        completed_pairs=length(pairs),
        detected_pairs=length(ack_slots),
        acked_pairs=length(ack_slots),
        detected_throughput=length(ack_slots) / sim_time,
        failed_detections=length(failure_slots),
        source_timeouts=length(source_timeout_log),
        late_acks=length(source_late_ack_log),
        unacked_at_source=length(source_sent_log) - length(source_ack_log) - length(source_timeout_log),
        mean_observed_fidelity,
        mean_rtt,
        source_sent_log,
        source_ack_log,
        source_timeout_log,
        source_late_ack_log,
        pairs,
        sim,
        net,
    )
end

function read_cli_config()
    werner_w = isempty(ARGS) ? parse(Float64, get(ENV, "WERNER_W", string(DEFAULT_WERNER_W))) : parse(Float64, ARGS[1])
    sim_time = length(ARGS) >= 2 ? parse(Float64, ARGS[2]) : parse(Float64, get(ENV, "QTCP_SIM_TIME", string(DEFAULT_SIM_TIME)))
    chi = if length(ARGS) >= 3
        parse(Float64, ARGS[3])
    elseif haskey(ENV, "SOURCE_CHI")
        parse(Float64, ENV["SOURCE_CHI"])
    else
        DEFAULT_CHI
    end
    (werner_w=werner_w, sim_time=sim_time, chi=chi)
end

if abspath(PROGRAM_FILE) == @__FILE__
    config = read_cli_config()
    result = run_two_node_qtcp_werner(; config...)

    println("QTCP two-node Werner demo")
    println("  werner_w           = ", result.werner_w)
    println("  expected fidelity  = ", result.expected_fidelity)
    println("  distance km        = ", result.distance_km)
    println("  link transmiss.    = ", result.transmissivity)
    if !isnothing(result.chi)
        println("  chi                = ", result.chi)
    end
    println("  request rate       = ", result.request_rate)
    println("  source window size = ", result.source_window_size)
    println("  source ACK timeout = ", result.source_ack_timeout)
    println("  sent requests      = ", result.sent_requests)
    println("  completed requests = ", result.completed_pairs)
    println("  detection prob.    = ", result.detection_prob)
    println("  detector a_p       = ", result.detector_a_p)
    println("  detector ACKs      = ", result.acked_pairs)
    println("  failed detections  = ", result.failed_detections)
    println("  source timeouts    = ", result.source_timeouts)
    println("  unacked at source  = ", result.unacked_at_source)
    println("  mean RTT           = ", result.mean_rtt)
    println("  mean observed fid. = ", result.mean_observed_fidelity)
    for pair in result.pairs
        println(
            "  flow ", pair.flow_uuid,
            ": ACKed = ", pair.acked_at_source,
            ", RTT = ", pair.rtt,
            ", observed fidelity = ", pair.observed_fidelity,
            ", source slot = ", pair.source_slot,
            ", destination slot = ", pair.destination_slot,
        )
    end
end
