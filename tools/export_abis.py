#!/usr/bin/env python3
"""Export, or check, the two launch ABIs using the locally pinned Foundry build."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if a committed ABI differs")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    failed = False
    for name in ("LaunchToken", "TestStaking"):
        result = subprocess.run(
            ["forge", "inspect", f"src/{name}.sol:{name}", "abi", "--json"],
            cwd=root,
            check=True,
            text=True,
            capture_output=True,
        )
        abi = json.loads(result.stdout)
        if not isinstance(abi, list):
            raise ValueError(f"Expected an ABI array for {name}")
        output = json.dumps(abi, indent=2) + "\n"
        path = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not path.exists() or path.read_text() != output:
                print(f"ABI mismatch: docs/abi/{name}.json", file=sys.stderr)
                failed = True
            else:
                print(f"ABI matches: {name}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(output)
            print(f"Exported docs/abi/{name}.json")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
