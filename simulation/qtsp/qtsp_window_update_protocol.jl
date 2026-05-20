isdefined(@__MODULE__, :QTSPSourceController) || include("qtsp_components.jl")

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

function qtsp_eval_update_stepsize(update_stepsize, n)
    value = Float64(update_stepsize(n))
    isfinite(value) && value >= 0 || throw(ArgumentError(
        "update_stepsize(n) must return a finite non-negative value. Got $(value) for n=$(n).",
    ))

    value
end

function qtsp_eval_werner_perturbation(werner_perturbation, n)
    value = Float64(werner_perturbation(n))
    isfinite(value) && value > 0 || throw(ArgumentError(
        "werner_perturbation(n) must return a finite positive value. Got $(value) for n=$(n).",
    ))

    value
end

qtsp_update_clamp_werner(w) = clamp(w, QTSP_MIN_WERNER_W, QTSP_MAX_WERNER_W)

function qtsp_update_window_size(window_size, observed_tp, n;
        target_tp=QTSP_TARGET_TP, max_window_size=Inf,
        update_stepsize=qtsp_update_stepsize)
    gamma = qtsp_eval_update_stepsize(update_stepsize, n)

    min(max_window_size,
        max(QTSP_MIN_WINDOW_SIZE, window_size + gamma * (target_tp - observed_tp)))
end

function qtsp_update_werner_parameter(werner_w, plus_tp, minus_tp, plus_w,
        minus_w, n; update_stepsize=qtsp_update_stepsize)
    gamma = qtsp_eval_update_stepsize(update_stepsize, n)
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
        max_window_size, probe_repeats, update_stepsize=qtsp_update_stepsize,
        werner_perturbation=qtsp_update_werner_perturbation)
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
    println(io, "  gamma(1) = ", qtsp_eval_update_stepsize(update_stepsize, 1))
    println(io, "  delta(1) = ", qtsp_eval_werner_perturbation(werner_perturbation, 1))
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
        probe_repeats=QTSP_PROBE_REPEATS,
        update_stepsize=qtsp_update_stepsize,
        werner_perturbation=qtsp_update_werner_perturbation)
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
            update_stepsize,
            werner_perturbation,
        )
        qtsp_wu_print_header(io)

        for row in rows
            qtsp_wu_print_update_row(io, row)
        end
    end
end

