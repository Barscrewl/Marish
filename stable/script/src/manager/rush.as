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
#include "lanes.as"

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
  target     the enemy start closest to our spawn: the start script's enemy
             teams when it has positions, else the map's enemy start spots
             (Lanes::EnemyStarts), else the mirror of our start through the
             map centre. Every scout and squad heads there first.
  scouts     the scout rush: each scout goes in alone as it leaves the lab,
             straight to the target (a route, fighting at its end); once
             there it is handed a native scout task and picks at what it finds.
  raiders    the raider rush: raiders gather at a rally point RallyDistance
             from the start toward the target, and every RaidSquadSize of
             them leave together along one route to the target; when the
             first of them arrives the squad becomes one native raid squad
             (CRaidTask), which hunts weak targets there as a group. A squad
             that waits FormMaxSeconds leaves with what it has. A raider
             whose squad is gone falls back to the native default.
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

    class Squad {
        array<int> ids;
        CRouteTask@ route = null;   // the way to the target
        IUnitTask@ raid = null;     // native raid squad, once there
    }

    dictionary seen;      // unit id -> true: counted once
    dictionary scouts;    // unit id -> true: on the way to the target
    dictionary roaming;   // unit id -> true: scout at the target, native scout task
    dictionary raiders;   // unit id -> true: not yet in a squad
    dictionary squadOf;   // unit id -> int index into squadList
    array<Squad@> squadList;
    array<int> forming;   // raiders waiting at the rally
    int formingSince = -1;
    CRouteTask@ rally = null;
    CRouteTask@ scoutRoute = null;
    int squads = 0;
    AIFloat3 target;
    bool hasTarget = false;

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
        roaming.delete(key);
        raiders.delete(key);
        int s = -1;
        if (squadOf.get(key, s) && s >= 0 && s < int(squadList.length())) {
            const int at = squadList[s].ids.find(int(u.id));
            if (at >= 0) squadList[s].ids.removeAt(at);
        }
        squadOf.delete(key);
        const int i = forming.find(int(u.id));
        if (i >= 0) forming.removeAt(i);
        if (int(u.id) == labId && !done) Finish("the lab was lost");
    }

    // The enemy start closest to our spawn (cached: the starts do not move).
    AIFloat3 Target()
    {
        if (hasTarget) return target;
        const AIFloat3 start = Global::Map::StartPos;
        array<AIFloat3> enemies = Lanes::EnemyStarts();
        float bestSq = -1.0f;
        for (uint i = 0; i < enemies.length(); ++i) {
            const float sq = MapHelpers::SqDist(start, enemies[i]);
            if (bestSq < 0.0f || sq < bestSq) { bestSq = sq; target = enemies[i]; }
        }
        string from = "the closest of " + enemies.length() + " enemy start(s)";
        if (bestSq < 0.0f) {
            target = AIFloat3(aiTerrainMgr.GetTerrainWidth() - start.x, start.y, aiTerrainMgr.GetTerrainHeight() - start.z);
            from = "no enemy start known: our start mirrored through the map centre";
        }
        hasTarget = true;
        GenericHelpers::LogUtil("[Rush] target (" + int(target.x) + ", " + int(target.z) + "), "
            + int(sqrt(MapHelpers::SqDist(start, target))) + " from our start: " + from, 1);
        return target;
    }

    AIFloat3 RallyPos()
    {
        const AIFloat3 start = Global::Map::StartPos;
        const AIFloat3 t = Target();
        const float dx = t.x - start.x, dz = t.z - start.z;
        const float len = sqrt(dx * dx + dz * dz);
        if (len < 1.0f) return start;
        const float k = AiMin(Global::Rush::RallyDistance, len * 0.5f) / len;
        return AIFloat3(start.x + dx * k, start.y, start.z + dz * k);
    }

    // A route task: hold at `to`, or go there and fight at the end.
    CRouteTask@ NewRoute(const AIFloat3 &in to, bool hold)
    {
        IUnitTask@ t = aiMilitaryMgr.Enqueue(TaskF::Route());
        CRouteTask@ r = cast<CRouteTask>(cast<IFighterTask>(t));
        if (r is null) return null;
        array<AIFloat3> route = {to};
        r.SetRoute(route);
        if (hold) r.SetHoldPosition(true);
        else r.SetTraversal(false, Global::Rush::ArriveRadius, true);
        return r;
    }

    IUnitTask@ RallyTask()
    {
        if (rally is null || rally.IsDead()) @rally = NewRoute(RallyPos(), true);
        return rally;
    }

    // Scouts share one route but each is ordered along it the moment it
    // leaves the lab, so they go in one by one.
    IUnitTask@ ScoutTask()
    {
        if (scoutRoute is null || scoutRoute.IsDead()) @scoutRoute = NewRoute(Target(), false);
        return scoutRoute;
    }

    // Sends the waiting raiders out together along a route to the target; the
    // newcomer (if any) is assigned by the caller through the returned task.
    IUnitTask@ Launch(CCircuitUnit@ newcomer, const string &in why)
    {
        Squad@ sq = Squad();
        @sq.route = NewRoute(Target(), false);
        if (sq.route is null) return null;
        const int idx = int(squadList.length());
        for (uint i = 0; i < forming.length(); ++i) {
            CCircuitUnit@ m = ai.GetTeamUnit(forming[i]);
            if (m is null) continue;
            if (!(newcomer !is null && m is newcomer) && !aiMilitaryMgr.TransferUnit(m, sq.route)) continue;
            sq.ids.insertLast(int(m.id));
            squadOf.set("" + m.id, idx);
            raiders.delete("" + m.id);
        }
        squadList.insertLast(sq);
        forming.resize(0);
        formingSince = -1;
        ++squads;
        GenericHelpers::LogUtil("[Rush] raid squad " + squads + " of " + sq.ids.length() + " leaves for the enemy start ("
            + why + ")", 1);
        return sq.route;
    }

    // Military::AiMakeTask, before the role's policy.
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (u is null) return null;
        const string key = "" + u.id;
        if (roaming.exists(key)) return aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::SCOUT));
        if (scouts.exists(key)) return ScoutTask();
        int s = -1;
        if (squadOf.get(key, s) && s >= 0 && s < int(squadList.length())) {
            Squad@ sq = squadList[s];
            if (sq.raid !is null && !sq.raid.IsDead()) return sq.raid;
            if (sq.raid is null && sq.route !is null && !sq.route.IsDead()) return sq.route;
            squadOf.delete(key);   // the squad is over: native takes it from here
            return null;
        }
        if (!raiders.exists(key)) return null;
        if (forming.find(int(u.id)) < 0) forming.insertLast(int(u.id));
        if (formingSince < 0) formingSince = ai.frame;
        if (int(forming.length()) >= Global::Rush::RaidSquadSize) return Launch(u, "squad of " + Global::Rush::RaidSquadSize + " gathered");
        return RallyTask();
    }

    // At the target a scout gets a native scout task, and a squad (as soon as
    // one of it arrives) one native raid task for all of it.
    void Arrivals()
    {
        if (scoutRoute !is null && !scoutRoute.IsDead()) {
            IUnitTask@ scoutTask = scoutRoute;
            array<string>@ keys = scouts.getKeys();
            for (uint i = 0; i < keys.length(); ++i) {
                CCircuitUnit@ u = ai.GetTeamUnit(int(parseInt(keys[i])));
                if (u is null || u.task !is scoutTask || !scoutRoute.IsAtEnd(u)) continue;
                IUnitTask@ scout = aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::SCOUT));
                if (scout is null || !aiMilitaryMgr.TransferUnit(u, scout)) continue;
                scouts.delete(keys[i]);
                roaming.set(keys[i], true);
                if (roaming.getSize() == 1)
                    GenericHelpers::LogUtil("[Rush] first scout reached the enemy start; scouts there go native", 1);
            }
        }
        for (uint s = 0; s < squadList.length(); ++s) {
            Squad@ sq = squadList[s];
            if (sq.raid !is null || sq.route is null || sq.route.IsDead()) continue;
            IUnitTask@ routeTask = sq.route;
            bool arrived = false;
            for (uint i = 0; i < sq.ids.length() && !arrived; ++i) {
                CCircuitUnit@ m = ai.GetTeamUnit(sq.ids[i]);
                arrived = m !is null && m.task is routeTask && sq.route.IsAtEnd(m);
            }
            if (!arrived) continue;
            @sq.raid = aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::RAID));
            if (sq.raid is null) continue;
            int n = 0;
            for (uint i = 0; i < sq.ids.length(); ++i) {
                CCircuitUnit@ m = ai.GetTeamUnit(sq.ids[i]);
                if (m !is null && aiMilitaryMgr.TransferUnit(m, sq.raid)) ++n;
            }
            GenericHelpers::LogUtil("[Rush] raid squad " + (s + 1) + " reached the enemy start: " + n + " raiding", 1);
        }
    }

    // LandArmy::Apply (economy update): arrivals at the target, and a squad
    // that has waited too long (or the rush's last raiders) leaves with what
    // it has.
    void Tick()
    {
        if (Active() && labId >= 0) {
            if (ai.GetTeamUnit(labId) is null) Finish("the lab was lost");
            else if (ai.frame - startFrame > Global::Rush::MaxSeconds * SECOND) Finish("time limit");
        }
        if (!Enabled()) return;
        Arrivals();
        if (forming.length() == 0 || formingSince < 0) return;
        const bool late = ai.frame - formingSince > Global::Rush::FormMaxSeconds * SECOND;
        const bool last = done || (stepIdx < steps.length() && steps[stepIdx].kind != "raider"
            && stepIdx > 0 && steps[stepIdx - 1].kind == "raider");
        if (late || last) Launch(null, late ? "waited " + Global::Rush::FormMaxSeconds + " s" : "the last raiders");
    }
}
