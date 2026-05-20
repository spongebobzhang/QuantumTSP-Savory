include("qtcp_werner_two_node.jl")

using Printf

###
# Edit this block to control the experiment.
###

const OUTPUT_TXT = joinpath(@__DIR__, "qtcp_werner_results.txt")

# Each case can set a different value for any parameter below.
const DEFAULT_EXPERIMENT_CASE = (;
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
    sim_time=200.0,
    success_prob=DEFAULT_SUCCESS_PROB,
    attempt_time=DEFAULT_ATTEMPT_TIME,
    memory_slots=nothing,
    initial_request_delay=DEFAULT_INITIAL_REQUEST_DELAY,
)

const EXPERIMENT_CASES = (
    DEFAULT_EXPERIMENT_CASE
    
    # (; DEFAULT_EXPERIMENT_CASE..., source_window_size=100, source_ack_timeout=2.0),
)

###
# Runner.
###

expected_detected_throughput(result) = result.request_rate * result.detection_prob

function expected_tp_value(; window_size, sim_time, werner_w, chi, distance_km,
        a_eta, beta_per_km, detector_a_p)
    isnothing(chi) && return NaN

    transmissivity = transmissivity_from_distance(distance_km, a_eta, beta_per_km)

    window_size / sim_time * transmissivity * chi * detector_a_p * 3 / 8 *
        (2 * werner_w - 3 * werner_w^2 + 1)
end

function run_qtcp_werner_case(;
        werner_w=DEFAULT_EXPERIMENT_CASE.werner_w,
        sim_time=DEFAULT_EXPERIMENT_CASE.sim_time,
        success_prob=DEFAULT_EXPERIMENT_CASE.success_prob,
        attempt_time=DEFAULT_EXPERIMENT_CASE.attempt_time,
        chi=DEFAULT_EXPERIMENT_CASE.chi,
        request_rate=DEFAULT_EXPERIMENT_CASE.request_rate,
        memory_slots=DEFAULT_EXPERIMENT_CASE.memory_slots,
        distance_km=DEFAULT_EXPERIMENT_CASE.distance_km,
        a_eta=DEFAULT_EXPERIMENT_CASE.a_eta,
        beta_per_km=DEFAULT_EXPERIMENT_CASE.beta_per_km,
        initial_request_delay=DEFAULT_EXPERIMENT_CASE.initial_request_delay,
        detector_a_p=DEFAULT_EXPERIMENT_CASE.detector_a_p,
        detection_prob=DEFAULT_EXPERIMENT_CASE.detection_prob,
        source_window_size=DEFAULT_EXPERIMENT_CASE.source_window_size,
        source_ack_timeout=DEFAULT_EXPERIMENT_CASE.source_ack_timeout,
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
        expected_detected_throughput=expected_detected_throughput(result),
        expected_tp=expected_tp_value(;
            window_size=source_window_size,
            sim_time,
            werner_w,
            chi=result.chi,
            distance_km,
            a_eta,
            beta_per_km,
            detector_a_p,
        ),
    )
end

const TXT_COLUMNS = (
    (name="case", width=4, align=:right),
    (name="sent", width=6, align=:right),
    (name="completed", width=9, align=:right),
    (name="acked", width=8, align=:right),
    (name="failed", width=7, align=:right),
    (name="timeout", width=7, align=:right),
    (name="late", width=5, align=:right),
    (name="unacked", width=7, align=:right),
    (name="req_rate", width=10, align=:right),
    (name="P_det", width=8, align=:right),
    (name="exp_det_tp", width=10, align=:right),
    (name="exp_tp", width=10, align=:right),
    (name="tp", width=8, align=:right),
    (name="meanRTT", width=8, align=:right),
    (name="meanF", width=8, align=:right),
)

const FLOW_IDS_PER_LINE = 16

function fmt_float(value)
    isnan(value) ? "NaN" : @sprintf("%.6f", value)
end

fmt_optional_float(value) = isnothing(value) ? "none" : fmt_float(value)

function pad_cell(value, column)
    text = string(value)
    if length(text) > column.width
        text = text[1:column.width]
    end
    column.align == :left ? rpad(text, column.width) : lpad(text, column.width)
end

