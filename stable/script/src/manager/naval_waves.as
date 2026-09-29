// Frigates and destroyers: hold at base, launch every one together at the threshold.
#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../helpers/generic_helpers.as"

/******************************************************************************

NAVAL WAVES (frigates and destroyers, every faction)

Ported from main (5de4272, bb41a7d, 6ff38cc) onto Cent's release, reshaped to
one rule: hold the frigates and destroyers, and once the hold reaches
Global::NavalWaves::LaunchAt ships combined, send every held ship out as one
attack.

    Armada   armpship (Ellysaw, frigate)       armroy (destroyer)
    Cortex   corpship (Riptide, frigate)       corroy (destroyer)
    Legion   legnavyfrigate (Argonaut)         legnavydestro (destroyer)

The defect
----------
CMilitaryManager::DefaultMakeTask maps a unit's MAIN role to a fight type
(scout, raider, riot, arty, aa, ah, bomber, support, mine, super). The
frigates and destroyers are assault / skirmish (no entry: a parked
Defend(ATTACK, max(minAttackers, preMaxGroupThreat)) near base) or riot
(DEFEND). Either way they sit in a defend squad that promotes only when its
power clears a bar native re-sets every 5 s from the enemy's groups. Cent's
Global::Military::AttackScale / AttackWaitSeconds lower that bar and send a
squad after 180 s, but they release whatever defend squad forms, one at a
time; on The Rock Jungle (2026-09-28, humans on the water) SEA was still
far too passive. The fleet needs to move as one.

Mechanism (native primitives only)
----------------------------------
  hold     TaskF::Defend(check=MELEE, promote=AH, power=HoldPower). Nothing
           enqueues a MELEE task, so the hold never promotes on its own.
           promote=AH keeps native's 5 s threshold rewrite (ATTACK-promoting
           defend tasks only) and Cent's attackWait (ATTACK promote only) off
           it, and CDefendTask::CanAssignTo compares promote, so these holds
           never merge with native defend squads or AirWaves' BOMB/AA holds.
  release  Abort() each distinct hold task from Main::AiUpdate; the ships go
           idle, re-enter Military::AiMakeTask and take the wave's task.
  wave     one TaskF::Common(ATTACK) for the whole wave. CAttackTask only picks
           enemy groups a ship leader can reach and shoot (CanMobileReachAt,
           HasSurfToWater / HasSurfToLand), else it heads for the front. The
           script path skips CanAssignTo, so the wave stays one squad; it
           travels at its slowest hull (legnavydestro 58 to corpship 82.5).
  escorts  none needed: Legion's arty ship ("support" attribute, a real added
           role) runs CSupportTask, which follows the leader of an ATTACK task
           once one exists.
  end      CAttackTask aborts itself when losses take it under minAttackers;
           survivors come back idle and rejoin the hold for the next wave.

Safety valve: a hold of at least TimeoutMinSize ships that has waited
MaxHoldSeconds launches anyway (0 turns it off), so a yard that cannot reach
LaunchAt never parks its fleet for good.

Only ids are stored (CCircuitUnit is not ref-counted); the wave task handle is
kept for the release window only. Log, grep [NAVY][Waves].

******************************************************************************/
namespace NavalWaves {
    const float HoldPower = 1.0e9f;   // never reached: holds must not self-promote

    dictionary shipDefs;         // def name -> true
    bool rosterBuilt = false;

    dictionary held;             // id string -> int id
    int holdSinceFrame = -1;     // first frame the hold was non-empty since the last launch

    dictionary launchQueue;      // id string -> int id, released, awaiting the wave task
    IUnitTask@ waveAttackTask = null;   // release window only
    int releaseUntilFrame = -1;  // >= 0 while released ships re-task

    int waveIndex = 0;
    int statusFrame = -100000;

    bool IsEnabled() { return Global::NavalWaves::Enabled; }

    void _BuildRoster()
    {
        rosterBuilt = true;
        shipDefs.deleteAll();
        string names = "";
        for (uint i = 0; i < Global::NavalWaves::Ships.length(); ++i) {
            const string n = Global::NavalWaves::Ships[i];
            if (ai.GetCircuitDef(n) is null) continue;   // not loaded in this game
            shipDefs.set(n, true);
            names += (names.length() > 0 ? ", " : "") + n;
        }
        GenericHelpers::LogUtil("[NAVY][Waves] roster: " + names + "; launch at " + Global::NavalWaves::LaunchAt
            + " combined", 2);
    }

    bool IsWaveShip(const CCircuitDef@ d)
    {
        if (d is null) return false;
        if (!rosterBuilt) _BuildRoster();
        return shipDefs.exists(d.GetName());
    }

    /**************************************************************************
     Military::AiMakeTask, ahead of the role policy. Null for ships this does
     not manage; the caller then takes its normal path.
     **************************************************************************/
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (!IsEnabled() || u is null || u.circuitDef is null) return null;
        if (!IsWaveShip(u.circuitDef)) return null;

