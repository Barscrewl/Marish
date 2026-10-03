// Shared cohort task with stable ground-LOS spacing and straight MOVE ingress.
namespace AirRecon {
    dictionary waiting, placed, assembled, sweeping, destinations, surveying, originalCaps;
    array<AIFloat3> slots;
    AIFloat3 direction;
    float spacing = 0.0f;
    int columns = 0, nextCycle = 0;
    CRouteTask@ wall;
    string Name(const string &in side) { return side == "cortex" ? "corawac" : side == "legion" ? "legwhisper" : "armawac"; }
    bool Controlled(CCircuitUnit@ u) { return u !is null && (u.task is null || u.task.GetType() != int(Task::Type::PLAYER)); }
    void Unlock(CCircuitDef@ def)
    {
        if (def is null) return;
        if (!originalCaps.exists(def.GetName())) originalCaps.set(def.GetName(), int(def.maxThisUnit));
        def.maxThisUnit = 2147483647;
    }
    int FighterPlant()
    {
        int selected = -1, count = 0;
        const int prior = aiTerrainMgr.GetLayoutInt("air.fighterPlant", -1);
        bool retained = false;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.GetBuildProgress() < 1.0f || Lifecycle::IsRetiring(u)
                || !UnitHelpers::IsT2AircraftPlant(u.circuitDef.GetName())) continue;
            ++count;
            if (u.id == prior) retained = true;
            if (selected < 0 || u.id < selected) selected = u.id;
        }
        if (count < 2) return -1;
        if (retained) return prior;
        aiTerrainMgr.SetLayoutInt("air.fighterPlant", selected);
        return selected;
    }
    int ProductionTarget(CCircuitDef@ def)
    {
        if (def is null || ai.frame < nextCycle) return 0;
        int unavailable = 0;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef.GetName() != def.GetName()) continue;
            CRouteTask@ task;
            if (!Controlled(u) || (sweeping.get("" + u.id, @task) && task !is null && !task.IsDead() && u.task is task)) ++unavailable;
        }
        return unavailable + AiMax(1, Global::RoleSettings::Air::RadarWaveSize);
    }
    float Extent(const AIFloat3 &in at, float dx, float dz)
    {
        const float margin = AiMax(128.0f, Global::RoleSettings::Air::RadarBacklineInset);
        float length = 1.0e9f;
        if (dx > 0.0001f) length = AiMin(length, (float(AiTerrainWidth()) - margin - at.x) / dx);
        if (dx < -0.0001f) length = AiMin(length, (margin - at.x) / dx);
        if (dz > 0.0001f) length = AiMin(length, (float(AiTerrainHeight()) - margin - at.z) / dz);
        if (dz < -0.0001f) length = AiMin(length, (margin - at.z) / dz);
        return AiMax(0.0f, length);
    }
    bool Plan(const CCircuitDef@ def)
    {
        const int count = AiMax(1, Global::RoleSettings::Air::RadarWaveSize);
        array<AIFloat3> allies = Lanes::ScriptStarts(false), enemies = Lanes::ScriptStarts(true);
        AIFloat3 home = Global::Map::StartPos, enemy = AirScreen::Enemy(home);
        if (allies.length() > 0) {
            home = AIFloat3(0,0,0);
            for (uint i = 0; i < allies.length(); ++i) { home.x += allies[i].x; home.z += allies[i].z; }
            home.x /= float(allies.length()); home.z /= float(allies.length());
        }
        if (enemies.length() > 0) {
            enemy = AIFloat3(0,0,0);
            for (uint i = 0; i < enemies.length(); ++i) { enemy.x += enemies[i].x; enemy.z += enemies[i].z; }
            enemy.x /= float(enemies.length()); enemy.z /= float(enemies.length());
        }
        const float dx = enemy.x - home.x, dz = enemy.z - home.z;
        const float distance = sqrt(dx*dx + dz*dz);
        if (distance < 1.0f) return false;
        direction = AIFloat3(dx/distance, 0, dz/distance);
        spacing = AiMax(64.0f, AirMath::RadarSpacing(def.GetLosRadius(), Global::RoleSettings::Air::RadarSightOverlap));
        // Fit all members; clamping them individually would pile them onto edges.
        for (int attempt = 0; attempt < 24; ++attempt) {
          // Try deeper friendly staging before sacrificing the requested overlap.
          for (int site = 0; site < 8; ++site) {
            const float advance = 0.25f + float(site%4)*0.05f;
            AIFloat3 centre = AirScreen::Clamp(AIFloat3(home.x + direction.x*distance*advance, 0, home.z + direction.z*distance*advance));
            // A start near a side edge must not collapse the whole team's wall
            // into that corner. First centre its transverse axis on the map.
            if (site < 4) {
                const float across = (float(AiTerrainWidth())*0.5f-centre.x)*(-direction.z)
                    + (float(AiTerrainHeight())*0.5f-centre.z)*direction.x;
                centre.x -= direction.z*across; centre.z += direction.x*across;
            }
            const float span = 2.0f * AiMin(Extent(centre, -direction.z, direction.x), Extent(centre, direction.z, -direction.x));
            columns = AirMath::RadarColumns(count, span, spacing);
            slots.resize(0);
            bool valid = columns > 0;
            for (int i = 0; valid && i < count; ++i) {
                const int rank = i / columns;
                const int rowCount = AiMin(columns, count - rank*columns);
                const float across = (float(i%columns) - float(rowCount-1)*0.5f)*spacing;
                const float back = float(rank)*spacing;
                const AIFloat3 point(centre.x-direction.z*across-direction.x*back, 0, centre.z+direction.x*across-direction.z*back);
                valid = AirLayout::Inside(point, 256.0f) && AirHome::Friendly(point);
                slots.insertLast(point);
            }
            if (valid) {
                GenericHelpers::LogUtil("[AIR][Recon] formation slots=" + count + " columns=" + columns + " spacing=" + int(spacing) + " sight=" + int(def.GetLosRadius()), 1);
                return true;
            }
          }
            spacing *= 0.9f;
        }
        slots.resize(0);
        return false;
    }
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (!AirEconomy::Active() || !Controlled(u) || u.circuitDef.GetName() != Name(UnitHelpers::GetSideForUnitName(u.circuitDef.GetName()))) return null;
        const string key = "" + u.id;
        CRouteTask@ active;
        if (sweeping.get(key, @active) && active !is null && !active.IsDead()) return active;
        sweeping.delete(key); destinations.delete(key); surveying.delete(key);
        if (slots.length() == 0 && !Plan(u.circuitDef)) return null;
        if (wall is null || wall.IsDead()) {
            @wall = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            if (wall is null) return null;
            array<AIFloat3> route = {AirScreen::Anchor()};
            wall.SetAirControl(true); wall.SetTraversal(true, Global::RoleSettings::Air::RadarAssemblyRadius, false); wall.SetRoute(route);
            placed.deleteAll(); assembled.deleteAll();
        }
        // Excess donations wait for the next cohort; they never disappear from
        // the controller when the first twenty transfer to their sweep task.
        if (!waiting.exists(key)) waiting.set(key, -1);
        u.SetIdleMode(0); u.SetFireState(0);
        return wall;
    }
    void ScoutBases(CCircuitUnit@ u, CRouteTask@ task)
    {
        array<AIFloat3> bases = Lanes::ScriptStarts(true), route;
        AIFloat3 from = u.GetPos(ai.frame);
        for (int n = 0; n < 3 && bases.length() > 0; ++n) {
            int best = 0; float sq = 1.0e20f;
            for (uint b = 0; b < bases.length(); ++b) {
                const float distance = MapHelpers::SqDist(from, bases[b]);
                if (distance < sq) { best = int(b); sq = distance; }
            }
            from = AirScreen::Clamp(bases[best]); route.insertLast(from); bases.removeAt(best);
        }
        if (route.length() == 0) route.insertLast(AirScreen::Enemy(from));
        if (route.length() == 1) route.insertLast(AirScreen::Clamp(AIFloat3(route[0].x-direction.z*spacing*0.5f, 0, route[0].z+direction.x*spacing*0.5f)));
        task.SetPatrol(true);
        if (task.SetUnitRoute(u, route, Global::RoleSettings::Air::RadarAssemblyRadius)) {
            surveying.set("" + u.id, true);
            GenericHelpers::LogUtil("[AIR][Recon] nearby bases plane=" + u.id + " bases=" + route.length(), 1);
        }
    }
    void Tick()
    {
        array<string>@ away = sweeping.getKeys();
        for (uint i = 0; i < away.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(away[i])); CRouteTask@ task; sweeping.get(away[i], @task);
            if (!Controlled(u) || task is null || task.IsDead() || u.task !is task) {
                sweeping.delete(away[i]); destinations.delete(away[i]); surveying.delete(away[i]); continue;
            }
            AIFloat3 point;
            if (!surveying.exists(away[i]) && destinations.get(away[i], point)
                && MapHelpers::SqDist(u.GetPos(ai.frame), point) <= Global::RoleSettings::Air::RadarAssemblyRadius*Global::RoleSettings::Air::RadarAssemblyRadius) ScoutBases(u, task);
        }
        array<string>@ ids = waiting.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (!Controlled(u) || wall is null || wall.IsDead() || u.task !is wall) {
                waiting.delete(ids[i]); placed.delete(ids[i]); assembled.delete(ids[i]);
            }
        }
        @ids = waiting.getKeys();
        if (ids.length() == 0) return;
        if (slots.length() == 0 && !Plan(ai.GetTeamUnit(parseInt(ids[0])).circuitDef)) return;
        array<bool> used(slots.length(), false);
        for (uint i = 0; i < ids.length(); ++i) {
            int slot = -1; waiting.get(ids[i], slot);
            if (slot >= 0 && slot < int(used.length())) used[slot] = true;
        }
        uint available = 0;
        int ready = 0;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i])); int slot = -1; waiting.get(ids[i], slot);
            if (slot < 0 || slot >= int(slots.length())) {
                while (available < used.length() && used[available]) ++available;
                if (available >= used.length()) continue;
                slot = int(available); used[available] = true; waiting.set(ids[i], slot);
            }
            if (!placed.exists(ids[i])) {
                array<AIFloat3> route = {slots[slot]};
                if (wall.SetUnitRoute(u, route, Global::RoleSettings::Air::RadarAssemblyRadius)) placed.set(ids[i], true);
            }
            const float distance = MapHelpers::SqDist(u.GetPos(ai.frame), slots[slot]);
            const float radiusSq = Global::RoleSettings::Air::RadarAssemblyRadius*Global::RoleSettings::Air::RadarAssemblyRadius;
            if (placed.exists(ids[i]) && distance <= radiusSq) assembled.set(ids[i], true);
            // Fixed-wing aircraft orbit a reached position. Do not wait several
            // minutes for twenty orbit phases to coincide inside the inner disc.
            if (AirMath::RadarReady(assembled.exists(ids[i]), distance, Global::RoleSettings::Air::RadarAssemblyRadius)) ++ready;
        }
        const int wanted = AiMax(1, Global::RoleSettings::Air::RadarWaveSize);
        if (ready < wanted) return;
        CRouteTask@ sweep = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
        if (sweep is null) return;
        array<AIFloat3> initial = {AirScreen::Enemy(Global::Map::StartPos)};
        sweep.SetAirControl(true); sweep.SetTraversal(true, Global::RoleSettings::Air::RadarAssemblyRadius, false); sweep.SetRoute(initial);
        @ids = waiting.getKeys(); int sent = 0;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i])); int slot = -1; waiting.get(ids[i], slot);
            if (!Controlled(u) || slot < 0 || slot >= int(slots.length())) continue;
            const AIFloat3 start = slots[slot];
            const float travel = Extent(start, direction.x, direction.z);
            const AIFloat3 end(start.x+direction.x*travel, 0, start.z+direction.z*travel);
            if (aiMilitaryMgr.TransferUnit(u, sweep)) {
                array<AIFloat3> route = {end};
                if (!sweep.SetUnitRoute(u, route, Global::RoleSettings::Air::RadarAssemblyRadius))
                    Invariants::Violation("INV-123", "" + u.id, "recon member rejected straight MOVE route");
                sweeping.set(ids[i], @sweep); destinations.set(ids[i], end); waiting.delete(ids[i]); placed.delete(ids[i]); assembled.delete(ids[i]); ++sent;
            }
        }
        if (sent == 0) { sweep.Abort(); return; }
        if (sent != wanted) Invariants::Violation("INV-123", "radar cohort", "recon launch differs from assembled cohort");
        slots.resize(0); placed.deleteAll(); assembled.deleteAll();
        if (waiting.isEmpty()) @wall = null;
        else {
            @ids = waiting.getKeys();
            for (uint i = 0; i < ids.length(); ++i) waiting.set(ids[i], -1);
        }
        nextCycle = ai.frame + AiMax(1, Global::RoleSettings::Air::RadarWaveIntervalSeconds)*SECOND;
        GenericHelpers::LogUtil("[AIR][Recon] synchronized sweep=" + sent + " formed=" + ready + " spacing=" + int(spacing), 1);
    }
    void Reset()
    {
        if (wall !is null && !wall.IsDead()) wall.Abort();
        array<string>@ ids = sweeping.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CRouteTask@ task; sweeping.get(ids[i], @task);
            if (task !is null && !task.IsDead()) task.Abort();
        }
        @wall = null; waiting.deleteAll(); placed.deleteAll(); assembled.deleteAll(); sweeping.deleteAll(); destinations.deleteAll(); surveying.deleteAll(); slots.resize(0); nextCycle = 0;
        @ids = originalCaps.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitDef@ def = ai.GetCircuitDef(ids[i]); int cap = 0;
            if (def !is null && originalCaps.get(ids[i], cap)) def.maxThisUnit = cap;
        }
        originalCaps.deleteAll();
    }
}
