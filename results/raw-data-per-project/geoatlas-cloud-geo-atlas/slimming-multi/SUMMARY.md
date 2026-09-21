# geoatlas-cloud-geo-atlas — multiModuleCheck

**Reactor**: 4 top-level pom aggregators (`component`, `boot`, `library`, `app`) → 10 leaf jar modules.

## Per-module singleModuleCheck

| Module | Used (direct+trans) | Unused direct | Unused trans | Unused inherit |
|---|---:|---:|---:|---:|
| `component/metadata` | 7+74 | **1** (`jasypt-spring-boot-starter`) | 1 | 0 |
| `component/ogc-api` | 6+139 | 0 | 7 | 0 |
| `component/tile-cache` | 11+122 | 0 | 6 | 0 |
| `boot/geoatlas-tile-boot-stater` | 1+20 | 0 | **132** | 0 |
| `library/base` | 3+26 | 0 | 2 | 0 |
| `library/common` | 0+0 | 0 | 0 | 0 |
| `library/io` | 0+0 | 0 | 0 | 0 |
| `library/tile` | 4+27 | **1** (`library/io` sibling — itself empty) | 2 | 0 |
| `library/mse/pyramid` | 9+87 | 0 | 7 | 0 |
| `app/geoatlas-tile-instance` | 6+123 | 0 | 7 | 0 |

## multiModuleCheck

```
[INFO] The case without refactoring pom
```

Every `UNUSED INHERIT *` is 0 → no cross-module pom restructuring suggested.

## Notable findings

1. **`boot/geoatlas-tile-boot-stater` 132 unused transitive** — same pattern as polybot's `ingestor-service`: a Spring Boot starter shim whose own bytecode references nothing from the spring-boot/tomcat/jackson stack. Slimming's static + reflection analysis cannot see DI-driven uses.
2. **`component/metadata` declares `jasypt-spring-boot-starter`** but never references it — actionable removal candidate. Likely vestigial encryption support.
3. **`library/io` and `library/common` are empty wrappers** (0 deps, 0 classes touched). `library/tile` declares `library/io` as a direct dep but doesn't use it — a place-holder dependency edge.

## vs native-image-agent

`depclean-vs-nia.md`: depclean called 47 deps bloated; 5 NIA-hits (false-negatives), 42 confirmed bloat.

Slimming totals across leaves: 165 unused (largely from boot-stater's 132). The `boot/geoatlas-tile-boot-stater` finding parallels polybot/ingestor-service: both static tools (slimming, depclean) miss Spring's DI reflection, NIA catches it.

The two genuinely actionable items slimming surfaced (`jasypt-spring-boot-starter` in metadata, `library/io` placeholder in `library/tile`) are NOT in NIA's hit set — both are real bloat that the runtime didn't exercise either, candidates for removal.
