"""Require the macOS 27 ARM64/Xcode 27.0 environment used for native acceptance."""

import json
import re
import subprocess


def validate(os_version, architecture, xcode_version, sdk_version):
    if not re.fullmatch(r"27\.[0-9]+(?:\.[0-9]+)?", os_version):
        raise ValueError("Native CI requires macOS 27")
    if architecture != "arm64":
        raise ValueError("Native CI requires Apple Silicon")
    if not re.fullmatch(r"Xcode 27\.0\nBuild version [A-Za-z0-9]+", xcode_version):
        raise ValueError("Native CI requires Xcode 27.0")
    if sdk_version != "27.0":
        raise ValueError("Native CI requires the macOS 27.0 SDK")


def main():
    def read(*arguments):
        return subprocess.check_output(arguments, text=True, timeout=30).strip()

    evidence = {
        "macOS": read("sw_vers", "-productVersion"),
        "macOSBuild": read("sw_vers", "-buildVersion"),
        "architecture": read("uname", "-m"),
        "xcode": read("xcodebuild", "-version"),
        "sdk": read("env", "-u", "SDKROOT", "xcrun", "--sdk", "macosx", "--show-sdk-version"),
    }
    print(json.dumps(evidence, sort_keys=True), flush=True)
    validate(evidence["macOS"], evidence["architecture"], evidence["xcode"], evidence["sdk"])


if __name__ == "__main__":
    main()
