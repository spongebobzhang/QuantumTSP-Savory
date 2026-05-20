using QuantumSavory
using QuantumSavory.ProtocolZoo
using QuantumSavory.ProtocolZoo: AbstractProtocol
using ConcurrentSim
using ConcurrentSim: Simulation, @yield, timeout, @process, now
using Graphs
using Random
import ResumableFunctions
using ResumableFunctions: @resumable

const SOURCE_NODE = 1
const DESTINATION_NODE = 2
const FLOW_UUID_START = 3001
const DEFAULT_WERNER_W = 0.9
const DEFAULT_MEMORY_SLOTS = 100
const DEFAULT_SIM_TIME = 20.0
const DEFAULT_ATTEMPT_TIME = 0.0
const DEFAULT_SUCCESS_PROB = 1.0
const DEFAULT_CHI = 1.0
const DEFAULT_DISTANCE_KM = 0.0
const DEFAULT_A_ETA = 1.0
const DEFAULT_BETA_PER_KM = 0.0
const DEFAULT_INITIAL_REQUEST_DELAY = 0.0
const DEFAULT_DETECTION_PROB = 1.0
const DEFAULT_DETECTOR_A_P = 1.0
const DEFAULT_SOURCE_WINDOW_SIZE = 3
const DEFAULT_SOURCE_ACK_TIMEOUT = 10.0

const perfect_pair = (Z1 ⊗ Z1 + Z2 ⊗ Z2) / sqrt(2)
const perfect_pair_dm = SProjector(perfect_pair)
const mixed_pair_dm = MixedState(perfect_pair_dm)

const QTCP_DETECTOR_ACK = :QTCPDetectorAck
const QTCP_DETECTED_PAIR_END = :QTCPDetectedPairEnd
const QTCP_DETECTION_FAILURE = :QTCPDetectionFailure

"""
    werner_pair(w)

Return the two-qubit Werner/depolarized Bell pair
`w * |Bell><Bell| + (1 - w) * I / 4`.

This demo treats `w` as a mixing parameter in `[0, 1]`.
The Bell-state fidelity is `(1 + 3w) / 4`.
"""
function werner_pair(w)
    0 <= w <= 1 || throw(ArgumentError("Werner parameter w must be in [0, 1]. Got $(w)."))
    w * perfect_pair_dm + (1 - w) * mixed_pair_dm
end

werner_from_fidelity(fidelity) = (4 * fidelity - 1) / 3
fidelity_from_werner(w) = (1 + 3 * w) / 4
detector_success_probability(a_p, w) = a_p * fidelity_from_werner(w)
# calculate the transimission attenuation based on the slides
transmissivity_from_distance(distance_km, a_eta, beta_per_km) = a_eta * exp(-beta_per_km * distance_km / 2)
source_generation_rate(chi, w; distance_km=DEFAULT_DISTANCE_KM,
    a_eta=DEFAULT_A_ETA, beta_per_km=DEFAULT_BETA_PER_KM) =
    chi * 3 * (1 - w) / 2 * transmissivity_from_distance(distance_km, a_eta, beta_per_km)

@kwdef struct WernerLinkController <: AbstractProtocol
    sim::Simulation
    net::RegisterNet
    nodeA::Int
    nodeB::Int
    werner_w::Float64 = DEFAULT_WERNER_W
    success_prob::Float64 = DEFAULT_SUCCESS_PROB
    attempt_time::Float64 = DEFAULT_ATTEMPT_TIME
end

@kwdef struct DestinationDetector <: AbstractProtocol
    sim::Simulation
    net::RegisterNet
    source_node::Int = SOURCE_NODE
    destination_node::Int = DESTINATION_NODE
    detection_prob::Float64 = DEFAULT_DETECTION_PROB
    rng::Random.AbstractRNG = Random.default_rng()
end

