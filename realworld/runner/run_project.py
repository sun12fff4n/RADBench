#!/usr/bin/env python3
"""Run benchmark stages against prepared project clones.

Single stages:

    prepare  — clone + checkout + overlay
    compile  — prepare if needed, then Maven compile
    junit    — prepare if needed, then JUnit tests
    start    — prepare if needed, then lifecycle.up + readiness wait
    smoke    — prepare if needed, then lifecycle.smoke only
    stop     — lifecycle.down + optional post_down for an existing clone

Pipeline mode:

    --until compile  runs prepare -> compile
    --until junit    runs prepare -> compile -> junit
    --until start    runs prepare -> compile -> junit -> start
    --until smoke    runs prepare -> compile -> junit -> start -> smoke
    --until stop     runs prepare -> compile -> junit -> start -> smoke -> stop
"""
import sys
import time
from pathlib import Path

if __package__ is None or __package__ == "":
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from realworld.runner.utils.common import (
    build_arg_parser,
    load_runner_config,
    prepare_project,
    result,
    run_cmd,
    run_records,
    run_stage_command,
    wait_for_urls,
    write_stage_log,
)


STAGES = ["prepare", "compile", "junit", "start", "smoke", "stop"]
PIPELINE = ["prepare", "compile", "junit", "start", "smoke", "stop"]


def run_prepare(rec, repo_root, workdir, fresh=False):
    project_id = rec["project_id"]
    clone_dir, _config, early_result = prepare_project(rec, repo_root, workdir, fresh=fresh)
    if early_result:
        return early_result
    return result(project_id, "OK", clone_dir=str(clone_dir))


def run_compile(rec, repo_root, workdir, fresh=False):
    return run_stage_command(rec, repo_root, workdir, "compile", "COMPILE", fresh=fresh)


def run_junit(rec, repo_root, workdir, fresh=False):
    return run_stage_command(rec, repo_root, workdir, "junit", "JUNIT", fresh=fresh)


def run_start(rec, repo_root, workdir, fresh=False):
    project_id = rec["project_id"]
    clone_dir, config, early_result = prepare_project(rec, repo_root, workdir, fresh=fresh)
    if early_result:
        return early_result

    lifecycle = config["lifecycle"]
    print(f"  start: {_one_line(lifecycle['up'])}")
    t0 = time.time()
    rc, out = run_cmd(lifecycle["up"], cwd=clone_dir, timeout=900)
    write_stage_log(clone_dir, "start", out)
    boot_time = time.time() - t0
    if rc != 0:
        return result(project_id, "BOOT_FAIL",
                      boot_time=round(boot_time, 1),
                      stderr=out[-1500:])

    wait_urls = config["wait_urls"]
    if wait_urls:
        wait_timeout = config["wait_timeout"]
        print(f"  wait:  {len(wait_urls)} url(s) (timeout {wait_timeout}s)")
        ok = wait_for_urls(wait_urls, timeout=wait_timeout)
        if not ok:
            return result(project_id, "READY_TIMEOUT", boot_time=round(boot_time, 1))

    print(f"  OK ({round(boot_time)}s boot)")
    return result(project_id, "OK", boot_time=round(boot_time, 1))


def run_smoke(rec, repo_root, workdir, fresh=False):
    project_id = rec["project_id"]
    clone_dir, config, early_result = prepare_project(rec, repo_root, workdir, fresh=fresh)
    if early_result:
        return early_result

    lifecycle = config["lifecycle"]
    print(f"  smoke: {_one_line(lifecycle['smoke'])}")
    t0 = time.time()
    rc, out = run_cmd(lifecycle["smoke"], cwd=clone_dir, timeout=1200)
    write_stage_log(clone_dir, "smoke", out)
    smoke_time = time.time() - t0
    if rc != 0:
        return result(project_id, "SMOKE_FAIL",
                      smoke_time=round(smoke_time, 1),
                      stdout_tail=out[-2000:])

    print(f"  OK ({round(smoke_time)}s smoke)")
    return result(project_id, "OK",
                  smoke_time=round(smoke_time, 1),
                  stdout_tail=out[-500:])


def run_stop(rec, repo_root, workdir, fresh=False):
    project_id = rec["project_id"]
    clone_dir = workdir / project_id
    if not clone_dir.exists():
        return result(project_id, "NOT_PREPARED",
                      stderr=f"No prepared clone at {clone_dir}")

    runner_dir = repo_root / rec["runner_path"]
    lifecycle = load_runner_config(runner_dir)["lifecycle"]
    print(f"\n=== {project_id} ===")
    print(f"  stop:  {_one_line(lifecycle['down'])}")
    t0 = time.time()
    rc, out = run_cmd(lifecycle["down"], cwd=clone_dir, timeout=300)
    stop_time = time.time() - t0
    if lifecycle.get("post_down"):
        print("  post_down")
        _rc2, out2 = run_cmd(lifecycle["post_down"], cwd=clone_dir, timeout=300)
        out += out2
    write_stage_log(clone_dir, "stop", out)
    if rc != 0:
        return result(project_id, "DOWN_FAIL",
                      stop_time=round(stop_time, 1),
                      stderr=out[-1500:])

    print(f"  OK ({round(stop_time)}s stop)")
    return result(project_id, "OK", stop_time=round(stop_time, 1))


def run_until(until_stage):
    def runner(rec, repo_root, workdir, fresh=False):
        final = None
        started = False
        for stage in PIPELINE[:PIPELINE.index(until_stage) + 1]:
            final = RUNNERS[stage](rec, repo_root, workdir, fresh=(fresh and stage == "prepare"))
            if stage == "start" and final["status"] == "OK":
                started = True
            if final["status"] != "OK":
                if until_stage == "stop" and started:
                    run_stop(rec, repo_root, workdir, fresh=False)
                return final
        return final
    return runner


def _one_line(s):
    return " ; ".join(line.strip() for line in (s or "").strip().splitlines() if line.strip())


RUNNERS = {
    "prepare": run_prepare,
    "compile": run_compile,
    "junit": run_junit,
    "start": run_start,
    "smoke": run_smoke,
    "stop": run_stop,
}


def main(default_stage=None, default_until=None, legacy_results=False):
    parser = build_arg_parser(__doc__)
    if default_stage is None and default_until is None:
        group = parser.add_mutually_exclusive_group(required=True)
        group.add_argument("--stage", choices=STAGES,
                           help="Run only this stage; prepare is reused or created first except for stop")
        group.add_argument("--until", choices=STAGES,
                           help="Run the pipeline from prepare through this stage")
    args = parser.parse_args()

    stage = default_stage
    until = default_until
    if stage is None and until is None:
        stage = args.stage
        until = args.until

    if legacy_results and args.results is None:
        args.results = "results.json"

    if until:
        run_records(until, args, run_until(until))
    else:
        run_records(stage, args, RUNNERS[stage])


if __name__ == "__main__":
    main()
