# jisl1024-JiChat — multiModuleCheck

**Reactor**: 13 leaf jar modules across `jichat-framework/*`, `jichat-gateway`, `jichat-modules/{chat,user,client}`.

## Per-module singleModuleCheck

| Module | Used | Unused dir | Unused trans | Unused inherit |
|---|---:|---:|---:|---:|
| `jichat-framework/jichat-common` | 59 | **4** | 41 | 0 |
| `jichat-framework/jichat-mybatis-gen` | 9 | **5** | 32 | 0 |
| `jichat-framework/jichat-spring-boot-starter-excel` | 50 | 2 | **85** | 0 |
| `jichat-framework/jichat-spring-boot-starter-mybatis` | 73 | 0 | 4 | 0 |
| `jichat-framework/jichat-spring-boot-starter-security` | 104 | 0 | 7 | 0 |
| `jichat-framework/jichat-spring-boot-starter-swagger` | 53 | 0 | 4 | 0 |
| `jichat-framework/jichat-spring-boot-starter-web` | 98 | 1 | 6 | 0 |
| `jichat-gateway` | 111 | 0 | 6 | 0 |
| `jichat-modules/chat-client` | 165 | 0 | 4 | 0 |
| `jichat-modules/chat-service/chat-service-api` | 61 | 0 | 5 | 0 |
| `jichat-modules/chat-service/chat-service-app` | 234 | 0 | 6 | 0 |
| `jichat-modules/user-service/user-service-api` | 15 | 0 | **51** | 0 |
| `jichat-modules/user-service/user-service-app` | 214 | 0 | 6 | 0 |

## multiModuleCheck

```
[INFO] The case without refactoring pom
```

Zero `UNUSED INHERIT *` everywhere → no cross-module pom restructuring suggested.

## Notable: actionable direct-dep removals

slimming flagged **direct** deps (declared in the module's pom, easy to delete) as unused:

- `jichat-common`: `fastjson2`, `commons-lang3`, `springdoc-openapi-starter-webmvc-api`, `hutool-all`
- `jichat-mybatis-gen`: `mybatis-plus-generator`, `spring-boot-autoconfigure`, `jetbrains/annotations`, `freemarker`
- `jichat-starter-excel`: `commons-io`, `jakarta.servlet-api`
- `jichat-starter-web`: 1 dep

These are genuine bloat — kept around as scaffolding from a project template / archetype.

## Big unused-transitive counts

- `jichat-starter-excel` 85: most of Spring Boot autoconfigure pulled by EasyExcel; statically unreached
- `user-service-api` 51: thin API module
- `jichat-common` 41 + `mybatis-gen` 32: utility libraries with broad classpath but narrow actual usage

## vs native-image-agent

depclean-vs-nia for jichat: depclean found 65 bloated deps; 11 NIA false-negatives, 54 confirmed bloat.

Slimming's per-module unused (most modules 4-7 trans) overlaps with depclean's confirmed-bloat set. The big-count modules (`starter-excel` 85, `user-service-api` 51) include the Spring/Tomcat reflection-driven deps that show up in depclean's NIA false-negatives — slimming under-counts the same DI reflection paths.

The 12 actionable direct-dep removals slimming surfaced (across `jichat-common`, `mybatis-gen`, `starter-excel`, `starter-web`) are NOT in NIA's hit set — confirmed safe to delete.
