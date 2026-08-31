#!/usr/bin/env python3
"""Convert a GraphML topology into Julia helpers for QTSP.

The output is meant to be pasted into `simulation/qtsp/qtsp_topologies.jl`.
It maps arbitrary GraphML node IDs onto Graphs.jl's 1-based vertex IDs and
deduplicates parallel edges because `SimpleGraph` cannot represent them.
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import TextIO


GRAPHML_NS = {"g": "http://graphml.graphdrawing.org/xmlns"}


def julia_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def graphml_key_ids(root: ET.Element, scope: str) -> dict[str, str]:
    keys: dict[str, str] = {}
    for key in root.findall("g:key", GRAPHML_NS):
        if key.attrib.get("for") == scope and "attr.name" in key.attrib:
            keys[key.attrib["attr.name"]] = key.attrib["id"]
    return keys


def node_data(node: ET.Element) -> dict[str, str]:
    return {
        data.attrib["key"]: data.text or ""
        for data in node.findall("g:data", GRAPHML_NS)
    }


def parse_graphml(path: Path) -> tuple[list[str], list[tuple[int, int]], list[str], list[tuple[float, float] | None]]:
    root = ET.parse(path).getroot()
    graph = root.find("g:graph", GRAPHML_NS)
    if graph is None:
        raise ValueError(f"No <graph> element found in {path}")

    node_key_ids = graphml_key_ids(root, "node")
    label_key = node_key_ids.get("label")
    latitude_key = node_key_ids.get("Latitude")
    longitude_key = node_key_ids.get("Longitude")

    node_elements = graph.findall("g:node", GRAPHML_NS)
    graphml_node_ids = [node.attrib["id"] for node in node_elements]
    node_index = {node_id: index for index, node_id in enumerate(graphml_node_ids, start=1)}

    labels: list[str] = []
    coordinates: list[tuple[float, float] | None] = []
    for node in node_elements:
        data = node_data(node)
        labels.append(data.get(label_key, node.attrib["id"]) if label_key else node.attrib["id"])
        if latitude_key and longitude_key and latitude_key in data and longitude_key in data:
            coordinates.append((float(data[latitude_key]), float(data[longitude_key])))
        else:
            coordinates.append(None)

    seen_edges: set[tuple[int, int]] = set()
    edges: list[tuple[int, int]] = []
    for edge in graph.findall("g:edge", GRAPHML_NS):
        src = node_index[edge.attrib["source"]]
        dst = node_index[edge.attrib["target"]]
        if src == dst:
            continue
        simple_edge = tuple(sorted((src, dst)))
        if simple_edge in seen_edges:
            continue
        seen_edges.add(simple_edge)
        edges.append(simple_edge)

    return graphml_node_ids, edges, labels, coordinates


def emit_julia_topology(
    io: TextIO,
    prefix: str,
    node_count: int,
    edges: list[tuple[int, int]],
    labels: list[str],
    coordinates: list[tuple[float, float] | None],
) -> None:
    print(f"function {prefix}_edges()", file=io)
    print("    [", file=io)
    for src, dst in edges:
        print(f"        ({src}, {dst}),", file=io)
    print("    ]", file=io)
    print("end", file=io)
    print(file=io)

    print(f"function {prefix}_graph()", file=io)
    print(f"    qtsp_graph_from_edges({node_count}, {prefix}_edges())", file=io)
    print("end", file=io)
    print(file=io)

    print(f"function {prefix}_node_labels()", file=io)
    print("    [", file=io)
    for label in labels:
        print(f"        {julia_string(label)},", file=io)
    print("    ]", file=io)
    print("end", file=io)
    print(file=io)

    if all(coord is not None for coord in coordinates):
        print(f"function {prefix}_node_coordinates()", file=io)
        print("    [", file=io)
        for coord in coordinates:
            assert coord is not None
            latitude, longitude = coord
            print(f"        ({latitude:.10f}, {longitude:.10f}),", file=io)
        print("    ]", file=io)
        print("end", file=io)
        print(file=io)

    print(f"function {prefix}_node_index(label::AbstractString)", file=io)
    print(f"    index = findfirst(==(label), {prefix}_node_labels())", file=io)
    print(f"    isnothing(index) && throw(ArgumentError(\"Unknown {prefix} node label: $(label).\"))", file=io)
    print(file=io)
    print("    index", file=io)
    print("end", file=io)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Extract a GraphML file into Julia QTSP topology helpers.",
    )
    parser.add_argument("graphml_path", type=Path)
    parser.add_argument(
        "--prefix",
        default="graphml_topology",
        help="Julia function prefix, for example 'surfnet'.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Write generated Julia code to this file instead of stdout.",
    )
    args = parser.parse_args(argv)

    _, edges, labels, coordinates = parse_graphml(args.graphml_path)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("w", encoding="utf-8") as io:
            emit_julia_topology(io, args.prefix, len(labels), edges, labels, coordinates)
    else:
        emit_julia_topology(sys.stdout, args.prefix, len(labels), edges, labels, coordinates)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
