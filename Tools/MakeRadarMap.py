#!/usr/bin/env python3
"""Build the radar display's vector base map from Natural Earth.

    python3 Tools/MakeRadarMap.py [output]

Writes Packages/WeatherStarCore/Sources/WeatherStarResources/Assets/Maps/radarmap.bin by
default. Needs only the standard library and a network connection; the output is committed,
so this only has to be run again to change what the map shows.

Why vectors: the radar used to sit on a crop of a 2550x1600 raster of the whole country,
blown up about three times, with its coastline in visible stair-steps. Drawn from vectors the
map is sharp at any size, the way the rest of the app's backgrounds are, and it is drawn in
exactly the coordinates the radar frames are requested in, so the two cannot disagree.

Natural Earth is public domain. The release is pinned so a rebuild is reproducible.

Format (little-endian):
    b"WSMAP\\x01"
    float32 origin longitude, float32 origin latitude, float32 step in degrees
    uint8 layer count
    per layer: uint8 kind, uint32 path count
        per path: uint32 point count, then (uint16 x, uint16 y) per point,
        where longitude = origin + x * step and latitude = origin + y * step
Kinds: 0 land (closed), 1 lakes (closed), 2 national borders (open), 3 state lines (open).
"""

import json
import struct
import sys
import urllib.request
from pathlib import Path

RELEASE = "v5.1.2"
BASE = f"https://raw.githubusercontent.com/nvkelso/natural-earth-vector/{RELEASE}/geojson"

# The radar composite covers 126W-65W, 23N-50N; a window centred anywhere in that reaches
# about 5.3 degrees of longitude and 1.5 of latitude beyond it. A margin on top keeps the
# clipped edges well outside anything a window can show.
WEST, EAST, SOUTH, NORTH = -132.0, -59.0, 20.0, 53.0

# 0.002 degrees is about 200 m: finer than a pixel even on a 4K television, and it still
# fits an unsigned 16-bit integer across the whole box.
STEP = 0.002
# Douglas-Peucker tolerance. The window is 750 km across in 854 points, so 0.004 degrees
# (about 400 m) is half a point on the design canvas.
TOLERANCE = 0.004
# Lakes and islands smaller than this, in square degrees, are dropped: at this scale they
# would be a speck, and Natural Earth has thousands of them.
MIN_AREA = 0.004

LAYERS = [
    (0, "ne_10m_land", "polygon"),
    (1, "ne_10m_lakes", "polygon"),
    (2, "ne_10m_admin_0_boundary_lines_land", "line"),
    (3, "ne_10m_admin_1_states_provinces_lines", "line"),
]


def fetch(name):
    url = f"{BASE}/{name}.geojson"
    print(f"  fetching {url}", file=sys.stderr)
    request = urllib.request.Request(url, headers={"User-Agent": "weatherfeels MakeRadarMap"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)


def geometries(collection, kind):
    for feature in collection["features"]:
        geometry = feature.get("geometry") or {}
        coordinates = geometry.get("coordinates") or []
        if kind == "polygon":
            if geometry.get("type") == "Polygon":
                yield from coordinates
            elif geometry.get("type") == "MultiPolygon":
                for polygon in coordinates:
                    yield from polygon
        else:
            if geometry.get("type") == "LineString":
                yield coordinates
            elif geometry.get("type") == "MultiLineString":
                yield from coordinates


# --- Clipping ---------------------------------------------------------------------------

def clip_ring(ring):
    """Sutherland-Hodgman against the box. Rings are drawn even-odd, so holes come out right."""
    def clip(points, inside, intersect):
        output = []
        for index, current in enumerate(points):
            previous = points[index - 1]
            if inside(current):
                if not inside(previous):
                    output.append(intersect(previous, current))
                output.append(current)
            elif inside(previous):
                output.append(intersect(previous, current))
        return output

    def at_x(x):
        return lambda a, b: (x, a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0]))

    def at_y(y):
        return lambda a, b: (a[0] + (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]), y)

    points = [tuple(p[:2]) for p in ring]
    if len(points) > 1 and points[0] == points[-1]:
        points = points[:-1]
    for inside, intersect in (
        (lambda p: p[0] >= WEST, at_x(WEST)),
        (lambda p: p[0] <= EAST, at_x(EAST)),
        (lambda p: p[1] >= SOUTH, at_y(SOUTH)),
        (lambda p: p[1] <= NORTH, at_y(NORTH)),
    ):
        if not points:
            break
        points = clip(points, inside, intersect)
    return points


