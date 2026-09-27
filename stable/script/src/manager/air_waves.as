// AIR role: T2 bomber waves.
#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/unit_helpers.as"
#include "../helpers/unitdef_helpers.as"
#include "military.as"

/******************************************************************************

T2 BOMBER WAVES

Native CMilitaryManager::DefaultMakeTask puts every unit whose main role is
"bomber" into a CBombTask the moment it leaves the factory, so bombers trickle
out one at a time. That is the right opening behaviour for T1 bombers and is
left untouched (every def not in UnitHelpers::GetAllT2WaveBombers /
GetAllT2Fighters falls through to the default task). T2 bombers and T2 fighters
are instead held at base and released together, escorted, in waves that grow
with every launch. BAR has no T3 bombers (the experimental aircraft plants are
unreachable and gantries build no aircraft); the wave roster is data-driven in
UnitHelpers, so a new tier is a list entry.

Native primitives used (no C++ required):
  hold     TaskF::Defend(check=MELEE, promote=BOMB|AA, power=HoldPower). A
           CDefendTask parks the unit near the base position and only engages
           enemies inside our own defence influence. It promotes when
           attackPower >= power or when any task of type `check` exists: MELEE
           tasks are never created (CMilitaryManager::Enqueue has no MELEE case)
           and HoldPower is far above any real sum, so a hold never promotes on
           its own. Promote is not ATTACK because UpdateDefenceTasks rewrites the
           power threshold of ATTACK-promoting defend tasks every 5 s. Holds of
           the same promote type merge natively; release therefore aborts by
           task, not by unit.
  release  IUnitTask::Abort() on every distinct hold task returns its units to
           CIdleTask. Each re-enters Military::AiMakeTask within a few seconds
           and is handed its wave task from the launch queue.
  wave     one TaskF::Common(BOMB) per bomber def: CBombTask::CanAssignTo only
           groups identical defs, and target selection stays native (see
           doc/bomber-targeting.md for its known defects). Fighters get
           TaskF::Guard(vip) on the wave's bombers, spread round-robin over the
           living bombers, so they fly with the wave and engage what comes near.
  end      no explicit end. CBombTask keeps bombing while it has targets;
           survivors that come back idle rejoin the hold for the next wave, and
           an escort whose bomber died re-attaches to another living wave bomber
           while the wave still has one.

Sizing (ComputeNextWaveSize): the next wave starts from the previous size and
grows by a factor picked from the previous wave's survival ratio, measured
BomberWaveEvaluateSeconds after launch: heavy losses mean the enemy anti-air is
winning and the next wave needs mass; light losses grow gently. The result is
raised to an enemy-anti-air floor (wave bomber metal >= a fraction of the enemy
anti_air metal on the map, from the Military cost cache) and clamped to
[BomberWaveFirstSize, BomberWaveMaxSize]. BomberWaveMaxSize is also a hard cap on
every launch: BomberStock's batch goes first, held survivors fill what is left,
and anything past the cap stays in the hold for the next wave. A wave also
launches on a time-out
once BomberWaveFirstSize bombers have been held for BomberWaveMaxHoldSeconds,
so slow production never stalls the air war.

Production: the T2 aircraft plant asks MakeProductionTask for the next wave
unit; bombers and fighters are grown together so the escort never lags.

Income floor (D-045): whatever the survival growth says, a wave must hold
BomberWaveSizePerIncomeStep bombers for every BomberWaveIncomeStep of
sliding-minimum metal income - 50 at +100, 100 at +200 - before it launches.

Attack methods (D-045, doc/air-wave-attacks.md): each launch draws one of
CARPET / FLANK / PINCER / STRIKE / DEEP / FEINT by weight and hands every
bomber one native CAirWaveTask carrying the plan: form a line abreast at the
stand-off, hold if told, attack-move down parallel lanes through the aim
(carpet) or dive on the chosen unit (strike). When the run is over the task
aborts itself, the survivors are handed the plain native bomb task once
(mop-up, `mopUp`), and after that they rejoin the hold. With no wave task
(the enqueue failed) a launch falls back to the plain bomb tasks as before.

CCircuitUnit handles are not ref-counted: only ids are stored and units are
re-acquired with ai.GetTeamUnit(id). Task handles are ref-counted and are kept
only for the release window; Military::AiTaskRemoved drops them early.

Full chain, script gate to ABI (verified against S3KCentrifugal/CircuitAI,
branch smrt @ 8d4725b - the private fork SMRTBARb's DLL actually builds from,
not the public rlcevg/CircuitAI barb5 this file otherwise cites):
  1. _TryLaunch (below) gates on bombers >= nextWaveSize: this file's own
     script-side count, nothing native involved yet.
  2. _Launch aborts the hold tasks; it does not create the bomb task. The
     freed units re-enter Military::AiMakeTask on their own next tick and
     call _MakeWaveBombTask.
  3. _MakeWaveBombTask -> aiMilitaryMgr.Enqueue(TaskF::Common(BOMB)) is the
     script/native (API) crossover.
  4. MilitaryManager.cpp, case BOMB: task = new CBombTask(this, 2.0f/mod) -
     confirmed byte-identical to public CircuitAI even in the private fork.
  5. CBombTask::Update -> FindTarget() - Centrifugal's own rewrite (commit
     37146fd0, "Refactor and enhance support for area-effect weapons and
     cargo handling"): scores enemies by cost/health against the squad's
     summed weapon alpha (killCap = groupAlpha * cfg.killMargin), prefers a
     killable target over a merely damageable one, and picks mode AREA over
     FOCUS when the cheapest killable target clusters with cfg.areaMinTargets
     or more others inside cfg.areaRadius and the squad has more than one
     bomber.
  6. mode FOCUS -> Attack(frame, isGround), resolving to the stock (public
     and private fork agree) ISquadTask::Attack in SquadTask.cpp.
     mode AREA -> AttackArea(frame) - entirely Centrifugal's: a new function
     that lines the squad up abreast perpendicular to PickApproachDir()
     (also new: threat-aware bearing selection) and issues per-bomber
     ground-attack plus fight-away orders directly, rather than through
     ISquadTask::Attack.
  7. Both paths converge on stock CCircuitUnit calls - CmdAttackGround,
     CmdFightTo, Attack() - confirmed byte-identical to public CircuitAI.
  8. The ABI crossover, stock and unmodified regardless of the fork: these
     go through the Engine_handleCommand function pointer
     (SSkirmishAICallback.h) with COMMAND_UNIT_ATTACK=45 / COMMAND_UNIT_
     FIGHT=44 (AISCommands.h) and a plain C command struct
     (SAttackUnitCommand / SFightUnitCommand) - the actual DLL/engine
     boundary, unrelated to CircuitAI itself being a private fork.

So: the count gate and the hold/release bookkeeping in this file are ours;
the dispatch (Enqueue / new CBombTask) and the final unit commands are stock
CircuitAI; the target-selection and area-formation logic in between is
Centrifugal's own, and is the piece actually worth re-reading in
BombTask.cpp if a wave's targeting looks wrong.

******************************************************************************/
namespace AirWaves {
    const float HoldPower = 1.0e9f;   // never reached: hold tasks must not self-promote

