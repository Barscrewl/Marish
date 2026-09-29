// TECH's experimental build system: the whole builder sequence (D-066).
#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/unit_helpers.as"
#include "../helpers/unitdef_helpers.as"
#include "../helpers/map_helpers.as"
#include "../helpers/guard_helpers.as"
#include "../manager/builder.as"
#include "../manager/team_economy.as"
#include "../manager/factory.as"
#include "../manager/layout.as"
#include "../manager/eco_planner.as"
#include "../manager/eco_role.as"

/******************************************************************************

TECH BUILD (experimental build system, D-066)

When Global::RoleSettings::Tech::ExperimentalBuild is on, this namespace is
the only source of work for TECH's builders. Native's own chooser
(DefaultMakeTask) returns nothing for this AI instance, its start-factory and
storage jobs are silent, and its site search never spirals: a task's site is
a planned slot (the factory pair, the turret box), an exact spot (a mex, a
geo) or the free footprint nearest the anchor the script asked for
(PackNearPoint). Every other role, and TECH with the flag off, runs the
stock ladder and the stock placement untouched.

MakeTask never returns null: a builder with nothing to build assists,
guards the factory or waits, and is asked again.

The sequence, per asking builder:

  turret        reclaim in reach, then the economy under construction by the
                owner's order, then any structure under construction in
                reach, then wait
  any builder   keeps the construction it is on (native re-asks while it walks)
  commander     the opening (the nearest OpeningMexCap mexes), then the start
                factory on its reserved slot, then the planner
  constructor   the start factory if it is still missing, mex expansion while
                metal income is under EcoMexExpandUntilIncome, the T2 lab
                gate, the planner, the role's strategic rungs (nukes,
                anti-nuke, gantry, water factories, donations - their sites
                are packed near the anchor they name), native's queued orders
                (defence, sensors, repairs) when the script reaches them,
                then assist the nearest structure under construction, then
                guard the primary factory, then wait

******************************************************************************/
namespace TechBuild {

    // ---------------------------------------------------------------- pieces

    IUnitTask@ Wait(int frames)
    {
        return aiBuilderMgr.Enqueue(TaskB::Wait(frames));
    }

    // The construction the builder is on, when native re-asks (D-063 follow-up 3).
    dictionary keepTrace;
    IUnitTask@ KeepCurrent(CCircuitUnit@ u)
    {
        IBuilderTask@ cur = (u.task is null) ? null : cast<IBuilderTask>(u.task);
        const bool keep = (cur !is null && Task::BuildType(cur.GetBuildType()) < Task::BuildType::REPAIR);
        // diagnostic (D-070 benchmarks): what a re-asked builder holds, on change
        {
            const string sig = (u.task is null) ? "nothing" : (cur is null ? "a non-builder task" : ("build type " + int(cur.GetBuildType())
                + (cur.buildDef is null ? "" : " " + cur.buildDef.GetName()) + (keep ? " (kept)" : " (not kept)")));
            const string id = "" + u.id;
            string last; keepTrace.get(id, last);
            if (last != sig) { keepTrace.set(id, sig); GenericHelpers::LogUtil("[TECH][Keep] " + u.circuitDef.GetName() + " " + u.id + " asked holding " + sig, 3); }
        }
        if (keep) return u.task;
        return null;
    }

    // The first T1 bot lab is a throwaway (owner's rule: it is always
    // reclaimed once the advanced lab begins), so it goes where the commander
    // stands - the nearest buildable footprint within its build range -
    // rather than on the pair's planned slot, and no time is spent walking.
    // The footprint is reserved and the task pinned to it; once the lab
    // stands, an exit cone in front of it is held (Tick) until it is gone,
    // so nothing is packed where its units come out. A constructor building
    // the first lab (commander lost) takes the pair's reserved slot instead.
    int firstLabExitZone = 0;
    int t2LabExitZone = 0;        // D-074: the advanced lab's exit is held the same way