def clip_line(line):
    """Split a polyline into the runs that lie inside the box, cutting at its edges."""
    def inside(p):
        return WEST <= p[0] <= EAST and SOUTH <= p[1] <= NORTH

    runs, current = [], []
    points = [tuple(p[:2]) for p in line]
    for index, point in enumerate(points):
        if inside(point):
            if not current and index > 0:
                current.append(edge_point(points[index - 1], point))
            current.append(point)
        elif current:
            current.append(edge_point(current[-1], point))
            runs.append(current)
            current = []
    if current:
        runs.append(current)
    return [run for run in runs if len(run) > 1]


def edge_point(inside_point, outside_point):
    """Where the segment between two points crosses the box, by bisection."""
    a, b = inside_point, outside_point

    def inside(p):
        return WEST <= p[0] <= EAST and SOUTH <= p[1] <= NORTH

    if not inside(a):
        a, b = b, a
    for _ in range(30):
        middle = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
        if inside(middle):
            a = middle
        else:
            b = middle
    return a


# --- Simplifying ------------------------------------------------------------------------

def simplify(points, closed):
    """Douglas-Peucker, iteratively so the continent's ring does not exhaust the stack."""
    if len(points) < 4:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        start, end = stack.pop()
        ax, ay = points[start]
        bx, by = points[end]
        dx, dy = bx - ax, by - ay
        length = (dx * dx + dy * dy) ** 0.5
        farthest, distance = None, TOLERANCE
        for index in range(start + 1, end):
            px, py = points[index]
            if length == 0:
                d = ((px - ax) ** 2 + (py - ay) ** 2) ** 0.5
            else:
                d = abs(dy * px - dx * py + bx * ay - by * ax) / length
            if d > distance:
                farthest, distance = index, d
        if farthest is not None:
            keep[farthest] = True
            stack.append((start, farthest))
            stack.append((farthest, end))
    result = [p for p, kept in zip(points, keep) if kept]
    return result if not closed or len(result) >= 3 else []


def area(ring):
    total = 0.0
    for index, (x1, y1) in enumerate(ring):
        x2, y2 = ring[(index + 1) % len(ring)]
        total += x1 * y2 - x2 * y1
    return abs(total) / 2


# --- Encoding ---------------------------------------------------------------------------

def quantise(points):
    encoded, last = [], None
    for lon, lat in points:
        x = round((lon - WEST) / STEP)
        y = round((lat - SOUTH) / STEP)
        if (x, y) != last:
            encoded.append((x, y))
            last = (x, y)
    return encoded


def build_layer(kind, name, shape):
    paths = []
    for coordinates in geometries(fetch(name), shape):
        if shape == "polygon":
            ring = clip_ring(coordinates)
            if len(ring) < 3 or area(ring) < MIN_AREA:
                continue
            ring = simplify(ring + [ring[0]], closed=True)[:-1]
            if len(ring) >= 3:
                paths.append(quantise(ring))
        else:
            for run in clip_line(coordinates):
                run = simplify(run, closed=False)
                if len(run) >= 2:
                    paths.append(quantise(run))
    return kind, [p for p in paths if len(p) >= 2]


def main():
    root = Path(__file__).resolve().parent.parent
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else (
        root / "Packages/WeatherStarCore/Sources/WeatherStarResources/Assets/Maps/radarmap.bin"
    )
    layers = [build_layer(kind, name, shape) for kind, name, shape in LAYERS]

    data = bytearray(b"WSMAP\x01")
    data += struct.pack("<fff", WEST, SOUTH, STEP)
    data += struct.pack("<B", len(layers))
    for kind, paths in layers:
        data += struct.pack("<BI", kind, len(paths))
        for path in paths:
            data += struct.pack("<I", len(path))
            for x, y in path:
                data += struct.pack("<HH", x, y)
    output.write_bytes(bytes(data))

    for kind, paths in layers:
        points = sum(len(p) for p in paths)
        print(f"  layer {kind}: {len(paths)} paths, {points} points", file=sys.stderr)
    print(f"wrote {output} ({len(data) / 1024:.0f} KB)", file=sys.stderr)


if __name__ == "__main__":
    main()
