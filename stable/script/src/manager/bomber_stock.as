// T2 bombers: park every one built by its factory, "support" role/attribute, launch in waves of up to 20.
#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/unit_helpers.as"

/******************************************************************************

T2 BOMBER STOCKPILE (park at the factory, role/attribute swap)

Roster is UnitHelpers::GetAllT2WaveBombers() - armpnix, armstil, armliche,
corhurc, legphoenix. Every one of them built is added to the stock array and
counted; nothing is left free.

The park
--------
A stocked bomber gets no AI task at all. Military::AiMakeTask returns null for
it (Claims), so it sits in the idle task where the factory left it, and the next
Update takes it out of AI control with ai.UnitControl(u, false). That hands it a
native CPlayerTask - the task CircuitAI gives a unit a human has taken over -
whose Start, Update, OnUnitIdle and OnUnitDamaged are all empty: no fight or
move orders are ever issued and damage does not trigger a retreat. The rally
point is therefore the spot the bomber stopped at after leaving its factory.

Fire state is set to hold fire (0) and move state to hold position (0) while
parked, so the engine's own idle auto-targeting does not pull it off the spot
either.

Support role/attribute
----------------------
While the stock fills, each roster def has its main role replaced with
"support" and its "siege" attribute replaced with a "support" attribute; at
release both go back to the snapshot taken at the first swap (bomber, plus siege
where the config had it - armstil and legphoenix have none). Role and attribute
live on CCircuitDef, so the swap applies to every unit of the def at once, and
SetMainRole only sets mainRole: the role mask keeps "bomber" and "air". A parked
bomber has no task that reads either, so the swap does not drive the park.

Release
-------
At WaveSize() live stocked bombers (5, 8, 11, ... 20, 20 - see Global::BomberStock) the
first WaveSize() of them go; any extra (two plants finishing in the same update) stay
parked for the next wave. Restore role/attribute, restore fire state
(fire at will, 2) and move state (maneuver, 1), hand the ids to Cent's
AirWaves::_Launch (AIR role) so its launch queue holds them, then return each to
AI control with ai.UnitControl(u, true). IUnitTask::RemoveAssignee puts it in
the idle task, it re-enters Military::AiMakeTask, and takes its wave bomb task
from AirWaves - or, under any other role, a CBombTask from DefaultMakeTask.

Debug log (level 1), grep [AIR][Stock]:
  - role/attribute swapped to support, or restored to regular
  - each bomber parked, with its position and the live count
  - stock reached the current wave size of live bombers
  - attack wave launch called

******************************************************************************/
namespace BomberStock {
    const int FIRE_HOLD = 0;
    const int FIRE_AT_WILL = 2;
    const int MOVE_HOLD_POS = 0;
    const int MOVE_MANEUVER = 1;

    dictionary stocked;          // id string -> int id, counted bombers
    dictionary parked;           // id string -> int id, stocked and under CPlayerTask
    dictionary releasing;        // id string -> int id, launched, not yet re-tasked
    int releaseUntilFrame = -1;
    int waveIndex = 0;           // waves launched so far

    // A wave cap: `normalCap` (20), or Air::LateBomberWaveMaxSize (40) once the
    // late-game lift is open - LateBomberWaveMinutes in and the average metal
    // income at LateBomberWaveMetalIncome. Latched. Shared with AirWaves.
    bool lateCapOpen = false;
    int WaveCap(int normalCap)
    {
        if (!lateCapOpen && ai.frame >= Global::RoleSettings::Air::LateBomberWaveMinutes * MINUTE
            && aiEconomyMgr.metal.income >= Global::RoleSettings::Air::LateBomberWaveMetalIncome) {
            lateCapOpen = true;
            GenericHelpers::LogUtil("[AIR][Waves] Late bomber waves: cap " + normalCap + " -> "
                + Global::RoleSettings::Air::LateBomberWaveMaxSize + " (mi=" + int(aiEconomyMgr.metal.income) + ")", 1);
        }
        if (!lateCapOpen) return normalCap;
        return AiMax(normalCap, Global::RoleSettings::Air::LateBomberWaveMaxSize);
    }

    // Size of the next wave: 5, 8, 11, ... (Global::BomberStock), capped.
    int WaveSize()
    {
        int size = Global::BomberStock::FirstWaveSize + Global::BomberStock::WaveSizeGrowth * waveIndex;
        const int cap = WaveCap(Global::BomberStock::MaxWaveSize);
        if (size > cap) size = cap;
        if (size < 1) size = 1;
        return size;
    }

    array<string> rosterNames;
    dictionary bomberDefs;       // def name -> true
    bool rosterBuilt = false;

