// Rush: Nightmare's scout and raider opening, before LandArmy's income steps.
#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../types/ai_role.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/unit_helpers.as"
#include "../helpers/map_helpers.as"
#include "spam.as"

/******************************************************************************

RUSH

FRONT's first T1 bot lab opens like NightmareAI's (Felnious/Skirmish
Night/mare, misc/commander.as: builder, 10 scouts, 12 raiders, builder) and
only then hands production to LandArmy's income-staged roster:

  queue      builder, ScoutCount scouts, 2 builders, RaiderCount raiders
             (Nightmare ends on its last builder; Marish moves it up so the
             early crew is whole by ~3 min). Each step is done when the
             lab has produced that many of its unit; the lab builds nothing
             else meanwhile. The three builders are Marish's early
             constructor crew (roles/front.as).
  units      scout   armflea / corak / leggob
             raider  armpw   / corak / leglob
             LandArmy keeps both allowed while the rush runs, whatever its
             income step says.
  scouts     the scout rush: every scout gets a native scout task of its own
             and goes in alone, picking at what it finds.
  raiders    the raider rush: raiders gather at a rally point RallyDistance
             from the start toward the nearest enemy start, and every
             RaidSquadSize of them leave together as one native raid squad
             (CRaidTask), which hunts weak targets as a group. A squad that
             waits FormMaxSeconds leaves with what it has. A raider whose
             squad is gone falls back to the native default.
  end        the queue complete, the lab lost, or MaxSeconds elapsed.

Settings live in Global::Rush.

******************************************************************************/
namespace Rush {

    class Step {
        string kind;
        int count;
        Step(const string &in k, int c) { kind = k; count = c; }
    }

    array<Step@> steps;
    array<int> produced;
    uint stepIdx = 0;
    int labId = -1;
    int startFrame = -1;
    bool done = false;
    IUnitTask@ pending = null;

    dictionary seen;      // unit id -> true: counted once
    dictionary scouts;    // unit id -> true
    dictionary raiders;   // unit id -> true: not yet in a squad
    dictionary squadOf;   // unit id -> IUnitTask@ (its raid squad)
    array<int> forming;   // raiders waiting at the rally
    int formingSince = -1;
    CRouteTask@ rally = null;
    int squads = 0;

    bool Enabled() { return Global::Rush::Enabled && Global::AISettings::Role == AiRole::FRONT; }
    bool Active() { return Enabled() && !done; }

    void Load()
    {
        if (steps.length() > 0) return;
        steps.insertLast(Step("builder", 1));
        steps.insertLast(Step("scout", Global::Rush::ScoutCount));
        steps.insertLast(Step("builder", 2));   // Nightmare's last builder moved up: the crew is whole by ~3 min
        steps.insertLast(Step("raider", Global::Rush::RaiderCount));
        produced.resize(steps.length());
        for (uint i = 0; i < produced.length(); ++i) produced[i] = 0;
    }

    string UnitFor(const string &in kind)
    {
        const string side = Global::AISettings::Side;
        if (kind == "builder") {
            array<string> cons = UnitHelpers::GetT1BotConstructors(side);
            return (cons.length() > 0) ? cons[0] : "";
        }
        if (kind == "scout") return (side == "armada") ? "armflea" : (side == "cortex") ? "corak" : "leggob";
        return (side == "armada") ? "armpw" : (side == "cortex") ? "corak" : "leglob";
    }

    // The combat units the rush builds; LandArmy keeps them allowed meanwhile.
    array<string> Units()
    {
        array<string> names = {UnitFor("scout"), UnitFor("raider")};
        return names;
    }

    void Finish(const string &in why)
    {
        if (done) return;
        done = true;
        @pending = null;
        string made = "";
        for (uint i = 0; i < steps.length(); ++i)
            made += (i > 0 ? ", " : "") + produced[i] + "/" + steps[i].count + " " + steps[i].kind;
        GenericHelpers::LogUtil("[Rush] opening done (" + why + "): " + made + "; " + squads + " raid squad(s) sent so far", 1);
    }

    // Front_FactoryAiMakeTask, before anything else for a T1 bot lab.
    IUnitTask@ FactoryTask(CCircuitUnit@ lab)
    {
        if (!Active() || lab is null || lab.circuitDef is null || !UnitHelpers::IsT1BotLab(lab.circuitDef.GetName())) return null;
        Load();
        if (labId < 0) {
            labId = int(lab.id);
            startFrame = ai.frame;
            GenericHelpers::LogUtil("[Rush] opening from " + lab.circuitDef.GetName() + " " + lab.id + ": builder, "
                + Global::Rush::ScoutCount + " " + UnitFor("scout") + ", builder, " + Global::Rush::RaiderCount + " "
                + UnitFor("raider") + " in squads of " + Global::Rush::RaidSquadSize + ", builder", 1);
        }
        if (int(lab.id) != labId) return null;
        if (ai.frame - startFrame > Global::Rush::MaxSeconds * SECOND) { Finish("time limit"); return null; }
        while (stepIdx < steps.length() && produced[stepIdx] >= steps[stepIdx].count) ++stepIdx;
        if (stepIdx >= steps.length()) { Finish("queue complete"); return null; }
        if (pending !is null && !pending.IsDead()) return pending;

        Step@ s = steps[stepIdx];
        CCircuitDef@ d = ai.GetCircuitDef(UnitFor(s.kind));
        if (d is null || !d.IsAvailable(ai.frame)) {
            GenericHelpers::LogUtil("[Rush] step " + stepIdx + " (" + s.kind + ") skipped: " + UnitFor(s.kind) + " not available", 1);
            produced[stepIdx] = s.count;
            return null;
        }
        const Task::RecruitType rt = (s.kind == "builder") ? Task::RecruitType::BUILDPOWER : Task::RecruitType::FIREPOWER;
        @pending = aiFactoryMgr.Enqueue(TaskS::Recruit(rt, Task::Priority::HIGH, d, lab.GetPos(ai.frame), 64.0f));
        return pending;
    }

