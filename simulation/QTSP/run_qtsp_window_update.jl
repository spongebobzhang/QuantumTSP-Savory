include("qtsp_two_node.jl")

using Printf
using Random

###
# Continuous QTSP window update experiment.
###

const QTSP_WINDOW_UPDATE_DEFAULT_CASE = (;
    flow_uuid=QTSP_DEFAULT_FLOW_UUID,
    werner_w=0.75,
    chi=30.0,
    send_rate=nothing,
    distance_km=25.0,
    a_eta=1.0,
    beta_per_km=0.046,
    detector_a_p=0.9,
    detection_prob=nothing,
    initial_window_size=10,
    max_window_size=100,
    memory_slots=nothing,
    classical_delay=0.0,
    quantum_delay=1.0,
    initial_delay=0.0,
    source_ack_timeout=10.0,
    window_stats_interval=1000.0,
)

# Iteration times and window interval will control the sim time
const QTSP_TARGET_TP = 2.4
const QTSP_UPDATE_ITERS = 20000
const QTSP_INITIAL_WINDOW_SIZE = QTSP_WINDOW_UPDATE_DEFAULT_CASE.initial_window_size
const QTSP_INITIAL_WERNER_W = QTSP_WINDOW_UPDATE_DEFAULT_CASE.werner_w
const QTSP_MIN_WINDOW_SIZE = 1.0
const QTSP_WERNER_BOUND_EPS = 1e-6
const QTSP_MIN_WERNER_W = QTSP_WERNER_BOUND_EPS
const QTSP_MAX_WERNER_W = 1.0 - QTSP_WERNER_BOUND_EPS
const QTSP_RNG_SEED = 42
const QTSP_PARALLEL_WITHIN_ITERATION = true
const QTSP_PROBE_REPEATS = 1
const QTSP_WINDOW_UPDATE_OUTPUT_TXT = joinpath(@__DIR__,
    "qtsp_window_update_results.txt")
const QTSP_WINDOW_UPDATE_DEBUG_AFTER = parse(Int,
    get(ENV, "QTSP_WINDOW_UPDATE_DEBUG_AFTER", "0"))

function qtsp_wu_debug(n, message)
    QTSP_WINDOW_UPDATE_DEBUG_AFTER > 0 && n >= QTSP_WINDOW_UPDATE_DEBUG_AFTER ||
        return nothing

    println(stderr, "[qtsp-wu-debug] iter=", n, " ", message)
    flush(stderr)

    nothing
end

qtsp_update_empirical_tp(result) = result.acked_states / result.sim_time

function qtsp_update_mean_value(values)
    collected = collect(values)

    sum(collected) / length(collected)
end

qtsp_update_stepsize(n) = 1 / (n + 100)^0.7

qtsp_update_werner_perturbation(n) = 0.05 / (n + 50)^0.15

qtsp_update_clamp_werner(w) = clamp(w, QTSP_MIN_WERNER_W, QTSP_MAX_WERNER_W)

function qtsp_update_window_size(window_size, observed_tp, n;
        target_tp=QTSP_TARGET_TP, max_window_size=Inf)
    gamma = qtsp_update_stepsize(n)

    min(max_window_size,
        max(QTSP_MIN_WINDOW_SIZE, window_size + gamma * (target_tp - observed_tp)))
end

function qtsp_update_werner_parameter(werner_w, plus_tp, minus_tp, plus_w,
        minus_w, n)
    gamma = qtsp_update_stepsize(n)
    perturbation_width = plus_w - minus_w
    perturbation_width > 0 || throw(ArgumentError(
        "Werner perturbation width must be positive. Got $(perturbation_width).",
    ))
    gradient_estimate = (plus_tp - minus_tp) / perturbation_width

    qtsp_update_clamp_werner(werner_w + gamma * gradient_estimate),
        gradient_estimate
end

