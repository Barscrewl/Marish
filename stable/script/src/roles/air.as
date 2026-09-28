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
// Post-T2 reactor ladder, shared with FRONT
#include "../manager/reactor_ladder.as"

namespace RoleAir {
    IUnitTask@ g_airStrategicFocusTask = null;
    int g_airStrategicFocusLeaderId = -1;
    bool g_airBuildFocusReleased = false;
    bool g_airGunshipOpenerDone = false;
    int g_airStrikeOpenerQueuedCount = 0;
    IUnitTask@ g_airCommanderWindTask = null;

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

    string Air_GetWindNameForSide(const string &in side)
    {
        if (side == "armada") return "armwin";
        if (side == "cortex") return "corwin";
        if (side == "legion") return "legwin";
        return "";
    }

    bool Air_ShouldPreferWind(const string &in side)
    {
        const string windName = Air_GetWindNameForSide(side);
        CCircuitDef@ windDef = (windName == "" ? null : ai.GetCircuitDef(windName));
        if (windDef is null || !windDef.IsAvailable(ai.frame)) return false;

        const float expectedWindEnergy = aiEconomyMgr.GetEnergyMake(windDef);
        const int windCount = windDef.count;
        return expectedWindEnergy > Global::RoleSettings::Air::GoodWindMinimumEnergy
            && windCount >= 0
            && windCount < Global::RoleSettings::Air::CommanderWindTargetCount
            && Economy::GetMinEnergyIncomeLast10s() < Global::RoleSettings::Air::CommanderWindEnergyIncomeTarget;
    }

    bool Air_HasCommanderWindOpportunity(const string &in side)
    {
        return Builder::commander !is null
            && !aiEconomyMgr.isEnergyFull
            && aiEconomyMgr.metal.current >= Global::RoleSettings::Air::CommanderWindMinimumMetalCurrent
            && Air_ShouldPreferWind(side);
    }

    IUnitTask@ Air_TryCommanderWind(CCircuitUnit@ commander)
    {
        if (commander is null || commander.circuitDef is null) return null;
        if (g_airCommanderWindTask !is null) {
            if (!Air_IsRetiredBuild(g_airCommanderWindTask)) return g_airCommanderWindTask;
            // Winds retired (ECO RETIREMENT); the cap refuses a new one below. Aborted on
            // the next update: this runs inside AiMakeTask and the task is likely the
            // commander's current one (Builder DEFERRED ABORT).
            Builder::AbortLater(g_airCommanderWindTask);
            @g_airCommanderWindTask = null;
        }

        const string side = UnitHelpers::GetSideForUnitName(commander.circuitDef.GetName());
        if (!Air_HasCommanderWindOpportunity(side)) return null;

        const string windName = Air_GetWindNameForSide(side);
        CCircuitDef@ windDef = ai.GetCircuitDef(windName);
        if (windDef is null) return null;

        IUnitTask@ task = aiBuilderMgr.Enqueue(
            TaskB::Common(
                Task::BuildType::ENERGY,
                Task::Priority::NORMAL,
                windDef,
                commander.GetPos(ai.frame),
                SQUARE_SIZE * 32,
                true,
                30 * SECOND
            )
        );
        if (task !is null) {
            @g_airCommanderWindTask = @task;
            GenericHelpers::LogUtil(
                "[AIR] Commander enqueued wind generator '" + windName +
                "' expectedEnergy=" + aiEconomyMgr.GetEnergyMake(windDef),
                2
            );
        }
        return task;
    }

