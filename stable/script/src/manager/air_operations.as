// AIR-only ownership shared by T1 raids, advanced strikes and defensive sorties.
// Store IDs, never long-lived non-owning unit handles.
namespace AirOperations {
    array<string> groundHeavyDefs;
    bool rosterReady = false;
    array<CAirWaveTask@> operations;
    array<bool> offensive;
    dictionary escorts; // unit ID -> owning wave (kept until the last bomber dies)
    bool Committed(int id)
    {
        IUnitTask@ task;
        const string key = "" + id;
        if (!escorts.get(key, @task)) return false;
        if (task !is null && !task.IsDead()) return true;
        escorts.delete(key);
        return false;
    }
    int AttachFighters(CAirWaveTask@ wave, bool attack = true)
    {
        operations.insertLast(wave); offensive.insertLast(attack);
        int count = 0;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.GetBuildProgress() < 1.0f || !AirScreen::IsFighter(u.circuitDef)
                || Committed(u.id) || (u.task !is null && u.task.GetType() == int(Task::Type::PLAYER))) continue;
            // Transfer only this member; aborting a shared wall task steals its neighbours.
            if (!aiMilitaryMgr.TransferUnit(u, wave)) continue;
            const string key = "" + u.id;
            IUnitTask@ owner = wave;
            escorts.set(key, @owner);
            AirProduction::home.delete(key); AirScreen::Removed(u.id);
            AirWaves::heldFighters.delete(key);
            ++count;
        }
        return count;
    }
    void Configure(CAirWaveTask@ wave, bool offensive, int preference)
    {
        wave.SetOperationPolicy(offensive, preference, Global::Map::StartPos,
            Global::RoleSettings::Air::StrikeEscortLead, Global::RoleSettings::Air::StrikeBacklineRiskLimit,
            Global::RoleSettings::Air::StrikeDistrictRadius);
        wave.SetAttackHandoffPolicy(Global::RoleSettings::Air::StrikeEarlyAttack,
            offensive ? Global::RoleSettings::Air::StrikeImmediatePriority : 0.0f,
            Global::RoleSettings::Air::StrikeImmediateRadius);
        if (offensive) {
            // A committed wave exhausts each class before descending. This also
            // lets new waves finish a defeated base after its named targets die.
            wave.AddTargetFallback(3); // preserve the existing frontline assault fallback
            wave.AddTargetFallback(4); // other economy and support structures
            wave.AddTargetFallback(7); // approved heavy ground units
            wave.AddTargetFallback(0); // remaining structures
            if (Global::RoleSettings::Air::StrikeCleanupMobile) wave.AddTargetFallback(8);
        }
        if (!rosterReady) {
            rosterReady = true;
            const array<string> gantries = UnitHelpers::GetAllGantries();
            const array<string> factories = UnitHelpers::GetAllLabs();
            for (int id = 1; id <= ai.GetDefCount(); ++id) {
                CCircuitDef@ def = ai.GetCircuitDef(id);
                if (def is null || !def.IsMobile() || def.IsAbleToFly()) continue;
                // A gantry may also offer lower-tier units (leggantuw builds
                // the T2 Telchine). Only gantry-exclusive outputs qualify for
                // expensive defensive bomber sorties; do not redefine their
                // shared UnitDef roles or other roles' targeting.
                bool lowerTier = false;
                for (uint f = 0; f < factories.length(); ++f) {
                    if (gantries.find(factories[f]) >= 0) continue;
                    CCircuitDef@ factory = ai.GetCircuitDef(factories[f]);
                    if (factory !is null && factory.CanBuild(def)) { lowerTier = true; break; }
                }
                if (lowerTier) continue;
                for (uint g = 0; g < gantries.length(); ++g) {
                    CCircuitDef@ gantry = ai.GetCircuitDef(gantries[g]);
                    if (gantry !is null && gantry.CanBuild(def)) { groundHeavyDefs.insertLast(def.GetName()); break; }
                }
            }
        }
        for (uint i = 0; i < groundHeavyDefs.length(); ++i) wave.AllowStrikeDef(ai.GetCircuitDef(groundHeavyDefs[i]), 1.0f);
        const array<string> sides = {"armada", "cortex", "legion"};
        for (uint i = 0; i < sides.length(); ++i) {
            wave.AllowStrikeDef(ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(sides[i])), 4.0f);
            wave.AllowStrikeDef(ai.GetCircuitDef(UnitHelpers::GetAdvEnergyConverterNameForSide(sides[i])), 3.0f);
        }
        // Factory classifications are authoritative and include all enabled factions/options.
        array<string> defs = UnitHelpers::GetAllLabs();
        for (uint i = 0; i < defs.length(); ++i) wave.AllowStrikeDef(ai.GetCircuitDef(defs[i]), 2.0f);
        array<AIFloat3> starts = Lanes::ScriptStarts(true);
        for (uint i = 0; i < starts.length(); ++i) wave.AddSearchPoint(starts[i]);
        if (starts.length() == 0) wave.AddSearchPoint(AirScreen::Enemy(Global::Map::StartPos));
    }
    void Tick()
    {
        for (int i = int(operations.length())-1; i >= 0; --i) {
            if (operations[i] is null || operations[i].IsDead()) { operations.removeAt(i); offensive.removeAt(i); }
            else if (offensive[i] && operations[i].GetState() == 5)
                Invariants::Violation("INV-116", "AIR", "offensive bomber operation entered return state");
        }
        array<string>@ ids = escorts.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            if (ai.GetTeamUnit(parseInt(ids[i])) is null) escorts.delete(ids[i]);
            else if (Committed(parseInt(ids[i]))) {
                IUnitTask@ owner; escorts.get(ids[i], @owner);
                CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
                if (u !is null && u.task !is owner && u.task !is null && u.task.GetType() != int(Task::Type::PLAYER))
                    Invariants::Violation("INV-115", ids[i], "committed fighter left its live bomber operation");
            }
        }
    }
    void Reset()
    {
        array<string>@ ids = escorts.getKeys();
        array<IUnitTask@> tasks;
        for (uint i = 0; i < ids.length(); ++i) {
            IUnitTask@ task; escorts.get(ids[i], @task);
            if (task !is null && !task.IsDead() && tasks.findByRef(task) < 0) tasks.insertLast(task);
        }
        escorts.deleteAll(); operations.resize(0); offensive.resize(0);
        for (uint i = 0; i < tasks.length(); ++i) tasks[i].Abort();
    }
}