    // Progressing into T2: the advanced lab is ordered, framed or standing.
    // No T1 lab is ordered from then on - the first one is being reclaimed
    // to pay for it (played: the commander rebuilt the T1 lab beside the
    // advanced lab's frame the moment the reclaim emptied the count).
    // D-078: an advanced fusion exists as a frame or stands.
    bool IntoAfus()
    {
        CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(Global::AISettings::Side));
        return d !is null && (d.count > 0 || aiBuilderMgr.GetUnfinishedCount(d) > 0);
    }
    // ... is under construction now.
    bool AfusUnderWay()
    {
        CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(Global::AISettings::Side));
        return d !is null && aiBuilderMgr.GetUnfinishedCount(d) > 0;
    }
    // D-077: the one owner of "may this energy def still be ordered": no wind
    // or solar once a fusion stands (they are being reclaimed), no advanced
    // solar once an advanced fusion is under way. Registered as
    // Global::energyAllowed for the shared builder helpers and the planner.
    // D-077: an energy def whose era is over: wind and solar once a fusion
    // stands, advanced solar once an advanced fusion is under way. The chain
    // counts such a step as met (its structures were reclaimed on purpose).
    bool EnergyRetired(const string &in name)
    {
        const string side = Global::AISettings::Side;
        const bool t1 = (name == UnitHelpers::GetWindNameForSide(side)) || (name == UnitHelpers::GetSolarNameForSide(side));
        const bool adv = (name == UnitHelpers::GetAdvSolarNameForSide(side));
        if (!t1 && !adv) return false;
        CCircuitDef@ fus = ai.GetCircuitDef(UnitHelpers::GetFusionNameForSide(side));
        const bool fusionUp = (fus !is null && fus.count - aiBuilderMgr.GetUnfinishedCount(fus) > 0) || IntoAfus();
        return (t1 && fusionUp) || (adv && IntoAfus());
    }
    bool EnergyAllowed(const string &in name)
    {
        const string side = Global::AISettings::Side;
        const bool t1 = (name == UnitHelpers::GetWindNameForSide(side)) || (name == UnitHelpers::GetSolarNameForSide(side));
        const bool adv = (name == UnitHelpers::GetAdvSolarNameForSide(side));
        const bool big = (name == UnitHelpers::GetFusionNameForSide(side)) || (name == UnitHelpers::GetAdvFusionNameForSide(side));
        if (!t1 && !adv && !big) return true;
        // D-079: no energy structure of any tier while energy floats; the
        // surplus is converted and the AI chases metal
        if (TechChain::EnergyFloats()) return false;
        if (big) return true;
        CCircuitDef@ fus = ai.GetCircuitDef(UnitHelpers::GetFusionNameForSide(side));
        const bool fusionUp = (fus !is null && fus.count - aiBuilderMgr.GetUnfinishedCount(fus) > 0) || IntoAfus();
        if (t1 && fusionUp) return false;
        if (adv && IntoAfus()) return false;
        return true;
    }
    // D-075 (owner's rule, read from the bank): metal income is above spending
    // when the bank has sat at InvariantFloatPercent of storage for
    // PowerAheadSeconds or risen by PowerAheadRise over that window. The
    // engine's pull is inflated by the build in progress (played: a full bank
    // with income under the pull for a minute), so it is not read.
    array<float> metalBank;   // one sample a second, the last PowerAheadSeconds
    int metalFullSince = -1;
    void TrackMetal()
    {
        const float stor = aiEconomyMgr.metal.storage;
        const float cur = aiEconomyMgr.metal.current;
        const bool full = (stor > 0.0f) && (cur >= Global::RoleSettings::Tech::InvariantFloatPercent * stor);
        if (!full) metalFullSince = -1; else if (metalFullSince < 0) metalFullSince = ai.frame;
        metalBank.insertLast(cur);
        const uint keep = uint(Global::RoleSettings::Tech::PowerAheadSeconds) + 1;
        while (metalBank.length() > keep) metalBank.removeAt(0);
    }
    bool MetalFullLong() { return metalFullSince >= 0 && ai.frame - metalFullSince >= int(Global::RoleSettings::Tech::PowerAheadSeconds) * SECOND; }
    bool MetalRising() { return metalBank.length() >= 2 && metalBank[metalBank.length() - 1] - metalBank[0] >= Global::RoleSettings::Tech::PowerAheadRise; }
    bool MetalAhead() { return MetalFullLong() || MetalRising(); }
    string MetalAheadWhy()
    {
        if (MetalFullLong()) return "bank full for " + int((ai.frame - metalFullSince) / SECOND) + " s";
        if (MetalRising()) return "bank up " + int(metalBank[metalBank.length() - 1] - metalBank[0]) + " in " + int(metalBank.length() - 1) + " s";
        return "bank steady";
    }
    bool BankHasRoomFor(CCircuitUnit@ unit, float fallback)
    {
        const float metal = (unit is null || unit.circuitDef is null) ? fallback : unit.circuitDef.costM;
        return aiEconomyMgr.metal.current + metal <= aiEconomyMgr.metal.storage;
    }

    bool IntoT2()
    {
        CCircuitDef@ t2 = ai.GetCircuitDef(EcoRole::T2LabName(Global::AISettings::Side));   // AIR: the T2 aircraft plant
        if (t2 is null) return false;
        return t2.count > 0 || aiBuilderMgr.GetUnfinishedCount(t2) > 0
            || aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY), t2) > 0;
    }

    // D-116: the advanced lab has begun: a frame or a finished lab, not only an
    // order (played on All That Glitters, build99: the order's footprint was dead,
    // every order aborted, yet the throwaway T1 lab was retired and reclaimed for
    // an advanced lab that never had a frame, and TECH was left with no lab)
    bool T2Begun()
    {
        CCircuitDef@ t2 = ai.GetCircuitDef(EcoRole::T2LabName(Global::AISettings::Side));
        if (t2 is null) return false;
        return t2.count > 0 || aiBuilderMgr.GetUnfinishedCount(t2) > 0;
    }

    IUnitTask@ StartFactory(CCircuitUnit@ u)
    {
        if (!RoleTech::Opening::complete || IntoT2()) return null;
        if (!T1LabAllowed()) return null;   // D-102 (played: the chain's lab step reordered the T1 lab once the advanced lab was reclaimed)
        const string side = Global::AISettings::Side;
        CCircuitDef@ lab = ai.GetCircuitDef(EcoRole::T1LabName(side));   // AIR: the T1 aircraft plant
        if (lab is null || !u.circuitDef.CanBuild(lab)) return null;
        if (lab.count > 0 || aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY), lab) > 0) return null;
        // D-101 (owner's rule): only with no construction turret standing may the
        // lab go anywhere; with one, the layout places it
        if (Layout::TurretsStand()) {
            const int id = Layout::ReserveFactorySite(lab);
            if (id >= 0) {
                const AIFloat3 p = aiTerrainMgr.GetReservationPos(id);
                IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::NOW, lab, p, null, 0.0f, false, true, 300 * SECOND));
                if (t is null) { aiTerrainMgr.ReleaseReservation(id); return null; }
                if (!AiPinReservation(t, id)) GenericHelpers::LogUtil("[TECH][Build] could not pin the T1 lab to slot " + id, 1);
                return t;
            }
        }
        // AIR keeps its T1 plant for the game: it goes on the pair's planned
        // slot (its nano block behind it), not wherever the commander stands
        if (EcoRole::ReclaimsLabs() && UnitHelpers::IsCommander(u.circuitDef) && Layout::HasComplex()) {
            const AIFloat3 at = u.GetPos(ai.frame);
            const int facing = Layout::facing;
            const float step = SQUARE_SIZE * 2;
            const int rings = int(Global::RoleSettings::Tech::ExpFirstLabRadius / step);
            // Never under the commander itself: a factory ordered on top of its
            // builder has its command dropped by the engine on every try (the
            // builder is in the way), which looked like a glitching commander.
            // The footprint's half-extent plus the commander's body, so the
            // nearest ring keeps the whole footprint clear of it.
            const float clear = float(lab.GetFootprintX() > lab.GetFootprintZ() ? lab.GetFootprintX() : lab.GetFootprintZ()) * 0.5f * step
                + Global::RoleSettings::Tech::ExpFirstLabClearance;
            const int firstRing = int(clear / step) + 1;
            for (int r = firstRing; r <= rings; ++r) {
                const int n = 8 * r;
                for (int k = 0; k < n; ++k) {
                    const float a = 6.2831853f * float(k) / float(n);
                    AIFloat3 p = AIFloat3(at.x + cos(a) * float(r) * step, 0.0f, at.z + sin(a) * float(r) * step);
                    if (!aiTerrainMgr.CanReserveBuilding(lab, p, facing)) continue;
                    if (!aiTerrainMgr.IsExitClear(lab, p, facing, 320.0f, 32.0f)) continue;   // D-074: nothing stands or will stand in its exit
                    const int id = aiTerrainMgr.ReserveBuilding(lab, p, facing, 0);
                    if (id < 0) continue;
                    p = aiTerrainMgr.GetReservationPos(id);
                    IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::NOW, lab, p, null, 0.0f, false, true, 300 * SECOND));
                    if (t is null) { aiTerrainMgr.ReleaseReservation(id); return null; }
                    if (!AiPinReservation(t, id)) GenericHelpers::LogUtil("[TECH][Build] could not pin the first lab to slot " + id, 1);
                    GenericHelpers::LogUtil("[TECH][Build] first lab at the commander: (" + int(p.x) + ", " + int(p.z) + "), "
                        + int(sqrt(MapHelpers::SqDist(p, at))) + " from it; the pair's slot stays planned", 1);
                    return t;
                }
            }
            GenericHelpers::LogUtil("[TECH][Build] no footprint for the first lab within " + int(Global::RoleSettings::Tech::ExpFirstLabRadius)
                + " of the commander; the pair's slot is used", 1);
        }
        IUnitTask@ t = EcoRole::EnqueueT1Lab(side, Global::Map::StartPos, 0.0f, 300 * SECOND, Task::Priority::NOW);
        if (t !is null) GenericHelpers::LogUtil("[TECH][Build] start factory ordered on the reserved slot", 1);
        return t;
    }

    // D-102 (owner's rule): the economy is online at LabEcoOnlineMetalIncome;
    // from then on labs are not reclaimed for metal and T1 labs are for spam
    // D-105: latched: once the economy has been online it stays so (played: the
    // 10-second minimum dipped under 200 at +309 and the rebuilt advanced lab was
    // reclaimed; the owner: above +200 there is no economic reason to reclaim a factory)
    bool ecoOnlineLatched = false;
    int ecoOnlineFrame = -1;          // the frame it latched (INV-039 measures from it)
    bool EcoOnline()
    {
        if (!ecoOnlineLatched && Economy::GetMinMetalIncomeLast10s() >= Global::RoleSettings::Tech::LabEcoOnlineMetalIncome) {
            ecoOnlineLatched = true;
            ecoOnlineFrame = ai.frame;
            GenericHelpers::LogUtil("[TECH][Build] the economy is online (+" + int(Economy::GetMinMetalIncomeLast10s()) + " metal): no lab is reclaimed for metal from now on (D-102, D-105)", 1);
        }
        return ecoOnlineLatched;
    }

    // D-105 (owner's rule): the advanced lab is not reclaimed when the metal the
    // advanced fusion needs will be there anyway: bank + income x its remaining
    // build time (build power within AfusProjectionRadius) covers AfusFundedShare
    // of its cost
    bool AfusFunded(string &out why)
    {
        CCircuitDef@ ad = ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(Global::AISettings::Side));
        if (ad is null) { why = "no def"; return false; }
        CCircuitUnit@ fr = aiBuilderMgr.FindUnfinishedNear(Layout::BaseCentre(), Global::RoleSettings::Tech::ChainAssistRadius, ad);
        if (fr is null) { why = "no frame"; return false; }
        const float progress = fr.GetBuildProgress();
        const float bp = aiBuilderMgr.GetBuildPowerNear(fr.GetPos(ai.frame), Global::RoleSettings::Tech::AfusProjectionRadius);
        const float secs = (1.0f - progress) * Global::RoleSettings::Tech::AfusBuildTime / ((bp > 1.0f) ? bp : 1.0f);
        const float bank = aiEconomyMgr.metal.current;
        const float income = aiEconomyMgr.metal.income;
        const float earned = bank + income * secs;
        const float need = Global::RoleSettings::Tech::AfusFundedShare * ad.costM;
        why = "bank " + int(bank) + " + " + int(income) + "/s x " + int(secs) + " s (" + int(progress * 100.0f) + "% built, build power "
            + int(bp) + ") = " + int(earned) + " against " + int(need) + " (" + int(Global::RoleSettings::Tech::AfusFundedShare * 100.0f) + "% of " + int(ad.costM) + ")";
        return earned >= need;
    }

    // D-105 (owner's rule): a T2 constructor reclaims only as a last resort, when
    // no other build power (turrets, T1 constructors, the commander) is within
    // ReclaimOtherPowerRadius of the target; otherwise it keeps to its build orders
    bool T2MayReclaim(CCircuitUnit@ u, CCircuitUnit@ target)
    {
        if (u is null || u.circuitDef is null || UnitHelpers::GetConstructorTier(u.circuitDef) < 2) return true;
        if (target is null) return false;
        const string side = Global::AISettings::Side;
        CCircuitDef@ t2b = ai.GetCircuitDef(UnitHelpers::GetT2BotConstructors(side)[0]);
        CCircuitDef@ t2a = ai.GetCircuitDef(UnitHelpers::GetT2AirConstructorNameForSide(side));
        const float other = aiBuilderMgr.GetBuildPowerNearExcept(target.GetPos(ai.frame), Global::RoleSettings::Tech::ReclaimOtherPowerRadius, t2b, t2a, target);
        return other <= 0.0f;
    }
    int T1Cons()
    {
        return UnitDefHelpers::SumUnitDefCounts(EcoRole::AllT1Cons());
    }
    // D-102: the T2 phase has begun at least once (the advanced lab reclaimed later
    // does not reopen the opening)
    bool everIntoT2 = false;
    int fundedLoggedFor = -1;   // D-105
    bool WasIntoT2() { if (!everIntoT2 && IntoT2()) everIntoT2 = true; return everIntoT2; }
    // D-102 (owner's rule): a T1 lab after the first: always for a restart (no
    // constructor of any tier left); else only with an advanced lab standing, and
    // with fewer than LabRebuildMinT1Cons T1 constructors or the economy online
    bool T1LabAllowed()
    {
        if (!WasIntoT2()) return true;
        const int cons = T1Cons() + UnitDefHelpers::SumUnitDefCounts(EcoRole::AllT2Cons());
        if (cons == 0) return true;
        if (UnitDefHelpers::SumUnitDefCounts(EcoRole::AllT2Labs()) == 0) return false;
        return T1Cons() < Global::RoleSettings::Tech::LabRebuildMinT1Cons || EcoOnline();
    }
    // D-102 (owner's rule): the lab native asks for when our last factory is gone
    // (isReset). Below the online income with LabRebuildMinT1Cons T1 constructors,
    // none: the constructors build, and the labs were torn down to feed the
    // economy. Otherwise the advanced lab first; a T1 lab only once one stands.
    // "" = none.
    string ResetFactory()
    {
        const string side = Global::AISettings::Side;
        if (T1Cons() >= Global::RoleSettings::Tech::LabRebuildMinT1Cons && !EcoOnline()) {
            GenericHelpers::LogUtil("[TECH][Build] last factory gone: no lab rebuilt (" + T1Cons() + " T1 constructors, +"
                + int(Economy::GetMinMetalIncomeLast10s()) + " metal under " + int(Global::RoleSettings::Tech::LabEcoOnlineMetalIncome) + ") (D-102)", 1);
            return "";
        }
        CCircuitDef@ t2 = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(side));
        if (t2 !is null && t2.IsAvailable(ai.frame) && UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs()) == 0) {
            GenericHelpers::LogUtil("[TECH][Build] last factory gone: the advanced lab first (D-102)", 1);
            return t2.GetName();
        }
        return UnitHelpers::GetT1BotLabForSide(side);
    }

    // D-107 (owner's rule): the first two T2 air constructors are dedicated: one
    // only ever builds advanced energy converters, the other only advanced
    // fusions. A role freed by a death goes to the next air constructor that asks.
    int airConvId = -1;
    int airAfusId = -1;
    bool IsT2AirCon(CCircuitUnit@ u)
    {
        return u !is null && u.circuitDef !is null && u.circuitDef.GetName() == UnitHelpers::GetT2AirConstructorNameForSide(Global::AISettings::Side);
    }
    // D-108: every T2 air constructor seen, so a freed role is handed on at once
    dictionary airConsSeen;
    // AIR (manager/eco_role.as): every T2 constructor is an air constructor, so
    // the first Air::ChainT2Constructors of them are what TECH's T2 bot
    // constructors are - the chain's mohos, then the fusion, then the advanced
    // fusion, and the mex upgrades - and never hold a dedicated role; only those
    // beyond them do (played, All That Glitters 2026-09-28: AIR's first two T2
    // air constructors took the advanced fusion and converter roles, no T1 mex
    // was upgraded and the advanced fusion went up at +26 metal). A chain
    // constructor lost is replaced by the next T2 air constructor that asks.
    dictionary airChainCons;
    bool IsAirChainCon(CCircuitUnit@ u)
    {
        if (!EcoRole::IsAir() || !IsT2AirCon(u)) return false;
        const string key = "" + u.id;
        if (airChainCons.exists(key)) return true;
        if (u.id == airConvId || u.id == airAfusId) return false;   // a dedicated builder keeps its role
        int alive = 0;
        array<string>@ keys = airChainCons.getKeys();
        for (uint i = 0; keys !is null && i < keys.length(); ++i) {
            if (ai.GetTeamUnit(parseInt(keys[i])) is null) airChainCons.delete(keys[i]);
            else ++alive;
        }
        if (alive >= Global::RoleSettings::Air::ChainT2Constructors) return false;
        airChainCons.set(key, ai.frame);
        GenericHelpers::LogUtil("[AIR][Eco] " + u.circuitDef.GetName() + " " + u.id + " is chain constructor " + (alive + 1) + "/"
            + Global::RoleSettings::Air::ChainT2Constructors + ": mohos, fusion, advanced fusion, as TECH's T2 constructors", 1);
        return true;
    }
    // D-108: a role whose builder is gone goes at once to another T2 air
    // constructor of ours that holds no role
    // D-108: a builder handed a role drops a job of another kind at once
    // (keep.current would otherwise finish it first; played: the new advanced
    // fusion builder was still on a converter)
    void DropOtherJob(int id, int role)
    {
        CCircuitUnit@ u = ai.GetTeamUnit(id);
        if (u is null || u.task is null) return;
        IBuilderTask@ bt = cast<IBuilderTask>(u.task);
        if (bt is null || bt.buildDef is null) return;
        const string side = Global::AISettings::Side;
        const string own = (role == 1) ? UnitHelpers::GetAdvEnergyConverterNameForSide(side) : UnitHelpers::GetAdvFusionNameForSide(side);
        if (bt.buildDef.GetName() == own) return;
        GenericHelpers::LogUtil("[TECH][Air] " + id + " drops " + bt.buildDef.GetName() + " for its role (D-108)", 1);
        aiBuilderMgr.AbortTask(u.task);
    }
    void RefillAirRoles()
    {
        if (airConvId >= 0 && ai.GetTeamUnit(airConvId) is null) { airConvId = -1; GenericHelpers::LogUtil("[TECH][Air] the converter builder is gone (D-108)", 1); }
        if (airAfusId >= 0 && ai.GetTeamUnit(airAfusId) is null) { airAfusId = -1; GenericHelpers::LogUtil("[TECH][Air] the advanced fusion builder is gone (D-108)", 1); }
        if (airConvId >= 0 && airAfusId >= 0) return;
        array<string>@ keys = airConsSeen.getKeys();
        for (uint i = 0; keys !is null && i < keys.length(); ++i) {
            const int id = parseInt(keys[i]);
            CCircuitUnit@ cand = ai.GetTeamUnit(id);
            if (cand is null) { airConsSeen.delete(keys[i]); continue; }
            if (id == airConvId || id == airAfusId) continue;
            // the advanced fusions first: the role that stalled the economy (D-108)
            if (airAfusId < 0) { airAfusId = id; GenericHelpers::LogUtil("[TECH][Air] " + id + " takes over the advanced fusions (D-108)", 1); DropOtherJob(id, 2); }
            else if (airConvId < 0) { airConvId = id; GenericHelpers::LogUtil("[TECH][Air] " + id + " takes over the converters (D-108)", 1); DropOtherJob(id, 1); }
            if (airConvId >= 0 && airAfusId >= 0) return;
        }
    }
    bool AirRoleVacant() { RefillAirRoles(); return airConvId < 0 || airAfusId < 0; }
    bool IsDedicatedAirCon(CCircuitUnit@ u) { return u !is null && (u.id == airConvId || u.id == airAfusId); }
    // D-108: a newly finished air constructor fills a vacant role before anything
    // else (the donation) can take it
    bool ClaimOnBuilt(CCircuitUnit@ u)
    {
        if (!IsT2AirCon(u)) return false;
        return AirConRole(u) != 0;
    }

    // 1: converters, 2: advanced fusions, 0: not dedicated (the role is claimed here)
    int AirConRole(CCircuitUnit@ u)
    {
        if (!IsT2AirCon(u)) return 0;
        if (IsAirChainCon(u)) return 0;   // AIR: never seen as a candidate for a role
        airConsSeen.set("" + u.id, ai.frame);
        RefillAirRoles();
        if (u.id == airConvId) return 1;
        if (u.id == airAfusId) return 2;
        if (airConvId < 0) {
            airConvId = u.id;
            GenericHelpers::LogUtil("[TECH][Air] " + u.circuitDef.GetName() + " " + u.id + " is dedicated to advanced energy converters (D-107)", 1);
            return 1;
        }
        if (airAfusId < 0) {
            airAfusId = u.id;
            GenericHelpers::LogUtil("[TECH][Air] " + u.circuitDef.GetName() + " " + u.id + " is dedicated to advanced fusions (D-107)", 1);
            return 2;
        }
        return 0;
    }
    // D-107: the converters cannot stay on (the bank under
    // ConverterStarveEnergyShare of storage, or stalling)
    bool ConvertersStarve()
    {
        const float s = aiEconomyMgr.energy.storage;
        return aiEconomyMgr.isEnergyStalling || (s > 0.0f && aiEconomyMgr.energy.current < Global::RoleSettings::Tech::ConverterStarveEnergyShare * s);
    }
    IUnitTask@ AssistNearestOf(CCircuitUnit@ u, const string &in defName)
    {
        CCircuitDef@ d = ai.GetCircuitDef(defName);
        if (d is null) return null;
        CCircuitUnit@ fr = aiBuilderMgr.FindUnfinishedNear(u.GetPos(ai.frame), Global::RoleSettings::Tech::ChainAssistRadius, d);
        if (fr is null) return null;
        return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, fr, 60 * SECOND));
    }
    IUnitTask@ BuildByLayout(CCircuitUnit@ u, const string &in defName, Task::BuildType type)
    {
        CCircuitDef@ d = ai.GetCircuitDef(defName);
        if (d is null || !d.IsAvailable(ai.frame) || !u.circuitDef.CanBuild(d)) return null;
        return Layout::Place(type, Task::Priority::HIGH, d, 300 * SECOND, u);
    }
    // the dedicated two: always their own structure (assist their own kind's
    // frame when the layout has no site). D-108: never anything else: with no
    // site and no frame they wait, and say why (played: the advanced fusion
    // builder fell through to converters and turrets, and the advanced fusions
    // stopped at six)
    int airWaitLog = -100000;
    // D-108 (played: the advanced fusions stopped at six): TECH's start caps
    // (StartCapAdvancedFusionReactors 0) and the rush chain's step target (1)
    // pin maxThisUnit, so the dedicated builder's structure read "not available
    // (2 of 1)" while other paths, which do not check it, built a few more. A
    // held role's structure is always one short of its cap.
    void LiftCapForRole(const string &in name)
    {
        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (d is null || d.maxThisUnit > d.count) return;
        d.maxThisUnit = d.count + 1;
        GenericHelpers::LogUtil("[TECH][Air] " + name + " cap lifted to " + d.maxThisUnit + " for its dedicated builder (D-108)", 2);
    }
    IUnitTask@ AirDedicated(CCircuitUnit@ u)
    {
        const string side = Global::AISettings::Side;
        const int role = AirConRole(u);
        if (role == 0) return null;
        const string name = (role == 1) ? UnitHelpers::GetAdvEnergyConverterNameForSide(side) : UnitHelpers::GetAdvFusionNameForSide(side);
        LiftCapForRole(name);
        IUnitTask@ t = BuildByLayout(u, name, (role == 1) ? Task::BuildType::CONVERT : Task::BuildType::ENERGY);
        if (t is null) @t = AssistNearestOf(u, name);
        if (t !is null) return t;
        if (ai.frame - airWaitLog > 30 * SECOND) {
            airWaitLog = ai.frame;
            CCircuitDef@ d = ai.GetCircuitDef(name);
            string why = (d is null) ? "no def" : (!d.IsAvailable(ai.frame) ? ("not available (" + d.count + " of " + d.maxThisUnit + ")")
                : (!u.circuitDef.CanBuild(d) ? "cannot build it" : "no site in the layout"));
            GenericHelpers::LogUtil("[TECH][Air] dedicated " + u.id + " waits for " + name + ": " + why + " (D-108)", 1);
        }
        return Wait(3 * SECOND);
    }
    // the rest of the T2 air constructors: converters while energy overflows; the
    // advanced fusion going up the moment the converters cannot stay on
    IUnitTask@ AirFlexible(CCircuitUnit@ u)
    {
        if (!IsT2AirCon(u) || IsAirChainCon(u) || AirConRole(u) != 0) return null;
        const string side = Global::AISettings::Side;
        if (ConvertersStarve()) return AssistNearestOf(u, UnitHelpers::GetAdvFusionNameForSide(side));
        if (TechChain::EnergyFloats()) return BuildByLayout(u, UnitHelpers::GetAdvEnergyConverterNameForSide(side), Task::BuildType::CONVERT);
        return null;
    }

    // D-106 (owner's rule): a fallback so no metal is lost to overflow when our
    // build power cannot keep up: whenever the metal bank is over
    // TeamShareMetalAbove of storage, refresh every teammate's economy and give
    // up to TeamShareMetalBudget of our storage, the lowest-filled live teammate
    // first, each filled up to its free storage
    int teamShareFrame = -100000;
    int teamShareLog = -100000;
    bool firstLabStood = false;
    int verifyFrame = -1;          // one check after a donation: did it arrive
    array<int> verifyTeams;
    void VerifyShare()
    {
        if (verifyFrame < 0 || ai.frame < verifyFrame) return;
        verifyFrame = -1;
        string line = "";
        for (uint i = 0; i < verifyTeams.length(); ++i) {
            TeamEconomy::UpdateTeam(verifyTeams[i]);
            line += (line.length() > 0 ? ", " : "") + "team " + verifyTeams[i] + " received " + int(TeamEconomy::Metal(verifyTeams[i], TeamEconomy::RECEIVED))
                + " (bank " + int(TeamEconomy::Metal(verifyTeams[i], TeamEconomy::CURRENT)) + ")";
        }
        GenericHelpers::LogUtil("[TECH][Share] after the donation: we sent " + int(TeamEconomy::OwnMetal(TeamEconomy::SENT)) + "; " + line + " (D-106)", 1);
    }
    void ShareOverflow()
    {
        VerifyShare();
        RefillAirRoles();                                  // D-108
        if (airConvId >= 0) LiftCapForRole(UnitHelpers::GetAdvEnergyConverterNameForSide(Global::AISettings::Side));   // D-108
        if (airAfusId >= 0) LiftCapForRole(UnitHelpers::GetAdvFusionNameForSide(Global::AISettings::Side));           // D-108
        if (airAfusId >= 0) Layout::HoldAfusSetAhead();    // D-108
        const float stor = aiEconomyMgr.metal.storage;
        const float cur = aiEconomyMgr.metal.current;
        // not the start bank: until the first lab has stood a full bank is the
        // opening's metal, not overflow (played: 420 metal given away at 15 s;
        // the opening's own flag was already set)
        if (!firstLabStood) {
            CCircuitDef@ l1 = ai.GetCircuitDef(EcoRole::T1LabName(Global::AISettings::Side));
            if (l1 !is null && l1.count > aiBuilderMgr.GetUnfinishedCount(l1)) firstLabStood = true;
        }
        if (!firstLabStood && !WasIntoT2()) return;
        if (stor <= 0.0f || cur < Global::RoleSettings::Tech::TeamShareMetalAbove * stor) return;
        if (ai.frame - teamShareFrame < int(Global::RoleSettings::Tech::TeamShareCheckSeconds * SECOND)) return;
        teamShareFrame = ai.frame;
        const int n = TeamEconomy::UpdateAll();
        array<int> ids;
        array<float> fills;
        for (int i = 0; i < n; ++i) {
            const int tid = TeamEconomy::TeamAt(i);
            if (tid < 0 || !TeamEconomy::Alive(tid) || TeamEconomy::Metal(tid, TeamEconomy::FREE) < Global::RoleSettings::Tech::TeamShareMinAmount) continue;
            // insertion by fill, lowest first
            const float f = TeamEconomy::MetalFill(tid);
            uint at = 0;
            while (at < fills.length() && fills[at] <= f) ++at;
            ids.insertAt(at, tid);
            fills.insertAt(at, f);
        }
        float budget = Global::RoleSettings::Tech::TeamShareMetalBudget * stor;
        if (budget > cur) budget = cur;
        string sent = "";
        for (uint i = 0; i < ids.length() && budget >= Global::RoleSettings::Tech::TeamShareMinAmount; ++i) {
            float give = TeamEconomy::Metal(ids[i], TeamEconomy::FREE);
            if (give > budget) give = budget;
            if (give < Global::RoleSettings::Tech::TeamShareMinAmount) continue;
            if (!TeamEconomy::SendMetal(ids[i], give)) continue;
            budget -= give;
            if (verifyFrame < 0) { verifyTeams.resize(0); verifyFrame = ai.frame + 45; }   // after the engine's next slow update
            verifyTeams.insertLast(ids[i]);
            sent += (sent.length() > 0 ? ", " : "") + int(give) + " to team " + ids[i] + " (" + int(fills[i] * 100.0f) + "% full)";
        }
        if (sent.length() > 0 || ai.frame - teamShareLog > 60 * SECOND) {
            teamShareLog = ai.frame;
            GenericHelpers::LogUtil("[TECH][Share] metal " + int(cur) + " of " + int(stor) + " (" + int(cur * 100.0f / stor) + "%): "
                + ((sent.length() > 0) ? ("sent " + sent) : ("no teammate with room (" + n + " teammates)"))
                + "; the engine counts " + int(TeamEconomy::OwnMetal(TeamEconomy::SENT)) + " metal sent in the last update (D-106)", 1);
        }
    }

    // From Tech_EconomyUpdate: the first lab's exit cone, held while it stands.
    void Tick()
    {
        TrackMetal();   // D-075
        ShareOverflow();   // D-106
        TechRules::Census();   // level 1, every CensusSeconds: what each builder and turret is on
        // AIR keeps its plants and has no land constructors to send forward:
        // no lab retirement, no forward or spam work (manager/eco_role.as)
        if (!EcoRole::ReclaimsLabs()) return;
        TechForward::Tick();   // D-109
        // D-076: the T1 lab retires the moment the advanced lab is under way.
        // One state, read by every actor: production stops (Lifecycle::Retire
        // stops the unit, the factory rows return nothing), guards and the
        // commander's help end, only the reclaim touches it (lab.t1.reclaim).
        if (T2Begun() && !throwawayDecided) {   // D-116: a frame, not an order
            // the throwaway is the lab standing when the advanced lab begins;
            // any T1 lab built later (lab.t1.spam) is a keeper (played: spam
            // labs were retired the moment they became the primary lab)
            throwawayDecided = true;
            throwawayLabId = (Factory::primaryT1BotLab is null) ? -2 : Factory::primaryT1BotLab.id;
        }
        CCircuitUnit@ tlab = Factory::primaryT1BotLab;
        // D-102: not once the economy is online (reclaiming a lab for metal is pointless late)
        if (tlab !is null && tlab.id == throwawayLabId && !Lifecycle::IsRetiring(tlab) && !EcoOnline()) {
            if (tlab.task !is null) aiFactoryMgr.AbortTask(tlab.task);   // native's recruit task would re-issue the build on idle
            Lifecycle::Retire(tlab, "the advanced lab is under way; the throwaway T1 lab is reclaimed (D-066)");
        }
        // D-078 (owner's rule): the advanced lab retires the moment an advanced
        // fusion is under construction and the bank has room for its metal
        {
            CCircuitUnit@ t2 = Factory::primaryT2BotLab;
            string fundedWhy;
            const bool funded = (t2 !is null) && AfusUnderWay() && AfusFunded(fundedWhy);   // D-105
            if (funded && t2 !is null && t2.id != fundedLoggedFor) {
                fundedLoggedFor = t2.id;
                GenericHelpers::LogUtil("[TECH][Build] the advanced lab is kept: the advanced fusion is funded without it: " + fundedWhy + " (D-105)", 1);
            }
            const bool due = (t2 !is null) && AfusUnderWay() && BankHasRoomFor(t2, 2500.0f) && !EcoOnline() && !funded;   // D-102, D-105
            if (due && !Lifecycle::IsRetiring(t2)) {
                if (t2.task !is null) aiFactoryMgr.AbortTask(t2.task);
                Lifecycle::Retire(t2, "an advanced fusion is under construction and the bank has room for the lab's metal (D-078)");
            }
            // INV-007: it never stays active while that holds
            if (due && !Lifecycle::IsRetiring(t2)) {
                if (t2DueSince < 0) t2DueSince = ai.frame;
                else if (ai.frame - t2DueSince >= int(Global::RoleSettings::Tech::InvariantT2ReclaimSeconds) * SECOND)
                    Invariants::Violation("INV-007", "" + t2.id, "advanced lab " + t2.id + " is active while an advanced fusion is under construction and the bank has room");
            } else t2DueSince = -1;
        }
        // INV-005: only the throwaway T1 lab is ever retired
        if (tlab !is null && tlab.id != throwawayLabId && Lifecycle::IsRetiring(tlab))
            Invariants::Violation("INV-005", "" + tlab.id, "T1 lab " + tlab.id + " is retiring but the throwaway is " + throwawayLabId);
        if (!Global::RoleSettings::Tech::ExperimentalBuild) return;
        CCircuitUnit@ lab = Factory::primaryT1BotLab;
        if (firstLabExitZone == 0 && lab !is null && Layout::HasComplex()) {
            firstLabExitZone = aiTerrainMgr.ReserveExitCone(lab, 320.0f, 32.0f);
            if (firstLabExitZone > 0) GenericHelpers::LogUtil("[TECH][Build] first lab's exit held (zone " + firstLabExitZone + ") until it is reclaimed", 1);
        } else if (firstLabExitZone > 0 && lab is null) {
            aiTerrainMgr.ReleaseZone(firstLabExitZone);
            GenericHelpers::LogUtil("[TECH][Build] first lab gone: its exit (zone " + firstLabExitZone + ") released", 1);
            firstLabExitZone = 0;
        }
        CCircuitUnit@ t2lab = Factory::primaryT2BotLab;
        if (t2LabExitZone == 0 && t2lab !is null && Layout::HasComplex()) {
            t2LabExitZone = aiTerrainMgr.ReserveExitCone(t2lab, 320.0f, 32.0f);
            if (t2LabExitZone > 0) GenericHelpers::LogUtil("[TECH][Build] advanced lab's exit held (zone " + t2LabExitZone + ")", 1);
        } else if (t2LabExitZone > 0 && t2lab is null) {
            aiTerrainMgr.ReleaseZone(t2LabExitZone);
            t2LabExitZone = 0;
        }
    }

    // The T1 bot lab is reclaimed the moment the advanced lab's frame exists
    // (owner's rule): every idle builder within `radius` of it joins the one
    // native reclaim task, turrets in reach put it before anything else
    // (Tech_TurretAssist), and the metal pays for the T2 lab.
    // D-078 (owner's rule): whenever a reclaim is ordered, every construction
    // turret in range stops what it does and joins it now (native
    // TurretsOnReclaim). Targets are remembered for INV-008.
    dictionary reclaimTargets;    // unit id -> frame of the order
    dictionary turretsPulledAt;   // unit id -> frame the turrets were pulled
    void PullTurrets(CCircuitUnit@ target)
    {
        if (target is null || target.circuitDef is null) return;
        const string key = "" + target.id;
        reclaimTargets.set(key, int64(ai.frame));
        int64 last = -100000; turretsPulledAt.get(key, last);
        if (ai.frame - int(last) < 30 * SECOND) return;
        turretsPulledAt.set(key, int64(ai.frame));
        const int n = aiBuilderMgr.TurretsOnReclaim(target.id, Global::RoleSettings::Tech::ReclaimTurretMargin, true);
        GenericHelpers::LogUtil("[TECH][Reclaim] " + n + " turret(s) pulled onto " + target.circuitDef.GetName() + " " + target.id, (n > 0) ? 1 : 3);
    }

    int t1LabReclaimId = -1;
    int reclaimDeferLog = -100000;
    int throwawayLabId = -1;      // D-076: the T1 lab standing when the advanced lab began; -2 = none
    int t2DueSince = -1;          // D-078: INV-007 clock
    bool throwawayDecided = false;

    IUnitTask@ ReclaimT1Lab(CCircuitUnit@ u, float radius)
    {
        CCircuitUnit@ lab = Factory::primaryT1BotLab;
        if (lab is null || lab is u) return null;
        if (lab.id != throwawayLabId) return null;   // D-076: only the throwaway lab; a later spam lab is a keeper
        if (!T2MayReclaim(u, lab)) return null;   // D-105: T2 constructors only as a last resort
        CCircuitDef@ t2 = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(Global::AISettings::Side));
        if (t2 is null) return null;
        if (!T2Begun()) return null;   // not begun yet (D-116: a frame, not an order)
        // D-072: reclaimed metal past the storage cap is lost, so the reclaim
        // waits until the bank has room for the lab's metal (the advanced lab's
        // build makes that room; it is part-built by then, as intended)
        {
            const float labMetal = (lab.circuitDef is null) ? 500.0f : lab.circuitDef.costM;
            if (aiEconomyMgr.metal.current + labMetal > aiEconomyMgr.metal.storage) {
                if (ai.frame - reclaimDeferLog > 30 * SECOND) {
                    reclaimDeferLog = ai.frame;
                    GenericHelpers::LogUtil("[TECH][Build] T1 lab reclaim deferred: metal " + int(aiEconomyMgr.metal.current) + " of "
                        + int(aiEconomyMgr.metal.storage) + " leaves no room for its " + int(labMetal), 1);
                }
                return null;
            }
        }
        if (MapHelpers::SqDist(u.GetPos(ai.frame), lab.GetPos(ai.frame)) > radius * radius) return null;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, lab, 180 * SECOND));
        if (t !is null) PullTurrets(lab);   // D-078
        if (t !is null && t1LabReclaimId != lab.id) {
            t1LabReclaimId = lab.id;
            GenericHelpers::LogUtil("[TECH][Build] the advanced lab is under way: reclaiming the T1 bot lab " + lab.id
                + "; idle build power in range joins", 1);
        }
        return t;
    }

    // Mex expansion for constructors: the nearest open spot the builder can
    // reach within EcoMexExpandRadius, outside allied ground, while metal
    // income is the bottleneck. The commander never expands after the opening.
    int lastNoSpotLog = -100000;

    IUnitTask@ ExpandMex(CCircuitUnit@ u, float metalIncome)
    {
        if (metalIncome >= Global::RoleSettings::Tech::EcoMexExpandUntilIncome) return null;
        // Cap 0: every spot inside the radius is considered, nearest the
        // builder first, until an open one is found. Played with cap 1 the
        // call looked at the single nearest spot, found it taken, and the base
        // sat on two mexes all game.
        IUnitTask@ t = aiEconomyMgr.EnqueueMexWithin(u, u.GetPos(ai.frame),
            Global::RoleSettings::Tech::EcoMexExpandRadius, 0, true);
        if (t !is null) {
            IBuilderTask@ order = cast<IBuilderTask>(t);
            AIFloat3 at = u.GetPos(ai.frame);
            if (order !is null) at = order.GetBuildPos();
            GenericHelpers::LogUtil("[TECH][Build] " + u.circuitDef.GetName() + " " + u.id + " expands to a mex at ("
                + int(at.x) + ", " + int(at.z) + ") at +" + int(metalIncome) + " metal", 1);
        } else if (ai.frame - lastNoSpotLog > 60 * SECOND) {
            lastNoSpotLog = ai.frame;
            GenericHelpers::LogUtil("[TECH][Build] no open mex spot within " + int(Global::RoleSettings::Tech::EcoMexExpandRadius)
                + " of " + u.circuitDef.GetName() + " " + u.id + " at +" + int(metalIncome) + " metal", 1);
        }
        return t;
    }

    // Native's queued orders the script chooses to honour: only the watchdog's
    // repairs of our own unfinished structures, nearest first and within
    // ExpOrderRadius of the base. Defence, radar and sonar orders native
    // queues on its own schedule are left alone (played: three junos, radars
    // 4,000 elmos out); TECH's base defence is the Defence rung below.
    IUnitTask@ QueuedOrder(CCircuitUnit@ u)
    {
        array<int> types = { int(Task::BuildType::REPAIR) };
        const AIFloat3 home = Layout::BaseCentre();
        const float radius = Global::RoleSettings::Tech::ExpOrderRadius;
        for (uint i = 0; i < types.length(); ++i) {
            IUnitTask@ t = aiBuilderMgr.FindQueuedTask(u, types[i]);
            if (t is null) continue;
            IBuilderTask@ bt = cast<IBuilderTask>(t);
            if (bt !is null) {
                const AIFloat3 at = bt.GetBuildPos();
                if (at.x >= 0.0f && MapHelpers::SqDist(at, home) > radius * radius) continue;
            }
            return t;
        }
        return null;
    }

    // Base defence (D-066 follow-up 9): once the first construction turret
    // stands, one light laser turret and one light AA turret near the
    // factories, packed by native nearest that anchor outside the planned
    // zones. Nothing more: TECH is a back-line role and the rest is the
    // team's.
    array<int> defenceOrders = { 0, 0 };   // D-075: orders per def; native refusing the site ExpDefenceMaxOrders times ends the rung
    IUnitTask@ Defence(CCircuitUnit@ u)
    {
        if (aiBuilderMgr.GetStaticBuildPowerNear(Layout::BaseCentre(), Global::RoleSettings::Tech::EcoBuildPowerRadius) <= 0.0f)
            return null;   // the first turret first
        const string side = Global::AISettings::Side;
        array<string> names = { UnitHelpers::GetStaticLLTNameForSide(side), UnitHelpers::GetStaticAALightNameForSide(side) };
        array<int> wanted = { Global::RoleSettings::Tech::ExpDefenceLLT, Global::RoleSettings::Tech::ExpDefenceAA };
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ def = ai.GetCircuitDef(names[i]);
            if (def is null || !def.IsAvailable(ai.frame) || !u.circuitDef.CanBuild(def)) continue;
            if (def.count + aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::DEFENCE), def) >= wanted[i]) continue;
            if (defenceOrders[i] >= Global::RoleSettings::Tech::ExpDefenceMaxOrders) continue;
            AIFloat3 anchor = Layout::factoryCentre;
            if (anchor.x < 0.0f) anchor = Global::Map::StartPos;
            IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::DEFENCE, Task::Priority::NORMAL, def, anchor, Global::RoleSettings::Tech::ExpDefenceRadius, true, 120 * SECOND));
            if (t !is null) { defenceOrders[i]++; GenericHelpers::LogUtil("[TECH][Build] base defence: " + names[i] + " near the factories (order " + defenceOrders[i] + " of " + Global::RoleSettings::Tech::ExpDefenceMaxOrders + ")", 1); }
            return t;
        }
        return null;
    }

    // D-077 (owner's rule): winds and solars are reclaimed once a fusion
    // stands and energy income without them still covers the pull by
    // ReclaimT1EnergyMargin; advanced solars once income without every T1 and
    // advanced-solar source covers it by ReclaimAdvSolarMargin; an advanced
    // fusion reclaims all of them. Nearest the base centre first, so the
    // middle of the layout is freed for the fusion era. Per-unit output:
    // solar 20, advanced solar 75, turbine the map's expected wind.
    dictionary reclaimInFlight;   // unit id -> frame ordered
    int ReclaimsInFlight()
    {
        array<string>@ keys = reclaimInFlight.getKeys();
        int n = 0;
        for (uint i = 0; keys !is null && i < keys.length(); ++i) {
            int64 at = 0; reclaimInFlight.get(keys[i], at);
            // gone (reclaimed) or stale: no longer in flight (played: 28 turbines took
            // twenty minutes with two slots held 90 s each)
            if (ai.frame - int(at) > 90 * SECOND || ai.GetTeamUnit(int(parseInt(keys[i]))) is null) reclaimInFlight.delete(keys[i]); else ++n;
        }
        return n;
    }
    // D-101: the reactors that stand finished (a def's count includes its frames;
    // played: an advanced fusion frame counted as standing, 29 turbines were
    // reclaimed with no reactor finished, energy fell to +123 and the frame never
    // finished)
    int FinishedOf(const string &in name)
    {
        CCircuitDef@ d = ai.GetCircuitDef(name);
        return (d is null) ? 0 : (d.count - aiBuilderMgr.GetUnfinishedCount(d));
    }
    bool ReactorStands()
    {
        const string side = Global::AISettings::Side;
        return FinishedOf(UnitHelpers::GetFusionNameForSide(side)) + FinishedOf(UnitHelpers::GetAdvFusionNameForSide(side)) > 0;
    }
    // AIR: its T1 energy converters are reclaimed once
    // Air::RetireT1ConvertersAtAdvConverters advanced converters stand finished,
    // or an advanced fusion does, and never built again (EcoPlanner::PickConverter);
    // AIR's eco retirement before TECH's economy. TECH never reclaims its T1
    // converters (it builds them only under BuildT1ConvertersUntilMetalIncome).
    bool airT1ConvRetired = false;
    bool AirT1ConvertersRetired()
    {
        if (!EcoRole::IsAir()) return false;
        if (airT1ConvRetired) return true;
        const string side = Global::AISettings::Side;
        const int adv = FinishedOf(UnitHelpers::GetAdvEnergyConverterNameForSide(side));
        if (adv < Global::RoleSettings::Air::RetireT1ConvertersAtAdvConverters && FinishedOf(UnitHelpers::GetAdvFusionNameForSide(side)) < 1) return false;
        airT1ConvRetired = true;
        GenericHelpers::LogUtil("[AIR][Eco] T1 energy converters retired: " + adv + " advanced converter(s) stand; reclaimed from now on, never built again", 1);
        return true;
    }
    IUnitTask@ ReclaimEnergy(CCircuitUnit@ u, const EcoPlanner::State@ s)
    {
        if (u is null || s is null) return null;
        const bool afusUp = FinishedOf(UnitHelpers::GetAdvFusionNameForSide(Global::AISettings::Side)) > 0;
        if (!ReactorStands()) return null;
        const float wind = TechChain::WindExpected();
        const float t1Make = s.winds * wind + s.solars * 20.0f;
        const float advMake = s.advSolars * 75.0f;
        const float pull = s.ePull;
        // AIR (manager/eco_role.as): its pull is mostly aircraft production, which
        // takes whatever energy there is (played, Salt Reef 2026-09-28: a pull of
        // 1,684 at +1,768, where TECH's was 115 to 771), so with its fusion
        // standing the winds stayed until the advanced fusion - three minutes with
        // the energy bank above EcoConvertEnergyPercent the whole time. For AIR the
        // bank is read, not the pull (as D-079 does for the chain): a bank that
        // floats is energy the T1 sources are not needed for. TECH is unchanged.
        const bool airFloat = EcoRole::IsAir() && s.eStor > 0.0f && s.eCur >= Global::RoleSettings::Tech::EcoConvertEnergyPercent * s.eStor;
        const bool t1Ok = afusUp || airFloat || (s.eIncome - t1Make >= pull * Global::RoleSettings::Tech::ReclaimT1EnergyMargin);
        const bool advOk = afusUp || airFloat || (s.eIncome - t1Make - advMake >= pull * Global::RoleSettings::Tech::ReclaimAdvSolarMargin);
        if (ReclaimsInFlight() >= Global::RoleSettings::Tech::ReclaimEnergyConcurrent) return null;
        const string side = Global::AISettings::Side;
        array<string> names;
        if (t1Ok && s.winds > 0) names.insertLast(UnitHelpers::GetWindNameForSide(side));
        if (t1Ok && s.solars > 0) names.insertLast(UnitHelpers::GetSolarNameForSide(side));
        if (advOk && s.advSolars > 0) names.insertLast(UnitHelpers::GetAdvSolarNameForSide(side));
        if (s.t1Convs > 0 && AirT1ConvertersRetired()) names.insertLast(UnitHelpers::GetEnergyConverterNameForSide(side));
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d is null) continue;
            CCircuitUnit@ target = aiBuilderMgr.FindOwnNear(Layout::BaseCentre(), Global::RoleSettings::Tech::ReclaimEnergyRadius, d);
            if (target is null) continue;
            if (!T2MayReclaim(u, target)) continue;   // D-105: T2 constructors only as a last resort
            // INV-024 (D-101): T1 energy is reclaimed only while a reactor stands finished
            if (!ReactorStands())
                Invariants::Violation("INV-024", target.circuitDef.GetName(), target.circuitDef.GetName() + " " + target.id + " reclaimed with no finished fusion or advanced fusion");
            IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::NORMAL, target, 120 * SECOND));
            if (t is null) continue;
            PullTurrets(target);   // D-078
            const string key = "" + target.id;
            if (!reclaimInFlight.exists(key)) {
                reclaimInFlight.set(key, int64(ai.frame));
                GenericHelpers::LogUtil("[TECH][Reclaim] " + names[i] + " " + target.id + ": energy +" + int(s.eIncome) + " without " + int(t1Make)
                    + " T1 and " + int(advMake) + " adv-solar covers a pull of " + int(pull) + (afusUp ? " (advanced fusion stands)" : " (fusion stands)")
                    + ((airFloat && !afusUp) ? ", AIR: energy bank " + int(s.eCur) + " of " + int(s.eStor) + " floats" : "") + "; by " + u.circuitDef.GetName() + " " + u.id, 1);
            }
            return t;
        }
        return null;
    }

    // D-078 (owner's rule): the advanced lab is reclaimed whenever an advanced
    // fusion is under construction and the bank has room for its metal
    // (Tick retires it; this is the order). Every turret in range joins.
    IUnitTask@ ReclaimT2Lab(CCircuitUnit@ u)
    {
        CCircuitUnit@ lab = Factory::primaryT2BotLab;
        if (lab is null || lab is u || !Lifecycle::IsRetiring(lab)) return null;
        if (!BankHasRoomFor(lab, 2500.0f)) return null;
        if (!T2MayReclaim(u, lab)) return null;   // D-105: T2 constructors only as a last resort
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, lab, 180 * SECOND));
        if (t !is null) PullTurrets(lab);
        return t;
    }

    IUnitTask@ AssistAny(CCircuitUnit@ u, float radius)
    {
        CCircuitUnit@ target = aiBuilderMgr.FindUnfinishedNear(u.GetPos(ai.frame), radius, null);
        if (target is null) return null;
        return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::NORMAL, target, 60 * SECOND));
    }

    IUnitTask@ GuardFactory(CCircuitUnit@ u)
    {
        CCircuitUnit@ fac = EcoRole::PrimaryT1Lab();
        if (fac is null || fac is u || Lifecycle::IsRetiring(fac)) return null;   // D-076: nobody guards a retiring lab
        if (TechFactories::IsSpamLab(fac)) return null;   // D-119: a spam lab is never assisted (its two turrets only)
        return GuardHelpers::AssignWorkerGuard(u, fac, Task::Priority::LOW, true, 20 * SECOND);
    }

    IUnitTask@ Planner(CCircuitUnit@ u, float metalIncome, float energyIncome)
    {
        const string key = EcoPlanner::Next(u, metalIncome, energyIncome);
        if (key.length() == 0) return null;
        IUnitTask@ redirect = RoleTech::Tech_RedirectEnergyToReactor("eco planner: " + key, u);
        if (redirect !is null) return redirect;
        return EcoPlanner::Execute(key, u);
    }

    // The role's strategic rungs (nukes, anti-nuke, gantry, water factories,
    // T2 constructor policy) as they stand; with no default task to fall
    // back to they return null when they have nothing.
    IUnitTask@ Strategic(CCircuitUnit@ u, float metalIncome, float energyIncome)
    {
        const CCircuitDef@ d = u.circuitDef;
        const int tier = UnitHelpers::GetConstructorTier(d);
        if (tier == 1) {
            if (UnitHelpers::IsAirConstructor(d))
                return RoleTech::Tech_T1AirConstructor_AiMakeTask(u, metalIncome, energyIncome, null);
            if (UnitHelpers::IsT1BotConstructor(d.GetName()))
                return RoleTech::Tech_T1BotConstructor_AiMakeTask(u, metalIncome, energyIncome, null);
            return null;
        }
        if (tier == 2) {
            const bool isEnergyFull = aiEconomyMgr.isEnergyFull;
            const bool energyLow = aiEconomyMgr.energy.current < aiEconomyMgr.energy.storage * Global::RoleSettings::Tech::EnergyStorageLowPercent;
            const float metalCurrent = aiEconomyMgr.metal.current;
            if (UnitHelpers::IsAirConstructor(d))
                return RoleTech::Tech_T2AirConstructor_AiMakeTask(u, isEnergyFull, metalIncome, energyIncome, metalCurrent, energyLow, null);
            if (UnitHelpers::IsT2BotConstructor(d.GetName()))
                return RoleTech::Tech_T2BotConstructor_AiMakeTask(u, isEnergyFull, metalIncome, energyIncome, metalCurrent, energyLow, null);
            if (UnitHelpers::IsFastAssistBot(d.GetName()))
                return RoleTech::Tech_T2FastAssistBotConstructor_AiMakeTask(u, isEnergyFull, metalIncome, energyIncome, metalCurrent, energyLow, null);
        }
        return null;
    }

    // ---------------------------------------------------------------- the sequence

    // The sequence is the rule table (roles/tech_rules.as, D-067); the
    // functions above are its acts. Never null: the table ends in "wait".
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        IUnitTask@ t = TechRules::Evaluate(u);
        if (t !is null) return t;
        return Wait(3 * SECOND);
    }
}
