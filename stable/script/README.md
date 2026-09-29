# AngelScript AI implementation

## Purpose and scope

This directory contains the profile-specific AngelScript policy layer used by CircuitAI. The C++ library owns engine integration, pathing, unit/task objects, schedulers, and manager implementations. These scripts select roles, tune managers, enqueue tasks, track strategic state, and override builder, factory, economy, and military decisions.

This document describes the shared implementation in `src/` and the difficulty profiles beside it. Compatibility with the current C++ bindings and recommended migrations are tracked in [CHANGE_RECOMMENDATIONS.md](CHANGE_RECOMMENDATIONS.md).

## Runtime structure

Each difficulty directory is a deployable script profile:

- `init.as` returns `SInitInfo`, initializes armor/category masks, and selects JSON profile fragments. Legion, scavenger, and extra-unit fragments are conditional on mod options.
- `experimental_balanced`, `experimental_hard`, and `experimental_terrible` include the shared graph through `src/setup.as`. Their `main.as` files register maps, select strategy weights, tag factory tiers, apply profile tuning, run periodic threat/cost updates, and receive Lua messages.
- `easy`, `medium`, `hard`, and `hard_aggressive` are legacy/native-driven profiles. Their `main.as` hooks are empty or contain only commented examples, so behavior comes from CircuitAI's native defaults and their JSON configuration rather than the shared role framework.

The experimental runtime sequence is:

1. `Init::AiInit()` builds the configuration fragment list.
2. `Main::AiMain()` registers maps and applies profile strategy/tuning.
3. The first factory selection calls `Setup::setupMap()`, which resolves map, start spot, faction, role, unit-limit overlays, and role delegates. It also logs a deterministic startup snapshot covering terrain dimensions and land/water percentages, team topology, effective UnitDef count, selected commander, parsed settings, sorted mod options, and selected game/team rules.
4. CircuitAI invokes namespace hooks for managers: `AiMakeTask`, `AiTaskAdded`, `AiTaskRemoved`, unit lifecycle hooks, economy updates, factory selection/switching, defence, and periodic `Main::AiUpdate()`.
5. Role delegates in `RoleConfig` specialize the shared manager behavior and fall back to native `Default*` methods when no script policy applies.

## Shared foundation

| Component | Responsibility |
|---|---|
| `src/common.as` | Shared initialization data such as armor definitions and categories used by every profile `init.as`. |
| `src/define.as` | Script constants, aliases, masks, priorities, random helpers, and common definitions expected by all modules. |
| `src/setup.as` | Composition root. Includes helpers, maps, roles, and managers; selects factories; parses mod options; resolves map/profile state; and wires role delegates. |
| `src/global.as` | Process-wide script state: map/start resolution, side and role, merged limits, mod options, profile controller, and extensive per-role tuning values. |
| `src/unit.as` | Built-in and custom role masks, unit attributes, `Unit::UseAs`, and compatibility aliases under `RT`. |
| `src/task.as` | Task enums and constructors for builder, factory/static, and fighter task request structures passed to native managers. |

## Type and policy model

| Component | Capability |
|---|---|
| `src/types/ai_role.as` | Defines FRONT, SUPPORT, AIR, TECH, SEA, and TACTICAL strategic roles and string conversion. |
| `src/types/role_config.as` | Delegate-based policy object for initialization, updates, task creation/lifecycle, unit lifecycle, factory switching/selection, air validity, defence, and role matching. Includes defaults and a registry. |
| `src/types/profile_controller.as` | Holds the selected `RoleConfig` and dispatches its periodic update. |
| `src/types/map_config.as` | Map-name matching, start spots, base and per-role unit limits, side-specific weighted factory openings, and strategic objectives. |
| `src/types/start_spot.as` | Start position, preferred role, and land-locked metadata. |
| `src/types/terrain.as` | Script terrain categories used by role and factory decisions. |
| `src/types/strategy.as` | Bitmask strategies such as T2, T3, and nuke rushes with enable/disable/name helpers. |
| `src/types/opener.as` | Opening build-plan data and selection state. |
| `src/types/building_type.as` | Strategic building categories used by objective resolution and builder enqueue helpers. |
| `src/types/strategic_objectives.as` | Objective geometry, role/side/constructor gates, ordered build steps, priorities, economy gates, and builder-group ownership. |
| `src/types/profile.as` | Fully commented-out superseded profile model; retained as historical design material, not runtime code. |

## Managers

### Builder manager policy

`src/manager/builder.as` is the largest orchestration module. It:

