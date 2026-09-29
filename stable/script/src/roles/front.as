// role: FRONT
#include "../types/role_config.as"
#include "../helpers/unit_helpers.as"
#include "../helpers/factory_helpers.as"
#include "../helpers/economy_helpers.as"
#include "../helpers/guard_helpers.as"
#include "../helpers/unitdef_helpers.as"
// Dynamic factory production + shared helpers
#include "../helpers/objective_helpers.as"
#include "../helpers/role_limit_helpers.as"
#include "../global.as"
#include "../types/terrain.as"
#include "../manager/factory_production.as"
// Builder state and helpers for enqueueing structures like nanos
#include "../manager/builder.as"
#include "../manager/economy.as"

namespace RoleFront {

    /******************************************************************************

    INITIALIZATION

    ******************************************************************************/

    void Front_Init() {
        GenericHelpers::LogUtil("Front role initialization logic executed", 2);

        // Apply FRONT role settings
        aiTerrainMgr.SetAllyZoneRange(Global::RoleSettings::Front::AllyRange);

        // FRONT-only: Set default fire state for all T1 combat units to 3 (fire at everything)
        // Note: 2 = fire at will, 3 = fire at everything
        array<string> t1Combat = UnitHelpers::GetAllT1CombatUnits();
        for (uint i = 0; i < t1Combat.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(t1Combat[i]);
            if (d is null) continue;
            // Best-effort: if engine exposes fire-state setter, apply it
            // TODO: If SetFireState is not available, consider moving this to behaviour config for this profile only.
            d.SetFireState(Global::RoleSettings::Front::DefaultT1CombatFireState);
        }

        // Default to bot thresholds in Front init
        aiMilitaryMgr.quota.scout = Global::RoleSettings::Front::MilitaryScoutCapBots;
        aiMilitaryMgr.quota.attack = Global::RoleSettings::Front::MilitaryAttackThresholdBots;
        aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Front::MilitaryRaidMinPowerBots; 
        aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Front::MilitaryRaidAvgPowerBots; 
        g_frontVehicleThresholdsApplied = false;

        Front_ApplyStartLimits();

        // Initialize dynamic factory production system for FRONT role when enabled
        if (Global::RoleSettings::Front::UseDynamicFactoryProduction) {
            FactoryProduction::Initialize();
            GenericHelpers::LogUtil("[FRONT] Dynamic factory production system initialized", 2);
        } else {
            GenericHelpers::LogUtil("[FRONT] Dynamic factory production disabled; using legacy factory selection", 2);
        }

        // Log all strategic objectives with distance from start
        ObjectiveHelpers::LogAllObjectivesFromStart(AiRole::FRONT, "FRONT");
    }

    void Front_ApplyStartLimits() {
        dictionary startLimits; 

        startLimits.set("armrectr", Global::RoleSettings::Front::StartCapRezBots);
        startLimits.set("cornecro", Global::RoleSettings::Front::StartCapRezBots);

        startLimits.set("armap", Global::RoleSettings::Front::StartCapT1AircraftPlants);
        startLimits.set("corap", Global::RoleSettings::Front::StartCapT1AircraftPlants);
        startLimits.set("legap", Global::RoleSettings::Front::StartCapT1AircraftPlants);

        startLimits.set("armsilo", Global::RoleSettings::Front::StartCapNukeSilos);
        startLimits.set("corsilo", Global::RoleSettings::Front::StartCapNukeSilos);
        startLimits.set("legsilo", Global::RoleSettings::Front::StartCapNukeSilos);

        UnitHelpers::ApplyUnitLimits(startLimits);

        GenericHelpers::LogUtil("Front start limits applied", 3);
    }

    /******************************************************************************

    MAIN HOOKS

    ******************************************************************************/

    // Compute the total metal "power" of all FRONT army units using the military manager's armyCost.
    // This is an approximate metal-equivalent value including both mobile and static forces so that
    // base fortifications contribute when comparing against enemy surface investment.
    float Front_GetArmyMetalCostEstimate()
    {
        // NOTE: aiMilitaryMgr.armyCost is used elsewhere (e.g. factory switch logic) as a
        // metal-equivalent measure of our army. We reuse that here so FRONT compares its
        // strength against cached enemy metal costs on a consistent scale.

        float armyCost = aiMilitaryMgr.armyCost;
        if (!(armyCost == armyCost) || armyCost < 0.f) {
            armyCost = 0.f;
        }
        return armyCost;
    }

    // Adjust FRONT military quotas based on comparison of our army metal cost vs cached enemy surface cost.
    void Front_UpdateDynamicMilitaryQuotas()
    {
        // Estimate our army metal cost
        float ourArmyCost = Front_GetArmyMetalCostEstimate();

        // Enemy surface metrics (cost per player) are cached centrally in Military when
        // the enemy cost cache is updated; we just read the derived values here.
        float enemySurfaceCostPerPlayer = Military::GetEnemySurfaceCostPerPlayer();
        float enemySurfaceCostTotal     = Military::g_cachedTotalSurfaceCost; // for logging only

        // Defensive sanity checks
        if (!(enemySurfaceCostPerPlayer == enemySurfaceCostPerPlayer) || enemySurfaceCostPerPlayer < 0.f) {
            enemySurfaceCostPerPlayer = 0.f;
        }

        float attackThreshold = enemySurfaceCostPerPlayer * Global::RoleSettings::Front::DynamicQuotaEnemyCostAttackThresholdMultiplier;
        float withdrawThreshold = enemySurfaceCostPerPlayer * Global::RoleSettings::Front::DynamicQuotaEnemyCostWithdrawThresholdMultiplier;

        // Hysteresis logic:
        // - If currently underpowered (defensive), we only switch to aggressive if we exceed the ATTACK threshold.
        // - If currently aggressive (attacking), we only switch to underpowered if we drop below the WITHDRAW threshold.
        if (g_frontIsUnderpowered) {
            if (ourArmyCost >= attackThreshold) {
                g_frontIsUnderpowered = false;
            }
        } else {
            if (ourArmyCost < withdrawThreshold) {
                g_frontIsUnderpowered = true;
            }
        }

        // When underpowered vs enemy surface cost, push quotas high to encourage more army production.
        if (g_frontIsUnderpowered) {
            // Use a high cap and low attack threshold to trigger more frequent waves.
            //aiMilitaryMgr.quota.scout = 10;
            aiMilitaryMgr.quota.attack = Global::RoleSettings::Front::UnderpoweredAttackQuota;
            aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Front::UnderpoweredRaidMinQuota;
            aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Front::UnderpoweredRaidAvgQuota;

            GenericHelpers::LogUtil(
                "[FRONT][Quota] Underpowered vs enemy surface (ourArmyCost=" + ourArmyCost +
                " enemySurfaceCostTotal=" + enemySurfaceCostTotal +
                " enemySurfacePerPlayer=" + enemySurfaceCostPerPlayer +
                " attackThr=" + attackThreshold +
                " withdrawThr=" + withdrawThreshold +
                ") => HIGH quotas: scout=" + aiMilitaryMgr.quota.scout +
                " attack=" + aiMilitaryMgr.quota.attack +
                " raid.min=" + aiMilitaryMgr.quota.raid.min +
                " raid.avg=" + aiMilitaryMgr.quota.raid.avg,
                3
            );
        } else {
            // When not underpowered, keep quotas near their front-role defaults (bots/vehicles split).
            int baseScout = g_frontVehicleThresholdsApplied
                ? Global::RoleSettings::Front::MilitaryScoutCapVehicles
                : Global::RoleSettings::Front::MilitaryScoutCapBots;
            float baseAttack = g_frontVehicleThresholdsApplied
                ? Global::RoleSettings::Front::MilitaryAttackThresholdVehicles
                : Global::RoleSettings::Front::MilitaryAttackThresholdBots;
            float baseRaidMin = g_frontVehicleThresholdsApplied
                ? Global::RoleSettings::Front::MilitaryRaidMinPowerVehicles
                : Global::RoleSettings::Front::MilitaryRaidMinPowerBots;
            float baseRaidAvg = g_frontVehicleThresholdsApplied
                ? Global::RoleSettings::Front::MilitaryRaidAvgPowerVehicles
                : Global::RoleSettings::Front::MilitaryRaidAvgPowerBots;

            aiMilitaryMgr.quota.scout = baseScout;
            aiMilitaryMgr.quota.attack = baseAttack;
            aiMilitaryMgr.quota.raid.min = baseRaidMin;
            aiMilitaryMgr.quota.raid.avg = baseRaidAvg;

            GenericHelpers::LogUtil(
                "[FRONT][Quota] Competitive vs enemy surface (ourArmyCost=" + ourArmyCost +
                " enemySurfaceCostTotal=" + enemySurfaceCostTotal +
                " enemySurfacePerPlayer=" + enemySurfaceCostPerPlayer +
                " attackThr=" + attackThreshold +
                " withdrawThr=" + withdrawThreshold +
                ") => BASE quotas: scout=" + aiMilitaryMgr.quota.scout +
                " attack=" + aiMilitaryMgr.quota.attack +
                " raid.min=" + aiMilitaryMgr.quota.raid.min +
                " raid.avg=" + aiMilitaryMgr.quota.raid.avg,
                4
            );
        }
    }

