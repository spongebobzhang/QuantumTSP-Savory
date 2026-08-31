include(joinpath(@__DIR__, "qtsp_topologies.jl"))

using Printf

function qtsp_print_tsv_row(io, values)
    println(io, join(values, '\t'))
end

function print_surfnet_nodes(io=stdout)
    labels = surfnet_node_labels()
    coordinates = surfnet_node_coordinates()

    qtsp_print_tsv_row(io, ("node", "label", "latitude", "longitude"))
    for node in eachindex(labels)
        latitude, longitude = coordinates[node]
        qtsp_print_tsv_row(io, (
            node,
            labels[node],
            @sprintf("%.10f", latitude),
            @sprintf("%.10f", longitude),
        ))
    end
end

function print_surfnet_edges(io=stdout;
        signal_speed_km_per_time=200_000.0,
        path_stretch=1.0,
        per_link_processing_delay=0.0)
    labels = surfnet_node_labels()
    distances = surfnet_edge_distances_km(; path_stretch)
    delays = surfnet_classical_delay_map(;
        signal_speed_km_per_time,
        path_stretch,
        per_link_processing_delay,
    )

    qtsp_print_tsv_row(io, (
        "src",
        "dst",
        "src_label",
        "dst_label",
        "distance_km",
        "classical_delay",
    ))
    for edge in surfnet_edges()
        src, dst = edge
        qtsp_print_tsv_row(io, (
            src,
            dst,
            labels[src],
            labels[dst],
            @sprintf("%.6f", distances[edge]),
            @sprintf("%.12f", delays[edge]),
        ))
    end
end

function print_surfnet_topology(; output_path=nothing,
        signal_speed_km_per_time=200_000.0,
        path_stretch=1.0,
        per_link_processing_delay=0.0)
    io = isnothing(output_path) ? stdout : open(output_path, "w")
    try
        println(io, "# SURFnet nodes")
        print_surfnet_nodes(io)
        println(io)
        println(io, "# SURFnet edges")
        print_surfnet_edges(io;
            signal_speed_km_per_time,
            path_stretch,
            per_link_processing_delay,
        )
    finally
        isnothing(output_path) || close(io)
    end

    nothing
end

function main(args=ARGS)
    output_path = isempty(args) ? nothing : only(args)
    print_surfnet_topology(; output_path)
end

if abspath(PROGRAM_FILE) == @__FILE__
    try
        main()
    catch err
        occursin("broken pipe", lowercase(sprint(showerror, err))) && exit(0)
        rethrow()
    end
end
