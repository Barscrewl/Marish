// Spam: economy-gated mass production of cheap units sent down fixed routes.
#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/unit_helpers.as"
#include "../helpers/map_helpers.as"
#include "roster.as"
#include "widget_link.as"

/******************************************************************************

SPAM

Units carrying the "spam" attribute (behaviour.json "attribute": ["spam"],
read as Unit::Attr::SPAM) get a behaviour of their own once the economy
clears Global::Spam::MinMetalIncome and MinEnergyIncome (both, sliding 10 s
minimum; deactivation at ReleaseFraction of each so a dip does not flap):

  factories   Every T1 factory with an entry in Global::Spam::UnitByFactory
              produces that unit on repeat and nothing else while spam is
              active (Factory::AiMakeTask asks here first).
  routes      Each spam factory owns one native CRouteTask (TaskF::Route)
              holding a multi-step route from the factory to the destination.
              Routes of different factories run in parallel lanes: the k-th
              factory is offset sideways by LaneSpacing * (0, +1, -1, +2, ...)
              from the direct line, with two intermediate waypoints so the
              lane is held, not just the end point.
  units       A finished spam unit is assigned to its factory's route task
              from Military::AiMakeTask (nearest spam factory, units spawn at
              their factory). CRouteTask issues plain move orders only, so
              nothing on the way interrupts the run; the units hold at the
              destination and fire at whatever comes into range.
  focus       The destination is BehindEnemyDistance beyond the current focus
              along the line from our start through it, clamped to the map:
              behind the enemy line and past its radar and LOS when the map
              allows. The focus is an enemy start spot (map start spots minus
              our own and our allies' from the roster; with no map spots the
              mirror of our start through the map centre). It rotates through
              the enemy spots nearest-first every RefocusMinutes, and
              SetFocus(pos) retargets on demand. Every refocus rebuilds every
              factory route and the route task re-issues it to all units
              already on the field.

Everything here is data on the script side plus one native task type; the
task keeps only unit pointers it is told about through the normal assignment
path and drops them through the normal removal path.

******************************************************************************/
namespace Spam {
    bool active = false;
    int activeSinceFrame = -1;
    dictionary routeByFactory;     // factory id string -> CRouteTask@
    dictionary laneByFactory;      // factory id string -> int lane (0, 1, -1, 2, -2 ...)
    // D-119 (owner: each spam lab correlates to a lane; lanes spaced apart, spread
    // across the active front, straight to the enemy backline): a role may give a
    // factory a SPREAD lane: a line parallel to the axis from our start to the
    // enemy starts, at a sideways place across the front. It replaces the lane
    // number's offset for that factory
    dictionary spreadByFactory;    // factory id string -> float sideways place (elmos from the axis)
    int lanesIssued = 0;
    // D-111 (owner: each factory correlates directly to a lane): a spam unit
    // runs the lane of the factory that built it, for good; the nearest
    // factory only decides at its first sight (it spawns at its factory)
    dictionary producerOf;         // unit id string -> factory id
    int routesVersion = 0;         // bumped whenever any route changes (a role re-applies factory routes)
    // D-111: factories a role put on repeat: their queue cycles by itself, so a
    // factory that asks again is given a wait, not another build (the queue would
    // grow by one every unit); the build is re-issued only once it stopped producing
    dictionary repeatFactory;      // factory id string -> frame of the last build issued
    dictionary lastProduced;       // factory id string -> frame its last spam unit was seen
    dictionary routedUnits;        // unit id string -> factory id (INV-043)
    int routeCheckFrame = -1;
    // Two different points, previously conflated:
    //   focus  - WHERE THE RUN ENDS. An enemy start spot; the destination is
    //            BehindEnemyDistance past it. Rotates on the refocus timer.
    //   front  - WHERE THE RUN GOES THROUGH. The AI's current combat focus
    //            from aiMilitaryMgr.GetCombatFocusPos(): the leader of the
    //            strongest ATTACK squad, else the enemy centroid. Spam is
    //            worth most crossing the fight - vision and decoy targets
    //            where the shooting already is - and only then carrying on
    //            into the backline.
    AIFloat3 focus;
    bool hasFocus = false;
    int focusIdx = 0;
    int lastFocusFrame = -1;
    AIFloat3 front;
    bool hasFront = false;
    // Diagnostics. Activation is one line; everything between activation and a
    // unit actually moving used to be silent, so a game where spam activated
    // and then did nothing (Eight Horses, f=19115: "Activated", no "Route
    // created", ever) could not be told apart from one where no spam factory
    // existed. Both memos log only when the answer changes, so a factory that
    // asks every few seconds produces one line, not hundreds.
    dictionary rejectByFactory;    // factory id string -> last reason logged
    int lastIdleReportFrame = -1;

