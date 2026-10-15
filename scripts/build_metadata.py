"""Static macOS artifact checks. This module never launches the inspected app."""
import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path


def version_parts(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("Invalid SDK/OS version: " + repr(value))
    parts = [int(part) for part in value.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def validate_metadata(architecture, commands, expected_sdk):
    if architecture.strip() != "arm64":
        raise ValueError("Expected an arm64-only executable, got " + repr(architecture))
    blocks = re.findall(r"\bcmd LC_BUILD_VERSION\b(.*?)(?=\bLoad command\b|\Z)", commands, re.S)
    if len(blocks) != 1:
        raise ValueError("Expected exactly one LC_BUILD_VERSION")
    fields = {}
    for name in ("platform", "minos", "sdk"):
        match = re.search(r"^\s*" + name + r"\s+(\S+)\s*$", blocks[0], re.M)
        if match is None:
            raise ValueError("Missing Mach-O build field: " + name)
        fields[name] = match.group(1)
    if fields["platform"] not in ("MACOS", "1"):
        raise ValueError("Expected macOS platform, got " + fields["platform"])
    if version_parts(fields["minos"]) != version_parts("13.0"):
        raise ValueError("Expected deployment target 13.0, got " + fields["minos"])
    if version_parts(fields["sdk"]) != version_parts(expected_sdk):
        raise ValueError("SDK mismatch: binary declares " + fields["sdk"] + ", selected SDK is " + expected_sdk)
    return fields


def selected_sdk_version():
    helper = Path(__file__).resolve().with_name("macos-toolchain.sh")
    return subprocess.check_output(["/bin/zsh", "-ec",
        'source "$1"; print -r -- "$NOW_SDK_VERSION"', "zsh", str(helper)], text=True).strip()


def check_binary(executable, expected_sdk):
    architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", str(executable)], text=True)
    commands = subprocess.check_output(["/usr/bin/vtool", "-show-build", str(executable)], text=True)
    return validate_metadata(architecture, commands, expected_sdk)


def record_provenance(executable, fields, destination):
    compiler = os.environ.get("NOW_SWIFTC")
    backend = os.environ.get("NOW_SWIFTPM_BACKEND")
    if not compiler or not backend:
        raise ValueError("Provenance recording requires the build script's selected toolchain")
    root = Path(__file__).resolve().parent.parent
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True)
    status = subprocess.run(["git", "status", "--porcelain"], cwd=root, capture_output=True, text=True)
    record = {
        "xcode": subprocess.check_output(["/usr/bin/xcodebuild", "-version"], text=True).strip(),
        "compiler": subprocess.check_output([compiler, "--version"], text=True).strip(),
        "backend": backend, "swiftLanguageMode": "5", "architecture": "arm64",
        "buildVersion": fields,
        # Source archives can be built without a .git directory; unknown is not clean.
        "sourceRevision": revision.stdout.strip() if revision.returncode == 0 else None,
        "workingTreeDirty": bool(status.stdout.strip()) if status.returncode == 0 else None,
        "packageResolvedSHA256": hashlib.sha256((root / "Package.resolved").read_bytes()).hexdigest(),
        "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
    }
    destination.write_text(json.dumps(record, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("--sdk")
    parser.add_argument("--record", type=Path)
    args = parser.parse_args()
    try:
        fields = check_binary(args.executable, args.sdk or selected_sdk_version())
        if args.record:
            record_provenance(args.executable, fields, args.record)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, "Build metadata check failed: " + str(error) + "\n")
    print("PASS: arm64 / macOS " + fields["minos"] + " / SDK " + fields["sdk"])


if __name__ == "__main__":
    main()