    // Builder::AiUnitAdded and Military::AiUnitAdded: counts the lab's output.
    void OnUnitAdded(CCircuitUnit@ u)
    {
        if (!Enabled() || done || u is null || u.circuitDef is null || labId < 0) return;
        const string key = "" + u.id;
        if (seen.exists(key) || u.GetProducerId() != labId) return;
        seen.set(key, true);
        if (stepIdx >= steps.length() || u.circuitDef.GetName() != UnitFor(steps[stepIdx].kind)) return;
        ++produced[stepIdx];
        if (steps[stepIdx].kind == "scout") scouts.set(key, true);
        else if (steps[stepIdx].kind == "raider") raiders.set(key, true);
    }

    void OnUnitRemoved(CCircuitUnit@ u)
    {
        if (u is null) return;
        const string key = "" + u.id;
        scouts.delete(key);
        raiders.delete(key);
        squadOf.delete(key);
        const int i = forming.find(int(u.id));
        if (i >= 0) forming.removeAt(i);
        if (int(u.id) == labId && !done) Finish("the lab was lost");
    }

    AIFloat3 RallyPos()
    {
        AIFloat3 start = Global::Map::StartPos;
        array<AIFloat3> enemies = Spam::EnemyStartSpots();
        AIFloat3 target = (enemies.length() > 0) ? enemies[0]
            : AIFloat3(aiTerrainMgr.GetTerrainWidth() * 0.5f, 0.0f, aiTerrainMgr.GetTerrainHeight() * 0.5f);
        const float dx = target.x - start.x, dz = target.z - start.z;
        const float len = sqrt(dx * dx + dz * dz);
        if (len < 1.0f) return start;
        const float k = AiMin(Global::Rush::RallyDistance, len * 0.5f) / len;
        return AIFloat3(start.x + dx * k, start.y, start.z + dz * k);
    }

    IUnitTask@ RallyTask()
    {
        if (rally !is null && !rally.IsDead()) return rally;
        IUnitTask@ t = aiMilitaryMgr.Enqueue(TaskF::Route());
        @rally = cast<CRouteTask>(cast<IFighterTask>(t));
        if (rally is null) return null;
        array<AIFloat3> route = {RallyPos()};
        rally.SetRoute(route);
        rally.SetHoldPosition(true);
        return rally;
    }

    // Sends the waiting raiders out as one native raid squad; the newcomer (if
    // any) is assigned by the caller through the returned task.
    IUnitTask@ Launch(CCircuitUnit@ newcomer, const string &in why)
    {
        IUnitTask@ raid = aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::RAID));
        if (raid is null) return null;
        int n = 0;
        for (uint i = 0; i < forming.length(); ++i) {
            CCircuitUnit@ m = ai.GetTeamUnit(forming[i]);
            if (m is null) continue;
            if (newcomer !is null && m is newcomer) { ++n; continue; }
            if (aiMilitaryMgr.TransferUnit(m, raid)) ++n;
            else continue;
            squadOf.set("" + m.id, @raid);
            raiders.delete("" + m.id);
        }
        if (newcomer !is null) {
            squadOf.set("" + newcomer.id, @raid);
            raiders.delete("" + newcomer.id);
        }
        forming.resize(0);
        formingSince = -1;
        ++squads;
        GenericHelpers::LogUtil("[Rush] raid squad " + squads + " of " + n + " leaves (" + why + ")", 1);
        return raid;
    }

    // Military::AiMakeTask, before the role's policy.
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (u is null) return null;
        const string key = "" + u.id;
        if (scouts.exists(key)) return aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::SCOUT));
        IUnitTask@ squad = null;
        if (squadOf.get(key, @squad)) {
            if (squad !is null && !squad.IsDead()) return squad;
            squadOf.delete(key);   // the squad is over: native takes it from here
            return null;
        }
        if (!raiders.exists(key)) return null;
        if (forming.find(int(u.id)) < 0) forming.insertLast(int(u.id));
        if (formingSince < 0) formingSince = ai.frame;
        if (int(forming.length()) >= Global::Rush::RaidSquadSize) return Launch(u, "squad of " + Global::Rush::RaidSquadSize + " gathered");
        return RallyTask();
    }

    // LandArmy::Apply (economy update): a squad that has waited too long, or
    // the rush's last raiders, leave with what they have.
    void Tick()
    {
        if (Active() && labId >= 0) {
            if (ai.GetTeamUnit(labId) is null) Finish("the lab was lost");
            else if (ai.frame - startFrame > Global::Rush::MaxSeconds * SECOND) Finish("time limit");
        }
        if (!Enabled() || forming.length() == 0 || formingSince < 0) return;
        const bool late = ai.frame - formingSince > Global::Rush::FormMaxSeconds * SECOND;
        const bool last = done || (stepIdx < steps.length() && steps[stepIdx].kind != "raider"
            && stepIdx > 0 && steps[stepIdx - 1].kind == "raider");
        if (late || last) Launch(null, late ? "waited " + Global::Rush::FormMaxSeconds + " s" : "the last raiders");
    }
}