    // Snapshot of the regular state, per roster def, taken before the first swap.
    array<int> origMainRole;
    array<bool> origSiege;
    bool snapshotTaken = false;
    bool swappedToSupport = false;

    bool IsEnabled() { return Global::BomberStock::Enabled; }

    // "support" as an ATTRIBUTE: minted on demand, like "spam" in unit.as.
    TypeMask SUPPORT_ATTR = aiAttrMasker.GetTypeMask("support");

    void _BuildRoster()
    {
        rosterBuilt = true;
        bomberDefs.deleteAll();
        rosterNames = UnitHelpers::GetAllT2WaveBombers();
        for (uint i = 0; i < rosterNames.length(); ++i) bomberDefs.set(rosterNames[i], true);
    }

    bool IsStockBomber(const CCircuitDef@ d)
    {
        if (d is null) return false;
        if (!rosterBuilt) _BuildRoster();
        return bomberDefs.exists(d.GetName());
    }

    // Live stocked bombers, for AirWaves' production decision.
    int LiveCount() { return _LiveCount(); }

    // Live count. Prunes ids whose unit is gone.
    int _LiveCount()
    {
        array<string>@ keys = stocked.getKeys();
        int live = 0;
        for (uint i = 0; i < keys.length(); ++i) {
            int id = 0;
            if (!stocked.get(keys[i], id)) continue;
            if (ai.GetTeamUnit(id) is null) { stocked.delete(keys[i]); continue; }
            ++live;
        }
        return live;
    }

    void _TakeSnapshot()
    {
        if (snapshotTaken) return;
        if (!rosterBuilt) _BuildRoster();
        origMainRole.resize(rosterNames.length());
        origSiege.resize(rosterNames.length());
        for (uint i = 0; i < rosterNames.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(rosterNames[i]);
            origMainRole[i] = (d is null) ? int(Unit::Role::BOMBER.type) : int(d.GetMainRole());
            origSiege[i] = (d !is null) && d.IsAttrAny(Unit::Attr::SIEGE.mask);
        }
        snapshotTaken = true;
    }

    // Replace main role and attribute with "support" on every roster def.
    void _SwapToSupport(const string &in why)
    {
        _TakeSnapshot();
        string changed = "";
        for (uint i = 0; i < rosterNames.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(rosterNames[i]);
            if (d is null) continue;
            d.SetMainRole(Unit::Role::SUPPORT.type);
            if (origSiege[i]) d.DelAttribute(Unit::Attr::SIEGE.type);
            d.AddAttribute(SUPPORT_ATTR.type);
            if (changed.length() > 0) changed += ", ";
            changed += rosterNames[i];
        }
        swappedToSupport = true;
        GenericHelpers::LogUtil("[AIR][Stock] role+attribute -> 'support' on [" + changed + "] at frame "
            + ai.frame + " (" + why + ")", 1);
    }

    // Put back the regular main role (bomber) and attribute (siege, where it had it).
    void _RestoreRegular(const string &in why)
    {
        if (!snapshotTaken) return;
        string changed = "";
        for (uint i = 0; i < rosterNames.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(rosterNames[i]);
            if (d is null) continue;
            d.SetMainRole(Type(origMainRole[i]));
            d.DelAttribute(SUPPORT_ATTR.type);
            if (origSiege[i]) d.AddAttribute(Unit::Attr::SIEGE.type);
            if (changed.length() > 0) changed += ", ";
            changed += rosterNames[i] + (origSiege[i] ? "=bomber/siege" : "=bomber");
        }
        swappedToSupport = false;
        GenericHelpers::LogUtil("[AIR][Stock] role+attribute restored on [" + changed + "] at frame "
            + ai.frame + " (" + why + ")", 1);
    }

    /**************************************************************************
     Military::AiUnitAdded, role-independent: every roster bomber is counted.
     **************************************************************************/
    void OnUnitAdded(CCircuitUnit@ u, Unit::UseAs usage)
    {
        if (!IsEnabled() || u is null || u.circuitDef is null) return;
        if (!IsStockBomber(u.circuitDef)) return;
        stocked.set("" + u.id, int(u.id));
    }

    /**************************************************************************
     Military::AiMakeTask entry, ahead of every other policy. True for a stocked
     bomber: the caller returns no task, so it stays idle where the factory left
     it until Update parks it. A released bomber is consumed here and falls
     through to the normal path (AirWaves' launch queue under AIR).
     **************************************************************************/
    bool Claims(CCircuitUnit@ u)
    {
        if (!IsEnabled() || u is null) return false;
        const string key = "" + u.id;
        if (releasing.exists(key)) {
            releasing.delete(key);
            return false;
        }
        return stocked.exists(key);
    }

