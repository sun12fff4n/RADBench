# mosip-inji-certify — multiModuleCheck

**Reactor**: `certify-parent` (pom) → `certify-integration-api`, `certify-core`, `certify-service`. Build needed `-Dgpg.skip=true` to avoid the parent's signed-release plugin.

## Per-module singleModuleCheck

| Module | All | Used | Unused dir | Unused trans | **Unused INHERIT dir** | **Unused INHERIT trans** |
|---|---:|---:|---:|---:|---:|---:|
| `certify-integration-api` | 57 | 13 | 1 | 7 | **3** | **33** |
| `certify-core` | 124 | 33 | 6 | 64 | **3** | **18** |
| `certify-service` | 274 | 264 | 1 | 9 | 0 | 0 |

## multiModuleCheck

```
[INFO] The case without refactoring pom
```

This is the **first project where the aggregator had real input** (synthesised `singleModule.json` with non-empty `ay`/`az`). Yet it still concludes no refactoring — and correctly so:

- The 3 inherit-direct deps unused by `certify-core` and `certify-integration-api` (`org.json:json`, `jakarta.servlet-api`, `jose4j`) **are used by `certify-service`** (its inherit-direct unused list is empty).
- Same for the inherit-transitive set — all 18/33 entries trace back to deps that the service module *does* exercise.
- → Parent's deps are correctly placed; pushing them down to a single child wouldn't be a clean win because at least one child genuinely needs each.

The aggregator's "no refactoring" verdict here matches the manual interpretation: the parent pom is well-factored.

## Notable per-module findings

- `certify-core` declares **6 direct unused deps** + 64 unused transitive — needs cleanup
- `certify-integration-api` is a thin contract module: 1 direct unused (likely `lombok`-style scaffolding)
- `certify-service` is the heavy lifter (264 used) with only 1 direct + 9 trans unused

## vs native-image-agent

depclean-vs-nia for mosip: depclean called 79 deps bloated; 24 NIA false-negatives, 55 confirmed bloat.

slimming surfaces the **inherit/parent-pom** layer that depclean doesn't separate — the 3 shared inherit-direct unused (json, jakarta.servlet-api, jose4j) are in fact REAL bloat for 2 of 3 children and should ideally live closer to the user (`certify-service`'s pom) rather than in the parent. NIA's runtime hits would tell us whether the smoke exercises only `certify-service` or all three.

The big-count `certify-core` 64 unused transitive overlaps with depclean's confirmed-bloat set. Slimming's reflection-aware pass shaves only a few entries — most of those transitives really are unreachable at runtime too.
