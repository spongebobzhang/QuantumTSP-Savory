using QuantumSavory
using QuantumSavory.ProtocolZoo: AbstractProtocol
using ConcurrentSim
using ConcurrentSim: Simulation, @yield, timeout, @process, now
using Graphs
using Random
import QuantumSavory: Tag
import ResumableFunctions
using ResumableFunctions: @resumable

const QTSP_SOURCE_NODE = 1
const QTSP_DESTINATION_NODE = 2
const QTSP_DEFAULT_FLOW_UUID = 4001
const QTSP_DEFAULT_WERNER_W = 0.9
const QTSP_DEFAULT_MEMORY_SLOTS = 100
const QTSP_DEFAULT_STATE_COUNT = 10
const QTSP_DEFAULT_WINDOW_SIZE = 3
const QTSP_DEFAULT_SEND_INTERVAL = 0.0
const QTSP_DEFAULT_INITIAL_DELAY = 0.0
const QTSP_DEFAULT_CLASSICAL_DELAY = 0.0
const QTSP_DEFAULT_QUANTUM_DELAY = 1.0
const QTSP_DEFAULT_CHI = 1.0
const QTSP_DEFAULT_DISTANCE_KM = 0.0
const QTSP_DEFAULT_A_ETA = 1.0
const QTSP_DEFAULT_BETA_PER_KM = 0.0
const QTSP_DEFAULT_DETECTION_PROB = 1.0
const QTSP_DEFAULT_DETECTOR_A_P = 1.0
const QTSP_DEFAULT_SOURCE_ACK_TIMEOUT = 10.0
const QTSP_DEFAULT_WINDOW_STATS_INTERVAL = Inf
const QTSP_DEFAULT_SIM_TIME = 100.0
const QTSP_SOURCE_RETAIN_START_SLOT = 1
const QTSP_SOURCE_SEND_SLOT = 100
const QTSP_DESTINATION_RECEIVE_START_SLOT = 1
const QTSP_SOURCE_DEBUG_AFTER_TIME = parse(Float64,
    get(ENV, "QTSP_SOURCE_DEBUG_AFTER_TIME", "Inf"))
const QTSP_TIME_EPS = 1e-9

const QTSP_PERFECT_PAIR = (Z1 ⊗ Z1 + Z2 ⊗ Z2) / sqrt(2)
const QTSP_PERFECT_PAIR_DM = SProjector(QTSP_PERFECT_PAIR)
const QTSP_MIXED_PAIR_DM = MixedState(QTSP_PERFECT_PAIR_DM)

"""
    qtsp_werner_pair(w)

Return the two-qubit Werner/depolarized Bell pair used by QTSP:
`w * |Bell><Bell| + (1 - w) * I / 4`.
"""
function qtsp_werner_pair(w)
    0 <= w <= 1 || throw(ArgumentError("Werner parameter w must be in [0, 1]. Got $(w)."))

    w * QTSP_PERFECT_PAIR_DM + (1 - w) * QTSP_MIXED_PAIR_DM
end

qtsp_fidelity_from_werner(w) = (1 + 3 * w) / 4
qtsp_detector_success_probability(a_p, w) = a_p * qtsp_fidelity_from_werner(w)
qtsp_transmissivity_from_distance(distance_km, a_eta, beta_per_km) =
    a_eta * exp(-beta_per_km * distance_km / 2)
qtsp_source_generation_rate(chi, w; distance_km=QTSP_DEFAULT_DISTANCE_KM,
    a_eta=QTSP_DEFAULT_A_ETA, beta_per_km=QTSP_DEFAULT_BETA_PER_KM) =
    chi * 3 * (1 - w) / 2 *
    qtsp_transmissivity_from_distance(distance_km, a_eta, beta_per_km)

"""
The wrapper for one QTSP quantum payload. 
"""
@kwdef struct QTSPQuantumWrapper
    flow_uuid::Int = QTSP_DEFAULT_FLOW_UUID
    # for now seq_num is the same as pair_id
    seq_num::Int
    pair_id::Int
    # werner_w  used to calculate detection probability
    werner_w::Float64 = QTSP_DEFAULT_WERNER_W
    source_node::Int = QTSP_SOURCE_NODE
    destination_node::Int = QTSP_DESTINATION_NODE
    source_retain_slot::Int
    send_time::Float64
end

Base.show(io::IO, wrapper::QTSPQuantumWrapper) = print(io,
    "QTSPQuantumWrapper flow ", wrapper.flow_uuid,
    " state ", wrapper.seq_num,
    " pair ", wrapper.pair_id,
    " w ", wrapper.werner_w,
    " | ", wrapper.source_node, " -> ", wrapper.destination_node,
    " | retain slot ", wrapper.source_retain_slot,
    " | sent at ", wrapper.send_time)

struct QTSPQuantumPacket
    # metadata wrapper that travels with the quantum payload in the channel
    wrapper::QTSPQuantumWrapper
    # reg contains the traveling qubit, which will be swapped into the destination's receive slot upon arrival
    # here it is always 1 just to denote the channel has one slot for one qubit
    reg::Register
end

struct QTSPWrappedQuantumChannel{T}
    trait::T
    queue::ConcurrentSim.DelayQueue{QTSPQuantumPacket}
    background::Any
end

QTSPWrappedQuantumChannel(env::Simulation, delay, background=nothing, trait=Qubit()) =
    QTSPWrappedQuantumChannel(trait,
        ConcurrentSim.DelayQueue{QTSPQuantumPacket}(env, delay),
        background)

QTSPWrappedQuantumChannel(qc::QuantumChannel) =
    QTSPWrappedQuantumChannel(qc.queue.store.env, qc.queue.delay, qc.background, qc.trait)

QTSPWrappedQuantumChannel(qc::QTSPWrappedQuantumChannel) = qc

QuantumSavory.Register(qc::QTSPWrappedQuantumChannel) = Register([qc.trait], [qc.background])