    bool IsEnabled()
    {
        if (!Global::Spam::Enabled) return false;
        if (Global::Map::LandLocked && !Global::Spam::AllowLandLocked) {
            if (!landLockedReported) {
                landLockedReported = true;
                GenericHelpers::LogUtil("[Spam] Off: this start is land-locked; the T1 factories keep their role logic (Global::Spam::AllowLandLocked)", 1);
            }
            return false;
        }
        return true;
    }
    bool landLockedReported = false;
    bool IsActive() { return active; }

    bool IsSpamDef(const CCircuitDef@ d)
    {
        return d !is null && d.IsAttrAny(Unit::Attr::SPAM.mask);
    }

    // The spam unit a factory produces, "" when the factory is not a spam factory.
    string SpamUnitFor(const CCircuitDef@ facDef)
    {
        if (facDef is null) return "";
        string name = "";
        if (!Global::Spam::UnitByFactory.get(facDef.GetName(), name)) return "";
        return name;
    }

    /**************************************************************************
     Activation (Main::AiUpdate, every 30 frames).
     **************************************************************************/
    void Update()
    {
        if (!IsEnabled()) return;
        const float mi = Economy::GetMinMetalIncomeLast10s();
        const float ei = Economy::GetMinEnergyIncomeLast10s();
        if (!active) {
            if (mi < Global::Spam::MinMetalIncome || ei < Global::Spam::MinEnergyIncome) {
                // Spam is a fusion-era behaviour by design: below this the same
                // units are ordinary front-line combat units and the roles should
                // keep using them as such. Report the shortfall occasionally so
                // "never activated" is distinguishable from "never evaluated".
                // Level 1, every two minutes: LOG_LEVEL is 1, and "never activated"
                // has to be tellable from "never evaluated" in a game log.
                if (lastIdleReportFrame < 0 || (ai.frame - lastIdleReportFrame) >= 2 * MINUTE) {
                    lastIdleReportFrame = ai.frame;
                    GenericHelpers::LogUtil("[Spam] Idle: mi=" + int(mi) + "/" + int(Global::Spam::MinMetalIncome)
                        + " ei=" + int(ei) + "/" + int(Global::Spam::MinEnergyIncome), 1);
                }
            }
            if (mi >= Global::Spam::MinMetalIncome && ei >= Global::Spam::MinEnergyIncome) {
                active = true;
                activeSinceFrame = ai.frame;
                _EnsureFocus();
                GenericHelpers::LogUtil("[Spam] Activated: mi=" + mi + " ei=" + ei + " focus=(" + int(focus.x) + "," + int(focus.z) + ")", 1);
                WidgetLink::Send("spam", "on|" + int(mi) + "|" + int(ei));
            }
            return;
        }
        const float rel = Global::Spam::ReleaseFraction;
        if (mi < Global::Spam::MinMetalIncome * rel || ei < Global::Spam::MinEnergyIncome * rel) {
            active = false;
            GenericHelpers::LogUtil("[Spam] Deactivated: mi=" + mi + " ei=" + ei + "; units on the field keep their routes", 1);
            WidgetLink::Send("spam", "off|" + int(mi) + "|" + int(ei));
            return;
        }
        CheckRoutedUnits();   // D-111: INV-043
        if (lastFocusFrame >= 0 && (ai.frame - lastFocusFrame) >= Global::Spam::RefocusMinutes * MINUTE) {
            NextFocus();
        }
        UpdateFront();
    }

