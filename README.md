## actual-projects-benchmark

End-to-end benchmark suite with 29 real-world Java web projects (Spring Boot, Vert.x, Quarkus, JAX-RS) + an `artificial-reflection/` Maven benchmark for small reflection cases.

Prereqs: Docker + Compose v2, Python 3.8+, PyYAML
(`pip install --break-system-packages pyyaml`).

### QuickStart

```bash
python3 realworld/scripts/run_compile.py                            # stage 1: Maven compile
python3 realworld/scripts/run_junit.py                              # stage 2: JUnit tests
python3 realworld/scripts/start_application.py                      # stage 3: boot app
python3 realworld/scripts/run_smoke.py                              # stage 4: smoke only
python3 realworld/scripts/stop_application.py                       # stop app

python3 realworld/scripts/run_smoke.py --manifest vertx_app_projects.json
python3 realworld/scripts/run_smoke.py --filter joal                # one project
python3 realworld/scripts/run_smoke.py --module-type single         # filter group
python3 realworld/scripts/run_smoke.py --keep                       # keep clones
python3 realworld/scripts/run_smoke.py --workdir /tmp/foo --results out.json

cd artificial-reflection && mvn test                                # artificial reflection suite
```

Per-project status is streamed into `results_<stage>.json` as the run progresses, unless `--results` is provided. The `realworld/scripts/*` commands are thin stage-specific entry points over the shared runner implementation. Failure records carry a `stderr` / `stdout_tail` excerpt so you can diagnose without re-running.


Clones are prepared once under `--workdir` (default: `/tmp/runner-driver`) and reused by later stages. Use `--fresh` to delete and recreate a prepared clone. 

To run a pipeline up to a cutoff stage:

```bash
python3 -m realworld.runner.run_project --until compile
python3 -m realworld.runner.run_project --until junit
python3 -m realworld.runner.run_project --until start
python3 -m realworld.runner.run_project --until smoke
```

### Stages

1. Compile
```bash
mvn -B -DskipTests compile                  # default
```

2. JUnit test
```bash
mvn -B test                                 # default
```

3. Smoke test
```bash
docker compose up -d --wait                 # default lifecycle.up, start stage
bash test_api.sh                            # default lifecycle.smoke, smoke stage
docker compose down -v                      # default lifecycle.down, stop stage
```

Project-specific stage commands can be set in `runner.yaml`:

```yaml
stages:
  compile: mvn -B -DskipTests package
  junit: mvn -B -Dsome.profile=test test
```

### run step by step

Pick an entry from `realworld/projects/springboot_app_single_module.json` (or another manifest under `realworld/projects/`) and read its `github_url`, `commit_hash`, `runner_path`, then:

1. Clone at the pinned commit
```bash
WORK=/tmp/by-hand && mkdir -p $WORK && cd $WORK
git clone <github_url> myrepo && cd myrepo
git checkout <commit_hash>
```

2. Apply the overlay
```bash
#    - springboot-app-single/<slug>/ is FLAT — copy the runner dir contents
#      (skip runner.yaml/README.md/.DS_Store if present).
#    - springboot-app-multi/<slug>/  is NESTED — copy <runner_path>/overlay/.
cp -r <repo>/runners/springboot-app-single/<slug>/. .          # flat
cp -r <repo>/runners/springboot-app-multi/<slug>/overlay/. .   # nested
```

3. Boot — default lifecycle, OR follow runner.yaml when present
```bash
docker compose up -d --wait

# (multi-module only) check runner.yaml for `lifecycle.up` and `wait.urls`,
# e.g. host-side `mvn -B -DskipTests install` before compose, or a project-
# specific `start-all-services.sh`. If `lifecycle.up` doesn't end with --wait,
# poll the URLs in `wait.urls` until each returns any HTTP response.
```
4. Smoke test
```bash
bash test_api.sh                              # default
# or runner.yaml's `lifecycle.smoke` for irregular runners
```

5. Tear down
```bash
docker compose down -v                        # default
# or runner.yaml's `lifecycle.down` (+ optional `lifecycle.post_down` sweep)
```


### Manifests

Project manifests live under `realworld/projects/`:

- `springboot_app_single_module.json` — 13 single-module runners.
- `springboot_app_multi_module.json` — 6 multi-module runners.
- `vertx_app_projects.json` — 4 Vert.x runners.
- `quarkus_app_projects.json` — 3 Quarkus runners.
- `jaxrs_app_projects.json` — 3 JAX-RS runners.
- `non_springboot_web_candidates.json` — all 10 non-Spring Boot runners.

**Note:** The stage drivers read `springboot_app_single_module.json` by default. Pass `--manifest <file>` to restrict the run to specific manifests.



## Artificial Reflection Project

```bash
cd artificial-reflection
mvn test
```

Modules are grouped as `l1`-`l5` resolvability levels, `s1`-`s2` binding protocols, `m1`-`m4` reflection mechanisms, and `d1`-`d2` dependency topologies. Each family has a `ground_truth.json`; shared interfaces live in `shared-api/`.