@kwdef mutable struct QTSPWindowUpdateProtocol <: AbstractProtocol
    sim::Simulation
    net::RegisterNet
    source_node::Int = QTSP_SOURCE_NODE
    destination_node::Int = QTSP_DESTINATION_NODE
    flow_uuid::Int = QTSP_DEFAULT_FLOW_UUID
    target_tp::Float64 = QTSP_TARGET_TP
    iterations::Int = QTSP_UPDATE_ITERS
    source_stop_time::Float64
    initial_window_size::Int = QTSP_INITIAL_WINDOW_SIZE
    max_window_size::Int = QTSP_WINDOW_UPDATE_DEFAULT_CASE.max_window_size
    window_stats_interval::Float64 = QTSP_WINDOW_UPDATE_DEFAULT_CASE.window_stats_interval
    initial_werner_w::Float64 = QTSP_INITIAL_WERNER_W
    chi::Union{Float64,Nothing} = QTSP_WINDOW_UPDATE_DEFAULT_CASE.chi
    send_rate::Union{Float64,Nothing} = QTSP_WINDOW_UPDATE_DEFAULT_CASE.send_rate
    distance_km::Float64 = QTSP_WINDOW_UPDATE_DEFAULT_CASE.distance_km
    a_eta::Float64 = QTSP_WINDOW_UPDATE_DEFAULT_CASE.a_eta
    beta_per_km::Float64 = QTSP_WINDOW_UPDATE_DEFAULT_CASE.beta_per_km
    detector_a_p::Float64 = QTSP_WINDOW_UPDATE_DEFAULT_CASE.detector_a_p
    detection_prob::Union{Float64,Nothing} = QTSP_WINDOW_UPDATE_DEFAULT_CASE.detection_prob
    classical_delay::Float64 = QTSP_WINDOW_UPDATE_DEFAULT_CASE.classical_delay
    quantum_delay::Float64 = QTSP_WINDOW_UPDATE_DEFAULT_CASE.quantum_delay
    initial_delay::Float64 = QTSP_WINDOW_UPDATE_DEFAULT_CASE.initial_delay
    source_ack_timeout::Float64 = QTSP_WINDOW_UPDATE_DEFAULT_CASE.source_ack_timeout
    probe_repeats::Int = QTSP_PROBE_REPEATS
    probe_runner::Any = nothing
    update_stepsize::Any = qtsp_update_stepsize
    werner_perturbation::Any = qtsp_update_werner_perturbation
    source_retain_start_slot::Int = QTSP_SOURCE_RETAIN_START_SLOT
    source_retain_slots::Int = max_window_size
    source_send_slot::Int = source_retain_start_slot + source_retain_slots
    destination_receive_start_slot::Int = QTSP_DESTINATION_RECEIVE_START_SLOT
    control::QTSPSourceControl
    window_estimate::Base.RefValue{Float64}
    werner_w::Base.RefValue{Float64}
    rng::Random.AbstractRNG = Random.MersenneTwister(qtsp_update_seed_for(300_000_000, 0, 1))
    on_update::Any = nothing
    send_log::Vector{QTSPStateInfo} = QTSPStateInfo[]
    receive_log::Vector{QTSPStateInfo} = QTSPStateInfo[]
    ack_log::Vector{QTSPStateInfo} = QTSPStateInfo[]
    timeout_log::Vector{QTSPStateInfo} = QTSPStateInfo[]
    late_ack_log::Vector{QTSPStateInfo} = QTSPStateInfo[]
    failure_log::Vector{QTSPStateInfo} = QTSPStateInfo[]
    window_log::Vector{QTSPWindowInfo} = QTSPWindowInfo[]
    rows::Vector{NamedTuple} = NamedTuple[]
end

