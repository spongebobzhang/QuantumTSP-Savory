using QuantumSavory
using QuantumSavory.ProtocolZoo
using ConcurrentSim
using Graphs
using Logging
using Test

const EDGE_LIST_PATH = joinpath(@__DIR__, "edge_list.txt")
const NODE_COUNT = 20
const MEMORY_SLOTS_PER_NODE = 6
const SOURCE_NODE = 1 # original graph node, labeled as v0
const DEFAULT_DEST_LABEL = 15
const FLOW_UUID = 2001
const REQUESTED_PAIRS = 1
const SIM_TIME = 1500.0
const VIDEO_FPS = 8
const PLOT_SCALE = 0.8
const PLOT_SLOT_SIZE = 0.03

node_label(node) = "v$(node - 1)"

point2f(cm, x, y) = Base.invokelatest(getfield(cm, :Point2f), x, y)
x_of(coord) = getproperty(coord, :data)[1]
y_of(coord) = getproperty(coord, :data)[2]

function parse_int(pattern, text)
    m = match(pattern, text)
    isnothing(m) ? nothing : parse(Int, m.captures[1])
end

function parse_destination_node()
    raw = if !isempty(ARGS)
        ARGS[1]
    else
        get(ENV, "QTCP_DST_LABEL", string(DEFAULT_DEST_LABEL))
    end
    label = try
        parse(Int, raw)
    catch
        throw(ArgumentError("Destination label must be an integer in 1:$(NODE_COUNT-1). Got `$(raw)`"))
    end
    1 <= label <= NODE_COUNT - 1 || throw(ArgumentError("Destination label must be in 1:$(NODE_COUNT-1). Got $(label)"))
    label + 1
end

const DESTINATION_NODE = parse_destination_node()

function build_demo_graph()
    graph = SimpleGraph(NODE_COUNT)
    open(EDGE_LIST_PATH, "r") do io
        for (lineno, line) in enumerate(eachline(io))
            stripped = strip(line)
            isempty(stripped) && continue
            startswith(stripped, "#") && continue
            parts = split(stripped)
            length(parts) == 2 || throw(ArgumentError("Invalid edge list line $(lineno): `$(line)`"))
            a = parse(Int, parts[1])
            b = parse(Int, parts[2])
            1 <= a <= NODE_COUNT || throw(ArgumentError("Invalid node $(a) on line $(lineno)"))
            1 <= b <= NODE_COUNT || throw(ArgumentError("Invalid node $(b) on line $(lineno)"))
            a == b && continue
            add_edge!(graph, a, b)
        end
    end
    is_connected(graph) || throw(ArgumentError("Edge-list graph is not connected: $(EDGE_LIST_PATH)"))
    return graph
end

function route_nodes(graph)
    path = Graphs.a_star(graph, SOURCE_NODE, DESTINATION_NODE)
    isempty(path) && throw(ArgumentError("No A* route found from $(node_label(SOURCE_NODE)) to $(node_label(DESTINATION_NODE))"))
    [path[1].src; [edge.dst for edge in path]]
end

function make_registercoords(cm)
    point_type = typeof(point2f(cm, 0.0, 0.0))
    coords = Vector{point_type}(undef, NODE_COUNT)
    for node in 1:NODE_COUNT
        theta = 2π * (node - 1) / NODE_COUNT
        radius_x = 6.0
        radius_y = 3.0
        coords[node] = point2f(cm, radius_x * cos(theta), radius_y * sin(theta))
    end
    coords
end

function build_demo_network()
    graph = build_demo_graph()
    registers = [Register(MEMORY_SLOTS_PER_NODE) for _ in 1:NODE_COUNT]
    net = RegisterNet(graph, registers)
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
    xs = [x_of(c) for c in coords]
    ys = [y_of(c) + 0.35 for c in coords]
    labels = [node_label(i) for i in 1:NODE_COUNT]
    Base.invokelatest(text_fn, ax, xs, ys; text=labels, align=(:center, :bottom), color=:black, fontsize=12)
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

function build_event_log()
    sim_log, net_log = build_demo_network()
    logger = EventLogger()
    with_logger(logger) do
        put!(net_log[SOURCE_NODE], Flow(src=SOURCE_NODE, dst=DESTINATION_NODE, npairs=1, uuid=FLOW_UUID))
        run(sim_log, SIM_TIME)
    end
    logger.records