@kwdef struct SourceWindowController <: AbstractProtocol
    sim::Simulation
    net::RegisterNet
    request_rate::Float64
    source_window_size::Int = DEFAULT_SOURCE_WINDOW_SIZE
    initial_delay::Float64 = DEFAULT_INITIAL_REQUEST_DELAY
    source_node::Int = SOURCE_NODE
    destination_node::Int = DESTINATION_NODE
    uuid_start::Int = FLOW_UUID_START
    source_ack_timeout::Float64 = DEFAULT_SOURCE_ACK_TIMEOUT
    sent_log::Vector{NamedTuple}
    ack_log::Vector{NamedTuple}
    timeout_log::Vector{NamedTuple}
    late_ack_log::Vector{NamedTuple}
end

function WernerLinkController(net::RegisterNet, nodeA::Int, nodeB::Int; kwargs...)
    WernerLinkController(; sim=get_time_tracker(net), net, nodeA, nodeB, kwargs...)
end

@resumable function (prot::WernerLinkController)()
    (; sim, net, nodeA, nodeB, werner_w, success_prob, attempt_time) = prot
    mbA = messagebuffer(net, nodeA)
    mbB = messagebuffer(net, nodeB)
    pairstate = werner_pair(werner_w)

    while true
        llrequestA = querydelete!(mbA, LinkLevelRequest, ❓, ❓, nodeB)
        llrequest, originator_node, destination_node = if isnothing(llrequestA)
            querydelete!(mbB, LinkLevelRequest, ❓, ❓, nodeA), nodeB, nodeA
        else
            llrequestA, nodeA, nodeB
        end

        if !isnothing(llrequest)
            _, flow_uuid, seq_num, _remote_node = llrequest.tag
            entangler = EntanglerProt(;
                sim,
                net,
                nodeA,
                nodeB,
                tag=nothing,
                pairstate,
                rounds=1,
                attempts=-1,
                success_prob,
                attempt_time,
            )

            proc = @process entangler()
            _, slotA, _, slotB = @yield proc
            originator_slot, destination_slot = if originator_node == nodeA
                slotA, slotB
            else
                slotB, slotA
            end

            put!(net[originator_node], LinkLevelReply(;
                flow_uuid,
                seq_num,
                memory_slot=originator_slot,
            ))
            put!(net[destination_node], LinkLevelReplyAtHop(;
                flow_uuid,
                seq_num,
                memory_slot=destination_slot,
            ))
        end

        @yield onchange(mbA) | onchange(mbB)
    end
end

@resumable function (prot::DestinationDetector)()
    (; sim, net, source_node, destination_node, detection_prob, rng) = prot
    mb = messagebuffer(net, destination_node)

    while true
        pair_end_msg = querydelete!(mb, QTCPPairEnd, ❓, ❓, destination_node, ❓, ❓, ❓)

        if !isnothing(pair_end_msg)
            _, flow_uuid, _flow_src, _flow_dst, seq_num, destination_slot, _start_time = pair_end_msg.tag
            # random number
            if rand(rng) <= detection_prob
                detected_pair = Tag(QTCP_DETECTED_PAIR_END,
                    flow_uuid, source_node, destination_node, seq_num, destination_slot)
                ack = Tag(QTCP_DETECTOR_ACK,
                    flow_uuid, source_node, destination_node, seq_num, destination_slot)

                put!(net[destination_node], detected_pair)
                # put ACK to the channel back to the source node
                # here the classical channel has no delay and it can be set
                # can be found in src/networks.jl: RegisterNet
                put!(channel(net, destination_node=>source_node; permit_forward=true), ack)
            else
                failure = Tag(QTCP_DETECTION_FAILURE,
                    flow_uuid, source_node, destination_node, seq_num, destination_slot)
                put!(net[destination_node], failure)
            end
        end

        @yield onchange(mb)
    end
end

# source will retrieve all detector ACK and check if it's late
function drain_source_detector_acks!(mb, pending, ack_log, late_ack_log, source_node, destination_node, current_time)
    while true
        ack_msg = querydelete!(mb, QTCP_DETECTOR_ACK, ❓, source_node, destination_node, ❓, ❓)
        isnothing(ack_msg) && break
        # get info from ACK tag
        _, flow_uuid, _, _, seq_num, destination_slot = ack_msg.tag
        # if the flow id is in pending, it's a successful ACK
        # then push it into ack_log
        # otherwise it's late so push it into late_ack_log
        if haskey(pending, flow_uuid)
            sent = pop!(pending, flow_uuid)
            push!(ack_log, (;
                flow_uuid,
                seq_num,
                destination_slot,
                send_time=sent.send_time,
                ack_time=current_time,
                rtt=current_time - sent.send_time,
            ))
        else
            push!(late_ack_log, (;
                flow_uuid,
                seq_num,
                destination_slot,
                ack_time=current_time,
            ))
        end
    end
