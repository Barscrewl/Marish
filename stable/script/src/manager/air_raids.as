#include "air_waves.as"
// T1 reusable bombers have a separate pool; Legion gunships use native raiding.
namespace AirRaids {
    dictionary held;
    dictionary joining;
    dictionary cohort;
    CAirWaveTask@ wave = null;
    int lastTry = -100000;
    bool IsBomber(const CCircuitDef@ d)
    {
        return d !is null && (d.GetName() == "armthund" || d.GetName() == "corshad");
    }
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (!AirEconomy::Active() || u is null) return null;
        // Generic DEFEND waits for armed enemy groups and misses exposed eco.
        // Reuse the threat-aware raider's full enemy scan for this light gunship.
        if (u.circuitDef.GetName() == "legmos") return aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::RAID));
        if (!IsBomber(u.circuitDef)) return null;
        const string key = "" + u.id;
        if (joining.exists(key)) {
            joining.delete(key);
            if (wave !is null && !wave.IsDead()) return wave;
        }
        IUnitTask@ stage = AirWaves::StagingTask(u, true);
        if (stage !is null) held.set(key, true);
        return stage;
    }
    void Update()
    {
        if (!AirEconomy::Active() || ai.frame - lastTry < 10 * SECOND) return;
        lastTry = ai.frame;
        if (wave !is null && !wave.IsDead()) return;
        if (wave !is null) {
            int survivors = 0;
            array<string>@ ids = cohort.getKeys();
            for (uint i = 0; i < ids.length(); ++i) if (ai.GetTeamUnit(parseInt(ids[i])) !is null) ++survivors;
            GenericHelpers::LogUtil("[AIR][Raid] returned cohort=" + cohort.getSize() + " survivors=" + survivors, 1);
            cohort.deleteAll(); joining.deleteAll(); @wave = null;
        }
        if (int(held.getSize()) < Global::RoleSettings::Air::T1RaidMinimum
            || AirScreen::HomeValue() < AirEconomy::EnemyAir()) return;
        array<string>@ ids = held.getKeys();
        CCircuitUnit@ first = ai.GetTeamUnit(parseInt(ids[0]));
        if (first is null) { held.delete(ids[0]); return; }
        @wave = cast<CAirWaveTask>(aiMilitaryMgr.Enqueue(TaskF::Wave()));
        if (wave is null) return;
        AirWaves::ConfigureStrike(wave, ai.GetCircuitDef(first.circuitDef.GetName()), held);
        wave.SetMissionPolicy(Global::RoleSettings::Air::StrikeCorridorPadding,
            Global::RoleSettings::Air::StrikeEdgeInset, Global::RoleSettings::Air::StrikeUnknownReserve,
            Global::RoleSettings::Air::StrikeRiskScale, Global::RoleSettings::Air::StrikeArmyReserve,
            Global::RoleSettings::Air::StrikeLocalAaReserve, false);
        if (!wave.PickStrikeTarget(Global::Map::StartPos, 2, 30.0f, false)) {
            wave.Abort(); @wave = null; return;
        }
        wave.SetPlan(Task::WaveMode::STRIKE, wave.GetAim(), Global::RoleSettings::Air::WaveFormDistance,
            Global::RoleSettings::Air::StrikeLaneSpacing, Global::RoleSettings::Air::WaveOverrun,
            Global::RoleSettings::Air::WaveFormTimeoutSeconds * SECOND, 0, Task::WAVE_SMART_BEARING, 1);
        array<IUnitTask@> tasks;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (u is null) continue;
            joining.set(ids[i], true); cohort.set(ids[i], true);
            if (u.task !is null && tasks.findByRef(u.task) < 0) tasks.insertLast(u.task);
        }
        held.deleteAll();
        for (uint i = 0; i < tasks.length(); ++i) tasks[i].Abort();
        GenericHelpers::LogUtil("[AIR][Raid] launched bombers=" + joining.getSize() + " target=" + wave.GetStrikeTargetId(), 1);
    }
    void Removed(int id) { held.delete("" + id); joining.delete("" + id); }
    void Reset()
    {
        array<string>@ ids = held.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (u !is null) {
                u.SetFireState(u.circuitDef.GetFireState()); u.SetIdleMode(1);
                if (u.task !is null) u.task.Abort();
            }
        }
        if (wave !is null && !wave.IsDead()) wave.Abort();
        @wave = null; held.deleteAll(); joining.deleteAll(); cohort.deleteAll(); lastTry = -100000;
    }
}