end

function parse_flow_seq(msg)
    m = match(r"flow (\d+), sequence (\d+)", msg)
    isnothing(m) && return nothing
    parse(Int, m.captures[1]), parse(Int, m.captures[2])
end

function extract_events(records)
    events = NamedTuple[]
    active_hop = Dict{Tuple{Int, Int}, Tuple{Int, Int}}()

    for record in records
        msg = record.message

        if occursin("flow", msg) && occursin("started", msg)
            flow = parse_int(r"flow (\d+)", msg)
            push!(events, (label="Flow $(flow) started at $(node_label(SOURCE_NODE))", node=SOURCE_NODE, src=nothing, kind=:local, hop=nothing))
            continue
        end

        if occursin("reached final destination", msg)
            seq = parse_int(r"pair (\d+)", msg)
            push!(events, (label="QDatagram pair $(seq) reached $(node_label(DESTINATION_NODE))", node=DESTINATION_NODE, src=nothing, kind=:local, hop=nothing))
            continue
        end

        if occursin("ChannelForwarder: Forwarding message from node", msg)
            src = parse_int(r"from node ([0-9]+)", msg)
            dst = parse_int(r"to node ([0-9]+)", msg)

            if occursin("QDatagramSuccess", msg)
                push!(events, (label="QDatagramSuccess $(node_label(src)) -> $(node_label(dst))", node=dst, src=src, kind=:transmission, hop=nothing))
                continue
            end

            if occursin("QDatagram", msg)
                push!(events, (label="QDatagram $(node_label(src)) -> $(node_label(dst))", node=dst, src=src, kind=:transmission, hop=nothing))
                continue
            end
        end

        if !occursin("MessageBuffer", msg) || !occursin("Receiving from source", msg)
            continue
        end

        node = parse_int(r"MessageBuffer @(\d+)", msg)
        src = parse_int(r"Receiving from source ([0-9]+)", msg)
        if occursin("LinkLevelRequest", msg)
            pair = parse_flow_seq(msg)
            remote = parse_int(r"remote node ([0-9]+)", msg)
            if !isnothing(pair) && !isnothing(remote)
                active_hop[pair] = (node, remote)
                push!(events, (label="LinkLevelRequest $(node_label(node)) -> $(node_label(remote))", node=remote, src=node, kind=:request, hop=(node, remote)))
            end
            continue
        end

        if occursin("LinkLevelReplyAtSource", msg)
            push!(events, (label="LinkLevelReplyAtSource at $(node_label(node))", node=node, src=nothing, kind=:local, hop=nothing))
            continue
        end

        if occursin("LinkLevelReplyAtHop", msg)
            pair = parse_flow_seq(msg)
            hop = isnothing(pair) ? nothing : get(active_hop, pair, nothing)
            if !isnothing(hop)
                push!(events, (label="LinkLevelReplyAtHop at $(node_label(node))", node=node, src=hop[1], kind=:reply_hop, hop=hop))
            end
            continue
        end

        if occursin("LinkLevelReply", msg)
            pair = parse_flow_seq(msg)
            hop = isnothing(pair) ? nothing : get(active_hop, pair, nothing)
            if !isnothing(hop)
                push!(events, (label="LinkLevelReply at $(node_label(node))", node=node, src=hop[2], kind=:reply, hop=hop))
            end
            continue
        end

        if occursin("QTCPPairBegin", msg)
            push!(events, (label="QTCPPairBegin at $(node_label(node))", node=node, src=nothing, kind=:local, hop=nothing))
            continue
        end

        if occursin("QTCPPairEnd", msg)
            push!(events, (label="QTCPPairEnd at $(node_label(node))", node=node, src=nothing, kind=:local, hop=nothing))
            continue
        end

        if occursin("QDatagramSuccess", msg)
            if !isnothing(src)
                push!(events, (label="QDatagramSuccess $(node_label(src)) -> $(node_label(node))", node=node, src=src, kind=:transmission, hop=nothing))
            end
            push!(events, (label="QDatagramSuccess received at $(node_label(node))", node=node, src=nothing, kind=:local, hop=nothing))
            continue
        end

        if occursin("QDatagram", msg)
            if !isnothing(src)
                push!(events, (label="QDatagram $(node_label(src)) -> $(node_label(node))", node=node, src=src, kind=:transmission, hop=nothing))
            end
            push!(events, (label="QDatagram received at $(node_label(node))", node=node, src=nothing, kind=:local, hop=nothing))
            continue
        end
    end

    events
