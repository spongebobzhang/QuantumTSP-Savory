include("qtsp_two_node_helpers.jl")

using Printf

const QTSP_OUTPUT_TXT = joinpath(@__DIR__, "qtsp_results.txt")
const QTSP_PRINT_STATE_DETAILS = false

const QTSP_DEFAULT_EXPERIMENT_CASE = (;
    flow_uuid=QTSP_DEFAULT_FLOW_UUID,
    state_count=nothing,
    window_size=5,
    werner_w=0.75,
    chi=30.0,
    send_rate=nothing,
    distance_km=25.0,
    a_eta=1.0,
    beta_per_km=0.046,
    detector_a_p=0.9,
    detection_prob=nothing,
    memory_slots=nothing,
    classical_delay=0.0,
    quantum_delay=1.0,
    send_interval=nothing,
    initial_delay=0.0,
    source_ack_timeout=10.0,
    window_stats_interval=10.0,
    sim_time=1000,
)

const QTSP_EXPERIMENT_CASES = (
    QTSP_DEFAULT_EXPERIMENT_CASE,
)

const QTSP_COLUMNS = (
    (name="case", width=4, align=:right),
    (name="flow", width=6, align=:right),
    (name="simT", width=8, align=:right),
    (name="sent", width=6, align=:right),
    (name="recv", width=6, align=:right),
    (name="acked", width=6, align=:right),
    (name="failed", width=7, align=:right),
    (name="timeout", width=7, align=:right),
    (name="late", width=5, align=:right),
    (name="unacked", width=7, align=:right),
    (name="window", width=6, align=:right),
    (name="T_W", width=8, align=:right),
    (name="winSamp", width=7, align=:right),
    (name="meanSent", width=8, align=:right),
    (name="meanAck", width=8, align=:right),
    (name="meanTout", width=8, align=:right),
    (name="send_rate", width=10, align=:right),
    (name="eta", width=8, align=:right),
    (name="P_det", width=8, align=:right),
    (name="exp_det", width=8, align=:right),
    (name="qdelay", width=8, align=:right),
    (name="cdelay", width=8, align=:right),
    (name="w", width=8, align=:right),
    (name="meanTx", width=8, align=:right),
    (name="meanRTT", width=8, align=:right),
    (name="tp", width=8, align=:right),
    (name="meanF", width=8, align=:right),
)

const QTSP_STATE_COLUMNS = (
    (name="flow", width=6, align=:right),
    (name="seq", width=5, align=:right),
    (name="pair", width=5, align=:right),
    (name="src", width=4, align=:right),
    (name="dst", width=4, align=:right),
    (name="sent", width=8, align=:right),
    (name="recv", width=8, align=:right),
    (name="ack", width=8, align=:right),
    (name="tout", width=8, align=:right),
    (name="tx", width=8, align=:right),
    (name="rtt", width=8, align=:right),
    (name="det", width=5, align=:right),
    (name="fail", width=5, align=:right),
    (name="fid", width=8, align=:right),
    (name="retain", width=6, align=:right),
    (name="send", width=6, align=:right),
    (name="dst", width=6, align=:right),
)

const QTSP_WINDOW_COLUMNS = (
    (name="idx", width=4, align=:right),
    (name="start", width=8, align=:right),
    (name="end", width=8, align=:right),
    (name="sent", width=5, align=:right),
    (name="acked", width=5, align=:right),
    (name="tout", width=5, align=:right),
    (name="late", width=5, align=:right),
    (name="tp", width=8, align=:right),
    (name="meanRTT", width=8, align=:right),
)

qtsp_expected_detected_throughput(result) = result.send_rate * result.detection_prob

function qtsp_fmt_float(value)
    isnan(value) ? "NaN" : @sprintf("%.6f", value)
end

qtsp_fmt_vector(values) = isempty(values) ? "-" : join(values, ",")

function qtsp_pad_cell(value, column)
    text = string(value)
    if length(text) > column.width
        text = text[1:column.width]
    end
    column.align == :left ? rpad(text, column.width) : lpad(text, column.width)
end

function qtsp_print_row(io, columns, values)
    for (index, column) in enumerate(columns)
        index > 1 && print(io, " | ")
        print(io, qtsp_pad_cell(values[index], column))
    end
    println(io)
end

qtsp_width(columns) = sum(column.width for column in columns) + 3 * (length(columns) - 1)

function qtsp_print_header(io, columns)
    qtsp_print_row(io, columns, getproperty.(columns, :name))
    println(io, repeat("-", qtsp_width(columns)))
end

