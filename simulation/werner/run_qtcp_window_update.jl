include("qtcp_werner_two_node.jl")

using Printf
using Random

###
# Window-size update experiment.
###

const WINDOW_UPDATE_DEFAULT_CASE = (;
    werner_w=0.75,
    chi=30.0,
    request_rate=nothing,
    distance_km=25.0,
    a_eta=1.0,
    beta_per_km=0.046,
    detector_a_p=0.9,
    detection_prob=nothing,
    source_window_size=20,
    source_ack_timeout=10.0,
    sim_time=500.0,
    success_prob=DEFAULT_SUCCESS_PROB,
    attempt_time=DEFAULT_ATTEMPT_TIME,
    memory_slots=nothing,
    initial_request_delay=DEFAULT_INITIAL_REQUEST_DELAY,
)

const TARGET_TP = 2.4
const UPDATE_ITERS = 3000
const INITIAL_WINDOW_SIZE = WINDOW_UPDATE_DEFAULT_CASE.source_window_size
const INITIAL_WERNER_W = WINDOW_UPDATE_DEFAULT_CASE.werner_w
const MIN_WINDOW_SIZE = 1.0
const WERNER_BOUND_EPS = 1e-6
const MIN_WERNER_W = WERNER_BOUND_EPS
const MAX_WERNER_W = 1.0 - WERNER_BOUND_EPS
const RNG_SEED = 42
const PARALLEL_WITHIN_ITERATION = true
const THROUGHPUT_REPEATS = 10
const WINDOW_UPDATE_OUTPUT_TXT = joinpath(@__DIR__, "qtcp_window_update_results.txt")

empirical_tp(result) = result.acked_pairs / result.sim_time

function mean_value(values)
    collected = collect(values)

    sum(collected) / length(collected)
end

function run_window_update_case(;
        werner_w=WINDOW_UPDATE_DEFAULT_CASE.werner_w,
        sim_time=WINDOW_UPDATE_DEFAULT_CASE.sim_time,
        success_prob=WINDOW_UPDATE_DEFAULT_CASE.success_prob,
        attempt_time=WINDOW_UPDATE_DEFAULT_CASE.attempt_time,
        chi=WINDOW_UPDATE_DEFAULT_CASE.chi,
        request_rate=WINDOW_UPDATE_DEFAULT_CASE.request_rate,
        memory_slots=WINDOW_UPDATE_DEFAULT_CASE.memory_slots,
        distance_km=WINDOW_UPDATE_DEFAULT_CASE.distance_km,
        a_eta=WINDOW_UPDATE_DEFAULT_CASE.a_eta,
        beta_per_km=WINDOW_UPDATE_DEFAULT_CASE.beta_per_km,
        initial_request_delay=WINDOW_UPDATE_DEFAULT_CASE.initial_request_delay,
        detector_a_p=WINDOW_UPDATE_DEFAULT_CASE.detector_a_p,
        detection_prob=WINDOW_UPDATE_DEFAULT_CASE.detection_prob,
        source_window_size=WINDOW_UPDATE_DEFAULT_CASE.source_window_size,
        source_ack_timeout=WINDOW_UPDATE_DEFAULT_CASE.source_ack_timeout,
        rng=Random.default_rng())
    result = run_two_node_qtcp_werner(;
        werner_w,
        sim_time,
        success_prob,
        attempt_time,
        chi,
        request_rate,
        memory_slots,
        distance_km,
        a_eta,
        beta_per_km,
        initial_request_delay,
        detector_a_p,
        detection_prob,
        source_window_size,
        source_ack_timeout,
        rng,
    )

    (;
        result...,
        sim_time,
    )
end

stepsize(n) = 1 / ( n + 100) ^ 0.7

werner_perturbation(n) = 0.05 / (n + 50) ^ 0.15

clamp_werner(w) = clamp(w, MIN_WERNER_W, MAX_WERNER_W)

function update_window_size(window_size, observed_tp, n; target_tp=TARGET_TP)
    gamma = stepsize(n)

    max(MIN_WINDOW_SIZE, window_size + gamma * (target_tp - observed_tp))
end

function update_werner_parameter(werner_w, plus_tp, minus_tp, plus_w, minus_w, n)
    gamma = stepsize(n)
    perturbation_width = plus_w - minus_w
    perturbation_width > 0 || throw(ArgumentError(
        "Werner perturbation width must be positive. Got $(perturbation_width).",
    ))
    gradient_estimate = (plus_tp - minus_tp) / perturbation_width

    clamp_werner(werner_w + gamma * gradient_estimate), gradient_estimate
end