function qtsp_update_send_rate(; chi, send_rate, werner_w, distance_km, a_eta,
        beta_per_km)
    if isnothing(send_rate)
        isnothing(chi) && throw(ArgumentError("Provide either chi or send_rate."))
        chi >= 0 || throw(ArgumentError("chi must be non-negative. Got $(chi)."))
        send_rate = qtsp_source_generation_rate(chi, werner_w; distance_km,
            a_eta, beta_per_km)
    end
    send_rate > 0 || throw(ArgumentError(
        "The send rate must be positive. Got $(send_rate) for chi=$(chi), w=$(werner_w).",
    ))

    send_rate
end

function qtsp_update_seed_for(label_offset, n, repeat_index)
    QTSP_RNG_SEED + label_offset + 10_000 * n + repeat_index
end

function qtsp_update_runnable_window_size(window_size)
    max(1, ceil(Int, window_size))
end

function run_qtsp_window_update_probe(;
        werner_w=QTSP_WINDOW_UPDATE_DEFAULT_CASE.werner_w,
        window_size=QTSP_WINDOW_UPDATE_DEFAULT_CASE.initial_window_size,
        sim_time=QTSP_WINDOW_UPDATE_DEFAULT_CASE.window_stats_interval,
        flow_uuid=QTSP_WINDOW_UPDATE_DEFAULT_CASE.flow_uuid,
        chi=QTSP_WINDOW_UPDATE_DEFAULT_CASE.chi,
        send_rate=QTSP_WINDOW_UPDATE_DEFAULT_CASE.send_rate,
        distance_km=QTSP_WINDOW_UPDATE_DEFAULT_CASE.distance_km,
        a_eta=QTSP_WINDOW_UPDATE_DEFAULT_CASE.a_eta,
        beta_per_km=QTSP_WINDOW_UPDATE_DEFAULT_CASE.beta_per_km,
        detector_a_p=QTSP_WINDOW_UPDATE_DEFAULT_CASE.detector_a_p,
        detection_prob=QTSP_WINDOW_UPDATE_DEFAULT_CASE.detection_prob,
        memory_slots=QTSP_WINDOW_UPDATE_DEFAULT_CASE.memory_slots,
        classical_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.classical_delay,
        quantum_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.quantum_delay,
        initial_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.initial_delay,
        source_ack_timeout=QTSP_WINDOW_UPDATE_DEFAULT_CASE.source_ack_timeout,
        rng=Random.default_rng())
    source_retain_start_slot = QTSP_SOURCE_RETAIN_START_SLOT
    source_send_slot = source_retain_start_slot + window_size
    memory_slots = something(memory_slots,
        max(qtsp_default_memory_slots(window_size), source_send_slot))

    run_two_node_qtsp(;
        state_count=nothing,
        flow_uuid,
        werner_w,
        window_size,
        memory_slots,
        chi,
        send_rate,
        distance_km,
        a_eta,
        beta_per_km,
        detector_a_p,
        detection_prob,
        classical_delay,
        quantum_delay,
        source_retain_slots=window_size,
        source_retain_start_slot,
        source_send_slot,
        destination_receive_start_slot=QTSP_DESTINATION_RECEIVE_START_SLOT,
        initial_delay,
        source_ack_timeout,
        window_stats_interval=Inf,
        rng,
        sim_time,
    )
end

function qtsp_update_summarize_probe_results(results)
    (;
        throughput=qtsp_update_mean_value(qtsp_update_empirical_tp(result)
            for result in results),
        acked_states=qtsp_update_mean_value(result.acked_states for result in results),
        sent_states=qtsp_update_mean_value(result.sent_states for result in results),
        source_timeouts=qtsp_update_mean_value(result.source_timeouts
            for result in results),
        failed_detections=qtsp_update_mean_value(result.failed_detections
            for result in results),
    )
end

function run_qtsp_repeated_probe(case, n, label_offset, repeats)
    results = Vector{Any}(undef, repeats)

    for repeat_index in 1:repeats
        results[repeat_index] = run_qtsp_window_update_probe(;
            case...,
            rng=Random.MersenneTwister(qtsp_update_seed_for(label_offset, n,
                repeat_index)),
        )
    end

    qtsp_update_summarize_probe_results(results)
