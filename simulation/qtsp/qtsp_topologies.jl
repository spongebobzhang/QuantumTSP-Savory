using Graphs

function qtsp_graph_from_edges(node_count::Int, edges_list)
    graph = SimpleGraph(node_count)
    for (u, v) in edges_list
        add_edge!(graph, u, v)
    end

    graph
end

function qtsp_graph()
    edges_list = [
        (1, 3), (1, 5),
        (2, 3),
        (3, 4),
        (4, 5), (4, 6),
        (5, 6),
        (6, 7)
    ]

    qtsp_graph_from_edges(7, edges_list)
end
