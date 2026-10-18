#!/usr/bin/env python3
"""Converts an Xcode result bundle (.xcresult) into Allure result files.

    xcresult-to-allure.py <bundle.xcresult> <allure-results-dir>

The Allure CLI's own xctest plugin reads the legacy result format and finds no tests in a bundle written by
current Xcode, so this reads the supported `xcresulttool get test-results` / `export attachments` output instead.
It covers Swift Testing and XCTest alike: one Allure result per test case, one per argument of a parameterized
Swift Testing test. Snapshot failures keep the reference / failure / difference images that swift-snapshot-testing
attaches to the bundle, named expected / actual / diff so the report's screen-diff view picks them up.

Standard library only; `xcrun` must be on the PATH.
"""
import hashlib
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

STATUS = {
    "Passed": "passed",
    "Failed": "failed",
    "Skipped": "skipped",
    "Expected Failure": "passed",
}

# What swift-snapshot-testing calls its attachments -> the names the Allure screen-diff view looks for.
SNAPSHOT_NAMES = {"reference": "expected", "failure": "actual", "difference": "diff"}

UUID_SUFFIX = re.compile(r"_[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")


def xcresulttool(*args):
    return subprocess.run(["xcrun", "xcresulttool", *args], check=True, capture_output=True, text=True).stdout


def attachment_name(human_readable):
    """`difference_0_<UUID>.png` -> `diff`; `Screenshot_<UUID>.png` -> `Screenshot`."""
    stem = os.path.splitext(human_readable)[0]
    stem = UUID_SUFFIX.sub("", stem)
    match = re.fullmatch(r"(.+?)_(\d+)", stem)
    base, index = (match.group(1), match.group(2)) if match else (stem, "0")
    name = SNAPSHOT_NAMES.get(base, base)
    return name if index == "0" else f"{name} #{index}"


def collect_failures(node):
    """Failure and skip messages directly under `node`: (message, "file:line")."""
    found = []
    for child in node.get("children", []):
        if child.get("nodeType") in ("Failure Message", "Skip Message"):
            location = child.get("sourceLocation") or {}
            where = f"{location['filePath']}:{location.get('lineNumber', '')}" if "filePath" in location else ""
            found.append((child.get("name", ""), where))
    return found


def attachment_groups(attachments):
    """Splits a test's attachments into one group per issue.

    Every issue exports its images followed by a `Complete Issue Description.txt`, which is the failure message
    verbatim. Returns [(description_text, [files])].
    """
    groups, current = [], []
    for item in attachments:
        if item["file"].endswith(".txt") and item["failure"]:
            groups.append((open(item["file"], encoding="utf-8").read().strip(), current))
            current = []
        else:
            current.append(item)
    if current:
        groups.append((None, current))
    return groups


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    bundle, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    tests = json.loads(xcresulttool("get", "test-results", "tests", "--path", bundle))
    export_dir = tempfile.mkdtemp(prefix="xcresult-attachments-")
    try:
        xcresulttool("export", "attachments", "--path", bundle, "--output-path", export_dir)
        manifest_path = os.path.join(export_dir, "manifest.json")
        manifest = json.load(open(manifest_path)) if os.path.exists(manifest_path) else []
        attachments = {}
        for entry in manifest:
            attachments[entry["testIdentifier"]] = [
                {
                    "file": os.path.join(export_dir, a["exportedFileName"]),
                    "name": a["suggestedHumanReadableName"],
                    "failure": a.get("isAssociatedWithFailure", False),
                }
                for a in entry["attachments"]
            ]

        cases = []  # (bundle, suites, test case node)

        def walk(node, bundle_name, suites):
            kind = node.get("nodeType")
            if kind == "Unit test bundle" or kind == "UI test bundle":
                bundle_name = node["name"]
            elif kind == "Test Suite":
                suites = suites + [node["name"]]
            elif kind == "Test Case":
                cases.append((bundle_name, suites, node))
                return
            for child in node.get("children", []):
                walk(child, bundle_name, suites)

        for root in tests.get("testNodes", []):
            walk(root, "", [])

        total_ms = sum(int(node.get("durationInSeconds", 0) * 1000) for _, _, node in cases)
        clock = int(time.time() * 1000) - total_ms
        written = 0

        for bundle_name, suites, case in cases:
            identifier = case.get("nodeIdentifier", case["name"])
            arguments = [c for c in case.get("children", []) if c.get("nodeType") == "Arguments"]
            files = attachments.get(identifier, [])
            groups = attachment_groups(files) if arguments else None
            tags = case.get("tags", [])

            # A parameterized test is one case with an Arguments node per argument set.
            units = [(case, None, None)] if not arguments else [(a, a["name"], a) for a in arguments]
            for node, argument, argument_node in units:
                status = STATUS.get(node.get("result"), "broken")
                failures = collect_failures(node)
                if argument is None:
                    chosen = [i for i in files if not (i["file"].endswith(".txt") and i["failure"])]
                else:
                    messages = {m.strip() for m, _ in failures}
                    chosen = next((g for text, g in groups if text in messages), [])

                duration = int(node.get("durationInSeconds", 0) * 1000)
                full_name = f"{bundle_name}.{identifier}" + (f"[{argument}]" if argument else "")
                result_id = str(uuid.uuid4())
                images = {attachment_name(i["name"]) for i in chosen}
                labels = [
                    {"name": "language", "value": "swift"},
                    {"name": "parentSuite", "value": bundle_name},
                ]
                if suites:
                    labels.append({"name": "suite", "value": suites[0]})
                if len(suites) > 1:
                    labels.append({"name": "subSuite", "value": " / ".join(suites[1:])})
                labels += [{"name": "tag", "value": t} for t in tags]
                if {"expected", "actual", "diff"} <= images:
                    labels.append({"name": "testType", "value": "screenshotDiff"})

                result_attachments = []
                for item in chosen:
                    extension = os.path.splitext(item["file"])[1]
                    source = f"{uuid.uuid4()}-attachment{extension}"
                    shutil.copyfile(item["file"], os.path.join(out_dir, source))
                    kind = mimetypes.guess_type(item["file"])[0] or "application/octet-stream"
                    result_attachments.append({"name": attachment_name(item["name"]), "source": source, "type": kind})

                result = {
                    "uuid": result_id,
                    "historyId": hashlib.md5(full_name.encode()).hexdigest(),
                    "testCaseId": hashlib.md5(f"{bundle_name}.{identifier}".encode()).hexdigest(),
                    "fullName": full_name,
                    "name": case["name"] + (f" ({argument})" if argument else ""),
                    "status": status,
                    "stage": "finished",
                    "start": clock,
                    "stop": clock + duration,
                    "labels": labels,
                    "attachments": result_attachments,
                    "parameters": [{"name": "argument", "value": argument}] if argument else [],
                }
                if failures:
                    result["statusDetails"] = {
                        "message": "\n\n".join(dict.fromkeys(m for m, _ in failures))[:8000],
                        "trace": "\n".join(w for _, w in failures if w),
                    }
                clock += duration
                with open(os.path.join(out_dir, f"{result_id}-result.json"), "w") as handle:
                    json.dump(result, handle)
                written += 1

        device = (tests.get("devices") or [{}])[0]
        with open(os.path.join(out_dir, "environment.properties"), "w") as handle:
            handle.write(
                f"platform={device.get('platform', 'iOS Simulator')}\n"
                f"device={device.get('deviceName', '')}\n"
                f"os={device.get('osVersion', '')}\n"
            )
        print(f"Allure: {written} results from {os.path.basename(bundle)} in {out_dir}/")
    finally:
        shutil.rmtree(export_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
