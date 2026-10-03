#include "../global.as"
#include "../helpers/economy_helpers.as"
#include "../helpers/unit_helpers.as"
#include "lifecycle.as"
#include "layout.as"
#include "team_economy.as"
#include "../roles/tech_forward.as"

// D-076: the invariants the TECH role promises, checked once a second in the
// game and written to the log as "[INVARIANT] INV-nnn ..." when broken. Every
// playtest check file forbids that line, so the benchmark loop is the
// regression suite; doc/invariants.md lists every id here and
// tools/knowledge/check_invariants.py keeps the two in step.
//
// Adding one: a Violation call with a new id, a row in doc/invariants.md, and
// the decision that introduced it names the invariant.
namespace Invariants {
    dictionary lastSaid;   // id|key -> frame last logged; one line a minute per subject

    bool inv50Done = false;   // D-120
    bool inv51Done = false;   // D-121
    dictionary inv53Idle;     // D-123: air constructor id -> samples in a row it did nothing
    void Violation(const string &in id, const string &in key, const string &in msg)
    {
        const string k = id + "|" + key;
        int64 last = -100000;
        lastSaid.get(k, last);
        if (ai.frame - int(last) < 60 * SECOND) return;
        lastSaid.set(k, int64(ai.frame));
        GenericHelpers::LogUtil("[INVARIANT] " + id + " " + msg, 1);
    }