function qtsp_case_values(index, row)
    (
        index,
        row.flow_uuid,
        qtsp_fmt_float(row.sim_time),
        row.sent_states,
        row.received_states,
        row.acked_states,
        row.failed_detections,
        row.source_timeouts,
        row.late_acks,
        row.unacked_at_source,
        row.window_size,
        qtsp_fmt_float(row.window_stats_interval),
        row.window_samples,
        qtsp_fmt_float(row.mean_window_sent),
        qtsp_fmt_float(row.mean_window_acked),
        qtsp_fmt_float(row.mean_window_timeouts),
        qtsp_fmt_float(row.send_rate),
        qtsp_fmt_float(row.transmissivity),
        qtsp_fmt_float(row.detection_prob),
        qtsp_fmt_float(qtsp_expected_detected_throughput(row)),
        qtsp_fmt_float(row.quantum_delay),
        qtsp_fmt_float(row.classical_delay),
        qtsp_fmt_float(row.werner_w),
        qtsp_fmt_float(row.mean_quantum_delivery_time),
        qtsp_fmt_float(row.mean_rtt),
        qtsp_fmt_float(row.acked_throughput),
        qtsp_fmt_float(row.mean_observed_fidelity),
    )
end

function qtsp_state_values(record)
    (
        record.flow_uuid,
        record.seq_num,
        record.pair_id,
        record.source_node,
        record.destination_node,
        qtsp_fmt_float(record.send_time),
        qtsp_fmt_float(record.receive_time),
        qtsp_fmt_float(record.ack_time),
        qtsp_fmt_float(record.timeout_time),
        qtsp_fmt_float(record.quantum_delivery_time),
        qtsp_fmt_float(record.rtt),
        record.detected,
        record.failed_detection,
        qtsp_fmt_float(record.observed_fidelity),
        record.source_retain_slot,
        record.source_send_slot,
        record.destination_slot,
    )
end

function qtsp_window_values(record)
    (
        record.window_index,
        qtsp_fmt_float(record.window_start),
        qtsp_fmt_float(record.window_end),
        record.sent_count,
        record.acked_count,
        record.timeout_count,
        record.late_ack_count,
        qtsp_fmt_float(record.acked_throughput),
        qtsp_fmt_float(record.mean_rtt),
    )
end

function print_qtsp_state_details(io, index, row)
    println(io)
    println(io, "Case ", index, " state transmissions:")
    qtsp_print_header(io, QTSP_STATE_COLUMNS)
    for record in row.state_records
        qtsp_print_row(io, QTSP_STATE_COLUMNS, qtsp_state_values(record))
    end
end

function print_qtsp_window_details(io, index, row)
    println(io)
    println(io, "Case ", index, " source time-window samples:")
    if isempty(row.window_log)
        println(io, "No periodic window samples collected.")
        return
    end

    qtsp_print_header(io, QTSP_WINDOW_COLUMNS)
    for record in row.window_log
        qtsp_print_row(io, QTSP_WINDOW_COLUMNS, qtsp_window_values(record))
    end
end

function write_qtsp_results_txt(path, rows)
    open(path, "w") do io
        println(io, "Generated $(length(rows)) QTSP experiment case(s).")
        println(io, "QTSP uses one windowed flow; each wrapped Q-datagram carries (flow, seq, pair) metadata with the traveling Werner-pair qubit.")
        println(io, "Send rate defaults to chi * 3 * (1 - w) / 2 * transmissivity.")
        println(io, "Detection probability defaults to detector_a_p * fidelity_from_werner(w).")
        qtsp_print_header(io, QTSP_COLUMNS)
        for (index, row) in enumerate(rows)
            qtsp_print_row(io, QTSP_COLUMNS, qtsp_case_values(index, row))
        end
        for (index, row) in enumerate(rows)
            QTSP_PRINT_STATE_DETAILS && print_qtsp_state_details(io, index, row)
            print_qtsp_window_details(io, index, row)
        end
    end
end

function run_qtsp_cases(cases=QTSP_EXPERIMENT_CASES; output_txt=QTSP_OUTPUT_TXT)
    rows = NamedTuple[]
    qtsp_print_header(stdout, QTSP_COLUMNS)

    for case in cases
        result = run_two_node_qtsp(; case...)
        push!(rows, result)
        qtsp_print_row(stdout, QTSP_COLUMNS, qtsp_case_values(length(rows), result))
    end

    for (index, row) in enumerate(rows)
        QTSP_PRINT_STATE_DETAILS && print_qtsp_state_details(stdout, index, row)
        print_qtsp_window_details(stdout, index, row)
    end

    write_qtsp_results_txt(output_txt, rows)
    println("Wrote ", output_txt)
    rows
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_qtsp_cases()
end
