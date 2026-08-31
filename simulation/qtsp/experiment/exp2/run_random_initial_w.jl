include(joinpath(@__DIR__, "..", "..", "protocol", "qtsp_window_update_runner.jl"))

using Dates
using Printf
using Random

# Edit these parameters for the experiment.
const EXP2_RANDOM_MASTER_SEED = 20260629
const EXP2_RANDOM_RUN_COUNT = 20
const EXP2_INITIAL_WERNER_RANGE = (0.01, 0.99)
const EXP2_INITIAL_WINDOW_SIZE = 5
const EXP2_MAX_WINDOW_SIZE = 100
const EXP2_TARGET_TP = 1.2
const EXP2_ITERATIONS = 10000
const EXP2_WINDOW_STATS_INTERVAL = 300.0
const EXP2_SIM_TIME = nothing
const EXP2_PROBE_REPEATS = 1

const EXP2_TOPOLOGY = surfnet_graph
const EXP2_SOURCE_NODE =22
const EXP2_DESTINATION_NODE = 9
const EXP2_USE_SURFNET_EDGE_DELAYS = true
const EXP2_SURFNET_SIGNAL_SPEED_KM_PER_TIME = 200_000.0
const EXP2_SURFNET_PATH_STRETCH = 1.0
const EXP2_SURFNET_PER_LINK_PROCESSING_DELAY = 0.0
const EXP2_EDGE_CLASSICAL_DELAYS = EXP2_USE_SURFNET_EDGE_DELAYS ?
    surfnet_classical_delay_map(;
        signal_speed_km_per_time=EXP2_SURFNET_SIGNAL_SPEED_KM_PER_TIME,
        path_stretch=EXP2_SURFNET_PATH_STRETCH,
        per_link_processing_delay=EXP2_SURFNET_PER_LINK_PROCESSING_DELAY,
    ) : nothing

const EXP2_FLOW_UUID = QTSP_DEFAULT_FLOW_UUID
const EXP2_CHI = 30.0
const EXP2_SEND_RATE = nothing
const EXP2_DISTANCE_KM = 25.0
const EXP2_A_ETA = 1.0
const EXP2_BETA_PER_KM = 0.046
const EXP2_DETECTOR_A_P = 0.9
const EXP2_DETECTION_PROB = nothing
const EXP2_MEMORY_SLOTS = nothing
# Fallback delay used only when EXP2_EDGE_CLASSICAL_DELAYS is nothing.
const EXP2_CLASSICAL_DELAY = 0.0
const EXP2_QUANTUM_DELAY = 1.0
const EXP2_INITIAL_DELAY = 0.0
const EXP2_SOURCE_ACK_TIMEOUT = 10.0

const EXP2_RESULT_ROOT = joinpath(@__DIR__, "result")
const EXP2_BATCH_ID = Dates.format(now(), dateformat"yyyymmdd_HHMMSS")
const EXP2_SUMMARY_PATH = joinpath(EXP2_RESULT_ROOT, "summary_$(EXP2_BATCH_ID).tsv")


script_update_stepsize(n) = 1 / (n + 100)^0.7
script_werner_perturbation(n) = 0.05 / (n + 50)^0.15

function exp2_slug(value)
    replace(@sprintf("%.6f", value), "." => "p", "-" => "m")
end

function exp2_run_dir(run_index, run_seed, initial_werner_w)
    joinpath(EXP2_RESULT_ROOT,
        @sprintf("%s_run_%03d_seed_%d_w_%s", EXP2_BATCH_ID, run_index, run_seed,
            exp2_slug(initial_werner_w)))
end

function exp2_write_key_values(io, values)
    for (key, value) in pairs(values)
        println(io, key, " = ", value)
    end
end

function exp2_edge_endpoints(edge)
    edge isa Pair && return edge.first, edge.second

    edge[1], edge[2]
end

function exp2_symmetric_get(values, src, dst, default)
    if haskey(values, (src, dst))
        return values[(src, dst)]
    elseif haskey(values, (dst, src))
        return values[(dst, src)]
    elseif haskey(values, src=>dst)
        return values[src=>dst]
    elseif haskey(values, dst=>src)
        return values[dst=>src]
    end

    default
end

