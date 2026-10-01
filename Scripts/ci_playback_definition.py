"""The workflow definition that establishes a tested playback candidate's provenance."""

import re


def producer_definition(workflow):
    text = workflow.decode("utf-8")
    # Consumer verification and cache publication are independent of engine publication. Retain the
    # triggers, permissions, source policies, engine toolchain, and every producer step through its successful upload verbatim.
    boundaries = ("  macos_verify:\n", "        id: engine_checkout\n", "      - name: Upload candidate playback artifact\n",
                  "      - name: Require engine results\n")
    positions = []
    for marker in boundaries:
        if text.count(marker) != 1:
            raise ValueError("Unrecognized CI producer boundary; update the definition policy")
        positions.append(text.index(marker))
    if positions != sorted(positions):
        raise ValueError("CI producer steps must precede the engine result gate")
    upload = text[positions[2]:positions[3]]
    if upload.count("      - name:") != 1:
        raise ValueError("Unexpected step between candidate upload and engine result gate")
    producer = text[:positions[3]]
    # These six outputs belong to later Swift phases, not candidate production. The workflow
    # policy separately binds and whitelists them; their changes must not invalidate an engine.
    producer = re.sub(r"(?m)^      (?:contracts_result|swift_result|release_result|contracts_key|tests_key|release_key):[^\n]*\n", "", producer)
    # Linux image selection cannot change the macOS-produced archive. Keep the source-policy
    # commands and their trust boundary; only normalize this runner label.
    return re.sub(r"(?m)^    runs-on: ubuntu-(?:latest|[0-9]+\.[0-9]+)$",
                  "    runs-on: ubuntu", producer).encode("utf-8")
