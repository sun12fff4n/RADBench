# ent0n29-polybot — multiModuleCheck

**Reactor**: `polybot` (pom) → 6 services: `polybot-core`, `executor-service`, `strategy-service`, `analytics-service`, `ingestor-service`, `infrastructure-orchestrator-service`.

## Per-module singleModuleCheck

| Module | Used | Unused (transitive) | Unused (inherit) |
|---|---:|---:|---:|
| `polybot-core` | 102 | 3 | 0 |
| `executor-service` | 124 | 2 | 0 |
| `strategy-service` | 123 | 3 | 0 |
| `analytics-service` | 92 | **0** | 0 |
| `ingestor-service` | 57 | **69** | 0 |
| `infrastructure-orchestrator-service` | 115 | 3 | 0 |

## multiModuleCheck

```
[INFO] The case without refactoring pom
```

Same as InseeFr-Eno: zero `UNUSED INHERIT *` across modules, so no cross-module pom restructuring is suggested.

## Notable: `ingestor-service` 69 unused transitive

Slimming flags the entire Spring Boot + Tomcat embed + Jackson + web3j + Prometheus + ASM transitive closure as unused. The module declares these via `spring-boot-starter-web` but its own bytecode doesn't reference any of them — it's a thin shim whose work runs through Spring beans configured in *other* modules.

This is precisely the case where slimming's static analysis (even with reflection chains) under-counts: Spring bean wiring driven by classpath scanning + property-based DI doesn't show up as a method call edge. NIA's smoke run would hit these classes at runtime if `ingestor-service` is exercised.

## vs native-image-agent

`depclean-vs-nia.md` for the same reactor:
- 50 deps depclean called bloated → 10 NIA false-negatives, 40 confirmed bloat.

Slimming's totals across the 6 modules: 80 deps marked unused (mostly from `ingestor-service`'s 69). Many of those 69 (spring-boot-actuator-autoconfigure, tomcat-embed-websocket, jul-to-slf4j, snakeyaml, jackson-databind, etc.) appear in depclean's NIA-false-negative table — both static tools miss the same Spring runtime reflection. This validates that the "depclean false-negatives" ARE real reflection-driven uses, not depclean-specific blind spots.

For modules other than `ingestor-service`, slimming's unused counts (0–3) are conservative and largely match NIA's miss set.