function Base.put!(qc::QTSPWrappedQuantumChannel, wrapper::QTSPQuantumWrapper, rref::RegRef)
    time = ConcurrentSim.now(qc.queue.store.env)
    channel_reg = Register(qc)
    QuantumSavory.swap!(rref, channel_reg[1]; time)
    # the packet will be available to the destination after the channel delay
    uptotime!(channel_reg[1], time + qc.queue.delay)
    put!(qc.queue, QTSPQuantumPacket(wrapper, channel_reg))
end

@resumable function post_take_qtsp_wrapped_qc(env, take_event, rref)
    packet = @yield take_event
    if isassigned(rref)
        error("A take! operation is being performed on a QTSPWrappedQuantumChannel, " *
              "but the target register slot is not empty.")
    end
    # savory's funtion: tranfer the state from the channel register to the destination's receive slot
    QuantumSavory.swap!(packet.reg[1], rref; time=now(env))

    packet.wrapper
end
# the destination take the packet from the channel, 
# swap the quantum state into its register, and get the wrapper for processing
function Base.take!(qc::QTSPWrappedQuantumChannel, rref::RegRef)
    take_event = take!(qc.queue)
    @process post_take_qtsp_wrapped_qc(qc.queue.store.env, take_event, rref)
end

function qtsp_install_wrapped_qchannel!(net::RegisterNet, source_node::Int,
        destination_node::Int)
    wrapped = QTSPWrappedQuantumChannel(qchannel(net, source_node=>destination_node))
    net.qchannels[source_node=>destination_node] = wrapped

    wrapped
end
# calculate the next hop
function qtsp_next_hop(net::RegisterNet, current_node::Int, destination_node::Int)
    current_node != destination_node || throw(ArgumentError(
        "current_node and destination_node must be different. Got $(current_node).",
    ))
    # A* algorithm
    path_edges = Graphs.a_star(net.graph, current_node, destination_node)
    isempty(path_edges) && throw(ArgumentError(
        "No route from current_node=$(current_node) to destination_node=$(destination_node).",
    ))

    edge = first(path_edges)
    if edge.src == current_node
        edge.dst
    elseif edge.dst == current_node
        edge.src
    else
        throw(ArgumentError(
            "Shortest-path edge $(edge) is not connected to current_node=$(current_node).",
        ))
    end
end

function qtsp_previous_hop(net::RegisterNet, source_node::Int,
        destination_node::Int)
    source_node != destination_node || throw(ArgumentError(
        "source_node and destination_node must be different. Got $(source_node).",
    ))

    path_edges = Graphs.a_star(net.graph, source_node, destination_node)
    isempty(path_edges) && throw(ArgumentError(
        "No route from source_node=$(source_node) to destination_node=$(destination_node).",
    ))

    edge = last(path_edges)
    if edge.src == destination_node
        edge.dst
    elseif edge.dst == destination_node
        edge.src
    else
        throw(ArgumentError(
            "Shortest-path edge $(edge) is not connected to destination_node=$(destination_node).",
        ))
    end
end

# Helper functions for recording and printing QTSP experiment results
@kwdef struct QTSPStateInfo
    flow_uuid::Int = QTSP_DEFAULT_FLOW_UUID
    seq_num::Int
    pair_id::Union{Int,Missing} = missing
    source_node::Int = QTSP_SOURCE_NODE
    destination_node::Int = QTSP_DESTINATION_NODE
    source_retain_slot::Union{Int,Missing} = missing
    source_send_slot::Union{Int,Missing} = missing
    destination_slot::Union{Int,Missing} = missing
    send_time::Float64 = NaN
    receive_time::Float64 = NaN
    ack_time::Float64 = NaN
    timeout_time::Float64 = NaN
    quantum_delivery_time::Float64 = NaN
    rtt::Float64 = NaN
    observed_fidelity::Float64 = NaN
    sent::Bool = false
    received::Bool = false
    acked::Bool = false
    detected::Bool = false
    failed_detection::Bool = false
    timed_out::Bool = false
end

@kwdef struct QTSPForwardInfo
    flow_uuid::Int = QTSP_DEFAULT_FLOW_UUID
    seq_num::Int
    pair_id::Int
    node::Int
    previous_node::Int
    next_node::Int
    forward_slot::Int
    receive_time::Float64
    send_time::Float64
end

@kwdef mutable struct QTSPSourceControl
    window_size::Int = QTSP_DEFAULT_WINDOW_SIZE
    werner_w::Float64 = QTSP_DEFAULT_WERNER_W
    send_interval::Float64 = QTSP_DEFAULT_SEND_INTERVAL
end

qtsp_state_key(info::QTSPStateInfo) = (info.flow_uuid, info.seq_num)
qtsp_state_key(flow_uuid, seq_num) = (flow_uuid, seq_num)

# window information. It's to calculate window-based throughput and other stats.
@kwdef struct QTSPWindowInfo
    flow_uuid::Int = QTSP_DEFAULT_FLOW_UUID
    window_index::Int
    window_start::Float64
    window_end::Float64
    sent_count::Int
    acked_count::Int
    timeout_count::Int
    late_ack_count::Int
    acked_throughput::Float64
    sent_seq_nums::Vector{Int}
    acked_seq_nums::Vector{Int}
    timed_out_seq_nums::Vector{Int}
    late_ack_seq_nums::Vector{Int}
    mean_rtt::Float64 = NaN
end

"""
ACK returned by the destination after one QTSP state has arrived.
"""
@kwdef struct QTSPAck
    flow_uuid::Int = QTSP_DEFAULT_FLOW_UUID
    seq_num::Int
    pair_id::Int
    source_node::Int = QTSP_SOURCE_NODE
    destination_node::Int = QTSP_DESTINATION_NODE
    destination_slot::Int
    receive_time::Float64
end

Base.show(io::IO, ack::QTSPAck) = print(io,
    "QTSPAck flow ", ack.flow_uuid,
    " state ", ack.seq_num,
    " pair ", ack.pair_id,
    " | ", ack.source_node, " -> ", ack.destination_node,
    " | destination slot ", ack.destination_slot,
    " | received at ", ack.receive_time)

