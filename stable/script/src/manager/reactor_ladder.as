// Post-T2 reactor ladder shared by AIR and FRONT: fusions, then AFUS, fusion reclaim, advanced converters.
#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/unit_helpers.as"
#include "../helpers/unitdef_helpers.as"

/******************************************************************************

POST-T2 REACTOR LADDER (ReactorLadder::TryT2Economy)

Run by a role's T2 constructors (AIR: every one, after the mex upgrade; FRONT:
primary and secondary, past Front::ReactorLadderMinSeconds). Fusion is uncapped
and advanced fusion is capped at Params::maxAFUS; the ladder only orders them:

  1. fusionsBeforeAFUS fusions, one at a time (Builder::EnqueueFUS), from
     minMetalIncomeForFUS average metal income.
  2. The first AFUS once those fusions are FINISHED. Until then every AFUS def
     is capped at 0 (UpdateAfusGate), so native energy tasks - economy.json
     lists armafus / corafus from 70 metal / 4000 energy income - cannot build
     one first. The cap then opens to Params::maxAFUS.
  3. Once reclaimFusionsAtAFUSCount AFUS exist - the second counts from the
     moment its nanoframe is down - the tracked fusions are reclaimed one at a
     time to fund it.
  4. The second AFUS as soon as the first is finished, ahead of converters.
  5. Advanced converters while energy sits at advConverterEnergyPercent of
     storage, up to convPerFusion / convPerAFUS per finished reactor
     (TryAdvConverter). This rule already applies from the first finished
     fusion: before the first AFUS it is tried once steps 1-2 have nothing to
     queue.
  6. Past the second, another AFUS whenever energy is below
     advConverterEnergyPercent (the converters are eating what the reactors
     make), one in flight at a time.
  7. Otherwise assist whichever reactor is under construction (Params::
     assistReactor; FRONT returns null instead and goes on to its silo steps).

A T2 constructor already building a fusion, AFUS or advanced converter keeps it
(IsOnLadderBuild): native re-evaluation probes the ladder too, and would
otherwise pull a builder off a half-walked AFUS onto a converter.

Known gap: fusions stay uncapped, so after the reclaim native energy tasks may
build a new fusion during an energy stall. The ladder never does.

One role runs per AI instance, so the gate and reclaim state here is that
role's. Finished reactors are tracked for every role (Main::AiUnitFinished via
RoleAir::Air_OnUnitFinished -> OnUnitFinished), so a role switched in mid-game
still knows what is standing. Only ids are kept; dead ids are pruned on read.

******************************************************************************/
namespace ReactorLadder {

    class Params {
        string tag;                        // log tag: "AIR", "FRONT"
        int fusionsBeforeAFUS;
        float minMetalIncomeForFUS;
        int reclaimFusionsAtAFUSCount;
        int maxAFUS;
        float advConverterEnergyPercent;
        int convPerFusion;
        int convPerAFUS;
        bool holdConverters = false;       // AIR metal-starved: no advanced converters
        Task::Priority reactorPrio = Task::Priority::NORMAL;
        // Step 7. FRONT turns it off: its silo and superweapon steps come after the
        // ladder, and an assist returned here would starve them.
        bool assistReactor = true;
    }

    array<string> ADV_CONVERTERS = { "armmmkr", "cormmkr", "legadveconv" };

    array<int> fusionIds;     // finished fusion reactors
    array<int> afusIds;       // finished advanced fusion reactors
    array<int> advConvIds;    // finished advanced converters

    bool afusGateOpen = false;
    IUnitTask@ fusionReclaimTask = null;

    bool NameIn(const string &in name, const array<string> &in names)
    {
        for (uint i = 0; i < names.length(); ++i) {
            if (names[i] == name) return true;
        }
        return false;
    }

    void RemoveId(array<int>@ ids, int id)
    {
        for (uint i = 0; i < ids.length(); ++i) {
            if (ids[i] == id) { ids.removeAt(i); return; }
        }
    }

    void PruneIds(array<int>@ ids)
    {
        for (int i = int(ids.length()) - 1; i >= 0; --i) {
            if (ai.GetTeamUnit(ids[i]) is null) ids.removeAt(uint(i));
        }
    }

    // True when `unit` was a reactor or advanced converter (tracked here).
    bool OnUnitFinished(CCircuitUnit@ unit)
    {
        if (unit is null || unit.circuitDef is null) return false;
        const string name = unit.circuitDef.GetName();
        if (NameIn(name, UnitHelpers::GetAllFusionReactors())) {
            RemoveId(@fusionIds, unit.id);
            fusionIds.insertLast(unit.id);
            return true;
        }
        if (NameIn(name, UnitHelpers::GetAllAdvancedFusionReactors())) {
            RemoveId(@afusIds, unit.id);
            afusIds.insertLast(unit.id);
            return true;
        }
        if (NameIn(name, ADV_CONVERTERS)) {
            RemoveId(@advConvIds, unit.id);
            advConvIds.insertLast(unit.id);
            return true;
        }
        return false;
    }