    // Advanced solar timing and energy gate, shared by the primary's ladder and the eco crew.
    bool Air_IsAdvancedSolarReady(const string &in side, float mi, float ei)
    {
        const bool timingReady =
            ai.frame >= Global::RoleSettings::Air::AdvancedSolarEarliestSeconds * SECOND
            && mi >= Global::RoleSettings::Air::AdvancedSolarMinimumMetalIncome
            && aiEconomyMgr.metal.current >= Global::RoleSettings::Air::AdvancedSolarMinimumMetalCurrent
            && !aiEconomyMgr.isEnergyFull
            && !Air_HasCommanderWindOpportunity(side);
        if (!timingReady) return false;
        array<string> t2AirCons = { "armaca", "coraca", "legaca" };
        return EconomyHelpers::ShouldBuildT1AdvancedSolar(
            /*energyIncome*/ ei,
            /*metalIncome*/ mi,
            /*energyIncomeMinimumThreshold*/ Global::RoleSettings::Air::AdvancedSolarEnergyIncomeMinimum,
            /*energyIncomeMaximumThreshold*/ Global::RoleSettings::Air::AdvancedSolarEnergyIncomeMaximum,
            /*t2ConstructorCount*/ UnitDefHelpers::SumUnitDefCounts(t2AirCons),
            /*t2FactoryCount*/ UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2AircraftPlants()),
            /*isT2FactoryQueued*/ Factory::IsT2AirPlantBuildQueued(),
            /*enableT2ProgressGate*/ true,
            /*metalIncomeFallbackMinimum*/ 6.0f);
    }

    /******************************************************************************

    ECO CREW

    Every T1 air constructor except the primary tries this before it guards the
    primary's strategic focus (factory projects) or takes the default task; the
    primary runs it after its own ladder. Order: converter while energy piles
    up, wind on a good-wind map, advanced solar once its gate opens, solar below
    SolarEnergyIncomeMinimum. Wind, advanced solar and solar are enqueued here
    with a per-type crew cooldown rather than through Builder::EnqueueT1Solar /
    EnqueueT1AdvancedSolar, whose shared cooldowns answer a second builder with
    a 200 s guard on the first instead of a building of its own.

    ******************************************************************************/
    dictionary g_airEcoCrewLastFrame;   // def name -> frame of the last crew enqueue

    bool Air_IsEcoDef(const CCircuitDef@ d, const string &in side)
    {
        if (d is null) return false;
        const string n = d.GetName();
        return n == UnitHelpers::GetSolarNameForSide(side)
            || n == UnitHelpers::GetAdvSolarNameForSide(side)
            || n == UnitHelpers::GetEnergyConverterNameForSide(side)
            || n == Air_GetWindNameForSide(side);
    }

    IUnitTask@ Air_EnqueueEcoEnergy(CCircuitUnit@ u, const string &in defName, const string &in why)
    {
        if (defName == "") return null;
        int last = -1000000;
        if (g_airEcoCrewLastFrame.exists(defName)) g_airEcoCrewLastFrame.get(defName, last);
        if (ai.frame - last < Global::RoleSettings::Air::EcoCrewCooldownSeconds * SECOND) return null;
        CCircuitDef@ d = ai.GetCircuitDef(defName);
        if (d is null || !d.IsAvailable(ai.frame)) return null;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::ENERGY, Task::Priority::NORMAL,
            d, u.GetPos(ai.frame), SQUARE_SIZE * 32, true, 30 * SECOND));
        if (t is null) return null;
        g_airEcoCrewLastFrame.set(defName, ai.frame);
        GenericHelpers::LogUtil("[AIR][Eco] " + u.circuitDef.GetName() + " id=" + u.id + " -> " + defName
            + " (" + why + ")", 2);
        return t;
    }

    IUnitTask@ Air_TryEcoBuild(CCircuitUnit@ u)
    {
        if (!Global::RoleSettings::Air::EcoCrewEnabled || u is null || u.circuitDef is null) return null;
        const string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // Keep an eco build in progress. Native re-evaluation probes this function
        // too; returning the current task stops each probe from queueing another.
        // A build of a retired def is not kept (ECO RETIREMENT).
        IBuilderTask@ current = cast<IBuilderTask>(u.task);
        if (current !is null && Air_IsEcoDef(current.buildDef, side) && !Air_IsRetiredDef(current.buildDef)) return u.task;

        const float mi = Economy::GetMinMetalIncomeLast10s();
        const float ei = Economy::GetMinEnergyIncomeLast10s();

        if (EconomyHelpers::ShouldBuildT1EnergyConverter(
            mi, ei, aiEconomyMgr.energy.current, aiEconomyMgr.energy.storage,
            Global::RoleSettings::Air::BuildT1ConvertersUntilMetalIncome,
            Global::RoleSettings::Air::BuildT1ConvertersMinimumEnergyIncome,
            Global::RoleSettings::Air::BuildT1ConvertersMinimumEnergyCurrentPercent))
        {
            IUnitTask@ tConv = Builder::EnqueueT1EnergyConverter(side, u.GetPos(ai.frame), SQUARE_SIZE * 32, SECOND * 30);
            if (tConv !is null) {
                GenericHelpers::LogUtil("[AIR][Eco] " + u.circuitDef.GetName() + " id=" + u.id + " -> converter", 2);
                return tConv;
            }
        }

        // Converters cost energy; everything below costs metal the factories also need.
        if (aiEconomyMgr.metal.current < Global::RoleSettings::Air::EcoCrewMinMetalCurrent) return null;

        IUnitTask@ t = null;
        const string windName = Air_GetWindNameForSide(side);
        CCircuitDef@ windDef = (windName == "") ? null : ai.GetCircuitDef(windName);
        if (windDef !is null
            && aiEconomyMgr.GetEnergyMake(windDef) > Global::RoleSettings::Air::GoodWindMinimumEnergy
            && windDef.count < Global::RoleSettings::Air::EcoCrewWindMaxCount
            && ei < Global::RoleSettings::Air::EcoCrewWindEnergyIncomeTarget)
        {
            @t = Air_EnqueueEcoEnergy(u, windName, "good wind");
            if (t !is null) return t;
        }

        if (Air_IsAdvancedSolarReady(side, mi, ei)) {
            @t = Air_EnqueueEcoEnergy(u, UnitHelpers::GetAdvSolarNameForSide(side), "advanced solar gate open");
            if (t !is null) return t;
        }

        if (EconomyHelpers::ShouldBuildT1Solar(ei, Global::RoleSettings::Air::SolarEnergyIncomeMinimum)) {
            @t = Air_EnqueueEcoEnergy(u, UnitHelpers::GetSolarNameForSide(side), "energy income " + int(ei));
            if (t !is null) return t;
        }
        return null;
    }

    bool Air_IsBuildFocusActive()
    {
        if (g_airBuildFocusReleased) return false;

        const bool deadlinePassed =
            ai.frame > Global::RoleSettings::Air::BuildFocusDeadlineSeconds * SECOND;
        const bool incomeEstablished =
            Economy::GetMinMetalIncomeLast10s() >= Global::RoleSettings::Air::BuildFocusMetalIncome
            && Economy::GetMinEnergyIncomeLast10s() >= Global::RoleSettings::Air::BuildFocusEnergyIncome;
        if (deadlinePassed || (Air_IsEconomyHealthy() && incomeEstablished)) {
            g_airBuildFocusReleased = true;
            GenericHelpers::LogUtil("[AIR] Early build-power focus released", 2);
            return false;
        }
        return true;
    }

    bool Air_IsConstructionTask(IUnitTask@ task)
    {
        IBuilderTask@ builderTask = cast<IBuilderTask>(task);
        if (builderTask is null) return false;
        return Builder::_IsConstructionBuildType(Task::BuildType(builderTask.GetBuildType()));
    }

    IUnitTask@ Air_SetStrategicFocus(CCircuitUnit@ leader, IUnitTask@ task)
    {
        if (leader !is null && Air_IsConstructionTask(task)) {
            @g_airStrategicFocusTask = @task;
            g_airStrategicFocusLeaderId = leader.id;
        }
        return task;
    }

    bool Air_HasTrackedTask(CCircuitUnit@ builder)
    {
        Builder::BuilderTaskTrack@ track = Builder::GetTrackForBuilder(builder);
        return track !is null && track.task !is null;
    }

    CCircuitUnit@ Air_GetAssignedT1Leader(CCircuitUnit@ builder)
    {
        if (builder is null) return null;
        const string key = "" + builder.id;
        CCircuitUnit@ ignored = null;
        if (Builder::primaryT1AirConstructor !is null
            && Builder::primaryT1AirConstructorGuards.get(key, @ignored)) {
            return Builder::primaryT1AirConstructor;
        }
        @ignored = null;
        if (Builder::secondaryT1AirConstructor !is null
            && Builder::secondaryT1AirConstructorGuards.get(key, @ignored)) {
            return Builder::secondaryT1AirConstructor;
        }
        return null;
    }

    IUnitTask@ Air_AssignFocusedFollower(CCircuitUnit@ builder)
    {
        IUnitTask@ assistTask = null;
        CCircuitUnit@ primary = Builder::primaryT1AirConstructor;
        if (g_airStrategicFocusTask !is null && primary !is null
            && primary.id == g_airStrategicFocusLeaderId) {
            @assistTask = GuardHelpers::AssignWorkerGuard(
                builder,
                primary,
                Task::Priority::HIGH,
                true,
                Global::RoleSettings::Air::BuildFocusAssistTimeoutSeconds * SECOND
            );
            if (assistTask !is null) return assistTask;
        }

        CCircuitUnit@ secondary = Builder::secondaryT1AirConstructor;
        if (secondary !is null && Air_HasTrackedTask(secondary)) {
            @assistTask = GuardHelpers::AssignWorkerGuard(
                builder,
                secondary,
                Task::Priority::HIGH,
                true,
                Global::RoleSettings::Air::BuildFocusAssistTimeoutSeconds * SECOND
            );
            if (assistTask !is null) return assistTask;
        }

        CCircuitUnit@ assignedLeader = Air_GetAssignedT1Leader(builder);
        if (assignedLeader !is null && Air_HasTrackedTask(assignedLeader)) {
            @assistTask = GuardHelpers::AssignWorkerGuard(
                builder,
                assignedLeader,
                Task::Priority::HIGH,
                true,
                Global::RoleSettings::Air::BuildFocusAssistTimeoutSeconds * SECOND
            );
            if (assistTask !is null) return assistTask;
        }

        return aiBuilderMgr.Enqueue(
            TaskB::Wait(Global::RoleSettings::Air::BuildFocusIdleWaitSeconds * SECOND)
        );
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
        @g_airStrategicFocusTask = null;
        g_airStrategicFocusLeaderId = -1;
        g_airBuildFocusReleased = false;
        g_airGunshipOpenerDone = false;
        g_airStrikeOpenerQueuedCount = 0;
        @g_airCommanderWindTask = null;
        g_airEcoCrewLastFrame.deleteAll();
        g_airLastScoutFrame = -1;
        g_airT2ProductionTurn = 0;
        g_airLateNanoTasks.resize(0);
        g_airLateNanoMisses = 0;

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
        ReactorLadder::InitAfusGate(Air_LadderParams());
        AirWaves::Init();

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
    of metal storage, until back above EcoPriorityExitPercent, metal goes to
    wave bombers, fusions and AFUS only. See Global::RoleSettings::Air
    METAL-STARVED MODE for exactly what is held back.

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
                + (g_airMetalStarved ? ": starved - metal to bombers, fusions and AFUS only"
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
        Air_UpdateEcoRetire();
        // Periodically update dynamic military quotas once the configured delay has passed
        if (ai.frame >= AIR_DYNAMIC_QUOTA_DELAY_FRAMES) {
            Air_UpdateDynamicMilitaryQuotas();
        }
        Air_UpdateBastionGate();
        Air_UpdateT1StrikeCap();
        Air_UpdateT2PlantCap();
        ReactorLadder::UpdateAfusGate(Air_LadderParams());
        // T2 bomber waves: launch when the hold reaches the target, size the next wave
        AirWaves::Update();
        //LogUtil("Air update logic executed", 5);
    }

    /******************************************************************************

    ECONOMY HOOKS

    ******************************************************************************/

    void Air_EconomyUpdate() {
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
                desiredT1Builders = AiMin(desiredT1Builders, Global::RoleSettings::Air::MaxT1AirConstructorCount);
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
    unavailable factory) obeys it as well as the primary constructor's own
    ShouldBuildT2AircraftPlant check. One-way: a later dip does not lower the
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

    REACTOR TRACKING

    Main::AiUnitFinished / AiUnitDestroyed forward here for every team unit, in
    every role. Finished fusions, advanced fusions and advanced converters are
    kept by ReactorLadder (fusionIds / afusIds / advConvIds) for whichever role
    runs the ladder; the retirement classes below are kept here. Only ids are
    kept (CCircuitUnit is asOBJ_NOCOUNT); dead ids are pruned on read.

    ******************************************************************************/
    bool _Air_NameIn(const string &in name, const array<string> &in names)
    {
        for (uint i = 0; i < names.length(); ++i) {
            if (names[i] == name) return true;
        }
        return false;
    }

    void _Air_RemoveId(array<int>@ ids, int id)
    {
        for (uint i = 0; i < ids.length(); ++i) {
            if (ids[i] == id) { ids.removeAt(i); return; }
        }
    }

    void _Air_PruneIds(array<int>@ ids)
    {
        for (int i = int(ids.length()) - 1; i >= 0; --i) {
            if (ai.GetTeamUnit(ids[i]) is null) ids.removeAt(uint(i));
        }
    }

    void Air_OnUnitFinished(CCircuitUnit@ unit)
    {
        if (unit is null || unit.circuitDef is null) return;
        if (ReactorLadder::OnUnitFinished(unit)) return;
        const string name = unit.circuitDef.GetName();
        if (_Air_NameIn(name, AIR_RETIRE_WIND_SOLAR) || _Air_NameIn(name, AIR_RETIRE_ADV_SOLAR)
            || _Air_NameIn(name, AIR_RETIRE_T1_CONVERTERS)) {
            _Air_RemoveId(@g_airEcoIds, unit.id);
            g_airEcoIds.insertLast(unit.id);
        }
    }

    void Air_OnUnitDestroyed(CCircuitUnit@ unit)
    {
        if (unit is null) return;
        ReactorLadder::OnUnitDestroyed(unit);
        _Air_RemoveId(@g_airEcoIds, unit.id);
    }

    /******************************************************************************

    ECO RETIREMENT (Air_UpdateEcoRetire)

    Lower-tier energy gives its ground - and its reclaim value - back once what
    replaces it is up. Three steps, each latched, so the fusion reclaim on the
    AFUS path (step 3 of the reactor ladder below) never undoes one:

      1. RetireWindSolarAtFusions fusions finished        -> winds and solars
      2. RetireAdvSolarAtFusions fusions finished         -> advanced solars
      3. RetireT1ConvertersAtAdvConverters advanced
         converters finished                              -> T1 energy converters

    A finished AFUS counts as steps 1 and 2 reached (its fusions may already be
    gone). The unit lists cover every faction: commanders build other sides'
    converters (legcom* can build armmakr).

    Retired defs are capped at 0 on every update, which is what keeps them from
    coming back: the native energy and converter planners, Builder::EnqueueT1Solar /
    EnqueueT1AdvancedSolar / EnqueueT1EnergyConverter, the eco crew
    (Air_EnqueueEcoEnergy) and the commander wind all refuse an unavailable def.
    Builds already queued are dropped rather than finished: Air_DefaultTask
    aborts a default task for a retired def, the eco crew stops "keeping" one,
    and the commander drops its wind.

    Reclaim: up to EcoRetireConcurrentReclaims TaskB::Reclaim tasks at once, for
    finished structures of a retired class. The eco crew (T1 air constructors
    other than the primary and secondary) take them before any eco build; the
    native default task hands them to anyone else (HIGH priority, no build def,
    so a metal stall does not hold them back). One nobody takes expires after
    EcoRetireReclaimTimeoutSeconds and is queued again.

    Only finished structures are tracked (Main::AiUnitFinished), so after a
    mid-game /aireload the ones built before it are not reclaimed.

    ******************************************************************************/
    // Not const: BatchApplyUnitCaps takes array<string>@.
    array<string> AIR_RETIRE_WIND_SOLAR = { "armwin", "corwin", "legwin", "armsolar", "corsolar", "legsolar" };
    array<string> AIR_RETIRE_ADV_SOLAR = { "armadvsol", "coradvsol", "legadvsol" };
    array<string> AIR_RETIRE_T1_CONVERTERS = { "armmakr", "cormakr", "legeconv" };

    array<int> g_airEcoIds;        // finished winds, solars, advanced solars, T1 converters
    bool g_airRetiredWindSolar = false;
    bool g_airRetiredAdvSolar = false;
    bool g_airRetiredT1Converters = false;
    array<IUnitTask@> g_airReclaimTasks;   // our eco reclaim tasks in flight
    array<int> g_airReclaimTargets;        // parallel: the unit each one reclaims
    uint g_airReclaimNext = 0;             // eco crew round-robin over g_airReclaimTasks

    bool Air_IsRetiredDef(const CCircuitDef@ d)
    {
        if (d is null) return false;
        const string n = d.GetName();
        return (g_airRetiredWindSolar && _Air_NameIn(n, AIR_RETIRE_WIND_SOLAR))
            || (g_airRetiredAdvSolar && _Air_NameIn(n, AIR_RETIRE_ADV_SOLAR))
            || (g_airRetiredT1Converters && _Air_NameIn(n, AIR_RETIRE_T1_CONVERTERS));
    }

    // A build task for a retired def.
    bool Air_IsRetiredBuild(IUnitTask@ t)
    {
        IBuilderTask@ bt = cast<IBuilderTask>(t);
        return bt !is null && Air_IsRetiredDef(bt.buildDef);
    }

    // Builder::MakeDefaultTaskWithLog, minus builds of retired defs: native may
    // still hold one queued from before the cap. It is aborted on the next update
    // (Builder DEFERRED ABORT - this runs inside AiMakeTask, where aborting the
    // task the engine may be re-evaluating crashes it); meanwhile, a short wait.
    IUnitTask@ Air_DefaultTask(Id builderId, const string &in label)
    {
        IUnitTask@ t = Builder::MakeDefaultTaskWithLog(builderId, label);
        if (!Air_IsRetiredBuild(t)) return t;
        if (!Builder::IsAbortQueued(t)) {
            IBuilderTask@ bt = cast<IBuilderTask>(t);
            GenericHelpers::LogUtil("[AIR][Retire] dropping queued " + bt.buildDef.GetName() + " (retired)", 2);
            Builder::AbortLater(t);
        }
        return aiBuilderMgr.Enqueue(TaskB::Wait(3 * SECOND));
    }

    void _Air_Retire(array<string>@ defs, const string &in what, const string &in why)
    {
        UnitHelpers::BatchApplyUnitCaps(defs, 0);
        GenericHelpers::LogUtil("[AIR][Retire] " + what + " retired (" + why + "): capped at 0, reclaiming", 1);
    }

    int _Air_ReclaimIndexOf(IUnitTask@ t)
    {
        for (uint i = 0; i < g_airReclaimTasks.length(); ++i) {
            if (g_airReclaimTasks[i] is t) return int(i);
        }
        return -1;
    }

    // Air_BuilderAiTaskRemoved: a reclaim task ended. Done or not, its slot frees;
    // a target still standing is picked again by the next update.
    void Air_OnReclaimTaskRemoved(IUnitTask@ task)
    {
        const int i = _Air_ReclaimIndexOf(task);
        if (i < 0) return;
        g_airReclaimTasks.removeAt(uint(i));
        g_airReclaimTargets.removeAt(uint(i));
    }

    // Eco crew: an eco reclaim to join, or null.
    IUnitTask@ Air_TakeEcoReclaim(CCircuitUnit@ u)
    {
        if (u !is null && u.task !is null && _Air_ReclaimIndexOf(u.task) >= 0) return u.task;   // keep it
        if (g_airReclaimTasks.length() == 0) return null;
        return g_airReclaimTasks[g_airReclaimNext++ % g_airReclaimTasks.length()];
    }

    void Air_UpdateEcoRetire()
    {
        if (!Global::RoleSettings::Air::EcoRetireEnabled) return;
        _Air_PruneIds(@ReactorLadder::fusionIds);
        _Air_PruneIds(@ReactorLadder::afusIds);
        _Air_PruneIds(@ReactorLadder::advConvIds);
        _Air_PruneIds(@g_airEcoIds);
        const int fus = int(ReactorLadder::fusionIds.length());
        const bool afus = ReactorLadder::afusIds.length() > 0;

        if (!g_airRetiredWindSolar && (afus || fus >= Global::RoleSettings::Air::RetireWindSolarAtFusions)) {
            g_airRetiredWindSolar = true;
            _Air_Retire(AIR_RETIRE_WIND_SOLAR, "winds and solars", "" + fus + " fusion(s) finished" + (afus ? ", AFUS up" : ""));
        }
        if (!g_airRetiredAdvSolar && (afus || fus >= Global::RoleSettings::Air::RetireAdvSolarAtFusions)) {
            g_airRetiredAdvSolar = true;
            _Air_Retire(AIR_RETIRE_ADV_SOLAR, "advanced solars", "" + fus + " fusion(s) finished" + (afus ? ", AFUS up" : ""));
        }
        if (!g_airRetiredT1Converters
            && int(ReactorLadder::advConvIds.length()) >= Global::RoleSettings::Air::RetireT1ConvertersAtAdvConverters) {
            g_airRetiredT1Converters = true;
            _Air_Retire(AIR_RETIRE_T1_CONVERTERS, "T1 energy converters", "" + ReactorLadder::advConvIds.length() + " advanced converter(s) finished");
        }

        // Hold the caps: a role switch restores the def baseline (Commands::DefState).
        // BatchApplyUnitCaps writes only on change.
        if (g_airRetiredWindSolar) UnitHelpers::BatchApplyUnitCaps(AIR_RETIRE_WIND_SOLAR, 0);
        if (g_airRetiredAdvSolar) UnitHelpers::BatchApplyUnitCaps(AIR_RETIRE_ADV_SOLAR, 0);
        if (g_airRetiredT1Converters) UnitHelpers::BatchApplyUnitCaps(AIR_RETIRE_T1_CONVERTERS, 0);

        // Queue reclaims up to the concurrency limit.
        const int limit = Global::RoleSettings::Air::EcoRetireConcurrentReclaims;
        for (uint i = 0; i < g_airEcoIds.length() && int(g_airReclaimTasks.length()) < limit; ++i) {
            const int id = g_airEcoIds[i];
            if (g_airReclaimTargets.find(id) >= 0) continue;
            CCircuitUnit@ s = ai.GetTeamUnit(id);
            if (s is null || !Air_IsRetiredDef(s.circuitDef)) continue;
            IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, s,
                Global::RoleSettings::Air::EcoRetireReclaimTimeoutSeconds * SECOND));
            if (t is null) break;
            if (_Air_ReclaimIndexOf(t) >= 0) continue;   // native returned the task that already reclaims it
            g_airReclaimTasks.insertLast(t);
            g_airReclaimTargets.insertLast(id);
            GenericHelpers::LogUtil("[AIR][Retire] reclaiming " + s.circuitDef.GetName() + " id=" + id
                + " (" + g_airReclaimTasks.length() + "/" + limit + " in flight)", 2);
        }
    }

    /******************************************************************************

    POST-T2 REACTOR LADDER

    Shared with FRONT: manager/reactor_ladder.as (ReactorLadder::TryT2Economy)
    documents the steps. AIR's settings are Global::RoleSettings::Air; while
    metal-starved the reactors go in at NOW priority - the only priority
    CBuilderManager::MakeBuilderTask hands idle builders during a metal stall -
    and no advanced converters are built (METAL-STARVED MODE).

    ******************************************************************************/
    ReactorLadder::Params@ Air_LadderParams()
    {
        ReactorLadder::Params@ p = ReactorLadder::Params();
        p.tag = "AIR";
        p.fusionsBeforeAFUS = Global::RoleSettings::Air::FusionsBeforeAFUS;
        p.minMetalIncomeForFUS = Global::RoleSettings::Air::MinimumMetalIncomeForFUS;
        p.reclaimFusionsAtAFUSCount = Global::RoleSettings::Air::ReclaimFusionsAtAFUSCount;
        p.maxAFUS = Global::RoleSettings::Air::MaxAdvancedFusionReactors;
        p.advConverterEnergyPercent = Global::RoleSettings::Air::AdvConverterEnergyPercent;
        p.convPerFusion = Global::RoleSettings::Air::AdvConvertersPerFusion;
        p.convPerAFUS = Global::RoleSettings::Air::AdvConvertersPerAFUS;
        const bool starved = Air_IsMetalStarved();
        p.holdConverters = starved;
        p.reactorPrio = starved ? Task::Priority::NOW : Task::Priority::NORMAL;
        return p;
    }

    IUnitTask@ Air_BuilderAiMakeTask(CCircuitUnit@ builder) {
        GenericHelpers::LogUtil("[Air_BuilderAiMakeTask] called for builder", 4);
        if (builder is null) return null;

        const CCircuitDef@ udef = builder.circuitDef;
        if (udef is null) return Air_DefaultTask(builder.id, "AIR");

        if (UnitHelpers::IsCommander(udef)) {
            return Air_Commander_AiMakeTask(builder);
        }

        string uname = udef.GetName();
        // T2 air constructors were pure native default: nothing in this role
        // ever asked them for a second plant, a fusion or a gantry, which is
        // why AIR floated at max metal late. The ladder returns null when not
        // floating, and the default runs as before.
        if (UnitHelpers::GetAllT2AirConstructors().find(uname) >= 0) {
            IUnitTask@ tLate = Air_LateExpansion_AiMakeTask(builder);
            if (tLate !is null) return tLate;
        }

        bool isT1AirConstructor = (uname == "armca" || uname == "corca" || uname == "legca");
        if (isT1AirConstructor) {
            if (builder is Builder::primaryT1AirConstructor) {
                return Air_T1Constructor_AiMakeTask(builder);
            }
            if (builder is Builder::secondaryT1AirConstructor) {
                return Air_DefaultTask(builder.id, "AIR expansion");
            }
            // The rest are the eco crew: economy before assisting the primary's
            // factory projects. The secondary stays on mex expansion.
            // Reclaiming retired eco comes first (ECO RETIREMENT).
            IUnitTask@ tRetire = Air_TakeEcoReclaim(builder);
            if (tRetire !is null) return tRetire;
            IUnitTask@ tEco = Air_TryEcoBuild(builder);
            if (tEco !is null) return tEco;
            if (Air_IsBuildFocusActive()) {
                return Air_AssignFocusedFollower(builder);
            }
        }

        // T2 constructors: mex upgrade first (best metal per metal, spots are finite),
        // then the reactor ladder (fusions -> AFUS -> converters, fusion reclaim).
        if (UnitHelpers::GetConstructorTier(udef) >= 2) {
            if (ReactorLadder::IsOnLadderBuild(builder)) return builder.task;
            // Metal-starved: reactors, not mex upgrades (METAL-STARVED MODE).
            if (Global::RoleSettings::MexUpgradeFirst && !Air_IsMetalStarved()) {
                IUnitTask@ tMexUp = EconomyHelpers::EnqueueMexUpgradeIfFirst(builder, Global::Map::StartPos,
                        Global::RoleSettings::MexUpgradeRadius,
                        Global::RoleSettings::MexUpgradeMaxConcurrent, "AIR");
                if (tMexUp !is null) return tMexUp;
            }
            IUnitTask@ tT2Eco = ReactorLadder::TryT2Economy(builder, Air_LadderParams());
            if (tT2Eco !is null) return tT2Eco;
        }

        return Air_DefaultTask(builder.id, "AIR");
    }

    /******************************************************************************

    BUILDER LOGIC (COMMANDER)

    ******************************************************************************/ 

    // Accelerate the first constructor, then reinforce the strategic lane while
    // early build-power focus remains active.
    IUnitTask@ Air_Commander_AiMakeTask(CCircuitUnit@ comm)
    {
        if (comm is null) return null;

        const int AIR_FACTORY_ASSIST_DEADLINE_FRAMES = Global::RoleSettings::Air::CommanderFactoryAssistDeadlineSeconds * SECOND;
        CCircuitUnit@ primary = Builder::primaryT1AirConstructor;
        if (primary !is null) {
            IUnitTask@ windTask = Air_TryCommanderWind(comm);
            if (windTask !is null) return windTask;

            if (g_airStrategicFocusTask !is null
                && primary.id == g_airStrategicFocusLeaderId && Air_IsBuildFocusActive()) {
                IUnitTask@ focusGuard = GuardHelpers::AssignWorkerGuard(
                    comm,
                    primary,
                    Task::Priority::HIGH,
                    true,
                    Global::RoleSettings::Air::CommanderFactoryAssistGuardTimeoutSeconds * SECOND
                );
                if (focusGuard !is null) return focusGuard;
            }
        }

        if (primary !is null || ai.frame > AIR_FACTORY_ASSIST_DEADLINE_FRAMES) {
            return Air_DefaultTask(comm.id, "AIR commander");
        }

        CCircuitUnit@ target = null;
        if (Factory::primaryT1AirPlant !is null) {
            @target = Factory::primaryT1AirPlant;
        }

        if (target is null) {
            return Air_DefaultTask(comm.id, "AIR commander");
        }

        // Assign a high-priority guard task so the commander sticks near the air factory.
        // The guard timeout is configurable via role settings.
        const int AIR_FACTORY_ASSIST_GUARD_TIMEOUT_FRAMES = Global::RoleSettings::Air::CommanderFactoryAssistGuardTimeoutSeconds * SECOND;
        IUnitTask@ guardTask = GuardHelpers::AssignWorkerGuard(
            comm,
            target,
            Task::Priority::HIGH,
            true,
            AIR_FACTORY_ASSIST_GUARD_TIMEOUT_FRAMES // guard duration; can be renewed while within deadline
        );

        if (guardTask !is null) return guardTask;
        return Air_DefaultTask(comm.id, "AIR commander");
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
        if (task !is null && task is g_airCommanderWindTask) {
            @g_airCommanderWindTask = null;
        }
        if (task !is null && task is g_airStrategicFocusTask) {
            @g_airStrategicFocusTask = null;
            g_airStrategicFocusLeaderId = -1;
        }
        // The ladder's fusion reclaim is released in Builder::AiTaskRemoved.
        Air_OnReclaimTaskRemoved(task);
        Air_OnLateNanoTaskRemoved(task, done);
    }

    void Air_BuilderAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        if (unit !is null && unit.circuitDef !is null
            && UnitHelpers::IsCommander(unit.circuitDef)) {
            @g_airCommanderWindTask = null;
        }
        if (unit !is null && unit.id == g_airStrategicFocusLeaderId) {
            @g_airStrategicFocusTask = null;
            g_airStrategicFocusLeaderId = -1;
        }
    }

    /******************************************************************************

    BUILDER LOGIC

    ******************************************************************************/

    /**************************************************************************
     LATE-GAME EXPANSION

     Runs only while metal is floating (see Global::RoleSettings::Air::Late*).
     Every structure it places goes on a ring LateExpansionRadius out from the
     start position, slot chosen by how many of that structure already exist,
     so each new one lands on fresh ground and the base grows outward instead
     of packing the core. Returns null when there is nothing to do, and the
     caller falls through to its normal policy.
     **************************************************************************/
    bool Air_IsFloating(float mi)
    {
        if (mi < Global::RoleSettings::Air::LateMetalIncome) return false;
        return aiEconomyMgr.isMetalFull
            || aiEconomyMgr.metal.current >= Global::RoleSettings::Air::LateMetalCurrent;
    }

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

    // Late nanos. The anchor used to be ring slot `nanos`: when that site could not
    // be built (unsafe, cliff, water - the nano task only searches within the
    // nano's own build distance and falls back to a patrol), no nano was ever
    // finished, `nanos` stayed 0 and the same slot was asked for again every
    // couple of seconds for the rest of the game (All That Glitters 2026-09-27:
    // "nano 1/12" from f=39225 on while AIR's bank rose from 4 700 to 13 000).
    // Now each late nano that ends unbuilt moves the next one to the next anchor:
    // the primary T2 air plant first - AIR floats metal because its plants cannot
    // spend it, so a nano there assists production at once - then the ring slots.
    array<IUnitTask@> g_airLateNanoTasks;
    int g_airLateNanoMisses = 0;

    AIFloat3 Air_LateNanoAnchor()
    {
        const int slots = (Global::RoleSettings::Air::LateRingSlots < 1) ? 1 : Global::RoleSettings::Air::LateRingSlots;
        const int k = g_airLateNanoMisses % (slots + 1);
        if (k == 0) {
            const AIFloat3 plant = Factory::GetT2AirPlantPos();
            if (plant.x >= 0.0f) return plant;
        }
        return Air_RingAnchor(k == 0 ? 0 : k - 1);
    }

    // Air_BuilderAiTaskRemoved.
    void Air_OnLateNanoTaskRemoved(IUnitTask@ task, bool done)
    {
        if (task is null) return;
        for (uint i = 0; i < g_airLateNanoTasks.length(); ++i) {
            if (g_airLateNanoTasks[i] !is task) continue;
            g_airLateNanoTasks.removeAt(i);
            if (!done) {
                ++g_airLateNanoMisses;
                GenericHelpers::LogUtil("[AIR][Late] nano site unusable; next nano moves to anchor "
                    + g_airLateNanoMisses % ((Global::RoleSettings::Air::LateRingSlots < 1 ? 1 : Global::RoleSettings::Air::LateRingSlots) + 1)
                    + " (0 = T2 air plant, then ring slots)", 1);
            }
            return;
        }
    }

    IUnitTask@ Air_LateExpansion_AiMakeTask(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null) return null;
        const float mi = Economy::GetMinMetalIncomeLast10s();
        const float ei = Economy::GetMinEnergyIncomeLast10s();
        if (!Air_IsFloating(mi)) return null;

        const string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        const float shake = Global::RoleSettings::Air::LateExpansionShake;
        const int t2Plants = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2AircraftPlants());
        const int nanos = UnitDefHelpers::GetUnitDefCount(UnitHelpers::GetT1NanoNameForSide(side));
        const int fusions = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllFusionReactors());
        const int afus = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllAdvancedFusionReactors());
        const int gantries = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllLandGantries());

        // 1. Build power. Nanos beyond the income-based target, anchored on the
        //    ring so they stand where the new plants will be, not in the core.
        //    Queued late-nano tasks count too: counting only standing nanos queued
        //    "nano 8/16" four times in 20 s (Supreme Isthmus 2026-09-27).
        const int nanoTarget = (t2Plants < 1 ? 1 : t2Plants) * Global::RoleSettings::Air::LateNanosPerT2Plant;
        const int nanosQueued = int(g_airLateNanoTasks.length());
        if (nanos + nanosQueued < nanoTarget && nanos + nanosQueued < Global::RoleSettings::Air::NanoMaxCount) {
            IUnitTask@ t = Builder::EnqueueT1Nano(side, Air_LateNanoAnchor(), shake, 120 * SECOND, Task::Priority::NORMAL);
            if (t !is null) {
                g_airLateNanoTasks.insertLast(t);
                GenericHelpers::LogUtil("[AIR][Late] nano " + (nanos + nanosQueued + 1) + "/" + nanoTarget
                    + " (metal " + int(aiEconomyMgr.metal.current) + ", income " + int(mi) + ")", 1);
                return Air_SetStrategicFocus(u, t);
            }
        }

        // 2. Production. More T2 air plants, each on the next ring slot.
        if (t2Plants < Global::RoleSettings::Air::LateMaxT2AircraftPlants && !Factory::IsT2AirPlantBuildQueued()) {
            IUnitTask@ t = Builder::EnqueueT2AirPlant(side, Air_RingAnchor(t2Plants), shake, 600 * SECOND);
            if (t !is null) {
                GenericHelpers::LogUtil("[AIR][Late] T2 air plant " + (t2Plants + 1) + "/"
                    + Global::RoleSettings::Air::LateMaxT2AircraftPlants + " on ring slot " + t2Plants, 1);
                return Air_SetStrategicFocus(u, t);
            }
        }

        // 3. Energy to carry it. A fusion per LateEnergyPerT2Plant of shortfall;
        //    an advanced fusion once rich enough for one.
        const float wantEnergy = float(t2Plants < 1 ? 1 : t2Plants) * Global::RoleSettings::Air::LateEnergyPerT2Plant;
        if (ei < wantEnergy || aiEconomyMgr.isEnergyEmpty) {
            if (mi >= Global::RoleSettings::Air::LateAFUSMetalIncome
                && aiEconomyMgr.metal.current >= Global::RoleSettings::Air::LateAFUSMetalCurrent) {
                IUnitTask@ t = Builder::EnqueueAFUS(side, Air_RingAnchor(fusions + afus), shake, 900 * SECOND);
                if (t !is null) {
                    GenericHelpers::LogUtil("[AIR][Late] advanced fusion (energy " + int(ei) + " < " + int(wantEnergy) + ")", 1);
                    return Air_SetStrategicFocus(u, t);
                }
            }
            IUnitTask@ t = Builder::EnqueueFUS(side, Air_RingAnchor(fusions + afus), shake, 600 * SECOND, Task::Priority::NORMAL);
            if (t !is null) {
                GenericHelpers::LogUtil("[AIR][Late] fusion (energy " + int(ei) + " < " + int(wantEnergy) + ")", 1);
                return Air_SetStrategicFocus(u, t);
            }
        }

        // 4. T3. The gantry is the only way to the experimental air plant:
        //    armhaap is built solely by the T3 air constructor the gantry makes.
        if (gantries < 1
            && mi >= Global::RoleSettings::Air::LateGantryMetalIncome
            && aiEconomyMgr.metal.current >= Global::RoleSettings::Air::LateGantryMetalCurrent) {
            IUnitTask@ t = Builder::EnqueueLandGantry(side);
            if (t !is null) {
                GenericHelpers::LogUtil("[AIR][Late] gantry (metal " + int(aiEconomyMgr.metal.current) + ", income " + int(mi) + ")", 1);
                return Air_SetStrategicFocus(u, t);
            }
        }

        return null;   // floating, but every rung is capped, queued or on cooldown
    }

    IUnitTask@ Air_T1Constructor_AiMakeTask(CCircuitUnit@ u) {
        // Snapshot economy
        //float mi = Global::Economy::MetalIncome;
        //float ei = Global::Economy::EnergyIncome;
		float mi = Economy::GetMinMetalIncomeLast10s();
		float ei = Economy::GetMinEnergyIncomeLast10s();

        AIFloat3 conLocation = u.GetPos(ai.frame);
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // Floating metal outranks the whole T1 ladder below: a converter or a
        // solar does nothing for a bank that is already full.
        {
            IUnitTask@ tLate = Air_LateExpansion_AiMakeTask(u);
            if (tLate !is null) return tLate;
        }

        if (u is Builder::primaryT1AirConstructor) {

            // Consider upgrading to a T2 Aircraft Plant if economy and prerequisites allow
            //if (!Builder::IsT2AirPlantQueued) {
                int t2AirPlantCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2AircraftPlants());
                bool hasPrimaryT1AirPlant = (Factory::primaryT1AirPlant !is null);
                // Native average income (as Barb4 reads it), not the 10 s minimum the
                // ladder below uses: one dip in the window no longer holds T2 back.
                if (EconomyHelpers::ShouldBuildT2AircraftPlant(
                    /*mi*/ aiEconomyMgr.metal.income,
                    /*ei*/ aiEconomyMgr.energy.income,
                    /*metalCurrent*/ aiEconomyMgr.metal.current,
                    /*requiredMetalIncome*/ Global::RoleSettings::Air::RequiredMetalIncomeForT2AircraftPlant,
                    /*requiredMetalCurrent*/ Global::RoleSettings::Air::RequiredMetalCurrentForT2AircraftPlant,
                    /*requiredEnergyIncome*/ Global::RoleSettings::Air::RequiredEnergyIncomeForT2AircraftPlant,
                    /*constructorDef*/ u.circuitDef,
                    /*t2AirPlantCount*/ t2AirPlantCount,
                    /*maxAllowed*/ g_airT2PlantsAllowed   // 1, then 2 at 100 and 3 at 200 avg metal income
                ) && hasPrimaryT1AirPlant) {
                    AIFloat3 anchor = Factory::GetT1AirPlantPos();
                    IUnitTask@ tT2Air = Builder::EnqueueT2AirPlant(unitSide, anchor, SQUARE_SIZE * 30, 600 * SECOND);
                    if (tT2Air !is null) return Air_SetStrategicFocus(u, tT2Air);
                }
                // Reserve-trigger: if metal reserves exceed 1300 and we have zero T2 air plants, force-queue one
                // regardless of income thresholds. Avoid duplicate enqueue if a build is already queued.
                if (hasPrimaryT1AirPlant && t2AirPlantCount <= 0 && aiEconomyMgr.metal.current > 1300.0f) {
                    AIFloat3 anchor2 = Factory::GetT1AirPlantPos();
                    IUnitTask@ tForceT2 = Builder::EnqueueT2AirPlant(unitSide, anchor2, SQUARE_SIZE * 40, 600 * SECOND);
                    if (tForceT2 !is null) return Air_SetStrategicFocus(u, tForceT2);
                }
           // }

            // Build Energy Converter?
            if (EconomyHelpers::ShouldBuildT1EnergyConverter(
                /*metalIncome*/ mi,
                /*energyIncome*/ ei,
                /*energyCurrent*/ aiEconomyMgr.energy.current,
                /*energyStorage*/ aiEconomyMgr.energy.storage,
                /*untilMetalIncome*/ Global::RoleSettings::Air::BuildT1ConvertersUntilMetalIncome,
                /*minEnergyIncome*/ Global::RoleSettings::Air::BuildT1ConvertersMinimumEnergyIncome,
                /*minEnergyCurrentPercent*/ Global::RoleSettings::Air::BuildT1ConvertersMinimumEnergyCurrentPercent
            )) {
                IUnitTask@ tConv = Builder::EnqueueT1EnergyConverter(unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 30);
                if (tConv !is null) return Air_SetStrategicFocus(u, tConv);
            }

            // Build regular solar?
            if (EconomyHelpers::ShouldBuildT1Solar(
                /*energyIncome*/ ei,
                /*minEnergyIncome*/ Global::RoleSettings::Air::SolarEnergyIncomeMinimum
            )) {
                IUnitTask@ tSolar = Builder::EnqueueT1Solar(u.id, unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 30);
                if (tSolar !is null) return Air_SetStrategicFocus(u, tSolar);
            }

            // Build a T1 nano caretaker if under desired target (income-based) or reserves allow
            float energyPercent = (aiEconomyMgr.energy.storage > 0.0f)
                ? (aiEconomyMgr.energy.current / aiEconomyMgr.energy.storage)
                : 0.0f;

            // Only build nanos if we have a preferred factory to anchor around
            if (Factory::GetPreferredFactory() !is null && EconomyHelpers::ShouldBuildT1Nano(
                ei,
                mi,
                Global::RoleSettings::Air::NanoEnergyPerUnit,
                Global::RoleSettings::Air::NanoMetalPerUnit,
                Global::RoleSettings::Air::NanoMaxCount,
                aiEconomyMgr.metal.current,
                Global::RoleSettings::Air::NanoBuildWhenOverMetal,
                energyPercent
            )) {
                // Centralized selection with per-factory nano caps and prioritization
                CCircuitUnit@ targetFactory = Factory::SelectFactoryNeedingNano();
                if (targetFactory !is null) {
                    IUnitTask@ tNano = Factory::EnqueueNanoForFactory(targetFactory, Task::Priority::NORMAL);
                    if (tNano !is null) return Air_SetStrategicFocus(u, tNano);
                }
            }

            // Build advanced T1 solar using Air predicate
            if (Air_IsAdvancedSolarReady(unitSide, mi, ei)) {
                IUnitTask@ tAdvSolar = Builder::EnqueueT1AdvancedSolar(u.id, unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 30);
                if (tAdvSolar !is null) return Air_SetStrategicFocus(u, tAdvSolar);
            }

            // Same ladder as the eco crew; adds wind, and places its own building
            // when the shared solar cooldowns above held it off.
            IUnitTask@ tEco = Air_TryEcoBuild(u);
            if (tEco !is null) return Air_SetStrategicFocus(u, tEco);
        }

        IUnitTask@ defaultTask = Air_DefaultTask(u.id, "AIR strategic");
        return Air_SetStrategicFocus(u, defaultTask);
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
            "legperdition", "leglraa", "legnanotc", "legnanotc", "leglrpc", "legdeflector", "leglrpc",
            "leglraa", "legdeflector", "legperdition", "legbastion", "legstarfall", "legbastion", "legbastion"}}
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
        @cfg.EconomyUpdateHandler = cast<EconomyUpdateDelegate@>(@Air_EconomyUpdate);

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
