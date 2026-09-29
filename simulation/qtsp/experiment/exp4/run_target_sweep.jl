"""Exp4: target-throughput sweep for QTSP on SURFnet.

For each target throughput, run several independent random initial Werner
parameters. The protocol is unchanged; only target_tp and the random initial
state vary. Results are written as per-run raw traces plus one TSV summary.
"""

include(joinpath(@__DIR__, "..", "..", "protocol", "qtsp_window_update_runner.jl"))

using Dates
using Printf
using Random
using Statistics

# --- Experiment parameters -------------------------------------------------

const EXP4_MASTER_SEED = 20260928
const EXP4_TARGET_VALUES = [0.4, 0.6, 0.8, 1.0, 1.2]
const EXP4_RUNS_PER_TARGET = 20
const EXP4_INITIAL_WERNER_RANGE = (0.01, 0.99)
const EXP4_INITIAL_WINDOW_SIZE = 5
const EXP4_MAX_WINDOW_SIZE = 100
const EXP4_ITERATIONS = 5000
const EXP4_WINDOW_STATS_INTERVAL = 300.0
const EXP4_SIM_TIME = nothing
const EXP4_PROBE_REPEATS = 1
const EXP4_PLOT_EACH_RUN = false

# Early stopping: at most EXP4_ITERATIONS windows, but stop once a stable
# target-throughput estimate and stable control state are observed.
const EXP4_CONVERGENCE_ENABLED = true
const EXP4_CONVERGENCE_MIN_ITERATIONS = 100
const EXP4_CONVERGENCE_HOLD_WINDOWS = 20
const EXP4_POST_CONVERGENCE_ITERATIONS = 300
const EXP4_CONVERGENCE_TP_TOL = 0.08
const EXP4_CONVERGENCE_TP_STD_TOL = 0.04
const EXP4_CONVERGENCE_WINDOW_DELTA_TOL = 0.02
const EXP4_CONVERGENCE_WERNER_DELTA_TOL = 0.01

const EXP4_TOPOLOGY = surfnet_graph
const EXP4_SOURCE_NODE = 22
const EXP4_DESTINATION_NODE = 9
const EXP4_USE_SURFNET_EDGE_DELAYS = true
const EXP4_SURFNET_SIGNAL_SPEED_KM_PER_TIME = 200_000.0
const EXP4_SURFNET_PATH_STRETCH = 1.0
const EXP4_SURFNET_PER_LINK_PROCESSING_DELAY = 0.0
const EXP4_EDGE_CLASSICAL_DELAYS = EXP4_USE_SURFNET_EDGE_DELAYS ?
    surfnet_classical_delay_map(;
        signal_speed_km_per_time=EXP4_SURFNET_SIGNAL_SPEED_KM_PER_TIME,
        path_stretch=EXP4_SURFNET_PATH_STRETCH,
        per_link_processing_delay=EXP4_SURFNET_PER_LINK_PROCESSING_DELAY,
    ) : nothing

const EXP4_FLOW_UUID = QTSP_DEFAULT_FLOW_UUID
const EXP4_CHI = 30.0
const EXP4_SEND_RATE = nothing
const EXP4_DISTANCE_KM = 25.0
const EXP4_A_ETA = 1.0
const EXP4_BETA_PER_KM = 0.046
const EXP4_DETECTOR_A_P = 0.9
const EXP4_DETECTION_PROB = nothing
const EXP4_MEMORY_SLOTS = nothing
const EXP4_CLASSICAL_DELAY = 0.0
const EXP4_QUANTUM_DELAY = 1.0
const EXP4_INITIAL_DELAY = 0.0
const EXP4_SOURCE_ACK_TIMEOUT = 10.0

const EXP4_RESULT_ROOT = joinpath(@__DIR__, "result")
const EXP4_BATCH_ID = Dates.format(now(), dateformat"yyyymmdd_HHMMSS")
const EXP4_SUMMARY_PATH = joinpath(
    EXP4_RESULT_ROOT, "summary_target_sweep_$(EXP4_BATCH_ID).tsv")

exp4_float(x) = isnan(x) ? "NaN" : @sprintf("%.12g", x)
exp4_slug(value) = replace(@sprintf("%.6f", value), "." => "p", "-" => "m")

