// Stalled T2 constructors: parked a moment, then handed back for a new task.
#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/map_helpers.as"

/******************************************************************************

BUILDER WATCHDOG

A T2 constructor can sit on a task that never gets anywhere: an order whose
site native refuses, re-issued on every ask (Starwatcher 2026-09-29: TECH's
T2 constructors were handed a dead nuclear silo order 1,484 times), a mex
spot two orders fight over, a path that never arrives. The rule table cannot
see it - the builder holds a task - so every CheckSeconds this looks at each
T2 constructor of ours:

  productive  moved MoveElmos or more since the last check, or the structure
              its own task builds gained build progress
  exempt      no task yet, a wait (nothing to do is not a stall), a player
              task (parked here, by the bomber stock, a ferry), a retreat, a
              reclaim, resurrect, guard or combat, a repair of a finished
              structure, a ferry gift; commanders are never watched

Crash safety (access violations in SkirmishAI.dll, 2026-09-26): nothing here
runs inside AiMakeTask; no unit handle is kept between checks (every unit is
fetched by id with ai.GetTeamUnit, null once dead); no other unit's task is
followed, only the builder's own task and its target; a unit is handed back
only while it still holds the player task given here.

A constructor unproductive for StallSeconds is taken out of AI control
(ai.UnitControl(u, false): a player task) and stopped, and ParkSeconds later
handed back (ai.UnitControl(u, true)): it goes idle and native asks the role
for a new task. Like the bomber stock, only ever from Main::AiUpdate, never
inside AiMakeTask. A released constructor is not parked again for
CooldownSeconds. Log: [Watchdog], level 1.

******************************************************************************/
namespace BuilderWatchdog {

    class Watch {
        int id;
        float x, z;
        float progress;          // the tracked structure's build progress at the last check (-1: none)
        int idleSince;           // first check with no progress, -1 while productive
        int parkedUntil;         // > 0 while parked here
        int restUntil;           // not parked again before this frame
        Watch(int i) { id = i; x = -1.0f; z = -1.0f; progress = -1.0f; idleSince = -1; parkedUntil = 0; restUntil = 0; }
    }

    array<Watch@> watched;
    int nextCheck = 0;

    // Builder::AiUnitAdded: every mobile T2 constructor of ours
    void Register(CCircuitUnit@ u)
    {
        if (u is null || !Global::BuilderWatchdog::Enabled) return;
        for (uint i = 0; i < watched.length(); ++i) if (watched[i].id == u.id) return;
        watched.insertLast(Watch(u.id));
    }

    // The structure this constructor's work shows up in, or null
    CCircuitUnit@ _Structure(CCircuitUnit@ u, bool &out exempt)
    {
        exempt = false;
        IUnitTask@ t = u.task;
        if (t is null) { exempt = true; return null; }
        const Task::Type tt = Task::Type(t.GetType());
        // a retreat (standing at base while repaired is its job) is never interrupted
        if (tt == Task::Type::WAIT || tt == Task::Type::PLAYER || tt == Task::Type::IDLE || tt == Task::Type::NIL
            || tt == Task::Type::RETREAT) { exempt = true; return null; }
        IBuilderTask@ bt = cast<IBuilderTask>(t);
        if (bt is null) return null;
        const Task::BuildType b = Task::BuildType(bt.GetBuildType());
        // Not judged: reclaim and resurrect (progress not visible), and a guard
        // (its work is the guarded builder's; that builder is watched itself -
        // no other unit's task is followed here, only this task's own target,
        // which native clears when it dies)
        if (b == Task::BuildType::RECLAIM || b == Task::BuildType::RESURRECT || b == Task::BuildType::GUARD
            || b == Task::BuildType::COMBAT) { exempt = true; return null; }
        CCircuitUnit@ target = bt.target;
        // a repair of a finished structure restores health, not build progress
        if (target !is null && b == Task::BuildType::REPAIR && target.GetBuildProgress() >= 1.0f) { exempt = true; return null; }
        return target;
    }

    void _Park(CCircuitUnit@ u, Watch@ w, int stalledFor)
    {
        IUnitTask@ t = u.task;
        IBuilderTask@ bt = (t is null) ? null : cast<IBuilderTask>(t);
        const string what = (bt is null) ? ("task type " + int(t.GetType()))
            : ("build type " + int(bt.GetBuildType()) + (bt.buildDef is null ? "" : " " + bt.buildDef.GetName()));
        if (!ai.UnitControl(u, false)) return;
        u.CmdStop();
        w.parkedUntil = ai.frame + int(Global::BuilderWatchdog::ParkSeconds * SECOND);
        w.idleSince = -1;
        const AIFloat3 p = u.GetPos(ai.frame);
        GenericHelpers::LogUtil("[Watchdog] " + u.circuitDef.GetName() + " " + u.id + " stalled " + (stalledFor / SECOND) + " s on "
            + what + " at (" + int(p.x) + ", " + int(p.z) + "): parked " + int(Global::BuilderWatchdog::ParkSeconds) + " s, then a new task", 1);
    }

    // Main::AiUpdate
    void Update()
    {
        if (!Global::BuilderWatchdog::Enabled || ai.frame < nextCheck) return;
        nextCheck = ai.frame + int(Global::BuilderWatchdog::CheckSeconds * SECOND);
        const int stallFrames = int(Global::BuilderWatchdog::StallSeconds * SECOND);
        const float moveSq = Global::BuilderWatchdog::MoveElmos * Global::BuilderWatchdog::MoveElmos;
        for (uint i = 0; i < watched.length(); ) {
            Watch@ w = watched[i];
            CCircuitUnit@ u = ai.GetTeamUnit(w.id);
            if (u is null || u.circuitDef is null) { watched.removeAt(i); continue; }
            ++i;
            // parked here: hand it back when its time is up
            if (w.parkedUntil > 0) {
                if (ai.frame < w.parkedUntil) continue;
                w.parkedUntil = 0;
                w.restUntil = ai.frame + int(Global::BuilderWatchdog::CooldownSeconds * SECOND);
                IUnitTask@ pt = u.task;
                if (pt !is null && Task::Type(pt.GetType()) == Task::Type::PLAYER) ai.UnitControl(u, true);
                GenericHelpers::LogUtil("[Watchdog] " + u.circuitDef.GetName() + " " + u.id + " released for a new task", 1);
                w.x = -1.0f; w.progress = -1.0f;
                continue;
            }
            if (Team::Ferry::IsGift(u.id)) { w.idleSince = -1; continue; }
            const AIFloat3 p = u.GetPos(ai.frame);
            bool exempt;
            CCircuitUnit@ s = _Structure(u, exempt);
            const float prog = (s is null) ? -1.0f : s.GetBuildProgress();
            const bool moved = (w.x >= 0.0f) && ((p.x - w.x) * (p.x - w.x) + (p.z - w.z) * (p.z - w.z) >= moveSq);
            const bool built = (prog >= 0.0f) && (w.progress >= 0.0f) && (prog > w.progress + 0.0005f);
            const bool first = (w.x < 0.0f);
            w.x = p.x; w.z = p.z; w.progress = prog;
            if (exempt || moved || built || first) { w.idleSince = -1; continue; }
            if (w.idleSince < 0) { w.idleSince = ai.frame; continue; }
            if (ai.frame < w.restUntil) continue;
            if (ai.frame - w.idleSince >= stallFrames) _Park(u, w, ai.frame - w.idleSince);
        }
    }
}  // namespace BuilderWatchdog
