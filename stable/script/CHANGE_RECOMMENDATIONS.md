# AngelScript change recommendations

## Scope

This review compares the implementation under `data/script/` with every change recorded in the root `BARB5_CHANGELOG.md` through commit `30e4297e` (2026-08-23). It separates required compatibility work from optional adoption of newly exposed APIs.

## Executive recommendation

The typed-task migration has been applied to the shared scripts. The reported AngelScript errors came from calling builder-only APIs through `IUnitTask`; all affected paths now cast to `IBuilderTask`, null-check the cast, call `GetBuildType()` and `GetBuildPos()` on that typed handle, and read `buildDef` as a property.

Then validate configured UnitDefs and factory build menus against the exact BAR game data version. Those warnings do not cause the shown symbol errors, but they indicate profile drift and can suppress intended units or create impossible production choices.

## Required compatibility changes

### 1. Typed task hierarchy

**Source change:** `9eafe08d`, typed `IBuilderTask`, `IFighterTask`, and `CSuperTask` bindings.

**Observed failure:** `GetBuildType`, `GetBuildPos`, and `GetBuildDef` are called on `IUnitTask`. The current API registers only common methods (`GetType`, `GetUnits`, `Abort`, and `Done`) on `IUnitTask`.

**Implemented migration:**

```angelscript
IBuilderTask@ builderTask = cast<IBuilderTask>(task);
if (builderTask !is null) {
    Task::BuildType buildType = Task::BuildType(builderTask.GetBuildType());
    const AIFloat3 buildPos = builderTask.GetBuildPos();
    CCircuitDef@ buildDef = builderTask.buildDef;
}
```

Do not rely only on `task.GetType() == Task::Type::BUILDER`; the enum check does not change the static AngelScript type and therefore does not expose builder members.

**Affected shared files:**

- `src/helpers/map_helpers.as`
- `src/manager/builder.as`
- `src/roles/front.as`
- `src/roles/support.as`
- `src/roles/air.as`
- `src/roles/tech.as`
- `src/roles/sea.as`
- `src/roles/tactical.as`

**Status:** complete in this working tree. Static validation confirms there are no `GetBuildDef()` calls and all remaining build accessors use declared, null-checked `IBuilderTask` handles. The affected shared graph is loaded by `experimental_balanced`, `experimental_hard`, and `experimental_terrible`; the legacy profiles have minimal native-driven `main.as` files. Final runtime confirmation still requires loading profiles through CircuitAI because the repository has no standalone AngelScript compile target.

### 2. Build definition accessor

`IBuilderTask` exposes `CCircuitDef@ const buildDef` as a property. There is no script method named `GetBuildDef()`. Replace all three calls in `src/manager/builder.as` with reads from a validated `IBuilderTask` handle.

### 3. Warning-free compilation

CircuitAI treats AngelScript warnings as errors. Failed method resolution leaves local variables uninitialized, creating the secondary warnings in the supplied log. Initializing locals is good defensive style, but it is not the root fix; typed casts remove both the symbol errors and their dependent warnings.

## Game-data compatibility findings

The supplied log reports unknown UnitDefs `legamsub`, `legcs`, `legministarfall`, `legplat`, `legrwall`, and `legfmkr`. It also reports invalid build edges:

- `armasy` cannot build `armcarry`.
- `coramsub` cannot build `corseal`.
- `corasy` cannot build `corcarry`.
- `corgantuw` cannot build `corseal`.

Recommended action:

1. Generate or obtain the UnitDef and factory build-option catalog from the same BAR release used at runtime.
2. Remove unavailable optional units from active JSON profiles, or gate them behind the matching mod option.
3. Move units to a factory that actually exposes them, or remove the invalid edge.
4. Validate Armada, Cortex, and Legion separately because fallback-to-Cortex behavior is intentional in a few script helpers but not universally valid.
5. Automate this as a pre-release validator over all active JSON files.

These warnings are not caused by the historical `BARb.un` profile name. The missing game-side `LuaRules/Configs/BARb.un/stable/script/experimental_balanced/main.as` message is followed by successful loading from the AI package path and is not the compile root cause.

## Changelog impact matrix