function exp4_run_dir(target_index, target_tp, run_index, run_seed, initial_w)
    joinpath(EXP4_RESULT_ROOT,
        @sprintf("%s_target_%s_t%02d_run_%03d_seed_%d_w_%s",
            EXP4_BATCH_ID, exp4_slug(target_tp), target_index, run_index,
            run_seed, exp4_slug(initial_w)))
end

function exp4_write_key_values(io, values)
    for (key, value) in pairs(values)
        println(io, key, " = ", value)
    end
end

function exp4_edge_endpoints(edge)
    edge isa Pair && return edge.first, edge.second
    edge[1], edge[2]
end

function exp4_symmetric_get(values, src, dst, default)
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

function exp4_write_edge_classical_delays(path, edge_classical_delays)
    isnothing(edge_classical_delays) && return nothing
    edge_classical_delays isa AbstractDict || return nothing

    labels = surfnet_node_labels()
    distances = surfnet_edge_distances_km(; path_stretch=EXP4_SURFNET_PATH_STRETCH)
    edges = sort(collect(keys(edge_classical_delays)); by=exp4_edge_endpoints)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "src\tdst\tsrc_label\tdst_label\tdistance_km\tclassical_delay")
        for edge in edges
            src, dst = exp4_edge_endpoints(edge)
            distance_km = exp4_symmetric_get(distances, src, dst, missing)
            delay = qtsp_edge_classical_delay(edge_classical_delays, src, dst)
            println(io, join((src, dst, labels[src], labels[dst], distance_km, delay), '\t'))
        end
    end
    path
end

