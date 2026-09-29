# SMRTBARb

A Beyond All Reason skirmish AI profile: AngelScript (`stable/script/`) layered
over CircuitAI's C++ engine, with per-difficulty JSON config in `stable/config/`.

## People

- **Barscrewl** (dartiberryy@yahoo.com) is the repository owner and the person
  you are working with in this project.
- **Centrifugal** is the upstream SMRTBARb developer. Changes landing from them
  arrive as large merges; preserve their work when reconciling.

## Upstream

CircuitAI's real source is on the `barb5` branch of `rlcevg/CircuitAI`
(`master` is a LICENSE/README stub). Engine behaviour claims about task
selection, roles or attributes should be checked against that branch rather
than recalled.

## Config conventions

- `behaviour*.json` is JSON with `//` and `/* */` comments and trailing commas,
  so it needs a tolerant parser.
- `stable/config/experimental_*/` files use CRLF in places. Edit them
  byte-wise; a naive text round-trip rewrites every line and turns a one-line
  change into a whole-file conflict.
- In a `role` array only `role[0]` is the unit's real role. `role[1..]` feeds
  `AddEnemyRoles()` only - how *other* AIs account for the unit - and does not
  change its own behaviour. Strings in `attribute` are matched against role
  names *first*, so an attribute that happens to name a role becomes a real
  added role.


## Branches

- `main` is our line: the map files, the FRONT and AIR work and our own
  managers.
- `cent-upstream` is Centrifugal's latest release with our work harmonized onto
  it. Cent's changes are the law here: our code fits his systems, never the
  other way round.
- Cent's releases themselves are tags, exactly as shipped:
  `cent-release/<name>` (first: `cent-release/TechEcoPrototypeV2`).
- `harmonize` was created before harmonizing moved onto `cent-upstream` and is
  no longer used.

`main` and `cent-upstream` have unrelated histories. Move our work across by
porting it (three-way per file against the Sep 20 import `3246e95` works for
files both sides grew from), never by merging one branch into the other.

### Taking in a new Cent release

Commit the release on top of the previous release tag, tag it, then merge the
tag into `cent-upstream`. The merge base is the previous release, so only what
Cent changed since then comes in, on top of our ported work:

```
git switch --detach cent-release/<previous>
git rm -rq .
cp -r "<package>/SMRTBARb/." .
git -c core.autocrlf=false add -A
git -c core.autocrlf=false commit -m "Cent release: <name>"
git tag cent-release/<name>
git push origin cent-release/<name>
git switch cent-upstream
git merge cent-release/<name>
```

Resolve conflicts in Cent's favour for his systems, keep our additions, then
test in game before pushing.

## Harmonized from `main` (onto TechEcoPrototypeV2)

- Maps: the 51 map configs from the BAR map-list export and their
  `maps.as` includes and registrations. Cent's maps kept; their TACTICAL
  factory weights and unit limits were stored under "HOVER_SEA", which
  `MapConfig::RoleKey()` never looks up, and now use "TACTICAL".
- AIR, `roles/air.as` three-way merged: metal-starved mode, T1 strike cap,
  Bastion gate, T2 plant cap by income, air scouts, T1 air constructors by
  income, heavy air every Nth T2 turn, no factory assist. Cent's porc chain
  (`PorcChainHandler`) and our starved-mode porc (`AiMakeDefenceHandler`)
  are both registered - one picks what is built, the other how much. AIR's
  economy has since been replaced by TECH's (see below).
- AIR bomber waves, `manager/air_waves.as` three-way merged onto Cent's
  income floor and wave attack methods (`CAirWaveTask`): fighter groups,
  Liche mix, escort production counts, starved production, and the late
  wave cap (`BomberStock::WaveCap`, 20 -> 40) on `Required()`, `_Launch` and
  `_Clamp`.
- New file: `manager/bomber_stock.as` (bombers parked out of AI control
  with `ai.UnitControl` until a wave is full).
- Shared files, AIR hooks only: `military.as` (BomberStock claim / count /
  forget), the three `experimental_*/main.as` (`Builder::FlushAborts`,
  `BomberStock::Update`), `global.as` (`Air` settings merged,
  `BomberStock` added), `builder.as` (DEFERRED ABORT; `EnqueueFUS` /
  `EnqueueAFUS` take `expireWhenAbandoned`, off for every existing caller).

Not ported: our gantry placement and re-placement (Cent's
`Builder::EnqueueLandGantry` at `Factory::GetPreferredFactoryPos()` and his
native factory layout are used), and our TECH, FRONT, SEA and other role work.

## AIR runs TECH's economy

With `Global::RoleSettings::Air::ExperimentalEco` (on), AIR's builders take
their work from TECH's experimental system (`TechBuild::MakeTask`, the rule
table, rush chain, income plan, eco planner and layout), not from code of
its own. `manager/eco_role.as` (`EcoRole`) is the only place the two roles
differ: which labs and constructors count (aircraft plants and air
constructors for AIR), how a T1 or T2 lab is enqueued, and
`ReclaimsLabs()` - AIR never reclaims its T1 or T2 plant, and TECH's land
rows (forward constructors, front factories, spam labs) and the invariant
tick are TECH only. AIR adds one row, `air.plants` (`Air_PlantsAndNanos`): more
T2 aircraft plants by income, nanos at them while metal floats.
Metal-starved mode still holds AIR's porc and T2 production. TECH code
that asks "which lab" should go through `EcoRole`, not name bot labs.

## Never abort a task inside AiMakeTask

The engine calls AiMakeTask while it assigns or re-evaluates that builder,
and the task it offers can be the builder's current one. `Abort()` there
frees a task the engine then touches again: three access violations in
SkirmishAI.dll on 2026-09-26. Use `Builder::AbortLater`; `Builder::FlushAborts`
aborts from `Main::AiUpdate`. Aborts from update loops are fine.
