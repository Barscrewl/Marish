// AIR's persistent advanced-economy modules, independent of the aircraft campus.
// Slots/claims and allied exclusion remain owned by the native layout service.
namespace AirEcoLayout {
    string Prefix() { return aiEconomyMgr.IsMetalMap() ? "air.fieldEco." : "air.eco."; }
    int ConverterSlots() { return aiEconomyMgr.IsMetalMap() ? 0 : 8; }
    class Module {
        string key;
        string side;
        int zone = 0;
        int facing = 0;
        bool started = false;
        array<int> slots; // reactor first, then advanced converters
    }
    array<Module@> modules;
    int retryAfter = 0;
    int planFrame = -100000;

    void Save(Module@ m)
    {
        aiTerrainMgr.SetLayoutInt(Prefix() + "count", int(modules.length()));
        aiTerrainMgr.SetLayoutInt(m.key + ".zone", m.zone);
        aiTerrainMgr.SetLayoutInt(m.key + ".facing", m.facing);
        aiTerrainMgr.SetLayoutInt(m.key + ".started", m.started ? 1 : 0);
        aiTerrainMgr.SetLayoutInt(m.key + ".side", m.side == "cortex" ? 1 : m.side == "legion" ? 2 : 0);
        aiTerrainMgr.SetLayoutInt(m.key + ".count", int(m.slots.length()));
        for (uint i = 0; i < m.slots.length(); ++i) aiTerrainMgr.SetLayoutInt(m.key + ".slot." + i, m.slots[i]);
    }
    void Init()
    {
        modules.resize(0); retryAfter = 0; planFrame = -100000;
        const int count = aiTerrainMgr.GetLayoutInt(Prefix() + "count", 0);
        for (int i = 0; i < count; ++i) {
            Module m;
            m.key = Prefix() + i;
            m.zone = aiTerrainMgr.GetLayoutInt(m.key + ".zone", 0);
            m.facing = aiTerrainMgr.GetLayoutInt(m.key + ".facing", AirLayout::facing);
            m.started = aiTerrainMgr.GetLayoutInt(m.key + ".started", 0) != 0;
            const int side = aiTerrainMgr.GetLayoutInt(m.key + ".side", 0);
            m.side = side == 1 ? "cortex" : side == 2 ? "legion" : "armada";
            const int n = aiTerrainMgr.GetLayoutInt(m.key + ".count", 0);
            for (int s = 0; s < AiMin(n, 9); ++s) m.slots.insertLast(aiTerrainMgr.GetLayoutInt(m.key + ".slot." + s, -1));
            modules.insertLast(m);
        }
    }
    bool NearReactor(const AIFloat3 &in pos, float separation)
    {
        for (uint i = 0; i < modules.length(); ++i) {
            Module@ m = modules[i];
            if (m.slots.length() > 0 && aiTerrainMgr.GetReservationState(m.slots[0]) >= 0
                && MapHelpers::SqDist(pos, aiTerrainMgr.GetReservationPos(m.slots[0])) < separation * separation) return true;
        }
        return false;
    }
    void ReleaseUnused(Module@ m)
    {
        for (uint i = 0; i < m.slots.length(); ++i) aiTerrainMgr.ReleasePersistentBuilding(m.slots[i]);
        if (m.zone > 0) aiTerrainMgr.ReleaseZone(m.zone);
        m.slots.resize(0); m.zone = 0; Save(m);
    }
    Module@ Reserve(const string &in side, Module@ reuse = null)
    {
        if (!AirLayout::enabled || ai.frame < retryAfter) return null;
        CCircuitDef@ reactor = ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(side));
        CCircuitDef@ converter = ai.GetCircuitDef(UnitHelpers::GetAdvEnergyConverterNameForSide(side));
        if (reactor is null || converter is null) return null;
        const int f = AirLayout::facing;
        const float rw = float(reactor.GetFootprintX()) * SQUARE_SIZE;
        const float rd = float(reactor.GetFootprintZ()) * SQUARE_SIZE;
        const float cw = float(converter.GetFootprintX()) * SQUARE_SIZE;
        const float cd = float(converter.GetFootprintZ()) * SQUARE_SIZE;
        const float pitch = 2.0f * cw + 16.0f;
        const float across = (ConverterSlots() == 0 ? rw : AiMax(rw, 1.5f * pitch + cw)) + 16.0f;
        const float bankZ = rd + Global::RoleSettings::Air::EcoConverterClearance + cd;
        const float front = ConverterSlots() == 0 ? rd : bankZ + 3.0f * cd + 16.0f;
        const float along = (front + rd) * 0.5f + 16.0f;
        const float shift = (front - rd) * 0.5f;
        // Fine candidate spacing can move an unused module around one blocker
        // without requiring another whole module-width of free land.
        const float step = 128.0f;
        const AIFloat3 anchor = AirLayout::Offset(Global::Map::StartPos, f, 0.0f, -900.0f);
        const int rings = 1 + int((Global::RoleSettings::Air::HomeEconomyRadius + 900.0f) / step);
        for (int ring = 0; ring <= rings; ++ring) {
            const int width = 2 * ring + 1;
            for (int cell = 0; cell < width * width; ++cell) {
                const int x = cell % width - ring, z = cell / width - ring;
                if (ring > 0 && x > -ring && x < ring && z > -ring && z < ring) continue;
                AIFloat3 at = AirLayout::Offset(anchor, f, float(x) * step, float(z) * step);
                if (!AirLayout::Inside(at, AiMax(across, front)) || !AirHome::EconomySite(at)
                    || NearReactor(at, Global::RoleSettings::Air::EcoReactorSpacing)) continue;
                bool near = AirLayout::bays.length() == 0 && MapHelpers::SqDist(at, Global::Map::StartPos)
                    < Global::RoleSettings::Air::EcoFactorySeparation * Global::RoleSettings::Air::EcoFactorySeparation;
                for (uint b = 0; b < AirLayout::bays.length(); ++b) {
                    AirLayout::Bay@ bay = AirLayout::bays[b];
                    if (bay.slot >= 0 && MapHelpers::SqDist(at, bay.centre)
                        < Global::RoleSettings::Air::EcoFactorySeparation * Global::RoleSettings::Air::EcoFactorySeparation) near = true;
                }
                if (near || !aiTerrainMgr.CanReserveBuilding(reactor, at, f)) continue;
                const AIFloat3 zone = AirLayout::Offset(at, f, 0.0f, shift);
                bool home = true;
                for (int corner = 0; corner < 4; ++corner)
                    if (!AirHome::EconomySite(AirLayout::Offset(zone, f, corner % 2 == 0 ? -across : across,
                        corner < 2 ? -along : along))) home = false;
                if (!home || !aiTerrainMgr.CanReserveArea(zone, f, across, along)) continue;
                array<int> slots;
                const int first = aiTerrainMgr.ReservePersistentBuilding(reactor, at, f);
                if (first < 0) continue;
                slots.insertLast(first);
                at = aiTerrainMgr.GetReservationPos(first);
                for (int s = 0; s < ConverterSlots(); ++s) {
                    const AIFloat3 p = AirLayout::Offset(at, f, (float(s % 4) - 1.5f) * pitch,
                        bankZ + float(s / 4) * (2.0f * cd + 16.0f));
                    const int id = aiTerrainMgr.ReservePersistentBuilding(converter, p, f);
                    if (id < 0) break;
                    slots.insertLast(id);
                }
                if (slots.length() != uint(1 + ConverterSlots())) {
                    for (uint s = 0; s < slots.length(); ++s) aiTerrainMgr.ReleasePersistentBuilding(slots[s]);
                    continue;
                }
                const int envelope = aiTerrainMgr.ReserveZone(AirLayout::Offset(at, f, 0.0f, shift), f, across, along, false);
                if (envelope <= 0) {
                    for (uint s = 0; s < slots.length(); ++s) aiTerrainMgr.ReleasePersistentBuilding(slots[s]);
                    continue;
                }
                Module@ m = reuse is null ? Module() : reuse;
                if (reuse is null) m.key = Prefix() + modules.length();
                m.side = side; m.facing = f; m.slots = slots;
                m.zone = envelope;
                if (reuse is null) modules.insertLast(m);
                Save(m);
                GenericHelpers::LogUtil("[AIR][EcoLayout] reserved " + m.key + " reactor=" + int(at.x) + "," + int(at.z)
                    + " converters=" + ConverterSlots() + " zone=" + m.zone, 1);
                return m;
            }
        }
        retryAfter = ai.frame + 10 * SECOND;
        return null;
    }
    Module@ Activate(Module@ m)
    {
        if (m.started) return m;
        if (m.slots.length() == 0) return Reserve(m.side, m);
        const int state = LayoutHelpers::ActivationState(m.slots);
        if (state == 2) { m.started = true; Save(m); return m; }
        if (state == 0) return m;
        GenericHelpers::LogUtil("[AIR][EcoLayout] relocate blocked unused " + m.key, 1);
        ReleaseUnused(m); retryAfter = 0;
        return Reserve(m.side, m);
    }
    void PlanAhead()
    {
        if (!AirLayout::enabled || ai.frame - planFrame < SECOND) return;
        if (MetalEconomy::Active() && AirLayout::bays.length() == 0) return;
        planFrame = ai.frame;
        int active = 0, planned = 0;
        Module@ retry = null;
        for (uint i = 0; i < modules.length(); ++i) {
            Module@ m = modules[i];
            if (!m.started && LayoutHelpers::ActivationState(m.slots) == 2) { m.started = true; Save(m); }
            if (m.started) ++active;
            if (m.slots.length() > 0) ++planned;
            else if (!m.started && retry is null) @retry = m;
        }
        if (planned < AirMath::PlannedBays(active, AiMax(2, Global::RoleSettings::Air::PlannedEcoModules)))
            Reserve(Global::AISettings::Side, retry);
    }
    bool Managed(const CCircuitDef@ d)
    {
        const string side = UnitHelpers::GetSideForUnitName(d.GetName());
        return d.GetName() == UnitHelpers::GetAdvFusionNameForSide(side)
            || d.GetName() == UnitHelpers::GetAdvEnergyConverterNameForSide(side);
    }
    IUnitTask@ Place(CCircuitUnit@ u, CCircuitDef@ d, Task::BuildType type, Task::Priority priority)
    {
        const string side = UnitHelpers::GetSideForUnitName(d.GetName());
        const bool reactor = d.GetName() == UnitHelpers::GetAdvFusionNameForSide(side);
        // One extra module is allowed when all existing slots of this kind are occupied.
        const uint count = modules.length();
        for (uint i = 0; i <= count; ++i) {
            Module@ m = i == count ? Reserve(side) : modules[i];
            if (m is null || m.side != side) continue;
            @m = Activate(m);
            if (m is null) continue;
            const uint limit = reactor && m.slots.length() > 0 ? 1 : m.slots.length();
            for (uint s = reactor ? 0 : 1; s < limit; ++s) {
                const int slot = m.slots[s];
                if (aiTerrainMgr.GetReservationState(slot) != 0 || !aiTerrainMgr.IsReservationBuildable(slot)) continue;
                if (!aiTerrainMgr.CanReachAt(u, aiTerrainMgr.GetReservationPos(slot), u.circuitDef.GetBuildDistance())) continue;
                IUnitTask@ task = AirLayout::Pinned(type, priority, d, slot);
                if (task is null) continue;
                m.started = true; Save(m);
                if (m.zone <= 0 || m.slots.length() != uint(1 + ConverterSlots()))
                    Invariants::Violation("INV-107", m.key, "AIR advanced economy order lacks its complete reserved module");
                GenericHelpers::LogUtil("[AIR][EcoLayout] place " + d.GetName() + " in " + m.key + " slot=" + slot, 1);
                return task;
            }
        }
        return null;
    }
    void Leave() { modules.resize(0); retryAfter = 0; planFrame = -100000; }
}
