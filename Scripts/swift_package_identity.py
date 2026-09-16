"""Read a module's compiler package identity from the selected SwiftPM build."""

import argparse
import json
from pathlib import Path


def package_identity(bin_path: Path, module: str = "SpottySessionRuntime") -> str:
    bin_path = bin_path.resolve()
    description = bin_path / "description.json"
    identities = []
    if description.is_file():
        commands = json.loads(description.read_text())["swiftCommands"]
        for command in commands.values():
            if command.get("moduleName") != module:
                continue
            arguments = command["otherArguments"]
            if "-package-name" not in arguments:
                identities.append(None)
            for index, argument in enumerate(arguments):
                if argument == "-package-name":
                    identities.append(arguments[index + 1] if index + 1 < len(arguments) else None)
    elif bin_path.parent.name == "Products":
        # Xcode SwiftPM places Products under <scratch>/out and its PIF at <scratch>.
        manifest = bin_path.parents[2] / "manifest.pif"
        for item in json.loads(manifest.read_text()):
            content = item.get("contents", {})
            if item.get("type") != "target" or content.get("name") != module:
                continue
            for configuration in content["buildConfigurations"]:
                if configuration["name"].lower() == bin_path.name.lower():
                    identities.append(configuration["buildSettings"].get("SWIFT_PACKAGE_NAME"))
    else:
        raise ValueError(f"No SwiftPM compiler metadata under {bin_path}")

    if not identities or any(not isinstance(value, str) or not value.strip() for value in identities):
        raise ValueError(f"Missing compiler package identity for {module}")
    if len(set(identities)) != 1:
        raise ValueError(f"Conflicting compiler package identities for {module}")
    return identities[0]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bin_path", type=Path)
    arguments = parser.parse_args()
    try:
        print(package_identity(arguments.bin_path))
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        parser.exit(1, f"Compiler package identity: {error}\n")
