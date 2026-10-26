#!/usr/bin/env python3
"""Build the table of NOAA tide prediction stations the Tides display looks up.

    python3 Tools/MakeTideStations.py [output]

Writes Packages/WeatherStarCore/Sources/WeatherStarResources/Assets/Data/tidestations.json by
default. Needs only the standard library. The output is committed, like the city and station
tables, so finding the nearest station costs no network and works before the first fetch.

Bundled rather than fetched at run time because the list is 2 MB of JSON and changes a few
times a year, while the answer the app needs from it — which station is nearest — is the same
every time for a given place. The compact form keeps id, name, state and position only.

Source: NOAA CO-OPS metadata API, every station with tide predictions, reference ("R") and
subordinate ("S") alike; both answer high/low prediction requests. Public domain.
"""

import json
import sys
import urllib.request
from pathlib import Path

URL = "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=tidepredictions"


def main():
    root = Path(__file__).resolve().parent.parent
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else (
        root / "Packages/WeatherStarCore/Sources/WeatherStarResources/Assets/Data/tidestations.json"
    )
    request = urllib.request.Request(URL, headers={"User-Agent": "weatherfeels MakeTideStations"})
    with urllib.request.urlopen(request, timeout=120) as response:
        stations = json.load(response)["stations"]

    rows = sorted(
        [
            s["id"],
            " ".join(s["name"].split()),
            s.get("state") or "",
            round(float(s["lat"]), 4),
            round(float(s["lng"]), 4),
        ]
        for s in stations
        if s.get("id") and s.get("name") and s.get("lat") is not None and s.get("lng") is not None
    )
    output.write_text(json.dumps(rows, separators=(",", ":"), ensure_ascii=False) + "\n")
    print(f"wrote {output}: {len(rows)} stations, {output.stat().st_size / 1024:.0f} KB", file=sys.stderr)


if __name__ == "__main__":
    main()