- Tracks commanders and primary, secondary, freelance, and tactical constructors across bot, vehicle, air, sea, and hover classes.
- Distributes assistants through per-leader guard maps and an unassigned worker pool.
- Routes role-specific builder task creation and falls back to `aiBuilderMgr.DefaultMakeTask()`.
- Enqueues factories, nanos, energy, storage, converters, mex upgrades, defences, sensors, superweapons, and objective buildings.
- Tracks selected builders by unit ID, current tasks, task start proximity, cooldowns, queued structures, and objective progress.
- Handles task-added/task-removed callbacks and unit lifecycle cleanup.
- Reacquires units by ID where possible because `CCircuitUnit` is exposed as a borrowed, non-counted native object.

### Factory manager policy

`src/manager/factory.as`:

- Tracks primary factories for every terrain/tier and per-factory caretaker counts.
- Tracks queued T2 labs and energy structures.
- Dispatches factory tasks and lifecycle events to the active role.
- Implements role-aware opening-factory selection and native fallback.
- Controls factory switching intervals, affordability gates, and assistance demand.
- Annotates factory definitions with script-local tier attributes.

`src/manager/factory_production.as` provides adaptive production for enabled roles. It registers per-factory unit/role tables, selects an economic tier, weights roles using enemy threat, guarantees required constructors, supports priority batches, and enqueues recruit tasks. Configurations are split into:

- `src/manager/factory_production/factory_configs_bot.as`
- `src/manager/factory_production/factory_configs_vehicle.as`
- `src/manager/factory_production/factory_configs_air.as`
- `src/manager/factory_production/factory_configs_hover.as`
- `src/manager/factory_production/factory_configs_sea.as`

### Economy manager policy

`src/manager/economy.as` derives empty/full/stalling flags from native resource snapshots, maintains rolling ten-second minimum income values, exposes economy placement anchors, and tracks owned mexes and upgrade state. It delegates role-specific income/cap transitions after updating shared state. Save/load hooks currently contain no persistence logic.

`src/manager/build_power.as` (`BuildPower`) is FRONT's and AIR's answer to metal near max, from their own income or from metal TECH trades in: while the bank sits at `Global::BuildPower::CapFill` of storage or more it queues construction turrets on the T2 plants and gantries (T1 plants only while there are none), sized from the unspent surplus and gated on energy; if the bank stays at `GantryFill` for `GantrySeconds` it queues another land gantry, raising the gantry cap (AIR starts at 0) within any map limit. It runs from `Main::AiUpdate`; FRONT's turret and gantry caps keep room for what it has queued.

`src/manager/naval_waves.as` (`NavalWaves`) holds every faction's frigates and destroyers in a hold task that cannot self-promote and launches every held ship as one attack once the hold reaches a size drawn per wave from `Global::NavalWaves::MinWaveSize`-`MaxWaveSize` (7-10), or after `MaxHoldSeconds` (4 minutes) with at least 3 held.

### Military manager policy

`src/manager/porc_policy.as` is the shared porcupine policy: `Military::Porc::MakeDefence` sets `aiMilitaryMgr.porcMode` / `porcBudgetMod` (late game gated on both incomes, energy stall fallback, enemy pressure, banked metal or energy) and then runs the native placement, adding a caretaker per cluster while the economy is strong, for every role without its own defence handler. `src/manager/military.as` dispatches role-specific task and unit hooks, adjusts defence behavior, caches enemy threat and metal-cost totals by surface/air/water category, and exposes per-player estimates used by dynamic role quotas. Enemy player count comes from `ai.GetEnemyTeamSize()`. The role masks those caches index are built by `FactoryProduction::BuildRoleCaches()`, which `Setup::setupMap()` now calls unconditionally; before that it ran only when a role enabled dynamic production, so every cached threat and cost stayed 0.

### Objective and team state

