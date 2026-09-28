// Build power scaled to capped metal: construction turrets while the bank sits full.
#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/unit_helpers.as"

/******************************************************************************

BUILD POWER ON CAPPED METAL

Every role sizes its construction turrets from income (FRONT: energy income /
150, and only its primary T1 constructor places them; the factory helper stops
at 5 per T1 plant and 20 per T2 plant, counted at enqueue). None of that looks
at the bank. Supreme Isthmus 2026-09-27: from about 27 minutes on every FRONT,
AIR, SUPPORT and TACTICAL teammate sat at 14 000 - 16 000 metal, full, for the
rest of the game, and TECH's D-106 donations topped them up again.

Metal caps two ways and both end in a full bank:
  - income: we make more than our build power spends (income > pull);
  - trade:  metal arrives from teammates (TECH's D-106 share, overflow from a
            full ally) faster than we spend it.
So the trigger is the bank, not income: at CapFill of storage or more for
SustainSeconds, add construction turrets. How many per step comes from the
metal that is going unspent,

    surplus = max(income - pull, 0) + (bank - storage x TargetFill) / DrainSeconds

one turret per MetalPerNano of it (a 200 build power T1 turret spends about
8 metal/s on a typical unit), at most MaxPerStep a step and MaxInFlight queued
at once, MaxNanos in all. A step runs every IntervalSeconds while capping; the
bank has to fall below ReleaseFill to end the capped stretch.

Placement. A turret only spends metal where something is being built, so each
goes to a factory: gantries first, then T2 plants, then T1, fewest of our
turrets first, up to NanosPerT1Factory / NanosPerT2Factory / NanosPerGantry
each; water factories get the naval turret. With no factory it goes to the
start position, one at a time. A turret task that ends unbuilt (no site,
expired) rests its factory for MissRestSeconds so the next one tries elsewhere.

Energy. Build power spends energy too; while energy is stalling or below
MinEnergyFill nothing is added (a status line says so once a minute).

Unit caps. FRONT caps turrets by energy income (Front_IncomeNanoLimits); it
keeps the cap at or above CapFloor() so a turret queued here stays buildable,
and a step raises the def's cap itself when it is below that.

TECH is skipped (Global::BuildPower::SkipTech): its eco planner owns its build
power and its surplus goes to teammates through D-106.

Main::AiUpdate -> BuildPower::Update; Builder::AiTaskRemoved -> OnTaskRemoved.
Log, grep [BuildPower].

******************************************************************************/
namespace BuildPower {

    // Our queued turret tasks, the factory each is for (-1: start position) and its def.
    array<IUnitTask@> pendingTasks;
    array<int> pendingFactory;
    array<string> pendingDef;
    dictionary placedAt;         // factory id -> int, our turrets finished there
    dictionary restUntil;        // factory id -> int frame, rested after a miss

    int nextStepFrame = 0;
    int capSinceFrame = -1;      // first frame of the current capped stretch
    int statusFrame = -100000;
    int added = 0;               // turrets finished from here this game

    bool _RoleAllowed()
    {
        if (!Global::BuildPower::Enabled) return false;
        if (Global::BuildPower::SkipTech && Global::AISettings::Role == AiRole::TECH) return false;
        return Global::AISettings::Side.length() > 0;
    }

    // exists() first: a failed get leaves the value undefined, not 0.
    int _GetInt(dictionary@ d, const string &in key)
    {
        int v = 0;
        if (d.exists(key)) d.get(key, v);
        return v;
    }