Tag(ack::QTSPAck) = Tag(QTSPAck, ack.flow_uuid, ack.seq_num, ack.source_node,
    ack.destination_node, ack.destination_slot, ack.receive_time)

@kwdef struct QTSPSourceController <: AbstractProtocol
    sim::Simulation
    net::RegisterNet
    source_node::Int = QTSP_SOURCE_NODE
    destination_node::Int = QTSP_DESTINATION_NODE
    flow_uuid::Int = QTSP_DEFAULT_FLOW_UUID
    state_count::Union{Int,Nothing} = nothing
    source_stop_time::Float64 = Inf
    window_size::Int = QTSP_DEFAULT_WINDOW_SIZE
    source_retain_slots::Int = window_size
    werner_w::Float64 = QTSP_DEFAULT_WERNER_W
    source_retain_start_slot::Int = QTSP_SOURCE_RETAIN_START_SLOT
    source_send_slot::Int = QTSP_SOURCE_SEND_SLOT
    send_interval::Float64 = QTSP_DEFAULT_SEND_INTERVAL
    initial_delay::Float64 = QTSP_DEFAULT_INITIAL_DELAY
    source_ack_timeout::Float64 = QTSP_DEFAULT_SOURCE_ACK_TIMEOUT
    window_stats_interval::Float64 = QTSP_DEFAULT_WINDOW_STATS_INTERVAL
    control::Union{QTSPSourceControl,Nothing} = nothing
    window_update_callback::Any = nothing
    send_log::Vector{QTSPStateInfo}
    ack_log::Vector{QTSPStateInfo}
    timeout_log::Vector{QTSPStateInfo}
    late_ack_log::Vector{QTSPStateInfo}
    window_log::Vector{QTSPWindowInfo} = QTSPWindowInfo[]
end

@kwdef struct QTSPDestinationController <: AbstractProtocol
    sim::Simulation
    net::RegisterNet
    source_node::Int = QTSP_SOURCE_NODE
    destination_node::Int = QTSP_DESTINATION_NODE
    flow_uuid::Int = QTSP_DEFAULT_FLOW_UUID
    state_count::Union{Int,Nothing} = nothing
    window_size::Int = QTSP_DEFAULT_WINDOW_SIZE
    source_retain_start_slot::Int = QTSP_SOURCE_RETAIN_START_SLOT
    destination_receive_start_slot::Int = QTSP_DESTINATION_RECEIVE_START_SLOT
    detector_a_p::Float64 = QTSP_DEFAULT_DETECTOR_A_P
    detection_prob::Union{Float64,Nothing} = QTSP_DEFAULT_DETECTION_PROB
    rng::Random.AbstractRNG = Random.default_rng()
    receive_log::Vector{QTSPStateInfo}
    failure_log::Vector{QTSPStateInfo}
end

@kwdef struct QTSPQuantumRouter <: AbstractProtocol
    sim::Simulation
    net::RegisterNet
    previous_node::Int
    node::Int
    destination_node::Int
    state_count::Union{Int,Nothing} = nothing
    forward_slot::Int
    flow_uuid::Union{Int,Nothing} = nothing
    forward_log::Vector{QTSPForwardInfo} = QTSPForwardInfo[]
end

"""
The source node will keep two kinds of slots: send slots and retain slots;
retains slots are used to simulate the memory: it will keep the traveling qubits until they are acknowledged or timed out, 
and Window size is actually the number of retain slots. 
The send slot is used to simulate the operation of sending a qubit into the channel.

This function is to check the validity of the source node's retain and send slots before simulation starts.
"""
function validate_qtsp_source_slots!(net, source_node, window_size,
        source_retain_start_slot, source_send_slot)
    window_size > 0 || throw(ArgumentError("window_size must be positive. Got $(window_size)."))
    source_retain_start_slot > 0 || throw(ArgumentError("source_retain_start_slot must be positive. Got $(source_retain_start_slot)."))
    source_send_slot > 0 || throw(ArgumentError("source_send_slot must be positive. Got $(source_send_slot)."))

    retain_slots = source_retain_start_slot:(source_retain_start_slot + window_size - 1)
    !(source_send_slot in retain_slots) || throw(ArgumentError(
        "source_send_slot=$(source_send_slot) overlaps retained slots $(first(retain_slots)):$(last(retain_slots)).",
    ))

    last_slot = max(last(retain_slots), source_send_slot)
    last_slot <= length(net[source_node]) || throw(ArgumentError(
        "Source register needs at least $(last_slot) slots to retain $(window_size) in-flight qubits and send one qubit. " *
        "It has $(length(net[source_node])).",
    ))

    nothing
end

function validate_qtsp_destination_slots!(net, destination_node,
        destination_receive_start_slot)
    destination_receive_start_slot > 0 || throw(ArgumentError("destination_receive_start_slot must be positive. Got $(destination_receive_start_slot)."))

    last_slot = destination_receive_start_slot
    last_slot <= length(net[destination_node]) || throw(ArgumentError(
        "Destination register needs at least $(last_slot) slots to receive one qubit. " *
        "It has $(length(net[destination_node])).",
    ))

    nothing
end

function qtsp_current_window_size(window_size, source_retain_slots, control)
    requested_window_size = isnothing(control) ? window_size : control.window_size
    requested_window_size > 0 || throw(ArgumentError(
        "window_size must be positive. Got $(requested_window_size).",
    ))

    min(requested_window_size, source_retain_slots)
end

function qtsp_current_werner_w(werner_w, control)
    current_werner_w = isnothing(control) ? werner_w : control.werner_w
    0 <= current_werner_w <= 1 || throw(ArgumentError(
        "Werner parameter w must be in [0, 1]. Got $(current_werner_w).",
    ))

    current_werner_w
end
# get the current send interval
function qtsp_current_send_interval(send_interval, control)
    current_send_interval = isnothing(control) ? send_interval : control.send_interval
    current_send_interval >= 0 || throw(ArgumentError(
        "send_interval must be non-negative. Got $(current_send_interval).",
    ))

    current_send_interval