    // Poll the AI's combat focus and rebuild every lane when it has moved far
    // enough to matter. This is the "route updated whenever the combat target
    // changed" half; the refocus timer above only moves the destination.
    void UpdateFront()
    {
        const AIFloat3 p = aiMilitaryMgr.GetCombatFocusPos();
        if (p.x < 0.0f) {   // invalid: no army and no known enemy
            return;
        }
        if (hasFront && MapHelpers::SqDist(p, front)
                < Global::Spam::FrontMoveThreshold * Global::Spam::FrontMoveThreshold) {
            return;
        }
        front = p;
        hasFront = true;
        RefreshRoutes();
        GenericHelpers::LogUtil("[Spam] Front moved to (" + int(p.x) + "," + int(p.z) + "); "
            + routeByFactory.getSize() + " route(s) rebuilt", 2);
        WidgetLink::Send("spam", "front|" + int(p.x) + "|" + int(p.z));
    }

    /**************************************************************************
     Focus (the target the routes lead behind).
     **************************************************************************/
    // Map start spots that are neither ours nor an ally's, nearest to us first.
    array<AIFloat3> EnemyStartSpots()
    {
        array<AIFloat3> result;
        StartSpot@[]@ spots = Global::Map::Config.StartSpots;
        if (spots is null || spots.length() == 0) return result;
        dictionary taken;
        const int own = MapHelpers::NearestSpotIdx(Global::Map::StartPos, spots);
        if (own >= 0) taken.set("" + own, true);
        array<Team::Roster::Entry@>@ allies = Team::Roster::All();
        for (uint i = 0; i < allies.length(); ++i) {
            if (allies[i].spotIndex >= 0) taken.set("" + allies[i].spotIndex, true);
        }
        array<float> dist;
        for (uint i = 0; i < spots.length(); ++i) {
            if (taken.exists("" + i)) continue;
            const float d = MapHelpers::SqDist(Global::Map::StartPos, spots[i].pos);
            uint pos = 0;
            while (pos < dist.length() && dist[pos] <= d) ++pos;
            result.insertAt(pos, spots[i].pos);
            dist.insertAt(pos, d);
        }
        return result;
    }

    AIFloat3 _MirrorOfStart()
    {
        const float w = float(aiTerrainMgr.GetTerrainWidth());
        const float h = float(aiTerrainMgr.GetTerrainHeight());
        return AIFloat3(w - Global::Map::StartPos.x, 0.0f, h - Global::Map::StartPos.z);
    }

    void _EnsureFocus()
    {
        if (hasFocus) return;
        focusIdx = 0;
        array<AIFloat3> enemies = EnemyStartSpots();
        SetFocus(enemies.length() > 0 ? enemies[0] : _MirrorOfStart());
    }

    void NextFocus()
    {
        array<AIFloat3> enemies = EnemyStartSpots();
        if (enemies.length() == 0) { SetFocus(_MirrorOfStart()); return; }
        focusIdx = (focusIdx + 1) % int(enemies.length());
        SetFocus(enemies[focusIdx]);
    }

    // Retarget every route and every unit already on the field.
    void SetFocus(const AIFloat3 &in pos)
    {
        focus = pos;
        hasFocus = true;
        lastFocusFrame = ai.frame;
        RefreshRoutes();
        GenericHelpers::LogUtil("[Spam] Focus set to (" + int(pos.x) + "," + int(pos.z) + "); " + routeByFactory.getSize() + " route(s) rebuilt", 1);
        WidgetLink::Send("spam", "focus|" + int(pos.x) + "|" + int(pos.z));
    }

    /**************************************************************************
     Routes.
     **************************************************************************/
    AIFloat3 _Clamp(const AIFloat3 &in p)
    {
        const float margin = Global::Spam::MapMargin;
        const float w = float(aiTerrainMgr.GetTerrainWidth());
        const float h = float(aiTerrainMgr.GetTerrainHeight());
        float x = p.x, z = p.z;
        if (x < margin) x = margin;
        if (x > w - margin) x = w - margin;
        if (z < margin) z = margin;
        if (z > h - margin) z = h - margin;
        return AIFloat3(x, 0.0f, z);
    }

    // Destination: BehindEnemyDistance past the focus on the line from our start.
    AIFloat3 Destination()
    {
        float dx = focus.x - Global::Map::StartPos.x;
        float dz = focus.z - Global::Map::StartPos.z;
        float len = sqrt(dx * dx + dz * dz);
        if (len < 1.0f) { dx = 1.0f; dz = 0.0f; len = 1.0f; }
        const float d = Global::Spam::BehindEnemyDistance;
        return _Clamp(AIFloat3(focus.x + dx / len * d, 0.0f, focus.z + dz / len * d));
    }

