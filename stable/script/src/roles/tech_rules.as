// TECH's build rules as one ordered table (D-067).
#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/unit_helpers.as"
#include "../helpers/unitdef_helpers.as"
#include "../helpers/map_helpers.as"
#include "../manager/builder.as"
#include "../manager/factory.as"
#include "../manager/layout.as"
#include "../manager/eco_planner.as"
#include "../manager/spam.as"
#include "../manager/eco_role.as"
#include "tech_forward.as"
#include "tech_factories.as"

/******************************************************************************

TECH RULES (D-067)

Every decision TECH's experimental build system makes for a builder is one
row of the table below, evaluated top to bottom for the asking builder. A
row is: a key, who it applies to, a list of named predicates over a context
read once per ask, and an act that returns a task. The first row whose
predicates hold and whose act returns a task wins; the choice is logged.

Why a table: a rule that lives inside one rung's `if` is invisible to the
next rung, and that is how "no T1 lab once the advanced lab is under way"
was lost when the lab logic moved (D-066 follow-up 16). A predicate has one
name and one definition, referenced by every row it applies to; the order
of rows is the sequencing policy and nothing else is.

The T1 bot lab, as an example of the reasoning the table has to carry
(researched in doc/tech-eco-meta.md and the knowledge base's
70-strategy/75-team-roles.md, 50-economy/52-scaling-curves.md):

  lab.t1.opening   at game start, a throwaway at the commander, to be
                   reclaimed the moment the advanced lab begins
  lab.t1.recover   every constructor lost and no lab of any tier standing
                   or ordered: the commander rebuilds one to get builders
  fwd.t1           D-109: the spam labs go forward (the spam cluster), built
                   by the released T1 land constructors, one per +100 metal
  never            for a T1 front - TECH does not fight T1 lane battles -
                   and never a second T1 lab early ("one factory with
                   turrets beats two without", the official economy guide)

Placement is not decided here. An act names a def and asks Layout
(the turret box, a factory slot, an exact spot, a packed anchor).

******************************************************************************/
namespace TechRules {

    // ---------------------------------------------------------------- who

    const int COMMANDER = 1;
    const int CON_T1 = 2;
    const int CON_T2 = 4;
    const int TURRET = 8;
    const int MOBILE = COMMANDER | CON_T1 | CON_T2;
    const int CONSTRUCTORS = CON_T1 | CON_T2;
    const int ANY = MOBILE | TURRET;

    // ---------------------------------------------------------------- context

    class Ctx {
        CCircuitUnit@ u;
        const CCircuitDef@ d;
        int who;
        float mi;                   // 10-second minimum metal income
        float ei;                   // 10-second minimum energy income
        EcoPlanner::State@ eco;     // banks, counts, build power, options (read once)
        bool openingDone;
        bool intoT2;                // the advanced lab is ordered, framed or standing
        int t1Labs;                 // standing
        int t2Labs;
        int constructors;           // mobile constructors alive, commander excluded
        bool spamGate;              // the spam economy thresholds are met
        // derived economy flags, the same definitions the planner uses
        float energyTarget;
        bool draining;
        bool floatingE;
        bool floatingM;
        float surplus;
        bool fusionEra;
        // D-075: build-power scaling (the owner's rule)
        float mPull;                // metal demand this frame
        bool aheadM;                // the metal bank full or rising (TechBuild::MetalAhead) with a bank of PowerTurretBankFactor turrets
        CCircuitUnit@ building;     // the nearest structure of ours under construction within ChainAssistRadius, or null
    }