end

function next_qtsp_retain_slot(net, source_node, source_retain_start_slot,
        source_retain_slots, seq_num, pending)
    pending_slots = Set(sent.source_retain_slot for sent in values(pending))

    for offset in 0:(source_retain_slots - 1)
        slot = source_retain_start_slot + mod(seq_num - 1 + offset, source_retain_slots)
        if !(slot in pending_slots) && !isassigned(net[source_node], slot)
            return slot
        end
    end

    nothing
end

function qtsp_packet_detection_probability(detection_prob, detector_a_p, werner_w)
    packet_detection_prob = isnothing(detection_prob) ?
        qtsp_detector_success_probability(detector_a_p, werner_w) :
        detection_prob
    0 <= packet_detection_prob <= 1 || throw(ArgumentError(
        "packet detection probability must be in [0, 1]. Got $(packet_detection_prob).",
    ))

    packet_detection_prob
end
# its to check if the source can send more states and the destination can receive more states
qtsp_state_cap_reached(sent_count, state_count::Nothing) = false
qtsp_state_cap_reached(sent_count, state_count::Int) = sent_count >= state_count

function qtsp_wait_for_ack_or_timer(sim, mb, wait_delay)
    if isfinite(wait_delay)
        timeout(sim, max(wait_delay, 1e-12)) | onchange(mb)
    else
        onchange(mb)
    end
end
# retrieve ACKs from the buffer and updated the pending states
function drain_qtsp_acks!(net, source_node, mb, pending, ack_log, late_ack_log,
        current_time)
    acked_count = 0

    while true
        ack_msg = querydelete!(mb, QTSPAck, ❓, ❓, ❓, ❓, ❓, ❓)
        isnothing(ack_msg) && break

        _, flow_uuid, seq_num, source_node_for_ack, destination_node, destination_slot,
            receive_time = ack_msg.tag
        pair_id = seq_num
        key = qtsp_state_key(flow_uuid, seq_num)
        if haskey(pending, key)
            sent = pop!(pending, key)
            push!(ack_log, QTSPStateInfo(;
                flow_uuid,
                seq_num,
                pair_id,
                source_node=source_node_for_ack,
                destination_node,
                source_retain_slot=sent.source_retain_slot,
                source_send_slot=sent.source_send_slot,
                destination_slot,
                send_time=sent.send_time,
                receive_time,
                ack_time=current_time,
                quantum_delivery_time=receive_time - sent.send_time,
                rtt=current_time - sent.send_time,
                sent=true,
                received=true,
                acked=true,
                detected=true,
            ))
            isassigned(net[source_node], sent.source_retain_slot) &&
                traceout!(net[source_node, sent.source_retain_slot])
            acked_count += 1
        else
            push!(late_ack_log, QTSPStateInfo(;
                flow_uuid,
                seq_num,
                pair_id,
                source_node=source_node_for_ack,
                destination_node,
                destination_slot,
                receive_time,
                ack_time=current_time,
                received=true,
                acked=true,
                detected=true,
            ))
        end
    end

    acked_count
end
# check for timed out states and update the pending states
function expire_qtsp_source_timeouts!(net, source_node, pending, timeout_log,
        source_ack_timeout, current_time)
    isfinite(source_ack_timeout) || return 0

    timed_out_keys = Tuple{Int,Int}[]
    for (key, sent) in pending
        if sent.send_time + source_ack_timeout <= current_time + QTSP_TIME_EPS
            push!(timed_out_keys, key)
        end
    end

    for key in sort(timed_out_keys, by=last)
        sent = pop!(pending, key)
        push!(timeout_log, QTSPStateInfo(;
            flow_uuid=sent.flow_uuid,
            seq_num=sent.seq_num,
            pair_id=sent.pair_id,
            source_node=sent.source_node,
            destination_node=sent.destination_node,
            source_retain_slot=sent.source_retain_slot,
            source_send_slot=sent.source_send_slot,
            send_time=sent.send_time,
            timeout_time=current_time,
            sent=true,
            timed_out=true,
        ))
        isassigned(net[source_node], sent.source_retain_slot) &&
            traceout!(net[source_node, sent.source_retain_slot])
    end

    length(timed_out_keys)
end
# calculate the delay until the next timeout expires, 
# itss used to determine how long the source should wait before checking for timeouts again
function next_qtsp_timeout_delay(pending, source_ack_timeout, current_time)
    (!isfinite(source_ack_timeout) || isempty(pending)) && return Inf

    next_timeout_time = Inf
    for sent in values(pending)
        next_timeout_time = min(next_timeout_time, sent.send_time + source_ack_timeout)
    end
    delay = next_timeout_time - current_time

    delay <= QTSP_TIME_EPS ? 0.0 : delay
end

function record_qtsp_window_info!(window_log, flow_uuid, window_index,
        window_start, window_end, sent_seq_nums, acked_seq_nums,
        timed_out_seq_nums, late_ack_seq_nums, acked_rtts)
    window_duration = window_end - window_start

    push!(window_log, QTSPWindowInfo(;
        flow_uuid,
        window_index,
        window_start,
        window_end,
        sent_count=length(sent_seq_nums),
        acked_count=length(acked_seq_nums),
        timeout_count=length(timed_out_seq_nums),
        late_ack_count=length(late_ack_seq_nums),
        acked_throughput=length(acked_seq_nums) / window_duration,
        sent_seq_nums=copy(sent_seq_nums),
        acked_seq_nums=copy(acked_seq_nums),
        timed_out_seq_nums=copy(timed_out_seq_nums),
        late_ack_seq_nums=copy(late_ack_seq_nums),
        mean_rtt=isempty(acked_rtts) ? NaN : sum(acked_rtts) / length(acked_rtts),
    ))
