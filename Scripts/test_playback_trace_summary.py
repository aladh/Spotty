"""Checks for workload, process and frame filtering in local Instruments summaries."""
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import xml.etree.ElementTree as ET

from summarize_synthetic_trace import summarize


def write_table(prefix, suffix, columns, rows):
    root = ET.Element("trace-query-result")
    schema = ET.SubElement(root, "schema")
    for name in columns:
        ET.SubElement(ET.SubElement(schema, "col"), "mnemonic").text = name
    identifiers = {}
    for values in rows:
        row = ET.SubElement(root, "row")
        for value in map(str, values):
            if value in identifiers:
                ET.SubElement(row, "value", ref=identifiers[value])
            else:
                identifier = str(len(identifiers) + 1)
                identifiers[value] = identifier
                ET.SubElement(row, "value", id=identifier).text = value
    ET.ElementTree(root).write(f"{prefix}-{suffix}.xml")


class TraceSummaryTests(unittest.TestCase):
    def test_filters_other_processes_and_censored_frames_and_resolves_references(self):
        with TemporaryDirectory() as directory:
            prefix = Path(directory) / "trace"
            app = "SpottyDemo (7)"
            write_table(prefix, "signposts", ["time", "process", "event-type", "identifier", "name"], [
                [1_000_000_000, app, "Begin", "work", "Demo workload"],
                [1_100_000_000, app, "Event", "batch", "Queue metadata batch"],
                [1_200_000_000, app, "Event", "batch", "Queue metadata batch"],
                [2_100_000_000, app, "Event", "batch", "Queue metadata batch"],
                [2_200_000_000, "Other (8)", "Event", "batch", "Queue metadata batch"],
                [3_000_000_000, app, "End", "work", "Demo workload"],
            ])
            write_table(prefix, "hitches-updates", ["process", "display", "swap-id"], [
                [app, "display", "a"], [app, "display", "b"], ["Other (8)", "display", "c"],
            ])
            write_table(prefix, "hitches-frame-lifetimes", ["start", "duration", "display", "swap-id"], [
                [1_100_000_000, 200_000_000, "display", "a"],
                [2_950_000_000, 100_000_000, "display", "b"],
                [1_300_000_000, 100_000_000, "display", "c"],
            ])
            write_table(prefix, "hitches", ["process", "display", "swap-id", "duration"], [
                [app, "display", "a", 8_000_000], [app, "display", "b", 90_000_000],
                ["Other (8)", "display", "c", 80_000_000],
            ])
            result = summarize(prefix)
            self.assertEqual(result["completeApplicationFrames"], 1)
            self.assertEqual(result["boundaryCrossingFramesExcluded"], 1)
            self.assertEqual(result["hitchDurationMilliseconds"]["maximum"], 8)
            self.assertEqual(result["hitchFreeFramePercent"], 0)
            self.assertEqual(result["metadataBatches"], 3)
            self.assertEqual(result["maximumMetadataBatchesInRollingSecond"], 2)

    def test_missing_workload_interval_cannot_be_reported_as_success(self):
        with TemporaryDirectory() as directory:
            prefix = Path(directory) / "trace"
            write_table(prefix, "signposts", ["time", "process", "event-type", "identifier", "name"], [])
            with self.assertRaisesRegex(ValueError, "complete Demo workload"):
                summarize(prefix)