function exp4_write_config(path; target_index, target_tp, run_index, run_seed,
        initial_w, output_txt, edge_delay_txt)
    open(path, "w") do io
        println(io, "QTSP exp4 target-throughput sweep run")
        println(io, "created_at = ", Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS"))
        println(io)
        exp4_write_key_values(io, (;
            master_seed=EXP4_MASTER_SEED,
            batch_id=EXP4_BATCH_ID,
            target_index,
            target_tp,
            run_index,
            run_seed,
            initial_werner_w=initial_w,
            initial_werner_range=EXP4_INITIAL_WERNER_RANGE,
            output_txt,
            edge_delay_txt,
            result_dir=dirname(output_txt),
        ))
        println(io)
        exp4_write_key_values(io, (;
            iterations=EXP4_ITERATIONS,
            initial_window_size=EXP4_INITIAL_WINDOW_SIZE,
            max_window_size=EXP4_MAX_WINDOW_SIZE,
            sim_time=EXP4_SIM_TIME,
            probe_repeats=EXP4_PROBE_REPEATS,
            plot_each_run=EXP4_PLOT_EACH_RUN,
            convergence_enabled=EXP4_CONVERGENCE_ENABLED,
            convergence_min_iterations=EXP4_CONVERGENCE_MIN_ITERATIONS,
            convergence_hold_windows=EXP4_CONVERGENCE_HOLD_WINDOWS,
            convergence_tp_tol=EXP4_CONVERGENCE_TP_TOL,
            convergence_tp_std_tol=EXP4_CONVERGENCE_TP_STD_TOL,
            convergence_window_delta_tol=EXP4_CONVERGENCE_WINDOW_DELTA_TOL,
            convergence_werner_delta_tol=EXP4_CONVERGENCE_WERNER_DELTA_TOL,
            window_stats_interval=EXP4_WINDOW_STATS_INTERVAL,
            source_node=EXP4_SOURCE_NODE,
            destination_node=EXP4_DESTINATION_NODE,
            flow_uuid=EXP4_FLOW_UUID,
            chi=EXP4_CHI,
            send_rate=EXP4_SEND_RATE,
            distance_km=EXP4_DISTANCE_KM,
            a_eta=EXP4_A_ETA,
            beta_per_km=EXP4_BETA_PER_KM,
            detector_a_p=EXP4_DETECTOR_A_P,
            detection_prob=EXP4_DETECTION_PROB,
            memory_slots=EXP4_MEMORY_SLOTS,
            classical_delay=EXP4_CLASSICAL_DELAY,
            edge_classical_delays=qtsp_wu_edge_delay_summary(EXP4_EDGE_CLASSICAL_DELAYS),
            surfnet_signal_speed_km_per_time=EXP4_SURFNET_SIGNAL_SPEED_KM_PER_TIME,
            surfnet_path_stretch=EXP4_SURFNET_PATH_STRETCH,
            surfnet_per_link_processing_delay=EXP4_SURFNET_PER_LINK_PROCESSING_DELAY,
            quantum_delay=EXP4_QUANTUM_DELAY,
            initial_delay=EXP4_INITIAL_DELAY,
            source_ack_timeout=EXP4_SOURCE_ACK_TIMEOUT,
        ))
    end
end

function exp4_tail_stats(rows, target_tp; fraction=0.1)
    values = [Float64(row.observed_tp) for row in rows if isfinite(row.observed_tp)]
    isempty(values) && return (mean_tp=NaN, rmse=NaN)
    tail_count = max(1, ceil(Int, length(values) * fraction))
    tail = values[max(1, end - tail_count + 1):end]
    (mean_tp=mean(tail), rmse=sqrt(mean((value - target_tp)^2 for value in tail)))
end


function exp4_convergence_status(rows, target_tp)
    EXP4_CONVERGENCE_ENABLED || return false
    length(rows) >= EXP4_CONVERGENCE_MIN_ITERATIONS || return false
    length(rows) >= EXP4_CONVERGENCE_HOLD_WINDOWS || return false

    recent = rows[max(1, end - EXP4_CONVERGENCE_HOLD_WINDOWS + 1):end]
    throughputs = Float64[r.observed_tp for r in recent]
    errors = abs.(throughputs .- target_tp)
    maximum(errors) <= EXP4_CONVERGENCE_TP_TOL || return false
    std(throughputs; corrected=false) <= EXP4_CONVERGENCE_TP_STD_TOL || return false

    windows = Float64[r.next_window_estimate for r in recent]
    werner = Float64[r.next_werner_w for r in recent]
    maximum(abs.(windows[2:end] .- windows[1:end-1])) <=
        EXP4_CONVERGENCE_WINDOW_DELTA_TOL || return false
    maximum(abs.(werner[2:end] .- werner[1:end-1])) <=
        EXP4_CONVERGENCE_WERNER_DELTA_TOL || return false

    true
end

function exp4_has_converged(prot, row, detected_iteration)
    if isnothing(detected_iteration[])
        if exp4_convergence_status(prot.rows, prot.target_tp)
            detected_iteration[] = row.iter
            println("Convergence detected at iteration ", row.iter,
                " for target ", prot.target_tp,
                "; continuing ", EXP4_POST_CONVERGENCE_ITERATIONS,
                " additional iterations")
        end
    end

    if !isnothing(detected_iteration[]) &&
            row.iter >= detected_iteration[] + EXP4_POST_CONVERGENCE_ITERATIONS
        println("Stopping target ", prot.target_tp, " at iteration ", row.iter)
        return true
    end
    false
end

function exp4_summary_row(; target_index, target_tp, run_index, run_seed,
        initial_w, rows, detected_iteration, output_txt, run_dir)
    final_row = isempty(rows) ? nothing : rows[end]
    tail = exp4_tail_stats(rows, target_tp)
    converged = !isnothing(detected_iteration) && length(rows) < EXP4_ITERATIONS
    (;
        target_index,
        target_tp,
        run_index,
        run_seed,
        initial_werner_w=initial_w,
        iterations=length(rows),
        final_observed_tp=isnothing(final_row) ? NaN : final_row.observed_tp,
        final_window_estimate=isnothing(final_row) ? NaN : final_row.next_window_estimate,
        final_window_used=isnothing(final_row) ? missing : final_row.next_window_used,
        final_werner_w=isnothing(final_row) ? NaN : final_row.next_werner_w,
        tail_mean_tp=tail.mean_tp,
        tail_rmse=tail.rmse,
        convergence_detected_iteration=isnothing(detected_iteration) ? missing : detected_iteration,
        converged,
        stop_reason=converged ? "converged_after_grace" : "max_iterations",
        output_txt,
        run_dir,
    )
end

function exp4_write_summary(path, rows)
    mkpath(dirname(path))
    columns = (:target_index, :target_tp, :run_index, :run_seed,
        :initial_werner_w, :iterations, :final_observed_tp,
        :final_window_estimate, :final_window_used, :final_werner_w,
        :tail_mean_tp, :tail_rmse, :convergence_detected_iteration,
        :converged, :stop_reason, :output_txt, :run_dir)
    open(path, "w") do io
        println(io, join(string.(columns), '\t'))
        for row in rows
            println(io, join((getproperty(row, column) for column in columns), '\t'))
        end
    end
end

function exp4_random_initial_w(rng)
    low, high = EXP4_INITIAL_WERNER_RANGE
    low + rand(rng) * (high - low)
end

function run_exp4_target_sweep()
    mkpath(EXP4_RESULT_ROOT)
    master_rng = Random.MersenneTwister(EXP4_MASTER_SEED)
    summary_rows = NamedTuple[]
    total_runs = length(EXP4_TARGET_VALUES) * EXP4_RUNS_PER_TARGET
    run_index = 0

    println("Running exp4 target sweep: ", total_runs, " network runs")
    println("targets = ", EXP4_TARGET_VALUES)
    println("runs per target = ", EXP4_RUNS_PER_TARGET)
    println("summary = ", EXP4_SUMMARY_PATH)

    for (target_index, target_tp) in enumerate(EXP4_TARGET_VALUES)
        for replicate in 1:EXP4_RUNS_PER_TARGET
            run_index += 1
            run_seed = rand(master_rng, 1:typemax(Int32))
            run_rng = Random.MersenneTwister(run_seed)
            initial_w = exp4_random_initial_w(run_rng)
            run_dir = exp4_run_dir(target_index, target_tp, run_index, run_seed, initial_w)
            mkpath(run_dir)
            output_txt = joinpath(run_dir, "window_update_results.txt")
            edge_delay_txt = isnothing(EXP4_EDGE_CLASSICAL_DELAYS) ? nothing :
                joinpath(run_dir, "edge_classical_delays.tsv")
            config_txt = joinpath(run_dir, "config.txt")

            if !isnothing(edge_delay_txt)
                exp4_write_edge_classical_delays(edge_delay_txt,
                    EXP4_EDGE_CLASSICAL_DELAYS)
            end
            exp4_write_config(config_txt;
                target_index, target_tp, run_index, run_seed,
                initial_w, output_txt, edge_delay_txt)

            println("[", run_index, "/", total_runs, "] target=", target_tp,
                " replicate=", replicate, " initial_w=", initial_w)
            flush(stdout)

            detected_iteration = Ref{Union{Nothing,Int}}(nothing)
            stop_condition = EXP4_CONVERGENCE_ENABLED ?
                ((prot, row) -> exp4_has_converged(prot, row, detected_iteration)) : nothing

            rows = run_qtsp_window_update(;
                topology=EXP4_TOPOLOGY,
                source_node=EXP4_SOURCE_NODE,
                destination_node=EXP4_DESTINATION_NODE,
                target_tp,
                iterations=EXP4_ITERATIONS,
                initial_window_size=EXP4_INITIAL_WINDOW_SIZE,
                initial_werner_w=initial_w,
                max_window_size=EXP4_MAX_WINDOW_SIZE,
                sim_time=EXP4_SIM_TIME,
                probe_repeats=EXP4_PROBE_REPEATS,
                output_txt,
                flow_uuid=EXP4_FLOW_UUID,
                chi=EXP4_CHI,
                send_rate=EXP4_SEND_RATE,
                distance_km=EXP4_DISTANCE_KM,
                a_eta=EXP4_A_ETA,
                beta_per_km=EXP4_BETA_PER_KM,
                detector_a_p=EXP4_DETECTOR_A_P,
                detection_prob=EXP4_DETECTION_PROB,
                memory_slots=EXP4_MEMORY_SLOTS,
                classical_delay=EXP4_CLASSICAL_DELAY,
                edge_classical_delays=EXP4_EDGE_CLASSICAL_DELAYS,
                quantum_delay=EXP4_QUANTUM_DELAY,
                initial_delay=EXP4_INITIAL_DELAY,
                source_ack_timeout=EXP4_SOURCE_ACK_TIMEOUT,
                window_stats_interval=EXP4_WINDOW_STATS_INTERVAL,
                update_stepsize=qtsp_update_stepsize,
                werner_perturbation=qtsp_update_werner_perturbation,
                stop_condition,
            )

            push!(summary_rows, exp4_summary_row(;
                target_index, target_tp, run_index, run_seed,
                initial_w, rows, detected_iteration=detected_iteration[],
                output_txt, run_dir))
            exp4_write_summary(EXP4_SUMMARY_PATH, summary_rows)
        end
    end

    println("Finished exp4 target sweep; summary = ", EXP4_SUMMARY_PATH)
    summary_rows
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_exp4_target_sweep()
end