    // INV-001: a retiring factory produces nothing. Called from the role's
    // unit-added hooks; a mobile unit appearing beside a retired factory is
    // the observable form of production continuing.
    void OnUnitAdded(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null || !u.circuitDef.IsMobile()) return;
        if (u.GetProducerId() >= 0 && Lifecycle::IsRetiringId(u.GetProducerId()))
            Violation("INV-001", "" + u.id, "a retiring factory produced " + u.circuitDef.GetName() + " " + u.id);
        // INV-010: no mobile combat unit under the plan's income gate (D-080)
        const string name = u.circuitDef.GetName();
        const bool builder = UnitHelpers::IsCommander(u.circuitDef) || UnitHelpers::GetConstructorTier(u.circuitDef) > 0 || UnitHelpers::IsAirConstructor(u.circuitDef)
            || UnitHelpers::GetAllRezBots().find(name) >= 0 || UnitHelpers::GetAllFastAssistBots().find(name) >= 0   // reclaimers and assist bots are build power, not combat
            || u.circuitDef.IsRoleAny(Unit::Role::TRANS.mask)   // D-093: the ferry's transport is logistics (played: armatlas and corvalk flagged)
            || TechHarbour::IsHarbourUnit(u.circuitDef);   // D-121 (owner): the harbour's sea units are built whatever the income
        const float mi = Economy::GetMinMetalIncomeLast10s();
        // D-160: Telchines use the separate coastal budget, admitted at enqueue
        // time. Completion may occur after income falls; ordinary combat keeps
        // its existing gate and Marauders are not exempted.
        const bool coastal = AmphibiousOps::Active() && AmphibiousOps::Kind(u.circuitDef)==0;
        if (!builder && !coastal && mi < TechPlan::CombatGate())
            Violation("INV-010", u.circuitDef.GetName(), "combat unit " + u.circuitDef.GetName() + " " + u.id + " produced at +" + int(mi) + " metal under the gate " + int(TechPlan::CombatGate()));
    }

    // INV-003: the chain never skips a step whose frame is under construction.
    void ChainStepSkipped(const string &in key, int unfinished)
    {
        if (unfinished > 0)
            Violation("INV-003", key, "chain step " + key + " skipped while " + unfinished + " frame(s) of it are under construction");
    }

    int frameId = -1;
    int frameSince = 0;
    int floatSince = -1;
    int afusSince = -1;
    int t2LabSince = -1;
    int lastLabTurretDist = -2;
    int lastLabFacing = -2;       // D-096: INV-018's log on change
    int lastLabExitCount = -1;
    int noForwardSince = -1;
    int turretsOverSince = -1;    // D-097: INV-019
    int fusionFramesLast = 0;     // D-100: INV-021
    int lastT1LabId = -1;         // D-101: INV-023
    int t1LabFramesLast = 0;      // D-102: INV-025
    int t2ConsHighSince = -1;     // D-103: INV-028
    dictionary factoriesSeen;     // D-104: INV-029
    dictionary retiredT2Seen;     // D-105: INV-031
    int overflowSince = -1;       // D-106: INV-033
    int airRolesOpenSince = -1;   // D-107: INV-034
    int airOffDutyLog = -100000;  // D-108: INV-035
    int roleCappedSince = -1;     // D-108: INV-036
    int roleCappedLog = -100000;  // D-108: INV-036
    int afusSeenCount = -1;       // D-108: INV-037
    int afusSeenFrame = -1;       // D-108: INV-037
    int fwdIdleLogT1 = -100000;   // D-109: INV-039
    int fwdIdleLogT2 = -100000;   // D-109: INV-039
    int ferryLog = -100000;       // D-110: INV-041, INV-042
    int baseFactorySince = -1;    // D-114: INV-044
    int baseFactoryLog = -100000; // D-114: INV-044
    int t2ConsAtHigh = 0;
    dictionary retiredLabsSeen;   // D-102: INV-026
    bool t1LabSeen = false;
    int ladderFloatSince = -1;
    dictionary energyFrames;   // energy def name -> unfinished count last tick (INV-009)
    dictionary offSince;   // reclaim target id -> frame turrets were first seen off it (INV-008)

    // D-175: every role checks the same overflow promise after sharing.
    void CheckTeamShare()
    {
        const float mStor = aiEconomyMgr.metal.storage;
        const bool high = TeamEconomy::OpeningReady() && mStor > 0.0f
            && aiEconomyMgr.metal.current >= Global::RoleSettings::Tech::TeamShareMetalAbove * mStor;
        if (!high) overflowSince = -1;
        else if (overflowSince < 0) overflowSince = ai.frame;
        else if (ai.frame - overflowSince >= 60 * SECOND) {
            int roomFor = -1;
            for (int i = 0; i < TeamEconomy::Count(); ++i) {
                const int tid = TeamEconomy::TeamAt(i);
                if (tid >= 0 && TeamEconomy::Alive(tid) && TeamEconomy::Frame(tid) >= 0
                    && TeamEconomy::Metal(tid, TeamEconomy::FREE) >= 0.25f * mStor) { roomFor = tid; break; }
            }
            if (roomFor >= 0)
                Violation("INV-033", "share", "metal over " + int(Global::RoleSettings::Tech::TeamShareMetalAbove * 100.0f)
                    + "% for 60 s while team " + roomFor + " has " + int(TeamEconomy::Metal(roomFor, TeamEconomy::FREE)) + " free");
            overflowSince = ai.frame;
        }
    }

    void Tick()
    {
        // INV-002: a frame of ours under construction has build power on it
        // within InvariantFrameSeconds (the nearest frame to the base is the
        // one watched; a chain leaves none further out).
        CCircuitUnit@ f = aiBuilderMgr.FindUnfinishedNear(Layout::BaseCentre(), Global::RoleSettings::Tech::ChainAssistRadius, null);
        const bool frame = (f !is null && f.circuitDef !is null && !f.circuitDef.IsMobile());
        if (!frame) {
            frameId = -1;
        } else {
            const float bp = aiBuilderMgr.GetBuildPowerNear(f.GetPos(ai.frame), Global::RoleSettings::Tech::InvariantFrameRadius);
            if (f.id != frameId || bp > 0.0f) { frameId = f.id; frameSince = ai.frame; }
            else if (ai.frame - frameSince >= int(Global::RoleSettings::Tech::InvariantFrameSeconds) * SECOND)
                Violation("INV-002", "" + f.id, f.circuitDef.GetName() + " " + f.id + " under construction has had no build power within "
                    + int(Global::RoleSettings::Tech::InvariantFrameRadius) + " for " + int(Global::RoleSettings::Tech::InvariantFrameSeconds) + " s");
        }

        // INV-004: metal does not float while a structure is under
        // construction and static build power is under the income target
        // (the owner's rule, D-075).
        const float stor = aiEconomyMgr.metal.storage;
        const float cur = aiEconomyMgr.metal.current;
        const float mi = Economy::GetMinMetalIncomeLast10s();
        const float bp = aiBuilderMgr.GetStaticBuildPowerNear(Layout::BaseCentre(), Global::RoleSettings::Tech::EcoBuildPowerRadius);
        const float target = mi * Global::RoleSettings::Tech::PowerBuildPowerPerMetal;
        const bool floating = (stor > 0.0f) && (cur >= Global::RoleSettings::Tech::InvariantFloatPercent * stor);
        if (floating && frame && bp < target) {
            if (floatSince < 0) floatSince = ai.frame;
            else if (ai.frame - floatSince >= int(Global::RoleSettings::Tech::InvariantFloatSeconds) * SECOND)
                Violation("INV-004", "float", "metal floating at " + int(cur) + " of " + int(stor) + " for " + int(Global::RoleSettings::Tech::InvariantFloatSeconds)
                    + " s while " + f.circuitDef.GetName() + " is under construction and static build power " + int(bp) + " is under " + int(target));
        } else {
            floatSince = -1;
        }

        // INV-006: no wind, solar or advanced solar stands InvariantReclaimSeconds
        // after an advanced fusion does (the owner's rule, D-077).
        const string side = Global::AISettings::Side;
        CCircuitDef@ afus = ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(side));
        if (!MetalEconomy::Active() && afus !is null && afus.count - aiBuilderMgr.GetUnfinishedCount(afus) > 0) {
            if (afusSince < 0) afusSince = ai.frame;
            else if (ai.frame - afusSince >= int(Global::RoleSettings::Tech::InvariantReclaimSeconds) * SECOND) {
                int left = 0;
                array<string> names = { UnitHelpers::GetWindNameForSide(side), UnitHelpers::GetSolarNameForSide(side), UnitHelpers::GetAdvSolarNameForSide(side) };
                for (uint i = 0; i < names.length(); ++i) { CCircuitDef@ d = ai.GetCircuitDef(names[i]); if (d !is null) left += d.count; }
                if (left > 0) Violation("INV-006", "energy", left + " wind/solar/advanced-solar structure(s) still stand " + int(Global::RoleSettings::Tech::InvariantReclaimSeconds) + " s after the advanced fusion");
            }
        } else {
            afusSince = -1;
        }

        // INV-009: no energy structure is ordered while energy floats (the
        // owner's rule, D-079): a new energy frame appearing while it floats.
        {
            const bool floats = !MetalEconomy::Active() && TechChain::EnergyFullSeconds() >= Global::RoleSettings::Tech::InvariantFloatOrderSeconds;   // metal fields fund production directly; no converter rung
            array<string> energy = { UnitHelpers::GetWindNameForSide(side), UnitHelpers::GetSolarNameForSide(side), UnitHelpers::GetAdvSolarNameForSide(side),
                                     UnitHelpers::GetFusionNameForSide(side), UnitHelpers::GetAdvFusionNameForSide(side) };
            for (uint i = 0; i < energy.length(); ++i) {
                CCircuitDef@ d = ai.GetCircuitDef(energy[i]);
                if (d is null) continue;
                const int now = aiBuilderMgr.GetUnfinishedCount(d);
                int64 before = 0; energyFrames.get(energy[i], before);
                if (now > int(before) && floats)
                    Violation("INV-009", energy[i], "a " + energy[i] + " frame appeared while " + TechChain::FloatWhy());
                energyFrames.set(energy[i], int64(now));
            }
        }

        // INV-011: past the objective the metal bank does not float while an
        // income step is unmet (D-080, the KI-415 promise)
        if (TechChain::LadderUnmet() && floating) {
            if (ladderFloatSince < 0) ladderFloatSince = ai.frame;
            else if (ai.frame - ladderFloatSince >= int(Global::RoleSettings::Tech::InvariantLadderFloatSeconds) * SECOND)
                Violation("INV-011", "ladder", "metal floating at " + int(cur) + " of " + int(stor) + " for " + int(Global::RoleSettings::Tech::InvariantLadderFloatSeconds) + " s with an income step of the plan unmet");
        } else ladderFloatSince = -1;

        // INV-013: a main cluster has a forward cluster planned within
        // InvariantForwardSeconds, unless every re-plan was used up (D-081)
        if (Layout::HasBox() && !Layout::ForwardPlanned() && !Layout::ForwardGivenUp()) {
            if (noForwardSince < 0) noForwardSince = ai.frame;
            else if (ai.frame - noForwardSince >= int(Global::RoleSettings::Tech::InvariantForwardSeconds) * SECOND)
                Violation("INV-013", "forward", "the main turret cluster has had no forward cluster planned for " + int(Global::RoleSettings::Tech::InvariantForwardSeconds) + " s");
        } else noForwardSince = -1;

        // INV-016: the advanced lab stands within a turret's reach (D-085)
        {
            CCircuitUnit@ t2 = Factory::primaryT2BotLab;
            if (t2 is null) t2LabSince = -1;
            else {
                if (t2LabSince < 0) t2LabSince = ai.frame;
                // D-099: a turret slot, planned or built, not a standing turret: the
                // owner's sequencing (D-098) lets the lab come first while build power is
                // short (played: the lab at 4.98 min, the first turret at 9.5 min, metal
                // spent throughout); where the lab stands is what this checks
                else if (ai.frame - t2LabSince >= int(Global::RoleSettings::Tech::InvariantLabReachSeconds) * SECOND
                    && aiTerrainMgr.CountGroupSlotsWithin(Layout::nanoGroup, t2.GetPos(ai.frame), Global::RoleSettings::Tech::ExpLabBuildPowerReach) == 0
                    && aiBuilderMgr.GetStaticBuildPowerNear(t2.GetPos(ai.frame), Global::RoleSettings::Tech::ExpLabBuildPowerReach) <= 0.0f)
                    Violation("INV-016", "" + t2.id, "the advanced lab " + t2.id + " has stood " + int(Global::RoleSettings::Tech::InvariantLabReachSeconds) + " s with no turret or turret slot within " + int(Global::RoleSettings::Tech::ExpLabBuildPowerReach));
                // D-088 (owner's ask): the distance from the advanced lab to the nearest
                // construction turret, logged when it changes; INV-017 when not flush
                CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side));
                CCircuitUnit@ n = (nano is null) ? null : aiBuilderMgr.FindOwnNear(t2.GetPos(ai.frame), 3000.0f, nano);
                const int d = (n is null) ? -1 : int(sqrt(MapHelpers::SqDist(n.GetPos(ai.frame), t2.GetPos(ai.frame))));
                if (d != lastLabTurretDist && (d < 0 || lastLabTurretDist < 0 || abs(d - lastLabTurretDist) >= 16)) {
                    lastLabTurretDist = d;
                    GenericHelpers::LogUtil("[Layout] advanced lab " + t2.id + ": nearest construction turret " + ((d < 0) ? "none" : ("" + d + " elmos"))
                        + ((d >= 0 && d <= int(Global::RoleSettings::Tech::LayoutLabFlushElmos)) ? " (flush)" : " (not flush)"), 1);
                }
                if (!Layout::fallback && ai.frame - t2LabSince >= int(Global::RoleSettings::Tech::InvariantLabReachSeconds) * SECOND && d > int(Global::RoleSettings::Tech::LayoutLabFlushElmos))   // D-121: flush is the planned layout's rule
                    Violation("INV-017", "" + t2.id, "the advanced lab's nearest construction turret is " + d + " elmos away, not flush (" + int(Global::RoleSettings::Tech::LayoutLabFlushElmos) + ")");
                // INV-018 (D-096): the advanced lab faces the front and nothing of ours
                // stands in its exit lane, so what it makes walks out toward the enemy
                const int labF = aiTerrainMgr.GetBuildingFacing(t2);
                // D-160: compare with the front when ordered. A completed lab
                // cannot rotate when the observed enemy front changes.
                const int planned = Layout::LabPlannedFacing();
                const int frontF = (planned >= 0) ? planned : Layout::LabFacing();
                const int inExit = aiTerrainMgr.CountStructuresInExit(t2);
                if (labF != lastLabFacing || inExit != lastLabExitCount) {
                    lastLabFacing = labF; lastLabExitCount = inExit;
                    GenericHelpers::LogUtil("[Layout] advanced lab " + t2.id + ": faces " + labF + ", the front " + frontF + ", "
                        + inExit + " structures in its exit lane", 1);
                }
                if (ai.frame - t2LabSince >= int(Global::RoleSettings::Tech::InvariantLabReachSeconds) * SECOND
                    && (labF != frontF || inExit > 0))
                    Violation("INV-018", "" + t2.id, "the advanced lab faces " + labF + " (the front " + frontF + ") with " + inExit + " structures in its exit lane");
            }
        }

        // INV-019 (D-097): no more turret frames stand unfinished than
        // Layout::TurretsAllowed for InvariantTurretFlightSeconds (played: five
        // at once in the early game, the metal stalled)
        {
            CCircuitDef@ nd = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side));
            const int frames = (nd is null) ? 0 : aiBuilderMgr.GetUnfinishedCount(nd);
            string why;
            // the slots, not what is left after the dear frames: a turret started
            // before the lab is not a violation once the lab starts (D-098)
            const int allowed = Layout::TurretSlots(why);
            if (frames > allowed) {
                if (turretsOverSince < 0) turretsOverSince = ai.frame;
                else if (ai.frame - turretsOverSince >= int(Global::RoleSettings::Tech::InvariantTurretFlightSeconds) * SECOND)
                    Violation("INV-019", "turrets", "" + frames + " turret frames under construction, " + allowed + " allowed (" + why + ")");
            } else turretsOverSince = -1;
        }

        // INV-021 (D-100): a fusion frame is not started while a mex of ours
        // within ChainMexFarRadius is still T1 with no upgrade under way
        {
            CCircuitDef@ fd = ai.GetCircuitDef(UnitHelpers::GetFusionNameForSide(Global::AISettings::Side));
            const int frames = (fd is null) ? 0 : aiBuilderMgr.GetUnfinishedCount(fd);
            // not while the metal floats (the fusion then goes ahead on purpose, D-100)
            if (!aiEconomyMgr.IsMetalMap() && frames > fusionFramesLast && Global::RoleSettings::Tech::ChainMohoRadius > 0.0f && !TechBuild::MetalFullLong()) {
                const AIFloat3 t1 = Economy::MexTracker::GetNearestNonUpgradedMexInRange(Global::Map::StartPos, Global::Map::StartPos,
                    Global::RoleSettings::Tech::ChainMohoRadius);
                if (t1.x >= 0.0f)
                    Violation("INV-021", "fusion", "a fusion frame started with a T1 mex at (" + int(t1.x) + ", " + int(t1.z) + ") not upgraded");
            }
            fusionFramesLast = frames;
        }

        // INV-023 (D-101): a T1 lab after the first, while a turret stands, is
        // placed by the layout: a turret slot within ExpLabBuildPowerReach
        {
            CCircuitUnit@ l1 = Factory::primaryT1BotLab;
            if (l1 !is null && l1.id != lastT1LabId) {
                // a front cluster's lab (D-114) stands at its own turret block: INV-038, INV-045
                if (t1LabSeen && Layout::TurretsStand() && !TechFactories::IsClusterLab(l1)) {
                    const AIFloat3 lp = l1.GetPos(ai.frame);
                    const float reach = Global::RoleSettings::Tech::ExpLabBuildPowerReach;
                    if (aiTerrainMgr.CountGroupSlotsWithin(Layout::nanoGroup, lp, reach) == 0
                        && (Layout::fwdGroup == 0 || aiTerrainMgr.CountGroupSlotsWithin(Layout::fwdGroup, lp, reach) == 0))
                        Violation("INV-023", "" + l1.id, "a T1 lab rebuilt at (" + int(lp.x) + ", " + int(lp.z) + ") with no turret slot within " + int(reach) + " while turrets stand");
                }
                t1LabSeen = true;
                lastT1LabId = l1.id;
            }
        }

        // INV-025 (D-102): a T1 lab frame (not the first) starts only when a lab is
        // wanted: fewer than LabRebuildMinT1Cons T1 constructors or the economy
        // online, and then only with an advanced lab standing or under construction
        {
            CCircuitDef@ t1d = ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(Global::AISettings::Side));
            const int frames = (t1d is null) ? 0 : aiBuilderMgr.GetUnfinishedCount(t1d);
            if (frames > t1LabFramesLast && t1LabSeen) {
                const bool wanted = TechBuild::T1Cons() < Global::RoleSettings::Tech::LabRebuildMinT1Cons || TechBuild::EcoOnline();
                const bool t2Up = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs()) > 0;
                if (!wanted || (TechBuild::EcoOnline() && !t2Up))
                    Violation("INV-025", "t1lab", "a T1 lab frame started with " + TechBuild::T1Cons() + " T1 constructors at +"
                        + int(Economy::GetMinMetalIncomeLast10s()) + " metal, advanced lab " + (t2Up ? "up" : "down"));
            }
            t1LabFramesLast = frames;
        }
        // INV-026 (D-102): no lab is retired for its metal once the economy is online
        {
            array<CCircuitUnit@> labs = { Factory::primaryT1BotLab, Factory::primaryT2BotLab };
            for (uint i = 0; i < labs.length(); ++i) {
                CCircuitUnit@ l = labs[i];
                if (l is null || !Lifecycle::IsRetiring(l) || retiredLabsSeen.exists("" + l.id)) continue;
                retiredLabsSeen.set("" + l.id, ai.frame);
                // D-114: the base's land factories rezoned at the count are not retired for metal
                if (TechBuild::EcoOnline() && !TechFactories::baseRetired.exists("" + l.id))
                    Violation("INV-026", "" + l.id, l.circuitDef.GetName() + " " + l.id + " retired at +" + int(Economy::GetMinMetalIncomeLast10s()) + " metal, the economy online");
            }
        }

        // INV-028 (D-103): with the metal bank over T2ConstructorBankShare and an
        // advanced lab standing, T2 constructors grow toward T2ConstructorCap
        {
            // D-119: the advanced lab's constructors only, to T2BotConstructorCap
            const int t2Cons = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
            const float mStor = aiEconomyMgr.metal.storage;
            const bool high = mStor > 0.0f && aiEconomyMgr.metal.current > Global::RoleSettings::Tech::T2ConstructorBankShare * mStor
                && Factory::primaryT2BotLab !is null && !Lifecycle::IsRetiring(Factory::primaryT2BotLab)
                && t2Cons < Global::RoleSettings::Tech::T2BotConstructorCap;
            if (!high || t2Cons > t2ConsAtHigh) { t2ConsHighSince = high ? ai.frame : -1; t2ConsAtHigh = t2Cons; }
            else if (t2ConsHighSince < 0) { t2ConsHighSince = ai.frame; t2ConsAtHigh = t2Cons; }
            else if (ai.frame - t2ConsHighSince >= 60 * SECOND) {
                Violation("INV-028", "t2cons", "metal bank over " + int(Global::RoleSettings::Tech::T2ConstructorBankShare * 100.0f) + "% for 60 s, " + t2Cons + " T2 constructors, none added");
                t2ConsHighSince = ai.frame;
            }
        }

        // INV-029 (D-104): a factory placed while a turret stands is within a
        // cell of a turret slot (the first lab is exempt: no turret stood)
        {
            array<string>@ keys = Factory::allFactories.getKeys();
            for (uint i = 0; keys !is null && i < keys.length(); ++i) {
                if (factoriesSeen.exists(keys[i])) continue;
                CCircuitUnit@ fac = null;
                if (!Factory::allFactories.get(keys[i], @fac) || fac is null || fac.circuitDef is null) continue;
                factoriesSeen.set(keys[i], ai.frame);
                if (!Layout::TurretsStand()) continue;
                if (TechFactories::IsClusterLab(fac)) continue;   // D-114: at its own turret block (INV-038, INV-045)
                if (TechFlank::Owns(fac)) continue;   // D-136: standalone reachable flank site, not an economy turret-box tenant
                const AIFloat3 fp = fac.GetPos(ai.frame);
                const int ff = aiTerrainMgr.GetBuildingFacing(fac);
                int gap = aiTerrainMgr.EdgeGapToGroup(fac.circuitDef, fp, ff, Layout::nanoGroup);
                if (Layout::fwdGroup > 0) {
                    const int g2 = aiTerrainMgr.EdgeGapToGroup(fac.circuitDef, fp, ff, Layout::fwdGroup);
                    if (g2 >= 0 && (gap < 0 || g2 < gap)) gap = g2;
                }
                GenericHelpers::LogUtil("[Layout] factory " + fac.circuitDef.GetName() + " " + fac.id + " stands " + gap + " cell(s) from a turret", 1);
                if (gap > 1)
                    Violation("INV-029", "" + fac.id, fac.circuitDef.GetName() + " " + fac.id + " stands " + gap + " cells from the turrets, not tight");
            }
        }

        // INV-031 (D-105): the advanced lab is not retired while the advanced
        // fusion is funded without it
        {
            CCircuitUnit@ l2 = Factory::primaryT2BotLab;
            if (l2 !is null && Lifecycle::IsRetiring(l2) && !retiredT2Seen.exists("" + l2.id)) {
                retiredT2Seen.set("" + l2.id, ai.frame);
                string why;
                if (TechBuild::AfusFunded(why))
                    Violation("INV-031", "" + l2.id, "the advanced lab " + l2.id + " retired while the advanced fusion was funded: " + why);
            }
        }

        // INV-034 (D-107): with two or more T2 air constructors both dedicated
        // roles are held within 60 s
        {
            CCircuitDef@ aca = ai.GetCircuitDef(UnitHelpers::GetT2AirConstructorNameForSide(Global::AISettings::Side));
            const int n = (aca is null) ? 0 : (aca.count - aiBuilderMgr.GetUnfinishedCount(aca));
            const bool open = n >= 2 && (TechBuild::airConvId < 0 || TechBuild::airAfusId < 0
                || ai.GetTeamUnit(TechBuild::airConvId) is null || ai.GetTeamUnit(TechBuild::airAfusId) is null);
            if (!open) airRolesOpenSince = -1;
            else if (airRolesOpenSince < 0) airRolesOpenSince = ai.frame;
            else if (ai.frame - airRolesOpenSince >= 60 * SECOND) {
                Violation("INV-034", "air", "" + n + " T2 air constructors but a dedicated role (converters " + TechBuild::airConvId + ", advanced fusions " + TechBuild::airAfusId + ") is open");
                airRolesOpenSince = ai.frame;
            }
        }

        // INV-036 (D-108): a held role's structure is never capped: the start caps
        // and the chain's step targets must not stop a dedicated builder
        // (10 s: a frame just placed meets the cap until the next economy tick lifts it)
        {
            const string cSide = Global::AISettings::Side;
            string capped = "";
            for (int r = 1; r <= 2; ++r) {
                const int id = (r == 1) ? TechBuild::airConvId : TechBuild::airAfusId;
                if (id < 0 || ai.GetTeamUnit(id) is null) continue;
                CCircuitDef@ d = ai.GetCircuitDef((r == 1) ? UnitHelpers::GetAdvEnergyConverterNameForSide(cSide) : UnitHelpers::GetAdvFusionNameForSide(cSide));
                if (d !is null && d.maxThisUnit <= d.count)
                    capped = d.GetName() + " capped at " + d.maxThisUnit + " (" + d.count + " stand) while dedicated " + id + " holds its role";
            }
            if (capped.length() == 0) roleCappedSince = -1;
            else if (roleCappedSince < 0) roleCappedSince = ai.frame;
            else if (ai.frame - roleCappedSince >= 10 * SECOND && ai.frame - roleCappedLog >= 30 * SECOND) {
                roleCappedLog = ai.frame;
                Violation("INV-036", "air", capped);
            }
        }

        // INV-037 (D-108): the advanced fusions keep going up: while the fusion
        // role is held and the metal bank is over half full, a new advanced fusion
        // (frame or finished) appears at least every 180 s
        {
            CCircuitDef@ af = ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(Global::AISettings::Side));
            const float mS = aiEconomyMgr.metal.storage;
            const bool watch = af !is null && TechBuild::airAfusId >= 0 && ai.GetTeamUnit(TechBuild::airAfusId) !is null
                && mS > 0.0f && aiEconomyMgr.metal.current > 0.5f * mS;
            if (!watch || af.count > afusSeenCount) { afusSeenCount = (af is null) ? -1 : af.count; afusSeenFrame = ai.frame; }
            else if (ai.frame - afusSeenFrame >= 180 * SECOND) {
                Violation("INV-037", "afus", "no new advanced fusion for 180 s (" + af.count + " stand or build) with the fusion role held and the metal bank over half");
                afusSeenFrame = ai.frame;
            }
        }

        // INV-041 (D-110): the cargo of a ferry run holds no construction order;
        // INV-042: a run ends (delivered or failed) within 600 s (the cargo park, FERRY_HOLD_FRAMES)
        // D-112: every gift, queued ones included
        for (uint gi = 0; gi < Team::Ferry::queuedCargo.length() && ai.frame - ferryLog >= 30 * SECOND; ++gi) {
            CCircuitUnit@ qg = ai.GetTeamUnit(Team::Ferry::queuedCargo[gi]);
            IBuilderTask@ qbt = (qg is null || qg.task is null) ? null : cast<IBuilderTask>(qg.task);
            if (qbt !is null) {
                ferryLog = ai.frame;
                Violation("INV-041", "ferry", "queued gift " + qg.id + " holds a build order ("
                    + (qbt.buildDef is null ? "type " + int(qbt.GetBuildType()) : qbt.buildDef.GetName()) + ")");
            }
        }
        if (Team::Ferry::cargoId >= 0 && ai.frame - ferryLog >= 30 * SECOND) {
            CCircuitUnit@ cg = ai.GetTeamUnit(Team::Ferry::cargoId);
            IBuilderTask@ cbt = (cg is null || cg.task is null) ? null : cast<IBuilderTask>(cg.task);
            if (cbt !is null) {
                ferryLog = ai.frame;
                Violation("INV-041", "ferry", "cargo " + Team::Ferry::cargoId + " holds a build order ("
                    + (cbt.buildDef is null ? "type " + int(cbt.GetBuildType()) : cbt.buildDef.GetName()) + ") during its run");
            } else if (Team::Ferry::runStart >= 0 && ai.frame - Team::Ferry::runStart > 600 * SECOND) {
                ferryLog = ai.frame;
                Violation("INV-042", "ferry", "the run for cargo " + Team::Ferry::cargoId + " has lasted " + int((ai.frame - Team::Ferry::runStart) / SECOND) + " s");
            }
        }

        // INV-038 (D-109, D-114): a front cluster's factory standing for 180 s has
        // its whole turret block
        for (uint i = 0; i < TechFactories::clusters.length(); ++i) {
            TechFactories::Cluster@ s = TechFactories::clusters[i];
            CCircuitUnit@ l = TechFactories::LabAt(s);
            // INV-045 (D-114): a front cluster's factory frame starts only once its
            // whole turret block stands finished (a gantry: its first
            // FrontT3TurretsFirst, D-119)
            if (l !is null && !s.labSeen) {
                s.labSeen = true;
                const int done = TechFactories::FinishedTurrets(s);
                if (done < TechFactories::TurretsBeforeLab(s))
                    Violation("INV-045", "front", "front cluster " + (i + 1) + " (" + s.defName + ") started its factory with " + done + " of its "
                        + s.slots + " turrets finished (" + TechFactories::TurretsBeforeLab(s) + " wanted first)");
            }
            if (l is null || l.GetBuildProgress() < 1.0f) { s.standFrame = -1; continue; }
            if (s.standFrame < 0) { s.standFrame = ai.frame; continue; }
            const int have = TechFactories::TurretsOf(s);
            if (ai.frame - s.standFrame >= 180 * SECOND && have < s.slots && ai.frame - s.invLog >= 60 * SECOND) {
                s.invLog = ai.frame;
                Violation("INV-038", "front", "front cluster " + (i + 1) + " (" + s.defName + ") has stood " + int((ai.frame - s.standFrame) / SECOND)
                    + " s with " + have + " of its " + s.slots + " turrets");
            }
        }

        // INV-046 (D-114): an open T2 or T3 front cluster has its factory within
        // FrontClusterOpenSeconds of being planned
        for (uint i = 0; i < TechFactories::clusters.length(); ++i) {
            TechFactories::Cluster@ s = TechFactories::clusters[i];
            if (s.ahead || s.tier < 2 || s.labRes < 0 || s.plannedFrame < 0 || TechFactories::LabAt(s) !is null) continue;
            if (ai.frame - s.plannedFrame >= Global::RoleSettings::Tech::FrontClusterOpenSeconds * SECOND && ai.frame - s.invOpenLog >= 120 * SECOND) {
                s.invOpenLog = ai.frame;
                Violation("INV-046", "front", "front cluster " + (i + 1) + " (" + s.defName + ") planned " + int((ai.frame - s.plannedFrame) / SECOND)
                    + " s ago has no factory; " + TechFactories::FinishedTurrets(s) + " of its " + s.slots + " turrets stand");
            }
        }

        // INV-047 (D-117): every spam row keeps a T3 lane, and no structure stands
        // on a lane it holds. INV-048: a standing spam lab's turret works for that
        // lab (guards or repairs it) at every check
        if (ai.frame % (60 * SECOND) < SECOND) {
            for (uint i = 0; i < TechFactories::spamRows.length(); ++i) {
                TechFactories::Row@ r = TechFactories::spamRows[i];
                if (r.laneL <= 0 && r.laneR <= 0)
                    Violation("INV-047", "lane", "spam row " + (i + 1) + " (" + r.labs.length() + " labs) holds no T3 lane");
                if ((r.laneL > 0 && !aiTerrainMgr.IsZoneClear(r.laneL)) || (r.laneR > 0 && !aiTerrainMgr.IsZoneClear(r.laneR)))
                    Violation("INV-047", "lane", "a structure stands on a T3 lane of spam row " + (i + 1));
            }
            for (uint i = 0; i < TechFactories::clusters.length(); ++i) {
                TechFactories::Cluster@ c = TechFactories::clusters[i];
                if (c.tier != 1) continue;
                CCircuitUnit@ l = TechFactories::LabAt(c);
                if (l is null || l.GetBuildProgress() < 1.0f) continue;
                for (uint k = 0; k < c.turretPos.length(); ++k) {
                    CCircuitUnit@ t = TechFactories::TurretAt(c.turretPos[k]);
                    if (t is null || t.GetBuildProgress() < 1.0f || t.task is null) continue;
                    IBuilderTask@ bt = cast<IBuilderTask>(t.task);
                    // D-119: its recent focus task (a guard keeps its target as an id; a
                    // factory-side turret idles for moments between two units)
                    if (TechFactories::GuardsLab(t, l) || (bt !is null && bt.target !is null && bt.target.id == l.id)) continue;
                    {
                        int64 rec = -1;
                        if (!TechFactories::focusOf.get("" + t.id, rec)) rec = -1;   // D-025
                        Violation("INV-048", "" + t.id, "spam cluster " + (i + 1) + "'s turret " + t.id + " is not working for its lab " + l.id
                            + " (task type " + (bt is null ? -1 : int(bt.GetBuildType())) + ", target " + ((bt is null || bt.target is null) ? -1 : bt.target.id)
                            + ", unit task type " + int(t.task.GetType()) + ", last focus on lab " + rec + ")");
                    }
                }
            }
        }

        // INV-053 (D-123): no T2 air constructor waits (or idles) at three samples in
        // a row, 30 s apart (played: every air constructor stood still once the
        // layout was full at 225 advanced converters)
        if (ai.frame % (30 * SECOND) < SECOND) {
            array<string>@ keys = TechBuild::airConsSeen.getKeys();
            for (uint i = 0; keys !is null && i < keys.length(); ++i) {
                CCircuitUnit@ a = ai.GetTeamUnit(parseInt(keys[i]));
                if (a is null) { inv53Idle.delete(keys[i]); continue; }
                if (Team::Ferry::IsGift(a.id)) { inv53Idle.delete(keys[i]); continue; }   // a gift waits for its transport by design (D-112)
                bool idle = (a.task is null) || int(a.task.GetType()) == int(Task::Type::IDLE);
                if (!idle) {
                    IBuilderTask@ bt = cast<IBuilderTask>(a.task);
                    idle = (bt !is null && Task::BuildType(bt.GetBuildType()) == Task::BuildType::WAIT);
                }
                int64 n = 0;
                if (!inv53Idle.get(keys[i], n)) n = 0;
                n = idle ? n + 1 : 0;
                inv53Idle.set(keys[i], n);
                if (n == 3) {
                    string last = "";
                    TechRules::lastKeyByUnit.get(keys[i], last);
                    Violation("INV-053", keys[i], "air constructor " + keys[i] + " has done nothing for 60 s (task type "
                        + ((a.task is null) ? -1 : int(a.task.GetType())) + ", last rule " + last + ")");
                }
            }
        }

        // INV-051 (D-121): once the harbour begins, an advanced shipyard stands or
        // is framed within HarbourYardSeconds (the owner's priority)
        if (!inv51Done && TechHarbour::activeLatched && ai.frame - TechHarbour::activeFrame >= Global::RoleSettings::Tech::HarbourYardSeconds * SECOND) {
            inv51Done = true;
            CCircuitDef@ ay = ai.GetCircuitDef(UnitHelpers::GetT2ShipyardForSide(Global::AISettings::Side));
            if (ay !is null && ay.count == 0 && aiBuilderMgr.GetUnfinishedCount(ay) == 0)
                Violation("INV-051", "yard", "no advanced shipyard " + Global::RoleSettings::Tech::HarbourYardSeconds + " s after the harbour began");
        }

        // INV-050 (D-120): a factory stands (or is framed) by FirstFactorySeconds.
        // Played: on Tundra Continents the planned layout did not fit, every site
        // was refused, and TECH had no factory for the whole game
        if (!inv50Done && ai.frame >= Global::RoleSettings::Tech::FirstFactorySeconds * SECOND) {
            inv50Done = true;
            if (Factory::allFactories.getSize() == 0 && !TechBuild::T2Begun())   // a framed advanced lab counts (the T1 lab is its throwaway, D-066)
                Violation("INV-050", "factory", "no factory " + Global::RoleSettings::Tech::FirstFactorySeconds + " s into the game (layout "
                    + (Layout::fallback ? "fallback: no planned pair" : (Layout::planned ? "planned" : "not planned")) + ")");
        }

        // INV-044 (D-114): with FrontReclaimAtCount land factories on the map, no
        // land factory stands at the main base for FrontBaseReclaimSeconds
        {
            CCircuitUnit@ bf = TechFactories::BaseLandFactory();
            if (bf is null) baseFactorySince = -1;
            else if (baseFactorySince < 0) baseFactorySince = ai.frame;
            else if (ai.frame - baseFactorySince >= Global::RoleSettings::Tech::FrontBaseReclaimSeconds * SECOND && ai.frame - baseFactoryLog >= 60 * SECOND) {
                baseFactoryLog = ai.frame;
                Violation("INV-044", "front", bf.circuitDef.GetName() + " " + bf.id + " still stands at the main base with " + TechFactories::LandFactoryCount()
                    + " land factories on the map (" + int((ai.frame - baseFactorySince) / SECOND) + " s)");
            }
        }

        // INV-039 (D-109): a released tier with forward work waiting orders some of it
        // within 180 s (T1: a spam lab wanted; T2: a mex cluster without long-range AA)
        {
            const int t1Land = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1BotConstructors());
            const int t2Land = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
            // T1 spam work waits for the economy online (D-114), so the clock starts
            // at the later of the release and that (played: fired the tick it latched)
            const bool online = TechBuild::EcoOnline();   // first: it latches ecoOnlineFrame
            int last1 = (TechForward::lastOrderT1 > TechForward::sinceT1) ? TechForward::lastOrderT1 : TechForward::sinceT1;
            if (TechBuild::ecoOnlineFrame > last1) last1 = TechBuild::ecoOnlineFrame;
            if (TechForward::sinceT1 >= 0 && t1Land > 0 && online
                && int(TechForward::SpamClusters().length()) < TechForward::SpamLabsWanted(aiEconomyMgr.metal.income)
                && ai.frame - last1 >= 180 * SECOND && ai.frame - fwdIdleLogT1 >= 180 * SECOND)
            {
                fwdIdleLogT1 = ai.frame;
                Violation("INV-039", "t1", "T1 land constructors released " + int((ai.frame - TechForward::sinceT1) / SECOND) + " s, "
                    + TechForward::SpamClusters().length() + " spam labs of " + TechForward::SpamLabsWanted(aiEconomyMgr.metal.income) + " wanted, no forward order for 180 s");
            }
            const int last2 = (TechForward::lastOrderT2 > TechForward::sinceT2) ? TechForward::lastOrderT2 : TechForward::sinceT2;
            if (TechForward::sinceT2 >= 0 && t2Land > 0 && ai.frame - last2 >= 180 * SECOND && ai.frame - fwdIdleLogT2 >= 180 * SECOND) {
                CCircuitDef@ lraa = ai.GetCircuitDef(UnitHelpers::GetStaticT2AARangeNameForSide(Global::AISettings::Side));
                array<TechForward::MexCluster@> cl = TechForward::Clusters();
                int open = 0;
                for (uint i = 0; lraa !is null && i < cl.length(); ++i) {
                    if (MapHelpers::SqDist(cl[i].c, Layout::BaseCentre()) < TechForward::Sq(Global::RoleSettings::Tech::MexDefenceBaseClear)) continue;
                    if (!TechForward::Stands(cl[i].c, Global::RoleSettings::Tech::MexDefenceRadius, lraa)) ++open;
                }
                if (open > 0) {
                    fwdIdleLogT2 = ai.frame;
                    Violation("INV-039", "t2", "T2 land constructors released " + int((ai.frame - TechForward::sinceT2) / SECOND) + " s, "
                        + open + " mex cluster(s) without long-range AA, no defence order for 180 s");
                }
            }
        }

        // INV-035 (D-108): a dedicated T2 air constructor never holds a
        // construction of another kind (it builds or assists its own, or waits)
        {
            const string aSide = Global::AISettings::Side;
            for (int r = 1; r <= 2; ++r) {
                const int id = (r == 1) ? TechBuild::airConvId : TechBuild::airAfusId;
                const string own = (r == 1) ? UnitHelpers::GetAdvEnergyConverterNameForSide(aSide) : UnitHelpers::GetAdvFusionNameForSide(aSide);
                CCircuitUnit@ du = (id < 0) ? null : ai.GetTeamUnit(id);
                IBuilderTask@ bt = (du is null || du.task is null) ? null : cast<IBuilderTask>(du.task);
                if (bt is null || bt.buildDef is null || bt.buildDef.GetName() == own) continue;
                if (ai.frame - airOffDutyLog < 30 * SECOND) continue;
                airOffDutyLog = ai.frame;
                Violation("INV-035", "air", "dedicated " + id + " (" + own + ") holds " + bt.buildDef.GetName());
            }
        }

        // INV-015: a dear chain order does not wait for its first builder (D-084)
        if (TechChain::DearOrderPendingSeconds() >= Global::RoleSettings::Tech::InvariantDearOrderSeconds)
            Violation("INV-015", "dear", "a dear chain order has had no frame for " + int(Global::RoleSettings::Tech::InvariantDearOrderSeconds) + " s");

        // INV-008: every construction turret in range of a reclaim of ours is
        // on it (the owner's rule, D-078).
        {
            array<string>@ keys = TechBuild::reclaimTargets.getKeys();
            for (uint i = 0; keys !is null && i < keys.length(); ++i) {
                int64 at = 0; TechBuild::reclaimTargets.get(keys[i], at);
                const int id = int(parseInt(keys[i]));
                CCircuitUnit@ t = ai.GetTeamUnit(id);
                if (t is null || ai.frame - int(at) > 180 * SECOND) { TechBuild::reclaimTargets.delete(keys[i]); offSince.delete(keys[i]); continue; }
                const int off = aiBuilderMgr.TurretsOnReclaim(id, Global::RoleSettings::Tech::ReclaimTurretMargin, false);
                if (off <= 0) { offSince.delete(keys[i]); continue; }
                int64 since = 0;
                if (!offSince.get(keys[i], since)) { offSince.set(keys[i], int64(ai.frame)); continue; }
                if (ai.frame - int(since) >= int(Global::RoleSettings::Tech::InvariantReclaimJoinSeconds) * SECOND)
                    Violation("INV-008", keys[i], off + " turret(s) in range of the reclaim of " + t.circuitDef.GetName() + " " + id + " are not on it");
            }
        }
    }
}
