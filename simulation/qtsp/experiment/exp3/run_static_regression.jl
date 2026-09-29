"""Static QTSP throughput regression experiment.

For every fixed (window_size, werner_w) pair, run the routed QTSP network
several times and write per-run and grouped TSV files.  This experiment does
not perform window or Werner updates; it measures the response surface that
the update protocol is trying to control.
"""

include(joinpath(@__DIR__, "..", "..", "protocol", "qtsp_components.jl"))
include(joinpath(@__DIR__, "..", "..", "qtsp_topologies.jl"))

using Dates
using Printf
using Random
using Statistics

# --- Experiment parameters -------------------------------------------------

const EXP3_MASTER_SEED = 20260921
const EXP3_REPEATS = 20
const EXP3_WINDOW_SIZES = [1, 2, 4, 8, 16, 32]
# Include the analytical stationary point w=1/3 explicitly.
const EXP3_WERNER_VALUES = [0.05, 0.15, 0.25, 1 / 3, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95]
const EXP3_FINE_WERNER_VALUES = sort(unique(vcat(
    collect(0.05:0.05:0.95), [1 / 3])))
const EXP3_DENSE_WERNER_VALUES = sort(unique(vcat(
    collect(0.025:0.025:0.975), [1 / 3])))
# Dense 1920-point response surface: 24 window sizes x 80 Werner values.
const EXP3_DENSE_1920_WINDOW_SIZES = vcat(
    collect(4:2:34), collect(36:4:64))
const EXP3_DENSE_1920_WERNER_VALUES = sort(unique(vcat(
    collect(1:79) ./ 80, [1 / 3])))

# Named sweeps. Select one with `--case <name>` below.
const EXP3_CASES = (
    (name="baseline", chi=30.0, memory_slots=100,
        window_sizes=EXP3_WINDOW_SIZES, werner_values=EXP3_WERNER_VALUES,
        repeats=EXP3_REPEATS),
    # Lower chi reduces window saturation and makes the analytical w response
    # easier to observe.
    (name="theory", chi=3.0, memory_slots=128,
        window_sizes=[4, 8, 16, 32, 64], werner_values=EXP3_WERNER_VALUES,
        repeats=EXP3_REPEATS),
    (name="theory_fine", chi=3.0, memory_slots=128,
        window_sizes=[4, 8, 12, 16, 24, 32, 48, 64],
        werner_values=EXP3_FINE_WERNER_VALUES, repeats=20),
    (name="theory_dense", chi=3.0, memory_slots=128,
        window_sizes=EXP3_DENSE_1920_WINDOW_SIZES,
        werner_values=EXP3_DENSE_1920_WERNER_VALUES, repeats=5),
    # Same physical rate as baseline, but with larger windows.
    (name="large_window", chi=30.0, memory_slots=128,
        window_sizes=[16, 32, 64, 96], werner_values=EXP3_WERNER_VALUES,
        repeats=EXP3_REPEATS),
)

const EXP3_TOPOLOGY = surfnet_graph
const EXP3_SOURCE_NODE = 22
const EXP3_DESTINATION_NODE = 9
const EXP3_USE_SURFNET_EDGE_DELAYS = true
const EXP3_SURFNET_SIGNAL_SPEED_KM_PER_TIME = 200_000.0
const EXP3_SURFNET_PATH_STRETCH = 1.0
const EXP3_SURFNET_PER_LINK_PROCESSING_DELAY = 0.0
const EXP3_EDGE_CLASSICAL_DELAYS = EXP3_USE_SURFNET_EDGE_DELAYS ?
    surfnet_classical_delay_map(
        signal_speed_km_per_time=EXP3_SURFNET_SIGNAL_SPEED_KM_PER_TIME,
        path_stretch=EXP3_SURFNET_PATH_STRETCH,
        per_link_processing_delay=EXP3_SURFNET_PER_LINK_PROCESSING_DELAY,
    ) : nothing

const EXP3_FLOW_UUID = QTSP_DEFAULT_FLOW_UUID
const EXP3_CHI = 30.0
const EXP3_SEND_RATE = nothing
const EXP3_DISTANCE_KM = 25.0
const EXP3_A_ETA = 1.0
const EXP3_BETA_PER_KM = 0.046
const EXP3_DETECTOR_A_P = 0.9
const EXP3_DETECTION_PROB = nothing
const EXP3_MEMORY_SLOTS = 100
const EXP3_CLASSICAL_DELAY = 0.0
const EXP3_QUANTUM_DELAY = 1.0
const EXP3_INITIAL_DELAY = 0.0
const EXP3_SOURCE_ACK_TIMEOUT = 10.0
const EXP3_WINDOW_STATS_INTERVAL = 100.0
const EXP3_SIM_TIME = 300.0

