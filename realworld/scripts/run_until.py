#!/usr/bin/env python3
"""Run the benchmark pipeline until a cutoff stage."""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from realworld.runner.run_project import main


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("until", choices=["prepare", "compile", "junit", "start", "smoke", "stop"])
    args, rest = parser.parse_known_args()
    sys.argv = [sys.argv[0], *rest]
    main(default_until=args.until)
