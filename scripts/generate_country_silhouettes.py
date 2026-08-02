#!/usr/bin/env python3
"""Generate compact, normalized country silhouettes from Natural Earth GeoJSON.

Natural Earth data is public domain:
https://www.naturalearthdata.com/downloads/50m-cultural-vectors/
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Iterable

Point = tuple[float, float]
Ring = list[Point]


def country_code(properties: dict[str, object]) -> str | None:
    for key in ("ISO_A2_EH", "ISO_A2", "WB_A2", "POSTAL"):
        value = str(properties.get(key) or "").strip().upper()
        if len(value) == 2 and value != "-99":
            return value
    return None


def geometry_rings(geometry: dict[str, object]) -> Iterable[Ring]:
    coordinates = geometry.get("coordinates")
    if not isinstance(coordinates, list):
        return
    geometry_type = geometry.get("type")
    polygons = [coordinates] if geometry_type == "Polygon" else coordinates
    if geometry_type not in {"Polygon", "MultiPolygon"}:
        return
    for polygon in polygons:
        if not isinstance(polygon, list):
            continue
        for raw_ring in polygon:
            if not isinstance(raw_ring, list):
                continue
            ring = [
                (float(point[0]), float(point[1]))
                for point in raw_ring
                if isinstance(point, list) and len(point) >= 2
            ]
            if len(ring) >= 4:
                yield ring


def perpendicular_distance(point: Point, start: Point, end: Point) -> float:
    if start == end:
        return math.dist(point, start)
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    numerator = abs(dy * point[0] - dx * point[1] + end[0] * start[1] - end[1] * start[0])
    return numerator / math.hypot(dx, dy)


def simplify_open(points: Ring, tolerance: float) -> Ring:
    if len(points) <= 4:
        return points
    first = points[0]
    last = points[-1]
    max_distance = 0.0
    split_index = 0
    for index, point in enumerate(points[1:-1], start=1):
        distance = perpendicular_distance(point, first, last)
        if distance > max_distance:
            max_distance = distance
            split_index = index

    if max_distance <= tolerance:
        return [first, last]
    left = simplify_open(points[: split_index + 1], tolerance)
    right = simplify_open(points[split_index:], tolerance)
    return left[:-1] + right


def simplify(points: Ring, tolerance: float) -> Ring:
    was_closed = points[0] == points[-1]
    open_points = points[:-1] if was_closed else points
    result = simplify_open(open_points, tolerance)
    return result + [result[0]] if was_closed else result


def normalize(rings: list[Ring]) -> list[list[list[float]]]:
    points = [point for ring in rings for point in ring]
    longitudes = [point[0] for point in points]
    crosses_dateline = max(longitudes) - min(longitudes) > 180
    adjusted = [
        [
            ((longitude + 360 if crosses_dateline and longitude < 0 else longitude), latitude)
            for longitude, latitude in ring
        ]
        for ring in rings
    ]
    latitudes = [latitude for ring in adjusted for _, latitude in ring]
    center_latitude = math.radians((min(latitudes) + max(latitudes)) / 2)
    longitude_scale = max(math.cos(center_latitude), 0.2)
    projected = [
        [(longitude * longitude_scale, latitude) for longitude, latitude in ring]
        for ring in adjusted
    ]
    projected_points = [point for ring in projected for point in ring]
    min_x = min(point[0] for point in projected_points)
    max_x = max(point[0] for point in projected_points)
    min_y = min(point[1] for point in projected_points)
    max_y = max(point[1] for point in projected_points)
    width = max(max_x - min_x, 0.0001)
    height = max(max_y - min_y, 0.0001)
    scale = max(width, height) / 0.90
    x_padding = (1 - width / scale) / 2
    y_padding = (1 - height / scale) / 2

    normalized: list[list[list[float]]] = []
    for ring in projected:
        points_in_square = [
            (
                x_padding + (x - min_x) / scale,
                1 - (y_padding + (y - min_y) / scale),
            )
            for x, y in ring
        ]
        detailed = simplify(points_in_square, tolerance=0.0015)
        if len(detailed) >= 4:
            normalized.append([[round(x, 5), round(y, 5)] for x, y in detailed])
    return normalized


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    source = json.loads(args.input.read_text(encoding="utf-8"))
    countries: dict[str, list[Ring]] = {}
    for feature in source.get("features", []):
        code = country_code(feature.get("properties", {}))
        if code is None:
            continue
        countries.setdefault(code, []).extend(geometry_rings(feature.get("geometry", {})))

    payload = {
        "source": "Natural Earth 1:50m Admin 0 Countries (public domain)",
        "countries": {
            code: {"rings": normalize(rings)}
            for code, rings in sorted(countries.items())
            if rings
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