    // ---- roster (built once in Init) ----
    dictionary waveBomberDefs;   // def name -> true
    dictionary waveFighterDefs;

    // ---- hold ----
    dictionary heldBombers;      // id string -> int id
    dictionary heldFighters;
    int holdSinceFrame = -1;     // first frame the bomber hold was non-empty since the last launch

    // ---- release / wave ----
    dictionary launchQueue;      // id string -> int id, released units awaiting a wave task
    dictionary waveBombers;      // id string -> int id, launched bombers still alive
    dictionary waveFighters;     // id string -> int id, launched escorts still alive
    dictionary waveBombTasks;    // bomber def name -> IUnitTask@, release window only
    IUnitTask@ waveTask = null;  // the launched wave's CAirWaveTask, until it aborts itself
    dictionary mopUp;            // id string -> true: a native bomb task is still owed after the run
    int lastMethod = -1;         // Task::WaveMode of the last launch
    uint nextVipIdx = 0;
    int releaseUntilFrame = -1;  // >= 0 while released units are being re-tasked

    // ---- history / sizing ----
    int waveIndex = 0;
    int nextWaveSize = 0;
    int lastWaveSize = 0;
    int lastLaunchFrame = -1;
    int lastLaunchFighters = 0;
    int armadaWaveBombersQueued = 0;   // drives the 1-in-LicheEveryNthBomber Liche mix
    bool lastWaveEvaluated = true;

    // ---- fighter groups (Global::RoleSettings::Air::FighterGroupSize) ----
    // A fighter hold (CDefendTask) engages enemy air inside our defence influence,
    // and each new fighter got its own until holds met and merged, so fighters went
    // in one at a time as they were built (Baryon Tar Lake 2026-09-26: roughly one
    // Hawk lost per Hawk built, six waves launched with no escort). New fighters
    // now park - out of AI control via ai.UnitControl, holding position, as
    // BomberStock parks bombers - until FighterGroupSize are waiting, then go into
    // one shared hold task together. A launching wave takes them as escorts.
    const int FIGHTER_MOVE_HOLD_POS = 0;
    const int FIGHTER_MOVE_MANEUVER = 1;
    dictionary parkFighters;      // id string -> int id, new fighters waiting for their group
    dictionary parkedFighters;    // id string -> int id, of those, under CPlayerTask
    dictionary groupQueue;        // id string -> int id, released as a group, awaiting the group hold
    IUnitTask@ groupHoldTask = null;