    // Delay for dynamic quota adjustments: 5 minutes in frames
    const int FRONT_DYNAMIC_QUOTA_DELAY_FRAMES = Global::RoleSettings::Front::DynamicQuotaDelaySeconds * SECOND;

    void Front_MainUpdate() {
        // Delay dynamic quota adjustments until 5 minutes into the game to avoid
        // early-game oscillations while armies and caches are still forming.
        if (ai.frame < FRONT_DYNAMIC_QUOTA_DELAY_FRAMES) {
            return;
        }

        // Dynamically adjust FRONT military quotas based on army vs enemy surface metal costs
        Front_UpdateDynamicMilitaryQuotas();
    }

    /******************************************************************************

    ECONOMY HOOKS

    ******************************************************************************/

    void Front_EconomyUpdate() {
        float metalIncome = Economy::GetMinMetalIncomeLast10s();
        float energyIncome = Economy::GetMinEnergyIncomeLast10s();
        Front_IncomeLimits(metalIncome, energyIncome);

        // One-time switch for T1 combat units to 'raider' role when metal income > 250
        if (!g_frontT1CombatRoleSwitchDone && metalIncome > 250.0f) {
            g_frontT1CombatRoleSwitchDone = true;
            int raiderType = aiRoleMasker.GetTypeMask("raider").type;
            if (raiderType >= 0) {
                array<string> t1Combat = UnitHelpers::GetAllT1CombatUnits();
                for (uint i = 0; i < t1Combat.length(); ++i) {
                    CCircuitDef@ d = ai.GetCircuitDef(t1Combat[i]);
                    if (d !is null) {
                        d.SetMainRole(raiderType);
                        GenericHelpers::LogUtil("[FRONT] Switched " + t1Combat[i] + " to raider role (income > 250)", 2);
                    }
                }
            }
        }
    }

    /******************************************************************************

    FACTORY HOOKS

    ******************************************************************************/

    // Track if vehicle thresholds have been applied (to avoid reapplying repeatedly)
    bool g_frontVehicleThresholdsApplied = false;

    // Track if T1 combat units have been switched to raider role
    bool g_frontT1CombatRoleSwitchDone = false;

    // Track if we are currently in "underpowered" mode (hysteresis state)
    bool g_frontIsUnderpowered = true; 

    // One-time T1 raider opener state for the first suitable T1 land factory
    bool g_frontRaiderOpenerDone = false;

    // One-time scout rush state for the very first T1 land factory (bot or vehicle)
    bool g_frontScoutRushFinished = false;
    int g_frontScoutRushFactoryId = -1;