end

function run_qtsp_probe_pair(plus_case, minus_case, n; repeats=QTSP_PROBE_REPEATS)
    repeats > 0 || throw(ArgumentError("repeats must be positive. Got $(repeats)."))

    if QTSP_PARALLEL_WITHIN_ITERATION && Threads.nthreads() >= 2
        plus_task = Threads.@spawn run_qtsp_repeated_probe(plus_case, n,
            100_000_000, repeats)
        minus_task = Threads.@spawn run_qtsp_repeated_probe(minus_case, n,
            200_000_000, repeats)

        fetch(plus_task), fetch(minus_task)
    else
        plus_result = run_qtsp_repeated_probe(plus_case, n, 100_000_000, repeats)
        minus_result = run_qtsp_repeated_probe(minus_case, n, 200_000_000, repeats)

        plus_result, minus_result
    end
end

const QTSP_WINDOW_UPDATE_COLUMNS = (
    (name="iter", width=4, align=:right),
    (name="start", width=8, align=:right),
    (name="end", width=8, align=:right),
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
    (name="sent", width=8, align=:right),
    (name="acked", width=8, align=:right),
    (name="timeout", width=8, align=:right),
    (name="W_next", width=10, align=:right),
    (name="Wrun_n", width=6, align=:right),
    (name="w_next", width=8, align=:right),
    (name="rate_n", width=8, align=:right),
)

qtsp_wu_fmt_float(value) = isnan(value) ? "NaN" : @sprintf("%.6f", value)

function qtsp_wu_pad_cell(value, column)
    text = string(value)
    if length(text) > column.width
        text = text[1:column.width]
    end
    column.align == :left ? rpad(text, column.width) : lpad(text, column.width)
end

function qtsp_wu_print_row(io, values, columns)
    for (index, column) in enumerate(columns)
        index > 1 && print(io, " | ")
        print(io, qtsp_wu_pad_cell(values[index], column))
    end
    println(io)
end

function qtsp_wu_print_header(io)
    qtsp_wu_print_row(io, getproperty.(QTSP_WINDOW_UPDATE_COLUMNS, :name),
        QTSP_WINDOW_UPDATE_COLUMNS)
    println(io, repeat("-", sum(column.width for column in QTSP_WINDOW_UPDATE_COLUMNS) +
        3 * (length(QTSP_WINDOW_UPDATE_COLUMNS) - 1)))
end

function qtsp_wu_row_values(row)
    (
        row.iter,
        qtsp_wu_fmt_float(row.window_start),
        qtsp_wu_fmt_float(row.window_end),
        qtsp_wu_fmt_float(row.gamma),
        qtsp_wu_fmt_float(row.delta),
        qtsp_wu_fmt_float(row.window_estimate),
        row.window_used,
        qtsp_wu_fmt_float(row.werner_w),
        qtsp_wu_fmt_float(row.target_tp),
        qtsp_wu_fmt_float(row.observed_tp),
        qtsp_wu_fmt_float(row.plus_tp),
        qtsp_wu_fmt_float(row.minus_tp),
        qtsp_wu_fmt_float(row.werner_gradient),
        row.sent_states,
        row.acked_states,
        row.source_timeouts,
        qtsp_wu_fmt_float(row.next_window_estimate),
        row.next_window_used,
        qtsp_wu_fmt_float(row.next_werner_w),
        qtsp_wu_fmt_float(row.next_send_rate),
    )
end

function qtsp_wu_print_update_row(io, row)
    qtsp_wu_print_row(io, qtsp_wu_row_values(row), QTSP_WINDOW_UPDATE_COLUMNS)
end

