"""The workflow definition that establishes a tested playback candidate's provenance."""

import re


def producer_definition(workflow):
    text = workflow.decode("utf-8")
    # The trailing app consumer and required aggregate are irrelevant to engine publication.
    # Retain the triggers, permissions, source policies, Rust verification job, candidate job,
    # macOS toolchain, and every producer step verbatim.
    boundaries = ("  rust_macos:\n", "  playback_candidate:\n",
                  "      - name: Upload candidate playback artifact\n", "  app_macos:\n")
    positions = []
    for marker in boundaries:
        if text.count(marker) != 1:
            raise ValueError("Unrecognized CI producer boundary; update the definition policy")
        positions.append(text.index(marker))
    if positions != sorted(positions):
        raise ValueError("CI producer steps must precede the Swift consumer phase")
    upload = text[positions[2]:positions[3]]
    if upload.count("      - name:") != 1:
        raise ValueError("Unexpected step between candidate upload and Swift setup")
    producer = text[:positions[3]]
    # Linux image selection cannot change the macOS-produced archive. Keep the source-policy
    # commands and their trust boundary; only normalize this runner label.
    return re.sub(r"(?m)^    runs-on: ubuntu-(?:latest|[0-9]+\.[0-9]+)$",
                  "    runs-on: ubuntu", producer).encode("utf-8")