function print_txt_row(io, values)
    for (index, column) in enumerate(TXT_COLUMNS)
        index > 1 && print(io, " | ")
        print(io, pad_cell(values[index], column))
    end
    println(io)
end

txt_width() = sum(column.width for column in TXT_COLUMNS) + 3 * (length(TXT_COLUMNS) - 1)

function print_txt_header(io)
    print_txt_row(io, getproperty.(TXT_COLUMNS, :name))
    println(io, repeat("-", txt_width()))
end

function result_txt_values(index, row)
    (
        index,
        row.sent_requests,
        row.completed_pairs,
        row.acked_pairs,
        row.failed_detections,
        row.source_timeouts,
        row.late_acks,
        row.unacked_at_source,
        fmt_float(row.request_rate),
        fmt_float(row.detection_prob),
        fmt_float(row.expected_detected_throughput),
        fmt_float(row.expected_tp),
        fmt_float(row.acked_pairs / row.sim_time),
        fmt_float(row.mean_rtt),
        fmt_float(row.mean_observed_fidelity),
    )
end

flow_key(entry) = (entry.flow_uuid, entry.seq_num)

function sorted_flow_keys(keys)
    sort(collect(keys); by=key -> (key[1], key[2]))
end

function format_flow_key(key)
    flow_uuid, seq_num = key
    isone(seq_num) ? string(flow_uuid) : string(flow_uuid, ".", seq_num)
end

function print_flow_id_list(io, label, keys)
    println(io, "  ", label, " (", length(keys), "):")
    if isempty(keys)
        println(io, "    none")
        return
    end

    ids = format_flow_key.(keys)
    for start in 1:FLOW_IDS_PER_LINE:length(ids)
        stop = min(start + FLOW_IDS_PER_LINE - 1, lastindex(ids))
        println(io, "    ", join(ids[start:stop], ", "))
    end
end

function print_flow_id_summary(io, index, row)
    sent_keys = Set(flow_key(entry) for entry in row.source_sent_log)
    acked_keys = Set(flow_key(entry) for entry in row.source_ack_log)
    timeout_keys = Set(flow_key(entry) for entry in row.source_timeout_log)
    late_ack_keys = Set(flow_key(entry) for entry in row.source_late_ack_log)
    detector_failed_keys = Set(flow_key(pair) for pair in row.pairs if !pair.detected)
    unacked_keys = setdiff(setdiff(sent_keys, acked_keys), timeout_keys)

    println(io, "Case ", index, " flow IDs:")
    print_flow_id_list(io, "sent", sorted_flow_keys(sent_keys))
    print_flow_id_list(io, "acked", sorted_flow_keys(acked_keys))
    print_flow_id_list(io, "detector failed", sorted_flow_keys(detector_failed_keys))
    print_flow_id_list(io, "source timed out", sorted_flow_keys(timeout_keys))
    print_flow_id_list(io, "late ACK", sorted_flow_keys(late_ack_keys))
    print_flow_id_list(io, "still unacked", sorted_flow_keys(unacked_keys))
end

function print_flow_id_summaries(io, rows)
    println(io)
    println(io, "Flow IDs")
    println(io, repeat("-", 8))
    for (index, row) in enumerate(rows)
        index > 1 && println(io)
        print_flow_id_summary(io, index, row)
    end
end

function write_results_txt(path, rows)
    open(path, "w") do io
        println(io, "Generated $(length(rows)) QTCP Werner experiment case(s).")
        println(io, "All requests in a case use the same Werner parameter w.")
        print_txt_header(io)

        for (index, row) in enumerate(rows)
            print_txt_row(io, result_txt_values(index, row))
        end

        print_flow_id_summaries(io, rows)
    end
end

function run_qtcp_werner_cases(cases=EXPERIMENT_CASES; output_txt=OUTPUT_TXT)
    rows = NamedTuple[]
    print_txt_header(stdout)

    for case in cases
        result = run_qtcp_werner_case(; case...)
        push!(rows, result)

        print_txt_row(stdout, result_txt_values(length(rows), result))
    end

    print_flow_id_summaries(stdout, rows)
    write_results_txt(output_txt, rows)
    println("Wrote ", output_txt)
    rows
end

run_parameter_grid() = run_qtcp_werner_cases()

if abspath(PROGRAM_FILE) == @__FILE__
    run_qtcp_werner_cases()
end