    void OnUnitDestroyed(CCircuitUnit@ unit)
    {
        if (unit is null) return;
        RemoveId(@fusionIds, unit.id);
        RemoveId(@afusIds, unit.id);
        RemoveId(@advConvIds, unit.id);
    }

    // Builder::AiTaskRemoved.
    void OnTaskRemoved(IUnitTask@ task)
    {
        if (task !is null && task is fusionReclaimTask) @fusionReclaimTask = null;
    }

    // Every AFUS def gets the same cap; CCircuitDef::count is per def, so a side
    // only ever builds its own AFUS and this caps that side at `cap`.
    void SetAfusCap(int cap)
    {
        array<string> afus = UnitHelpers::GetAllAdvancedFusionReactors();
        for (uint i = 0; i < afus.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(afus[i]);
            if (d !is null) d.maxThisUnit = cap;
        }
    }

    void InitAfusGate(const Params@ p)
    {
        afusGateOpen = false;
        @fusionReclaimTask = null;
        PruneIds(@fusionIds);
        PruneIds(@afusIds);
        const int afusTotal = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllAdvancedFusionReactors());
        // After /aireload the tracked ids start empty: CircuitAI replays standing
        // units only when loading a savegame (CCircuitAI::Load), not in Init. So the
        // fusion count (built or under construction) opens the gate too; at game
        // start it is 0.
        const int fusTotal = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllFusionReactors());
        if (afusTotal > 0 || int(fusionIds.length()) >= p.fusionsBeforeAFUS || fusTotal >= p.fusionsBeforeAFUS) {
            afusGateOpen = true;   // already past step 2 (reloaded, or role switched in mid-game)
            SetAfusCap(p.maxAFUS);
            return;
        }
        SetAfusCap(0);
        GenericHelpers::LogUtil("[" + p.tag + "][Reactor] AFUS held until " + p.fusionsBeforeAFUS
            + " fusions are finished", 2);
    }

    void UpdateAfusGate(const Params@ p)
    {
        if (afusGateOpen) return;
        PruneIds(@fusionIds);
        if (int(fusionIds.length()) < p.fusionsBeforeAFUS) return;
        afusGateOpen = true;
        SetAfusCap(p.maxAFUS);
        GenericHelpers::LogUtil("[" + p.tag + "][Reactor] " + fusionIds.length() + " fusions finished: AFUS unlocked", 1);
    }

    // Current task builds a fusion, AFUS or advanced converter (see header).
    bool IsOnLadderBuild(CCircuitUnit@ u)
    {
        if (u is null) return false;
        IBuilderTask@ current = cast<IBuilderTask>(u.task);
        if (current is null || current.buildDef is null) return false;
        const string n = current.buildDef.GetName();
        return NameIn(n, UnitHelpers::GetAllFusionReactors())
            || NameIn(n, UnitHelpers::GetAllAdvancedFusionReactors())
            || NameIn(n, ADV_CONVERTERS);
    }

    IUnitTask@ TryReclaimFusion(const Params@ p)
    {
        if (fusionReclaimTask !is null) return null;   // one at a time
        for (uint i = 0; i < fusionIds.length(); ++i) {
            CCircuitUnit@ fus = ai.GetTeamUnit(fusionIds[i]);
            if (fus is null) continue;
            IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, fus, 120 * SECOND));
            if (t is null) return null;
            @fusionReclaimTask = t;
            GenericHelpers::LogUtil("[" + p.tag + "][Reactor] reclaiming fusion id=" + fus.id + " to fund the AFUS ("
                + fusionIds.length() + " fusion(s) left)", 1);
            return t;
        }
        return null;
    }

    // Advanced converter on surplus energy: energy at advConverterEnergyPercent of
    // storage, no stall, below convPerFusion / convPerAFUS per finished reactor.
    IUnitTask@ TryAdvConverter(CCircuitUnit@ u, const string &in side, const Params@ p, bool energyHigh,
            float energyPct, int fusFinished, int afusFinished)
    {
        if (p.holdConverters || !energyHigh || aiEconomyMgr.isEnergyStalling) return null;
        const int have = UnitDefHelpers::SumUnitDefCounts(ADV_CONVERTERS);
        const int want = fusFinished * p.convPerFusion + afusFinished * p.convPerAFUS;
        if (have >= want) return null;
        IUnitTask@ tConv = Builder::EnqueueAdvEnergyConverter(side, u.GetPos(ai.frame), SQUARE_SIZE * 32, SECOND * 300);
        if (tConv !is null) {
            GenericHelpers::LogUtil("[" + p.tag + "][Reactor] advanced converter " + (have + 1) + "/" + want
                + ", energy at " + int(energyPct * 100.0f) + "%", 2);
        }
        return tConv;
    }

    IUnitTask@ TryT2Economy(CCircuitUnit@ u, const Params@ p)
    {
        if (u is null || u.circuitDef is null || p is null) return null;
        const string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        const float mi = aiEconomyMgr.metal.income;
        PruneIds(@fusionIds);
        PruneIds(@afusIds);
        const int fusFinished = int(fusionIds.length());
        const int afusFinished = int(afusIds.length());
        const int fusTotal = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllFusionReactors());
        const int afusTotal = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllAdvancedFusionReactors());
        const int fusNeeded = p.fusionsBeforeAFUS;
        const float energyPct = (aiEconomyMgr.energy.storage > 0.0f)
            ? (aiEconomyMgr.energy.current / aiEconomyMgr.energy.storage) : 0.0f;
        const bool energyHigh = energyPct >= p.advConverterEnergyPercent;
        const AIFloat3 reactorPos = Factory::GetPreferredFactoryPos();

        // 1-2. Fusions, then the first AFUS once they are finished.
        if (afusTotal == 0) {
            if (fusTotal < fusNeeded && mi >= p.minMetalIncomeForFUS) {
                IUnitTask@ tFus = Builder::EnqueueFUS(side, reactorPos, SQUARE_SIZE * 32, SECOND * 300, p.reactorPrio, /*expireWhenAbandoned*/ true);
                if (tFus !is null) {
                    GenericHelpers::LogUtil("[" + p.tag + "][Reactor] fusion " + (fusTotal + 1) + "/" + fusNeeded + " queued", 2);
                    return tFus;
                }
            }
            // afusGateOpen covers fusions standing from before a reload (InitAfusGate).
            if (fusFinished >= fusNeeded || (afusGateOpen && fusTotal >= fusNeeded)) {
                UpdateAfusGate(p);
                IUnitTask@ tAfus = Builder::EnqueueAFUS(side, reactorPos, SQUARE_SIZE * 32, SECOND * 300, p.reactorPrio, /*expireWhenAbandoned*/ true);
                if (tAfus !is null) {
                    GenericHelpers::LogUtil("[" + p.tag + "][Reactor] first AFUS queued (" + fusFinished + " fusions finished)", 1);
                    return tAfus;
                }
            }
            // Advanced converters from the first finished fusion, same surplus-energy
            // rule as step 5. After the reactor steps: a builder only gets here when the
            // fusion / AFUS it would build is already queued (one of each at a time).
            IUnitTask@ tConvEarly = TryAdvConverter(u, side, p, energyHigh, energyPct, fusFinished, afusFinished);
            if (tConvEarly !is null) return tConvEarly;
            if (!p.assistReactor) return null;
            return Builder::EnqueueAssistReactor(Task::Priority::HIGH, 60 * SECOND);
        }

        // 3. The second AFUS is down: reclaim the fusions to fund it.
        if (afusTotal >= p.reclaimFusionsAtAFUSCount && fusFinished > 0) {
            IUnitTask@ tRecl = TryReclaimFusion(p);
            if (tRecl !is null) return tRecl;
        }

        // 4. The second AFUS goes up straight after the first, ahead of converters.
        const bool afusBuilding = afusTotal > afusFinished;
        const int afusBeforeReclaim = p.reclaimFusionsAtAFUSCount;
        if (!afusBuilding && afusFinished >= 1 && afusTotal < afusBeforeReclaim) {
            IUnitTask@ tAfus2 = Builder::EnqueueAFUS(side, reactorPos, SQUARE_SIZE * 32, SECOND * 300, p.reactorPrio, /*expireWhenAbandoned*/ true);
            if (tAfus2 !is null) {
                GenericHelpers::LogUtil("[" + p.tag + "][Reactor] AFUS " + (afusTotal + 1) + " queued; fusions will be reclaimed once it is down", 1);
                return tAfus2;
            }
        }

        // 5. Advanced converters on surplus energy.
        IUnitTask@ tConv = TryAdvConverter(u, side, p, energyHigh, energyPct, fusFinished, afusFinished);
        if (tConv !is null) return tConv;

        // 6. Later AFUS whenever the converters are eating what the reactors make.
        // Builder::EnqueueAFUS ignores maxThisUnit, so the cap is checked here too.
        if (!afusBuilding && afusTotal >= afusBeforeReclaim && !energyHigh && afusTotal < p.maxAFUS) {
            IUnitTask@ tAfus = Builder::EnqueueAFUS(side, reactorPos, SQUARE_SIZE * 32, SECOND * 300, p.reactorPrio, /*expireWhenAbandoned*/ true);
            if (tAfus !is null) {
                GenericHelpers::LogUtil("[" + p.tag + "][Reactor] AFUS " + (afusTotal + 1) + " queued (energy at "
                    + int(energyPct * 100.0f) + "%)", 1);
                return tAfus;
            }
        }

        // 7. Help finish whatever reactor is going up.
        if (!p.assistReactor) return null;
        return Builder::EnqueueAssistReactor(Task::Priority::HIGH, 60 * SECOND);
    }
}  // namespace ReactorLadder