function exp2_write_edge_classical_delays(path, edge_classical_delays)
    isnothing(edge_classical_delays) && return nothing
    edge_classical_delays isa AbstractDict || return nothing

    labels = surfnet_node_labels()
    distances = surfnet_edge_distances_km(; path_stretch=EXP2_SURFNET_PATH_STRETCH)
    edges = sort(collect(keys(edge_classical_delays)); by=exp2_edge_endpoints)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "src\tdst\tsrc_label\tdst_label\tdistance_km\tclassical_delay")
        for edge in edges
            src, dst = exp2_edge_endpoints(edge)
            distance_km = exp2_symmetric_get(distances, src, dst, missing)
            delay = qtsp_edge_classical_delay(edge_classical_delays, src, dst)
            println(io, join((
                src,
                dst,
                labels[src],
                labels[dst],
                distance_km,
                delay,
            ), '\t'))
        end
    end

    path
end

function exp2_write_run_config(path; run_index, run_seed, initial_werner_w,
        output_txt, edge_delay_txt)
    open(path, "w") do io
        println(io, "QTSP exp2 random initial Werner parameter run")
        println(io, "created_at = ", Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS"))
        println(io)
        exp2_write_key_values(io, (;
            master_seed=EXP2_RANDOM_MASTER_SEED,
            batch_id=EXP2_BATCH_ID,
            run_index,
            run_seed,
            initial_werner_w,
            initial_werner_range=EXP2_INITIAL_WERNER_RANGE,
            output_txt,
            edge_delay_txt,
            result_dir=dirname(output_txt),
        ))
        println(io)
        exp2_write_key_values(io, (;
            target_tp=EXP2_TARGET_TP,
            iterations=EXP2_ITERATIONS,
            initial_window_size=EXP2_INITIAL_WINDOW_SIZE,
            max_window_size=EXP2_MAX_WINDOW_SIZE,
            sim_time=EXP2_SIM_TIME,
            probe_repeats=EXP2_PROBE_REPEATS,
            window_stats_interval=EXP2_WINDOW_STATS_INTERVAL,
            gamma_1=script_update_stepsize(1),
            gamma_last=script_update_stepsize(EXP2_ITERATIONS),
            delta_1=script_werner_perturbation(1),
            delta_last=script_werner_perturbation(EXP2_ITERATIONS),
            source_node=EXP2_SOURCE_NODE,
            destination_node=EXP2_DESTINATION_NODE,
            flow_uuid=EXP2_FLOW_UUID,
            chi=EXP2_CHI,
            send_rate=EXP2_SEND_RATE,
            distance_km=EXP2_DISTANCE_KM,
            a_eta=EXP2_A_ETA,
            beta_per_km=EXP2_BETA_PER_KM,
            detector_a_p=EXP2_DETECTOR_A_P,
            detection_prob=EXP2_DETECTION_PROB,
            memory_slots=EXP2_MEMORY_SLOTS,
            classical_delay=EXP2_CLASSICAL_DELAY,
            classical_delay_role=isnothing(EXP2_EDGE_CLASSICAL_DELAYS) ?
                "fixed per link" : "fallback only; per-edge delays override it",
            edge_classical_delays=qtsp_wu_edge_delay_summary(
                EXP2_EDGE_CLASSICAL_DELAYS),
            surfnet_signal_speed_km_per_time=EXP2_SURFNET_SIGNAL_SPEED_KM_PER_TIME,
            surfnet_path_stretch=EXP2_SURFNET_PATH_STRETCH,
            surfnet_per_link_processing_delay=EXP2_SURFNET_PER_LINK_PROCESSING_DELAY,
            quantum_delay=EXP2_QUANTUM_DELAY,
            initial_delay=EXP2_INITIAL_DELAY,
            source_ack_timeout=EXP2_SOURCE_ACK_TIMEOUT,
        ))
    end
end

function exp2_summary_row(; run_index, run_seed, initial_werner_w, rows,
        output_txt, run_dir)
    final_row = isempty(rows) ? nothing : rows[end]

    (;
        run_index,
        run_seed,
        initial_werner_w,
        iterations=length(rows),
        final_observed_tp=isnothing(final_row) ? NaN : final_row.observed_tp,
        final_window_estimate=isnothing(final_row) ? NaN : final_row.next_window_estimate,
        final_window_used=isnothing(final_row) ? missing : final_row.next_window_used,
        final_werner_w=isnothing(final_row) ? NaN : final_row.next_werner_w,
        final_send_rate=isnothing(final_row) ? NaN : final_row.next_send_rate,
        output_txt,
        run_dir,
    )
end

function exp2_write_summary(path, summary_rows)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io,
            "run_index\trun_seed\tinitial_werner_w\titerations\t" *
            "final_observed_tp\tfinal_window_estimate\tfinal_window_used\t" *
            "final_werner_w\tfinal_send_rate\toutput_txt\trun_dir")
        for row in summary_rows
            println(io, join((
                row.run_index,
                row.run_seed,
                row.initial_werner_w,
                row.iterations,
                row.final_observed_tp,
                row.final_window_estimate,
                row.final_window_used,
                row.final_werner_w,
                row.final_send_rate,
                row.output_txt,
                row.run_dir,
            ), '\t'))
        end
    end
