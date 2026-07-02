#!/usr/bin/env python3
"""Shared helpers for the real-world benchmark stage drivers."""
import argparse
import json
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required. Install with:", file=sys.stderr)
    print("  python3 -m pip install --break-system-packages pyyaml", file=sys.stderr)
    sys.exit(1)


DEFAULT_MANIFESTS = [
    "springboot_app_single_module.json",
]

DEFAULT_LIFECYCLE = {
    "up": "docker compose up -d --wait",
    "smoke": "bash test_api.sh",
    "down": "docker compose down -v",
    "post_down": None,
}

DEFAULT_STAGES = {
    "compile": "mvn -B -DskipTests compile",
    "junit": "mvn -B test",
}


def build_arg_parser(description):
    p = argparse.ArgumentParser(description=description, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--manifest", action="append", default=None,
                   help=f"JSON manifest path (repeatable). Default: {' + '.join(DEFAULT_MANIFESTS)}")
    p.add_argument("--workdir", default="/tmp/runner-driver")
    p.add_argument("--results", default=None,
                   help="Results JSON path. Defaults to the stage-specific results file")
    p.add_argument("--filter", default=None, help="Substring match on project_id")
    p.add_argument("--module-type", choices=["single", "multi"], default=None,
                   help="Restrict to a Maven layout group")
    p.add_argument("--fresh", action="store_true",
                   help="Delete an existing prepared clone before running")
    p.add_argument("--keep", action="store_true",
                   help="Deprecated compatibility flag; prepared clones are kept by default")
    return p


def load_records(repo_root, manifest_args):
    records = []
    manifests = manifest_args if manifest_args else DEFAULT_MANIFESTS
    for m in manifests:
        with open(resolve_manifest(repo_root, m)) as f:
            records.extend(json.load(f))
    return records


def resolve_manifest(root, manifest_arg):
    p = Path(manifest_arg)
    if p.is_absolute():
        return p
    project_path = root / "realworld" / "projects" / p
    return project_path if project_path.exists() else root / p


def selected_records(records, args):
    for rec in records:
        project_id = rec["project_id"]
        if args.filter and args.filter not in project_id:
            continue
        if args.module_type and rec.get("module_type") != args.module_type:
            continue
        yield rec