end

"""
this function will check the pending flows and delete time-out ones
and log into timeout_log
"""
function expire_source_ack_timeouts!(pending, timeout_log, source_ack_timeout, current_time)
    isfinite(source_ack_timeout) || return

    timed_out_flows = [
        flow_uuid for (flow_uuid, sent) in pending
        # check the time
        if current_time - sent.send_time >= source_ack_timeout
    ]

    for flow_uuid in sort(timed_out_flows)
        sent = pop!(pending, flow_uuid)
        push!(timeout_log, (;
            flow_uuid,
            seq_num=sent.seq_num,
            send_time=sent.send_time,
            timeout_time=current_time,
            age=current_time - sent.send_time,
        ))
    end
end

"""
This function will calculate the time until the next pending flow times out.
It will tell the source controller how long to wait before checking the pending flows again.
"""
function next_source_timeout_delay(pending, source_ack_timeout, current_time)
    (!isfinite(source_ack_timeout) || isempty(pending)) && return Inf

    next_timeout_time = minimum(sent.send_time + source_ack_timeout for sent in values(pending))
    # return the time until the next timeout
    return max(0.0, next_timeout_time - current_time)
end

function source_controller_wait_event(sim, mb, pending, wait_delay)
    timer_event = timeout(sim, max(wait_delay, 1e-12))

    # if the pending is empty, we can just wait for the timer event
    # otherwise we need to wait for either the timer event or a new ACK in the message
    isempty(pending) ? timer_event : timer_event | onchange(mb)
end

@resumable function (prot::SourceWindowController)()
    (; sim, net, request_rate, source_window_size, initial_delay, source_node,
        destination_node, uuid_start, source_ack_timeout, sent_log, ack_log,
        timeout_log, late_ack_log) = prot
    request_rate > 0 || throw(ArgumentError("request_rate must be positive. Got $(request_rate)."))
    source_window_size > 0 || throw(ArgumentError("source_window_size must be positive. Got $(source_window_size)."))
    source_ack_timeout > 0 || throw(ArgumentError("source_ack_timeout must be positive. Got $(source_ack_timeout)."))

    mb = messagebuffer(net, source_node)
    # define the period
    period = 1 / request_rate
    uuid = uuid_start
    next_send_time = initial_delay
    pending = Dict{Int,NamedTuple}()

    @yield timeout(sim, initial_delay)
    while true
        current_time = now(sim)
        drain_source_detector_acks!(mb, pending, ack_log, late_ack_log,
            source_node, destination_node, current_time)
        expire_source_ack_timeouts!(pending, timeout_log, source_ack_timeout, current_time)

        if length(pending) < source_window_size && current_time >= next_send_time
            put!(net[source_node], Flow(;
                src=source_node,
                dst=destination_node,
                npairs=1,
                uuid,
            ))
            push!(sent_log, (;
                flow_uuid=uuid,
                seq_num=1,
                send_time=now(sim),
            ))
            pending[uuid] = (;
                seq_num=1,
                send_time=now(sim),
            )
            uuid += 1
            next_send_time = current_time + period
            continue
        end
        # to decide the frequency of checking the pending flows
        # send delay is the time until we can send the next request
        # timeout delay is the time until the next pending request times out
        send_delay = length(pending) < source_window_size ? max(0.0, next_send_time - current_time) : Inf
        timeout_delay = next_source_timeout_delay(pending, source_ack_timeout, current_time)

        wait_delay = min(send_delay, timeout_delay, period)

        @yield source_controller_wait_event(sim, mb, pending, wait_delay)
    end
end

function estimated_request_count(sim_time, request_rate, initial_delay)
    initial_delay > sim_time && return 0
    floor(Int, (sim_time - initial_delay) * request_rate) + 1
end