| Change | Script impact | Recommendation |
|---|---|---|
| Large-army engagement scaling (`d1e2f713`) | Native threat behavior changed; no API break. | Re-tune role quota multipliers after gameplay tests because native engagement ranges now scale with enemy count. |
| Factory choice ownership (`234a01b0`) | Factory state moved into `CFactoryManager`. | Current scripts already use `aiFactoryMgr`; retain that boundary and avoid assumptions about leader-owned factory data. |
| Adaptive threat range (`3da0228b`) | New config can alter threat interpretation. | Verify each profile's `adaptive_threat_range`; document intentional `1.0` values as disabled scaling. |
| Native registration rewrite (`869f96cb`) | Signatures are now exact and overload mistakes fail at registration/compile time. | Keep script calls aligned with declarations in `src/circuit/script/*Script.cpp`; add an API smoke-load to CI. |
| SuperTask/vector fixes (`9ea0e457`) | Corrects native behavior and `SqDistance2D` overload. | No migration required; prefer exposed vector methods where they simplify manual distance logic after load testing. |
| Task control, move state, terrain, patrol (`0ef36267`) | Adds `Abort`, `Done`, `SetMoveState`, terrain helpers, and `TaskS::Patrol`. | Optional adoption. Use lifecycle methods only for managed live tasks; consider replacing custom patrol patterns with `TaskS::Patrol`. |
| Recoil API buckets and aliases (`505734a4`, `85e0a470`) | Lua utility compatibility only. | No AngelScript change. Keep aliases while unified `Spring` remains the deployed API. |
| MSVC and Apple ARM64 support (`7b308d72`, `eb650ece`) | Build portability; no script syntax change. | No script migration. Include both platforms in native build CI if distributed there. |
| Typed task hierarchy (`9eafe08d`) | Breaking API change. | Required migration described above. |
| JIT interface cleanup (`0f16bed3`) | Native implementation detail. | No script migration; smoke-test JIT and non-JIT builds if both are shipped. |
| Harmful water and path failure (`32c11e37`) | Adds `SetWaterHarmful`; failed fighter paths now stop. | Ensure setup maps `map_waterislava` to `aiSetupMgr.SetWaterHarmful()`. Re-test SEA/TACTICAL behavior on lava-water maps. |
| Auto-abort and `NO_DISRUPT` (`bd272eb3`) | Adds `IBuilderTask.canAutoAbort`; geometry C++ namespace moved. | Optionally protect critical objective/nuke tasks and key builders. No AngelScript geometry namespace migration is required. |
| `AIFloat3` ABI and terrain-center fix (`9875f1b3`) | Fixes returned vectors; function is `AiTerrainCenter()`. | Search future scripts for the old `AITerrainCenter` spelling. Current manual `AIFloat3` usage benefits automatically. |
| Final C++ classes (`f2cc1015`) | Out-of-tree native subclassing breaks. | No AngelScript change; extension code should use composition or supported interfaces. |
| Polygon API (`8203ca30`, `edeab2e0`) | Adds `CPolygon`, `IsInRange`, `GetVerts`, and `AiAddLine`. | Optional: model objective areas with polygons rather than point/radius approximations. Remember `GetVerts()` returns a copy. |
| Factory tier weights and importance (`fca11d02`, `ce73066f`) | Adds runtime tuning APIs; getters may return null. | Consider replacing duplicate script-side production weighting only where native factory weighting is sufficient. Always null-check getters and preserve exact array sizes. |
| Cached mod options (`edeab2e0`) | Returned dictionary is shared and mutable. | Treat `GetModOptions()` as read-only; copy values into `Global::ModOptions` rather than modifying the dictionary. |
| Tracy API (`d79156c0`, `7c907796`) | Script profiling zones become available. | Add balanced zones around factory selection, objective execution, and builder routing only during profiling; do not leave unmatched zones on early returns. |
| Military response bindings (`87015770`) | Runtime role-response tuning is available; returned views are borrowed. | Optional adoption for adaptive counters. Do not retain `SResponseInfo`/`SVsInfo` across manager mutations; reacquire before writes. |
| Movement/economy/support behavior (`b9b74db7`) | Native distant movement and support semantics changed. | Re-test custom guard logic because native support now uses `GUARD`; avoid duplicate periodic fight orders. |
| Commander/economy tuning (`16b0e872`) | Adds `dangerHysteresis` and `startMexTravel`. | Expose profile-specific values through `ApplyProfileSettings()` rather than hard-coded shared defaults. |
| Per-definition energy counts (`1d9952f3`) | Native demand accounting is more granular. | Re-test role energy thresholds; do not compensate for the old aggregate suppression behavior. |
| Safe `CRegion` ownership (`e6b33037`) | Native lifetime correction. | No direct script migration; avoid retaining borrowed region-related native views beyond their owner. |
| Factory representer validation (`30e4297e`) | Factory selection rejects more invalid sites. | Expect more fallbacks on constrained maps. Test map opening weights and objective anchors where large footprints are chosen. |

## Recommended modernization backlog

### Priority 0: restore operation

- [x] Complete the typed-task migration in all active call sites.
- Load `experimental_balanced` and confirm zero AngelScript warnings/errors.
- Repeat a smoke load for `experimental_hard` and `experimental_terrible`, then smoke-test the four legacy profiles for JSON/native compatibility.

### Priority 1: prevent recurrence

- Add a headless or minimal-game profile smoke test to CI.
- Add a JSON UnitDef/build-menu validator tied to the target BAR data revision.
- Centralize builder-task conversion/access helpers to make the native type boundary explicit.
- Rename all stale `HOVER_SEA` map keys to `TACTICAL` and validate map role overlays.

### Priority 2: close functional gaps

- Implement or remove the all-false defence predicate layer.
- Replace approximate MEX/GEO objective anchors with native resource-site queries.
- Complete Legion dynamic air/naval configurations and verify all Legion UnitDefs.
- Replace the enemy-player-count stub with a native binding.
- Define save/load semantics for objective, mex-upgrade, donation, and builder-tracking state.

### Priority 3: reduce maintenance cost

- Extract common profile entrypoint logic and leave profiles as tuning-only overlays.
- Consolidate duplicate unit catalogs and generate them from authoritative game data where possible.
- Migrate objective regions to `CPolygon` where point/radius matching is too coarse.
- Add selective Tracy zones to identify expensive builder and production decisions.
- Reduce hot-path logging or make verbose categories independently configurable.

## Validation checklist

- No active call invokes `GetBuildType()` or `GetBuildPos()` on `IUnitTask`.
- No active call references `GetBuildDef()`.
- Every cast to `IBuilderTask` is null-checked before use.
- Every profile compiles with warnings-as-errors.
- No active JSON references an unavailable UnitDef.
- Every configured factory/unit edge exists in the target game build menu.
- Armada, Cortex, Legion, scavenger, and extra-unit option combinations are tested where supported.
- Map-specific `TACTICAL` weights and overlays resolve under `MapConfig.RoleKey()`.