    void Init()
    {
        waveBomberDefs.deleteAll();
        waveFighterDefs.deleteAll();
        {
            array<string> ids = UnitHelpers::GetAllT2WaveBombers();
            for (uint i = 0; i < ids.length(); ++i) waveBomberDefs.set(ids[i], true);
        }
        {
            array<string> ids = UnitHelpers::GetAllT2Fighters();
            for (uint i = 0; i < ids.length(); ++i) waveFighterDefs.set(ids[i], true);
        }
        heldBombers.deleteAll();
        heldFighters.deleteAll();
        launchQueue.deleteAll();
        waveBombers.deleteAll();
        waveFighters.deleteAll();
        waveBombTasks.deleteAll();
        @waveTask = null;
        mopUp.deleteAll();
        lastMethod = -1;
        nextVipIdx = 0;
        holdSinceFrame = -1;
        releaseUntilFrame = -1;
        waveIndex = 0;
        nextWaveSize = Global::RoleSettings::Air::BomberWaveFirstSize;
        lastWaveSize = 0;
        lastLaunchFrame = -1;
        lastLaunchFighters = 0;
        armadaWaveBombersQueued = 0;
        lastWaveEvaluated = true;
        parkFighters.deleteAll();
        parkedFighters.deleteAll();
        groupQueue.deleteAll();
        @groupHoldTask = null;
        GenericHelpers::LogUtil("[AIR][Waves] Init: enabled=" + (IsEnabled() ? "yes" : "no")
            + " first=" + Global::RoleSettings::Air::BomberWaveFirstSize
            + " max=" + Global::RoleSettings::Air::BomberWaveMaxSize
            + " fighterRatio=" + Global::RoleSettings::Air::BomberWaveFighterRatio, 2);
    }

    bool IsEnabled() { return Global::RoleSettings::Air::BomberWavesEnabled; }
    // Init only runs under the AIR role, so an empty roster means no AirWaves here.
    bool IsActive() { return IsEnabled() && waveBomberDefs.getSize() > 0; }

    // BomberStock entry: launch these bombers (plus any held escorts) as a wave now.
    void LaunchStock(const array<int>@ ids, const string &in reason)
    {
        if (!IsActive() || ids is null) return;
        _Launch(ai.frame, reason, ids);
    }
    bool IsWaveBomber(const CCircuitDef@ d) { return d !is null && waveBomberDefs.exists(d.GetName()); }
    bool IsWaveFighter(const CCircuitDef@ d) { return d !is null && waveFighterDefs.exists(d.GetName()); }

    // Fighters required to escort `bombers` (ratio rounded up).
    // Escorts buy nothing against ground AA: unit_aa_targeting_priority.lua
    // ranks bombers 0.1 against fighters 2, so AA ignores the screen and shoots
    // the bombers regardless. A fighter is only worth holding a wave for when
    // the enemy actually flies, so the ratio scales with their air investment
    // and collapses to zero against a purely ground defence.
    int FightersFor(int bombers)
    {
        const float ratio = Global::RoleSettings::Air::BomberWaveFighterRatio;
        if (ratio <= 0.0f || bombers <= 0) return 0;
        const float enemyAir = Military::GetCachedRoleCost("air")
            + Military::GetCachedRoleCost("bomber");
        if (enemyAir < Global::RoleSettings::Air::EscortMinEnemyAirCost) return 0;
        // Full ratio once the enemy air investment reaches the full-escort mark.
        const float full = AiMax(Global::RoleSettings::Air::EscortFullEnemyAirCost, 1.0f);
        const float scale = AiMin(enemyAir / full, 1.0f);
        const float want = float(bombers) * ratio * scale;
        int n = int(want);
        if (float(n) < want) ++n;
        return n;
    }

    /**************************************************************************
     Military::AiMakeTask entry. Returns null for units the wave system does
     not manage; the caller then takes the native default task.
     **************************************************************************/
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (!IsEnabled() || u is null || u.circuitDef is null) return null;
        const bool isBomber = IsWaveBomber(u.circuitDef);
        const bool isFighter = !isBomber && IsWaveFighter(u.circuitDef);
        if (!isBomber && !isFighter) return null;