        const string key = "" + u.id;
        if (launchQueue.exists(key)) {
            launchQueue.delete(key);
            if (ai.frame <= releaseUntilFrame) {
                IUnitTask@ t = _MakeWaveTask();
                if (t !is null) return t;
            }
            // Missed the window, or Enqueue refused: hold for the next wave.
        }
        return _MakeHoldTask(u);
    }

    // One CAttackTask for the wave, made on the first released ship to ask.
    IUnitTask@ _MakeWaveTask()
    {
        if (waveAttackTask is null) {
            @waveAttackTask = aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::ATTACK));
            if (waveAttackTask is null) {
                GenericHelpers::LogUtil("[NAVY][Waves] Enqueue(ATTACK) returned null; the ship rejoins the hold", 1);
            }
        }
        return waveAttackTask;
    }

    IUnitTask@ _MakeHoldTask(CCircuitUnit@ u)
    {
        IUnitTask@ t = aiMilitaryMgr.Enqueue(
            TaskF::Defend(Task::FightType::MELEE, Task::FightType::AH, HoldPower));
        if (t is null) return null;
        held.set("" + u.id, int(u.id));
        if (holdSinceFrame < 0) holdSinceFrame = ai.frame;
        return t;
    }

    /**************************************************************************
     Main::AiUpdate, every 30 frames.
     **************************************************************************/
    void Update()
    {
        if (!IsEnabled()) return;
        if (!rosterBuilt) _BuildRoster();
        const int frame = ai.frame;
        _PruneHeld();
        if (releaseUntilFrame >= 0 && frame > releaseUntilFrame) _EndRelease();
        if (releaseUntilFrame < 0) _TryLaunch(frame);
    }

    void _PruneHeld()
    {
        array<string>@ keys = held.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            int id = 0;
            if (!held.get(keys[i], id) || ai.GetTeamUnit(id) is null) held.delete(keys[i]);
        }
    }

    void _TryLaunch(int frame)
    {
        const int ships = int(held.getSize());
        if (ships == 0) { holdSinceFrame = -1; return; }
        if (holdSinceFrame < 0) holdSinceFrame = frame;
        const int heldSeconds = (frame - holdSinceFrame) / SECOND;

        if (frame - statusFrame >= MINUTE) {
            statusFrame = frame;
            GenericHelpers::LogUtil("[NAVY][Waves] holding " + ships + "/" + Global::NavalWaves::LaunchAt
                + " frigates and destroyers for " + heldSeconds + " s (waves so far " + waveIndex + ")", 1);
        }

        const bool reached = ships >= Global::NavalWaves::LaunchAt;
        const bool timedOut = Global::NavalWaves::MaxHoldSeconds > 0
            && ships >= Global::NavalWaves::TimeoutMinSize
            && heldSeconds >= Global::NavalWaves::MaxHoldSeconds;
        if (!reached && !timedOut) return;
        _Launch(frame, reached ? "threshold reached" : "held " + heldSeconds + " s");
    }

    void _Launch(int frame, const string &in reason)
    {
        launchQueue.deleteAll();
        @waveAttackTask = null;

        array<IUnitTask@> aborted;
        _ReleaseHeld(@aborted);

        const int launched = int(launchQueue.getSize());
        holdSinceFrame = -1;
        if (launched == 0) return;   // every held id was stale

        ++waveIndex;
        releaseUntilFrame = frame + Global::NavalWaves::ReleaseWindowSeconds * SECOND;
        GenericHelpers::LogUtil("[NAVY][Waves] wave " + waveIndex + " launched (" + reason + "): "
            + launched + " ships, " + aborted.length() + " hold task(s) released", 1);
    }

    // Every held ship goes to the launch queue; each distinct DEFEND hold task is
    // aborted once. A ship retreating or already idle keeps its task and takes
    // the wave task when it next asks.
    void _ReleaseHeld(array<IUnitTask@>@ aborted)
    {
        array<string>@ keys = held.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            int id = 0;
            if (!held.get(keys[i], id)) continue;
            CCircuitUnit@ u = ai.GetTeamUnit(id);
            if (u is null) continue;
            launchQueue.set(keys[i], id);

            IUnitTask@ t = u.task;
            if (t is null || Task::Type(t.GetType()) != Task::Type::FIGHTER) continue;
            IFighterTask@ ft = cast<IFighterTask>(t);
            if (ft is null || Task::FightType(ft.GetFightType()) != Task::FightType::DEFEND) continue;
            if (_ContainsTask(@aborted, t)) continue;
            aborted.insertLast(t);
            t.Abort();
        }
        held.deleteAll();
    }

    bool _ContainsTask(array<IUnitTask@>@ list, IUnitTask@ t)
    {
        for (uint i = 0; i < list.length(); ++i) {
            if (list[i] is t) return true;
        }
        return false;
    }

    void _EndRelease()
    {
        const int stragglers = int(launchQueue.getSize());
        launchQueue.deleteAll();
        @waveAttackTask = null;
        releaseUntilFrame = -1;
        if (stragglers > 0) {
            GenericHelpers::LogUtil("[NAVY][Waves] release window closed with " + stragglers
                + " ship(s) not re-tasked; they rejoin the hold when idle", 2);
        }
    }

    /**************************************************************************
     Bookkeeping hooks (Military::AiUnitRemoved / AiTaskRemoved).
     **************************************************************************/
    void OnUnitRemoved(CCircuitUnit@ u)
    {
        if (u is null) return;
        const string key = "" + u.id;
        held.delete(key);
        launchQueue.delete(key);
    }

    void OnTaskRemoved(IUnitTask@ task)
    {
        if (task is null || waveAttackTask is null) return;
        if (waveAttackTask is task) @waveAttackTask = null;
    }
}  // namespace NavalWaves