end

function dedupe_events(events)
    deduped = typeof(events[begin:end])([])
    seen = Set{Tuple}()
    for event in events
        key = if event.kind in (:request, :reply, :reply_hop)
            (event.kind, event.hop, event.label)
        elseif event.kind == :transmission
            (event.kind, event.src, event.node, event.label)
        else
            (event.kind, event.node, event.label)
        end
        key in seen && continue
        push!(seen, key)
        push!(deduped, event)
    end
    deduped
end

function normalize_event_order(events)
    ordered = collect(events)
    reach_idx = findfirst(e -> occursin("reached $(node_label(DESTINATION_NODE))", e.label), ordered)
    success_idx = findfirst(e -> occursin("QDatagramSuccess", e.label), ordered)
    if !isnothing(reach_idx) && !isnothing(success_idx) && success_idx < reach_idx
        reach_event = ordered[reach_idx]
        deleteat!(ordered, reach_idx)
        insert!(ordered, success_idx, reach_event)
    end
    ordered
end

function lerp_point(cm, a, b, t)
    point2f(cm, (1 - t) * x_of(a) + t * x_of(b), (1 - t) * y_of(a) + t * y_of(b))
end

function make_message_frames(cm, coords, events)
    frames = NamedTuple[]
    label_y = 3.8
    hold = 8
    move = 10

    function push_hold!(label, token_points, active_points, text_point)
        for _ in 1:hold
            push!(frames, (label=label, token_points=token_points, active_points=active_points, text_point=text_point))
        end
    end

    function push_move!(label, a, b, text_point; yshift=0.0)
        pa = point2f(cm, x_of(a), y_of(a) + yshift)
        pb = point2f(cm, x_of(b), y_of(b) + yshift)
        for step in 0:move
            t = step / move
            token = lerp_point(cm, pa, pb, t)
            push!(frames, (label=label, token_points=[token], active_points=[a, b], text_point=text_point))
        end
    end

    function push_reply_pair!(label, a, b, text_point)
        mid = point2f(cm, (x_of(a) + x_of(b)) / 2, (y_of(a) + y_of(b)) / 2 + 0.4)
        for step in 0:move
            t = step / move
            lefttok = lerp_point(cm, mid, a, t)
            righttok = lerp_point(cm, mid, b, t)
            push!(frames, (label=label, token_points=[lefttok, righttok, mid], active_points=[a, b], text_point=text_point))
        end
    end

    i = 1
    while i <= length(events)
        event = events[i]
        nodept = coords[event.node]
        text_point = point2f(cm, 0.0, label_y)

        if event.kind == :request && !isnothing(event.src)
            push_move!(event.label, coords[event.src], nodept, text_point; yshift=0.2)
        elseif event.kind == :reply && i < length(events) && events[i + 1].kind == :reply_hop && events[i + 1].hop == event.hop
            a, b = event.hop
            push_reply_pair!("LinkController on $(node_label(a))-$(node_label(b)) sends replies", coords[a], coords[b], text_point)
            i += 1
        elseif event.kind == :transmission && !isnothing(event.src)
            push_move!(event.label, coords[event.src], nodept, text_point; yshift=occursin("Success", event.label) ? 0.45 : 0.0)
        else
            push_hold!(event.label, [nodept], [nodept], text_point)
        end
        i += 1
    end
    frames
end