def run_records(stage, args, runner):
    repo_root = Path(__file__).resolve().parents[3]
    workdir = Path(args.workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    results_path = args.results or f"results_{stage}.json"

    results = []
    records = load_records(repo_root, args.manifest)
    for rec in selected_records(records, args):
        project_id = rec["project_id"]
        if not rec.get("runner_path"):
            results.append(result(project_id, "SKIP_NO_RUNNER"))
            write_results(results_path, results)
            continue

        results.append(runner(rec, repo_root, workdir, fresh=args.fresh))
        write_results(results_path, results)

    print_summary(results)


def prepare_project(rec, repo_root, workdir, fresh=False):
    project_id = rec["project_id"]
    runner_path = rec["runner_path"]
    github_url = rec["github_url"]
    commit = rec["commit_hash"]

    print(f"\n=== {project_id} ===")
    runner_dir = repo_root / runner_path
    overlay_dir, overlay_ignore = overlay_for(runner_dir)
    config = load_runner_config(runner_dir)

    clone_dir = workdir / project_id
    if clone_dir.exists() and fresh:
        shutil.rmtree(clone_dir)

    prepared = False
    if clone_dir.exists():
        rc, out = run_cmd("git rev-parse HEAD", cwd=clone_dir, timeout=30)
        current = out.strip().splitlines()[-1] if out.strip() else ""
        if rc != 0:
            return clone_dir, config, result(project_id, "PREPARE_FAIL",
                                            stderr=f"Existing workdir is not a git clone: {clone_dir}")
        if current != commit:
            return clone_dir, config, result(
                project_id,
                "STALE_CLONE",
                stderr=f"{clone_dir} is at {current[:8]}, expected {commit[:8]}. Re-run with --fresh.",
            )
        print(f"  reuse clone {clone_dir} @ {commit[:8]}")
        prepared = is_prepared(clone_dir, rec)
    else:
        print(f"  clone {github_url} @ {commit[:8]}")
        rc, out = run_cmd(f"git clone --quiet {github_url} {clone_dir}", cwd=workdir, timeout=300)
        if rc != 0:
            return None, config, result(project_id, "CLONE_FAIL", stderr=out[-500:])

        rc, out = run_cmd(f"git checkout --quiet {commit}", cwd=clone_dir, timeout=60)
        if rc != 0:
            return clone_dir, config, result(project_id, "CHECKOUT_FAIL", stderr=out[-500:])

    overlay_label = overlay_dir.relative_to(repo_root)
    if prepared:
        print(f"  reuse overlay ({overlay_label}/)")
        return clone_dir, config, None

    print(f"  sync overlay  ({overlay_label}/)")
    try:
        shutil.copytree(overlay_dir, clone_dir, dirs_exist_ok=True, ignore=overlay_ignore)
        write_prepare_marker(clone_dir, rec, overlay_label)
    except Exception as e:
        return clone_dir, config, result(project_id, "OVERLAY_FAIL", stderr=str(e)[-500:])

    return clone_dir, config, None


def is_prepared(clone_dir, rec):
    marker_path = clone_dir / ".runner-driver-prepared.json"
    if not marker_path.exists():
        return False
    try:
        marker = json.load(marker_path.open())
    except Exception:
        return False
    return (
        marker.get("project_id") == rec["project_id"]
        and marker.get("commit_hash") == rec["commit_hash"]
        and marker.get("runner_path") == rec["runner_path"]
    )


def overlay_for(runner_dir):
    overlay_subdir = runner_dir / "overlay"
    overlay_dir = overlay_subdir if overlay_subdir.is_dir() else runner_dir
    overlay_ignore = (
        shutil.ignore_patterns("runner.yaml", "README.md", ".DS_Store")
        if overlay_dir is runner_dir else None
    )
    return overlay_dir, overlay_ignore


def load_runner_config(runner_dir):
    lifecycle = dict(DEFAULT_LIFECYCLE)
    stages = dict(DEFAULT_STAGES)
    wait_urls = []
    wait_timeout = 240

    runner_yaml = runner_dir / "runner.yaml"
    if runner_yaml.exists():
        with open(runner_yaml) as f:
            cfg = yaml.safe_load(f) or {}
        lifecycle.update(cfg.get("lifecycle", {}))
        stages.update(cfg.get("stages", {}))
        # Backward/forward friendly: allow stage commands under lifecycle too.
        for name in DEFAULT_STAGES:
            if name in lifecycle:
                stages[name] = lifecycle[name]
        wait = cfg.get("wait", {}) or {}
        wait_urls = wait.get("urls", [])
        wait_timeout = wait.get("timeout_seconds", 240)

    return {
        "lifecycle": lifecycle,
        "stages": stages,
        "wait_urls": wait_urls,
        "wait_timeout": wait_timeout,
    }


def write_prepare_marker(clone_dir, rec, overlay_label):
    marker = {
        "project_id": rec["project_id"],
        "commit_hash": rec["commit_hash"],
        "runner_path": rec["runner_path"],
        "overlay": str(overlay_label),
        "prepared_at": int(time.time()),
    }
    with open(clone_dir / ".runner-driver-prepared.json", "w") as f:
        json.dump(marker, f, indent=2)


def run_stage_command(rec, repo_root, workdir, stage, status_prefix, fresh=False):
    project_id = rec["project_id"]
    clone_dir, config, early_result = prepare_project(rec, repo_root, workdir, fresh=fresh)
    if early_result:
        return early_result

    cmd = stage_command(rec, clone_dir, config, stage)
    elapsed = 0
    print(f"  {stage}: {_one_line(cmd)}")
    t0 = time.time()
    rc, out = run_cmd(cmd, cwd=clone_dir, timeout=1200)
    write_stage_log(clone_dir, stage, out)
    elapsed = time.time() - t0
    if rc != 0:
        return result(project_id, f"{status_prefix}_FAIL",
                      **{f"{stage}_time": round(elapsed, 1)},
                      stdout_tail=out[-2000:])

    print(f"  OK ({round(elapsed)}s)")
    return result(project_id, "OK",
                  **{f"{stage}_time": round(elapsed, 1)},
                  stdout_tail=out[-500:])


def write_stage_log(clone_dir, stage, output):
    log_dir = clone_dir / ".runner-driver" / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    with open(log_dir / f"{stage}.log", "w") as f:
        f.write(output)


def stage_command(rec, clone_dir, config, stage):
    cmd = config["stages"][stage]
    if cmd == DEFAULT_STAGES[stage]:
        return docker_maven_cmd(rec, clone_dir, cmd)
    return cmd


def docker_maven_cmd(rec, clone_dir, maven_cmd):
    image = rec.get("docker_image")
    if not image:
        return maven_cmd
    project_dir = shlex.quote(str(clone_dir.resolve()))
    image_arg = shlex.quote(image)
    maven_args = " ".join(shlex.quote(part) for part in shlex.split(maven_cmd)[1:])
    return (
        "docker run --rm "
        f"-v {project_dir}:/workspace "
        "-w /workspace "
        "-v runner-driver-m2:/root/.m2 "
        f"{image_arg} mvn {maven_args}"
    )


def run_cmd(cmd, cwd, timeout):
    """Run a shell snippet via `bash -c`. Captures stdout+stderr together."""
    try:
        proc = subprocess.run(
            ["bash", "-c", cmd],
            cwd=str(cwd),
            timeout=timeout,
            capture_output=True,
            text=True,
        )
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except subprocess.TimeoutExpired as e:
        def decode(x):
            if x is None:
                return ""
            if isinstance(x, bytes):
                return x.decode(errors="replace")
            return x
        return 124, f"TIMEOUT after {timeout}s\n" + decode(e.stdout) + decode(e.stderr)


def wait_for_urls(urls, timeout):
    """Poll all URLs until each returns ANY HTTP response (4xx/5xx fine)."""
    start = time.time()
    not_ready = set(urls)
    while not_ready and (time.time() - start) < timeout:
        for url in list(not_ready):
            try:
                urlopen(Request(url), timeout=3)
                not_ready.discard(url)
            except HTTPError:
                not_ready.discard(url)
            except (URLError, TimeoutError, ConnectionError):
                pass
        if not_ready:
            time.sleep(5)
    return not not_ready


def result(project_id, status, **extra):
    out = {"project_id": project_id, "status": status}
    out.update(extra)
    return out


def _one_line(s):
    return " ; ".join(line.strip() for line in (s or "").strip().splitlines() if line.strip())


def write_results(path, results):
    with open(path, "w") as f:
        json.dump(results, f, indent=2)


def print_summary(results):
    print()
    print("=" * 60)
    statuses = {}
    for r in results:
        statuses[r["status"]] = statuses.get(r["status"], 0) + 1
    print(f"Summary across {len(results)} runs:")
    for status, count in sorted(statuses.items()):
        marker = "OK" if status == "OK" else "--" if status.startswith("SKIP") else "!!"
        print(f"  {marker} {status:18s} {count}")