    int _NanoCount()
    {
        const string side = Global::AISettings::Side;
        int n = 0;
        CCircuitDef@ land = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(side));
        if (land !is null) n += land.count;
        CCircuitDef@ naval = ai.GetCircuitDef(UnitHelpers::GetT1NavalNanoNameForSide(side));
        if (naval !is null) n += naval.count;
        return n;
    }

    int _QueuedOfDef(const string &in defName)
    {
        int n = 0;
        for (uint i = 0; i < pendingDef.length(); ++i) {
            if (pendingDef[i] == defName) ++n;
        }
        return n;
    }

    // The lowest turret cap a role may set while our tasks are queued: the live
    // turrets of a queued def plus ours of it still to be built. 0 when none.
    int CapFloor()
    {
        int floor = 0;
        for (uint i = 0; i < pendingDef.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(pendingDef[i]);
            if (d is null) continue;
            const int need = d.count + _QueuedOfDef(pendingDef[i]);
            if (need > floor) floor = need;
        }
        return floor;
    }

    int _FactoryTier(const string &in name)
    {
        if (UnitHelpers::IsLandGantry(name) || UnitHelpers::IsWaterGantry(name)) return 3;
        if (UnitHelpers::IsT2BotLab(name) || UnitHelpers::IsT2VehicleLab(name) || UnitHelpers::IsT2AircraftPlant(name)
            || UnitHelpers::IsT2Shipyard(name) || UnitHelpers::IsSeaplanePlatform(name)) {
            return 2;
        }
        return 1;
    }

    int _FactoryCap(int tier)
    {
        if (tier >= 3) return Global::BuildPower::NanosPerGantry;
        if (tier == 2) return Global::BuildPower::NanosPerT2Factory;
        return Global::BuildPower::NanosPerT1Factory;
    }

    int _PendingAt(int factoryId)
    {
        int n = 0;
        for (uint i = 0; i < pendingFactory.length(); ++i) {
            if (pendingFactory[i] == factoryId) ++n;
        }
        return n;
    }

    // The factory the next turret goes to: highest tier, then fewest of ours.
    // -1 when no factory has room.
    int _PickFactory()
    {
        array<string>@ keys = Factory::allFactories.getKeys();
        if (keys is null) return -1;
        int best = -1, bestTier = 0, bestHave = 0;
        for (uint i = 0; i < keys.length(); ++i) {
            const int id = int(parseInt(keys[i]));
            CCircuitUnit@ f = ai.GetTeamUnit(id);
            if (f is null || f.circuitDef is null) continue;
            if (ai.frame < _GetInt(restUntil, keys[i])) continue;
            const int tier = _FactoryTier(f.circuitDef.GetName());
            const int have = _GetInt(placedAt, keys[i]) + _PendingAt(id);
            if (have >= _FactoryCap(tier)) continue;
            if (best < 0 || tier > bestTier || (tier == bestTier && have < bestHave)) {
                best = id; bestTier = tier; bestHave = have;
            }
        }
        return best;
    }

    // Keep the def buildable for the turret about to be queued.
    void _EnsureCap(const string &in defName)
    {
        CCircuitDef@ d = ai.GetCircuitDef(defName);
        if (d is null) return;
        const int need = d.count + _QueuedOfDef(defName) + 1;
        if (d.maxThisUnit < need) {
            d.maxThisUnit = need;
            GenericHelpers::LogUtil("[BuildPower] " + defName + " cap raised to " + need, 2);
        }
    }

    // Queue one turret; true when a task was queued.
    bool _QueueOne(const string &in why)
    {
        const string side = Global::AISettings::Side;
        const int factoryId = _PickFactory();
        CCircuitUnit@ f = null;
        if (factoryId >= 0) @f = ai.GetTeamUnit(factoryId);
        AIFloat3 anchor = Global::Map::StartPos;
        bool water = false;
        string where = "the start position";
        if (f !is null && f.circuitDef !is null) {
            anchor = f.GetPos(ai.frame);
            water = UnitHelpers::FactoryIsWater(f.circuitDef.GetName());
            where = f.circuitDef.GetName() + " " + factoryId;
        } else if (_PendingAt(-1) > 0) {
            return false;   // one at a time at the start position
        }
        string defName = UnitHelpers::GetT1NanoNameForSide(side);
        if (water) defName = UnitHelpers::GetT1NavalNanoNameForSide(side);
        _EnsureCap(defName);

        const int timeout = Global::BuildPower::TaskTimeoutSeconds * SECOND;
        IUnitTask@ t = null;
        if (water) {
            @t = Builder::EnqueueT1NavalNano(side, anchor, SQUARE_SIZE * 24, timeout);
        } else {
            @t = Builder::EnqueueT1Nano(side, anchor, SQUARE_SIZE * 24, timeout, Task::Priority::HIGH);
        }
        if (t is null) return false;   // cooldown or def unavailable: next step

        pendingTasks.insertLast(t);
        pendingFactory.insertLast((f is null) ? -1 : factoryId);
        pendingDef.insertLast(defName);
        GenericHelpers::LogUtil("[BuildPower] " + defName + " queued at " + where + " (" + why + "; "
            + _NanoCount() + " turrets, " + pendingTasks.length() + " queued)", 1);
        return true;
    }

    /**************************************************************************
     Builder::AiTaskRemoved.
     **************************************************************************/
    void OnTaskRemoved(IUnitTask@ task, bool done)
    {
        if (task is null) return;
        for (uint i = 0; i < pendingTasks.length(); ++i) {
            if (pendingTasks[i] !is task) continue;
            const int factoryId = pendingFactory[i];
            const string key = "" + factoryId;
            pendingTasks.removeAt(i);
            pendingFactory.removeAt(i);
            pendingDef.removeAt(i);
            if (done) {
                ++added;
                if (factoryId >= 0) placedAt.set(key, _GetInt(placedAt, key) + 1);
            } else if (factoryId >= 0) {
                restUntil.set(key, ai.frame + Global::BuildPower::MissRestSeconds * SECOND);
                GenericHelpers::LogUtil("[BuildPower] turret for factory " + factoryId
                    + " ended unbuilt; that factory rests " + Global::BuildPower::MissRestSeconds + " s", 1);
            }
            return;
        }
    }

    /**************************************************************************
     Main::AiUpdate, every 30 frames.
     **************************************************************************/
    void Update()
    {
        if (ai.frame < nextStepFrame) return;
        nextStepFrame = ai.frame + Global::BuildPower::IntervalSeconds * SECOND;
        if (!_RoleAllowed()) return;
        if (ai.frame < Global::BuildPower::MinMinutes * MINUTE) return;

        const float storage = aiEconomyMgr.metal.storage;
        const float bank = aiEconomyMgr.metal.current;
        const float fill = (storage > 0.0f) ? bank / storage : 0.0f;
        if (fill < Global::BuildPower::ReleaseFill) {
            capSinceFrame = -1;
            return;
        }
        if (fill < Global::BuildPower::CapFill && !aiEconomyMgr.isMetalFull) return;   // in between: hold
        if (capSinceFrame < 0) capSinceFrame = ai.frame;
        const int cappedSeconds = (ai.frame - capSinceFrame) / SECOND;
        if (cappedSeconds < Global::BuildPower::SustainSeconds) return;

        const float income = aiEconomyMgr.metal.income;
        const float pull = aiEconomyMgr.metal.pull;
        const float over = bank - storage * Global::BuildPower::TargetFill;
        float surplus = AiMax(income - pull, 0.0f);
        if (over > 0.0f) surplus += over / float(AiMax(Global::BuildPower::DrainSeconds, 1));
        const float perNano = AiMax(Global::BuildPower::MetalPerNano, 1.0f);
        int want = int(surplus / perNano);
        if (float(want) * perNano < surplus) ++want;   // round up
        if (want < 1) want = 1;
        if (want > Global::BuildPower::MaxPerStep) want = Global::BuildPower::MaxPerStep;

        const float eStorage = aiEconomyMgr.energy.storage;
        const float eFill = (eStorage > 0.0f) ? aiEconomyMgr.energy.current / eStorage : 0.0f;
        const string state = "bank " + int(bank) + "/" + int(storage) + " for " + cappedSeconds + " s, +"
            + int(income) + " in, " + int(pull) + " pull, surplus " + int(surplus) + "/s";
        const bool statusDue = ai.frame - statusFrame >= MINUTE;
        if (aiEconomyMgr.isEnergyStalling || eFill < Global::BuildPower::MinEnergyFill) {
            if (statusDue) {
                statusFrame = ai.frame;
                GenericHelpers::LogUtil("[BuildPower] metal capping but energy is short (" + int(eFill * 100.0f)
                    + "% full" + (aiEconomyMgr.isEnergyStalling ? ", stalling" : "") + "): no turrets; " + state, 1);
            }
            return;
        }
        const int nanos = _NanoCount();
        if (nanos + int(pendingTasks.length()) >= Global::BuildPower::MaxNanos) {
            if (statusDue) {
                statusFrame = ai.frame;
                GenericHelpers::LogUtil("[BuildPower] metal capping at the turret limit (" + nanos + " + "
                    + pendingTasks.length() + " queued of " + Global::BuildPower::MaxNanos + "); " + state, 1);
            }
            return;
        }
        const int room = Global::BuildPower::MaxInFlight - int(pendingTasks.length());
        if (want > room) want = room;
        for (int i = 0; i < want; ++i) {
            if (!_QueueOne(state)) break;
        }
    }
}  // namespace BuildPower