end
"""
This is the main controller function for the QTSP source. 
It will keep sending new states until the simulation ends, 
and process ACKs and timeouts to update the state. 
It also records the state information and statistics.
"""
@resumable function (prot::QTSPSourceController)()
    (; sim, net, source_node, destination_node, flow_uuid, state_count, source_stop_time,
        werner_w, window_size, source_retain_slots, source_retain_start_slot,
        source_send_slot, send_interval, initial_delay, source_ack_timeout,
        window_stats_interval, control, window_update_callback, send_log, ack_log,
        timeout_log, late_ack_log, window_log) = prot
    # check check check all parameters
    !isnothing(state_count) && state_count > 0 || isnothing(state_count) ||
        throw(ArgumentError("state_count must be positive or nothing. Got $(state_count)."))
    validate_qtsp_source_slots!(net, source_node, source_retain_slots,
        source_retain_start_slot, source_send_slot)
    window_size > 0 || throw(ArgumentError("window_size must be positive. Got $(window_size)."))
    source_retain_slots >= window_size || throw(ArgumentError(
        "source_retain_slots must be at least window_size. Got source_retain_slots=$(source_retain_slots), window_size=$(window_size).",
    ))
    send_interval >= 0 || throw(ArgumentError("send_interval must be non-negative. Got $(send_interval)."))
    initial_delay >= 0 || throw(ArgumentError("initial_delay must be non-negative. Got $(initial_delay)."))
    source_ack_timeout > 0 || throw(ArgumentError("source_ack_timeout must be positive. Got $(source_ack_timeout)."))
    window_stats_interval > 0 || throw(ArgumentError("window_stats_interval must be positive. Got $(window_stats_interval)."))
    source_stop_time >= initial_delay || throw(ArgumentError(
        "source_stop_time must be greater than or equal to initial_delay. Got $(source_stop_time).",
    ))
    # initialize 
    source_mb = messagebuffer(net, source_node)
    next_hop = qtsp_next_hop(net, source_node, destination_node)
    qch = qchannel(net, source_node=>next_hop)
    qch isa QTSPWrappedQuantumChannel || throw(ArgumentError(
        "QTSPSourceController requires a QTSPWrappedQuantumChannel. " *
        "Call qtsp_install_wrapped_qchannel!(net, $(source_node), $(next_hop)) first.",
    ))
    qtsp_current_window_size(window_size, source_retain_slots, control)
    qtsp_current_werner_w(werner_w, control)
    qtsp_current_send_interval(send_interval, control)
    pending = Dict{Tuple{Int,Int},QTSPStateInfo}()
    next_send_time = initial_delay
    sent_count = 0
    acked_count = 0
    timeout_count = 0
    sample_window_stats = isfinite(window_stats_interval)
    window_index = 1
    window_start_time = initial_delay
    next_window_stats_time = initial_delay + window_stats_interval
    window_sent_seq_nums = Int[]
    window_acked_seq_nums = Int[]
    window_timeout_seq_nums = Int[]
    window_late_ack_seq_nums = Int[]
    window_acked_rtts = Float64[]
    source_debug_iterations = 0

    @yield timeout(sim, initial_delay)
    # main loop: keep sending new states until the simulation ends
    # process ACKs and timeouts
    while now(sim) < source_stop_time || !isempty(pending)
        current_time = now(sim)
        if sample_window_stats
            # window stats are recorded every window_stats_interval
            while current_time >= next_window_stats_time
                record_qtsp_window_info!(window_log, flow_uuid, window_index,
                    window_start_time, next_window_stats_time, window_sent_seq_nums,
                    window_acked_seq_nums, window_timeout_seq_nums,
                    window_late_ack_seq_nums, window_acked_rtts)
                if !isnothing(window_update_callback)
                    window_update_callback(window_log[end])
                    next_send_time = next_window_stats_time
                end
                empty!(window_sent_seq_nums)
                empty!(window_acked_seq_nums)
                empty!(window_timeout_seq_nums)
                empty!(window_late_ack_seq_nums)
                empty!(window_acked_rtts)
                window_index += 1
                window_start_time = next_window_stats_time
                # update next recording time
                next_window_stats_time += window_stats_interval
            end
        end

        ack_log_start = length(ack_log)
        timeout_log_start = length(timeout_log)
        late_ack_log_start = length(late_ack_log)
        # process ACKs
        acked_count += drain_qtsp_acks!(net, source_node, source_mb, pending,
            ack_log, late_ack_log,
            current_time)
        # process timeouts
        timeout_count += expire_qtsp_source_timeouts!(net, source_node, pending, timeout_log,
            source_ack_timeout, current_time)
        if sample_window_stats
            for index in (ack_log_start + 1):length(ack_log)
                push!(window_acked_seq_nums, ack_log[index].seq_num)
                push!(window_acked_rtts, ack_log[index].rtt)
            end
            for index in (timeout_log_start + 1):length(timeout_log)
                push!(window_timeout_seq_nums, timeout_log[index].seq_num)
            end
            for index in (late_ack_log_start + 1):length(late_ack_log)
                push!(window_late_ack_seq_nums, late_ack_log[index].seq_num)
            end
        end

        current_time = now(sim)
        retain_slot_blocked = false
        # keep sending new states
        while !qtsp_state_cap_reached(sent_count, state_count) &&
                current_time < source_stop_time &&
                current_time >= next_send_time
            current_window_size = qtsp_current_window_size(window_size,
                source_retain_slots, control)
            length(pending) < current_window_size || break
            current_werner_w = qtsp_current_werner_w(werner_w, control)
            current_send_interval = qtsp_current_send_interval(send_interval, control)
            seq_num = sent_count + 1
            pair_id = seq_num
            send_time = current_time
            source_retain_slot = next_qtsp_retain_slot(net, source_node,
                source_retain_start_slot, source_retain_slots, seq_num, pending)
            if isnothing(source_retain_slot)
                retain_slot_blocked = true
                break
            end
            # create the packet wrapper
            wrapper = QTSPQuantumWrapper(;
                flow_uuid,
                seq_num,
                pair_id,
                werner_w=current_werner_w,
                source_node,
                destination_node,
                source_retain_slot,
                send_time,
            )
            state_info = QTSPStateInfo(;
                flow_uuid,
                seq_num,
                pair_id,
                source_node,
                destination_node,
                source_retain_slot,
                source_send_slot,
                send_time,
                sent=true,
            )
            # for a pair the sender will keep one qubit in retain slot and send the other
            pairstate = qtsp_werner_pair(current_werner_w)
            initialize!((net[source_node, source_retain_slot], net[source_node, source_send_slot]),
                pairstate; time=send_time)
            put!(qch, wrapper, net[source_node, source_send_slot])
            sent_count += 1
            pending[qtsp_state_key(state_info)] = state_info
            push!(send_log, state_info)
            sample_window_stats && push!(window_sent_seq_nums, seq_num)

            next_send_time = send_time + current_send_interval
            current_time = now(sim)
            iszero(current_send_interval) || break
        end

        now(sim) >= source_stop_time && isempty(pending) && break
        qtsp_state_cap_reached(sent_count, state_count) && isempty(pending) && break

        current_window_size = qtsp_current_window_size(window_size, source_retain_slots,
            control)
        send_delay = if !qtsp_state_cap_reached(sent_count, state_count) &&
                now(sim) < source_stop_time &&
                !retain_slot_blocked &&
                length(pending) < current_window_size
            max(0.0, next_send_time - now(sim))
        else
            Inf
        end
        timeout_delay = next_qtsp_timeout_delay(pending, source_ack_timeout, now(sim))
        window_stats_delay = sample_window_stats ?
            max(0.0, next_window_stats_time - now(sim)) : Inf

        # the delay we may wait before doing the next action
        wait_delay = min(send_delay, timeout_delay, window_stats_delay)
        if now(sim) >= QTSP_SOURCE_DEBUG_AFTER_TIME
            source_debug_iterations += 1
            if source_debug_iterations <= 20 ||
                    source_debug_iterations % 100_000 == 0
                println(stderr,
                    "[qtsp-source-debug] t=", now(sim),
                    " pending=", length(pending),
                    " sent_count=", sent_count,
                    " next_send_time=", next_send_time,
                    " current_window_size=", current_window_size,
                    " retain_slot_blocked=", retain_slot_blocked,
                    " send_delay=", send_delay,
                    " timeout_delay=", timeout_delay,
                    " window_stats_delay=", window_stats_delay,
                    " wait_delay=", wait_delay)
                flush(stderr)
            end
            source_debug_iterations <= 1_000_000 || error(
                "QTSP source exceeded 1,000,000 debug iterations after time $(QTSP_SOURCE_DEBUG_AFTER_TIME).",
            )
        end
        # wait for the next:
        # time to send the next state, or a timeout expires, or it's time to record the next window stats
        # also if onchange(mb) it will process immediately 
        @yield qtsp_wait_for_ack_or_timer(sim, source_mb, wait_delay)
    end
    # record the final time window
    if sample_window_stats && (
            !isempty(window_sent_seq_nums) ||
            !isempty(window_acked_seq_nums) ||
            !isempty(window_timeout_seq_nums) ||
            !isempty(window_late_ack_seq_nums))
        record_qtsp_window_info!(window_log, flow_uuid, window_index,
            window_start_time, next_window_stats_time, window_sent_seq_nums,
            window_acked_seq_nums, window_timeout_seq_nums, window_late_ack_seq_nums,
            window_acked_rtts)
    end