    // Take idle stocked bombers out of AI control: CPlayerTask issues nothing.
    void _ParkIdle()
    {
        array<string>@ keys = stocked.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            if (parked.exists(keys[i])) continue;
            int id = 0;
            if (!stocked.get(keys[i], id)) continue;
            CCircuitUnit@ u = ai.GetTeamUnit(id);
            if (u is null) continue;
            IUnitTask@ t = u.task;
            if (t is null || Task::Type(t.GetType()) != Task::Type::IDLE) continue;

            u.SetFireState(FIRE_HOLD);
            u.SetMoveState(MOVE_HOLD_POS);
            if (!ai.UnitControl(u, false)) continue;
            parked.set(keys[i], id);

            const AIFloat3 pos = u.GetPos(ai.frame);
            GenericHelpers::LogUtil("[AIR][Stock] parked " + u.circuitDef.GetName() + " id=" + id
                + " at (" + int(pos.x) + "," + int(pos.z) + ") -> " + _LiveCount() + "/"
                + WaveSize(), 1);
        }
    }

    /**************************************************************************
     Main::AiUpdate, every 30 frames.
     **************************************************************************/
    void Update()
    {
        if (!IsEnabled()) return;
        if (!rosterBuilt) _BuildRoster();

        if (releaseUntilFrame >= 0) {
            _PruneReleasing();
            if (releasing.getSize() > 0 && ai.frame <= releaseUntilFrame) return;
            releasing.deleteAll();
            releaseUntilFrame = -1;
        }
        if (!swappedToSupport) {
            _SwapToSupport(waveIndex == 0 ? "stockpile start" : "wave " + waveIndex + " re-tasked, stocking again");
        }

        _ParkIdle();
        const int live = _LiveCount();
        if (live >= WaveSize()) _Release(live);
    }

    void _PruneReleasing()
    {
        array<string>@ keys = releasing.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            int id = 0;
            if (!releasing.get(keys[i], id) || ai.GetTeamUnit(id) is null) releasing.delete(keys[i]);
        }
    }

    void _Release(int live)
    {
        const int size = WaveSize();   // this wave's size, before waveIndex moves on
        ++waveIndex;
        GenericHelpers::LogUtil("[AIR][Stock] ===== REACHED " + live + "/" + size
            + " live stocked bombers at frame " + ai.frame + " (wave " + waveIndex + "; next wave "
            + WaveSize() + ") =====", 1);

        _RestoreRegular("wave " + waveIndex + " launching");

        // At most `size` go; the rest stay stocked and parked for the next wave.
        array<int> ids;
        array<string>@ keys = stocked.getKeys();
        for (uint i = 0; i < keys.length() && int(ids.length()) < size; ++i) {
            int id = 0;
            if (!stocked.get(keys[i], id) || ai.GetTeamUnit(id) is null) continue;
            ids.insertLast(id);
            releasing.set(keys[i], id);
            stocked.delete(keys[i]);
            parked.delete(keys[i]);
        }
        releaseUntilFrame = ai.frame + Global::BomberStock::ReleaseWindowSeconds * SECOND;

        // Launch before handing control back, so the wave's launch queue already
        // holds these ids when they come back idle.
        if (AirWaves::IsActive()) {
            GenericHelpers::LogUtil("[AIR][Stock] calling AirWaves launch for " + ids.length()
                + " bomber(s) (wave " + waveIndex + ")", 1);
            AirWaves::LaunchStock(@ids, "stockpile reached " + live);
        } else {
            GenericHelpers::LogUtil("[AIR][Stock] no AirWaves (non-AIR role): " + ids.length()
                + " bomber(s) (wave " + waveIndex + ") re-task through DefaultMakeTask as bombers", 1);
        }

        // Back to AI control: CPlayerTask -> idle -> Military::AiMakeTask.
        // A bomber not parked yet is still idle and simply re-tasks.
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null) continue;
            u.SetFireState(FIRE_AT_WILL);
            u.SetMoveState(MOVE_MANEUVER);
            IUnitTask@ t = u.task;
            if (t !is null && Task::Type(t.GetType()) == Task::Type::PLAYER) ai.UnitControl(u, true);
        }
    }

    void OnUnitRemoved(CCircuitUnit@ u)
    {
        if (u is null) return;
        const string key = "" + u.id;
        stocked.delete(key);
        parked.delete(key);
        releasing.delete(key);
    }
}  // namespace BomberStock