`src/manager/objective_manager.as` owns objective assignment, completion, selected objective per role/builder group, and queued/built counts by concrete unit type. `src/manager/spam.as` (`Spam`) is the economy-gated spam: once metal and energy income clear `Global::Spam` thresholds every T1 factory listed in `UnitByFactory` produces its spam unit on repeat, each factory owns a native `CRouteTask` (`TaskF::Route`) with a parallel-lane route to a point behind the current focus, spam units join their factory route from `Military::AiMakeTask`, and every refocus rebuilds all routes and re-issues them to units on the field; see `doc/spam-routes.md`. `src/manager/donation.as` (`Team::Donation`) is TECH's hand-out: N of the T2 combat bots its advanced lab batches (drawn once between `Tech::T2BotDonationMin` and `T2BotDonationMax` with geometric decay) go to the closest allies by roster start position, fewest-first; T2 constructors are given only to a teammate that asked (`barbdon|conreq`, sent automatically by a non-TECH BARb with no T2 of its own, `Global::ConstructorRequest`), built ahead of everything else by the advanced lab and flown by the ferry transport when TECH owns one. `src/manager/sea_assist.as` (`Team::SeaAssist`) is SEA's construction-ship gift to a TACTICAL ally, which then runs the shared `helpers/sea_constructor_helpers.as` ladder. `src/manager/roster.as` (`Team::Roster`) makes every allied BARb announce team id, skirmish AI id, role, side, start factory, start position, landlocked flag, start-spot index and lead-team flag over `AiSendMessage` until all allied team ids have answered (newcomers are answered directly); consumers use `Team::Roster::Get/All/WithRole/Leader/Nearest`. `src/manager/widget_link.as` mirrors roster and orphan events to the local LuaUI through `ai.CallUI` (host machine only, playing or spectating) for `tools/widgets/gui_barb_team_link.lua`. `src/manager/commands.as` is the reverse path: `Main::AiLuaMessage` hands `barb|...` lines from the widget to `Commands::Handle` (`query` answers with the roster line, `setrole|<ROLE>` performs a runtime role switch: restore the def snapshot taken in Setup, rebind the RoleConfig, run its InitHandler, recompute merged limits, re-announce; `layout|on|off` pushes the planned base to the widget overlay). `src/manager/layout.as` is TECH's policy shell over the native plan (D-060 factory pair, D-063 turret box): it chooses the factory-pair candidate, fits the turret box behind it (the flattest, most buildable rectangle, turret rows reserved slot by slot as invisible turrets), adopts named state after load, and places every economy structure and turret on box cells nearest a turret (`Layout::Place`, `Layout::NanoTask`, native `PackNearGroup`), pinned, never spiralled. `src/manager/eco_planner.as` (`EcoPlanner`, D-058/D-063) is the one next-building function: energy draining, energy floating (converter), build power short or metal floating (turret), energy below target, storage; it offers only what the box can hold. The commander's opening (every reachable mex within 2,000 elmos, nearest first, then the start factory) is `Opening` in `roles/tech.as`. See `doc/layout-design.md`, `doc/eco-planner.md` and `doc/tech-eco-meta.md`. It also implements orphan rescue: `Team::CheckOrphaned` (from `Main::AiUpdate`) makes an AI with no commander and no workers ask its allies one at a time for a T1 constructor via `AiSendMessage`; `Team::HandleMessage` (from `Main::AiMessage`) makes a donor with three or more workers hand over a spare, non-leader T1 constructor with `ai.GiveUnits`. Live T1 constructor ids are registered by `Builder::AiUnitAdded`/`AiUnitRemoved`.

## Strategic roles

| Role | Primary behavior |
|---|---|
| FRONT (`src/roles/front.as`) | Land-force opening, bot/vehicle factory specialization, adaptive production, income-driven caps, guard behavior, defence construction, and delayed army-versus-enemy-surface quota hysteresis. |
| SUPPORT (`src/roles/support.as`) | Economy/support opening, restricted combat/air/nuke access, resurrection and assistance focus, commander/constructor guarding, and income-scaled builder limits. |
| AIR (`src/roles/air.as`) | Staged air production, an early two-lane build-power policy (strategic economy plus expansion), task-aware constructor assistance, commander-built wind on suitable maps, delayed advanced solar, T1 static defence restricted to anti-air, bounded fighter/heavy-air quotas, and delayed air-force-versus-enemy-air quotas. T1 combat aircraft use native military task assignment; T2 bombers and T2 fighters are held at base and released together in growing escorted waves by `src/manager/air_waves.as`. |
| TECH (`src/roles/tech.as`) | T2/T3/nuke strategies, strict tier caps, storage and energy progression, mex upgrades, gantries, strategic objectives, constructor donation, shipyards and hover plants on landlocked starts once income allows, and extensive economy-dependent build routing. |
| SEA (`src/roles/sea.as`) | Shipyard starts, naval production, tidal/sea economy, naval fire states, sea constructors and donation, and fleet-versus-enemy-water quota adjustment. |
| TACTICAL (`src/roles/tactical.as`) | Hover-focused opening, tactical constructors, map-objective execution, hover production, objective-based static construction, and mixed-terrain expansion. This replaces the older HOVER_SEA name. |

Every role supplies only the delegates it needs. Missing behavior deliberately falls back to the shared manager or native CircuitAI implementation.

## Helpers

