// FRONT / AIR near max metal: construction turrets on T2 plants and gantries, then another gantry.
#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/unit_helpers.as"
#include "../helpers/unitdef_helpers.as"

/******************************************************************************

BUILD POWER ON CAPPED METAL (FRONT and AIR)

Cent's TECH scales its economy far past what it can spend and trades the
surplus to the team (D-106: every teammate filled up to its free storage,
lowest first). FRONT and AIR size their construction turrets from income
(FRONT: energy / 150, placed only by its primary T1 constructor; the factory
helper stops at 5 per T1 plant and 20 per T2 plant, counted at enqueue) and
never from the bank. Supreme Isthmus 2026-09-27: from about 27 minutes every
FRONT and AIR teammate sat at 14 000 - 16 000 metal, full, to the end.

Metal fills two ways and both end in a full bank - our own income, and metal
traded in by TECH or overflowing from a full ally - so the trigger is the bank.

Turrets. Once the bank has been at CapFill of storage or more for
SustainSeconds, each step (IntervalSeconds) queues construction turrets at
the T2 plants and gantries - gantries first, fewest of our turrets first, up
to NanosPerT2Factory / NanosPerGantry each; naval turrets at water plants.
With no T2 plant or gantry at all the T1 plants take them (T1Fallback). How
many per step comes from the metal going unspent,

    surplus = max(income - pull, 0) + (bank - storage x TargetFill) / DrainSeconds

one turret per MetalPerNano of it, at most MaxPerStep a step, MaxInFlight
queued, MaxNanos in all. A turret task that ends unbuilt rests its plant for
MissRestSeconds. The capped stretch ends when the bank falls under ReleaseFill.

Gantry. When the bank has stayed at GantryFill or more for GantrySeconds
without a break - the turrets did not drain it - and income is at least
GantryMinIncome, one more land gantry is queued (Builder::EnqueueLandGantry,
at Cent's preferred factory position), up to MaxGantries, at most one in
flight and GantryIntervalSeconds apart. The gantry's own cap is raised for
it: AIR starts with every gantry capped at 0 and nothing lifts that (its
late-game gantry never fired in any 2026-09-27 game), and FRONT re-caps
gantries at 0 or 1 from income every economy update. A map's own gantry limit
(Global::Map::MergedUnitLimits) is respected.

Energy. Build power spends energy too: while energy stalls or is under
MinEnergyFill nothing is added (a status line says so once a minute).

Unit caps. FRONT keeps its turret and gantry caps at or above NanoCapFloor()
/ GantryCapFloor() so what is queued here stays buildable.

Main::AiUpdate -> Update; Builder::AiTaskRemoved -> OnTaskRemoved.
Log, grep [BuildPower].

******************************************************************************/
namespace BuildPower {

    // Our queued turret tasks, the plant each is for, and its def.
    array<IUnitTask@> pendingTasks;
    array<int> pendingFactory;
    array<string> pendingDef;
    dictionary placedAt;         // factory id -> int, our turrets finished there
    dictionary restUntil;        // factory id -> int frame, rested after a miss

    IUnitTask@ gantryTask = null;   // our gantry in flight
    int lastGantryFrame = -100000;
    int gantriesAdded = 0;

    int nextStepFrame = 0;
    int capSinceFrame = -1;      // first frame of the current capped stretch (CapFill)
    int fullSinceFrame = -1;     // first frame of the current unbroken stretch at GantryFill
    int statusFrame = -100000;