    // Attempt to enqueue a scout for the one-time scout rush from the first T1 land factory.
    // Returns a task if a scout was enqueued, otherwise null.
    IUnitTask@ Front_TryScoutRush(CCircuitUnit@ u, const string &in factoryName, const string &in side)
    {
        if (u is null) return null;
        if (g_frontScoutRushFinished) return null;
        if (!UnitHelpers::IsT1BotLab(factoryName) && !UnitHelpers::IsT1VehicleLab(factoryName)) return null;

        // Lock to the first T1 land factory encountered
        if (g_frontScoutRushFactoryId == -1) {
            g_frontScoutRushFactoryId = u.id;
            GenericHelpers::LogUtil("[FRONT] ScoutRush locked to factory id=" + g_frontScoutRushFactoryId + " (" + factoryName + ")", 2);
        }
        if (u.id != g_frontScoutRushFactoryId) return null; // only the locked factory performs the rush

        int target = Global::RoleSettings::Front::ScoutRushCount;
        if (target <= 0) { g_frontScoutRushFinished = true; return null; }

        string scoutName = UnitHelpers::GetFrontT1ScoutForFactory(factoryName, side);
        if (scoutName == "") { g_frontScoutRushFinished = true; return null; }

        CCircuitDef@ sdef = ai.GetCircuitDef(scoutName);
        if (sdef is null || !sdef.IsAvailable(ai.frame)) {
            // If unavailable, complete rush to avoid perpetual attempts
            g_frontScoutRushFinished = true;
            return null;
        }

        const AIFloat3 pos = u.GetPos(ai.frame);
        IUnitTask@ last = null;
        for (int i = 0; i < target; ++i) {
            @last = aiFactoryMgr.Enqueue(
                TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, sdef, pos, 64.f)
            );
        }
        g_frontScoutRushFinished = true;
        GenericHelpers::LogUtil("[FRONT] ScoutRush enqueued count=" + target, 2);
        return last;
    }

    // One-time T1 raider-style opener: enqueue a batch of cheap land raider units
    // from the first suitable T1 land factory after constructor enforcement.
    IUnitTask@ Front_TryT1RaiderOpener(CCircuitUnit@ u, const string &in factoryName, const string &in side)
    {
        if (u is null) return null;
        if (g_frontRaiderOpenerDone) return null;
        if (!UnitHelpers::IsT1BotLab(factoryName) && !UnitHelpers::IsT1VehicleLab(factoryName)) return null;

        string raiderName = UnitHelpers::GetFrontT1RaiderForFactory(factoryName, side);
        if (raiderName == "") {
            g_frontRaiderOpenerDone = true;
            return null;
        }

        CCircuitDef@ pdef = ai.GetCircuitDef(raiderName);
        if (pdef is null || !pdef.IsAvailable(ai.frame)) {
            g_frontRaiderOpenerDone = true;
            return null;
        }

        const AIFloat3 pos = u.GetPos(ai.frame);
        IUnitTask@ last = null;
        const int count = Global::RoleSettings::Front::RaiderOpenerCount;
        for (int i = 0; i < count; ++i) {
            @last = aiFactoryMgr.Enqueue(
                TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, pdef, pos, 64.f)
            );
        }
        g_frontRaiderOpenerDone = true;
        GenericHelpers::LogUtil("[FRONT] T1 raider opener enqueued count=" + count + " unit=" + raiderName, 2);
        return last;
    }

    // Ensure labs recruit a minimum number of constructors
    // - T1 Bot Lab: at least MinT1BotConstructorCount T1 bot constructors (ck)
    // - T1 Vehicle Plant: at least MinT1VehicleConstructorCount T1 vehicle constructors (cv)
    // - T2 Bot Lab: maintain at least MinT2BotConstructorCount T2 bot constructors
    // - T2 Vehicle Plant: maintain at least MinT2VehicleConstructorCount T2 vehicle constructors
    IUnitTask@ Front_FactoryAiMakeTask(CCircuitUnit@ u)
    {
        if (u is null) return aiFactoryMgr.DefaultMakeTask(u);
        const CCircuitDef@ facDef = u.circuitDef;
        if (facDef is null) return aiFactoryMgr.DefaultMakeTask(u);

        string factoryName = facDef.GetName();
        string side = UnitHelpers::GetSideForUnitName(factoryName);

        // T1 Bot Lab enforcement
        if (UnitHelpers::IsT1BotLab(factoryName)) {
            array<string> botConstructorNames = UnitHelpers::GetT1BotConstructors(side);
            if (botConstructorNames.length() > 0) {
                string botConstructorName = botConstructorNames[0];
                int existingBotConstructors = UnitDefHelpers::GetUnitDefCount(botConstructorName);
                if (existingBotConstructors < Global::RoleSettings::Front::MinT1BotConstructorCount) {
                    CCircuitDef@ ctorDef = ai.GetCircuitDef(botConstructorName);
                    if (ctorDef !is null && ctorDef.IsAvailable(ai.frame)) {
                        const AIFloat3 pos = u.GetPos(ai.frame);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, ctorDef, pos, 64.f)
                        );
                    }
                }
            }

            // After constructor enforcement, try one-time scout rush for T1 bot lab
            IUnitTask@ rushTask = Front_TryScoutRush(u, factoryName, side);
            if (rushTask !is null) return rushTask;

            // After scout rush, try one-time T1 raider opener for T1 bot lab
            IUnitTask@ raiderTask = Front_TryT1RaiderOpener(u, factoryName, side);
            if (raiderTask !is null) return raiderTask;
        }

        // T1 Vehicle Plant enforcement
        if (UnitHelpers::IsT1VehicleLab(factoryName)) {
            array<string> vehicleConstructorNames = UnitHelpers::GetT1VehicleConstructors(side);
            if (vehicleConstructorNames.length() > 0) {
                string vehicleConstructorName = vehicleConstructorNames[0];
                int existingVehicleConstructors = UnitDefHelpers::GetUnitDefCount(vehicleConstructorName);
                if (existingVehicleConstructors < Global::RoleSettings::Front::MinT1VehicleConstructorCount) {
                    CCircuitDef@ vdef = ai.GetCircuitDef(vehicleConstructorName);
                    if (vdef !is null && vdef.IsAvailable(ai.frame)) {
                        const AIFloat3 pos2 = u.GetPos(ai.frame);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, vdef, pos2, 64.f)
                        );
                    }
                }
            }

            // After constructor enforcement, try one-time scout rush for T1 vehicle plant
            IUnitTask@ rushTask2 = Front_TryScoutRush(u, factoryName, side);
            if (rushTask2 !is null) return rushTask2;

            // After scout rush, try one-time T1 raider opener for T1 vehicle plant
            IUnitTask@ raiderTask2 = Front_TryT1RaiderOpener(u, factoryName, side);
            if (raiderTask2 !is null) return raiderTask2;
        }

        // T2 Bot Lab enforcement (Front-specific minimum T2 bot constructors)
        if (UnitHelpers::IsT2BotLab(factoryName)) {
            int t2CtorCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
            if (t2CtorCount < Global::RoleSettings::Front::MinT2BotConstructorCount) {
                array<string> t2BotCtors = UnitHelpers::GetT2BotConstructors(side);
                if (t2BotCtors.length() > 0) {
                    CCircuitDef@ t2Ctor = ai.GetCircuitDef(t2BotCtors[0]);
                    if (t2Ctor !is null && t2Ctor.IsAvailable(ai.frame)) {
                        const AIFloat3 pos3 = u.GetPos(ai.frame);
                        GenericHelpers::LogUtil("[FRONT][Factory] T2 bot ctor below target (" + t2CtorCount + "), enqueue '" + t2BotCtors[0] + "'", 3);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, t2Ctor, pos3, 64.f)
                        );
                    }
                }
            }
        }

        // T2 Vehicle Plant enforcement (Front-specific minimum T2 vehicle constructors)
        if (UnitHelpers::IsT2VehicleLab(factoryName) && Global::RoleSettings::Front::MinT2VehicleConstructorCount > 0) {
            int t2VehCtorCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2VehicleConstructors());
            if (t2VehCtorCount < Global::RoleSettings::Front::MinT2VehicleConstructorCount) {
                array<string> t2VehCtors = UnitHelpers::GetT2VehicleConstructors(side);
                if (t2VehCtors.length() > 0) {
                    CCircuitDef@ t2Veh = ai.GetCircuitDef(t2VehCtors[0]);
                    if (t2Veh !is null && t2Veh.IsAvailable(ai.frame)) {
                        const AIFloat3 pos4 = u.GetPos(ai.frame);
                        GenericHelpers::LogUtil("[FRONT][Factory] T2 vehicle ctor below target (" + t2VehCtorCount + "), enqueue '" + t2VehCtors[0] + "'", 3);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, t2Veh, pos4, 64.f)
                        );
                    }
                }
            }
        }

        // After constructor guarantees (T1/T2) and optional scout rushes, prefer dynamic factory
        // production for all factories (T1/T2 labs, air, gantries, etc.) when enabled.
        if (Global::RoleSettings::Front::UseDynamicFactoryProduction) {
            IUnitTask@ dynTask = FactoryProduction::MakeTask(u);
            if (dynTask !is null) {
                return dynTask;
            }
            GenericHelpers::LogUtil("[FRONT] Dynamic factory production returned null for '" + factoryName + "', using default", 3);
        }

        // Fall back to default when no rule triggers
        return aiFactoryMgr.DefaultMakeTask(u);
    }

    string Front_SelectFactoryHandler(const AIFloat3& in pos, bool isStart, bool isReset) {
        if(isStart) {
            if(Global::Map::NearestMapStartPosition !is null) {
                return FactoryHelpers::SelectStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
            } else {
                GenericHelpers::LogUtil("[Front_SelectFactoryHandler] nearestMapPosition is null", 2);
                return FactoryHelpers::GetFallbackStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
            }
        }
   
        return "";
    }

    // Factory unit lifecycle hooks (Front role)
    void Front_FactoryAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        if (unit is null) {
            GenericHelpers::LogUtil("[FRONT] FactoryAiUnitAdded: unit=<null>", 2);
            return;
        }

        if (usage != Unit::UseAs::FACTORY)
		return;

        const CCircuitDef@ facDef = unit.circuitDef;
        string factoryName = (facDef is null ? "" : facDef.GetName());

        // If we build a vehicle lab at any point, switch to vehicle thresholds
        if (!g_frontVehicleThresholdsApplied && factoryName != "" && UnitHelpers::IsT1VehicleLab(factoryName)) {
            aiMilitaryMgr.quota.scout = Global::RoleSettings::Front::MilitaryScoutCapVehicles;
            aiMilitaryMgr.quota.attack = Global::RoleSettings::Front::MilitaryAttackThresholdVehicles;
            aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Front::MilitaryRaidMinPowerVehicles;
            aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Front::MilitaryRaidAvgPowerVehicles;
            g_frontVehicleThresholdsApplied = true;
            GenericHelpers::LogUtil("[FRONT] Vehicle lab built; applied vehicle raid/attack thresholds", 2);
        }
        if (Factory::userData[facDef.id].attr & Factory::Attr::T3 != 0) {
            array<string> spam = {"armpw", "corak", "armflea", "armfav", "corfav"};
            for (uint i = 0; i < spam.length(); ++i)
                ai.GetCircuitDef(spam[i]).SetIgnore(true);
        }

        GenericHelpers::LogUtil("[FRONT] FactoryAiUnitAdded id=" + unit.id + " usage=" + usage, 3);
        // Note: Factory registration and preferred anchors are centralized in Factory manager.
        // Front role currently has no additional per-factory behavior here.
    }

    void Front_FactoryAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        //GenericHelpers::LogUtil("[FRONT] FactoryAiUnitRemoved id=" + (unit is null ? -1 : unit.id) + " usage=" + usage, 3);
        // No Front-specific cleanup required; Factory manager handles primary/anchor clearing.
    }

    bool Front_AiIsSwitchTime(int lastSwitchFrame) {
        int interval = (30 * SECOND);
        return (lastSwitchFrame + interval) <= ai.frame;
    }

    bool Front_AiIsSwitchAllowed(const CCircuitDef@ facDef, float armyCost, int factoryCount, float metalCurrent, bool &out assistRequired) {
        const bool isOK = (armyCost > Global::RoleSettings::Front::SwitchFactoryCostMultiplier * facDef.costM * float(factoryCount)) || (metalCurrent > facDef.costM);
        assistRequired = !isOK;
        return isOK;
    }

    int Front_MakeSwitchInterval() {
        return AiRandom(Global::RoleSettings::Front::MinAiSwitchTime, Global::RoleSettings::Front::MaxAiSwitchTime) * SECOND;
    }

    /******************************************************************************

    MILITARY HOOKS

    ******************************************************************************/
    
    // Counter for scout assignment
    int g_frontScoutAssignmentCount = 0;

    void Front_MilitaryAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage) {
        if (unit is null) return;
        
        // Only apply to the first N units
        if (g_frontScoutAssignmentCount >= Global::RoleSettings::Front::ScoutAssignmentLimit) return;

        string name = unit.circuitDef.GetName();
        if (name == "armpw" || name == "corak" || name == "leggob") {
            // Assign SCOUT attribute (workaround as AddRole is not available on instances)
            // We use the attribute masker to get/create a "scout" attribute ID.
            unit.AddAttribute(aiAttrMasker.GetTypeMask("scout").type);
            g_frontScoutAssignmentCount++;
            GenericHelpers::LogUtil("[FRONT] Assigned SCOUT attribute to " + name + " (" + g_frontScoutAssignmentCount + "/" + Global::RoleSettings::Front::ScoutAssignmentLimit + ")", 2);
        }
    }

    /******************************************************************************

    BUILDER HOOKS

    ******************************************************************************/ 

    IUnitTask@ Front_BuilderAiMakeTask(CCircuitUnit@ builder) {
        GenericHelpers::LogUtil("[Front_BuilderAiMakeTask] called for builder", 3);
        if (builder is null) return null; // Defensive check

        // Pre-create and cache a single default task instance; never recreate.
        IUnitTask@ defaultTask = Builder::MakeDefaultTaskWithLog(builder.id, "FRONT");

        const CCircuitDef@ udef = builder.circuitDef;
        if (udef is null) return defaultTask;

        // Early return: if the default task represents a resource expansion (MEX/GEO variants), keep it.
        IBuilderTask@ defaultBuilderTask = cast<IBuilderTask>(defaultTask);
        if (defaultBuilderTask !is null) {
            Task::BuildType dbt = Task::BuildType(defaultBuilderTask.GetBuildType());
            if (dbt == Task::BuildType::MEX || dbt == Task::BuildType::MEXUP ||
                dbt == Task::BuildType::GEO || dbt == Task::BuildType::GEOUP ||
                dbt == Task::BuildType::ENERGY) {
                GenericHelpers::LogUtil("[FRONT] defaultTask is MEX/MEXUP/GEO/GEOUP/ENERGY; returning early", 3);
                return defaultTask;
            }

            // If the default task is a radar but we're low on stored energy (<90% of storage)
            // and recent energy income is also low (<200 over last 10 seconds), prefer building
            // a solar collector instead to stabilize the grid.
            if (dbt == Task::BuildType::RADAR) {
                float energyCurrent = aiEconomyMgr.energy.current;
                float energyStorage = aiEconomyMgr.energy.storage;
                float energyIncomeMin10s = Economy::GetMinEnergyIncomeLast10s();
                if (energyStorage > 0.0f
                    && energyCurrent < energyStorage * 0.9f
                    && energyIncomeMin10s < 200.0f) {
                    string unitSide = Global::AISettings::Side;
                    IUnitTask@ solarTask = Builder::EnqueueT1Solar(
                        builder.id,
                        unitSide,
                        builder.GetPos(ai.frame),
                        /*shake*/ SQUARE_SIZE * 16,
                        /*timeout*/ 60 * SECOND
                    );
                    if (solarTask !is null) {
                        GenericHelpers::LogUtil("[FRONT] Overriding RADAR defaultTask with T1 solar (energy < 90% storage and income < 200)", 3);
                        return solarTask;
                    }
                }
            }
        }

        // Commander-specific logic: delegate to commander builder logic when applicable.
        bool isCommander = UnitHelpers::IsCommander(udef);
        if (isCommander) {
            return Front_Commander_AiMakeTask(builder, defaultTask);
        }

        // Route T1 land constructors (bot or vehicle) to FRONT logic; others fallback
        int ctorTier = UnitHelpers::GetConstructorTier(udef);
        if (ctorTier == 1) {
            // The first T2 plant of each kind: every T1 constructor, not only the
            // primary / secondary ones routed below (Front_TryFirstT2Plant)
            {
                IUnitTask@ tFirstT2 = Front_TryFirstT2Plant(builder, UnitHelpers::GetSideForUnitName(udef.GetName()), Economy::GetMinMetalIncomeLast10s());
                if (tFirstT2 !is null) return tFirstT2;
            }
            if (builder is Builder::primaryT1BotConstructor || builder is Builder::secondaryT1BotConstructor
             || builder is Builder::primaryT1VehConstructor || builder is Builder::secondaryT1VehConstructor) {
                // Use same economy snapshot style as T2: min over last 10s for incomes
                bool isEnergyFull = aiEconomyMgr.isEnergyFull;
                bool isEnergyStalling = aiEconomyMgr.isEnergyStalling;
                float metalIncome = Economy::GetMinMetalIncomeLast10s();
                float energyIncome = Economy::GetMinEnergyIncomeLast10s();
                return Front_T1Constructor_AiMakeTask(builder, defaultTask, metalIncome, energyIncome, isEnergyStalling, isEnergyFull);
            }
        } else if (ctorTier == 2) {
            // Mirror TECH role routing: handle primary/secondary T2 bot constructors explicitly
            bool isEnergyFull = aiEconomyMgr.isEnergyFull;
            float metalIncome = Economy::GetMinMetalIncomeLast10s();
            float energyIncome = Economy::GetMinEnergyIncomeLast10s();
            float metalCurrent = aiEconomyMgr.metal.current;
            bool isEnergyLessThan90Percent = aiEconomyMgr.energy.current < aiEconomyMgr.energy.storage * Global::RoleSettings::Front::EnergyStorageLowPercent;
            if (builder is Builder::primaryT2BotConstructor || builder is Builder::secondaryT2BotConstructor || builder is Builder::freelanceT2BotConstructor) {
                return Front_T2Constructor_AiMakeTask(builder, defaultTask, isEnergyFull, metalIncome, energyIncome, metalCurrent, isEnergyLessThan90Percent);
            }
        }
        // Fallback to cached default task
        return defaultTask;
    }

    /******************************************************************************

    BUILDER LOGIC (COMMANDER)

    ******************************************************************************/ 

    // For the first 2 minutes of the game, keep the commander assigned to guard
    // the primary T1 bot lab or primary T1 vehicle plant (if present).
    IUnitTask@ Front_Commander_AiMakeTask(CCircuitUnit@ comm, IUnitTask@ defaultTask)
    {
        if (comm is null) return defaultTask;

        // 2 minutes in frames: 2 * 60 * SECOND
        const int FRONT_COMMANDER_GUARD_DEADLINE = 2 * 60 * SECOND;
        if (ai.frame > FRONT_COMMANDER_GUARD_DEADLINE) {
            // After the early window, fall back to default behavior
            return defaultTask;
        }

        // Prefer guarding the primary T1 bot lab; otherwise guard the primary T1 vehicle plant.
        CCircuitUnit@ target = null;
        if (Factory::primaryT1BotLab !is null) {
            @target = Factory::primaryT1BotLab;
        } else if (Factory::primaryT1VehPlant !is null) {
            @target = Factory::primaryT1VehPlant;
        }

        if (target is null) {
            // No suitable factory yet; let normal builder/commander logic handle this frame
            return defaultTask;
        }

        // Assign a high-priority guard task so the commander sticks near the frontline factory
        IUnitTask@ guardTask = GuardHelpers::AssignWorkerGuard(
            comm,
            target,
            Task::Priority::HIGH,
            true,
            10 * SECOND // guard duration; can be renewed while within deadline
        );

        return (guardTask !is null ? guardTask : defaultTask);
    }

    CCircuitUnit@ energizer1 = null;
	CCircuitUnit@ energizer2 = null;

    void Front_BuilderAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		//LogUtil("BUILDER::AiUnitAdded:" + unit.circuitDef, 2);
		const CCircuitDef@ cdef = unit.circuitDef;
		if (usage != Unit::UseAs::BUILDER || cdef.IsRoleAny(Unit::Role::COMM.mask))
			return;

		// constructor with BASE attribute is assigned to tasks near base
		if (cdef.costM < Global::RoleSettings::Front::BuilderCostThresholdForBase) {
			if (energizer1 is null
				&& (uint(cdef.count) > aiMilitaryMgr.GetGuardTaskNum() || cdef.IsAbleToFly()))
			{
				@energizer1 = unit;
				unit.AddAttribute(Unit::Attr::BASE.type);
			}
		} else {
			if (energizer2 is null) {
				@energizer2 = unit;
				unit.AddAttribute(Unit::Attr::BASE.type);
			}
		}

	}

    void Front_BuilderAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		if (energizer1 is unit)
			@energizer1 = null;
		else if (energizer2 is unit)
			@energizer2 = null;
	}

    void Front_BuilderAiTaskAdded(IUnitTask@ task) {
        GenericHelpers::LogUtil("[Front_BuilderAiTaskAdded] called for task", 3);
    }

    void Front_BuilderAiTaskRemoved(IUnitTask@ task, bool done) {

    }

    /******************************************************************************

    ECONOMY LOGIC

    ******************************************************************************/ 

    void Front_IncomeLimits(float metalIncome, float energyIncome) {
        // Determine cap: 35 metal income per lab (e.g., 70 -> 2 labs)
        int cap = int(metalIncome / Global::RoleSettings::Front::MetalIncomePerLab);

        // Scale Tier 2 bot/vehicle lab caps by economy: 35 metal income per lab
        Front_IncomeLabLimits(metalIncome);
        Front_IncomeBuilderLimits(metalIncome);
        Front_IncomeNanoLimits(energyIncome);

        //Always apply map limits, regardless of how eco changes labs limits
        dictionary mapLimits = Global::Map::Config.UnitLimits;
        UnitHelpers::ApplyUnitLimits(mapLimits);
    }

    void Front_IncomeLabLimits(float metalIncome) {
        // Apply hard caps for T2 labs from global settings
        int maxT2Bot = Global::RoleSettings::Front::MaxT2BotLabs;
        int maxT2Veh = Global::RoleSettings::Front::MaxT2VehicleLabs;

        string side = Global::AISettings::Side;
        
        // T2 Bot Labs
        array<string> t2BotLabs = UnitHelpers::GetT2BotLabs(side);
        UnitHelpers::BatchApplyUnitCaps(t2BotLabs, maxT2Bot);

        // T2 Vehicle Labs
        array<string> t2VehLabs = UnitHelpers::GetT2VehicleLabs(side);
        UnitHelpers::BatchApplyUnitCaps(t2VehLabs, maxT2Veh);

        // Gantries
        array<string> gantries = UnitHelpers::GetAllGantries();
        int gantryCap = (metalIncome >= Global::RoleSettings::Front::MetalIncomeForGantry) ? 1 : 0;
        // Gantries added on maxed metal (manager/build_power.as) stay allowed.
        const int buildPowerGantries = BuildPower::GantryCapFloor();
        if (gantryCap < buildPowerGantries) gantryCap = buildPowerGantries;
        UnitHelpers::BatchApplyUnitCaps(gantries, gantryCap);
    }

    void Front_IncomeBuilderLimits(float metalIncome) {
        // Determine cap: 35 metal income per lab (e.g., 70 -> 2 labs)
        int t1BuilderCap = 5 * int(metalIncome / Global::RoleSettings::Front::MetalIncomePerT1Builder);
        if (t1BuilderCap < Global::RoleSettings::Front::MinBuilderCap) t1BuilderCap = Global::RoleSettings::Front::MinBuilderCap;

        string side = Global::AISettings::Side;
        
        // T1 Builders
        array<string> t1Builders = UnitHelpers::GetT1LandBuilders(side);
        UnitHelpers::BatchApplyUnitCaps(t1Builders, t1BuilderCap);

        // T2 Builder Cap Logic
        int t2BuilderCap = 5 * int(metalIncome / Global::RoleSettings::Front::MetalIncomePerT2Builder);
        if (t2BuilderCap < Global::RoleSettings::Front::MinBuilderCap) t2BuilderCap = Global::RoleSettings::Front::MinBuilderCap;

        // T2 Builders
        array<string> t2Builders = UnitHelpers::GetT2LandBuilders(side);
        UnitHelpers::BatchApplyUnitCaps(t2Builders, t2BuilderCap);
    }

    void Front_IncomeNanoLimits(float energyIncome) {
        int nanoCap = int(energyIncome / Global::RoleSettings::Front::NanoEnergyPerUnit);
        
        if (nanoCap < Global::RoleSettings::Front::NanoMinCount) {
            nanoCap = Global::RoleSettings::Front::NanoMinCount;
        }

        if (energyIncome > Global::RoleSettings::Front::NanoEnergyIncomeThresholdForMax) {
            nanoCap = Global::RoleSettings::Front::NanoMaxCount;
        }
        // Turrets queued on capped metal (manager/build_power.as) stay buildable.
        const int buildPowerFloor = BuildPower::NanoCapFloor();
        if (nanoCap < buildPowerFloor) nanoCap = buildPowerFloor;
        array<string> nanos = UnitHelpers::GetT1NanoUnitNames();
        UnitHelpers::BatchApplyUnitCaps(nanos, nanoCap);
    }

    /******************************************************************************

    BUILDER LOGIC

    ******************************************************************************/ 

    // Helper to attempt building a T1 nano caretaker
    IUnitTask@ Front_TryBuildNano(float metalIncome) {
        float energyPercent = (aiEconomyMgr.energy.storage > 0.0f)
            ? (aiEconomyMgr.energy.current / aiEconomyMgr.energy.storage)
            : 0.0f;

        // Primary condition: reserves-based gate (legacy behavior).
        bool allowByReserves = EconomyHelpers::ShouldBuildT1Nano_ByReserves(
            /*metalCurrent*/ aiEconomyMgr.metal.current,
            /*buildWhenOverMetal*/ Global::RoleSettings::Front::NanoBuildWhenOverMetal,
            /*energyPercent*/ energyPercent
        );

        // Secondary condition: early construction turret allowance when
        // income is above a small threshold but we have no nanos yet.
        // This lets us get the first nano online without needing a big
        // metal stockpile, while still preventing early over-spam.
        int existingNanos = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetT1NanoUnitNames());
        bool allowFirstNanoByIncome = (metalIncome > Global::RoleSettings::Front::NanoMinIncomeForFirst && existingNanos < 1);

        if (allowByReserves || allowFirstNanoByIncome) {
            CCircuitUnit@ targetFactory = Factory::SelectFactoryNeedingNano();
            if (targetFactory !is null) {
                IUnitTask@ tNano = Factory::EnqueueNanoForFactory(targetFactory, Task::Priority::HIGH);
                if (tNano !is null) return tNano;
            }
        }
        return null;
    }

    // The first T2 plant's bank trigger: T2LabStoredMetalThresholdRatio of its
    // cost, or FirstT2StoredStorageRatio of our metal storage when that is
    // smaller, at FirstT2StoredMinMetalIncome or more. Played (team 15, All That
    // Glitters 2026-09-28): storage ~1,900 against 2,340 for an armavp, so the
    // bank trigger could never fire, whatever TECH shared.
    bool Front_BankPaysFirstT2(CCircuitDef@ d, float metalIncome)
    {
        if (d is null || metalIncome < Global::RoleSettings::Front::FirstT2StoredMinMetalIncome) return false;
        float need = d.costM * Global::RoleSettings::Front::T2LabStoredMetalThresholdRatio;
        const float byStorage = aiEconomyMgr.metal.storage * Global::RoleSettings::Front::FirstT2StoredStorageRatio;
        if (byStorage > 0.0f && byStorage < need) need = byStorage;
        return aiEconomyMgr.metal.current >= need;
    }

    // Fast-track to the first T2 plant of a kind, for ANY T1 constructor that
    // can build it (was the primary bot / vehicle constructor only: dead or busy,
    // nothing tried). A bot constructor starts the T2 bot lab, a vehicle
    // constructor the T2 vehicle plant, when none of that kind stands or is
    // ordered and any trigger is met (OR): metal income, game time
    // (TimeTriggerForFirstT2LabSeconds), or the bank (Front_BankPaysFirstT2).
    IUnitTask@ Front_TryFirstT2Plant(CCircuitUnit@ u, const string &in unitSide, float metalIncome)
    {
        const bool timeMet = (ai.frame >= (Global::RoleSettings::Front::TimeTriggerForFirstT2LabSeconds * SECOND));
        {
            CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(unitSide));
            if (d !is null && u.circuitDef.CanBuild(d)
                && UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs()) < 1
                && aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY), d) == 0) {
                const bool incomeMet = (metalIncome >= Global::RoleSettings::Front::MinimumMetalIncomeForFirstT2Lab);
                const bool bankMet = Front_BankPaysFirstT2(d, metalIncome);
                if (incomeMet || timeMet || bankMet) {
                    IUnitTask@ t = Builder::EnqueueT2BotLabIfNeeded(unitSide, Factory::GetT1BotLabPos(), SQUARE_SIZE * 30, SECOND * 300);
                    if (t !is null) {
                        GenericHelpers::LogUtil("[FRONT] first T2 bot lab " + d.GetName() + " by " + u.circuitDef.GetName() + " " + u.id
                            + " (" + (incomeMet ? "income" : (timeMet ? "time" : "bank")) + ": +" + int(metalIncome) + " metal, bank "
                            + int(aiEconomyMgr.metal.current) + " of " + int(aiEconomyMgr.metal.storage) + ")", 1);
                        return t;
                    }
                }
            }
        }
        {
            const string vehName = (unitSide == "cortex") ? "coravp" : ((unitSide == "legion") ? "legavp" : "armavp");
            CCircuitDef@ d = ai.GetCircuitDef(vehName);
            if (d !is null && u.circuitDef.CanBuild(d)
                && UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2VehicleLabs()) < 1
                && aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY), d) == 0) {
                const bool incomeMet = (metalIncome >= Global::RoleSettings::Front::MinimumMetalIncomeForFirstT2VehiclePlant);
                const bool bankMet = Front_BankPaysFirstT2(d, metalIncome);
                if (incomeMet || timeMet || bankMet) {
                    IUnitTask@ t = Builder::EnqueueT2VehiclePlant(unitSide, Factory::GetPreferredFactoryPos(), SQUARE_SIZE * 24, 600 * SECOND);
                    if (t !is null) {
                        GenericHelpers::LogUtil("[FRONT] first T2 vehicle plant " + d.GetName() + " by " + u.circuitDef.GetName() + " " + u.id
                            + " (" + (incomeMet ? "income" : (timeMet ? "time" : "bank")) + ": +" + int(metalIncome) + " metal, bank "
                            + int(aiEconomyMgr.metal.current) + " of " + int(aiEconomyMgr.metal.storage) + ")", 1);
                        return t;
                    }
                }
            }
        }
        return null;
    }

    IUnitTask@ Front_T1Constructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, float metalIncome, float energyIncome, bool isEnergyStalling, bool isEnergyFull) {
        // Econ snapshot is passed by caller (min over last 10s for incomes)

        AIFloat3 conLocation = u.GetPos(ai.frame);
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // Primary constructor branch (Bots)
        if (u is Builder::primaryT1BotConstructor) {
            int t2ConstructionBotCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
            int t2LabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs());

            // The first T2 bot lab's fast-track is Front_TryFirstT2Plant, above, for any T1 constructor.

            // Transition to vehicles if metal income > threshold and no vehicle plant
            int t1VehLabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1VehicleLabs());
            if (metalIncome > Global::RoleSettings::Front::MinimumMetalIncomeForT1FactoryTransition && t1VehLabCount < 1) {
                AIFloat3 pos = Factory::GetPreferredFactoryPos();
                IUnitTask@ tVeh = Builder::EnqueueT1VehiclePlant(unitSide, pos, SQUARE_SIZE * 24, 600 * SECOND);
                if (tVeh !is null) return tVeh;
            }

            // Try T2 lab if eco allows
            bool shouldT2Lab = EconomyHelpers::ShouldBuildT2BotLab(
                /*mi*/ metalIncome,
                /*ei*/ energyIncome,
                /*metalCurrent*/ aiEconomyMgr.metal.current,
                /*requiredMetalIncome*/ Global::RoleSettings::Front::MinimumMetalIncomeForT2Lab,
                /*requiredMetalCurrent*/ Global::RoleSettings::Front::RequiredMetalCurrentForT2Lab,
                /*requiredEnergyIncome*/ Global::RoleSettings::Front::MinimumEnergyIncomeForT2Lab,
                /*constructorDef*/ u.circuitDef,
                /*t2BotLabCount*/ t2LabCount,
                /*maxAllowed*/ Global::RoleSettings::Front::MaxT2BotLabs,
                /*hasPrimaryFactory*/ (Factory::primaryT1BotLab !is null)
            );

            if (shouldT2Lab) {
                // Place near our T1 Bot Lab (or commander fallback via Factory)
                AIFloat3 anchor = Factory::GetT1BotLabPos();
                IUnitTask@ tLab = Builder::EnqueueT2BotLabIfNeeded(unitSide, anchor, SQUARE_SIZE * 30, SECOND * 300);
                if (tLab !is null) return tLab;
            }

            // After T2 lab attempt: build a T1 nano caretaker when either reserves allow
            // it or we're early-game with sufficient income and zero existing nanos.
            // Route through centralized per-factory nano selection and enqueue helpers.
            IUnitTask@ tNano = Front_TryBuildNano(metalIncome);
            if (tNano !is null) return tNano;

        }

        // Primary constructor branch (Vehicles)
        if (u is Builder::primaryT1VehConstructor) {
            // The first T2 vehicle plant's fast-track is Front_TryFirstT2Plant, above, for any T1 constructor.

            // Transition to bots if metal income > threshold and no bot lab
            int t1BotLabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1BotLabs());
            if (metalIncome > Global::RoleSettings::Front::MinimumMetalIncomeForT1FactoryTransition && t1BotLabCount < 1) {
                AIFloat3 pos = Factory::GetPreferredFactoryPos();
                IUnitTask@ tBot = Builder::EnqueueT1BotLab(unitSide, pos, SQUARE_SIZE * 24, 600 * SECOND);
                if (tBot !is null) return tBot;
            }
            
            // Try building nano
            IUnitTask@ tNano = Front_TryBuildNano(metalIncome);
            if (tNano !is null) return tNano;

            // No special vehicle-only eco tasks for now; default
            return defaultTask;
        }

        return defaultTask;
    }

    IUnitTask@ Front_T2Constructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, bool isEnergyFull, float metalIncome, float energyIncome, float metalCurrent, bool isEnergyLessThan90Percent) {
        // Copy of TECH T2 constructor logic with Front-specific gating:
        // - Before 20 minutes of game time, force eco: only build energy converter/AFUS/FUS (skip gantry/nuke/anti-nuke)
        // - After 20 minutes, allow full TECH-style sequence (gantry, nuke, anti-nuke, etc.)

        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // Freelance T2 constructors just do default tasks
        if (u is Builder::freelanceT2BotConstructor) {
            return defaultTask;
        }

        const bool isPrimary = (u is Builder::primaryT2BotConstructor || u is Builder::primaryT2VehConstructor);
        const bool isSecondary = (u is Builder::secondaryT2BotConstructor);

        AIFloat3 anchor = Global::Map::StartPos;

        // Eco gating: force economy builds for the first 20 minutes
        const bool forceEco = (ai.frame < (Global::RoleSettings::Front::TimeTriggerForT2EcoGatingSeconds * SECOND));

        if (isPrimary) {
            // Fusion Reactor
            if (EconomyHelpers::ShouldBuildFusionReactor(
                /*mi*/ metalIncome,
                /*ei*/ energyIncome,
                /*energy<90%*/ isEnergyLessThan90Percent,
                /*reqMi*/ Global::RoleSettings::Front::MinimumMetalIncomeForFUS,
                /*reqEi*/ Global::RoleSettings::Front::MinimumEnergyIncomeForFUS,
                /*maxEi*/ Global::RoleSettings::Front::MaxEnergyIncomeForFUS
            )) {
                IUnitTask@ tFus2 = Builder::EnqueueFUS(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 300);
                if (tFus2 !is null) return tFus2;
            }
        } 

        return defaultTask;
    }

    /******************************************************************************

    ROLE CONFIGURATION

    ******************************************************************************/

    bool Front_RoleMatch(AiRole preferredMapRole, const string &in side, const AIFloat3& in pos, const string &in defaultStartFactory) {
        bool match = false;

        if (preferredMapRole == AiRole::FRONT) match = true;
       
        if (match) { 
            GenericHelpers::LogUtil("[RoleMatch] FRONT", 2); 
        }

        return match;
    }

    /******************************************************************************

    PORC CHAIN (PorcChainHandler)

    FRONT was being rushed by human players early and its defences collapsed.
    The default land order spends a defence point's budget (amountFactor 32-48 x
    income, ~960-2400 metal at +30 to +50) on a Sentry, an AA, two or three
    Beamers and then a 440-480 metal HLT; the Dragon's Claw / Maw are not in the
    order at all, and Legion's Dragon's Jaw is only its 14th, 24th and 25th entry,
    so Legion opened on Hives (7500 energy each).

    FRONT's land chain now opens on the mid-tier pieces that income can buy: the
    first six default entries (LLT, AA, HLLT, HLLT, HLT, HLLT) become eight, cumulative
    metal in brackets:
      Armada  Sentry, Beamer, Dragon's Claw, AA, Beamer, Beamer, Dragon's Claw, HLT  (1855)
      Cortex  Guard, Twin Guard, Dragon's Maw, AA, Twin Guard, Twin Guard, Dragon's Maw, HLT  (1815)
      Legion  LLT, Dragon's Jaw, AA, LLT, Dragon's Jaw, Dragon's Jaw, Hive, Cacophony  (1810)
    then the default order carries on (AA, Juno, ...). Water chain unchanged.

    ******************************************************************************/
    dictionary FrontPorcOpening = {
        {"armada", array<string> = {"armllt", "armbeamer", "armclaw", "armrl", "armbeamer", "armbeamer", "armclaw", "armhlt"}},
        {"cortex", array<string> = {"corllt", "corhllt", "cormaw", "corrl", "corhllt", "corhllt", "cormaw", "corhlt"}},
        {"legion", array<string> = {"leglht", "legdtr", "legrl", "leglht", "legdtr", "legdtr", "leghive", "legmg"}}
    };
    const uint FRONT_PORC_DEFAULT_OPENING = 6;   // default land entries the opening replaces

    void Front_PorcChain(const string &in side)
    {
        array<string>@ opening = null;
        array<string>@ land = PorcHelpers::DefaultChain(side, false);
        if (!FrontPorcOpening.get(side, @opening) || opening is null || land.length() <= FRONT_PORC_DEFAULT_OPENING) {
            PorcHelpers::ApplyDefaultChains(side);
            GenericHelpers::LogUtil("[Porc] FRONT: no opening for side " + side + "; keeping the default", 2);
            return;
        }
        // A role switch re-applies the chain from the current one: drop our own
        // opening if it is already there, else the default one it replaces.
        bool ours = land.length() >= opening.length();
        for (uint i = 0; ours && i < opening.length(); ++i) {
            if (land[i] != opening[i]) ours = false;
        }
        const uint skip = ours ? opening.length() : FRONT_PORC_DEFAULT_OPENING;
        array<string> chain;
        for (uint i = 0; i < opening.length(); ++i) chain.insertLast(opening[i]);
        for (uint i = skip; i < land.length(); ++i) chain.insertLast(land[i]);
        aiMilitaryMgr.SetPorcChain(side, false, @chain);
        aiMilitaryMgr.SetPorcChain(side, true, PorcHelpers::DefaultChain(side, true));
        GenericHelpers::LogUtil("[Porc] FRONT: " + side + " opening set (" + opening.length() + " mid-tier entries, "
            + chain.length() + " total)", 1);
    }

    /******************************************************************************

    BASE PORC (AiMakeDefenceHandler)

    The opening above is only walked where native DefaultMakeDefence walks the
    whole order. In mode AUTO it does that only at clusters its own heuristic
    calls front line - rich clusters MORE than 1000 from the base, clusters with
    two threatened neighbours, clusters outside our influence - and every other
    cluster takes `porcupine.prevent` (1) entry: the Sentry / Guard / Pharos.
    The shared policy stays in AUTO until pressure (10 min) or the late game
    (25 min, or +120 metal and +1500 energy), so through the rush window FRONT's
    own base clusters got one LLT each and no Beamer, Twin Guard or Dragon's Jaw.

    From BasePorcFromMinutes, a cluster within BasePorcRadius of the start asks
    the shared policy for FULL, so the base walks the opening as far as the
    budget (amountFactor x income) reaches. Other clusters, and any cluster
    while energy is stalling, keep the shared policy unchanged.

    ******************************************************************************/
    void Front_AiMakeDefence(int cluster, const AIFloat3& in pos)
    {
        // Same opening gate as the handler-less path in Military::AiMakeDefence.
        if (!((ai.frame > 10 * MINUTE) || (aiEconomyMgr.metal.income > 10.f) || (aiEnemyMgr.mobileThreat > 0.f))) return;
        const AIFloat3 start = Global::Map::StartPos;
        const float dx = pos.x - start.x, dz = pos.z - start.z;
        const float r = Global::RoleSettings::Front::BasePorcRadius;
        const bool baseCluster = Global::Map::HasStart && (dx * dx + dz * dz <= r * r);
        const bool forceFull = baseCluster && !aiEconomyMgr.isEnergyStalling
            && ai.frame >= Global::RoleSettings::Front::BasePorcFromMinutes * MINUTE;
        if (forceFull && !g_frontBasePorcLogged) {
            g_frontBasePorcLogged = true;
            GenericHelpers::LogUtil("[Porc] FRONT: base cluster " + cluster + " walks the whole order (FULL) from here on, within "
                + int(r) + " of the start", 1);
        }
        Military::Porc::MakeDefence(cluster, pos, forceFull);
    }
    bool g_frontBasePorcLogged = false;

    void Register() {
        if (RoleConfigs::Get(AiRole::FRONT) !is null) return; // already
        RoleConfig@ cfg = RoleConfig(AiRole::FRONT, cast<MainUpdateDelegate@>(@Front_MainUpdate));

        @cfg.InitHandler = cast<InitDelegate@>(@Front_Init);
       
        @cfg.AiIsSwitchTimeHandler = cast<AiIsSwitchTimeDelegate@>(@Front_AiIsSwitchTime);
        @cfg.AiIsSwitchAllowedHandler = cast<AiIsSwitchAllowedDelegate@>(@Front_AiIsSwitchAllowed);
        @cfg.MakeSwitchIntervalHandler = cast<MakeSwitchIntervalDelegate@>(@Front_MakeSwitchInterval);

        @cfg.BuilderAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Front_BuilderAiMakeTask);
        @cfg.FactoryAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Front_FactoryAiMakeTask);

        @cfg.BuilderAiUnitAdded = cast<AiUnitAddedDelegate@>(@Front_BuilderAiUnitAdded);
        @cfg.BuilderAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Front_BuilderAiUnitRemoved);

        @cfg.BuilderAiTaskAddedHandler = cast<AiTaskAddedDelegate@>(@Front_BuilderAiTaskAdded);
        @cfg.BuilderAiTaskRemovedHandler = cast<AiTaskRemovedDelegate@>(@Front_BuilderAiTaskRemoved);

        @cfg.EconomyUpdateHandler = cast<EconomyUpdateDelegate@>(@Front_EconomyUpdate);
       
        @cfg.SelectFactoryHandler = cast<SelectFactoryDelegate@>(@Front_SelectFactoryHandler);
        @cfg.FactoryAiUnitAdded = cast<AiUnitAddedDelegate@>(@Front_FactoryAiUnitAdded);
        @cfg.FactoryAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Front_FactoryAiUnitRemoved);

        @cfg.MilitaryAiUnitAdded = cast<AiUnitAddedDelegate@>(@Front_MilitaryAiUnitAdded);

        @cfg.RoleMatchHandler = cast<RoleMatchDelegate@>(@Front_RoleMatch);
        @cfg.PorcChainHandler = cast<PorcChainDelegate@>(@Front_PorcChain);
        @cfg.AiMakeDefenceHandler = cast<AiMakeDefence@>(@Front_AiMakeDefence);

        RoleConfigs::Register(cfg);
    }
}