    // Factory -> two lane waypoints -> destination. Lane k is offset sideways by
    // LaneSpacing * k from the direct line so several factories run in parallel.
    array<AIFloat3> BuildRoute(const AIFloat3 &in from, int lane)
    {
        array<AIFloat3> route;
        const AIFloat3 to = Destination();
        float dx = to.x - from.x;
        float dz = to.z - from.z;
        float len = sqrt(dx * dx + dz * dz);
        if (len < 1.0f) { route.insertLast(to); return route; }
        const float nx = -dz / len;   // left-hand normal
        const float nz = dx / len;
        const float off = Global::Spam::LaneSpacing * float(lane);

        // Via the front when we know where it is, otherwise the old straight
        // run. The lane offset is applied to every waypoint including the
        // destination, so parallel lanes stay parallel the whole way instead
        // of converging on one point.
        if (hasFront) {
            // Half way to the front, then the front itself: two waypoints hold
            // the lane on the approach, which one waypoint would not.
            route.insertLast(_Clamp(AIFloat3(from.x + (front.x - from.x) * 0.5f + nx * off, 0.0f,
                                             from.z + (front.z - from.z) * 0.5f + nz * off)));
            route.insertLast(_Clamp(AIFloat3(front.x + nx * off, 0.0f, front.z + nz * off)));
        } else {
            route.insertLast(_Clamp(AIFloat3(from.x + dx * 0.33f + nx * off, 0.0f, from.z + dz * 0.33f + nz * off)));
            route.insertLast(_Clamp(AIFloat3(from.x + dx * 0.66f + nx * off, 0.0f, from.z + dz * 0.66f + nz * off)));
        }
        route.insertLast(_Clamp(AIFloat3(to.x + nx * off, 0.0f, to.z + nz * off)));
        return route;
    }

    // D-119: the axis of the spread lanes: from our start toward the focus (the
    // enemy start the runs end behind); `nx, nz` sideways. Not the centre of all
    // unused start spots: on a many-spot map most of them are empty
    void _Axis(float &out ax, float &out az, float &out nx, float &out nz)
    {
        _EnsureFocus();
        ax = focus.x - Global::Map::StartPos.x; az = focus.z - Global::Map::StartPos.z;
        float len = sqrt(ax * ax + az * az);
        if (len < 1.0f) { ax = 1.0f; az = 0.0f; len = 1.0f; }
        ax /= len; az /= len;
        nx = -az; nz = ax;
    }
    float _Along(const AIFloat3 &in p, float ax, float az) { return (p.x - Global::Map::StartPos.x) * ax + (p.z - Global::Map::StartPos.z) * az; }
    float _Side(const AIFloat3 &in p, float nx, float nz) { return (p.x - Global::Map::StartPos.x) * nx + (p.z - Global::Map::StartPos.z) * nz; }
    AIFloat3 _At(float along, float side, float ax, float az, float nx, float nz)
    {
        return AIFloat3(Global::Map::StartPos.x + ax * along + nx * side, 0.0f, Global::Map::StartPos.z + az * along + nz * side);
    }

    // The lab -> half way to its lane's front point -> its lane's front point ->
    // straight on to the enemy backline (BehindEnemyDistance past the focus), all
    // but the first leg on one line parallel to the axis
    array<AIFloat3> BuildSpreadRoute(const AIFloat3 &in from, float side)
    {
        float ax, az, nx, nz;
        _Axis(ax, az, nx, nz);
        const float back = _Along(focus, ax, az) + Global::Spam::BehindEnemyDistance;
        const float fromAlong = _Along(from, ax, az);
        float frontAlong = hasFront ? _Along(front, ax, az) : fromAlong + (back - fromAlong) * 0.5f;
        if (frontAlong < fromAlong + 200.0f) frontAlong = fromAlong + 200.0f;
        const AIFloat3 fp = _At(frontAlong, side, ax, az, nx, nz);
        array<AIFloat3> route;
        route.insertLast(_Clamp(AIFloat3((from.x + fp.x) * 0.5f, 0.0f, (from.z + fp.z) * 0.5f)));
        route.insertLast(_Clamp(fp));
        route.insertLast(_Clamp(_At(back, side, ax, az, nx, nz)));
        return route;
    }

