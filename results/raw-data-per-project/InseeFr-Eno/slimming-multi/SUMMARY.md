# InseeFr-Eno — multiModuleCheck

**Reactor**: `eno` (pom) → `eno-core`, `eno-treatments`, `eno-ws`

## Per-module singleModuleCheck (each in its own JVM to avoid slimming's static-state NPE)

| Module | All deps | Used | Unused (transitive) | Unused (inherit) | realBloated |
|---|---:|---:|---:|---:|---:|
| `eno-core` | 47 | 47 | 0 | 0 | 0 |
| `eno-treatments` | 54 | 52 | 2 | 0 | 2 |
| `eno-ws` | 131 | 128 | 3 | 0 | 3 |

`eno-treatments` unused: `org.skyscreamer:jsonassert:1.5.3`, `com.vaadin.external.google:android-json:0.0.20131108.vaadin1`.
`eno-ws` unused: same two + `org.jspecify:jspecify:1.0.0`.

## multiModuleCheck (aggregator)

```
[INFO] The case without refactoring pom
```

The parent pom inherits only `lombok` (used by every child), so there are zero `UNUSED INHERIT *` entries to pull up or push down across the reactor. The aggregator correctly concludes nothing needs cross-module refactoring.

## Plugin-level findings

slimming v1.0's multiModuleCheck has two undocumented behaviours that made the goal silently no-op originally:

1. It expects `<reactor>/bloatedOutput/singleModule.json`, **not** `<reactor>/singleModule.json` — the bytecode bootstrap recipe is `\u0001\u0001bloatedOutput\u0001`. The error message says "in project root" which is misleading.
2. v1.0's `singleModuleCheck` does not write `singleModule.json` at all (write path is conditional on internal state that stays empty). It looks like the goal was renamed/reworked for a never-published v2.0.

Workaround used here: each submodule is run in its own `mvn -pl <m>` invocation (slimming's `public static final Set` cache poisons subsequent reactor modules → NPE), then `singleModule.json` is synthesised from the per-module logs and dropped into `bloatedOutput/`.

## vs native-image-agent

`depclean-vs-nia.md` (whole reactor, 131 artifacts) reports 35 deps depclean called bloated, of which 17 are NIA-hits at runtime and 18 are confirmed bloat.

slimming (reflection-aware) per module:
- `eno-core` 47/47 used — agrees with NIA on every dep being needed
- `eno-treatments` 2 unused — both genuine (test-scope helpers superseded by JUnit5 / Jackson; not in NIA reflect-config)
- `eno-ws` 3 unused — same two plus `jspecify` (annotation-only, never reflectively touched)

Slimming's three "unused" findings overlap with depclean's "confirmed bloat" set and are NOT in NIA's runtime hits — both static tools agree, runtime confirms.
