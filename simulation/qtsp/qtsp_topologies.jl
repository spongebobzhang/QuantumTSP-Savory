using Graphs

function qtsp_graph_from_edges(node_count::Int, edges_list)
    graph = SimpleGraph(node_count)
    for (u, v) in edges_list
        add_edge!(graph, u, v)
    end

    graph
end
# Graph to be set
function qtsp_graph()
    edges_list = [
        (1, 3), (1, 5),
        (2, 3),
        (3, 4),
        (4, 5), (4, 6),
        (5, 6), (5, 8),
        (6, 7), (6, 8),
        (7, 8)
    ]
    # input node_count and edges_list to create the graph
    qtsp_graph_from_edges(8, edges_list)
end

function surfnet_edges()
    [
        (1, 2),
        (2, 9),
        (2, 4),
        (3, 42),
        (3, 4),
        (3, 7),
        (4, 50),
        (5, 9),
        (5, 10),
        (5, 8),
        (6, 9),
        (6, 48),
        (7, 8),
        (9, 33),
        (9, 36),
        (9, 39),
        (9, 48),
        (9, 37),
        (9, 31),
        (9, 32),
        (10, 33),
        (11, 12),
        (12, 20),
        (12, 24),
        (13, 31),
        (14, 15),
        (14, 31),
        (15, 43),
        (15, 16),
        (15, 46),
        (16, 17),
        (17, 18),
        (18, 19),
        (19, 20),
        (20, 25),
        (20, 31),
        (21, 27),
        (21, 22),
        (22, 29),
        (23, 38),
        (23, 31),
        (24, 31),
        (25, 28),
        (26, 28),
        (26, 38),
        (27, 28),
        (27, 30),
        (29, 30),
        (31, 37),
        (31, 39),
        (31, 32),
        (33, 34),
        (33, 39),
        (33, 40),
        (34, 35),
        (35, 36),
        (38, 39),
        (39, 40),
        (41, 42),
        (41, 50),
        (43, 45),
        (43, 47),
        (44, 45),
        (44, 47),
        (46, 48),
        (47, 48),
        (48, 49),
        (49, 50),
    ]
end

function surfnet_graph()
    qtsp_graph_from_edges(50, surfnet_edges())
end

function surfnet_node_coordinates()
    [
        (52.8500000000, 6.6083300000),
        (52.8341700000, 6.3694400000),
        (53.2191700000, 6.5666700000),
        (52.9966700000, 6.5625000000),
        (52.6316700000, 4.7486100000),
        (52.5083300000, 5.4750000000),
        (53.2013900000, 5.8085900000),
        (52.9598800000, 4.7593300000),
        (52.3740300000, 4.8896900000),
        (52.3808400000, 4.6368300000),
        (51.7650000000, 5.5180600000),
        (51.6991700000, 5.3041700000),
        (52.0283300000, 5.1680600000),
        (51.9700000000, 5.6666700000),
        (51.8425000000, 5.8527800000),
        (51.3700000000, 6.1680600000),
        (50.8836500000, 5.9815400000),
        (50.8483300000, 5.6888900000),
        (51.1392900000, 5.8862700000),
        (51.4408300000, 5.4777800000),
        (51.4925000000, 4.0500000000),
        (51.4425000000, 3.5736100000),
        (52.0166700000, 4.7083300000),
        (52.0291700000, 5.0805600000),
        (51.5555100000, 5.0913000000),
        (51.8100000000, 4.6736100000),
        (51.4950000000, 4.2916700000),
        (51.5865600000, 4.7759600000),
        (51.5000000000, 3.6138900000),
        (51.6500000000, 3.9194400000),
        (52.0908300000, 5.1222200000),
        (52.1741700000, 5.0013900000),
        (52.1583300000, 4.4930600000),
        (52.1800000000, 4.4694400000),
        (52.2600000000, 4.5569400000),
        (52.3000000000, 4.7500000000),
        (52.2233300000, 5.1763900000),
        (51.9225000000, 4.4791700000),
        (52.0066700000, 4.3555600000),
        (52.0766700000, 4.2986100000),
        (52.7791700000, 6.9069400000),
        (53.1441700000, 7.0347200000),
        (51.9800000000, 5.9111100000),
        (52.2100000000, 5.9694400000),
        (52.1383300000, 6.2013900000),
        (52.2183300000, 6.8958300000),
        (52.2550000000, 6.1638900000),
        (52.5125000000, 6.0944400000),
        (52.6958300000, 6.1944400000),
        (52.7225000000, 6.4763900000),
    ]
end

function surfnet_node_labels()
    [
        "Westerbork",
        "Dwingeloo",
        "Groningen",
        "Assen",
        "Alkmaar",
        "Lelystad",
        "Leeuwarden",
        "Den Helder",
        "Amsterdam",
        "Haarlem",
        "Oss",
        "Den Bosch",
        "Houten",
        "Wageningen",
        "Nijmegen",
        "Venlo",
        "Heerlen",
        "Maastricht",
        "Maasbracht",
        "Eindhoven",
        "Yerseke",
        "Vlissingen",
        "Gouda",
        "Nieuwegen",
        "Tilburg",
        "Dordrecht",
        "Bergen op Zoom",
        "Breda",
        "Middelburg",
        "Zierikzee",
        "Utrecht",
        "Breukelen",
        "Leiden",
        "Oegstgeest",
        "Lisse",
        "Schiphol-Rijk",
        "Hilversum",
        "Rotterdam",
        "Delft",
        "Den Haag",
        "Emmen",
        "Winschoten",
        "Arnhem",
        "Apeldoorn",
        "Zutphen",
        "Enschede",
        "Deventer",
        "Zwolle",
        "Meppel",
        "Hoogeveen",
    ]
end

function surfnet_node_index(label::AbstractString)
    index = findfirst(==(label), surfnet_node_labels())
    isnothing(index) && throw(ArgumentError("Unknown SURFnet node label: $(label)."))

    index
end

function qtsp_haversine_km(coord_a, coord_b; earth_radius_km=6371.0)
    lat_a, lon_a = coord_a
    lat_b, lon_b = coord_b
    φ_a = deg2rad(lat_a)
    φ_b = deg2rad(lat_b)
    Δφ = deg2rad(lat_b - lat_a)
    Δλ = deg2rad(lon_b - lon_a)
    a = clamp(sin(Δφ / 2)^2 + cos(φ_a) * cos(φ_b) * sin(Δλ / 2)^2,
        0.0, 1.0)

    2 * earth_radius_km * atan(sqrt(a), sqrt(1 - a))
end

function surfnet_edge_distances_km(; path_stretch=1.0)
    path_stretch > 0 || throw(ArgumentError("path_stretch must be positive."))
    coordinates = surfnet_node_coordinates()

    Dict(edge => path_stretch *
        qtsp_haversine_km(coordinates[edge[1]], coordinates[edge[2]])
        for edge in surfnet_edges())
end

function surfnet_classical_delay_map(;
        signal_speed_km_per_time=200_000.0,
        path_stretch=1.0,
        per_link_processing_delay=0.0)
    signal_speed_km_per_time > 0 || throw(ArgumentError(
        "signal_speed_km_per_time must be positive.",
    ))
    per_link_processing_delay >= 0 || throw(ArgumentError(
        "per_link_processing_delay must be non-negative.",
    ))

    Dict(edge => distance_km / signal_speed_km_per_time + per_link_processing_delay
        for (edge, distance_km) in surfnet_edge_distances_km(; path_stretch))
end