    // D-119: spread lanes for these factories, one each, LaneSpacing apart, centred
    // on the active front (the combat focus; the axis while none is known), the
    // set shifted to stay on the map. Sorted by the labs' own sideways places, so
    // no two routes cross.
    void SetSpreadLanes(array<CCircuitUnit@>@ labs)
    {
        const uint n = labs.length();
        if (n == 0) return;
        float ax, az, nx, nz;
        _Axis(ax, az, nx, nz);
        const float step = Global::Spam::LaneSpacing;
        const float centre = hasFront ? _Side(front, nx, nz) : 0.0f;
        float first = centre - step * float(n - 1) * 0.5f;
        float last = first + step * float(n - 1);
        // on the map: the corners' sideways places, less the margin
        const float w = float(aiTerrainMgr.GetTerrainWidth()), h = float(aiTerrainMgr.GetTerrainHeight());
        const array<float> cx = { 0.0f, w, 0.0f, w }, cz = { 0.0f, 0.0f, h, h };
        float mlo = 1.0e30f, mhi = -1.0e30f;
        for (uint i = 0; i < 4; ++i) {
            const float s = _Side(AIFloat3(cx[i], 0.0f, cz[i]), nx, nz);
            if (s < mlo) mlo = s;
            if (s > mhi) mhi = s;
        }
        mlo += Global::Spam::MapMargin; mhi -= Global::Spam::MapMargin;
        if (last > mhi) { first -= last - mhi; last = mhi; }
        if (first < mlo) { last += mlo - first; first = mlo; }
        // the labs by their own sideways place
        array<CCircuitUnit@> order;
        array<float> key;
        for (uint i = 0; i < n; ++i) {
            if (labs[i] is null) continue;
            const float s = _Side(labs[i].GetPos(ai.frame), nx, nz);
            uint at = 0;
            while (at < key.length() && key[at] <= s) ++at;
            order.insertAt(at, labs[i]);
            key.insertAt(at, s);
        }
        bool changed = false;
        for (uint i = 0; i < order.length(); ++i) {
            const float side = first + step * float(i);
            const string k = "" + order[i].id;
            float cur = 0.0f;
            if (spreadByFactory.get(k, cur) && abs(cur - side) < 50.0f) continue;
            spreadByFactory.set(k, side);
            changed = true;
            CRouteTask@ task = null;
            if (routeByFactory.get(k, @task) && task !is null) task.SetRoute(BuildSpreadRoute(order[i].GetPos(ai.frame), side));
            GenericHelpers::LogUtil("[Spam] factory " + order[i].id + " runs spread lane " + (i + 1) + " of " + order.length()
                + " at " + int(side) + " elmos sideways (front at " + int(centre) + ", lanes " + int(step) + " apart) (D-119)", 1);
        }
        if (changed) ++routesVersion;
    }
    array<AIFloat3> _RouteOfKey(const string &in key, const AIFloat3 &in from)
    {
        float side = 0.0f;
        if (spreadByFactory.get(key, side)) return BuildSpreadRoute(from, side);
        int lane = 0;
        laneByFactory.get(key, lane);
        return BuildRoute(from, lane);
    }

    // D-111: a role fixes a factory's lane (TECH: the lab's place in its row)
    void SetFactoryLane(CCircuitUnit@ factory, int lane)
    {
        if (factory is null) return;
        const string key = "" + factory.id;
        int cur = 0;
        if (laneByFactory.get(key, cur) && cur == lane) return;
        laneByFactory.set(key, lane);
        CRouteTask@ task = null;
        if (routeByFactory.get(key, @task) && task !is null) {
            task.SetRoute(_RouteOfKey(key, factory.GetPos(ai.frame)));
            ++routesVersion;
        }
        GenericHelpers::LogUtil("[Spam] factory " + factory.id + " runs lane " + lane + " (D-111)", 1);
    }
    // D-111: the waypoints of a factory's lane, for its factory route
    array<AIFloat3> RouteOf(CCircuitUnit@ factory)
    {
        _EnsureFocus();
        return _RouteOfKey("" + factory.id, factory.GetPos(ai.frame));
    }
    void SetRepeatFactory(CCircuitUnit@ factory)
    {
        if (factory is null) return;
        const string key = "" + factory.id;
        int f;
        if (!repeatFactory.get(key, f)) repeatFactory.set(key, -100000);
    }