function seed_for(label_offset, n, repeat_index)
    RNG_SEED + label_offset + 10_000 * n + repeat_index
end

function summarize_results(results)
    (;
        throughput=mean_value(empirical_tp(result) for result in results),
        acked_pairs=mean_value(result.acked_pairs for result in results),
        sent_requests=mean_value(result.sent_requests for result in results),
        source_timeouts=mean_value(result.source_timeouts for result in results),
    )
end

function run_repeated_case(case, n, label_offset, repeats)
    results = Vector{Any}(undef, repeats)

    if PARALLEL_WITHIN_ITERATION && Threads.nthreads() > 1 && repeats > 1
        tasks = map(1:repeats) do repeat_index
            Threads.@spawn run_window_update_case(;
                case...,
                rng=Random.MersenneTwister(seed_for(label_offset, n, repeat_index)),
            )
        end

        for (index, task) in enumerate(tasks)
            results[index] = fetch(task)
        end
    else
        for repeat_index in 1:repeats
            results[repeat_index] = run_window_update_case(;
                case...,
                rng=Random.MersenneTwister(seed_for(label_offset, n, repeat_index)),
            )
        end
    end

    summarize_results(results)
end

function run_iteration_cases(case, plus_case, minus_case, n; repeats=THROUGHPUT_REPEATS)
    repeats > 0 || throw(ArgumentError("repeats must be positive. Got $(repeats)."))

    if PARALLEL_WITHIN_ITERATION && Threads.nthreads() >= 3
        result_task = Threads.@spawn run_repeated_case(case, n, 0, repeats)
        plus_task = Threads.@spawn run_repeated_case(plus_case, n, 100_000_000, repeats)
        minus_task = Threads.@spawn run_repeated_case(minus_case, n, 200_000_000, repeats)

        fetch(result_task), fetch(plus_task), fetch(minus_task)
    else
        result = run_repeated_case(case, n, 0, repeats)
        plus_result = run_repeated_case(plus_case, n, 100_000_000, repeats)
        minus_result = run_repeated_case(minus_case, n, 200_000_000, repeats)

        result, plus_result, minus_result
    end
end

function runnable_window_size(window_size)
    max(1, ceil(Int, window_size))
end

const WINDOW_UPDATE_COLUMNS = (
    (name="iter", width=4, align=:right),
    (name="gamma", width=8, align=:right),
    (name="delta", width=8, align=:right),
    (name="W_est", width=10, align=:right),
    (name="W_run", width=6, align=:right),
    (name="w", width=8, align=:right),
    (name="target", width=8, align=:right),
    (name="tp", width=8, align=:right),
    (name="tp_plus", width=8, align=:right),
    (name="tp_minus", width=8, align=:right),
    (name="w_grad", width=10, align=:right),
    (name="acked", width=10, align=:right),
    (name="sent", width=10, align=:right),
    (name="timeout", width=10, align=:right),
    (name="W_next", width=10, align=:right),
    (name="w_next", width=8, align=:right),
)

fmt_float(value) = isnan(value) ? "NaN" : @sprintf("%.6f", value)
fmt_avg_count(value) = @sprintf("%.2f", value)

function pad_cell(value, column)
    text = string(value)
    if length(text) > column.width
        text = text[1:column.width]
    end
    column.align == :left ? rpad(text, column.width) : lpad(text, column.width)
end

function print_txt_row(io, values, columns)
    for (index, column) in enumerate(columns)
        index > 1 && print(io, " | ")
        print(io, pad_cell(values[index], column))
    end
    println(io)
end

function update_row_values(row)
    (
        row.iter,
        fmt_float(row.gamma),
        fmt_float(row.delta),
        fmt_float(row.window_estimate),
        row.window_used,
        fmt_float(row.werner_w),
        fmt_float(row.target_tp),
        fmt_float(row.observed_tp),
        fmt_float(row.plus_tp),
        fmt_float(row.minus_tp),
        fmt_float(row.werner_gradient),
        fmt_avg_count(row.acked_pairs),
        fmt_avg_count(row.sent_requests),
        fmt_avg_count(row.source_timeouts),
        fmt_float(row.next_window_estimate),
        fmt_float(row.next_werner_w),
    )
end

function print_window_update_header(io)
    print_txt_row(io, getproperty.(WINDOW_UPDATE_COLUMNS, :name), WINDOW_UPDATE_COLUMNS)
    println(io, repeat("-", sum(column.width for column in WINDOW_UPDATE_COLUMNS) +
        3 * (length(WINDOW_UPDATE_COLUMNS) - 1)))
end

function print_window_update_row(io, row)
    print_txt_row(io, update_row_values(row), WINDOW_UPDATE_COLUMNS)