function build_qtsp_window_update_protocol(; sim,
        net,
        source_node=QTSP_SOURCE_NODE,
        destination_node=QTSP_DESTINATION_NODE,
        target_tp=QTSP_TARGET_TP,
        iterations=QTSP_UPDATE_ITERS,
        initial_window_size=QTSP_INITIAL_WINDOW_SIZE,
        initial_werner_w=QTSP_INITIAL_WERNER_W,
        max_window_size=QTSP_WINDOW_UPDATE_DEFAULT_CASE.max_window_size,
        sim_time=nothing,
        probe_repeats=QTSP_PROBE_REPEATS,
        probe_runner=nothing,
        flow_uuid=QTSP_WINDOW_UPDATE_DEFAULT_CASE.flow_uuid,
        chi=QTSP_WINDOW_UPDATE_DEFAULT_CASE.chi,
        send_rate=QTSP_WINDOW_UPDATE_DEFAULT_CASE.send_rate,
        distance_km=QTSP_WINDOW_UPDATE_DEFAULT_CASE.distance_km,
        a_eta=QTSP_WINDOW_UPDATE_DEFAULT_CASE.a_eta,
        beta_per_km=QTSP_WINDOW_UPDATE_DEFAULT_CASE.beta_per_km,
        detector_a_p=QTSP_WINDOW_UPDATE_DEFAULT_CASE.detector_a_p,
        detection_prob=QTSP_WINDOW_UPDATE_DEFAULT_CASE.detection_prob,
        classical_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.classical_delay,
        quantum_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.quantum_delay,
        initial_delay=QTSP_WINDOW_UPDATE_DEFAULT_CASE.initial_delay,
        source_ack_timeout=QTSP_WINDOW_UPDATE_DEFAULT_CASE.source_ack_timeout,
        window_stats_interval=QTSP_WINDOW_UPDATE_DEFAULT_CASE.window_stats_interval,
        source_retain_start_slot=QTSP_SOURCE_RETAIN_START_SLOT,
        source_retain_slots=max_window_size,
        source_send_slot=source_retain_start_slot + source_retain_slots,
        destination_receive_start_slot=QTSP_DESTINATION_RECEIVE_START_SLOT,
        update_stepsize=qtsp_update_stepsize,
        werner_perturbation=qtsp_update_werner_perturbation,
        rng=Random.MersenneTwister(qtsp_update_seed_for(300_000_000, 0, 1)),
        on_update=nothing)
    iterations > 0 || throw(ArgumentError("iterations must be positive. Got $(iterations)."))
    probe_repeats > 0 || throw(ArgumentError("probe_repeats must be positive. Got $(probe_repeats)."))
    window_stats_interval > 0 || throw(ArgumentError(
        "window_stats_interval must be positive. Got $(window_stats_interval).",
    ))
    max_window_size isa Integer || throw(ArgumentError(
        "max_window_size must be an integer. Got $(max_window_size).",
    ))
    max_window_size > 0 || throw(ArgumentError(
        "max_window_size must be positive. Got $(max_window_size).",
    ))
    source_retain_slots >= max_window_size || throw(ArgumentError(
        "source_retain_slots must be at least max_window_size. Got source_retain_slots=$(source_retain_slots), max_window_size=$(max_window_size).",
    ))
    isnothing(probe_runner) && throw(ArgumentError(
        "QTSPWindowUpdateProtocol requires a probe_runner. " *
        "Pass a custom probe runner for the target network, or use build_two_node_qtsp_window_update_protocol(...) for the current two-node experiment.",
    ))
    qtsp_eval_update_stepsize(update_stepsize, 1)
    qtsp_eval_werner_perturbation(werner_perturbation, 1)

    source_stop_time = something(sim_time,
        initial_delay + iterations * window_stats_interval)
    source_stop_time >= initial_delay + iterations * window_stats_interval ||
        throw(ArgumentError(
            "sim_time must cover all update windows. Got sim_time=$(source_stop_time), iterations=$(iterations), T_W=$(window_stats_interval).",
        ))

    initial_window_estimate = min(Float64(max_window_size),
        max(QTSP_MIN_WINDOW_SIZE, Float64(initial_window_size)))
    initial_window_used = min(max_window_size,
        qtsp_update_runnable_window_size(initial_window_estimate))
    initial_send_rate = qtsp_update_send_rate(; chi, send_rate,
        werner_w=initial_werner_w, distance_km, a_eta, beta_per_km)
    control = QTSPSourceControl(;
        window_size=initial_window_used,
        werner_w=initial_werner_w,
        send_interval=1 / initial_send_rate,
    )

    QTSPWindowUpdateProtocol(;
        sim,
        net,
        source_node,
        destination_node,
        flow_uuid,
        target_tp,
        iterations,
        source_stop_time,
        initial_window_size,
        max_window_size,
        window_stats_interval,
        initial_werner_w,
        chi,
        send_rate,
        distance_km,
        a_eta,
        beta_per_km,
        detector_a_p,
        detection_prob,
        classical_delay,
        quantum_delay,
        initial_delay,
        source_ack_timeout,
        probe_repeats,
        probe_runner,
        update_stepsize,
        werner_perturbation,
        source_retain_start_slot,
        source_retain_slots,
        source_send_slot,
        destination_receive_start_slot,
        control,
        window_estimate=Ref(initial_window_estimate),
        werner_w=Ref(Float64(initial_werner_w)),
        rng,
        on_update,
    )
end