end
"""
This controller for destination is to receive the quantum states sent by the source, 
    record the information, and send ACKs back to the source.
"""
@resumable function (prot::QTSPDestinationController)()
    (; sim, net, source_node, destination_node, flow_uuid, state_count, window_size,
        source_retain_start_slot, destination_receive_start_slot,
        detector_a_p, detection_prob, rng, receive_log, failure_log) = prot

    !isnothing(state_count) && state_count > 0 || isnothing(state_count) ||
        throw(ArgumentError("state_count must be positive or nothing. Got $(state_count)."))
    validate_qtsp_destination_slots!(net, destination_node, destination_receive_start_slot)
    detector_a_p >= 0 || throw(ArgumentError("detector_a_p must be non-negative. Got $(detector_a_p)."))
    isnothing(detection_prob) || 0 <= detection_prob <= 1 ||
        throw(ArgumentError("detection_prob must be in [0, 1] or nothing. Got $(detection_prob)."))

    previous_hop = qtsp_previous_hop(net, source_node, destination_node)
    qch = qchannel(net, previous_hop=>destination_node)
    qch isa QTSPWrappedQuantumChannel || throw(ArgumentError(
        "QTSPDestinationController requires a QTSPWrappedQuantumChannel. " *
        "Call qtsp_install_wrapped_qchannel!(net, $(previous_hop), $(destination_node)) first.",
    ))
    ack_channel = channel(net, destination_node=>source_node; permit_forward=true)
    receive_slot = destination_receive_start_slot
    received_count = 0

    while !qtsp_state_cap_reached(received_count, state_count)
        # take the packet from channel and process
        wrapper = @yield take!(qch, net[destination_node, receive_slot])
        received_count += 1

        receive_time = now(sim)
        flow_uuid = wrapper.flow_uuid
        seq_num = wrapper.seq_num
        pair_id = wrapper.pair_id
        source_node = wrapper.source_node
        destination_node = wrapper.destination_node
        source_retain_slot = wrapper.source_retain_slot
        send_time = wrapper.send_time
        observed_fidelity = if isassigned(net[source_node], source_retain_slot)
            real(observable(
                (net[source_node, source_retain_slot], net[destination_node, receive_slot]),
                projector(QTSP_PERFECT_PAIR),
            ))
        else
            NaN
        end
        # calculate the probability of successfully detecting the packet
        packet_detection_prob = qtsp_packet_detection_probability(detection_prob,
            detector_a_p, wrapper.werner_w)
        # random number
        detected = rand(rng) <= packet_detection_prob
        receive_info = QTSPStateInfo(;
            flow_uuid,
            seq_num,
            pair_id,
            source_node,
            destination_node,
            source_retain_slot,
            destination_slot=receive_slot,
            send_time,
            receive_time,
            quantum_delivery_time=receive_time - send_time,
            observed_fidelity,
            received=true,
            detected,
            failed_detection=!detected,
        )
        push!(receive_log, receive_info)
        # send ACK
        if detected
            put!(ack_channel, QTSPAck(;
                flow_uuid,
                seq_num,
                pair_id,
                source_node,
                destination_node,
                destination_slot=receive_slot,
                receive_time,
            ))
        else
            push!(failure_log, receive_info)
        end
        # clear the qubits in the source retain slot and destination receive slot 
        # its to make the simulation quicker and the source will still keep track of the state information
        isassigned(net[source_node], source_retain_slot) &&
            traceout!(net[source_node, source_retain_slot])
        traceout!(net[destination_node, receive_slot])
    end
