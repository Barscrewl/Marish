// role: AIR
#include "../helpers/unit_helpers.as"
#include "../helpers/unitdef_helpers.as"
#include "../helpers/objective_helpers.as"
#include "../helpers/economy_helpers.as"
#include "../types/role_config.as"
#include "../global.as"
#include "../types/terrain.as"
// Dynamic factory production
#include "../manager/factory_production.as"
// T2 bomber waves
#include "../manager/air_waves.as"
// The economy: TECH's experimental build system on the aircraft plants
// (manager/eco_role.as; see ECONOMY below)
#include "../manager/eco_role.as"
#include "../manager/layout.as"
#include "tech.as"

/******************************************************************************

ECONOMY

AIR's economy is TECH's experimental build system (D-066), run on the aircraft
plants: the opening mexes, the rush chain to the advanced fusion (mexes, T1
aircraft plant, energy, the advanced aircraft plant, T2 mex upgrades, fusion,
turrets, advanced fusion), the planned base (the factory pair and the turret
box: every economy structure packed within a turret's reach, D-060/D-063),
the eco planner's energy, converter, storage and turret rows, the block of
construction turrets in the turret box (the chain's nano step, power.t1,
power.turret, turret.build: D-075/D-097/D-105), energy reclaim once a reactor
stands (D-077), and after the chain the metal-income ladder (mex upgrades,
advanced fusions) to +200 and +500. Every builder asks roles/tech_rules.as
(TechBuild::MakeTask); never null.

What differs from TECH (manager/eco_role.as):
  - the labs are the T1 and T2 aircraft plants, and neither is ever reclaimed
    to fund the economy
  - TECH's land rows (forward constructors, front factory clusters, spam labs)
    do not run
  - every T2 constructor is an air constructor: the first
    Air::ChainT2Constructors are the chain's (what TECH's T2 bot constructors
    are: mohos first, then the fusion, then the advanced fusion); only those
    the plan adds beyond them (from +200) take the dedicated converter /
    advanced fusion roles (D-107)
  - row air.plants: another T2 aircraft plant at each income stage (100, 200,
    ADVANCED AIRCRAFT PLANT CAP), placed by the layout (Air_T2Plants)
  - BuildPower (manager/build_power.as) is off: its native turret and gantry
    orders are never taken by the table, and its queued turrets held the
    layout's turret count full
  - METAL-STARVED MODE still holds porc to the preventive structure and the
    plants to wave bombers

The switch is Global::RoleSettings::Air::ExperimentalEco.

******************************************************************************/
namespace RoleAir {
    bool g_airGunshipOpenerDone = false;
    int g_airStrikeOpenerQueuedCount = 0;

    bool Air_IsEconomyHealthy()
    {
        return !aiEconomyMgr.isEnergyStalling;
    }

    bool Air_IsCombatProductionReady(float metalIncome, float energyIncome)
    {
        return Air_IsEconomyHealthy()
            && metalIncome >= Global::RoleSettings::Air::T1CombatProductionMetalIncome
            && energyIncome >= Global::RoleSettings::Air::T1CombatProductionEnergyIncome;
    }

    /******************************************************************************

    DYNAMIC MILITARY QUOTAS

    ******************************************************************************/

    // Compute the total metal "power" of our AIR force only (T1+T2 combat aircraft).
    // This intentionally ignores non-air units so that AIR's aggression reflects
    // the strength of its own role rather than the entire global army.
    float Air_GetArmyMetalCostEstimate()
    {
        // Sum metal cost for all T1/T2 combat aircraft we currently field.
        float airCost = 0.f;

        // T1 combat aircraft
        {
            array<string> t1Air = UnitHelpers::GetAllT1AircraftCombatUnits();
            for (uint i = 0; i < t1Air.length(); ++i) {
                CCircuitDef@ d = ai.GetCircuitDef(t1Air[i]);
                if (d is null) continue;
                const int count = UnitDefHelpers::GetUnitDefCount(t1Air[i]);
                if (count <= 0) continue;
                airCost += d.costM * float(count);
            }
        }

        // T2 combat aircraft
        {
            array<string> t2Air = UnitHelpers::GetAllT2AircraftCombatUnits();
            for (uint i = 0; i < t2Air.length(); ++i) {
                CCircuitDef@ d = ai.GetCircuitDef(t2Air[i]);
                if (d is null) continue;
                const int count = UnitDefHelpers::GetUnitDefCount(t2Air[i]);
                if (count <= 0) continue;
                airCost += d.costM * float(count);
            }
        }

        // NaN check: NaN is the only value not equal to itself
        if (!(airCost == airCost) || airCost < 0.f) {
            airCost = 0.f;
        }

        return airCost;
    }

    // Adjust AIR military quotas based on comparison of our AIR metal cost vs cached enemy AIR cost.
    void Air_UpdateDynamicMilitaryQuotas()
    {
        // Estimate our AIR metal cost only (excludes land/sea forces)
        float ourArmyCost = Air_GetArmyMetalCostEstimate();

        // Enemy AIR metrics (cost per player) are cached centrally in Military when
        // the enemy cost cache is updated; we just read the derived values here.
        float enemyAirCostPerPlayer = Military::GetEnemyAirCostPerPlayer();
        float enemyAirCostTotal     = Military::g_cachedTotalAirCost; // for logging only

        // Defensive sanity checks
        if (!(enemyAirCostPerPlayer == enemyAirCostPerPlayer) || enemyAirCostPerPlayer < 0.f) {
            enemyAirCostPerPlayer = 0.f;
        }

        float threshold = enemyAirCostPerPlayer * Global::RoleSettings::Air::DynamicQuotaEnemyCostThresholdMultiplier;

        bool isUnderpowered = (ourArmyCost < threshold);

        if (isUnderpowered) {
            // When underpowered vs enemy air cost, push quotas high to encourage more army production.
            aiMilitaryMgr.quota.attack = Global::RoleSettings::Air::UnderpoweredAttackQuota;
            aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Air::UnderpoweredRaidMinQuota;
            aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Air::UnderpoweredRaidAvgQuota;

            GenericHelpers::LogUtil(
                "[AIR][Quota] Underpowered vs enemy air (ourAirCost=" + ourArmyCost +
                " enemyAirCostTotal=" + enemyAirCostTotal +
                " enemyAirPerPlayer=" + enemyAirCostPerPlayer +
                " thr=" + threshold +
                ") => HIGH quotas: scout=" + aiMilitaryMgr.quota.scout +
                " attack=" + aiMilitaryMgr.quota.attack +
                " raid.min=" + aiMilitaryMgr.quota.raid.min +
                " raid.avg=" + aiMilitaryMgr.quota.raid.avg,
                3
            );
        } else {
            // When not underpowered, keep quotas near their air-role defaults.
            aiMilitaryMgr.quota.scout = Global::RoleSettings::Air::MilitaryScoutCap;
            aiMilitaryMgr.quota.attack = Global::RoleSettings::Air::MilitaryAttackThreshold;
            aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Air::MilitaryRaidMinPower;
            aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Air::MilitaryRaidAvgPower;

            GenericHelpers::LogUtil(
                "[AIR][Quota] Competitive vs enemy air (ourAirCost=" + ourArmyCost +
                " enemyAirCostTotal=" + enemyAirCostTotal +
                " enemyAirPerPlayer=" + enemyAirCostPerPlayer +
                " thr=" + threshold +
                ") => BASE quotas: scout=" + aiMilitaryMgr.quota.scout +
                " attack=" + aiMilitaryMgr.quota.attack +
                " raid.min=" + aiMilitaryMgr.quota.raid.min +
                " raid.avg=" + aiMilitaryMgr.quota.raid.avg,
                4
            );
        }
    }