    Ctx@ Build(CCircuitUnit@ u)
    {
        Ctx@ c = Ctx();
        @c.u = u;
        @c.d = u.circuitDef;
        if (!c.d.IsMobile()) c.who = TURRET;
        else if (UnitHelpers::IsCommander(c.d)) c.who = COMMANDER;
        else c.who = (UnitHelpers::GetConstructorTier(c.d) >= 2) ? CON_T2 : CON_T1;
        c.mi = Economy::GetMinMetalIncomeLast10s();
        c.ei = Economy::GetMinEnergyIncomeLast10s();
        @c.eco = EcoPlanner::Read(u, c.mi, c.ei);
        c.openingDone = RoleTech::Opening::complete;
        c.intoT2 = TechBuild::IntoT2();
        c.t1Labs = UnitDefHelpers::SumUnitDefCounts(EcoRole::AllT1Labs());   // AIR: aircraft plants
        c.t2Labs = UnitDefHelpers::SumUnitDefCounts(EcoRole::AllT2Labs());
        c.constructors = UnitDefHelpers::SumUnitDefCounts(EcoRole::AllT1Cons())
            + UnitDefHelpers::SumUnitDefCounts(EcoRole::AllT2Cons());
        c.spamGate = Global::Spam::Enabled && c.mi >= Global::Spam::MinMetalIncome && c.ei >= Global::Spam::MinEnergyIncome;
        const EcoPlanner::State@ s = c.eco;
        c.energyTarget = EcoPlanner::TargetEnergy(s.mIncome);
        c.draining = (s.eStor > 0.0f) && (s.eCur < Global::RoleSettings::Tech::EcoEnergyLowPercent * s.eStor) && (s.ePull > s.eIncome);
        c.floatingE = (s.eStor > 0.0f) && (s.eCur >= Global::RoleSettings::Tech::EcoConvertEnergyPercent * s.eStor);
        c.floatingM = aiEconomyMgr.isMetalFull
            || ((s.mStor > 0.0f) && (s.mCur >= Global::RoleSettings::Tech::EcoFloatMetalPercent * s.mStor) && (s.mIncome >= 5.0f));
        c.surplus = s.eIncome - s.ePull;
        c.fusionEra = (s.t2Cons > 0) && (s.eIncome >= Global::RoleSettings::Tech::EcoFusionEnergyIncome);
        c.mPull = aiEconomyMgr.metal.pull;
        {
            CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side));
            const float bank = (nano is null) ? 1.0e9f : nano.costM * Global::RoleSettings::Tech::PowerTurretBankFactor;
            c.aheadM = TechBuild::MetalAhead() && (s.mCur >= bank);   // read from the bank, not the pull (D-075 played)
        }
        @c.building = null;
        if (c.aheadM) {
            CCircuitUnit@ f = aiBuilderMgr.FindUnfinishedNear(Layout::BaseCentre(), Global::RoleSettings::Tech::ChainAssistRadius, null);
            if (f !is null && f.circuitDef !is null && !f.circuitDef.IsMobile()) @c.building = f;
        }
        return c;
    }

    // ---------------------------------------------------------------- predicates (named once)

    funcdef bool When(Ctx@ c);

    // Read live, not from the context: the opening act itself marks the
    // opening complete when no spot is left, and the lab row is next in the
    // same pass (played: the first lab was traced as lab.t1.recover).
    bool OpeningDone(Ctx@ c)      { return RoleTech::Opening::complete; }
    bool OpeningPending(Ctx@ c)   { return !RoleTech::Opening::complete; }
    bool IntoT2(Ctx@ c)           { return c.intoT2; }
    bool NotIntoT2(Ctx@ c)        { return !c.intoT2; }
    bool NoT1Lab(Ctx@ c)          { return c.t1Labs == 0 && aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY), ai.GetCircuitDef(EcoRole::T1LabName(Global::AISettings::Side))) == 0; }
    // manager/eco_role.as: rows about bot labs being eaten, land constructors and
    // land front/spam factories are TECH's; AIR has its own plant row
    bool TechRole(Ctx@ c)         { return !EcoRole::IsAir(); }
    bool AirRole(Ctx@ c)          { return EcoRole::IsAir(); }
    bool NoLabAtAll(Ctx@ c)       { return c.t1Labs == 0 && c.t2Labs == 0 && !c.intoT2; }
    bool NoConstructors(Ctx@ c)   { return c.constructors == 0; }
    bool T2LabStands(Ctx@ c)      { return c.t2Labs > 0; }
    bool EcoOnline(Ctx@ c)        { return TechBuild::EcoOnline(); }   // D-102
    // D-105: the post-objective plan keeps the chain active for good (its income
    // ladder); once the economy is online the spam labs do not wait for it
    bool ChainDoneOrOnline(Ctx@ c) { return !TechChain::Active() || TechBuild::EcoOnline(); }
    bool NotMetalFull(Ctx@ c)     { return !TechBuild::MetalFullLong(); }   // D-105: converters make metal; a full bank wastes it
    bool DearFrameUp(Ctx@ c)      { return aiBuilderMgr.CountUnfinishedNear(Layout::BaseCentre(), Global::RoleSettings::Tech::EcoBuildPowerRadius, Global::RoleSettings::Tech::ChainParallelCostM, null) > 0; }   // D-105
    bool TurretRoom(Ctx@ c)       { return !Layout::TurretsCapped() && Layout::CanPlaceTurret(); }   // D-105
    bool MetalFloodedLong(Ctx@ c) { return TechBuild::MetalFullLong(); }   // D-105
    bool T2LabAgain(Ctx@ c)       { return c.t2Labs == 0 && TechBuild::EcoOnline(); }   // D-102: the advanced lab again once the economy is online
    bool NoAfusYetOrAgain(Ctx@ c) { return !TechBuild::IntoAfus() || (c.t2Labs == 0 && TechBuild::EcoOnline()); }   // D-078, D-102
    bool SpamGate(Ctx@ c)         { return c.spamGate; }
    bool ChainActive(Ctx@ c)      { return TechChain::Active(); }
    bool ChainInactive(Ctx@ c)    { return !TechChain::Active(); }
    // D-105 (played: income +300 to +600 with the bank full and one spam lab):
    // the spam labs scale with income, ExpSpamLabs at the online income, one more
    // per SpamLabMetalStep above it, up to SpamLabsMax
    int SpamLabsFor(float mi)
    {
        int n = Global::RoleSettings::Tech::ExpSpamLabs;
        if (mi > Global::RoleSettings::Tech::LabEcoOnlineMetalIncome)
            n += int((mi - Global::RoleSettings::Tech::LabEcoOnlineMetalIncome) / Global::RoleSettings::Tech::SpamLabMetalStep);
        return (n > Global::RoleSettings::Tech::SpamLabsMax) ? Global::RoleSettings::Tech::SpamLabsMax : n;
    }
    bool SpamLabsWanted(Ctx@ c)   { return c.t1Labs < SpamLabsFor(c.mi) && aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY), null) == 0; }
    bool MetalBottleneck(Ctx@ c)  { return c.mi < Global::RoleSettings::Tech::EcoMexExpandUntilIncome; }
    bool Draining(Ctx@ c)         { return c.draining; }
    bool NotDraining(Ctx@ c)      { return !c.draining; }
    bool EnergyShort(Ctx@ c)      { return c.energyTarget > c.ei && !c.floatingE; }
    bool EnergyFloating(Ctx@ c)   { return c.floatingE; }
    bool EnergyIdle(Ctx@ c)       { return !c.eco.energyBuilding; }
    bool EnergyBusy(Ctx@ c)       { return c.eco.energyBuilding; }
    bool EnergyAssistable(Ctx@ c) { return c.eco.energyAssistable; }
    bool NotStalling(Ctx@ c)      { return !aiEconomyMgr.isEnergyStalling; }
    bool T2LabRetiring(Ctx@ c)    { return Factory::primaryT2BotLab !is null && Lifecycle::IsRetiring(Factory::primaryT2BotLab); }   // D-078
    bool NoAfusYet(Ctx@ c)        { return !TechBuild::IntoAfus(); }   // D-078: no advanced lab is ordered once the advanced fusion is under way
    bool NoDearOrderPending(Ctx@ c) { return !TechChain::DearOrderPending(); }   // D-084
    bool EnergyFloatsBank(Ctx@ c) { return TechChain::EnergyFloats(); }   // D-079: the bank-based float, the chain's definition
    bool EnergyReclaimable(Ctx@ c){ const EcoPlanner::State@ s = c.eco; return TechBuild::ReactorStands() && (s.winds + s.solars + s.advSolars) > 0; }   // D-077; D-101: a finished reactor, not a frame
    bool MetalAhead(Ctx@ c)       { return c.aheadM; }                 // D-075: income above spending, the bank rising
    bool StructureBuilding(Ctx@ c){ return c.building !is null; }      // D-075: a structure of ours is under construction
    bool ConverterSurplus(Ctx@ c) { return c.floatingE || c.surplus >= 2.0f * Global::RoleSettings::Tech::EcoConverterUse; }
    // Energy income past EcoEnergyRatioHigh times the metal income and metal not
    // floating: the energy is worth more as metal (played: ten solars, no converter)
    bool EnergyOutscalesMetal(Ctx@ c) { return c.mi > 0.0f && c.ei >= Global::RoleSettings::Tech::EcoEnergyRatioHigh * c.mi && !c.floatingM; }
    bool ConverterWanted(Ctx@ c)  { return ConverterSurplus(c) || EnergyOutscalesMetal(c); }
    bool MetalFloating(Ctx@ c)    { return c.floatingM; }
    bool EnergyAhead(Ctx@ c)      { return c.ei < 2.0f * c.energyTarget; }
    bool EnergyForMe(Ctx@ c)      { return c.eco.builderIsT2 || !c.fusionEra; }   // in the fusion era T1 builders leave energy to T2
    bool FirstTurretStands(Ctx@ c){ return aiBuilderMgr.GetStaticBuildPowerNear(Layout::BaseCentre(), Global::RoleSettings::Tech::EcoBuildPowerRadius) > 0.0f; }
    bool Always(Ctx@ c)           { return true; }
    bool BaseFactoryToGo(Ctx@ c)  { return TechFactories::BaseLandFactory() !is null; }   // D-114
    bool FrontClusterOpen(Ctx@ c) { return TechFactories::OpenAbove(2) || TechFactories::RefillWanted(1, 3); }   // D-114
    bool LandCon(Ctx@ c)          { return TechForward::IsLand(c.u); }        // D-109: a bot, not an air constructor
    bool T1LandReleased(Ctx@ c)   { return TechForward::T1Released(); }       // D-109
    bool T2LandReleased(Ctx@ c)   { return TechForward::T2Released(); }       // D-109

    // ---------------------------------------------------------------- acts

    funcdef IUnitTask@ Act(Ctx@ c);

    IUnitTask@ ByKey(Ctx@ c, const string &in key) { return EcoPlanner::Enqueue(key, c.u); }

    IUnitTask@ DoTurretAssist(Ctx@ c)   { return RoleTech::Tech_TurretAssist(c.u); }
    IUnitTask@ DoTurretAny(Ctx@ c)
    {
        CCircuitUnit@ near = aiBuilderMgr.FindUnfinishedNear(c.u.GetPos(ai.frame), 700.0f, null);
        if (near is null) return null;
        return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::NORMAL, near, 30 * SECOND));
    }
    IUnitTask@ DoWaitShort(Ctx@ c)      { return TechBuild::Wait(5 * SECOND); }
    IUnitTask@ DoAirDedicated(Ctx@ c)   { return TechBuild::AirDedicated(c.u); }   // D-107
    IUnitTask@ DoAirFlexible(Ctx@ c)    { return TechBuild::AirFlexible(c.u); }    // D-107
    IUnitTask@ DoBaseFactoryReclaim(Ctx@ c) { return TechFactories::ReclaimBaseFactory(c.u); }   // D-114
    IUnitTask@ DoFrontCluster(Ctx@ c)       { return TechFactories::OpenWork(c.u); }            // D-114
    IUnitTask@ DoTurretSpam(Ctx@ c)     { return TechFactories::TurretFocus(c.u); }    // D-109, D-114: every front cluster's turrets
    IUnitTask@ DoFerryCargo(Ctx@ c)                                                 // D-110
    {
        if (!Team::Ferry::IsGift(c.u.id)) return null;
        // in flight: the ferry's own hold (native, damage-proof)
        if (Team::Ferry::IsCargo(c.u.id) && c.u.task !is null && cast<IBuilderTask>(c.u.task) is null) return c.u.task;
        // D-112: queued: parked behind the base, nothing else
        return Team::Ferry::Park(c.u, false);   // the table's caller assigns it
    }
    IUnitTask@ DoLandRecall(Ctx@ c)     { return TechForward::Recall(c.u); }       // D-109
    IUnitTask@ DoDefendMexes(Ctx@ c)    { return TechForward::DefendMexes(c.u); }  // D-109
    IUnitTask@ DoForwardT1(Ctx@ c)      { return TechForward::ForwardT1(c.u, c.mi); }   // D-109
    IUnitTask@ DoT1Turret(Ctx@ c)       { return Layout::NanoTask(c.u, Task::Priority::HIGH); }   // D-105
    // D-105: a turret assists the nearest producing factory within its reach
    IUnitTask@ DoTurretFactory(Ctx@ c)
    {
        const float reach = 400.0f;   // the construction turret's builddistance (cornanotc, armnanotc, legnanotc)
        const AIFloat3 here = c.u.GetPos(ai.frame);
        array<string>@ keys = Factory::allFactories.getKeys();
        CCircuitUnit@ best = null;
        float bestSq = 1.0e30f;
        for (uint i = 0; keys !is null && i < keys.length(); ++i) {
            CCircuitUnit@ fac = null;
            if (!Factory::allFactories.get(keys[i], @fac) || fac is null || fac.task is null || Lifecycle::IsRetiring(fac)) continue;
            if (TechFactories::IsSpamLab(fac)) continue;   // D-119: its two turrets only
            const float sq = MapHelpers::SqDist(here, fac.GetPos(ai.frame));
            const float r = reach + ((fac.circuitDef is null) ? 48.0f : float(fac.circuitDef.GetFootprintX() > fac.circuitDef.GetFootprintZ() ? fac.circuitDef.GetFootprintX() : fac.circuitDef.GetFootprintZ()) * 4.0f);
            if (sq <= r * r && sq < bestSq) { bestSq = sq; @best = fac; }
        }
        if (best is null) return null;
        return GuardHelpers::AssignWorkerGuard(c.u, best, Task::Priority::LOW, true, 20 * SECOND);
    }
    IUnitTask@ DoWait(Ctx@ c)           { return TechBuild::Wait(3 * SECOND); }
    IUnitTask@ DoKeepCurrent(Ctx@ c)    { return TechBuild::KeepCurrent(c.u); }
    IUnitTask@ DoChain(Ctx@ c)          { return TechChain::Next(c.u); }
    IUnitTask@ DoOpening(Ctx@ c)        { return RoleTech::Opening::MakeTask(c.u); }
    IUnitTask@ DoReclaimT1Lab(Ctx@ c)
    {
        return TechBuild::ReclaimT1Lab(c.u, (c.who == COMMANDER) ? Global::RoleSettings::Tech::ExpCommanderHomeRadius
                                                                  : Global::RoleSettings::Tech::ExpAssistRadius);
    }
    IUnitTask@ DoStartFactory(Ctx@ c)   { return TechBuild::StartFactory(c.u); }
    IUnitTask@ DoSpamLab(Ctx@ c)
    {
        // D-105 (played: served the pair's old T1 slot, 32 to 45 cells from the
        // turrets, INV-029): flush against the turrets (D-104); the pair's slot
        // only when the layout has no site
        CCircuitDef@ lab = ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(Global::AISettings::Side));
        IUnitTask@ t = (lab is null) ? null : Layout::OrderFactory(lab, 300 * SECOND);
        if (t is null) @t = Builder::EnqueueT1BotLab(Global::AISettings::Side, Global::Map::StartPos, 0.0f, 300 * SECOND, Task::Priority::NORMAL);
        if (t !is null) GenericHelpers::LogUtil("[Rule] spam lab: the spam gate is open (+" + int(c.mi) + " metal, " + int(c.ei) + " energy)", 1);
        return t;
    }
    IUnitTask@ DoExpandMex(Ctx@ c)      { return TechBuild::ExpandMex(c.u, c.mi); }
    IUnitTask@ DoEnergy(Ctx@ c)
    {
        string why;
        const string key = EcoPlanner::PickEnergy(c.eco, why, c.draining ? "energy draining" : "energy below target " + int(c.energyTarget));
        if (key.length() == 0) return null;
        IUnitTask@ redirect = RoleTech::Tech_RedirectEnergyToReactor("rule energy: " + key, c.u);
        if (redirect !is null) return redirect;
        return ByKey(c, key);
    }
    IUnitTask@ DoAssistEnergy(Ctx@ c)   { return ByKey(c, "assistenergy"); }
    IUnitTask@ DoT2Lab(Ctx@ c)
    {
        string why;
        if (EcoPlanner::PickT2Lab(c.eco, why).length() == 0) return null;
        return ByKey(c, "t2lab");
    }
    IUnitTask@ DoMexUpgrade(Ctx@ c)
    {
        string why;
        if (EcoPlanner::PickMexUpgrade(c.eco, why).length() == 0) return null;
        return ByKey(c, "mexup");
    }
    IUnitTask@ DoConverter(Ctx@ c)
    {
        string why;
        // when energy outscales metal a T1 converter's draw is granted even without a measured surplus
        float surplus = c.surplus;
        if (EnergyOutscalesMetal(c) && surplus < Global::RoleSettings::Tech::EcoConverterUse) surplus = Global::RoleSettings::Tech::EcoConverterUse;
        const string key = EcoPlanner::PickConverter(c.eco, surplus, why);
        if (key.length() == 0) return null;
        return ByKey(c, key);
    }
    // D-075, the owner's rule: metal income above spending while a structure
    // is under construction means build power is short: a construction
    // turret (the box slot nearest a lab), Layout::TurretsAllowed at a time (D-097);
    // the rest assist the turret going up. When nothing is under
    // construction the rows below order the next structure by priority.
    int powerTurretNoSlotLog = -100000;
    IUnitTask@ DoReclaimT2Lab(Ctx@ c) { return TechBuild::ReclaimT2Lab(c.u); }   // D-078
    IUnitTask@ DoEnergyReclaim(Ctx@ c) { return TechBuild::ReclaimEnergy(c.u, c.eco); }   // D-077
    IUnitTask@ DoPowerTurret(Ctx@ c)
    {
        const EcoPlanner::State@ s = c.eco;
        CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side));
        if (nano is null || !nano.IsAvailable(ai.frame)) return null;
        // before the advanced lab the rush owns the builders: only a bank that
        // has sat full for PowerAheadSeconds counts (played: a rising bank of 800
        // sent the commander to a turret at 4:00 and the advanced lab came at 7:13)
        if (!TechBuild::IntoT2() && !TechBuild::MetalFullLong()) return null;
        // build power scales with income: at the target, the rows below spend the metal instead
        // ... unless the metal bank has been full for PowerAheadSeconds: a full
        // bank with a structure under construction is build power short whatever
        // the ratio says (played: the advanced fusion took six minutes at a full
        // bank with the rule at its cap; the cap exists for the idle base after
        // the objective, D-075)
        if (!TechBuild::MetalFullLong() && s.buildPowerNear >= s.mIncome * Global::RoleSettings::Tech::PowerBuildPowerPerMetal) return null;
        const bool onNano = (c.building.circuitDef is nano);
        if (!onNano && !Layout::TurretsCapped() && c.d.CanBuild(nano)) {   // D-097: queued orders count too
            IUnitTask@ t = Layout::NanoTask(c.u, Task::Priority::HIGH);
            if (t !is null) {
                GenericHelpers::LogUtil("[TECH][Power] +" + int(s.mIncome) + " metal, " + TechBuild::MetalAheadWhy() + " (" + int(s.mCur) + " of " + int(s.mStor)
                    + ") while " + c.building.circuitDef.GetName() + " is under construction: turret by " + c.d.GetName() + " " + c.u.id, 1);
                return t;
            }
            if (ai.frame - powerTurretNoSlotLog > 30 * SECOND) {
                powerTurretNoSlotLog = ai.frame;
                GenericHelpers::LogUtil("[TECH][Power] no turret slot for " + c.d.GetName() + " (" + (s.turretSlot ? "slot yes" : "slot no") + ")", 1);
            }
        }
        if (s.nanosBuilding > 0) return ByKey(c, "assistnano");
        // D-098 (owner's rule): metal high while a structure is going up and no
        // turret may start: this builder's power goes on that structure
        if (c.building !is null && c.d.IsMobile())
            return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, c.building, 60 * SECOND));
        return null;
    }
    IUnitTask@ DoTurret(Ctx@ c)
    {
        string why;
        const string key = EcoPlanner::PickTurret(c.eco, c.floatingM, why);   // "nano", "assistnano" or ""
        if (key.length() == 0) return null;
        return ByKey(c, key);
    }
    IUnitTask@ DoEnergyStorage(Ctx@ c)
    {
        const EcoPlanner::State@ s = c.eco;
        const string name = UnitHelpers::GetEnergyStorageNameForSide(Global::AISettings::Side);
        const bool lulls = s.winds >= Global::RoleSettings::Tech::EcoStorageWinds && s.estors + s.estorsQueued < 1 && s.mIncome >= 4.0f;
        const bool small = s.estors + s.estorsQueued < Global::RoleSettings::Tech::EcoMaxEnergyStorages
            && s.eStor < s.eIncome * Global::RoleSettings::Tech::EcoStorageSeconds && s.mIncome >= 15.0f
            && s.mCur >= Global::RoleSettings::Tech::EcoStorageMinMetalBank;
        if (!(lulls || small) || !EcoPlanner::Buildable(name, s)) return null;
        return ByKey(c, "estor");
    }
    IUnitTask@ DoMetalStorage(Ctx@ c)
    {
        const EcoPlanner::State@ s = c.eco;
        const string name = UnitHelpers::GetMetalStorageNameForSide(Global::AISettings::Side);
        if (!(aiEconomyMgr.isMetalFull && s.mstors + s.mstorsQueued < Global::RoleSettings::Tech::EcoMaxMetalStorages && s.mIncome >= 20.0f)) return null;
        if (!EcoPlanner::Buildable(name, s)) return null;
        return ByKey(c, "mstor");
    }
    IUnitTask@ DoBestPayback(Ctx@ c)
    {
        array<EcoPlanner::Option@> opts = EcoPlanner::EnergyOptions(c.eco);
        for (uint i = 0; i < opts.length(); ++i)
            if (EcoPlanner::Affordable(opts[i], c.eco)) return ByKey(c, opts[i].key);
        return null;
    }
    // AIR: more T2 aircraft plants as income allows, and the nanos that serve
    // them (roles/air.as); nothing of TECH's strategic ladder
    IUnitTask@ DoAirPlants(Ctx@ c)      { return RoleAir::Air_PlantsAndNanos(c.u, c.mi); }
    IUnitTask@ DoLegacy(Ctx@ c)
    {
        if (EcoRole::IsAir()) return null;
        if (c.who == COMMANDER) return RoleTech::Tech_Commander_AiMakeTask(c.u, null, c.mi);
        return TechBuild::Strategic(c.u, c.mi, c.ei);
    }
    IUnitTask@ DoDefence(Ctx@ c)        { return TechBuild::Defence(c.u); }
    IUnitTask@ DoQueuedRepair(Ctx@ c)   { return TechBuild::QueuedOrder(c.u); }
    IUnitTask@ DoAssistAny(Ctx@ c)
    {
        return TechBuild::AssistAny(c.u, (c.who == COMMANDER) ? Global::RoleSettings::Tech::ExpCommanderHomeRadius
                                                               : Global::RoleSettings::Tech::ExpAssistRadius);
    }
    IUnitTask@ DoGuardFactory(Ctx@ c)   { return TechBuild::GuardFactory(c.u); }

    array<When@> W0() { array<When@> a; return a; }
    array<When@> W1(When@ a1) { array<When@> a = {a1}; return a; }
    array<When@> W2(When@ a1, When@ a2) { array<When@> a = {a1, a2}; return a; }
    array<When@> W3(When@ a1, When@ a2, When@ a3) { array<When@> a = {a1, a2, a3}; return a; }
    array<When@> W4(When@ a1, When@ a2, When@ a3, When@ a4) { array<When@> a = {a1, a2, a3, a4}; return a; }
    array<When@> W5(When@ a1, When@ a2, When@ a3, When@ a4, When@ a5) { array<When@> a = {a1, a2, a3, a4, a5}; return a; }

    // ---------------------------------------------------------------- the table

    class Rule {
        string key;
        int who;
        array<When@> when;
        Act@ act;
        string note;
        Rule(const string &in k, int w, array<When@> ws, Act@ a, const string &in n)
        {
            key = k; who = w; when = ws; @act = a; note = n;
        }
    }

    array<Rule@> table;

    void Init()
    {
        if (table.length() > 0) return;
        table.insertLast(Rule("turret.spam",       TURRET,       W1(@TechRole), @DoTurretSpam,   "D-109: the two turrets directly behind a spam lab always work for that lab"));
        table.insertLast(Rule("turret.assist",     TURRET,       W0(), @DoTurretAssist, "reclaim in reach, then the economy under construction by the D-065 order"));
        table.insertLast(Rule("turret.any",        TURRET,       W0(), @DoTurretAny,    "any structure of ours under construction within reach"));
        table.insertLast(Rule("turret.factory",    TURRET,       W1(@MetalFloodedLong), @DoTurretFactory, "D-105: the metal bank full and nothing to build in reach: assist a producing factory in reach (production is the sink)"));
        table.insertLast(Rule("turret.wait",       TURRET,       W0(), @DoWaitShort,    "5 s"));
        table.insertLast(Rule("ferry.cargo",       MOBILE,       W0(), @DoFerryCargo,   "D-110/D-112: a gift (in flight or queued) keeps the ferry's hold or its park behind the base until the drop-off; nothing else"));
        table.insertLast(Rule("land.recall",       CONSTRUCTORS, W1(@TechRole), @DoLandRecall,   "D-109: a tier whose air constructors went down: its land constructors drop a forward job for the eco rows"));
        table.insertLast(Rule("keep.current",      MOBILE,       W0(), @DoKeepCurrent,  "the construction the builder is on, when native re-asks"));
        table.insertLast(Rule("air.dedicated",     CON_T2,       W0(), @DoAirDedicated, "D-107: the first two T2 air constructors: one only advanced energy converters, the other only advanced fusions, always"));
        table.insertLast(Rule("air.flex",          CON_T2,       W0(), @DoAirFlexible,  "D-107: the other T2 air constructors: advanced converters while energy overflows, the advanced fusion going up when the converters cannot stay on"));
        table.insertLast(Rule("fwd.t2.defend",     CON_T2,       W3(@TechRole, @LandCon, @T2LandReleased), @DoDefendMexes, "D-109: the T2 air constructors are up: T2 land constructors defend the mex clusters, long-range AA then flak"));
        table.insertLast(Rule("fwd.t1",            CON_T1,       W3(@TechRole, @LandCon, @T1LandReleased), @DoForwardT1,   "D-109: more than 5 T1 air constructors: T1 land constructors build the spam cluster forward (labs, their turrets, AA, pads)"));
        table.insertLast(Rule("opening.mex",       COMMANDER,    W1(@OpeningPending), @DoOpening,      "the nearest OpeningMexCap mexes within OpeningMexRadius"));
        table.insertLast(Rule("lab.t1.reclaim",    MOBILE,       W2(@TechRole, @IntoT2), @DoReclaimT1Lab, "the advanced lab is under way: every builder in range reclaims the T1 lab"));
        table.insertLast(Rule("lab.t2.reclaim",     MOBILE,       W2(@TechRole, @T2LabRetiring), @DoReclaimT2Lab, "D-078: the advanced lab is retiring (an advanced fusion is under construction, the bank has room): every builder reclaims it, turrets in range join"));
        table.insertLast(Rule("lab.base.reclaim",   MOBILE,       W2(@TechRole, @BaseFactoryToGo), @DoBaseFactoryReclaim, "D-114: with 3 land factories on the map the base's land factories are retired and reclaimed; their ground goes back to the economy"));
        table.insertLast(Rule("lab.front",          CONSTRUCTORS, W2(@TechRole, @FrontClusterOpen), @DoFrontCluster, "D-114: a front cluster's lost turret; an open T2 or T3 front factory cluster: its turrets, help on one going up, then its factory"));
        table.insertLast(Rule("energy.reclaim",     MOBILE,       W2(@EnergyReclaimable, @NotStalling), @DoEnergyReclaim, "D-077: a fusion stands and energy income without the T1 sources covers the pull by ReclaimT1EnergyMargin: reclaim winds and solars nearest the base centre; advanced solars at ReclaimAdvSolarMargin; an advanced fusion reclaims all"));
        // D-105 (owner's rule): T1 constructors add build power before assisting a
        // T2 construction; the reclaim rows above stay first
        table.insertLast(Rule("power.t1",          CON_T1,       W2(@DearFrameUp, @TurretRoom), @DoT1Turret,     "D-105: a dear frame is up and the turret calculation has room: a T1 constructor adds a construction turret rather than assist"));
        table.insertLast(Rule("energy.convert.float", MOBILE,     W4(@EnergyFloatsBank, @NotStalling, @NoDearOrderPending, @NotMetalFull), @DoConverter,    "D-079: before the chain - energy floats (TechChain::EnergyFloats): a converter, whatever the chain is doing"));
        table.insertLast(Rule("power.turret",      MOBILE,       W4(@MetalAhead, @StructureBuilding, @NotStalling, @NoDearOrderPending), @DoPowerTurret, "D-075: metal income above spending while a structure is under construction: a turret, Layout::TurretsAllowed at a time (D-097), else assist the turret going up"));
        table.insertLast(Rule("air.plants",        CONSTRUCTORS, W1(@AirRole), @DoAirPlants,  "AIR: another T2 aircraft plant as income stages allow (100, 200), placed by the layout; nanos at the plants while metal floats"));
        table.insertLast(Rule("chain.next",        MOBILE,       W1(@ChainActive), @DoChain,      "the rush chain (D-070): the first unmet target - assist its frame, wait for its order, or order it"));
        table.insertLast(Rule("lab.t1.opening",    MOBILE,       W3(@OpeningDone, @NotIntoT2, @NoT1Lab), @DoStartFactory, "the throwaway first lab at the commander; a constructor uses the pair's slot"));
        table.insertLast(Rule("lab.t1.recover",    COMMANDER,    W3(@OpeningDone, @NoConstructors, @NoLabAtAll), @DoStartFactory, "every constructor and every lab lost: the commander rebuilds a T1 lab"));
        table.insertLast(Rule("mex.expand",        CONSTRUCTORS, W2(@OpeningDone, @MetalBottleneck), @DoExpandMex,    "the nearest open spot within EcoMexExpandRadius while metal is the bottleneck"));
        table.insertLast(Rule("energy.draining",   MOBILE,       W2(@Draining, @EnergyIdle), @DoEnergy,       "the base is stalling: cheapest energy per E/s, a fusion in the fusion era"));
        table.insertLast(Rule("energy.assist",     MOBILE,       W3(@Draining, @EnergyBusy, @EnergyAssistable), @DoAssistEnergy, "stalling and one is going up within EcoAssistRadius: assist it"));
        table.insertLast(Rule("lab.t2",            CONSTRUCTORS, W2(@OpeningDone, @NoAfusYetOrAgain), @DoT2Lab,        "the advanced lab the moment +18 metal / 250 energy clear (PickT2Lab); again once the economy is online and none stands (D-102)"));
        table.insertLast(Rule("mex.upgrade",       CON_T2,       W0(), @DoMexUpgrade,   "the nearest owned T1 mex within MexUpgradeRadius, one at a time"));
        table.insertLast(Rule("energy.convert",    MOBILE,       W3(@ConverterWanted, @NotStalling, @NotMetalFull), @DoConverter,    "energy floating, a surplus of twice a converter's draw, or energy income past EcoEnergyRatioHigh x metal: a converter"));
        table.insertLast(Rule("turret.build",      MOBILE,       W0(), @DoTurret,       "static build power under EcoBuildPowerPerMetal x metal, or metal floating: a turret on its slot; else assist the one going up"));
        table.insertLast(Rule("energy.short",      MOBILE,       W3(@EnergyShort, @EnergyIdle, @EnergyForMe), @DoEnergy,       "below the energy target and nothing going up: cheapest energy per E/s"));
        table.insertLast(Rule("energy.assist2",    MOBILE,       W3(@EnergyShort, @EnergyBusy, @EnergyAssistable), @DoAssistEnergy, "below target and one is going up within EcoAssistRadius: assist it"));
        table.insertLast(Rule("storage.energy",    MOBILE,       W0(), @DoEnergyStorage, "one energy storage once winds carry the base, or the bank holds under EcoStorageSeconds"));
        table.insertLast(Rule("storage.metal",     MOBILE,       W0(), @DoMetalStorage, "metal storage when the bank is full"));
        table.insertLast(Rule("energy.float",      MOBILE,       W3(@MetalFloating, @EnergyAhead, @EnergyIdle), @DoBestPayback,  "metal floating with energy ahead: the best-payback source anyway"));
        table.insertLast(Rule("legacy.strategic",  MOBILE,       W1(@ChainInactive), @DoLegacy,       "the role's strategic rungs as they stand (nukes, anti-nuke, gantry, water factories, T2 constructor policy)"));
        table.insertLast(Rule("defence.base",      CONSTRUCTORS, W1(@FirstTurretStands), @DoDefence,      "one light laser and one light AA near the factories"));
        table.insertLast(Rule("order.repair",      CONSTRUCTORS, W0(), @DoQueuedRepair, "native's queued repairs of our own unfinished structures within ExpOrderRadius"));
        table.insertLast(Rule("assist.any",        MOBILE,       W0(), @DoAssistAny,    "the nearest structure under construction within the builder's assist radius"));
        table.insertLast(Rule("guard.factory",     CONSTRUCTORS, W0(), @DoGuardFactory, "guard the primary T1 lab"));
        table.insertLast(Rule("wait",              MOBILE,       W0(), @DoWait,         "3 s, then ask again"));
        GenericHelpers::LogUtil("[Rule] table of " + table.length() + " rules loaded", 1);
    }

    // ---------------------------------------------------------------- evaluation and trace

    dictionary lastKeyByUnit;   // unit id -> last key, for the level-1 change trace

    IUnitTask@ Evaluate(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null) return null;
        Init();
        Ctx@ c = Build(u);
        {   // diagnostic (D-070 benchmarks): what the unit holds when it is asked
            IBuilderTask@ cur = (u.task is null) ? null : cast<IBuilderTask>(u.task);
            const string sig = (u.task is null) ? "no task" : ((cur is null) ? "non-builder task" : ("builder task type " + int(cur.GetBuildType())
                + (cur.buildDef is null ? "" : " " + cur.buildDef.GetName())));
            const string id = "ask" + u.id;
            string last; lastKeyByUnit.get(id, last);
            if (last != sig) { lastKeyByUnit.set(id, sig); GenericHelpers::LogUtil("[Rule][ask] " + c.d.GetName() + " " + u.id + " holds " + sig, 3); }
        }
        for (uint i = 0; i < table.length(); ++i) {
            Rule@ r = table[i];
            if ((r.who & c.who) == 0) continue;
            bool ok = true;
            for (uint k = 0; k < r.when.length() && ok; ++k) ok = r.when[k](c);
            if (!ok) continue;
            IUnitTask@ t = r.act(c);
            if (t is null) continue;
            Trace(c, r);
            return t;
        }
        return null;
    }

    void Trace(Ctx@ c, const Rule@ r)
    {
        const string id = "" + c.u.id;
        string last;
        lastKeyByUnit.get(id, last);
        const int level = (last == r.key || r.key == "keep.current" || r.key == "wait" || r.key == "turret.wait") ? 3 : 1;
        lastKeyByUnit.set(id, r.key);
        GenericHelpers::LogUtil("[Rule] " + r.key + " for " + c.d.GetName() + " " + c.u.id + " | M +" + int(c.mi) + " E " + int(c.ei)
            + "/" + int(c.energyTarget) + (c.intoT2 ? " T2" : " T1") + (c.draining ? " draining" : "") + (c.floatingE ? " E-float" : "")
            + (c.floatingM ? " M-float" : ""), level);
    }
}
