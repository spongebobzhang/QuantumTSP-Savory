include(joinpath(@__DIR__, "..", "protocol", "qtsp_window_update_runner.jl"))


# cases outer loop
const EXP2_TARGET_THROUGHPUTS = (1.0, 2.0)
const EXP2_TOPOLOGY = qtsp_graph
const EXP2_SOURCE_NODE = 1
const EXP2_DESTINATION_NODE = 7

# cases inner loop
const EXP2_INITIAL_CASES = (
    (initial_window_size=10, initial_werner_w=0.75),
    (initial_window_size=15, initial_werner_w=0.8),
    (initial_window_size=5, initial_werner_w=0.9),
    (initial_window_size=50, initial_werner_w=0.1),
    (initial_window_size=1, initial_werner_w=0.95)

)

const EXP2_ITERATIONS = 5000
const EXP2_WINDOW_STATS_INTERVAL = 2000.0
const EXP2_SIM_TIME = nothing
const EXP2_OUTPUT_DIR = joinpath(@__DIR__, "results")
const EXP2_SUMMARY_PATH = joinpath(EXP2_OUTPUT_DIR, "summary.tsv")

function exp2_slug(value)
    replace(string(value), "." => "p", "-" => "m")
end

function exp2_result_path(target_tp, initial_window_size, initial_werner_w)
    filename = "target_$(exp2_slug(target_tp))" *
        "_W$(initial_window_size)" *
        "_w$(exp2_slug(initial_werner_w)).txt"

    joinpath(EXP2_OUTPUT_DIR, filename)
end

function exp2_summary_row(target_tp, initial_window_size, initial_werner_w, rows, output_txt)
    final_row = isempty(rows) ? nothing : rows[end]

    (;
        target_tp,
        initial_window_size,
        initial_werner_w,
        iterations=length(rows),
        final_observed_tp=isnothing(final_row) ? NaN : final_row.observed_tp,
        final_window_estimate=isnothing(final_row) ? NaN : final_row.next_window_estimate,
        final_window_used=isnothing(final_row) ? missing : final_row.next_window_used,
        final_werner_w=isnothing(final_row) ? NaN : final_row.next_werner_w,
        final_send_rate=isnothing(final_row) ? NaN : final_row.next_send_rate,
        output_txt,
    )
end

function write_exp2_summary(path, summary_rows)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io,
            "target_tp\tinitial_window_size\tinitial_werner_w\titerations\t" *
            "final_observed_tp\tfinal_window_estimate\tfinal_window_used\t" *
            "final_werner_w\tfinal_send_rate\toutput_txt")
        for row in summary_rows
            println(io, join((
                row.target_tp,
                row.initial_window_size,
                row.initial_werner_w,
                row.iterations,
                row.final_observed_tp,
                row.final_window_estimate,
                row.final_window_used,
                row.final_werner_w,
                row.final_send_rate,
                row.output_txt,
            ), '\t'))
        end
    end
end

function run_exp2()
    mkpath(EXP2_OUTPUT_DIR)
    summary_rows = NamedTuple[]

    for target_tp in EXP2_TARGET_THROUGHPUTS
        for case in EXP2_INITIAL_CASES
            output_txt = exp2_result_path(target_tp, case.initial_window_size,
                case.initial_werner_w)
            println()
            println("Running exp2 case:")
            println("  target_tp = ", target_tp)
            println("  initial_window_size = ", case.initial_window_size)
            println("  initial_werner_w = ", case.initial_werner_w)
            println("  source_node = ", EXP2_SOURCE_NODE)
            println("  destination_node = ", EXP2_DESTINATION_NODE)
            println("  output_txt = ", output_txt)
            flush(stdout)

            rows = run_qtsp_window_update(;
                topology=EXP2_TOPOLOGY,
                source_node=EXP2_SOURCE_NODE,
                destination_node=EXP2_DESTINATION_NODE,
                target_tp,
                iterations=EXP2_ITERATIONS,
                initial_window_size=case.initial_window_size,
                initial_werner_w=case.initial_werner_w,
                max_window_size=100,
                sim_time=EXP2_SIM_TIME,
                probe_repeats=1,
                output_txt,
                flow_uuid=QTSP_DEFAULT_FLOW_UUID,
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
                initial_delay=0.0,
                source_ack_timeout=10.0,
                window_stats_interval=EXP2_WINDOW_STATS_INTERVAL,
            )

            push!(summary_rows, exp2_summary_row(target_tp,
                case.initial_window_size, case.initial_werner_w, rows, output_txt))
            write_exp2_summary(EXP2_SUMMARY_PATH, summary_rows)
            println("Updated ", EXP2_SUMMARY_PATH)
            flush(stdout)
        end
    end

    summary_rows
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_exp2()
end