function qtsp_window_update_after_window!(prot::QTSPWindowUpdateProtocol,
        window_info::QTSPWindowInfo)
    n = window_info.window_index
    n > prot.iterations && return nothing

    window_used = prot.control.window_size
    current_werner_w = prot.werner_w[]
    observed_tp = window_info.acked_throughput
    gamma = qtsp_eval_update_stepsize(prot.update_stepsize, n)
    delta = qtsp_eval_werner_perturbation(prot.werner_perturbation, n)
    plus_w = qtsp_update_clamp_werner(current_werner_w + delta)
    minus_w = qtsp_update_clamp_werner(current_werner_w - delta)

    qtsp_wu_debug(n,
        "callback start window=[$(window_info.window_start), $(window_info.window_end)] W=$(window_used) w=$(current_werner_w) plus=$(plus_w) minus=$(minus_w)")

    qtsp_wu_debug(n, "probe start")
    plus_result, minus_result = prot.probe_runner(prot, plus_w, minus_w, n,
        window_info)
    qtsp_wu_debug(n,
        "probe done plus_tp=$(plus_result.throughput) minus_tp=$(minus_result.throughput)")

    plus_tp = plus_result.throughput
    minus_tp = minus_result.throughput
    next_window_estimate = qtsp_update_window_size(prot.window_estimate[],
        observed_tp, n; target_tp=prot.target_tp, max_window_size=prot.max_window_size,
        update_stepsize=prot.update_stepsize)
    next_window_used = min(prot.max_window_size,
        qtsp_update_runnable_window_size(next_window_estimate))
    next_werner_w, werner_gradient = qtsp_update_werner_parameter(
        current_werner_w, plus_tp, minus_tp, plus_w, minus_w, n;
        update_stepsize=prot.update_stepsize)
    next_send_rate = qtsp_update_send_rate(; chi=prot.chi,
        send_rate=prot.send_rate, werner_w=next_werner_w,
        distance_km=prot.distance_km, a_eta=prot.a_eta,
        beta_per_km=prot.beta_per_km)

    row = (;
        iter=n,
        window_start=window_info.window_start,
        window_end=window_info.window_end,
        gamma,
        delta,
        window_estimate=prot.window_estimate[],
        window_used,
        werner_w=current_werner_w,
        target_tp=prot.target_tp,
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
    push!(prot.rows, row)
    isnothing(prot.on_update) || prot.on_update(row)

    prot.window_estimate[] = next_window_estimate
    prot.werner_w[] = next_werner_w
    prot.control.window_size = next_window_used
    prot.control.werner_w = next_werner_w
    prot.control.send_interval = 1 / next_send_rate

    nothing
end

@resumable function (prot::QTSPWindowUpdateProtocol)()
    @process QTSPDestinationController(;
        sim=prot.sim,
        net=prot.net,
        source_node=prot.source_node,
        destination_node=prot.destination_node,
        flow_uuid=prot.flow_uuid,
        state_count=nothing,
        window_size=prot.control.window_size,
        source_retain_start_slot=prot.source_retain_start_slot,
        destination_receive_start_slot=prot.destination_receive_start_slot,
        detector_a_p=prot.detector_a_p,
        detection_prob=prot.detection_prob,
        rng=prot.rng,
        receive_log=prot.receive_log,
        failure_log=prot.failure_log,
    )()

    @process QTSPSourceController(;
        sim=prot.sim,
        net=prot.net,
        source_node=prot.source_node,
        destination_node=prot.destination_node,
        flow_uuid=prot.flow_uuid,
        state_count=nothing,
        source_stop_time=prot.source_stop_time,
        window_size=prot.control.window_size,
        source_retain_slots=prot.source_retain_slots,
        werner_w=prot.initial_werner_w,
        source_retain_start_slot=prot.source_retain_start_slot,
        source_send_slot=prot.source_send_slot,
        send_interval=prot.control.send_interval,
        initial_delay=prot.initial_delay,
        source_ack_timeout=prot.source_ack_timeout,
        window_stats_interval=prot.window_stats_interval,
        control=prot.control,
        window_update_callback=window_info -> qtsp_window_update_after_window!(prot,
            window_info),
        send_log=prot.send_log,
        ack_log=prot.ack_log,
        timeout_log=prot.timeout_log,
        late_ack_log=prot.late_ack_log,
        window_log=prot.window_log,
    )()

    @yield timeout(prot.sim, max(0.0, prot.source_stop_time - now(prot.sim)) +
        QTSP_TIME_EPS)

    prot.rows
end

function run_qtsp_window_update_protocol!(prot::QTSPWindowUpdateProtocol)
    @process prot()
    run(prot.sim, prot.source_stop_time + QTSP_TIME_EPS)

    prot
end