function print_qtsp_window_update_parameters(io; target_tp, iterations, sim_time,
        window_stats_interval, initial_window_size, initial_werner_w,
        max_window_size, probe_repeats)
    println(io, "Initial update parameters:")
    println(io, "  target_tp = ", target_tp)
    println(io, "  iterations = ", iterations)
    println(io, "  sim_time = ", sim_time)
    println(io, "  window_stats_interval = ", window_stats_interval)
    println(io, "  initial_window_size = ", initial_window_size)
    println(io, "  initial_werner_w = ", initial_werner_w)
    println(io, "  max_window_size = ", max_window_size)
    println(io, "  min_window_size = ", QTSP_MIN_WINDOW_SIZE)
    println(io, "  werner_bounds = [", QTSP_MIN_WERNER_W, ", ",
        QTSP_MAX_WERNER_W, "]")
    println(io, "  rng_seed = ", QTSP_RNG_SEED)
    println(io, "  parallel_within_iteration = ", QTSP_PARALLEL_WITHIN_ITERATION)
    println(io, "  julia_threads = ", Threads.nthreads())
    println(io, "  probe_repeats = ", probe_repeats)
    println(io, "  gamma(n) = 1 / (n + 100)^0.7")
    println(io, "  delta(n) = 0.05 / (n + 50)^0.15")
    println(io)

    println(io, "Default simulation parameters:")
    for (name, value) in pairs(QTSP_WINDOW_UPDATE_DEFAULT_CASE)
        println(io, "  ", name, " = ", value)
    end
    println(io)
end

function write_qtsp_window_update_results(path, rows; target_tp=QTSP_TARGET_TP,
        iterations=QTSP_UPDATE_ITERS,
        sim_time=iterations * QTSP_WINDOW_UPDATE_DEFAULT_CASE.window_stats_interval,
        window_stats_interval=QTSP_WINDOW_UPDATE_DEFAULT_CASE.window_stats_interval,
        initial_window_size=QTSP_INITIAL_WINDOW_SIZE,
        initial_werner_w=QTSP_INITIAL_WERNER_W,
        max_window_size=QTSP_WINDOW_UPDATE_DEFAULT_CASE.max_window_size,
        probe_repeats=QTSP_PROBE_REPEATS)
    open(path, "w") do io
        println(io, "QTSP continuous window-size and Werner-parameter update.")
        println(io, "Main run: one continuous QTSP simulation, updated at each source T_W boundary.")
        println(io, "Update rule: W_next = W + gamma * (target_tp - observed_tp).")
        println(io, "Update rule: w_next = w + gamma * ((tp_plus - tp_minus) / (w_plus - w_minus)).")
        println(io, "Werner plus/minus probes are independent one-window QTSP runs; the main run is not restarted.")
        println(io, "Werner parameter is clamped to [$(QTSP_MIN_WERNER_W), $(QTSP_MAX_WERNER_W)].")
        println(io)
        print_qtsp_window_update_parameters(io;
            target_tp,
            iterations,
            sim_time,
            window_stats_interval,
            initial_window_size,
            initial_werner_w,
            max_window_size,
            probe_repeats,
        )
        qtsp_wu_print_header(io)

        for row in rows
            qtsp_wu_print_update_row(io, row)
        end
    end
end