end

function print_window_update_parameters(io; target_tp, iterations,
        initial_window_size, initial_werner_w, repeats)
    println(io, "Initial update parameters:")
    println(io, "  target_tp = ", target_tp)
    println(io, "  iterations = ", iterations)
    println(io, "  initial_window_size = ", initial_window_size)
    println(io, "  initial_werner_w = ", initial_werner_w)
    println(io, "  min_window_size = ", MIN_WINDOW_SIZE)
    println(io, "  werner_bounds = [", MIN_WERNER_W, ", ", MAX_WERNER_W, "]")
    println(io, "  rng_seed = ", RNG_SEED)
    println(io, "  parallel_within_iteration = ", PARALLEL_WITHIN_ITERATION)
    println(io, "  julia_threads = ", Threads.nthreads())
    println(io, "  throughput_repeats = ", repeats)
    println(io, "  gamma(n) = 1 / (n + 100)^0.7")
    println(io, "  delta(n) = 0.05 / (n + 50)^0.15")
    println(io)

    println(io, "Default simulation parameters:")
    for (name, value) in pairs(WINDOW_UPDATE_DEFAULT_CASE)
        println(io, "  ", name, " = ", value)
    end
    println(io)
end

function write_window_update_results(path, rows; target_tp=TARGET_TP,
        iterations=UPDATE_ITERS, initial_window_size=INITIAL_WINDOW_SIZE,
        initial_werner_w=INITIAL_WERNER_W, repeats=THROUGHPUT_REPEATS)
    open(path, "w") do io
        println(io, "QTCP Werner window-size and Werner-parameter update.")
        println(io, "Update rule: W_next = W + gamma * (target_tp - observed_tp).")
        println(io, "Update rule: w_next = w + gamma * ((tp_plus - tp_minus) / (w_plus - w_minus)).")
        println(io, "The plus/minus Werner runs use the old W_run from the same iteration.")
        println(io, "Werner parameter is clamped to [$(MIN_WERNER_W), $(MAX_WERNER_W)] so request_rate stays positive.")
        println(io)
        print_window_update_parameters(io;
            target_tp,
            iterations,
            initial_window_size,
            initial_werner_w,
            repeats,
        )
        print_window_update_header(io)

        for row in rows
            print_window_update_row(io, row)
        end
    end
end

function run_window_update(; target_tp=TARGET_TP, iterations=UPDATE_ITERS,
        initial_window_size=INITIAL_WINDOW_SIZE, initial_werner_w=INITIAL_WERNER_W,
        repeats=THROUGHPUT_REPEATS, output_txt=WINDOW_UPDATE_OUTPUT_TXT)
    repeats > 0 || throw(ArgumentError("repeats must be positive. Got $(repeats)."))

    rows = NamedTuple[]
    window_estimate = Float64(initial_window_size)
    werner_w = Float64(initial_werner_w)

    print_window_update_header(stdout)

    for n in 1:iterations
        window_used = runnable_window_size(window_estimate)
        case = merge(WINDOW_UPDATE_DEFAULT_CASE, (;
            source_window_size=window_used,
            werner_w,
        ))
        delta = werner_perturbation(n)
        plus_w = clamp_werner(werner_w + delta)
        minus_w = clamp_werner(werner_w - delta)

        plus_case = merge(case, (; werner_w=plus_w))
        minus_case = merge(case, (; werner_w=minus_w))
        result, plus_result, minus_result = run_iteration_cases(case, plus_case, minus_case, n;
            repeats)
        observed_tp = result.throughput
        next_window_estimate = update_window_size(window_estimate, observed_tp, n;
            target_tp)
        plus_tp = plus_result.throughput
        minus_tp = minus_result.throughput

        next_werner_w, werner_gradient = update_werner_parameter(werner_w,
            plus_tp, minus_tp, plus_w, minus_w, n)

        row = (;
            iter=n,
            gamma=stepsize(n),
            delta,
            window_estimate,
            window_used,
            werner_w,
            target_tp,
            observed_tp,
            plus_tp,
            minus_tp,
            werner_gradient,
            acked_pairs=result.acked_pairs,
            sent_requests=result.sent_requests,
            source_timeouts=result.source_timeouts,
            next_window_estimate,
            next_werner_w,
        )
        push!(rows, row)
        print_window_update_row(stdout, row)

        window_estimate = next_window_estimate
        werner_w = next_werner_w
    end

    write_window_update_results(output_txt, rows;
        target_tp,
        iterations,
        initial_window_size,
        initial_werner_w,
        repeats,
    )
    println("Wrote ", output_txt)
    rows
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_window_update()
end