    // Delay for dynamic quota adjustments: mirrors Front role but scoped to AIR.
    const int AIR_DYNAMIC_QUOTA_DELAY_FRAMES = Global::RoleSettings::Air::DynamicQuotaDelaySeconds * SECOND;

    /******************************************************************************

    INITIALIZATION

    ******************************************************************************/
    void Air_Init() {
        GenericHelpers::LogUtil("Air role initialization logic executed", 2);
        g_airGunshipOpenerDone = false;
        g_airStrikeOpenerQueuedCount = 0;
        g_airLastScoutFrame = -1;
        g_airT2ProductionTurn = 0;

        // Apply AIR role settings
        aiTerrainMgr.SetAllyZoneRange(Global::RoleSettings::Air::AllyRange);

        // Porc cadence: reach the full chain mid game, spend more per visit,
        // and put AA on the allies' clusters as well as our own.
        Global::Porc::LateGameMinutes = Global::RoleSettings::Air::PorcLateGameMinutes;
        Global::Porc::LateGameMetalIncome = Global::RoleSettings::Air::PorcLateGameMetalIncome;
        Global::Porc::LateGameEnergyIncome = Global::RoleSettings::Air::PorcLateGameEnergyIncome;
        Global::Porc::LateBudgetMod = Global::RoleSettings::Air::PorcLateBudgetMod;
        aiMilitaryMgr.porcAllyAA = Global::RoleSettings::Air::PorcAlliedClustersAA ? 1 : 0;
        // Change scout cap (unit count)
        aiMilitaryMgr.quota.scout = Global::RoleSettings::Air::MilitaryScoutCap;

        // Change attack gate (power threshold, not a headcount)
        aiMilitaryMgr.quota.attack = Global::RoleSettings::Air::MilitaryAttackThreshold;

        // Change raid thresholds (power)
        aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Air::MilitaryRaidMinPower;
        aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Air::MilitaryRaidAvgPower;

        GenericHelpers::LogUtil("[Air][Quota] scout=" + aiMilitaryMgr.quota.scout +
            " attack=" + aiMilitaryMgr.quota.attack +
            " raid.min=" + aiMilitaryMgr.quota.raid.min +
            " raid.avg=" + aiMilitaryMgr.quota.raid.avg, 3);

        Air_ApplyStartLimits();
        Air_CloseBastionGate();
        Air_CapT1Strike();
        Air_InitT2PlantCap();
        AirWaves::Init();

        // The economy (see ECONOMY): TECH's experimental build system, switched
        // on for this instance the way Tech_Init does it. The layout plan
        // follows from setup (Air_LayoutPlan) once the caps and porc are in.
        if (EcoRole::Enabled()) {
            Layout::Enable(Global::RoleSettings::Tech::LayoutEnabled);
            aiEconomyMgr.assistNanoEnabled = false;   // the planner owns turrets (D-063)
            aiEconomyMgr.reclEnergyEff = 0.0f;        // the energy.reclaim row owns energy reclaim (D-077)
            aiBuilderMgr.experimentalBuild = true;
            aiBuilderMgr.experimentalDirectRange = Global::RoleSettings::Tech::ExperimentalBuildDirectRange;
            aiBuilderMgr.experimentalSearchRadius = Global::RoleSettings::Tech::ExperimentalSearchRadius;
            RoleTech::Opening::Init();
            TechChain::Init();   // D-070: the rush chain to the advanced fusion
            TechPlan::Init();    // the metal ladder after it
            @Global::energyAllowed = @TechBuild::EnergyAllowed;   // D-077: no T1 energy in the fusion era
            GenericHelpers::LogUtil("[AIR][Eco] TECH's experimental build system on the aircraft plants: direct range "
                + int(aiBuilderMgr.experimentalDirectRange) + ", search radius " + int(aiBuilderMgr.experimentalSearchRadius), 1);
        } else {
            aiBuilderMgr.experimentalBuild = false;
            GenericHelpers::LogUtil("[AIR][Eco] experimental economy off: native builder defaults", 1);
        }

        // Initialize dynamic factory production system for AIR role when enabled
        if (Global::RoleSettings::Air::UseDynamicFactoryProduction) {
            FactoryProduction::Initialize();
            GenericHelpers::LogUtil("[AIR] Dynamic factory production system initialized", 2);
        } else {
            GenericHelpers::LogUtil("[AIR] Dynamic factory production disabled; using legacy factory selection", 2);
        }

        // Log all strategic objectives with distance from start
        ObjectiveHelpers::LogAllObjectivesFromStart(AiRole::AIR, "AIR");
    }

    void Air_ApplyStartLimits() {
        dictionary startLimits; 

        //Limit gantries to 0

        startLimits.set("armshltx", 0);
        startLimits.set("armshltxuw", 0);
        startLimits.set("corgant", 0);
        startLimits.set("corgantuw", 0);
        startLimits.set("leggant", 0);

        startLimits.set("armvp", 0);
        startLimits.set("corvp", 0);
        startLimits.set("legvp", 0);
        startLimits.set("armlab", 0);
        startLimits.set("corlab", 0);
        startLimits.set("leglab", 0);

        startLimits.set("armsilo", 0);
        startLimits.set("corsilo", 0);
        startLimits.set("legsilo", 0);

        array<string> t1GroundDefences = UnitHelpers::GetAllT1LandDefences();
        for (uint i = 0; i < t1GroundDefences.length(); ++i) {
            startLimits.set(t1GroundDefences[i], 0);
        }

        UnitHelpers::ApplyUnitLimits(startLimits);

        GenericHelpers::LogUtil("Air start limits applied", 3);
    }

    /******************************************************************************

    BASTION GATE

    The T1 land defences above are capped at 0, and native DefaultMakeDefence
    skips an unavailable def without counting its cost; it also skips anti-air
    (legrl, leglupara) while the enemy has no air. On a Legion porc visit the
    land chain [leglht, legrl, leghive, leghive, legmg, leghive, leglupara,
    legjuno, legbastion, ...] therefore reaches legbastion (index 12 of the
    porcupine list in build_chain_leg.json) right after legjuno, and its
    defence hub adds three caretakers, a jammer and a shield. Keep it capped at 0
    until the native average metal income reaches BastionMinAvgMetalIncome, then
    restore the cap it had. One-way: a later dip does not close it again.

    ******************************************************************************/
    const string AIR_GATED_BASTION = "legbastion";
    bool g_airBastionReleased = false;
    int g_airBastionCap = 0;

    void Air_CloseBastionGate() {
        g_airBastionReleased = false;
        CCircuitDef@ d = ai.GetCircuitDef(AIR_GATED_BASTION);
        if (d is null) {
            g_airBastionReleased = true;
            return;
        }
        g_airBastionCap = d.maxThisUnit;
        d.maxThisUnit = 0;
        GenericHelpers::LogUtil("[AIR][Bastion] " + AIR_GATED_BASTION + " capped at 0 until avg metal income >= "
            + Global::RoleSettings::Air::BastionMinAvgMetalIncome + " (restores cap " + g_airBastionCap + ")", 2);
    }