const EXP3_RESULT_ROOT = joinpath(@__DIR__, "result")

# --- Small helpers ----------------------------------------------------------

exp3_float(x) = isnan(x) ? "NaN" : @sprintf("%.12g", x)
exp3_route(route) = join(route, "->")

function exp3_std(values)
    length(values) > 1 ? std(values) : 0.0
end

exp3_grid_key(window_size, werner_w) =
    (Int(window_size), round(Float64(werner_w), digits=10))

function exp3_parse_float(text)
    lowercase(strip(text)) == "nan" ? NaN : parse(Float64, strip(text))
end

function exp3_run_case(window_size, werner_w, seed;
        chi=EXP3_CHI, memory_slots=EXP3_MEMORY_SLOTS)
    graph = EXP3_TOPOLOGY()
    net = RegisterNet(graph,
        [Register(memory_slots) for _ in Graphs.vertices(graph)];
        classical_delay=EXP3_CLASSICAL_DELAY,
        quantum_delay=EXP3_QUANTUM_DELAY)
    qtsp_apply_classical_delays!(net, EXP3_EDGE_CLASSICAL_DELAYS)

    result = run_network_qtsp(
        net=net,
        source_node=EXP3_SOURCE_NODE,
        destination_node=EXP3_DESTINATION_NODE,
        state_count=nothing,
        flow_uuid=EXP3_FLOW_UUID,
        werner_w=werner_w,
        window_size=window_size,
        chi=chi,
        send_rate=EXP3_SEND_RATE,
        distance_km=EXP3_DISTANCE_KM,
        a_eta=EXP3_A_ETA,
        beta_per_km=EXP3_BETA_PER_KM,
        detector_a_p=EXP3_DETECTOR_A_P,
        detection_prob=EXP3_DETECTION_PROB,
        initial_delay=EXP3_INITIAL_DELAY,
        source_ack_timeout=EXP3_SOURCE_ACK_TIMEOUT,
        window_stats_interval=EXP3_WINDOW_STATS_INTERVAL,
        rng=Random.MersenneTwister(seed),
        sim_time=EXP3_SIM_TIME,
    )

    (; seed,
        window_size,
        werner_w,
        route=exp3_route(result.route),
        hop_count=result.hop_count,
        sim_time=result.sim_time,
        total_time=result.total_time,
        sent_states=result.sent_states,
        forwarded_states=result.forwarded_states,
        received_states=result.received_states,
        acked_states=result.acked_states,
        failed_detections=result.failed_detections,
        source_timeouts=result.source_timeouts,
        late_acks=result.late_acks,
        unacked_at_source=result.unacked_at_source,
        acked_throughput=result.acked_throughput,
        delivery_throughput=result.delivery_throughput,
        send_rate=result.send_rate,
        transmissivity=result.transmissivity,
        detection_prob=result.detection_prob,
        route_quantum_delay=result.route_quantum_delay,
        route_classical_delay=result.route_classical_delay,
        mean_quantum_delivery_time=result.mean_quantum_delivery_time,
        mean_rtt=result.mean_rtt,
        mean_observed_fidelity=result.mean_observed_fidelity,
        window_samples=result.window_samples,
        mean_window_sent=result.mean_window_sent,
        mean_window_acked=result.mean_window_acked,
        mean_window_timeouts=result.mean_window_timeouts)
end

