#!/usr/bin/env python3
"""Converts an .xcresult into Allure result files (the format Flutter's run writes to allure-results/).

usage: xcresult-to-allure.py <bundle.xcresult> <allure-results-dir>

Standard library only. Needs Xcode's `xcrun xcresulttool` (Xcode 16+).
"""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import uuid

STATUS = {"Passed": "passed", "Failed": "failed", "Skipped": "skipped", "Expected Failure": "passed"}


def xcresulttool(*args):
    return subprocess.run(["xcrun", "xcresulttool", *args], check=True, capture_output=True, text=True).stdout


def walk(node, path):
    """Yields (suite path, test case node) for every test case below node."""
    kind = node.get("nodeType")
    if kind == "Test Case":
        arguments = [c for c in node.get("children", []) if c.get("nodeType") == "Arguments"]
        if not arguments:
            yield path, node
            return
        # A parameterized test: one result per argument, named after it.
        for argument in arguments:
            yield path, {**argument, "name": f"{node['name']}: {argument['name']}",
                         "nodeIdentifier": node.get("nodeIdentifier", node["name"]), "argument": argument["name"]}
        return
    if kind in ("Unit test bundle", "Test Suite"):
        path = path + [node["name"]]
    for child in node.get("children", []):
        yield from walk(child, path)


def failures(node):
    for child in node.get("children", []):
        if child.get("nodeType") == "Failure Message":
            yield child["name"]
        yield from failures(child)


def export_attachments(bundle, out):
    """test identifier -> [(name, file)] for the attachments of every test case."""
    xcresulttool_out = pathlib.Path(out)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", str(xcresulttool_out)],
                   check=True, capture_output=True)
    manifest = xcresulttool_out / "manifest.json"
    found = {}
    if manifest.exists():
        for test in json.loads(manifest.read_text()):
            for att in test.get("attachments", []):
                found.setdefault(test.get("testIdentifier", ""), []).append(
                    (att.get("suggestedHumanReadableName") or att["exportedFileName"], xcresult_file(xcresulttool_out, att["exportedFileName"])))
    return found


def xcresult_file(root, name):
    return root / name


def main(bundle, results):
    results = pathlib.Path(results)
    results.mkdir(parents=True, exist_ok=True)
    tests = json.loads(xcresulttool("get", "test-results", "tests", "--path", bundle))
    with tempfile.TemporaryDirectory() as tmp:
        attachments = export_attachments(bundle, tmp)
        count = 0
        for root in tests.get("testNodes", []):
            for path, case in walk(root, []):
                identifier = case.get("nodeIdentifier", case["name"])
                status = STATUS.get(case.get("result"), "unknown")
                duration = int(case.get("durationInSeconds", 0) * 1000)
                result = {
                    "uuid": str(uuid.uuid4()),
                    "historyId": hashlib.md5((identifier + case["name"]).encode()).hexdigest(),
                    "fullName": "/".join(path + [identifier]),
                    "name": case["name"],
                    "status": status,
                    "stage": "finished",
                    "start": 0,
                    "stop": duration,
                    "labels": [
                        {"name": "language", "value": "swift"},
                        {"name": "parentSuite", "value": path[0] if path else ""},
                        {"name": "suite", "value": path[-1] if path else ""},
                    ],
                    "attachments": [],
                }
                if status == "failed":
                    messages = list(failures(case))
                    result["statusDetails"] = {"message": messages[0] if messages else "failed", "trace": "\n".join(messages)}
                argument = case.get("argument")
                for name, file in attachments.get(identifier, []):
                    # A parameterized test's attachments are named after the argument they belong to.
                    if argument and not name.startswith(argument):
                        continue
                    target = results / f"{uuid.uuid4()}-attachment{pathlib.Path(file).suffix}"
                    target.write_bytes(pathlib.Path(file).read_bytes())
                    result["attachments"].append({"name": name, "source": target.name, "type": "image/png"})
                (results / f"{result['uuid']}-result.json").write_text(json.dumps(result))
                count += 1
    print(f"Allure: wrote {count} results to {results}/")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