function run_qtsp_window_update(; target_tp=QTSP_TARGET_TP,
        iterations=QTSP_UPDATE_ITERS,
        initial_window_size=QTSP_INITIAL_WINDOW_SIZE,
        initial_werner_w=QTSP_INITIAL_WERNER_W,
        max_window_size=QTSP_WINDOW_UPDATE_DEFAULT_CASE.max_window_size,
        sim_time=nothing,
        probe_repeats=QTSP_PROBE_REPEATS,
        output_txt=QTSP_WINDOW_UPDATE_OUTPUT_TXT,
        flow_uuid=QTSP_WINDOW_UPDATE_DEFAULT_CASE.flow_uuid,
        chi=QTSP_WINDOW_UPDATE_DEFAULT_CASE.chi,
        send_rate=QTSP_WINDOW_UPDATE_DEFAULT_CASE.send_rate,
        distance_km=QTSP_WINDOW_UPDATE_DEFAULT_CASE.distance_km,
        a_eta=QTSP_WINDOW_UPDATE_DEFAULT_CASE.a_eta,
        beta_per_km=QTSP_WINDOW_UPDATE_DEFAULT_CASE.beta_per_km,
        detector_a_p=QTSP_WINDOW_UPDATE_DEFAULT_CASE.detector_a_p,
        detection_prob=QTSP_WINDOW_UPDATE_DEFAULT_CASE.detection_prob,
        memory_slots=QTSP_WINDOW_UPDATE_DEFAULT_CASE.memory_slots,
        classical_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.classical_delay,
        quantum_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.quantum_delay,
        initial_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.initial_delay,
        source_ack_timeout=QTSP_WINDOW_UPDATE_DEFAULT_CASE.source_ack_timeout,
        window_stats_interval=QTSP_WINDOW_UPDATE_DEFAULT_CASE.window_stats_interval)
    iterations > 0 || throw(ArgumentError("iterations must be positive. Got $(iterations)."))
    probe_repeats > 0 || throw(ArgumentError("probe_repeats must be positive. Got $(probe_repeats)."))
    window_stats_interval > 0 || throw(ArgumentError(
        "window_stats_interval must be positive. Got $(window_stats_interval).",
    ))
    max_window_size > 0 || throw(ArgumentError(
        "max_window_size must be positive. Got $(max_window_size).",
    ))

    run_until = something(sim_time, initial_delay + iterations * window_stats_interval)
    run_until >= initial_delay + iterations * window_stats_interval ||
        throw(ArgumentError(
            "sim_time must cover all update windows. Got sim_time=$(run_until), iterations=$(iterations), T_W=$(window_stats_interval).",
        ))

    initial_window_estimate = min(Float64(max_window_size),
        max(QTSP_MIN_WINDOW_SIZE, Float64(initial_window_size)))
    initial_window_used = min(max_window_size,
        qtsp_update_runnable_window_size(initial_window_estimate))
    initial_send_rate = qtsp_update_send_rate(; chi, send_rate,
        werner_w=initial_werner_w, distance_km, a_eta, beta_per_km)
    # control is to adjust the window size, werner parameter, and send rate for the next window 
    control = QTSPSourceControl(;
        window_size=initial_window_used,
        werner_w=initial_werner_w,  
        send_interval=1 / initial_send_rate,
    )

    source_retain_start_slot = QTSP_SOURCE_RETAIN_START_SLOT
    source_retain_slots = max_window_size
    source_send_slot = source_retain_start_slot + source_retain_slots
    memory_slots = something(memory_slots,
        max(qtsp_default_memory_slots(source_retain_slots), source_send_slot,
            QTSP_DESTINATION_RECEIVE_START_SLOT))

    sim, net = build_two_node_qtsp_network(; memory_slots, classical_delay,
        quantum_delay, distance_km, a_eta, beta_per_km)

    send_log = QTSPStateInfo[]
    receive_log = QTSPStateInfo[]
    ack_log = QTSPStateInfo[]
    timeout_log = QTSPStateInfo[]
    late_ack_log = QTSPStateInfo[]
    failure_log = QTSPStateInfo[]
    window_log = QTSPWindowInfo[]
    rows = NamedTuple[]
    window_estimate = Ref(initial_window_estimate)
    werner_w = Ref(Float64(initial_werner_w))
    # this function will be called at the end of each time window,
    # it will run the probes, calculate the next parameters, and update the control
    function update_after_window(window_info)
        n = window_info.window_index
        n > iterations && return nothing

        window_used = control.window_size
        current_werner_w = werner_w[]
        observed_tp = window_info.acked_throughput
        delta = qtsp_update_werner_perturbation(n)
        plus_w = qtsp_update_clamp_werner(current_werner_w + delta)
        minus_w = qtsp_update_clamp_werner(current_werner_w - delta)
        qtsp_wu_debug(n,
            "callback start window=[$(window_info.window_start), $(window_info.window_end)] W=$(window_used) w=$(current_werner_w) plus=$(plus_w) minus=$(minus_w)")
        probe_case = (;
            flow_uuid,
            window_size=window_used,
            sim_time=window_stats_interval,
            chi,
            send_rate,
            distance_km,
            a_eta,
            beta_per_km,
            detector_a_p,
            detection_prob,
            memory_slots=nothing,
            classical_delay,
            quantum_delay,
            initial_delay=0.0,
            source_ack_timeout,
        )
        plus_case = merge(probe_case, (; werner_w=plus_w))
        minus_case = merge(probe_case, (; werner_w=minus_w))
        qtsp_wu_debug(n, "probe start")
        plus_result, minus_result = run_qtsp_probe_pair(plus_case, minus_case, n;
            repeats=probe_repeats)
        qtsp_wu_debug(n,
            "probe done plus_tp=$(plus_result.throughput) minus_tp=$(minus_result.throughput)")
        plus_tp = plus_result.throughput
        minus_tp = minus_result.throughput
        # calculate the next window size  and Werner parameter
        next_window_estimate = qtsp_update_window_size(window_estimate[],
            observed_tp, n; target_tp, max_window_size)
        next_window_used = min(max_window_size,
            qtsp_update_runnable_window_size(next_window_estimate))
        next_werner_w, werner_gradient = qtsp_update_werner_parameter(
            current_werner_w, plus_tp, minus_tp, plus_w, minus_w, n)
        next_send_rate = qtsp_update_send_rate(; chi, send_rate,
            werner_w=next_werner_w, distance_km, a_eta, beta_per_km)

        row = (;
            iter=n,
            window_start=window_info.window_start,
            window_end=window_info.window_end,
            gamma=qtsp_update_stepsize(n),
            delta,
            window_estimate=window_estimate[],
            window_used,
            werner_w=current_werner_w,
            target_tp,
            observed_tp,
            plus_tp,
            minus_tp,
            werner_gradient,
            sent_states=window_info.sent_count,
            acked_states=window_info.acked_count,
            source_timeouts=window_info.timeout_count,
            late_acks=window_info.late_ack_count,
            next_window_estimate,
            next_window_used,
            next_werner_w,
            next_send_rate,
        )
        push!(rows, row)
        qtsp_wu_print_update_row(stdout, row)
        flush(stdout)
        # update the control parameters for the next window
        window_estimate[] = next_window_estimate
        werner_w[] = next_werner_w
        control.window_size = next_window_used
        control.werner_w = next_werner_w
        control.send_interval = 1 / next_send_rate

        nothing
    end

    qtsp_wu_print_header(stdout)
    flush(stdout)

    @process QTSPDestinationController(;
        sim,
        net,
        source_node=QTSP_SOURCE_NODE,
        destination_node=QTSP_DESTINATION_NODE,
        flow_uuid,
        state_count=nothing,
        window_size=initial_window_used,
        source_retain_start_slot,
        destination_receive_start_slot=QTSP_DESTINATION_RECEIVE_START_SLOT,
        detector_a_p,
        detection_prob,
        rng=Random.MersenneTwister(qtsp_update_seed_for(300_000_000, 0, 1)),
        receive_log,
        failure_log,
    )()

    @process QTSPSourceController(;
        sim,
        net,
        source_node=QTSP_SOURCE_NODE,
        destination_node=QTSP_DESTINATION_NODE,
        flow_uuid,
        state_count=nothing,
        source_stop_time=run_until,
        window_size=initial_window_used,
        source_retain_slots,
        werner_w=initial_werner_w,
        source_retain_start_slot,
        source_send_slot,
        send_interval=1 / initial_send_rate,
        initial_delay,
        source_ack_timeout,
        window_stats_interval,
        control,
        window_update_callback=update_after_window,
        send_log,
        ack_log,
        timeout_log,
        late_ack_log,
        window_log,
    )()

    run(sim, run_until + 1e-9)

    write_qtsp_window_update_results(output_txt, rows;
        target_tp,
        iterations,
        sim_time=run_until,
        window_stats_interval,
        initial_window_size,
        initial_werner_w,
        max_window_size,
        probe_repeats,
    )
    println("Wrote ", output_txt)

    rows
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_qtsp_window_update()
end
