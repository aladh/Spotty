#!/usr/bin/env python3
"""Summarize four local xctrace XML exports without retaining process or host metadata."""
import argparse
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET


def read_table(path):
    root = ET.parse(path).getroot()
    identifiers = {element.attrib["id"]: element for element in root.iter() if "id" in element.attrib}

    def value(element):
        while "ref" in element.attrib:
            element = identifiers[element.attrib["ref"]]
        return element.text or element.attrib.get("fmt", "")

    schema = next(root.iter("schema"), None)
    if schema is None:
        raise ValueError(f"Missing exported table schema: {path.name}")
    columns = [column.findtext("mnemonic") for column in schema.findall("col")]
    return [dict(zip(columns, map(value, row), strict=True)) for row in root.iter("row")]


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return {"count": 0}
    return {
        "count": len(ordered), "minimum": ordered[0],
        **{name: ordered[math.floor((len(ordered) - 1) * fraction)]
           for name, fraction in (("p50", .5), ("p95", .95), ("p99", .99))},
        "maximum": ordered[-1],
    }


def summarize(prefix):
    def table(suffix):
        return read_table(Path(f"{prefix}-{suffix}.xml"))

    signs = table("signposts")
    markers = [row for row in signs if row["name"] == "Demo workload"
               and row["process"].startswith("SpottyDemo (")]
    begins = [row for row in markers if row["event-type"] == "Begin"]
    ends = [row for row in markers if row["event-type"] == "End"]
    if len(begins) != 1 or len(ends) != 1:
        raise ValueError("Expected exactly one complete Demo workload interval")
    begin, end_marker = begins[0], ends[0]
    if any(begin[key] != end_marker[key] for key in ("identifier", "process")):
        raise ValueError("Workload interval endpoints do not match")
    start, end = int(begin["time"]), int(end_marker["time"])
    if end <= start:
        raise ValueError("Workload interval must have positive duration")
    process = begin["process"]

    def frame_key(row):
        return row["display"], row["swap-id"]

    # Frame Lifetimes has no process column; join it to the app's update records.
    app_keys = {frame_key(row) for row in table("hitches-updates") if row["process"] == process}
    overlapping = [row for row in table("hitches-frame-lifetimes")
                   if frame_key(row) in app_keys and int(row["start"]) < end
                   and int(row["start"]) + int(row["duration"]) > start]
    frames = [row for row in overlapping if int(row["start"]) >= start
              and int(row["start"]) + int(row["duration"]) <= end]
    keys = {frame_key(row) for row in frames}
    if not frames or len(keys) != len(frames):
        raise ValueError("Expected nonempty, uniquely identified complete app frames")
    hitches = [row for row in table("hitches")
               if row["process"] == process and frame_key(row) in keys]
    hitch_keys = {frame_key(row) for row in hitches}
    batches = sorted(int(row["time"]) for row in signs
                     if row["process"] == process and row["name"] == "Queue metadata batch"
                     and row["event-type"] == "Event" and start <= int(row["time"]) < end)
    # Half-open rolling windows avoid counting an event at both one-second boundaries.
    maximum_per_second = max((sum(t <= value < t + 1_000_000_000 for value in batches)
                              for t in batches), default=0)
    return {
        "workloadSeconds": (end - start) / 1e9,
        "completeApplicationFrames": len(frames),
        "boundaryCrossingFramesExcluded": len(overlapping) - len(frames),
        "completeFrameLifetimesMilliseconds": distribution([int(row["duration"]) / 1e6 for row in frames]),
        "framesWithHitches": len(hitch_keys),
        "hitchFreeFramePercent": 100 * (len(keys) - len(hitch_keys)) / len(keys),
        "hitchDurationMilliseconds": distribution([int(row["duration"]) / 1e6 for row in hitches]),
        "metadataBatches": len(batches),
        "maximumMetadataBatchesInRollingSecond": maximum_per_second,
        "metadataBatchGapMilliseconds": distribution([(v - u) / 1e6 for u, v in zip(batches, batches[1:])]),
        "metadataBatchOffsetsMilliseconds": [(value - start) / 1e6 for value in batches],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix", help="Prefix of -signposts, -hitches, -hitches-updates and -hitches-frame-lifetimes XML files")
    arguments = parser.parse_args()
    print(json.dumps(summarize(arguments.prefix), indent=2))