end

@resumable function (prot::QTSPQuantumRouter)()
    (; sim, net, previous_node, node, destination_node, state_count, forward_slot,
        flow_uuid, forward_log) = prot

    node != destination_node || throw(ArgumentError(
        "QTSPQuantumRouter forwards through intermediate nodes only. Node $(node) is the destination.",
    ))
    !isnothing(state_count) && state_count > 0 || isnothing(state_count) ||
        throw(ArgumentError("state_count must be positive or nothing. Got $(state_count)."))
    forward_slot > 0 || throw(ArgumentError("forward_slot must be positive. Got $(forward_slot)."))
    forward_slot <= length(net[node]) || throw(ArgumentError(
        "Router node $(node) needs slot $(forward_slot), but it has $(length(net[node])) slots.",
    ))
    # listen to the channel from previous_node
    incoming_qch = qchannel(net, previous_node=>node)
    incoming_qch isa QTSPWrappedQuantumChannel || throw(ArgumentError(
        "QTSPQuantumRouter requires a QTSPWrappedQuantumChannel for $(previous_node)=>$(node). " *
        "Call qtsp_install_wrapped_qchannel!(net, $(previous_node), $(node)) first.",
    ))

    forwarded_count = 0
    while !qtsp_state_cap_reached(forwarded_count, state_count)
        # take the packet from channel and process
        wrapper = @yield take!(incoming_qch, net[node, forward_slot])
        receive_time = now(sim)

        if !isnothing(flow_uuid) && wrapper.flow_uuid != flow_uuid
            throw(ArgumentError(
                "Router node $(node) received flow $(wrapper.flow_uuid), expected $(flow_uuid).",
            ))
        end

        next_node = qtsp_next_hop(net, node, destination_node)
        outgoing_qch = qchannel(net, node=>next_node)
        outgoing_qch isa QTSPWrappedQuantumChannel || throw(ArgumentError(
            "QTSPQuantumRouter requires a QTSPWrappedQuantumChannel for $(node)=>$(next_node). " *
            "Call qtsp_install_wrapped_qchannel!(net, $(node), $(next_node)) first.",
        ))

        put!(outgoing_qch, wrapper, net[node, forward_slot])
        send_time = now(sim)
        push!(forward_log, QTSPForwardInfo(;
            flow_uuid=wrapper.flow_uuid,
            seq_num=wrapper.seq_num,
            pair_id=wrapper.pair_id,
            node,
            previous_node,
            next_node,
            forward_slot,
            receive_time,
            send_time,
        ))
        forwarded_count += 1
    end
end

function qtsp_install_wrapped_qchannels!(net::RegisterNet)
    for (; src, dst) in Graphs.edges(net.graph)
        qtsp_install_wrapped_qchannel!(net, src, dst)
        qtsp_install_wrapped_qchannel!(net, dst, src)
    end

    net
end

function qtsp_routing_path(net::RegisterNet, source_node::Int,
        destination_node::Int)
    route = [source_node]
    visited = Set(route)

    while last(route) != destination_node
        next_node = qtsp_next_hop(net, last(route), destination_node)
        next_node in visited && throw(ArgumentError(
            "QTSP routing loop detected while routing $(source_node)=>$(destination_node): $(route) then $(next_node).",
        ))
        push!(route, next_node)
        push!(visited, next_node)
    end

    route
end

function qtsp_route_quantum_delay(net::RegisterNet, route)
    sum(qchannel(net, src=>dst).queue.delay
        for (src, dst) in zip(route[1:(end - 1)], route[2:end]))
end

function qtsp_route_classical_delay(net::RegisterNet, source_node::Int,
        destination_node::Int)
    route = qtsp_routing_path(net, source_node, destination_node)

    sum(net.cchannels[src=>dst].delay
        for (src, dst) in zip(route[1:(end - 1)], route[2:end]))
end

function estimated_qtsp_network_completion_time(; state_count,
        route_quantum_delay, route_classical_delay, send_interval, initial_delay,
        source_ack_timeout)
    initial_delay + state_count *
        (max(source_ack_timeout, route_quantum_delay + route_classical_delay) +
         send_interval)
end

function launch_qtsp_quantum_routers!(sim, net; source_node, destination_node,
        state_count, forward_slot, flow_uuid, forward_log)
    for node in Graphs.vertices(net.graph)
        (node == source_node || node == destination_node) && continue
        for previous_node in Graphs.neighbors(net.graph, node)
            @process QTSPQuantumRouter(;
                sim,
                net,
                previous_node,
                node,
                destination_node,
                state_count,
                forward_slot,
                flow_uuid,
                forward_log,
            )()
        end
    end

    nothing
end

function qtsp_mean_or_nan(values)
    collected = collect(values)
    isempty(collected) ? NaN : sum(collected) / length(collected)
end

