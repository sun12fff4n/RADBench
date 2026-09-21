# ymanvieu-trading — multiModuleCheck

**Reactor**: `trading` (pom) → `trading-common`, `trading-test`, `trading-data-collect`, `trading-webapp`, `trading-gatling`.

## Per-module singleModuleCheck

| Module | Used | Unused dir | Unused trans | Unused inherit |
|---|---:|---:|---:|---:|
| `trading-common` | 100 | 1 | 3 | 0 |
| `trading-test` | 9 | 1 | 0 | 0 |
| `trading-data-collect` | 146 | 0 | 5 | 0 |
| `trading-webapp` | 161 | 0 | 5 | 0 |
| `trading-gatling` | 111 | 0 | 0 | 0 |

## multiModuleCheck

```
[INFO] The case without refactoring pom
```

No `UNUSED INHERIT *` anywhere → parent pom is well-factored.

## Notable per-module direct removals

- `trading-common`: declares `org.mapstruct:mapstruct:1.6.0.Beta1` directly but never uses it (likely added before annotation-processor migration to a separate scope).
- `trading-test`: declares `org.assertj:assertj-core` directly with default `compile` scope (should be test-scope at most). slimming finds no compile-time use.

Both are genuine, easy removal candidates.

## vs native-image-agent

depclean-vs-nia for trading reports a small bloated set; slimming's findings overlap with depclean's confirmed-bloat (mapstruct, assertj, error_prone_annotations are annotation-only or test-only, not in NIA hits).

The reactor is among the cleanest of the 6 multi-module projects: total 14 unused across 5 modules, no inherit-bloat. Both static tools agree, runtime confirms.
