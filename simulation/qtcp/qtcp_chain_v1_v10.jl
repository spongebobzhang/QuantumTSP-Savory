using QuantumSavory
using QuantumSavory.ProtocolZoo
using ConcurrentSim
using Graphs
using Logging
using Test

const NODE_COUNT = 10
const MEMORY_SLOTS_PER_NODE = 5
const SOURCE_NODE = 1
const DESTINATION_NODE = 10
const FLOW_UUID = 1001
const REQUESTED_PAIRS = 3
const SIM_TIME = 2000.0
const VIDEO_FPS = 8
const PLOT_SCALE = 1.2
const PLOT_SLOT_SIZE = 0.14

function build_demo_network()
    registers = [Register(MEMORY_SLOTS_PER_NODE) for _ in 1:NODE_COUNT]
    net = RegisterNet(path_graph(NODE_COUNT), registers)
    sim = get_time_tracker(net)

    @process EndNodeController(sim, net, SOURCE_NODE)()
    @process EndNodeController(sim, net, DESTINATION_NODE)()

    for node in 1:NODE_COUNT
        @process NetworkNodeController(sim, net, node)()
    end

    for edge in edges(net)
        @process LinkController(sim=sim, net=net, nodeA=edge.src, nodeB=edge.dst)()
    end

    return sim, net
end

function add_node_labels!(cm, ax, coords)
    text_fn = getfield(cm, :text!)
    xs = [getproperty(c, :data)[1] for c in coords]
    ys = [getproperty(c, :data)[2] + 0.7 for c in coords]
    labels = ["v$(i)" for i in 1:NODE_COUNT]
    Base.invokelatest(text_fn, ax, xs, ys; text=labels, align=(:center, :bottom), color=:black, fontsize=16)
end

point2f(cm, x, y) = Base.invokelatest(getfield(cm, :Point2f), x, y)

function x_of(coord)
    getproperty(coord, :data)[1]
end

mutable struct EventLogger <: AbstractLogger
    records::Vector{NamedTuple{(:level, :message), Tuple{LogLevel, String}}}
end

EventLogger() = EventLogger(NamedTuple{(:level, :message), Tuple{LogLevel, String}}[])

Logging.min_enabled_level(::EventLogger) = Logging.Debug
Logging.shouldlog(::EventLogger, level, _module, group, id) = true
Logging.catch_exceptions(::EventLogger) = false

function Logging.handle_message(logger::EventLogger, level, message, _module, group, id, file, line; kwargs...)
    push!(logger.records, (level=level, message=string(message)))
end

function parse_int(pattern, text)
    m = match(pattern, text)
    isnothing(m) ? nothing : parse(Int, m.captures[1])
end

function build_event_log()
    sim_log, net_log = build_demo_network()
    logger = EventLogger()
    with_logger(logger) do
        put!(net_log[SOURCE_NODE], Flow(src=SOURCE_NODE, dst=DESTINATION_NODE, npairs=1, uuid=FLOW_UUID))
        run(sim_log, SIM_TIME)
    end
    logger.records
end

