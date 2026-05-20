using CairoMakie

const DEFAULT_RESULT_PATH = joinpath(@__DIR__, "result1.txt")
const DEFAULT_OUTPUT_PATH = joinpath(@__DIR__, "result1_throughput.png")
const DEFAULT_TARGET_THROUGHPUT = 2.4

function parse_qtsp_window_update_table(path)
    lines = readlines(path)
    header_index = findfirst(line -> occursin(r"^\s*iter\s*\|", line), lines)
    isnothing(header_index) && throw(ArgumentError(
        "Could not find the window-update table header in $(path).",
    ))

    header = strip.(split(lines[header_index], "|"))
    iter_column = findfirst(==("iter"), header)
    tp_column = findfirst(==("tp"), header)
    if isnothing(iter_column) || isnothing(tp_column)
        throw(ArgumentError("The table must contain both iter and tp columns."))
    end

    iterations = Int[]
    throughputs = Float64[]
    for line in lines[(header_index + 1):end]
        stripped = strip(line)
        isempty(stripped) && continue
        startswith(stripped, "-") && continue
        occursin("|", line) || continue

        cells = strip.(split(line, "|"))
        length(cells) >= max(iter_column, tp_column) || continue

        try
            push!(iterations, parse(Int, cells[iter_column]))
            push!(throughputs, parse(Float64, cells[tp_column]))
        catch err
            @warn "Skipping non-data table row." line exception=(err, catch_backtrace())
        end
    end

    isempty(iterations) && throw(ArgumentError("No throughput rows were parsed from $(path)."))

    iterations, throughputs
end

function plot_qtsp_throughput(iterations, throughputs;
        target_throughput=DEFAULT_TARGET_THROUGHPUT,
        title="QTSP throughput by update iteration")
    fig = Figure(size=(1100, 650), fontsize=18)
    ax = Axis(fig[1, 1];
        xlabel="Iteration",
        ylabel="Throughput",
        title,
        xgridvisible=true,
        ygridvisible=true,
    )

    lines!(ax, iterations, throughputs;
        color=:steelblue,
        linewidth=1.5,
        label="observed throughput",
    )
    hlines!(ax, [target_throughput];
        color=:crimson,
        linestyle=:dash,
        linewidth=2.5,
        label="target throughput = $(target_throughput)",
    )

    xlims!(ax, first(iterations), last(iterations))
    half_span = max(maximum(abs.(throughputs .- target_throughput)) * 1.08,
        target_throughput * 0.15,
        0.1)
    ylims!(ax, target_throughput - half_span, target_throughput + half_span)

    axislegend(ax; position=:rt)

    fig
end

function main(args=ARGS)
    input_path = length(args) >= 1 ? args[1] : DEFAULT_RESULT_PATH
    output_path = length(args) >= 2 ? args[2] : DEFAULT_OUTPUT_PATH
    target_throughput = length(args) >= 3 ?
        parse(Float64, args[3]) :
        DEFAULT_TARGET_THROUGHPUT

    iterations, throughputs = parse_qtsp_window_update_table(input_path)
    fig = plot_qtsp_throughput(iterations, throughputs;
        target_throughput,
        title="QTSP throughput from $(basename(input_path))")
    save(output_path, fig)

    println("Parsed ", length(iterations), " rows from ", input_path)
    println("Wrote ", output_path)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
