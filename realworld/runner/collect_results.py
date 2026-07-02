#!/usr/bin/env python3
"""Print a compact status summary for one or more stage result JSON files."""
import argparse
import json
from collections import Counter


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", nargs="+")
    args = parser.parse_args()

    for path in args.results:
        data = json.load(open(path))
        counts = Counter(r["status"] for r in data)
        print(path)
        for status, count in sorted(counts.items()):
            print(f"  {status:18s} {count}")


if __name__ == "__main__":
    main()