function parse_event(record)
    msg = record.message
    if occursin("ChannelForwarder: Forwarding message", msg)
        src = parse_int(r"from node (\d+)", msg)
        dst = parse_int(r"to node (\d+)", msg)
        label = if occursin("QDatagramSuccess", msg)
            "QDatagramSuccess v$(src) -> v$(dst)"
        else
            "Forwarded message v$(src) -> v$(dst)"
        end
        return (label=label, node=dst, src=src, kind=:transmission, hop=nothing)
    elseif occursin("MessageBuffer", msg) && occursin("Forwarding message to node", msg)
        src = parse_int(r"MessageBuffer @(\d+)", msg)
        dst = parse_int(r"Forwarding message to node (\d+)", msg)
        label = if occursin("QDatagramSuccess", msg)
            "QDatagramSuccess v$(src) -> v$(dst)"
        else
            "Forwarded message v$(src) -> v$(dst)"
        end
        return (label=label, node=dst, src=src, kind=:transmission, hop=nothing)
    elseif occursin("flow", msg) && occursin("started", msg)
        flow = parse_int(r"flow (\d+)", msg)
        return (label="Flow $(flow) started at v$(SOURCE_NODE)", node=SOURCE_NODE, src=nothing, kind=:local, hop=nothing)
    elseif occursin("returned to start node", msg)
        seq = parse_int(r"pair (\d+)", msg)
        return (label="QDatagramSuccess for pair $(seq) returned to v$(SOURCE_NODE)", node=SOURCE_NODE, src=DESTINATION_NODE, kind=:transmission, hop=nothing)
    elseif occursin("reached final destination", msg)
        seq = parse_int(r"pair (\d+)", msg)
        return (label="QDatagram pair $(seq) reached v$(DESTINATION_NODE)", node=DESTINATION_NODE, src=DESTINATION_NODE - 1, kind=:transmission, hop=nothing)
    elseif occursin("MessageBuffer", msg)
        node = parse_int(r"MessageBuffer @(\d+)", msg)
        src = parse_int(r"Receiving from source ([0-9]+)", msg)
        label = if occursin("Flow", msg)
            "Flow at v$(node)"
        elseif occursin("LinkLevelRequest", msg)
            remote = parse_int(r"remote node ([0-9]+)", msg)
            isnothing(remote) ? "LinkLevelRequest at v$(node)" : "LinkLevelRequest v$(node) -> v$(remote)"
        elseif occursin("LinkLevelReplyAtHop", msg)
            "LinkLevelReplyAtHop arrived at v$(node)"
        elseif occursin("LinkLevelReplyAtSource", msg)
            "LinkLevelReplyAtSource at v$(node)"
        elseif occursin("LinkLevelReply", msg)
            "LinkLevelReply at v$(node)"
        elseif occursin("QDatagramSuccess", msg)
            isnothing(src) ? "QDatagramSuccess at v$(node)" : "QDatagramSuccess v$(src) -> v$(node)"
        elseif occursin("QTCPPairBegin", msg)
            "QTCPPairBegin at v$(node)"
        elseif occursin("QTCPPairEnd", msg)
            "QTCPPairEnd at v$(node)"
        elseif occursin("QDatagram", msg)
            isnothing(src) ? "QDatagram at v$(node)" : "QDatagram v$(src) -> v$(node)"
        else
            nothing
        end
        isnothing(label) && return nothing
        if occursin("LinkLevelRequest", msg)
            remote = parse_int(r"remote node ([0-9]+)", msg)
            if !isnothing(remote)
                return (label=label, node=remote, src=node, kind=:request, hop=(min(node, remote), max(node, remote)))
            end
        elseif occursin("LinkLevelReplyAtHop", msg)
            reply_src = max(SOURCE_NODE, node - 1)
            return (label=label, node=node, src=reply_src, kind=:reply_hop, hop=(min(node, reply_src), max(node, reply_src)))
        elseif occursin("LinkLevelReplyAtSource", msg)
            return (label=label, node=node, src=nothing, kind=:local, hop=nothing)
        elseif occursin("LinkLevelReply", msg)
            reply_src = min(DESTINATION_NODE, node + 1)
            return (label=label, node=node, src=reply_src, kind=:reply, hop=(min(node, reply_src), max(node, reply_src)))
        end
        return (label=label, node=node, src=src, kind=isnothing(src) ? :local : :transmission, hop=nothing)
    end
    return nothing
end

function lerp_point(cm, a, b, t)
    point2f(cm, (1 - t) * x_of(a) + t * x_of(b), (1 - t) * getproperty(a, :data)[2] + t * getproperty(b, :data)[2])
end