    int _NextLane()
    {
        // 0, +1, -1, +2, -2, ...
        const int n = lanesIssued++;
        if (n == 0) return 0;
        const int k = (n + 1) / 2;
        return (n % 2 == 1) ? k : -k;
    }

    // The route task of a factory, created on first use.
    CRouteTask@ RouteFor(CCircuitUnit@ factory)
    {
        if (factory is null) return null;
        const string key = "" + factory.id;
        CRouteTask@ task = null;
        if (routeByFactory.get(key, @task) && task !is null) return task;

        IUnitTask@ t = aiMilitaryMgr.Enqueue(TaskF::Route());
        IFighterTask@ ft = cast<IFighterTask>(t);
        @task = (ft is null) ? null : cast<CRouteTask>(ft);
        if (task is null) return null;
        int lane = 0;
        if (!laneByFactory.get(key, lane)) {
            lane = _NextLane();
            laneByFactory.set(key, lane);
        }
        _EnsureFocus();
        task.SetRoute(_RouteOfKey(key, factory.GetPos(ai.frame)));
        // Spread WITHIN the factory's line: each unit is dealt its own lane
        // across a band, so the stream crosses the map as a broad front that
        // one shell cannot erase and that sees a band's width, then focuses
        // back toward one endpoint. The factory-level offset above keeps
        // different factories' bands apart; this keeps one band from being a
        // single file.
        task.SetLanes(Global::Spam::UnitLanes, Global::Spam::UnitLaneSpacing, Global::Spam::EndSpread);
        routeByFactory.set(key, @task);
        ++routesVersion;
        GenericHelpers::LogUtil("[Spam] Route created for factory " + factory.id + " lane " + lane
            + " -> (" + int(Destination().x) + "," + int(Destination().z) + ")", 1);
        return task;
    }