function exp3_write_config(path, batch_id; case_name, chi, memory_slots,
        window_sizes, werner_values, repeats, reuse_batch=nothing)
    open(path, "w") do io
        println(io, "QTSP exp3 static throughput regression")
        println(io, "created_at = ", Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS"))
        println(io, "batch_id = ", batch_id)
        println(io, "case_name = ", case_name)
        println(io, "reuse_batch = ", something(reuse_batch, "none"))
        println(io, "master_seed = ", EXP3_MASTER_SEED)
        println(io, "chi = ", chi)
        println(io, "memory_slots = ", memory_slots)
        println(io, "repeats = ", repeats)
        println(io, "window_sizes = ", join(window_sizes, ","))
        println(io, "werner_values = ", join(werner_values, ","))
        println(io, "source_node = ", EXP3_SOURCE_NODE)
        println(io, "destination_node = ", EXP3_DESTINATION_NODE)
        println(io, "sim_time = ", EXP3_SIM_TIME)
        println(io, "window_stats_interval = ", EXP3_WINDOW_STATS_INTERVAL)
        println(io, "edge_classical_delays = ",
            isnothing(EXP3_EDGE_CLASSICAL_DELAYS) ? "none" : "SURFnet distance-based")
        println(io, "distance_km = ", EXP3_DISTANCE_KM,
            " (source attenuation model; not per-edge SURFnet distance)")
    end
end

function exp3_write_tsv(path, rows, columns)
    open(path, "w") do io
        println(io, join(columns, '\t'))
        for row in rows
            println(io, join((getproperty(row, column) for column in columns), '\t'))
        end
    end
end

function exp3_read_key_values(path)
    values = Dict{String, String}()
    for line in readlines(path)
        occursin(" = ", line) || continue
        key, value = split(line, " = "; limit=2)
        values[strip(key)] = strip(value)
    end
    values
end

function exp3_read_reuse_rows(batch_dir; expected_chi, expected_memory_slots)
    batch_dir = abspath(batch_dir)
    run_path = joinpath(batch_dir, "static_regression_runs.tsv")
    config_path = joinpath(batch_dir, "config.txt")
    isfile(run_path) || throw(ArgumentError(
        "Reuse batch has no static_regression_runs.tsv: $(batch_dir)"))
    isfile(config_path) || throw(ArgumentError(
        "Reuse batch has no config.txt: $(batch_dir)"))

    config = exp3_read_key_values(config_path)
    if haskey(config, "chi")
        reuse_chi = config["chi"]
        isapprox(parse(Float64, reuse_chi), expected_chi) ||
            throw(ArgumentError("Reuse batch chi=" * reuse_chi *
                " does not match expected chi=" * string(expected_chi) * "."))
    end
    if haskey(config, "memory_slots")
        reuse_memory_slots = config["memory_slots"]
        parse(Int, reuse_memory_slots) == expected_memory_slots ||
            throw(ArgumentError("Reuse batch memory_slots=" * reuse_memory_slots *
                " does not match expected memory_slots=" *
                string(expected_memory_slots) * "."))
    end
    for (key, expected) in (("source_node", EXP3_SOURCE_NODE),
            ("destination_node", EXP3_DESTINATION_NODE))
        if haskey(config, key) && parse(Int, config[key]) != expected
            throw(ArgumentError("Reuse batch $key=$(config[key]) does not match expected $key=$(expected)."))
        end
    end

    lines = readlines(run_path)
    isempty(lines) && return NamedTuple[]
    header = split(lines[1], '\t')
    positions = Dict(name => findfirst(==(name), header) for name in header)
    field = (row, name) -> row[positions[name]]
    rows = NamedTuple[]
    for line in lines[2:end]
        isempty(strip(line)) && continue
        cells = split(line, '\t')
        length(cells) == length(header) || continue
        push!(rows, (
            run_index=parse(Int, field(cells, "run_index")),
            replicate=parse(Int, field(cells, "replicate")),
            seed=parse(Int, field(cells, "seed")),
            window_size=parse(Int, field(cells, "window_size")),
            werner_w=exp3_parse_float(field(cells, "werner_w")),
            route=field(cells, "route"),
            hop_count=parse(Int, field(cells, "hop_count")),
            sim_time=exp3_parse_float(field(cells, "sim_time")),
            total_time=exp3_parse_float(field(cells, "total_time")),
            sent_states=parse(Int, field(cells, "sent_states")),
            forwarded_states=parse(Int, field(cells, "forwarded_states")),
            received_states=parse(Int, field(cells, "received_states")),
            acked_states=parse(Int, field(cells, "acked_states")),
            failed_detections=parse(Int, field(cells, "failed_detections")),
            source_timeouts=parse(Int, field(cells, "source_timeouts")),
            late_acks=parse(Int, field(cells, "late_acks")),
            unacked_at_source=parse(Int, field(cells, "unacked_at_source")),
            acked_throughput=exp3_parse_float(field(cells, "acked_throughput")),
            delivery_throughput=exp3_parse_float(field(cells, "delivery_throughput")),
            send_rate=exp3_parse_float(field(cells, "send_rate")),
            transmissivity=exp3_parse_float(field(cells, "transmissivity")),
            detection_prob=exp3_parse_float(field(cells, "detection_prob")),
            route_quantum_delay=exp3_parse_float(field(cells, "route_quantum_delay")),
            route_classical_delay=exp3_parse_float(field(cells, "route_classical_delay")),
            mean_quantum_delivery_time=exp3_parse_float(field(cells, "mean_quantum_delivery_time")),
            mean_rtt=exp3_parse_float(field(cells, "mean_rtt")),
            mean_observed_fidelity=exp3_parse_float(field(cells, "mean_observed_fidelity")),
            window_samples=parse(Int, field(cells, "window_samples")),
            mean_window_sent=exp3_parse_float(field(cells, "mean_window_sent")),
            mean_window_acked=exp3_parse_float(field(cells, "mean_window_acked")),
            mean_window_timeouts=exp3_parse_float(field(cells, "mean_window_timeouts")),
        ))
    end
    rows
end

function exp3_index_reuse_rows(rows, window_sizes, werner_values, repeats)
    allowed = Set(exp3_grid_key(window_size, werner_w)
        for window_size in window_sizes, werner_w in werner_values)
    grouped = Dict{Tuple{Int, Float64}, Vector{Any}}()
    for row in sort(rows; by=row -> row.run_index)
        key = exp3_grid_key(row.window_size, row.werner_w)
        key in allowed || continue
        values = get!(grouped, key, Any[])
        length(values) < repeats && push!(values, row)
    end
    grouped
end

function exp3_group_rows(rows, window_sizes, werner_values)
    groups = Dict{Tuple{Int, Float64}, Vector{Any}}()
    for row in rows
        key = (row.window_size, row.werner_w)
        push!(get!(groups, key, Any[]), row)
    end

    output = NamedTuple[]
    for window_size in window_sizes, werner_w in werner_values
        members = get(groups, (window_size, werner_w), Any[])
        isempty(members) && continue
        throughput = [row.acked_throughput for row in members]
        delivery = [row.delivery_throughput for row in members]
        rtt = [row.mean_rtt for row in members if isfinite(row.mean_rtt)]
        fidelity = [row.mean_observed_fidelity for row in members
            if isfinite(row.mean_observed_fidelity)]
        push!(output, (
            window_size=window_size,
            werner_w=exp3_float(werner_w),
            repeats=length(members),
            mean_acked_throughput=exp3_float(mean(throughput)),
            std_acked_throughput=exp3_float(exp3_std(throughput)),
            min_acked_throughput=exp3_float(minimum(throughput)),
            max_acked_throughput=exp3_float(maximum(throughput)),
            mean_delivery_throughput=exp3_float(mean(delivery)),
            model_w_factor=exp3_float(2 * werner_w - 3 * werner_w^2 + 1),
            mean_send_rate=exp3_float(mean(row.send_rate for row in members)),
            mean_detection_prob=exp3_float(mean(row.detection_prob for row in members)),
            mean_rtt=isempty(rtt) ? "NaN" : exp3_float(mean(rtt)),
            mean_observed_fidelity=isempty(fidelity) ? "NaN" : exp3_float(mean(fidelity)),
            mean_sent_states=exp3_float(mean(row.sent_states for row in members)),
            mean_acked_states=exp3_float(mean(row.acked_states for row in members)),
            mean_timeouts=exp3_float(mean(row.source_timeouts for row in members)),
            route=members[1].route,
            hop_count=members[1].hop_count,
            route_classical_delay=exp3_float(members[1].route_classical_delay),
            route_quantum_delay=exp3_float(members[1].route_quantum_delay),
        ))
    end
    output
end

function run_exp3_static_regression(; case_name="custom", chi=EXP3_CHI,
        memory_slots=EXP3_MEMORY_SLOTS, window_sizes=EXP3_WINDOW_SIZES,
        werner_values=EXP3_WERNER_VALUES, repeats=EXP3_REPEATS,
        reuse_batch=nothing)
    mkpath(EXP3_RESULT_ROOT)
    batch_id = string(case_name, "_", Dates.format(now(), dateformat"yyyymmdd_HHMMSS"))
    batch_dir = joinpath(EXP3_RESULT_ROOT, batch_id)
    mkpath(batch_dir)
    exp3_write_config(joinpath(batch_dir, "config.txt"), batch_id;
        case_name, chi, memory_slots, window_sizes, werner_values, repeats,
        reuse_batch)

    master_rng = Random.MersenneTwister(EXP3_MASTER_SEED)
    rows = NamedTuple[]
    reuse_rows = if isnothing(reuse_batch)
        Dict{Tuple{Int, Float64}, Vector{Any}}()
    else
        exp3_index_reuse_rows(
            exp3_read_reuse_rows(reuse_batch;
                expected_chi=chi, expected_memory_slots=memory_slots),
            window_sizes, werner_values, repeats)
    end
    reused_count = sum(length(group_values) for group_values in Base.values(reuse_rows))
    reused_count > 0 && println("Reusing ", reused_count,
        " existing runs from ", abspath(reuse_batch))
    run_index = 0
    total_runs = length(window_sizes) * length(werner_values) * repeats
    println("Running exp3 static regression: ", total_runs, " network runs")

    for window_size in window_sizes, werner_w in werner_values,
            replicate in 1:repeats
        run_index += 1
        key = exp3_grid_key(window_size, werner_w)
        existing = get(reuse_rows, key, Any[])
        if replicate <= length(existing)
            row = merge(existing[replicate],
                (run_index=run_index, replicate=replicate,
                    window_size=window_size, werner_w=Float64(werner_w)))
            push!(rows, row)
            println("[", run_index, "/", total_runs, "] W=", window_size,
                " w=", @sprintf("%.3f", werner_w), " replicate=", replicate,
                " ... reused tp=", exp3_float(row.acked_throughput))
            flush(stdout)
            continue
        end
        seed = rand(master_rng, 1:typemax(Int32))
        print("[", run_index, "/", total_runs, "] W=", window_size,
            " w=", @sprintf("%.2f", werner_w), " replicate=", replicate, " ... ")
        flush(stdout)
        result = exp3_run_case(window_size, werner_w, seed; chi, memory_slots)
        row = merge((run_index=run_index, replicate=replicate), result)
        push!(rows, row)
        println("tp=", exp3_float(row.acked_throughput))
        flush(stdout)
    end

    run_columns = (:run_index, :replicate, :seed, :window_size, :werner_w, :route,
        :hop_count, :sim_time, :total_time, :sent_states, :forwarded_states,
        :received_states, :acked_states, :failed_detections, :source_timeouts,
        :late_acks, :unacked_at_source, :acked_throughput, :delivery_throughput,
        :send_rate, :transmissivity, :detection_prob, :route_quantum_delay,
        :route_classical_delay, :mean_quantum_delivery_time, :mean_rtt,
        :mean_observed_fidelity, :window_samples, :mean_window_sent,
        :mean_window_acked, :mean_window_timeouts)
    formatted_rows = [NamedTuple{run_columns}(Tuple(
        column in (:route,) ? getproperty(row, column) :
        column in (:run_index, :replicate, :seed, :window_size, :hop_count,
            :sent_states, :forwarded_states, :received_states, :acked_states,
            :failed_detections, :source_timeouts, :late_acks, :unacked_at_source,
            :window_samples) ? getproperty(row, column) :
        exp3_float(getproperty(row, column)) for column in run_columns)) for row in rows]
    exp3_write_tsv(joinpath(batch_dir, "static_regression_runs.tsv"),
        formatted_rows, run_columns)

    grouped = exp3_group_rows(rows, window_sizes, werner_values)
    exp3_write_tsv(joinpath(batch_dir, "static_regression_grid.tsv"), grouped,
        propertynames(first(grouped)))
    println("Wrote ", batch_dir)
    batch_dir
end

function exp3_case(name)
    for case in EXP3_CASES
        case.name == name && return case
    end
    valid = join((case.name for case in EXP3_CASES), ", ")
    throw(ArgumentError("Unknown exp3 case '$name'. Choose one of: $valid"))
end

function exp3_cli_case_name()
    index = findfirst(==("--case"), ARGS)
    isnothing(index) && return "baseline"
    index < length(ARGS) || error("--case requires a name")
    ARGS[index + 1]
end

function exp3_cli_reuse_batch()
    index = findfirst(==("--reuse"), ARGS)
    isnothing(index) && return nothing
    index < length(ARGS) || error("--reuse requires a batch directory")
    ARGS[index + 1]
end

if abspath(PROGRAM_FILE) == @__FILE__
    if "--smoke" in ARGS
        run_exp3_static_regression(case_name="smoke", window_sizes=[4],
            werner_values=[0.5], repeats=1)
    elseif "--all" in ARGS
        isnothing(exp3_cli_reuse_batch()) ||
            error("--reuse can only be used with one --case, not --all")
        for case in EXP3_CASES
            run_exp3_static_regression(; case_name=case.name, chi=case.chi,
                memory_slots=case.memory_slots, window_sizes=case.window_sizes,
                werner_values=case.werner_values, repeats=case.repeats)
        end
    else
        case = exp3_case(exp3_cli_case_name())
        run_exp3_static_regression(; case_name=case.name, chi=case.chi,
            memory_slots=case.memory_slots, window_sizes=case.window_sizes,
            werner_values=case.werner_values, repeats=case.repeats,
            reuse_batch=exp3_cli_reuse_batch())
    end
end
