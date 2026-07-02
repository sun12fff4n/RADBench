#!/usr/bin/env python3
"""Backward-compatible wrapper for the old boot + smoke + down flow."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from realworld.runner.run_project import run_smoke, run_start, run_stop
from realworld.runner.utils.common import build_arg_parser, run_records


def run_legacy_smoke(rec, repo_root, workdir, fresh=False):
    outcome = run_start(rec, repo_root, workdir, fresh=fresh)
    if outcome["status"] != "OK":
        return outcome
    try:
        outcome = run_smoke(rec, repo_root, workdir, fresh=False)
        return outcome
    finally:
        run_stop(rec, repo_root, workdir, fresh=False)


def main():
    args = build_arg_parser(__doc__).parse_args()
    if args.results is None:
        args.results = "results.json"
    run_records("smoke", args, run_legacy_smoke)


if __name__ == "__main__":
    main()