    bool _RoleAllowed()
    {
        if (!Global::BuildPower::Enabled || Global::AISettings::Side.length() == 0) return false;
        const AiRole role = Global::AISettings::Role;
        if (role == AiRole::FRONT) return Global::BuildPower::Front;
        // AIR on TECH's economy (manager/eco_role.as): its builders take work only
        // from TECH's rule table, which never takes these native orders, and the
        // queued turrets held Layout's turret count full, so TECH's own turret
        // rows placed none (All That Glitters 2026-09-28)
        if (role == AiRole::AIR) return Global::BuildPower::Air && !Global::RoleSettings::Air::ExperimentalEco;
        return false;
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

    // The lowest turret cap a role may set while our turret tasks are queued.
    int NanoCapFloor()
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

    // The lowest land-gantry cap a role may set: every gantry we added stays
    // allowed, plus the one in flight.
    int GantryCapFloor()
    {
        if (gantriesAdded == 0 && gantryTask is null) return 0;
        CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetLandGantryForSide(Global::AISettings::Side));
        const int standing = (d is null) ? 0 : d.count;
        return standing + ((gantryTask is null) ? 0 : 1);
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

    // The plant the next turret goes to: gantries, then T2 plants, fewest of
    // ours first; T1 plants only while there is no T2 plant or gantry at all.
    // -1 when none has room.
    int _PickFactory()
    {
        array<string>@ keys = Factory::allFactories.getKeys();
        if (keys is null) return -1;
        int best = -1, bestTier = 0, bestHave = 0;
        bool anyT2 = false;
        for (uint i = 0; i < keys.length(); ++i) {
            const int id = int(parseInt(keys[i]));
            CCircuitUnit@ f = ai.GetTeamUnit(id);
            if (f is null || f.circuitDef is null) continue;
            const int tier = _FactoryTier(f.circuitDef.GetName());
            if (tier >= 2) anyT2 = true;
            if (ai.frame < _GetInt(restUntil, keys[i])) continue;
            const int have = _GetInt(placedAt, keys[i]) + _PendingAt(id);
            if (have >= _FactoryCap(tier)) continue;
            if (best < 0 || tier > bestTier || (tier == bestTier && have < bestHave)) {
                best = id; bestTier = tier; bestHave = have;
            }
        }
        if (best >= 0 && bestTier < 2 && (anyT2 || !Global::BuildPower::T1Fallback)) return -1;
        return best;
    }

    // Keep a def buildable for the unit about to be queued; false when a map
    // limit forbids it.
    bool _EnsureCap(const string &in defName, int need)
    {
        CCircuitDef@ d = ai.GetCircuitDef(defName);
        if (d is null) return false;
        if (Global::Map::MergedUnitLimits.exists(defName)) {
            int mapLimit = 0;
            Global::Map::MergedUnitLimits.get(defName, mapLimit);
            if (need > mapLimit) return false;
        }
        if (d.maxThisUnit < need) {
            d.maxThisUnit = need;
            GenericHelpers::LogUtil("[BuildPower] " + defName + " cap raised to " + need, 2);
        }
        return true;
    }

    // Queue one turret; true when a task was queued.
    bool _QueueNano(const string &in why)
    {
        const string side = Global::AISettings::Side;
        const int factoryId = _PickFactory();
        if (factoryId < 0) return false;
        CCircuitUnit@ f = ai.GetTeamUnit(factoryId);
        if (f is null || f.circuitDef is null) return false;
        const AIFloat3 anchor = f.GetPos(ai.frame);
        const bool water = UnitHelpers::FactoryIsWater(f.circuitDef.GetName());
        string defName = UnitHelpers::GetT1NanoNameForSide(side);
        if (water) defName = UnitHelpers::GetT1NavalNanoNameForSide(side);
        CCircuitDef@ d = ai.GetCircuitDef(defName);
        if (d is null || !_EnsureCap(defName, d.count + _QueuedOfDef(defName) + 1)) return false;

        const int timeout = Global::BuildPower::TaskTimeoutSeconds * SECOND;
        IUnitTask@ t = null;
        if (water) {
            @t = Builder::EnqueueT1NavalNano(side, anchor, SQUARE_SIZE * 24, timeout);
        } else {
            @t = Builder::EnqueueT1Nano(side, anchor, SQUARE_SIZE * 24, timeout, Task::Priority::HIGH);
        }
        if (t is null) return false;   // cooldown or def unavailable: next step

        pendingTasks.insertLast(t);
        pendingFactory.insertLast(factoryId);
        pendingDef.insertLast(defName);
        GenericHelpers::LogUtil("[BuildPower] " + defName + " queued at " + f.circuitDef.GetName() + " " + factoryId
            + " (" + why + "; " + _NanoCount() + " turrets, " + pendingTasks.length() + " queued)", 1);
        return true;
    }

    void _TryGantry(float income, int fullSeconds, const string &in why)
    {
        if (gantryTask !is null) return;
        if (fullSeconds < Global::BuildPower::GantrySeconds) return;
        if (income < Global::BuildPower::GantryMinIncome) return;
        if (ai.frame < Global::BuildPower::GantryMinMinutes * MINUTE) return;
        if (ai.frame - lastGantryFrame < Global::BuildPower::GantryIntervalSeconds * SECOND) return;

        const string side = Global::AISettings::Side;
        const string name = UnitHelpers::GetLandGantryForSide(side);
        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (d is null) return;
        const int gantries = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllLandGantries());
        if (gantries >= Global::BuildPower::MaxGantries) return;
        if (!_EnsureCap(name, d.count + 1)) return;

        IUnitTask@ t = Builder::EnqueueLandGantry(side);
        if (t is null) return;   // gantry cooldown, or unavailable
        @gantryTask = t;
        lastGantryFrame = ai.frame;
        GenericHelpers::LogUtil("[BuildPower] metal maxed for " + fullSeconds + " s: gantry " + (gantries + 1) + "/"
            + Global::BuildPower::MaxGantries + " queued (" + name + "; " + why + ")", 1);
    }