| Helper | Responsibility |
|---|---|
| `generic_helpers.as` | Structured logging and one-time start capture. |
| `map_helpers.as` | XZ distance/range calculations, nearest start selection, land-lock checks, and builder-task range checks. |
| `unit_helpers.as` | Faction/tier/terrain unit catalogs, factory and constructor classification, unit limits, side-specific structure lookup, and objective UnitDef resolution. |
| `unitdef_helpers.as` | UnitDef lookup/count aggregation, ignore flags, attributes, and main-role mutation. |
| `economy_helpers.as` | Parameterized economic gates and count formulas for factories, builders, energy, storage, converters, and assistance. |
| `factory_helpers.as` | Side/role fallback factories and weighted map-specific opening selection. |
| `builder_helpers.as` | Shared builder selection and task utilities. |
| `guard_helpers.as` | Guard task creation and weighted distribution among leaders. |
| `role_helpers.as` | Default role selection and random side-specific land/water factories. |
| `role_limit_helpers.as` | Bulk tier/faction combat and gantry cap policies. |
| `limits_helpers.as` | Base-map plus role-overlay unit-limit merge. |
| `objective_helpers.as` | Objective filtering, matching, distance, ordering, progress, and state wrappers. |
| `objective_executor.as` | Resolves objective steps to concrete UnitDefs/build types and enqueues the next actionable task. |
| `porc_helpers.as` | Porcupine chain: the config-seeded default, additive Extra Units / Scavenger tiers gated on mod options, and per-role rewrite through `RoleConfig::PorcChainHandler`. See `doc/porc-chain.md`. |
| `defense_helpers.as` | Reserved defence predicates; all current predicates are placeholders returning `false`. |
| `collection_helpers.as` | Dictionary/array utility operations. |
| `task_helpers.as` | Human-readable task/build-type names for diagnostics. |

## Map layer

`src/maps.as` registers the default map and the map modules under `src/maps/`. A map can provide:

- Prefix-based map-name matching.
- Known start positions with role and land-lock hints.
- Base UnitDef caps and role-specific cap overlays.
- Side-specific weighted opening factories.
- Ordered strategic objectives with geometry, constructor class, role, economy, timing, and priority constraints.

The current modules are `acidic_quarry`, `all_that_glitters`, `ancient_bastion_remake`, `eight_horses`, `flats_and_forests`, `forge`, `glacial_gap`, `koom_valley`, `mediterraneum`, `raptor_crater`, `red_river_estuary`, `serene_caldera`, `shore_to_shore`, `sinkhole_network`, `supreme_isthmus`, `swirly_rock`, `tempest`, and `tundra_continents`, plus `default_map_config` and the legacy string-based `factory_mapping` helper.

Supreme Isthmus has the richest objective data, including island, geo-hill, coastal, sensor, defence, economy, and long-range weapon chains. Other maps primarily provide starts, role hints, caps, and opening weights.

## C++ binding boundary

Scripts consume native globals including `ai`, `aiSetupMgr`, `aiTerrainMgr`, `aiBuilderMgr`, `aiFactoryMgr`, `aiEconomyMgr`, `aiMilitaryMgr`, role/attribute/side maskers, and task request types. Important ownership rules:

- `IUnitTask` is the common task interface. Builder-only data requires `cast<IBuilderTask>(task)`.
- `IBuilderTask` exposes `GetBuildType()`, `GetBuildPos()`, `buildDef`, `target`, and writable `canAutoAbort`.
- `IFighterTask` exposes fighter type; `CSuperTask` adds target-position control.
- `CCircuitUnit` handles are borrowed. Long-lived code should retain IDs and reacquire the unit.
- Manager response views and cached mod-option dictionaries are native-owned or shared; callers must respect the lifetimes described in the recommendations document.

## Known gaps and risks

Open problems are tracked in [`../../doc/known-issues.md`](../../doc/known-issues.md),
the repository-wide register. Script-layer entries are `KI-2xx`, with the
configuration entries that affect scripts at `KI-3xx`. Add an entry there
whenever you diagnose a script problem and leave it unfixed; do not start a
second list here.

The typed-task compilation failure once reported against `experimental_balanced`
has been corrected in the shared source. All builder metadata access now uses a
null-checked `IBuilderTask`; the obsolete `GetBuildDef()` call was replaced with
the `buildDef` property. The four legacy profiles never executed the affected
code.

## Maintenance workflow

1. Update the C++ binding registration and `BARB5_CHANGELOG.md` first when the script API changes.
2. Search all shared and profile scripts for changed symbols and ownership assumptions.
3. Keep fallback behavior null-safe and prefer typed task casts over task-type enum checks alone.
4. Validate every configured UnitDef against the target BAR version and each factory's actual build options.
5. Load every profile at least once with Armada, Cortex, and Legion/optional-unit modes relevant to that profile.
6. Treat AngelScript warnings as failures because the host application compiles with warnings-as-errors.