function save_network_snapshot(graph)
    outpath = joinpath(@__DIR__, "qtcp_edgelist_v0_$(DESTINATION_NODE - 1).png")
    try
        cm = Base.require(Main, :CairoMakie)
        Base.invokelatest(getfield(cm, :activate!))
        fig = Base.invokelatest(getfield(cm, :Figure), ; size=(1600, 900))
        coords = make_registercoords(cm)
        plot_net = RegisterNet(graph, [Register(MEMORY_SLOTS_PER_NODE) for _ in 1:NODE_COUNT])
        subfig = Base.invokelatest(getindex, fig, 1, 1)
        _, ax, _, _ = Base.invokelatest(
            registernetplot_axis,
            subfig,
            plot_net;
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

function save_network_video(graph)
    outpath = joinpath(@__DIR__, "qtcp_edgelist_v0_$(DESTINATION_NODE - 1)_messages.mp4")
    try
        cm = Base.require(Main, :CairoMakie)
        Base.invokelatest(getfield(cm, :activate!))
        fig = Base.invokelatest(getfield(cm, :Figure), ; size=(1600, 900))
        coords = make_registercoords(cm)
        records = build_event_log()
        events = normalize_event_order(dedupe_events(extract_events(records)))
        point_type = typeof(coords[1])
        observable_ctor = getfield(cm, :Observable)
        token_obs = Base.invokelatest(observable_ctor, point_type[])
        active_obs = Base.invokelatest(observable_ctor, point_type[])
        text_pos_obs = Base.invokelatest(observable_ctor, point_type[])
        text_label_obs = Base.invokelatest(observable_ctor, String[])
        ax = Base.invokelatest(getfield(cm, :Axis), Base.invokelatest(getindex, fig, 1, 1))

        base_edges = point_type[]
        for (; src, dst) in edges(graph)
            push!(base_edges, coords[src], coords[dst])
        end
        Base.invokelatest(getfield(cm, :linesegments!), ax, base_edges; color=:gray75, linewidth=2)
        Base.invokelatest(getfield(cm, :scatter!), ax, coords; color=:gray30, markersize=16)
        Base.invokelatest(getfield(cm, :linesegments!), ax, active_obs; color=:tomato, linewidth=5)
        Base.invokelatest(getfield(cm, :scatter!), ax, token_obs; color=:tomato, markersize=18)
        Base.invokelatest(getfield(cm, :text!), ax, text_pos_obs; text=text_label_obs, align=(:center, :center), color=:black, fontsize=20)
        add_node_labels!(cm, ax, coords)
        Base.invokelatest(getfield(cm, :hidedecorations!), ax)
        Base.invokelatest(getfield(cm, :hidespines!), ax)
        Base.invokelatest(getfield(cm, :xlims!), ax, -7.0, 7.0)
        Base.invokelatest(getfield(cm, :ylims!), ax, -4.5, 4.5)

        frames = make_message_frames(cm, coords, events)
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

graph = build_demo_graph()
route = route_nodes(graph)
sim, net = build_demo_network()
path = Graphs.a_star(graph, SOURCE_NODE, DESTINATION_NODE)
route = [path[1].src; [edge.dst for edge in path]]

println("QTCP edge-list network demo from $(node_label(SOURCE_NODE)) to $(node_label(DESTINATION_NODE))")
println("Edge list: ", EDGE_LIST_PATH)
println("A* route: ", join(node_label.(route), " -> "))
println("Nodes: ", NODE_COUNT)
println("Requested pairs: ", REQUESTED_PAIRS)
println("Memory slots per node: ", MEMORY_SLOTS_PER_NODE)
save_network_snapshot(graph)
save_network_video(graph)

println("Injecting flow $(FLOW_UUID) at $(node_label(SOURCE_NODE))")
put!(net[SOURCE_NODE], Flow(src=SOURCE_NODE, dst=DESTINATION_NODE, npairs=REQUESTED_PAIRS, uuid=FLOW_UUID))
run(sim, SIM_TIME)

source_mb = messagebuffer(net, SOURCE_NODE)
destination_mb = messagebuffer(net, DESTINATION_NODE)
pair_begin_msg = querydelete!(source_mb, QTCPPairBegin, ❓, ❓, ❓, ❓, ❓, ❓)
pair_end_msg = querydelete!(destination_mb, QTCPPairEnd, ❓, ❓, ❓, ❓, ❓, ❓)
@test !isnothing(pair_begin_msg)
@test !isnothing(pair_end_msg)

println()
println("Source-side ready pair at $(node_label(SOURCE_NODE)):")
println("  ", pair_begin_msg.tag)
println()
println("Destination-side ready pair at $(node_label(DESTINATION_NODE)):")
println("  ", pair_end_msg.tag)