function make_message_frames(cm, coords, events)
    frames = NamedTuple[]
    label_y = 2.2
    hold = 6
    move = 8

    function push_hold!(label, color, token_points, active_points, text_point)
        for _ in 1:hold
            push!(frames, (label=label, color=color, token_points=token_points, active_points=active_points, text_point=text_point))
        end
    end

    function push_move!(label, color, a, b, text_point; yshift=0.0)
        pa = point2f(cm, x_of(a), getproperty(a, :data)[2] + yshift)
        pb = point2f(cm, x_of(b), getproperty(b, :data)[2] + yshift)
        for step in 0:move
            t = step / move
            token = lerp_point(cm, pa, pb, t)
            push!(frames, (label=label, color=color, token_points=[token], active_points=[a, b], text_point=text_point))
        end
    end

    function push_reply_pair!(label, color, a, b, text_point)
        mid = point2f(cm, (x_of(a) + x_of(b)) / 2, 0.55)
        for step in 0:move
            t = step / move
            lefttok = lerp_point(cm, mid, a, t)
            righttok = lerp_point(cm, mid, b, t)
            push!(frames, (label=label, color=color, token_points=[lefttok, righttok, mid], active_points=[a, b], text_point=text_point))
        end
    end

    i = 1
    while i <= length(events)
        event = events[i]
        nodept = coords[event.node]
        text_point = point2f(cm, (x_of(coords[1]) + x_of(coords[end])) / 2, label_y)
        color = occursin("Request", event.label) ? :darkorange :
            occursin("Reply", event.label) ? :seagreen :
            occursin("Success", event.label) ? :purple :
            occursin("Pair", event.label) ? :crimson : :royalblue
        if occursin("QDatagramSuccess", event.label)
            push_move!(event.label, color, coords[DESTINATION_NODE], coords[SOURCE_NODE], text_point; yshift=0.55)
        elseif event.kind == :request && !isnothing(event.src)
            push_move!(event.label, color, coords[event.src], nodept, text_point; yshift=0.22)
        elseif event.kind == :reply && i < length(events) && events[i + 1].kind in (:reply_hop, :reply_source) && events[i + 1].hop == event.hop
            hopa, hopb = event.hop
            push_reply_pair!("LinkController on v$(hopa)-v$(hopb) sends replies", color, coords[hopa], coords[hopb], text_point)
            i += 1
        elseif isnothing(event.src)
            push_hold!(event.label, color, [nodept], [nodept], text_point)
        else
            srcpt = coords[event.src]
            push_move!(event.label, color, srcpt, nodept, text_point)
        end
        i += 1
    end
    return frames, label_y
end

function dedupe_events(events)
    deduped = typeof(events[begin:end])([])
    seen = Set{Tuple}()
    for event in events
        key = if event.kind in (:request, :reply, :reply_hop, :reply_source)
            (event.kind, event.hop, event.label)
        elseif occursin("QDatagramSuccess", event.label)
            (:qdatagram_success, FLOW_UUID)
        else
            (event.kind, event.src, event.node, event.label)
        end
        key in seen && continue
        push!(seen, key)
        push!(deduped, event)
    end
    deduped
end

function normalize_event_order(events)
    ordered = collect(events)
    reach_idx = findfirst(e -> occursin("reached v$(DESTINATION_NODE)", e.label), ordered)
    success_idx = findfirst(e -> occursin("QDatagramSuccess", e.label), ordered)
    if !isnothing(reach_idx) && !isnothing(success_idx) && success_idx < reach_idx
        reach_event = ordered[reach_idx]
        deleteat!(ordered, reach_idx)
        insert!(ordered, success_idx, reach_event)
    end
    ordered
end

function make_registercoords(cm)
    p2f = getfield(cm, :Point2f)
    [Base.invokelatest(p2f, 1.5 * (i - 1), 0.0) for i in 1:NODE_COUNT]
end

function save_network_snapshot(net)
    outpath = joinpath(@__DIR__, "qtcp_chain_v1_v10_network.png")
    try
        cm = Base.require(Main, :CairoMakie)
        Base.invokelatest(getfield(cm, :activate!))
        fig = Base.invokelatest(getfield(cm, :Figure), ; size=(1600, 300))
        coords = make_registercoords(cm)
        subfig = Base.invokelatest(getindex, fig, 1, 1)
        _, ax, _, _ = Base.invokelatest(
            registernetplot_axis,
            subfig,
            net;
            registercoords=coords,
            scale=PLOT_SCALE,
            slotsize=PLOT_SLOT_SIZE,
        )
        add_node_labels!(cm, ax, coords)
        Base.invokelatest(getfield(cm, :save), outpath, fig)
        println("Saved network snapshot to ", outpath)
    catch err
        @warn "Skipping network snapshot. Install/import CairoMakie to enable PNG rendering." exception=(err, catch_backtrace())
    end
end