        const string key = "" + u.id;
        if (launchQueue.exists(key)) {
            launchQueue.delete(key);
            if (ai.frame <= releaseUntilFrame) {
                IUnitTask@ t = isBomber ? _MakeWaveTaskFor(u) : _MakeEscortTask(u);
                if (t !is null) return t;
            }
            // Missed the window or nothing to join: park it for the next wave.
        }
        else if (isFighter && waveFighters.exists(key)) {
            // Escort whose bomber died while the wave still has living bombers.
            IUnitTask@ t = _MakeEscortTask(u);
            if (t !is null) return t;
            waveFighters.delete(key);
        }
        else if (isBomber && waveBombers.exists(key)) {
            if (mopUp.exists(key)) {
                // The planned run is over (CAirWaveTask aborted itself): one
                // native bomb task to finish what the carpet left, then home.
                mopUp.delete(key);
                IUnitTask@ t = _MakeWaveBombTask(u);
                if (t !is null) return t;
            }
            // Wave bomber back from its run (bomb task aborted or merged away): the
            // wave is over for this unit, it rejoins the pool.
            waveBombers.delete(key);
        }
        if (isFighter && Global::RoleSettings::Air::FighterGroupSize > 1) {
            // Released with its group: the group's shared hold.
            if (groupQueue.exists(key)) {
                groupQueue.delete(key);
                IUnitTask@ g = _MakeGroupHoldTask(u);
                if (g !is null) return g;
            }
            // Otherwise wait for a group: no task here (IsParking keeps the native
            // default away), Update parks it.
            if (!parkFighters.exists(key)) parkFighters.set(key, int(u.id));
            heldFighters.delete(key);   // back from a hold that ended: counted once, as waiting
            return null;
        }
        return _MakeHoldTask(u, isBomber);
    }

    /**************************************************************************
     Sizing floor from income (D-045).
     **************************************************************************/
    int IncomeFloor()
    {
        const float step = Global::RoleSettings::Air::BomberWaveIncomeStep;
        if (step <= 0.0f) return 0;
        const float mi = Economy::GetMinMetalIncomeLast10s();
        return int(mi / step) * Global::RoleSettings::Air::BomberWaveSizePerIncomeStep;
    }

    // What the next wave must hold: the survival-grown target or the income floor.
    int Required()
    {
        const int floor = IncomeFloor();
        int req = (nextWaveSize > floor) ? nextWaveSize : floor;
        const int hi = BomberStock::WaveCap(Global::RoleSettings::Air::BomberWaveMaxSize);   // 40 late
        return (req > hi) ? hi : req;
    }

    /**************************************************************************
     Attack methods (doc/air-wave-attacks.md).
     **************************************************************************/
    int _ChooseMethod()
    {
        array<float> w = {
            Global::RoleSettings::Air::WaveWeightCarpet, Global::RoleSettings::Air::WaveWeightFlank,
            Global::RoleSettings::Air::WaveWeightPincer, Global::RoleSettings::Air::WaveWeightStrike,
            Global::RoleSettings::Air::WaveWeightDeep, Global::RoleSettings::Air::WaveWeightFeint };
        float sum = 0.0f;
        for (uint i = 0; i < w.length(); ++i) { if (w[i] > 0.0f) sum += w[i]; }
        if (sum <= 0.0f) return Task::WaveMode::CARPET;
        const float roll = (float(AiRandom(0, 999)) + 0.5f) / 1000.0f * sum;
        float acc = 0.0f;
        for (uint i = 0; i < w.length(); ++i) {
            if (w[i] <= 0.0f) continue;
            acc += w[i];
            if (roll < acc) return int(i);
        }
        return Task::WaveMode::CARPET;
    }

    string MethodName(int m)
    {
        if (m == Task::WaveMode::CARPET) return "CARPET";
        if (m == Task::WaveMode::FLANK) return "FLANK";
        if (m == Task::WaveMode::PINCER) return "PINCER";
        if (m == Task::WaveMode::STRIKE) return "STRIKE";
        if (m == Task::WaveMode::DEEP) return "DEEP";
        if (m == Task::WaveMode::FEINT) return "FEINT";
        return "?";
    }

    // The point a carpet runs through: the current combat focus, else the
    // middle of the map.
    AIFloat3 _FrontAim()
    {
        AIFloat3 p = aiMilitaryMgr.GetCombatFocusPos();
        if (p.x < 0.0f || p.z < 0.0f) {
            p = AIFloat3(float(AiTerrainWidth()) * 0.5f, 0.0f, float(AiTerrainHeight()) * 0.5f);
        }
        return p;
    }

    // Build the launched wave's plan. Null when the native task could not be
    // made; the launch then uses the plain bomb tasks.
    IUnitTask@ _PlanWave(int bombers)
    {
        IUnitTask@ raw = aiMilitaryMgr.Enqueue(TaskF::Wave());
        IFighterTask@ ft = (raw is null) ? null : cast<IFighterTask>(raw);
        CAirWaveTask@ wt = (ft is null) ? null : cast<CAirWaveTask>(ft);
        if (wt is null) {
            GenericHelpers::LogUtil("[AIR][Waves] no CAirWaveTask; wave " + waveIndex + " flies the plain bomb task", 1);
            return null;
        }
        const float fd = Global::RoleSettings::Air::WaveFormDistance;
        const float sp = Global::RoleSettings::Air::WaveLaneSpacing;
        const float ov = Global::RoleSettings::Air::WaveOverrun;
        const int ft0 = Global::RoleSettings::Air::WaveFormTimeoutSeconds * SECOND;
        const float minCost = Global::RoleSettings::Air::WaveStrikeMinStaticCost;
        int method = _ChooseMethod();
        AIFloat3 aim = _FrontAim();
        string detail = "";
        if (method == Task::WaveMode::STRIKE || method == Task::WaveMode::DEEP) {
            const int pref = (method == Task::WaveMode::DEEP) ? 1 : 0;
            if (wt.PickStrikeTarget(Global::Map::StartPos, pref, minCost, true)) {
                aim = wt.GetAim();
                detail = " target=" + wt.GetStrikeTargetId();
            } else {
                GenericHelpers::LogUtil("[AIR][Waves] " + MethodName(method) + ": no qualifying target (statics >= "
                    + int(minCost) + " or T3); carpeting the front instead", 1);
                method = Task::WaveMode::CARPET;
            }
        }
        if (method == Task::WaveMode::CARPET) {
            wt.SetPlan(method, aim, fd, sp, ov, ft0, 0, 0.0f, 1);
        } else if (method == Task::WaveMode::FLANK) {
            const float lo = Global::RoleSettings::Air::WaveFlankMinDeg;
            const float hi = Global::RoleSettings::Air::WaveFlankMaxDeg;
            float deg = lo + (hi - lo) * float(AiRandom(0, 999)) / 999.0f;
            if (AiRandom(0, 1) == 1) deg = -deg;
            detail = " bearing=" + int(deg);
            wt.SetPlan(method, aim, fd, sp, ov, ft0, 0, deg, 1);
        } else if (method == Task::WaveMode::PINCER) {
            wt.SetPlan(method, aim, fd, sp, ov, ft0, 0, Global::RoleSettings::Air::WavePincerDeg, 2);
        } else if (method == Task::WaveMode::STRIKE || method == Task::WaveMode::DEEP) {
            wt.SetPlan(method, aim, fd, sp, ov, ft0, 0, Task::WAVE_SMART_BEARING, 1);
        } else {  // FEINT
            wt.SetPlan(method, aim, fd, sp, ov, ft0, Global::RoleSettings::Air::WaveFeintHoldSeconds * SECOND, 0.0f, 1);
        }
        lastMethod = method;
        GenericHelpers::LogUtil("[AIR][Waves] Wave " + waveIndex + " method=" + MethodName(method)
            + " aim=(" + int(aim.x) + "," + int(aim.z) + ")" + detail + " bombers=" + bombers
            + " standoff=" + int(fd) + " spacing=" + int(sp), 1);
        return raw;
    }

    // Air_MilitaryAiMakeTask: a fighter waiting for its group gets no task at all.
    bool IsParking(CCircuitUnit@ u)
    {
        return u !is null && parkFighters.exists("" + u.id);
    }

    // One hold task per released group, so its fighters start and fly as one squad.
    IUnitTask@ _MakeGroupHoldTask(CCircuitUnit@ u)
    {
        if (groupHoldTask is null) {
            @groupHoldTask = aiMilitaryMgr.Enqueue(TaskF::Defend(Task::FightType::MELEE, Task::FightType::AA, HoldPower));
            if (groupHoldTask is null) return null;
        }
        heldFighters.set("" + u.id, int(u.id));
        return groupHoldTask;
    }

    // Fighters counted toward escorts and production: held, parked, and released.
    int FighterPoolCount()
    {
        return int(heldFighters.getSize() + parkFighters.getSize() + groupQueue.getSize());
    }

    // Main update: park idle waiting fighters; release a full group.
    void _UpdateFighterGroups()
    {
        const int groupSize = Global::RoleSettings::Air::FighterGroupSize;
        if (groupSize <= 1) return;
        array<string>@ keys = parkFighters.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            int id = 0;
            if (!parkFighters.get(keys[i], id)) continue;
            CCircuitUnit@ u = ai.GetTeamUnit(id);
            if (u is null) { parkFighters.delete(keys[i]); parkedFighters.delete(keys[i]); continue; }
            if (parkedFighters.exists(keys[i])) continue;
            IUnitTask@ t = u.task;
            if (t is null || Task::Type(t.GetType()) != Task::Type::IDLE) continue;
            u.SetMoveState(FIGHTER_MOVE_HOLD_POS);   // fire at will, but never chase
            if (ai.UnitControl(u, false)) parkedFighters.set(keys[i], id);
        }
        if (int(parkFighters.getSize()) < groupSize) return;

        const int n = int(parkFighters.getSize());
        @groupHoldTask = null;   // this group gets a hold of its own
        _UnparkAllInto(@groupQueue);
        GenericHelpers::LogUtil("[AIR][Waves] fighter group of " + n + " released into the hold", 2);
    }

    // Hand every waiting fighter back to AI control and queue it in `into`.
    void _UnparkAllInto(dictionary@ into)
    {
        array<string>@ keys = parkFighters.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            int id = 0;
            if (!parkFighters.get(keys[i], id)) continue;
            CCircuitUnit@ u = ai.GetTeamUnit(id);
            if (u is null) continue;
            into.set(keys[i], id);
            u.SetMoveState(FIGHTER_MOVE_MANEUVER);
            IUnitTask@ t = u.task;
            if (t !is null && Task::Type(t.GetType()) == Task::Type::PLAYER) ai.UnitControl(u, true);
        }
        parkFighters.deleteAll();
        parkedFighters.deleteAll();
    }

    IUnitTask@ _MakeHoldTask(CCircuitUnit@ u, bool isBomber)
    {
        // Distinct promote types keep bomber and fighter holds from merging into
        // each other or into native riot holds (promote ATTACK). See header.
        const Task::FightType promote = isBomber ? Task::FightType::BOMB : Task::FightType::AA;
        IUnitTask@ t = aiMilitaryMgr.Enqueue(TaskF::Defend(Task::FightType::MELEE, promote, HoldPower));
        if (t is null) return null;
        dictionary@ held = isBomber ? @heldBombers : @heldFighters;
        held.set("" + u.id, int(u.id));
        if (isBomber && holdSinceFrame < 0) holdSinceFrame = ai.frame;
        return t;
    }

    IUnitTask@ _MakeWaveTaskFor(CCircuitUnit@ u)
    {
        if (waveTask !is null) return waveTask;
        return _MakeWaveBombTask(u);
    }

    IUnitTask@ _MakeWaveBombTask(CCircuitUnit@ u)
    {
        const string defName = u.circuitDef.GetName();
        IUnitTask@ t = null;
        if (!waveBombTasks.get(defName, @t) || t is null) {
            @t = aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::BOMB));
            if (t is null) return null;
            waveBombTasks.set(defName, @t);
        }
        return t;
    }

    // Guard the next living wave bomber (round-robin). CFGuardTask is deduplicated
    // per vip by CMilitaryManager::Enqueue, so fighters on the same bomber share
    // one task; the script assignment path does not apply the native guard cap.
    IUnitTask@ _MakeEscortTask(CCircuitUnit@ u)
    {
        array<string>@ vips = waveBombers.getKeys();
        for (uint tries = 0; tries < vips.length(); ++tries) {
            const string vipKey = vips[nextVipIdx++ % vips.length()];
            int vipId = 0;
            if (!waveBombers.get(vipKey, vipId)) continue;
            CCircuitUnit@ vip = ai.GetTeamUnit(vipId);
            if (vip is null) { waveBombers.delete(vipKey); continue; }
            IUnitTask@ t = aiMilitaryMgr.Enqueue(TaskF::Guard(vip));
            if (t is null) continue;
            waveFighters.set("" + u.id, int(u.id));
            return t;
        }
        return null;
    }

    /**************************************************************************
     Main update (Air_MainUpdate, every 30 frames).
     **************************************************************************/
    void Update()
    {
        if (!IsEnabled()) return;
        const int frame = ai.frame;
        _UpdateFighterGroups();
        if (releaseUntilFrame >= 0 && frame > releaseUntilFrame) _EndRelease();
        if (!lastWaveEvaluated && lastLaunchFrame >= 0
            && frame >= lastLaunchFrame + Global::RoleSettings::Air::BomberWaveEvaluateSeconds * SECOND) {
            _EvaluateLastWave();
        }
        if (releaseUntilFrame < 0) _TryLaunch(frame);
    }

    void _TryLaunch(int frame)
    {
        const int bombers = int(heldBombers.getSize());
        const int fighters = FighterPoolCount();
        if (bombers == 0) { holdSinceFrame = -1; return; }
        if (holdSinceFrame < 0) holdSinceFrame = frame;

        const int minSize = Global::RoleSettings::Air::BomberWaveFirstSize;
        const int required = Required();
        const bool targetReached = (bombers >= required) && (fighters >= FightersFor(required));
        // The time-out waives the escort requirement only: a side that cannot
        // field fighters must still launch with whatever escort it has. The
        // bomber floor stands - at high income a five-bomber wave was launching
        // against a floor of fifty (CR-013).
        const bool timedOut = (bombers >= minSize) && (bombers >= required)
            && (frame - holdSinceFrame) >= Global::RoleSettings::Air::BomberWaveMaxHoldSeconds * SECOND;
        if (!targetReached && !timedOut) return;
        _Launch(frame, targetReached ? ("target " + required + " reached (income floor " + IncomeFloor() + ")")
                                     : ("hold time-out at " + bombers + "/" + required));
    }

    // `stock` (BomberStock's parked batch) goes first; held bombers fill the
    // rest up to BomberWaveMaxSize. Stock bombers sit under a CPlayerTask, not
    // a hold, so they only need queueing: BomberStock hands them back to AI
    // control right after this returns.
    void _Launch(int frame, const string &in reason, const array<int>@ stock = null)
    {
        waveBombers.deleteAll();
        waveFighters.deleteAll();
        waveBombTasks.deleteAll();
        launchQueue.deleteAll();
        mopUp.deleteAll();
        @waveTask = null;
        nextVipIdx = 0;

        const int cap = BomberStock::WaveCap(Global::RoleSettings::Air::BomberWaveMaxSize);
        if (stock !is null) {
            for (uint i = 0; i < stock.length() && int(waveBombers.getSize()) < cap; ++i) {
                if (ai.GetTeamUnit(stock[i]) is null) continue;
                const string key = "" + stock[i];
                launchQueue.set(key, stock[i]);
                waveBombers.set(key, stock[i]);
                heldBombers.delete(key);
            }
        }
        array<IUnitTask@> aborted;
        _ReleaseHeld(@heldBombers, @waveBombers, @aborted, cap - int(waveBombers.getSize()));
        _ReleaseHeld(@heldFighters, null, @aborted, -1);
        // Waiting fighters, and a group not yet in its hold, go with the wave as escorts.
        _UnparkAllInto(@launchQueue);
        {
            array<string>@ gk = groupQueue.getKeys();
            for (uint i = 0; i < gk.length(); ++i) {
                int id = 0;
                if (groupQueue.get(gk[i], id)) launchQueue.set(gk[i], id);
            }
            groupQueue.deleteAll();
        }
        const int launchedBombers = int(waveBombers.getSize());
        const int launchedFighters = int(launchQueue.getSize()) - launchedBombers;

        ++waveIndex;
        @waveTask = _PlanWave(launchedBombers);
        {
            array<string>@ ids = waveBombers.getKeys();
            for (uint i = 0; i < ids.length(); ++i) mopUp.set(ids[i], true);
        }
        lastWaveSize = launchedBombers;
        lastLaunchFighters = launchedFighters;
        lastLaunchFrame = frame;
        lastWaveEvaluated = false;
        releaseUntilFrame = frame + Global::RoleSettings::Air::BomberWaveReleaseWindowSeconds * SECOND;
        holdSinceFrame = -1;
        // Provisional target until the survival ratio is known.
        nextWaveSize = _Clamp(int(float(lastWaveSize) * Global::RoleSettings::Air::BomberWaveGrowthDefault + 0.5f));

        GenericHelpers::LogUtil("[AIR][Waves] Wave " + waveIndex + " launched (" + reason + "): bombers=" + launchedBombers
            + " fighters=" + launchedFighters + " holdTasksAborted=" + aborted.length()
            + " provisionalNext=" + nextWaveSize, 1);
    }

    // Move up to `limit` held ids (all when negative) into the launch queue (and
    // `wave` when given) and abort each distinct hold task once. Only DEFEND
    // fighter tasks are aborted: a unit that is retreating or idle keeps that
    // task and takes its wave task when it next asks for one inside the release
    // window. Ids past the limit stay held; one that shared an aborted hold comes
    // back idle, is not in the launch queue, and re-enters the hold.
    void _ReleaseHeld(dictionary@ held, dictionary@ wave, array<IUnitTask@>@ aborted, int limit)
    {
        array<string>@ keys = held.getKeys();
        int released = 0;
        for (uint i = 0; i < keys.length(); ++i) {
            int id = 0;
            if (!held.get(keys[i], id)) continue;
            CCircuitUnit@ u = ai.GetTeamUnit(id);
            if (u is null) { held.delete(keys[i]); continue; }
            if (limit >= 0 && released >= limit) continue;
            ++released;
            held.delete(keys[i]);
            launchQueue.set(keys[i], id);
            if (wave !is null) wave.set(keys[i], id);

            IUnitTask@ t = u.task;
            if (t is null || Task::Type(t.GetType()) != Task::Type::FIGHTER) continue;
            IFighterTask@ ft = cast<IFighterTask>(t);
            if (ft is null || Task::FightType(ft.GetFightType()) != Task::FightType::DEFEND) continue;
            if (_ContainsTask(@aborted, t)) continue;
            aborted.insertLast(t);
            t.Abort();
        }
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
        waveBombTasks.deleteAll();
        releaseUntilFrame = -1;
        if (stragglers > 0) {
            GenericHelpers::LogUtil("[AIR][Waves] Release window closed with " + stragglers
                + " unit(s) never re-tasked; they rejoin the hold when idle", 2);
        }
    }

    void _EvaluateLastWave()
    {
        lastWaveEvaluated = true;
        const int survivors = int(waveBombers.getSize());
        const float survival = (lastWaveSize > 0) ? float(survivors) / float(lastWaveSize) : 1.0f;
        const float enemyAAMetal = Military::GetCachedRoleCost("anti_air");
        const float bomberCost = _WaveBomberCost();
        const int previous = nextWaveSize;
        nextWaveSize = ComputeNextWaveSize(lastWaveSize, survival, enemyAAMetal, bomberCost);
        GenericHelpers::LogUtil("[AIR][Waves] Wave " + waveIndex + " evaluated: launched=" + lastWaveSize
            + " survivors=" + survivors + " survival=" + survival + " enemyAAMetal=" + enemyAAMetal
            + " bomberCost=" + bomberCost + " next=" + nextWaveSize + " (provisional was " + previous + ")", 1);
    }

    /**************************************************************************
     Sizing. Pure function of the previous wave and the enemy anti-air, so it can
     be reasoned about from the settings alone:
       growth  = survival < Low  ? GrowthOnHeavyLoss
               : survival > High ? GrowthOnLightLoss
               :                   GrowthDefault
       next    = round(previous * growth)
       aaFloor = round(enemyAAMetal * EnemyAAMetalFraction / bomberCost)
       result  = clamp(max(next, aaFloor), FirstSize, MaxSize)
     **************************************************************************/
    int ComputeNextWaveSize(int previous, float survival, float enemyAAMetal, float bomberCost)
    {
        float growth = Global::RoleSettings::Air::BomberWaveGrowthDefault;
        if (survival < Global::RoleSettings::Air::BomberWaveLowSurvival) {
            growth = Global::RoleSettings::Air::BomberWaveGrowthOnHeavyLoss;
        } else if (survival > Global::RoleSettings::Air::BomberWaveHighSurvival) {
            growth = Global::RoleSettings::Air::BomberWaveGrowthOnLightLoss;
        }
        int next = int(float(previous) * growth + 0.5f);
        if (bomberCost > 0.0f && enemyAAMetal > 0.0f) {
            const int aaFloor = int(enemyAAMetal * Global::RoleSettings::Air::BomberWaveEnemyAAMetalFraction / bomberCost + 0.5f);
            if (next < aaFloor) next = aaFloor;
        }
        return _Clamp(next);
    }

    int _Clamp(int size)
    {
        const int lo = Global::RoleSettings::Air::BomberWaveFirstSize;
        const int hi = BomberStock::WaveCap(Global::RoleSettings::Air::BomberWaveMaxSize);   // 40 late
        if (size < lo) size = lo;
        if (size > hi) size = hi;
        return size;
    }

    float _WaveBomberCost()
    {
        const string name = UnitHelpers::GetT2WaveBomberForSide(Global::AISettings::Side);
        CCircuitDef@ d = (name.length() == 0) ? null : ai.GetCircuitDef(name);
        return (d is null) ? 0.0f : d.costM;
    }

    /**************************************************************************
     Production: called by the AIR factory handler for a T2 aircraft plant. One
     recruit per call; the factory asks again when idle. Bombers and fighters are
     grown together so the escort is ready when the bombers are.
     **************************************************************************/
    IUnitTask@ MakeProductionTask(CCircuitUnit@ factory, const string &in side, const AIFloat3 &in pos)
    {
        if (!IsEnabled() || factory is null) return null;
        if (Economy::GetMinMetalIncomeLast10s() < Global::RoleSettings::Air::BomberWaveProductionMetalIncome) return null;

        // With BomberStock on, the bombers wait in its park, not in heldBombers,
        // so count those against its wave size. Otherwise heldBombers stays 0,
        // every call orders another bomber, and nothing past this step (the
        // factory weights, which include Tyrannus) is ever built.
        const bool stock = BomberStock::IsEnabled();
        const int bombers = stock ? BomberStock::LiveCount() : int(heldBombers.getSize());
        const int required = stock ? BomberStock::WaveSize() : Required();
        const int fighters = FighterPoolCount();
        const int targetFighters = FightersFor(required);

        // Metal-starved (RoleAir METAL-STARVED MODE): bombers only, no escorts.
        const bool starved = RoleAir::Air_IsMetalStarved();
        string name = "";
        bool isWaveBomber = false;
        if (!starved && fighters < FightersFor(bombers) && fighters < targetFighters) {
            name = UnitHelpers::GetT2FighterForSide(side);      // escort lags the bombers
        } else if (bombers < required) {
            name = UnitHelpers::GetT2WaveBomberForSide(side);
            isWaveBomber = true;
            // Armada: once average metal income reaches LicheMinMetalIncome, every
            // LicheEveryNthBomber-th wave bomber is a Liche (7 Blizzards + 1 Liche).
            // armliche is in GetAllT2WaveBombers, so BomberStock parks and counts it
            // with the rest of the wave.
            const int everyNth = Global::RoleSettings::Air::LicheEveryNthBomber;
            if (side == "armada" && everyNth > 0
                && aiEconomyMgr.metal.income >= Global::RoleSettings::Air::LicheMinMetalIncome
                && (armadaWaveBombersQueued + 1) % everyNth == 0)
            {
                CCircuitDef@ liche = ai.GetCircuitDef("armliche");
                if (liche !is null && liche.IsAvailable(ai.frame)) name = "armliche";
            }
        } else if (!starved && fighters < targetFighters) {
            name = UnitHelpers::GetT2FighterForSide(side);
        }
        if (name.length() == 0) return null;

        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (d is null || !d.IsAvailable(ai.frame)) return null;
        GenericHelpers::LogUtil("[AIR][Waves] Production: " + name + " (" + (stock ? "stocked" : "held")
            + " bombers=" + bombers + "/" + required + " fighters=" + fighters + "/" + targetFighters + ")",
            name == "armliche" ? 2 : 3);
        IUnitTask@ t = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, d, pos, 64.f));
        if (t !is null && isWaveBomber && side == "armada") ++armadaWaveBombersQueued;
        return t;
    }

    /**************************************************************************
     Bookkeeping hooks.
     **************************************************************************/
    void OnUnitRemoved(CCircuitUnit@ u)
    {
        if (u is null) return;
        const string key = "" + u.id;
        heldBombers.delete(key);
        heldFighters.delete(key);
        launchQueue.delete(key);
        waveBombers.delete(key);
        waveFighters.delete(key);
        parkFighters.delete(key);
        parkedFighters.delete(key);
        groupQueue.delete(key);
    }

    void OnTaskRemoved(IUnitTask@ task)
    {
        if (task is null) return;
        if (groupHoldTask is task) @groupHoldTask = null;
        if (waveTask !is null && waveTask is task) {
            @waveTask = null;
            GenericHelpers::LogUtil("[AIR][Waves] Wave " + waveIndex + " run over; survivors mop up on the native bomb task", 1);
        }
        if (waveBombTasks.getSize() == 0) return;
        array<string>@ keys = waveBombTasks.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            IUnitTask@ t = null;
            if (waveBombTasks.get(keys[i], @t) && t is task) {
                waveBombTasks.delete(keys[i]);
            }
        }
    }
}  // namespace AirWaves