function run_network_qtsp(; net,
        source_node,
        destination_node,
        state_count=nothing,
        flow_uuid=QTSP_DEFAULT_FLOW_UUID,
        werner_w=QTSP_DEFAULT_WERNER_W,
        window_size=QTSP_DEFAULT_WINDOW_SIZE,
        chi=QTSP_DEFAULT_CHI,
        send_rate=nothing,
        distance_km=QTSP_DEFAULT_DISTANCE_KM,
        a_eta=QTSP_DEFAULT_A_ETA,
        beta_per_km=QTSP_DEFAULT_BETA_PER_KM,
        detector_a_p=QTSP_DEFAULT_DETECTOR_A_P,
        detection_prob=nothing,
        source_retain_slots=nothing,
        source_retain_start_slot=QTSP_SOURCE_RETAIN_START_SLOT,
        source_send_slot=nothing,
        destination_receive_start_slot=QTSP_DESTINATION_RECEIVE_START_SLOT,
        forward_slot=QTSP_DESTINATION_RECEIVE_START_SLOT,
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
    source_retain_slots = something(source_retain_slots, window_size)
    source_retain_slots >= window_size || throw(ArgumentError(
        "source_retain_slots must be at least window_size. Got source_retain_slots=$(source_retain_slots), window_size=$(window_size).",
    ))
    source_send_slot = something(source_send_slot,
        source_retain_start_slot + source_retain_slots)
    initial_delay >= 0 || throw(ArgumentError("initial_delay must be non-negative. Got $(initial_delay)."))
    source_ack_timeout > 0 || throw(ArgumentError("source_ack_timeout must be positive. Got $(source_ack_timeout)."))
    window_stats_interval > 0 || throw(ArgumentError("window_stats_interval must be positive. Got $(window_stats_interval)."))

    transmissivity = qtsp_transmissivity_from_distance(distance_km, a_eta,
        beta_per_km)
    detection_prob = something(detection_prob,
        qtsp_detector_success_probability(detector_a_p, werner_w))
    0 <= detection_prob <= 1 || throw(ArgumentError("detection_prob must be in [0, 1]. Got $(detection_prob)."))

    if isnothing(send_rate)
        isnothing(chi) && throw(ArgumentError("Provide either chi or send_rate."))
        chi >= 0 || throw(ArgumentError("chi must be non-negative. Got $(chi)."))
        send_rate = qtsp_source_generation_rate(chi, werner_w; distance_km,
            a_eta, beta_per_km)
    end
    send_rate > 0 || throw(ArgumentError(
        "The send rate must be positive. Got $(send_rate) for chi=$(chi), w=$(werner_w).",
    ))
    send_interval = something(send_interval, 1 / send_rate)
    send_interval >= 0 || throw(ArgumentError("send_interval must be non-negative. Got $(send_interval)."))

    sim = get_time_tracker(net)
    qtsp_install_wrapped_qchannels!(net)
    memory_slots = minimum(length(register) for register in net.registers)

    route = qtsp_routing_path(net, source_node, destination_node)
    route_quantum_delay = qtsp_route_quantum_delay(net, route)
    route_classical_delay = qtsp_route_classical_delay(net, destination_node,
        source_node)

    run_until = if isnothing(sim_time)
        isnothing(state_count) ?
            QTSP_DEFAULT_SIM_TIME :
            estimated_qtsp_network_completion_time(;
                state_count,
                route_quantum_delay,
                route_classical_delay,
                send_interval,
                initial_delay,
                source_ack_timeout,
            ) + 1e-9
    else
        sim_time
    end
    run_until > 0 || throw(ArgumentError("sim_time must be positive. Got $(run_until)."))

    send_log = QTSPStateInfo[]
    receive_log = QTSPStateInfo[]
    ack_log = QTSPStateInfo[]
    timeout_log = QTSPStateInfo[]
    late_ack_log = QTSPStateInfo[]
    failure_log = QTSPStateInfo[]
    window_log = QTSPWindowInfo[]
    forward_log = QTSPForwardInfo[]

    launch_qtsp_quantum_routers!(sim, net; source_node, destination_node,
        state_count, forward_slot, flow_uuid, forward_log)

    @process QTSPDestinationController(;
        sim,
        net,
        source_node,
        destination_node,
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
        source_node,
        destination_node,
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

    run(sim, run_until + QTSP_TIME_EPS)

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
            source_node,
            destination_node,
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
    fidelity_records = filter(record -> record.received &&
        !isnan(record.observed_fidelity), state_records)
    completion_times = [
        (entry.ack_time for entry in ack_log)...,
        (entry.timeout_time for entry in timeout_log)...,
    ]
    total_time = isnothing(state_count) ? run_until :
        (isempty(completion_times) ? now(sim) : maximum(completion_times))

    (;
        state_count,
        flow_uuid,
        source_node,
        destination_node,
        route,
        hop_count=length(route) - 1,
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
        forward_slot,
        route_classical_delay,
        route_quantum_delay,
        send_interval,
        initial_delay,
        source_ack_timeout,
        window_stats_interval,
        sim_time=run_until,
        total_time,
        sent_states=length(send_log),
        received_states=length(receive_log),
        acked_states=length(ack_log),
        forwarded_states=length(forward_log),
        failed_detections=length(failure_log),
        source_timeouts=length(timeout_log),
        late_acks=length(late_ack_log),
        unacked_at_source=length(send_log) - length(ack_log) - length(timeout_log),
        delivery_throughput=isempty(receive_log) ? 0.0 : length(receive_log) / total_time,
        acked_throughput=isempty(ack_log) ? 0.0 : length(ack_log) / total_time,
        mean_quantum_delivery_time=qtsp_mean_or_nan(
            record.quantum_delivery_time for record in received_records),
        mean_rtt=qtsp_mean_or_nan(record.rtt for record in acked_records),
        mean_observed_fidelity=qtsp_mean_or_nan(
            record.observed_fidelity for record in fidelity_records),
        send_log,
        receive_log,
        ack_log,
        timeout_log,
        late_ack_log,
        failure_log,
        forward_log,
        window_log,
        window_samples=length(window_log),
        mean_window_sent=qtsp_mean_or_nan(entry.sent_count for entry in window_log),
        mean_window_acked=qtsp_mean_or_nan(entry.acked_count for entry in window_log),
        mean_window_timeouts=qtsp_mean_or_nan(entry.timeout_count for entry in window_log),
        state_records,
        sim,
        net,
    )
end