    /**************************************************************************
     Builder::AiTaskRemoved.
     **************************************************************************/
    void OnTaskRemoved(IUnitTask@ task, bool done)
    {
        if (task is null) return;
        if (gantryTask !is null && gantryTask is task) {
            @gantryTask = null;
            if (done) ++gantriesAdded;
            GenericHelpers::LogUtil("[BuildPower] gantry " + (done ? "finished" : "ended unbuilt"), 1);
            return;
        }
        for (uint i = 0; i < pendingTasks.length(); ++i) {
            if (pendingTasks[i] !is task) continue;
            const string key = "" + pendingFactory[i];
            pendingTasks.removeAt(i);
            pendingFactory.removeAt(i);
            pendingDef.removeAt(i);
            if (done) {
                placedAt.set(key, _GetInt(placedAt, key) + 1);
            } else {
                restUntil.set(key, ai.frame + Global::BuildPower::MissRestSeconds * SECOND);
                GenericHelpers::LogUtil("[BuildPower] turret for factory " + key
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
        if (fill >= Global::BuildPower::GantryFill || aiEconomyMgr.isMetalFull) {
            if (fullSinceFrame < 0) fullSinceFrame = ai.frame;
        } else {
            fullSinceFrame = -1;
        }
        if (fill < Global::BuildPower::ReleaseFill) {
            capSinceFrame = -1;
            return;
        }
        if (fill < Global::BuildPower::CapFill && !aiEconomyMgr.isMetalFull) return;   // in between: hold
        if (capSinceFrame < 0) capSinceFrame = ai.frame;
        const int cappedSeconds = (ai.frame - capSinceFrame) / SECOND;
        if (cappedSeconds < Global::BuildPower::SustainSeconds) return;
        const int fullSeconds = (fullSinceFrame < 0) ? 0 : (ai.frame - fullSinceFrame) / SECOND;

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
                GenericHelpers::LogUtil("[BuildPower] metal near max but energy is short (" + int(eFill * 100.0f)
                    + "% full" + (aiEconomyMgr.isEnergyStalling ? ", stalling" : "") + "): nothing added; " + state, 1);
            }
            return;
        }

        _TryGantry(income, fullSeconds, state);

        const int nanos = _NanoCount();
        if (nanos + int(pendingTasks.length()) >= Global::BuildPower::MaxNanos) {
            if (statusDue) {
                statusFrame = ai.frame;
                GenericHelpers::LogUtil("[BuildPower] metal near max at the turret limit (" + nanos + " + "
                    + pendingTasks.length() + " queued of " + Global::BuildPower::MaxNanos + "); " + state, 1);
            }
            return;
        }
        const int room = Global::BuildPower::MaxInFlight - int(pendingTasks.length());
        if (want > room) want = room;
        int queued = 0;
        for (int i = 0; i < want; ++i) {
            if (!_QueueNano(state)) break;
            ++queued;
        }
        if (queued == 0 && want > 0 && statusDue && _PickFactory() < 0) {
            statusFrame = ai.frame;
            GenericHelpers::LogUtil("[BuildPower] metal near max but no T2 plant or gantry has room for a turret"
                + " (gantry after " + Global::BuildPower::GantrySeconds + " s at "
                + int(Global::BuildPower::GantryFill * 100.0f) + "%, now " + fullSeconds + " s); " + state, 1);
        }
    }
}  // namespace BuildPower