end

function exp2_plot_result(output_txt)
    script = joinpath(@__DIR__, "..", "..", "plot_qtsp_window_results.py")
    run(`python3 $script $output_txt`)
end

function exp2_random_initial_werner(rng)
    low, high = EXP2_INITIAL_WERNER_RANGE
    0 <= low <= high <= 1 || throw(ArgumentError(
        "EXP2_INITIAL_WERNER_RANGE must be inside [0, 1] with low <= high.",
    ))

    low + rand(rng) * (high - low)
end

function run_exp2_random_initial_w()
    mkpath(EXP2_RESULT_ROOT)
    master_rng = Random.MersenneTwister(EXP2_RANDOM_MASTER_SEED)
    summary_rows = NamedTuple[]

    for run_index in 1:EXP2_RANDOM_RUN_COUNT
        run_seed = rand(master_rng, 1:typemax(Int32))
        run_rng = Random.MersenneTwister(run_seed)
        initial_werner_w = exp2_random_initial_werner(run_rng)
        run_dir = exp2_run_dir(run_index, run_seed, initial_werner_w)
        mkpath(run_dir)
        output_txt = joinpath(run_dir, "window_update_results.txt")
        edge_delay_txt = isnothing(EXP2_EDGE_CLASSICAL_DELAYS) ? nothing :
            joinpath(run_dir, "edge_classical_delays.tsv")
        config_txt = joinpath(run_dir, "config.txt")

        if !isnothing(edge_delay_txt)
            exp2_write_edge_classical_delays(edge_delay_txt,
                EXP2_EDGE_CLASSICAL_DELAYS)
        end
        exp2_write_run_config(config_txt;
            run_index,
            run_seed,
            initial_werner_w,
            output_txt,
            edge_delay_txt,
        )

        println()
        println("Running exp2 random-W case ", run_index, " / ",
            EXP2_RANDOM_RUN_COUNT)
        println("  run_seed = ", run_seed)
        println("  initial_werner_w = ", initial_werner_w)
        println("  result_dir = ", run_dir)
        println("  output_txt = ", output_txt)
        if !isnothing(edge_delay_txt)
            println("  edge_delay_txt = ", edge_delay_txt)
        end
        flush(stdout)

        rows = run_qtsp_window_update(;
            topology=EXP2_TOPOLOGY,
            source_node=EXP2_SOURCE_NODE,
            destination_node=EXP2_DESTINATION_NODE,
            target_tp=EXP2_TARGET_TP,
            iterations=EXP2_ITERATIONS,
            initial_window_size=EXP2_INITIAL_WINDOW_SIZE,
            initial_werner_w,
            max_window_size=EXP2_MAX_WINDOW_SIZE,
            sim_time=EXP2_SIM_TIME,
            probe_repeats=EXP2_PROBE_REPEATS,
            output_txt,
            flow_uuid=EXP2_FLOW_UUID,
            chi=EXP2_CHI,
            send_rate=EXP2_SEND_RATE,
            distance_km=EXP2_DISTANCE_KM,
            a_eta=EXP2_A_ETA,
            beta_per_km=EXP2_BETA_PER_KM,
            detector_a_p=EXP2_DETECTOR_A_P,
            detection_prob=EXP2_DETECTION_PROB,
            memory_slots=EXP2_MEMORY_SLOTS,
            classical_delay=EXP2_CLASSICAL_DELAY,
            edge_classical_delays=EXP2_EDGE_CLASSICAL_DELAYS,
            quantum_delay=EXP2_QUANTUM_DELAY,
            initial_delay=EXP2_INITIAL_DELAY,
            source_ack_timeout=EXP2_SOURCE_ACK_TIMEOUT,
            window_stats_interval=EXP2_WINDOW_STATS_INTERVAL,
            update_stepsize=script_update_stepsize,
            werner_perturbation=script_werner_perturbation,
        )

        exp2_plot_result(output_txt)

        push!(summary_rows, exp2_summary_row(;
            run_index,
            run_seed,
            initial_werner_w,
            rows,
            output_txt,
            run_dir,
        ))
        exp2_write_summary(EXP2_SUMMARY_PATH, summary_rows)
        println("Finished run ", run_index, "; updated ", EXP2_SUMMARY_PATH)
        flush(stdout)
    end

    summary_rows
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_exp2_random_initial_w()
end