    /******************************************************************************

    T1 STRIKE CAP

    Past the strike opener, native DefaultMakeTask picks T1 bombers and gunships
    from the plant's factory.json weights (20% each on armap/corap), and those
    weights are shared with every role. AIR caps each of these defs at
    T1StrikeCapBeforeT2 alive until Factory::primaryT2AirPlant is set - it is set
    when the plant is finished, not when it is started - then restores the caps
    they had. DefaultMakeTask skips an unavailable def, so the weight falls to
    the rest of the list (fighters, constructors). One-way.

    Metal storages ride on the same latch at cap 0 (Barb4 caps them for AIR
    outright): native UpdateStorageTasks queues one at HIGH priority whenever
    metal is full, which for AIR is exactly when it is banking for the T2 plant.
    Energy storage is untouched.

    ******************************************************************************/
    const array<string> AIR_T1_STRIKE_DEFS = { "armthund", "armkam", "corshad", "corbw", "legmos", "legcib", "legkam" };
    const array<string> AIR_METAL_STORAGE_DEFS = { "armmstor", "cormstor", "legmstor", "armuwadvms", "coruwadvms",
        "legamstor", "leguwmstore", "leganavalmstor" };
    dictionary g_airT1StrikeCaps;   // def name -> cap to restore
    bool g_airT1StrikeCapped = false;