    void RefreshRoutes()
    {
        array<string>@ keys = routeByFactory.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            CRouteTask@ task = null;
            if (!routeByFactory.get(keys[i], @task) || task is null) continue;
            CCircuitUnit@ factory = ai.GetTeamUnit(int(parseInt(keys[i])));
            if (factory is null) { task.Abort(); routeByFactory.delete(keys[i]); continue; }
            task.SetRoute(_RouteOfKey(keys[i], factory.GetPos(ai.frame)));
        }
        ++routesVersion;
    }

    // Nearest known spam factory to a position (spam units spawn at their factory).
    CCircuitUnit@ _NearestSpamFactory(const AIFloat3 &in pos)
    {
        CCircuitUnit@ best = null;
        float bestSq = 1e30f;
        array<string>@ keys = routeByFactory.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            CCircuitUnit@ f = ai.GetTeamUnit(int(parseInt(keys[i])));
            if (f is null) continue;
            const float sq = MapHelpers::SqDist(pos, f.GetPos(ai.frame));
            if (sq < bestSq) { bestSq = sq; @best = f; }
        }
        return best;
    }

    /**************************************************************************
     Hooks.
     **************************************************************************/
    // Factory::AiMakeTask asks here first. Returns null when this factory is not
    // producing spam right now, so the normal role logic runs.
    // Log `why` for this factory, but only when it differs from the last answer.
    void _Reject(CCircuitUnit@ factory, const string &in why)
    {
        const string key = "" + factory.id;
        string last = "";
        if (rejectByFactory.get(key, last) && last == why) return;
        rejectByFactory.set(key, why);
        if (why.length() == 0) return;   // memo cleared on success; nothing to say
        GenericHelpers::LogUtil("[Spam] " + factory.circuitDef.GetName() + " (" + factory.id
            + ") not spamming: " + why, 1);
    }

    IUnitTask@ FactoryMakeTask(CCircuitUnit@ factory)
    {
        if (!active || factory is null || factory.circuitDef is null) return null;
        const string unitName = SpamUnitFor(factory.circuitDef);
        if (unitName.length() == 0) {
            // Not a spam factory. Expected for every T2/T3/air/sea factory, so
            // this is the one rejection worth keeping quiet.
            return null;
        }
        CCircuitDef@ d = ai.GetCircuitDef(unitName);
        if (d is null) {
            _Reject(factory, "unit '" + unitName + "' is not a loaded def");
            return null;
        }
        if (!d.IsAvailable(ai.frame)) {
            // The likely cause when a listed T1 factory still exists and still
            // produces nothing: a role start limit or a reached unit cap makes
            // the spam unit unavailable.
            _Reject(factory, "'" + unitName + "' unavailable (tech gate or unit limit)");
            return null;
        }
        _Reject(factory, "");   // clears the memo so a later rejection logs again
        RouteFor(factory);   // make sure the lane exists before the first unit pops
        {
            const string key = "" + factory.id;
            int issued;
            // D-119: nothing calls SetRepeatFactory any more (TECH's spam labs
            // take one build per ask; a repeat queue did not survive a recruit)
            if (repeatFactory.get(key, issued)) {
                int seen = -100000;
                lastProduced.get(key, seen);
                const int since = (seen > issued) ? seen : issued;
                if (ai.frame - since < Global::Spam::RepeatStallSeconds * SECOND) {
                    return aiFactoryMgr.Enqueue(TaskS::Wait(false, 20 * SECOND));   // the repeat queue carries on
                }
                repeatFactory.set(key, ai.frame);
                GenericHelpers::LogUtil("[Spam] " + factory.circuitDef.GetName() + " (" + factory.id + ") on repeat: " + unitName + " queued (D-111)", 1);
            }
        }
        return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NOW, d, factory.GetPos(ai.frame), 64.f));
    }

    // Military::AiMakeTask asks here first. Spam units join their factory's route
    // while spam is active or while any route still exists (units built just
    // before deactivation still go).
    IUnitTask@ MilitaryMakeTask(CCircuitUnit@ u)
    {
        if (!IsEnabled() || u is null || !IsSpamDef(u.circuitDef)) return null;
        if (routeByFactory.getSize() == 0) return null;
        const string ukey = "" + u.id;
        int fid = -1;
        CCircuitUnit@ factory = null;
        if (producerOf.get(ukey, fid)) @factory = ai.GetTeamUnit(fid);
        if (factory is null) {
            const bool first = (fid < 0);
            @factory = _NearestSpamFactory(u.GetPos(ai.frame));
            if (factory is null) return null;
            producerOf.set(ukey, factory.id);
            if (first) lastProduced.set("" + factory.id, ai.frame);
        }
        CRouteTask@ task = RouteFor(factory);
        if (task is null) return null;
        routedUnits.set(ukey, factory.id);
        return task;
    }

    // INV-043 (D-111): a spam unit given its lane stays on it (a unit found on
    // another task names what took it: the owner saw routes cleared at once)
    void CheckRoutedUnits()
    {
        if (ai.frame - routeCheckFrame < 10 * SECOND) return;
        routeCheckFrame = ai.frame;
        array<string>@ keys = routedUnits.getKeys();
        int moved = 0;
        string example = "";
        for (uint i = 0; i < keys.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(int(parseInt(keys[i])));
            if (u is null) { routedUnits.delete(keys[i]); producerOf.delete(keys[i]); continue; }
            IFighterTask@ ft = (u.task is null) ? null : cast<IFighterTask>(u.task);
            CRouteTask@ rt = (ft is null) ? null : cast<CRouteTask>(ft);
            if (rt !is null) continue;
            ++moved;
            if (example.length() == 0) example = u.circuitDef.GetName() + " " + u.id + " now on task type " + ((u.task is null) ? -1 : int(u.task.GetType()));
            routedUnits.delete(keys[i]);
        }
        if (moved > 0) Invariants::Violation("INV-043", "spam", moved + " spam unit(s) left their lane (" + example + ")");
    }

    void OnFactoryRemoved(CCircuitUnit@ factory)
    {
        if (factory is null) return;
        const string key = "" + factory.id;
        CRouteTask@ task = null;
        if (routeByFactory.get(key, @task) && task !is null) {
            task.Abort();   // its units go idle and rejoin the nearest remaining route
        }
        routeByFactory.delete(key);
        laneByFactory.delete(key);
        spreadByFactory.delete(key);
        repeatFactory.delete(key);
        lastProduced.delete(key);
    }

    void OnTaskRemoved(IUnitTask@ task)
    {
        if (task is null || routeByFactory.getSize() == 0) return;
        array<string>@ keys = routeByFactory.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            CRouteTask@ t = null;
            if (routeByFactory.get(keys[i], @t) && t is task) routeByFactory.delete(keys[i]);
        }
    }
}  // namespace Spam