function save_network_video()
    outpath = joinpath(@__DIR__, "qtcp_chain_v1_v10_messages.mp4")
    try
        cm = Base.require(Main, :CairoMakie)
        Base.invokelatest(getfield(cm, :activate!))
        fig = Base.invokelatest(getfield(cm, :Figure), ; size=(1600, 420))
        coords = make_registercoords(cm)
        events = normalize_event_order(dedupe_events(filter(!isnothing, parse_event.(build_event_log()))))
        point_type = typeof(coords[1])
        observable_ctor = getfield(cm, :Observable)
        token_obs = Base.invokelatest(observable_ctor, point_type[])
        active_obs = Base.invokelatest(observable_ctor, point_type[])
        text_pos_obs = Base.invokelatest(observable_ctor, point_type[])
        text_label_obs = Base.invokelatest(observable_ctor, String[])
        ax = Base.invokelatest(getfield(cm, :Axis), Base.invokelatest(getindex, fig, 1, 1))

        base_edges = point_type[]
        for hop in 1:(NODE_COUNT - 1)
            push!(base_edges, coords[hop], coords[hop + 1])
        end
        Base.invokelatest(getfield(cm, :linesegments!), ax, base_edges; color=:gray75, linewidth=4)
        Base.invokelatest(getfield(cm, :scatter!), ax, coords; color=:gray30, markersize=26)
        Base.invokelatest(getfield(cm, :linesegments!), ax, active_obs; color=:tomato, linewidth=8)
        Base.invokelatest(getfield(cm, :scatter!), ax, token_obs; color=:tomato, markersize=30)
        Base.invokelatest(
            getfield(cm, :text!),
            ax,
            text_pos_obs;
            text=text_label_obs,
            align=(:center, :center),
            color=:black,
            fontsize=24,
        )
        add_node_labels!(cm, ax, coords)
        Base.invokelatest(getfield(cm, :hidedecorations!), ax)
        Base.invokelatest(getfield(cm, :hidespines!), ax)
        Base.invokelatest(getfield(cm, :xlims!), ax, -0.8, x_of(coords[end]) + 0.8)
        Base.invokelatest(getfield(cm, :ylims!), ax, -0.6, 3.0)

        frames, _ = make_message_frames(cm, coords, events)
        record_fn = getfield(cm, :record)
        Base.invokelatest() do
            record_fn(fig, outpath, 1:length(frames); framerate=VIDEO_FPS) do frame_idx
                frame = frames[frame_idx]
                token_obs[] = frame.token_points
                active_obs[] = frame.active_points
                text_pos_obs[] = [frame.text_point]
                text_label_obs[] = [frame.label]
            end
        end
        println("Saved network video to ", outpath)
    catch err
        @warn "Skipping network video. Install/import CairoMakie with video support to enable MP4 export." exception=(err, catch_backtrace())
    end
end

sim, net = build_demo_network()

println("QTCP chain demo on v1 -> v10")
println("Nodes: ", join(["v$(i)" for i in 1:NODE_COUNT], " -> "))
println("Requested pairs: $(REQUESTED_PAIRS)")
println("Memory slots per node: $(MEMORY_SLOTS_PER_NODE)")
save_network_snapshot(net)
save_network_video()

flow = Flow(
    src=SOURCE_NODE,
    dst=DESTINATION_NODE,
    npairs=REQUESTED_PAIRS,
    uuid=FLOW_UUID
)

println("Injecting flow $(FLOW_UUID) at v$(SOURCE_NODE)")
put!(net[SOURCE_NODE], flow)
run(sim, SIM_TIME)

source_mb = messagebuffer(net, SOURCE_NODE)
destination_mb = messagebuffer(net, DESTINATION_NODE)
intermediate_buffers = [messagebuffer(net, node) for node in 2:9]

pair_begins = Any[]
pair_ends = Any[]

for _ in 1:REQUESTED_PAIRS
    pair_begin_msg = querydelete!(source_mb, QTCPPairBegin, ❓, ❓, ❓, ❓, ❓, ❓)
    pair_end_msg = querydelete!(destination_mb, QTCPPairEnd, ❓, ❓, ❓, ❓, ❓, ❓)
    @test !isnothing(pair_begin_msg)
    @test !isnothing(pair_end_msg)
    push!(pair_begins, pair_begin_msg.tag)
    push!(pair_ends, pair_end_msg.tag)
end

for mb in intermediate_buffers
    @test isempty(mb.buffer)
end

@test isempty(source_mb.buffer)
@test isempty(destination_mb.buffer)

println()
println("Source-side ready pairs at v$(SOURCE_NODE):")
for pair_begin in pair_begins
    println("  ", pair_begin)
end

println()
println("Destination-side ready pairs at v$(DESTINATION_NODE):")
for pair_end in pair_ends
    println("  ", pair_end)
end

println()
println("QTCP completed $(REQUESTED_PAIRS) end-to-end pairs across the 10-node chain.")
