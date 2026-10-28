"""Merges LCOV files line by line: a line's hit count is the sum across inputs.

Usage: python3 -I merge-lcov.py <out> <in>...

`run-tests.sh` exports one LCOV file per test run (the package bundle and the sample-app-hosted
bundle) over the same Sources/; this writes the one report both make together.
"""
import sys
from collections import OrderedDict


def read(path, files):
    current = None
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if line.startswith("SF:"):
                current = files.setdefault(line[3:], OrderedDict())
            elif line.startswith("DA:") and current is not None:
                number, hits = line[3:].split(",")[:2]
                current[int(number)] = current.get(int(number), 0) + int(hits)
            elif line == "end_of_record":
                current = None


def main():
    out, inputs = sys.argv[1], sys.argv[2:]
    files = OrderedDict()
    for path in inputs:
        read(path, files)
    total = covered = 0
    with open(out, "w") as f:
        for source in sorted(files):
            lines = files[source]
            f.write("SF:%s\n" % source)
            for number in sorted(lines):
                f.write("DA:%d,%d\n" % (number, lines[number]))
            hit = sum(1 for h in lines.values() if h > 0)
            f.write("LF:%d\nLH:%d\nend_of_record\n" % (len(lines), hit))
            total += len(lines)
            covered += hit
    pct = 100.0 * covered / total if total else 0
    print(" Line coverage: %d of %d lines (%.2f%%)" % (covered, total, pct))


if __name__ == "__main__":
    main()
