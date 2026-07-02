#!/usr/bin/env python3
"""Prepare one project clone by applying its runner overlay, then stop."""
import argparse
import json
import sys
from pathlib import Path

if __package__ is None or __package__ == "":
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from realworld.runner.utils.common import load_records, prepare_project


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project_id")
    parser.add_argument("--manifest", action="append", default=None)
    parser.add_argument("--workdir", default="/tmp/runner-driver")
    parser.add_argument("--fresh", action="store_true")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    records = load_records(repo_root, args.manifest)
    rec = next((r for r in records if r["project_id"] == args.project_id), None)
    if rec is None:
        available = ", ".join(sorted(r["project_id"] for r in records))
        raise SystemExit(f"Unknown project_id: {args.project_id}\nAvailable: {available}")

    workdir = Path(args.workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    clone_dir, _config, early = prepare_project(rec, repo_root, workdir, fresh=args.fresh)
    if early:
        print(json.dumps(early, indent=2))
        raise SystemExit(1)
    print(clone_dir)


if __name__ == "__main__":
    main()