    void _Air_CapDefs(const array<string> &in names, int cap) {
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d is null) continue;
            g_airT1StrikeCaps.set(names[i], d.maxThisUnit);
            if (d.maxThisUnit > cap) d.maxThisUnit = cap;
        }
    }

    void Air_CapT1Strike() {
        g_airT1StrikeCaps.deleteAll();
        const int cap = Global::RoleSettings::Air::T1StrikeCapBeforeT2;
        _Air_CapDefs(AIR_T1_STRIKE_DEFS, cap);
        _Air_CapDefs(AIR_METAL_STORAGE_DEFS, 0);
        g_airT1StrikeCapped = true;
        GenericHelpers::LogUtil("[AIR][T1Strike] T1 bombers/gunships capped at " + cap
            + " each, metal storages at 0, until the first T2 aircraft plant is finished", 2);
    }

    void Air_UpdateT1StrikeCap() {
        if (!g_airT1StrikeCapped || Factory::primaryT2AirPlant is null) return;
        g_airT1StrikeCapped = false;
        array<string>@ names = g_airT1StrikeCaps.getKeys();
        for (uint i = 0; i < names.length(); ++i) {
            int orig = 0;
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d is null || !g_airT1StrikeCaps.get(names[i], orig)) continue;
            d.maxThisUnit = orig;
        }
        GenericHelpers::LogUtil("[AIR][T1Strike] T2 aircraft plant finished: T1 bomber/gunship and metal storage caps restored", 1);
    }

    void Air_UpdateBastionGate() {
        if (g_airBastionReleased) return;
        const float avgMetalIncome = aiEconomyMgr.metal.income;
        if (avgMetalIncome < Global::RoleSettings::Air::BastionMinAvgMetalIncome) return;
        g_airBastionReleased = true;
        CCircuitDef@ d = ai.GetCircuitDef(AIR_GATED_BASTION);
        if (d is null) return;
        d.maxThisUnit = g_airBastionCap;
        GenericHelpers::LogUtil("[AIR][Bastion] avg metal income " + avgMetalIncome + " >= "
            + Global::RoleSettings::Air::BastionMinAvgMetalIncome + ": " + AIR_GATED_BASTION
            + " released (cap " + g_airBastionCap + ")", 1);
    }

    /******************************************************************************

    MAIN HOOKS

    ******************************************************************************/

    /******************************************************************************

    METAL-STARVED MODE

    At low bonuses AIR's metal bank sat empty while its T2 plant built escorts and
    heavy air, native fallback production filled in with fighters (factory.json
    weights them 37-90% at low income), and the shared porc policy's pressure
    rule - which compares the enemy's surface army with ours, and AIR has little -
    put every cluster on the FULL porcupine order. Below EcoPriorityEnterPercent
    of metal storage, until back above EcoPriorityExitPercent, porc is held to
    the preventive structure per cluster (Air_AiMakeDefence), the T2 plants to
    wave bombers and constructors (no escorts, scouts, heavy air or fallback
    fighters), and no further T2 plant is ordered (Air_T2Plants). The
    economy itself (TECH's rule table) is not held back.

    ******************************************************************************/
    bool g_airMetalStarved = false;

    bool Air_IsMetalStarved()
    {
        return Global::RoleSettings::Air::EcoPriorityEnabled && g_airMetalStarved;
    }

    void Air_UpdateEcoPriority()
    {
        const float storage = aiEconomyMgr.metal.storage;
        if (storage <= 0.0f) return;
        const float pct = aiEconomyMgr.metal.current / storage;
        const bool was = g_airMetalStarved;
        if (!g_airMetalStarved && pct < Global::RoleSettings::Air::EcoPriorityEnterPercent) g_airMetalStarved = true;
        else if (g_airMetalStarved && pct > Global::RoleSettings::Air::EcoPriorityExitPercent) g_airMetalStarved = false;
        if (was != g_airMetalStarved && Global::RoleSettings::Air::EcoPriorityEnabled) {
            GenericHelpers::LogUtil("[AIR][EcoPriority] metal bank " + int(pct * 100.0f) + "% of " + int(storage)
                + (g_airMetalStarved ? ": starved - T2 plants to wave bombers and constructors, porc PREVENT"
                                     : ": recovered - normal production"), 1);
        }
    }

    // Porc while starved: the preventive structure per cluster and nothing more.
    // Otherwise the shared policy (Military::Porc).
    void Air_AiMakeDefence(int cluster, const AIFloat3& in pos)
    {
        // Same opening gate as the handler-less path in Military::AiMakeDefence.
        if (!((ai.frame > 10 * MINUTE) || (aiEconomyMgr.metal.income > 10.f) || (aiEnemyMgr.mobileThreat > 0.f))) return;
        if (!Air_IsMetalStarved()) {
            Military::Porc::MakeDefence(cluster, pos);
            return;
        }
        aiMilitaryMgr.porcMode = Military::Porc::MODE_PREVENT;
        aiMilitaryMgr.porcBudgetMod = 1.0f;
        GenericHelpers::LogUtil("[Porc] cluster=" + cluster + " mode=PREVENT (AIR metal-starved)", 3);
        aiMilitaryMgr.DefaultMakeDefence(cluster, pos);
    }

    // A factory with nothing it may build while starved waits and asks again,
    // instead of the native fallback (fighters at low income).
    IUnitTask@ Air_StarvedFactoryWait(const string &in fname)
    {
        GenericHelpers::LogUtil("[AIR][EcoPriority] " + fname + " idles: metal-starved", 3);
        return aiFactoryMgr.Enqueue(TaskS::Wait(false, Global::RoleSettings::Air::EcoPriorityFactoryWaitSeconds * SECOND));
    }

    void Air_MainUpdate() {
        Air_UpdateEcoPriority();
        // Periodically update dynamic military quotas once the configured delay has passed
        if (ai.frame >= AIR_DYNAMIC_QUOTA_DELAY_FRAMES) {
            Air_UpdateDynamicMilitaryQuotas();
        }
        Air_UpdateBastionGate();
        Air_UpdateT1StrikeCap();
        Air_UpdateT2PlantCap();
        // T2 bomber waves: launch when the hold reaches the target, size the next wave
        AirWaves::Update();
        //LogUtil("Air update logic executed", 5);
    }

    /******************************************************************************

    ECONOMY HOOKS

    The experimental system's per-update work, as Tech_EconomyUpdate runs it:
    the opening's deadline, the bank trackers and the overflow share
    (TechBuild::Tick), the chain's energy tracker and caps (TechChain::Tick),
    and the layout's restored state (Layout::Update). TECH's invariants
    (manager/invariants.as) are TECH's promises and are not checked here.

    ******************************************************************************/

    void Air_EconomyUpdate() {
        if (!EcoRole::Enabled()) return;
        const float metalIncome = Economy::GetMinMetalIncomeLast10s();
        RoleTech::Opening::Tick();
        TechBuild::Tick();
        TechChain::Tick();
        Layout::Update(metalIncome, Factory::primaryT2AirPlant !is null,
            UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2AirConstructors()));
    }

    // Setup (LayoutHelpers::ApplyForRole): the factory pair (the T1 and T2
    // aircraft plants) and the turret box behind it, as for TECH.
    void Air_LayoutPlan(const string &in side)
    {
        Layout::Plan(side);
    }

    /******************************************************************************

    FACTORY HOOKS

    ******************************************************************************/

    // Resolve a strike aircraft that the side's T1 aircraft plant can actually build.
    string GetT1StrikeAircraftNameForSide(const string &in side)
    {
        if (side == "armada") return "armkam";
        if (side == "cortex") return "corbw";
        if (side == "legion") return "legkam";
        return "";
    }

    /******************************************************************************

    AIR SCOUTS

    One scout early (MinAirScoutCount, first 5 minutes, while none is alive),
    then one every ScoutIntervalSeconds for the rest of the game, skipped while
    MaxAliveAirScouts are still flying. The factory.json weight for the scout
    planes is 0 past tier 0, so without this AIR stops scouting after the opener.

    Before the first T2 aircraft plant is finished, Armada and Cortex build their
    T1 scout plane (armpeep Blink / corfink Fink) at the T1 plant; after it, every
    side builds its T2 radar plane (armawac / corawac / legwhisper) at the T2
    plant. Legion's T1 plant has no scout plane - legfig is an anti_air fighter
    and would never scout - so Legion has no air scout before T2.

    ******************************************************************************/
    int g_airLastScoutFrame = -1;
    int g_airT2ProductionTurn = 0;   // T2 plant production decisions past constructors and scouts

    // Once a T2 aircraft plant is finished every side scouts with its T2 radar
    // plane from it; before that Armada and Cortex use their T1 scout plane.
    string Air_ScoutNameFor(const string &in side, bool fromT2Plant)
    {
        if (fromT2Plant) {
            if (side == "armada") return "armawac";
            if (side == "cortex") return "corawac";
            if (side == "legion") return "legwhisper";
            return "";
        }
        if (Factory::primaryT2AirPlant !is null) return "";
        if (side == "armada") return "armpeep";
        if (side == "cortex") return "corfink";
        return "";
    }

    IUnitTask@ Air_TryAirScout(const string &in side, const AIFloat3 &in pos, bool fromT2Plant)
    {
        const string name = Air_ScoutNameFor(side, fromT2Plant);
        if (name == "") return null;
        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (d is null || !d.IsAvailable(ai.frame)) return null;

        array<string> scouts = { "armpeep", "corfink", "armawac", "corawac", "legwhisper" };
        const int alive = UnitDefHelpers::SumUnitDefCounts(scouts);
        const int interval = Global::RoleSettings::Air::ScoutIntervalSeconds * SECOND;

        string why = "";
        if (g_airLastScoutFrame < 0) {
            if (alive < Global::RoleSettings::Air::MinAirScoutCount && ai.frame <= 5 * MINUTE) why = "opener";
        } else if (interval > 0 && ai.frame - g_airLastScoutFrame >= interval) {
            if (alive < Global::RoleSettings::Air::MaxAliveAirScouts) why = "every " + Global::RoleSettings::Air::ScoutIntervalSeconds + " s";
        }
        // The clock starts at the opener; if the opener window passes unused, at 5 minutes.
        if (why == "" && g_airLastScoutFrame < 0 && ai.frame > 5 * MINUTE) g_airLastScoutFrame = ai.frame - interval;
        if (why == "") return null;

        IUnitTask@ t = aiFactoryMgr.Enqueue(
            TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, d, pos, 64.f));
        if (t is null) return null;
        g_airLastScoutFrame = ai.frame;
        GenericHelpers::LogUtil("[AIR][Scout] " + name + " queued (" + why + ", alive=" + alive + ")", 2);
        return t;
    }

    IUnitTask@ Air_TryT1StrikeOpener(const CCircuitDef@ facDef, const string &in side, const AIFloat3 &in pos)
    {
        if (g_airGunshipOpenerDone) return null;
        if (facDef is null) return null;
        if (Economy::GetMinMetalIncomeLast10s() < Global::RoleSettings::Air::T1StrikeOpenerMinimumMetalIncome ||
            Economy::GetMinEnergyIncomeLast10s() < Global::RoleSettings::Air::T1StrikeOpenerMinimumEnergyIncome) {
            return null;
        }

        string gunshipName = GetT1StrikeAircraftNameForSide(side);
        if (gunshipName == "") return null;

        CCircuitDef@ gdef = ai.GetCircuitDef(gunshipName);
        if (gdef is null || !gdef.IsAvailable(ai.frame)) {
            return null;
        }

        const int targetCount = Global::RoleSettings::Air::T1StrikeOpenerSize;
        if (targetCount <= 0 || g_airStrikeOpenerQueuedCount >= targetCount) {
            g_airGunshipOpenerDone = true;
            return null;
        }

        IUnitTask@ task = aiFactoryMgr.Enqueue(
            TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, gdef, pos, 64.f)
        );
        if (task !is null) {
            g_airStrikeOpenerQueuedCount++;
            g_airGunshipOpenerDone = g_airStrikeOpenerQueuedCount >= targetCount;
            GenericHelpers::LogUtil(
                "[AIR] T1 strike opener enqueued " + g_airStrikeOpenerQueuedCount +
                "/" + targetCount + " unit=" + gunshipName,
                2
            );
        }
        return task;
    }

    IUnitTask@ Air_FactoryAiMakeTask(CCircuitUnit@ u) {
        const CCircuitDef@ facDef = (u is null ? null : u.circuitDef);
        if (facDef is null) {
            return aiFactoryMgr.DefaultMakeTask(u);
        }

        // Only customize for aircraft plants; otherwise fallback
        const string fname = facDef.GetName();
        if (!UnitHelpers::IsT1AircraftPlant(fname) && !UnitHelpers::IsT2AircraftPlant(fname)) {
            return aiFactoryMgr.DefaultMakeTask(u);
        }

        const AIFloat3 pos = u.GetPos(ai.frame);
        const string side = UnitHelpers::GetSideForUnitName(fname);
        // Use the sliding-window minimum metal income across all checks in this factory make task
        const float metalIncome = Economy::GetMinMetalIncomeLast10s();
        const float energyIncome = Economy::GetMinEnergyIncomeLast10s();

        // Determine plant tier first and only queue T1 builders from T1 plants.
        bool isT1Plant = UnitHelpers::IsT1AircraftPlant(fname);
        bool isT2Plant = (!isT1Plant && UnitHelpers::IsT2AircraftPlant(fname));

        if (isT1Plant) {
            const int maxT1Builders = Global::RoleSettings::Air::MinT1AirConstructorCount;
            array<string> allT1AirCons = UnitHelpers::GetAllT1AirConstructors();
            int t1BuildersTotal = UnitDefHelpers::SumUnitDefCounts(allT1AirCons);
            string t1BuilderName = (side == "armada" ? "armca" : side == "cortex" ? "corca" : side == "legion" ? "legca" : "armca");
            CCircuitDef@ t1BuilderDef = ai.GetCircuitDef(t1BuilderName);

            // Establish economy control before consuming the opening queue on
            // scouts or combat aircraft.
            if (maxT1Builders > 0 && t1BuildersTotal < 1
                && t1BuilderDef !is null && t1BuilderDef.IsAvailable(ai.frame)) {
                return aiFactoryMgr.Enqueue(
                    TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, t1BuilderDef, pos, 64.f)
                );
            }

            // Air scouts: one early, then one every ScoutIntervalSeconds all game.
            IUnitTask@ tScout = Air_TryAirScout(side, pos, false);
            if (tScout !is null) return tScout;

            // Barb4-style build power: MinT1AirConstructorCount outright, then one per
            // T1AirConstructorPerMetalIncome of income, up to MaxT1AirConstructorCount.
            // Past the first, only an energy stall holds them back.
            int desiredT1Builders = (maxT1Builders < 1 ? maxT1Builders : 1);
            if (Air_IsEconomyHealthy()) {
                const float perCtor = AiMax(Global::RoleSettings::Air::T1AirConstructorPerMetalIncome, 1.0f);
                desiredT1Builders = AiMax(maxT1Builders, int(metalIncome / perCtor));
                // no ceiling on TECH's economy: its turret block scales with the build power near the base
                if (!EcoRole::Enabled()) desiredT1Builders = AiMin(desiredT1Builders, Global::RoleSettings::Air::MaxT1AirConstructorCount);
            }
            if (t1BuildersTotal < desiredT1Builders
                && t1BuilderDef !is null && t1BuilderDef.IsAvailable(ai.frame)) {
                return aiFactoryMgr.Enqueue(
                    TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, t1BuilderDef, pos, 64.f)
                );
            }

            const bool combatProductionReady = Air_IsCombatProductionReady(metalIncome, energyIncome);
            if (combatProductionReady) {
                string fighterName = (side == "armada" ? "armfig" : side == "cortex" ? "corveng" : side == "legion" ? "legfig" : "armfig");
                int haveFighters = UnitDefHelpers::GetUnitDefCount(fighterName);
                if (haveFighters < Global::RoleSettings::Air::MinT1FighterCount) {
                    CCircuitDef@ fighterDef = ai.GetCircuitDef(fighterName);
                    if (fighterDef !is null && fighterDef.IsAvailable(ai.frame)) {
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, fighterDef, pos, 64.f)
                        );
                    }
                }

                IUnitTask@ gunshipOpener = Air_TryT1StrikeOpener(facDef, side, pos);
                if (gunshipOpener !is null) {
                    return gunshipOpener;
                }
            }

            if (combatProductionReady && Global::RoleSettings::Air::UseDynamicFactoryProduction) {
                GenericHelpers::LogUtil("[AIR][FactoryProduction] T1 plant '" + fname + "' side=" + side + " metalIncome=" + metalIncome, 4);
                IUnitTask@ dynTaskT1 = FactoryProduction::MakeTask(u);
                if (dynTaskT1 !is null) {
                    return dynTaskT1;
                }
                GenericHelpers::LogUtil("[AIR] Dynamic factory production returned null for '" + fname + "', using default", 3);
            }

        }

        // If T2 plant: ensure advanced constructor targets, then apply T2-specific strategy
        if (isT2Plant) {
            // Metal-starved: wave bombers and the constructor minimum only (see
            // METAL-STARVED MODE); everything else below is skipped.
            const bool starved = Air_IsMetalStarved();

            // 0) T2 radar-plane scouts (see Air_TryAirScout).
            if (!starved) {
                IUnitTask@ tT2Scout = Air_TryAirScout(side, pos, true);
                if (tT2Scout !is null) return tT2Scout;
            }

            // 1) Ensure at least MinT2AirConstructorCount advanced air constructors exist globally
            const int maxT2Cons = Global::RoleSettings::Air::MinT2AirConstructorCount;
            int minT2Cons = (maxT2Cons < 1 ? maxT2Cons : 1);
            if (Air_IsEconomyHealthy()
                && metalIncome >= Global::RoleSettings::Air::SecondT2AirConstructorMetalIncome
                && energyIncome >= Global::RoleSettings::Air::SecondT2AirConstructorEnergyIncome) {
                minT2Cons = maxT2Cons;
            }
            // The economy (see ECONOMY): the chain's constructors at once
            // (Air::ChainT2Constructors, TECH's T2 constructors: mohos, fusion,
            // advanced fusion), not staged on income - the mohos are what the
            // income waits on; on top of them TECH's plan wants one per
            // PlanAirConstructorPerMetal of income from PlanAirConstructorsFromMetal,
            // and the first two of those are dedicated (D-107)
            if (EcoRole::Enabled()) {
                if (minT2Cons < Global::RoleSettings::Air::ChainT2Constructors) minT2Cons = Global::RoleSettings::Air::ChainT2Constructors;
                minT2Cons += TechPlan::AirConstructorsWanted();
            }
            if (minT2Cons > 0) {
                array<string> t2AirCons; t2AirCons = { "armaca", "coraca", "legaca" };
                int haveT2Cons = UnitDefHelpers::SumUnitDefCounts(t2AirCons);
                if (haveT2Cons < minT2Cons) {
                    string advCtorName = (side == "armada" ? "armaca" : side == "cortex" ? "coraca" : side == "legion" ? "legaca" : "armaca");
                    CCircuitDef@ advCtor = ai.GetCircuitDef(advCtorName);
                    if (advCtor !is null && advCtor.IsAvailable(ai.frame)) {
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, advCtor, pos, 64.f)
                        );
                    }
                }
            }

            // 2) Heavy air strike (Legion/Cortex only), on one T2 production turn in
            // T2HeavyAirEveryNthTurn. Capping only the alive count did not stop it
            // monopolizing the plant: Tyrannus / Dragon die in fights, the count
            // rarely stays at the target, so every turn refilled heavies and the
            // wave bombers below (legphoenix / corhurc) were almost never reached.
            ++g_airT2ProductionTurn;
            const int heavyEvery = Global::RoleSettings::Air::T2HeavyAirEveryNthTurn;
            const bool heavyTurn = (heavyEvery <= 1) || (g_airT2ProductionTurn % heavyEvery == 0);
            {
                float mi = metalIncome;
                float incomeThresh = Global::RoleSettings::Air::T2HeavyAirIncomeThreshold;
                int batch = Global::RoleSettings::Air::T2HeavyAirBatchPerFactory;
                if (!starved && heavyTurn && batch > 0 && mi > incomeThresh && (side == "legion" || side == "cortex")) {
                    string heavyName = (side == "legion" ? "legfort" : "corcrwh");
                    CCircuitDef@ heavyDef = ai.GetCircuitDef(heavyName);
                    int haveHeavy = UnitDefHelpers::GetUnitDefCount(heavyName);
                    int heavyTarget = Global::RoleSettings::Air::T2HeavyAirTargetCount;
                    if (haveHeavy >= 0 && haveHeavy < heavyTarget && heavyDef !is null && heavyDef.IsAvailable(ai.frame)) {
                        int deficit = heavyTarget - haveHeavy;
                        int toQueue = (deficit < batch ? deficit : batch);
                        IUnitTask@ firstTask = null;
                        for (int i = 0; i < toQueue; ++i) {
                            IUnitTask@ t = aiFactoryMgr.Enqueue(
                                TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, heavyDef, pos, 64.f)
                            );
                            if (firstTask is null) @firstTask = t;
                        }
                        if (firstTask !is null) return firstTask;
                    }
                }
            }

            // 3) T2 bomber waves: fill the hold with the next wave's bombers and escorts.
            // Not gated on Air_IsCombatProductionReady: its only live condition at T2
            // is "no energy stall", and skipping here during a stall did not save
            // anything - the plant still built, from the heavy step or the native
            // legaap/coraap weights, which favour legfort / corcrwh late. AirWaves
            // keeps its own BomberWaveProductionMetalIncome gate.
            {
                IUnitTask@ waveTask = AirWaves::MakeProductionTask(u, side, pos);
                if (waveTask !is null) {
                    return waveTask;
                }
            }

            // No bomber due: wait rather than take the native fallback, which is
            // fighter-weighted at low income.
            if (starved) return Air_StarvedFactoryWait(fname);

            // Dynamic selection runs after bounded strategic quotas so it cannot
            // make constructor or heavy-air policy unreachable.
            if (Air_IsCombatProductionReady(metalIncome, energyIncome)
                && Global::RoleSettings::Air::UseDynamicFactoryProduction) {
                IUnitTask@ dynTaskT2 = FactoryProduction::MakeTask(u);
                if (dynTaskT2 !is null) {
                    return dynTaskT2;
                }
                GenericHelpers::LogUtil("[AIR] Dynamic factory production returned null for '" + fname + "', using default", 3);
            }
        }
        // If T2 plant but no specific action above, do NOT enqueue T1 construction aircraft here to avoid blocking advanced queues.

        // Economy snapshot for simple gating
        // float mi = Global::Economy::MetalIncome;
        // float ei = Global::Economy::EnergyIncome;

        // Simple air roster per side (T1)
    // string scout = (side == "armada" ? "armpeep" : side == "cortex" ? "corfink" : "legfig" );
        // string fighter = (side == "armada" ? "armfig" : side == "cortex" ? "corveng" : "legfig" );
        // string bomber = (side == "armada" ? "armthund" : side == "cortex" ? "corhurc" : "legbmb" );
        // // Prefer fighters early, sprinkle scouts and bombers

        // // Maintain a small scout presence
        // int scouts = UnitDefHelpers::SumUnitDefCounts({ scout });
        // if (scouts < 2 && ei > 150.0f) {
        //     CCircuitDef@ d = ai.GetCircuitDef(scout);
        //     if (d !is null && d.IsAvailable(ai.frame))
        //         return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, d, pos, 64.f));
        // }

        // // Fighters: mainline AA/air control
        // int fighters = UnitDefHelpers::SumUnitDefCounts({ fighter });
        // if (fighters < 8 && mi > 8.0f && ei > 220.0f) {
        //     CCircuitDef@ d = ai.GetCircuitDef(fighter);
        //     if (d !is null && d.IsAvailable(ai.frame))
        //         return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, d, pos, 64.f));
        // }

        // // Bombers: gated heavier by eco
        // int bombers = UnitDefHelpers::SumUnitDefCounts({ bomber });
        // if (bombers < 4 && mi > 10.0f && ei > 300.0f) {
        //     CCircuitDef@ d = ai.GetCircuitDef(bomber);
        //     if (d !is null && d.IsAvailable(ai.frame))
        //         return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, d, pos, 64.f));
        // }

        // Fallback to default when no specific recruit fired
        return aiFactoryMgr.DefaultMakeTask(u);
    }

    string Air_SelectFactoryHandler(const AIFloat3& in pos, bool isStart, bool isReset) {
        if(isStart) {
            if(Global::Map::NearestMapStartPosition !is null) {
                return FactoryHelpers::SelectStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
            } else {
                GenericHelpers::LogUtil("[Air_SelectFactoryHandler] nearestMapPosition is null", 2);
                return FactoryHelpers::GetFallbackStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
            }
        }
   
        return "";
    }

    // Local default implementations (ready to customize per-role)
    bool Air_AiIsSwitchTime(int lastSwitchFrame) {
        int interval = (30 * SECOND);
        return (lastSwitchFrame + interval) <= ai.frame;
    }
    bool Air_AiIsSwitchAllowed(const CCircuitDef@ facDef, float armyCost, int factoryCount, float metalCurrent, bool &out assistRequired) {
        const bool isOK = (armyCost > 1.2f * facDef.costM * float(factoryCount)) || (metalCurrent > facDef.costM);
        // Never ask for factory assist. The flag feeds only native
        // CheckMobileAssistRequired, the first step of every default builder task:
        // it guards the recruiting air plant with any constructor within 600, which
        // is where every new air constructor spawns. AIR wants them on economy.
        assistRequired = false;
        return isOK;
    }
    int Air_MakeSwitchInterval() {
        return AiRandom(Global::RoleSettings::Air::MinAiSwitchTime, Global::RoleSettings::Air::MaxAiSwitchTime) * SECOND;
    }
    
    
    /******************************************************************************

    MILITARY HOOKS

    ******************************************************************************/
    
    // T2 bombers and T2 fighters belong to the wave system (manager/air_waves.as):
    // held at base, released together, escorted. Every other air unit, including
    // all T1 bombers, keeps the native default task (solo bomb runs as built).
    IUnitTask@ Air_MilitaryAiMakeTask(CCircuitUnit@ u)
    {
        IUnitTask@ waveTask = AirWaves::MakeTask(u);
        if (waveTask !is null) return waveTask;
        // A wave fighter waiting for its group gets no task - not the native default
        // either - and stays idle until AirWaves::Update parks it (fighter groups).
        if (AirWaves::IsParking(u)) return null;
        return aiMilitaryMgr.DefaultMakeTask(u);
    }

    void Air_MilitaryAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        AirWaves::OnUnitRemoved(unit);
    }

    void Air_MilitaryAiTaskRemoved(IUnitTask@ task, bool done)
    {
        AirWaves::OnTaskRemoved(task);
    }

    /******************************************************************************

    BUILDER HOOKS

    ******************************************************************************/ 

    /******************************************************************************

    ADVANCED AIRCRAFT PLANT CAP

    The second advanced aircraft plant waits for SecondT2AircraftPlantMetalIncome
    native average metal income, the third for ThirdT2AircraftPlantMetalIncome,
    and there is never a fourth (MaxT2AircraftPlants). Enforced as the def cap on
    armaap / coraap / legaap, so native UpdateFactoryTasks (which skips an
    unavailable factory) obeys it as well as the air.plants row
    (Air_T2Plants). One-way: a later dip does not lower the
    cap under a plant that is already on the map or in construction.

    ******************************************************************************/
    int g_airT2PlantsAllowed = 1;
    dictionary g_airT2PlantCapOrig;   // def name -> config cap (behaviour "limit")

    int _Air_StagedT2Plants(float avgMetalIncome)
    {
        int n = 1;
        if (avgMetalIncome >= Global::RoleSettings::Air::SecondT2AircraftPlantMetalIncome) ++n;
        if (avgMetalIncome >= Global::RoleSettings::Air::ThirdT2AircraftPlantMetalIncome) ++n;
        return AiMin(n, Global::RoleSettings::Air::MaxT2AircraftPlants);
    }

    void _Air_ApplyT2PlantCap()
    {
        array<string> plants = UnitHelpers::GetAllT2AircraftPlants();
        for (uint i = 0; i < plants.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(plants[i]);
            if (d is null) continue;
            if (!g_airT2PlantCapOrig.exists(plants[i])) g_airT2PlantCapOrig.set(plants[i], d.maxThisUnit);
            int orig = 0;
            g_airT2PlantCapOrig.get(plants[i], orig);
            d.maxThisUnit = AiMin(orig, g_airT2PlantsAllowed);
        }
    }

    void Air_InitT2PlantCap()
    {
        g_airT2PlantCapOrig.deleteAll();
        g_airT2PlantsAllowed = AiMax(1, _Air_StagedT2Plants(aiEconomyMgr.metal.income));
        _Air_ApplyT2PlantCap();
        GenericHelpers::LogUtil("[AIR][T2Plant] advanced aircraft plants capped at " + g_airT2PlantsAllowed
            + " (2nd at " + int(Global::RoleSettings::Air::SecondT2AircraftPlantMetalIncome)
            + ", 3rd at " + int(Global::RoleSettings::Air::ThirdT2AircraftPlantMetalIncome)
            + " avg metal income, max " + Global::RoleSettings::Air::MaxT2AircraftPlants + ")", 2);
    }

    void Air_UpdateT2PlantCap()
    {
        const float mi = aiEconomyMgr.metal.income;
        const int staged = _Air_StagedT2Plants(mi);
        if (staged <= g_airT2PlantsAllowed) return;
        g_airT2PlantsAllowed = staged;
        _Air_ApplyT2PlantCap();
        GenericHelpers::LogUtil("[AIR][T2Plant] avg metal income " + int(mi) + ": advanced aircraft plant cap raised to "
            + g_airT2PlantsAllowed, 1);
    }

    /******************************************************************************

    BUILDER DISPATCH

    With the experimental economy on (see ECONOMY) every builder - commander,
    T1 and T2 air constructors, turrets - takes its task from TECH's rule table;
    AIR's own work is the table's air.plants row (Air_T2Plants). The
    table never returns null. Off, native's default task.

    ******************************************************************************/
    IUnitTask@ Air_BuilderAiMakeTask(CCircuitUnit@ builder) {
        GenericHelpers::LogUtil("[Air_BuilderAiMakeTask] called for builder", 4);
        if (builder is null) return null;
        if (EcoRole::Enabled()) return TechBuild::MakeTask(builder);
        return Builder::MakeDefaultTaskWithLog(builder.id, "AIR");
    }

    void Air_BuilderAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		//LogUtil("BUILDER::AiUnitAdded:" + unit.circuitDef, 2);
		const CCircuitDef@ cdef = unit.circuitDef;
		if (usage != Unit::UseAs::BUILDER || cdef.IsRoleAny(Unit::Role::COMM.mask))
			return;

        string uname = cdef.GetName();
        bool isT1AirConstructor = (uname == "armca" || uname == "corca" || uname == "legca");
        bool isT2AirConstructor = (uname == "armaca" || uname == "coraca" || uname == "legaca");

        if (isT1AirConstructor && unit !is Builder::primaryT1AirConstructor) {
            unit.DelAttribute(Unit::Attr::BASE.type);
        }
        else if (isT2AirConstructor) {
            // Advanced air constructors must be able to take expansion and
            // advanced-economy tasks instead of all becoming base energizers.
            unit.DelAttribute(Unit::Attr::BASE.type);
        }

	}

    void Air_BuilderAiTaskAdded(IUnitTask@ task) {
        GenericHelpers::LogUtil("[Air_BuilderAiTaskAdded] called for task", 3);
    }

    void Air_BuilderAiTaskRemoved(IUnitTask@ task, bool done) {
    }

    void Air_BuilderAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
    {
    }

    // A retiring factory's bookkeeping (manager/lifecycle.as). AIR retires none,
    // but the experimental system reads Lifecycle; a gone factory is forgotten.
    void Air_FactoryAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        Lifecycle::Forget(unit);
    }

    /******************************************************************************

    BUILDER LOGIC

    ******************************************************************************/

    /**************************************************************************
     T2 AIRCRAFT PLANTS (the air.plants row)

     A T2 plant the layout has no footprint for goes on a ring
     LateExpansionRadius out from the start, one slot per plant, so the base
     grows outward instead of packing the core. Nanos are TECH's: the chain's
     nano step and the power.t1 / power.turret / turret.build rows place them
     in the layout's turret box, flush against the plants.
     **************************************************************************/
    AIFloat3 Air_ClampToMap(const AIFloat3 &in p, float margin)
    {
        const float w = float(aiTerrainMgr.GetTerrainWidth());
        const float h = float(aiTerrainMgr.GetTerrainHeight());
        float x = p.x, z = p.z;
        if (x < margin) x = margin;
        if (x > w - margin) x = w - margin;
        if (z < margin) z = margin;
        if (z > h - margin) z = h - margin;
        return AIFloat3(x, p.y, z);
    }

    // Slot k of n on a ring around the start position. Slot 0 faces the map
    // centre, so the first expansion leans toward the fight rather than the
    // map edge; the rest rotate evenly from there.
    AIFloat3 Air_RingAnchor(int k)
    {
        const int n = (Global::RoleSettings::Air::LateRingSlots < 1) ? 1 : Global::RoleSettings::Air::LateRingSlots;
        const AIFloat3 c = Global::Map::StartPos;
        const float cx = float(aiTerrainMgr.GetTerrainWidth()) * 0.5f;
        const float cz = float(aiTerrainMgr.GetTerrainHeight()) * 0.5f;
        float ax = cx - c.x, az = cz - c.z;
        const float len = sqrt(ax * ax + az * az);
        if (len < 1.0f) { ax = 1.0f; az = 0.0f; } else { ax /= len; az /= len; }
        const float step = 6.2831853f / float(n);
        const float a = float(k % n) * step;
        const float ca = cos(a), sa = sin(a);
        const float dx = ax * ca - az * sa;
        const float dz = ax * sa + az * ca;
        const float r = Global::RoleSettings::Air::LateExpansionRadius;
        return Air_ClampToMap(AIFloat3(c.x + dx * r, c.y, c.z + dz * r), Global::RoleSettings::Air::LateExpansionShake);
    }

    // The air.plants row of TECH's rule table (roles/tech_rules.as). The first
    // T2 aircraft plant is the economy's advanced lab (the chain's alab step
    // and the lab.t2 row, placed by the layout); after it, another T2 aircraft
    // plant whenever the ADVANCED AIRCRAFT PLANT CAP stage allows one more (2nd
    // at SecondT2AircraftPlantMetalIncome, 3rd at ThirdT2AircraftPlantMetalIncome)
    // and the bank holds RequiredMetalCurrentForT2AircraftPlant: flush against
    // the turrets (Layout::OrderFactory), else on the ring round the start; not
    // while metal-starved. Null when none is due: the table goes on to the chain
    // and the economy.
    IUnitTask@ Air_T2Plants(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null) return null;
        const string side = Global::AISettings::Side;
        const int t2Plants = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2AircraftPlants());
        if (t2Plants < 1 || t2Plants >= g_airT2PlantsAllowed || Factory::IsT2AirPlantBuildQueued()
            || Air_IsMetalStarved() || !Builder::IsT2FactoryOffCooldown()
            || aiEconomyMgr.metal.current < Global::RoleSettings::Air::RequiredMetalCurrentForT2AircraftPlant) return null;
        CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(side));
        if (d is null || !d.IsAvailable(ai.frame) || !u.circuitDef.CanBuild(d)) return null;
        IUnitTask@ t = Layout::OrderFactory(d, 600 * SECOND);
        string where = "flush against the turrets";
        if (t !is null) {
            Builder::MarkT2FactoryEnqueued();
        } else {
            @t = Builder::EnqueueT2AirPlant(side, Air_RingAnchor(t2Plants - 1), Global::RoleSettings::Air::LateExpansionShake, 600 * SECOND);
            where = "on ring slot " + (t2Plants - 1);
        }
        if (t !is null) {
            GenericHelpers::LogUtil("[AIR][Plants] T2 aircraft plant " + (t2Plants + 1) + "/" + g_airT2PlantsAllowed
                + " " + where + " (avg metal income " + int(aiEconomyMgr.metal.income) + ")", 1);
        }
        return t;
    }

    /******************************************************************************

    ROLE CONFIGURATION

    ******************************************************************************/
   

    bool Air_RoleMatch(AiRole preferredMapRole, const string &in side, const AIFloat3& in pos, const string &in defaultStartFactory) {
        bool match = false;

        if (preferredMapRole == AiRole::AIR) match = true;
       
        if (match) { 
            GenericHelpers::LogUtil("[RoleMatch] AIR", 2); 
        }

        return match;
    }

    /**************************************************************************
     PORC CHAIN

     Position in the chain is a budget threshold (doc/porc-chain.md), and the
     default land order never reaches flak at all - armflak is not in the
     land sequence, and Mercury sits at position 12 behind ~14k of metal. For
     an air role that is backwards: its value to the team is air denial.

     This order leads with flak, puts long-range AA where a well-funded
     cluster actually reaches, and repeats both down the chain; it drops the
     duplicate beamers, the Overwatch and three of the six Rattlesnakes to
     pay for it. Juno stays at position 6, the gates, the LRPCs, the EMP
     launchers and Ragnarok keep their counts. Water is the default.
     **************************************************************************/
    dictionary AirLandChain = {
        {"armada", array<string> = {
            "armllt", "armrl", "armflak", "armbeamer", "armcir", "armflak", "armjuno", "armmercury",
            "armamd", "armamb", "armflak", "armmercury", "armgate", "armanni", "armbrtha", "armflak",
            "armemp", "armmercury", "armnanotc", "armnanotc", "armbrtha", "armgate", "armbrtha",
            "armmercury", "armgate", "armemp", "armamb", "armvulc", "armamb", "armamb"}},
        {"cortex", array<string> = {
            "corllt", "corrl", "corflak", "corhllt", "cormadsam", "corflak", "corjuno", "corscreamer",
            "corfmd", "cortoast", "corflak", "corscreamer", "corgate", "cordoom", "corint", "corflak",
            "cortron", "corscreamer", "cornanotc", "cornanotc", "corint", "corgate", "corint",
            "corscreamer", "corgate", "cortron", "cortoast", "corbuzz", "cortoast", "cortoast"}},
        {"legion", array<string> = {
            "leglht", "legrl", "legflak", "leghive", "leglupara", "legflak", "legjuno", "leglraa",
            "legabm", "legbastion", "legflak", "leglraa", "legdeflector", "legcluster", "leglrpc", "legflak",
            "leglraa", "legnanotc", "legnanotc", "leglrpc", "legdeflector", "leglrpc",   // no Perdition: no working fire DLL
            "leglraa", "legdeflector", "legbastion", "legstarfall", "legbastion", "legbastion"}}
    };

    void Air_PorcChain(const string &in side)
    {
        array<string>@ land = null;
        if (AirLandChain.exists(side)) {
            AirLandChain.get(side, @land);
        }
        if (land is null || land.length() == 0) {
            GenericHelpers::LogUtil("[Porc] AIR: no chain for side " + side + "; keeping the default", 2);
            PorcHelpers::ApplyDefaultChains(side);
            return;
        }
        // Content tiers (Extra Units, scavengers) go on the end, as for every role.
        if (Global::ModOptions::ExperimentalExtraUnits) {
            PorcHelpers::AppendTier(@land, @PorcHelpers::ExtraUnitsLand, side, "experimentalextraunits");
        }
        if (Global::ModOptions::ScavUnitsForPlayers) {
            PorcHelpers::AppendTier(@land, @PorcHelpers::ScavUnitsLand, side, "scavunitsforplayers");
        }
        aiMilitaryMgr.SetPorcChain(side, false, land);
        aiMilitaryMgr.SetPorcChain(side, true, PorcHelpers::DefaultChain(side, true));
        GenericHelpers::LogUtil("[Porc] AIR: " + side + " air-denial chain set (" + land.length() + " entries)", 1);
    }

    void Register() {
        if (RoleConfigs::Get(AiRole::AIR) !is null) return;
        RoleConfig@ cfg = RoleConfig(AiRole::AIR, cast<MainUpdateDelegate@>(@Air_MainUpdate));

        @cfg.InitHandler = cast<InitDelegate@>(@Air_Init);

        @cfg.AiIsSwitchTimeHandler = cast<AiIsSwitchTimeDelegate@>(@Air_AiIsSwitchTime);
        @cfg.AiIsSwitchAllowedHandler = cast<AiIsSwitchAllowedDelegate@>(@Air_AiIsSwitchAllowed);
        @cfg.MakeSwitchIntervalHandler = cast<MakeSwitchIntervalDelegate@>(@Air_MakeSwitchInterval);

        @cfg.BuilderAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Air_BuilderAiMakeTask);
        @cfg.FactoryAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Air_FactoryAiMakeTask);
        
        @cfg.BuilderAiUnitAdded = cast<AiUnitAddedDelegate@>(@Air_BuilderAiUnitAdded);
        @cfg.BuilderAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Air_BuilderAiUnitRemoved);

        @cfg.BuilderAiTaskAddedHandler = cast<AiTaskAddedDelegate@>(@Air_BuilderAiTaskAdded);
        @cfg.BuilderAiTaskRemovedHandler = cast<AiTaskRemovedDelegate@>(@Air_BuilderAiTaskRemoved);

        @cfg.SelectFactoryHandler = cast<SelectFactoryDelegate@>(@Air_SelectFactoryHandler);
        @cfg.FactoryAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Air_FactoryAiUnitRemoved);
        @cfg.EconomyUpdateHandler = cast<EconomyUpdateDelegate@>(@Air_EconomyUpdate);
        // The economy's planned base (see ECONOMY): the factory pair and turret box at setup
        @cfg.LayoutPlanHandler = cast<LayoutPlanDelegate@>(@Air_LayoutPlan);

        @cfg.RoleMatchHandler = cast<RoleMatchDelegate@>(@Air_RoleMatch);

        @cfg.MilitaryAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Air_MilitaryAiMakeTask);
        @cfg.MilitaryAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Air_MilitaryAiUnitRemoved);
        @cfg.MilitaryAiTaskRemovedHandler = cast<AiTaskRemovedDelegate@>(@Air_MilitaryAiTaskRemoved);

        @cfg.PorcChainHandler = cast<PorcChainDelegate@>(@Air_PorcChain);
        // Porc: preventive only while metal-starved, the shared policy otherwise.
        @cfg.AiMakeDefenceHandler = cast<AiMakeDefence@>(@Air_AiMakeDefence);

        RoleConfigs::Register(cfg);
    }
}
