// role: TACTICAL
#include "../helpers/unit_helpers.as"
#include "../types/role_config.as"
#include "../helpers/economy_helpers.as"
#include "../global.as"
#include "../types/terrain.as"
#include "../helpers/objective_helpers.as"
#include "../helpers/objective_executor.as"
#include "../types/strategic_objectives.as"
#include "../manager/factory_production.as"
#include "../helpers/sea_constructor_helpers.as"

namespace RoleTactical {

	/******************************************************************************

	INITIALIZATION

	******************************************************************************/

	void Tactical_Init() {
		GenericHelpers::LogUtil("Tactical role initialization logic executed", 2);

		// Apply TACTICAL role settings
		aiTerrainMgr.SetAllyZoneRange(Global::RoleSettings::Tactical::AllyRange);
		// Change scout cap (unit count)
		aiMilitaryMgr.quota.scout = Global::RoleSettings::Tactical::MilitaryScoutCap;

		// Change attack gate (power threshold, not a headcount)
		aiMilitaryMgr.quota.attack = Global::RoleSettings::Tactical::MilitaryAttackThreshold;

		// Change raid thresholds (power)
		aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Tactical::MilitaryRaidMinPower; 
		aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Tactical::MilitaryRaidAvgPower; 

		Tactical_ApplyStartLimits();

		// TACTICAL-only: Set default fire state for T1 HOVER combat units to 3 (fire at everything),
		// mirroring FRONT role behavior but scoped to hover units so they aggressively shoot walls/obstacles.
		// Note: 2 = fire at will, 3 = fire at everything
		{
			array<string> t1Combat = UnitHelpers::GetAllT1HoverCombatUnits();
			for (uint i = 0; i < t1Combat.length(); ++i) {
				CCircuitDef@ d = ai.GetCircuitDef(t1Combat[i]);
				if (d is null) continue;
				d.SetFireState(3);
			}
			GenericHelpers::LogUtil("[TACTICAL] Applied default fire state=3 to T1 HOVER combat units", 3);
		}

		// Log all strategic objectives with distance from start once at init
		ObjectiveHelpers::LogAllObjectivesFromStart(AiRole::TACTICAL, "TACTICAL");

		// At init, find and log matching objectives for this role (no assignment)
		ObjectiveHelpers::LogMatchingObjectivesForRole(
			AiRole::TACTICAL,
			"TACTICAL",
			Global::AISettings::Side,
			Objectives::ConstructorClass::HOVER,
			Global::Map::StartPos,
			ai.frame,
			5
		);

		// Select initial objectives per group for tactical T1
		Tactical_SelectObjectiveForGroup(Objectives::BuilderGroup::TACTICAL);

		// Enable tactical constructor for Tactical role
		Builder::SetTacticalEnabled(true);

		// Initialize dynamic factory production system if enabled
		if (Global::RoleSettings::Tactical::UseDynamicFactoryProduction) {
			FactoryProduction::Initialize();
			GenericHelpers::LogUtil("[TACTICAL] Dynamic factory production system initialized", 2);
		} else {
			GenericHelpers::LogUtil("[TACTICAL] Dynamic factory production disabled; using legacy logic", 2);
		}
	}

	void Tactical_ApplyStartLimits() {
		// ****************** LAB LIMITS ****************** //
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1BotLabs(), Global::RoleSettings::Tactical::StartCapT1BotLabs);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2BotLabs(), Global::RoleSettings::Tactical::StartCapT2BotLabs);

		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1VehicleLabs(), Global::RoleSettings::Tactical::StartCapT1VehiclePlants);

		// ****************** Aircraft Plant LIMITS ****************** //
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1AircraftPlants(), Global::RoleSettings::Tactical::StartCapT1AircraftPlants);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2AircraftPlants(), Global::RoleSettings::Tactical::StartCapT2AircraftPlants);

		// ****************** Shipyard LIMITS ****************** //
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1Shipyards(), Global::RoleSettings::Tactical::StartCapT1Shipyards);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2Shipyards(), Global::RoleSettings::Tactical::StartCapT2Shipyards);

		GenericHelpers::LogUtil("Tactical start limits applied", 3);
	}

	/******************************************************************************

	MAIN HOOKS

	******************************************************************************/
 
	void Tactical_MainUpdate() {
		// MainUpdate: no periodic objective scanning (performance). Selection occurs at Init.
	}

	/******************************************************************************

	ECONOMY HOOKS

	******************************************************************************/

	void Tactical_EconomyUpdate() {
		// No tactical-specific economy adjustments yet
	}

	/******************************************************************************

	FACTORY HOOKS

	******************************************************************************/

	IUnitTask@ Tactical_FactoryAiMakeTask(CCircuitUnit@ u)
	{
		// Single null/def guard to avoid repeated checks
		const CCircuitDef@ facDef = (u is null ? null : u.circuitDef);
		if (facDef is null) {
			return aiFactoryMgr.DefaultMakeTask(u);
		}

		const string facName = facDef.GetName();
		const string side = UnitHelpers::GetSideForUnitName(facName);

		// First: ensure a baseline of T2 vehicle construction capability.
		// If this is a T2 Vehicle Plant and we have zero T2 vehicle constructors for our side,
		// enqueue the side-specific T2 vehicle constructor (armacv/coracv/legacv).
		if (UnitHelpers::IsT2VehicleLab(facName)) {
			string vehCtor = (side == "armada" ? "armacv" : (side == "cortex" ? "coracv" : "legacv"));
			int haveVehCtors = UnitDefHelpers::GetUnitDefCount(vehCtor);
			if (haveVehCtors < 1) {
				CCircuitDef@ ctorDef = ai.GetCircuitDef(vehCtor);
				if (ctorDef !is null && ctorDef.IsAvailable(ai.frame)) {
					const AIFloat3 pos = u.GetPos(ai.frame);
					return aiFactoryMgr.Enqueue(
						TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, ctorDef, pos, 64.f)
					);
				}
			}
		}

		// For hover plants: ensure minimum constructor count first, then try dynamic production
		bool isHoverPlant = UnitHelpers::IsT1HoverPlant(facName) || UnitHelpers::IsFloatingHoverPlant(facName);
		if (isHoverPlant) {
			// Minimum hover constructor guarantee (always enforced)
			string hoverCtorName = UnitHelpers::GetT1HoverConstructor(side);
			int haveHoverCtors = UnitDefHelpers::GetUnitDefCount(hoverCtorName);
			if (haveHoverCtors < Global::RoleSettings::Tactical::MinHoverConstructorCount) {
				CCircuitDef@ ctorDef2 = ai.GetCircuitDef(hoverCtorName);
				if (ctorDef2 !is null && ctorDef2.IsAvailable(ai.frame)) {
					const AIFloat3 pos2 = u.GetPos(ai.frame);
					return aiFactoryMgr.Enqueue(
						TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, ctorDef2, pos2, 64.f)
					);
				}
			}

			// Dynamic production system for hover factories
			if (Global::RoleSettings::Tactical::UseDynamicFactoryProduction) {
				IUnitTask@ dynamicTask = FactoryProduction::MakeTask(u);
				if (dynamicTask !is null) {
					return dynamicTask;
				}
				GenericHelpers::LogUtil("[TACTICAL] Dynamic production returned null for '" + facName + "', falling back to default", 3);
			}
		}

		// No special case triggered, use default factory make task
		return aiFactoryMgr.DefaultMakeTask(u);
	}

	string Tactical_SelectFactoryHandler(const AIFloat3& in pos, bool isStart, bool isReset) {
		if (isStart) {
			// Explicitly start with a land hover plant for TACTICAL role to avoid bot labs
			string side = Global::AISettings::Side;
			string hoverFac = UnitHelpers::GetT1HoverPlantForSide(side); // armhp/corhp/leghp

			if (hoverFac.length() > 0) {
				GenericHelpers::LogUtil("[Tactical][SelectFactory] Start: choosing land hover plant '" + hoverFac + "' (side=" + side + ")", 2);
				return hoverFac;
			}

			// As a last resort, defer to generic role-based selection
			if (Global::Map::NearestMapStartPosition !is null) {
				GenericHelpers::LogUtil("[Tactical][SelectFactory] WARNING: hover plant unresolved; deferring to role-based selector", 2);
				return FactoryHelpers::SelectStartFactoryForRole(Global::AISettings::Role, side);
			} else {
				GenericHelpers::LogUtil("[Tactical_SelectFactoryHandler] nearestMapPosition is null; using generic fallback selector", 2);
				return FactoryHelpers::GetFallbackStartFactoryForRole(Global::AISettings::Role, side);
			}
		}

		return "";
	}

	bool Tactical_AiIsSwitchTime(int lastSwitchFrame) {
		int interval = (30 * SECOND);
		return (lastSwitchFrame + interval) <= ai.frame;
	}

	bool Tactical_AiIsSwitchAllowed(const CCircuitDef@ facDef, float armyCost, int factoryCount, float metalCurrent, bool &out assistRequired) {
		const bool isOK = (armyCost > 1.2f * facDef.costM * float(factoryCount)) || (metalCurrent > facDef.costM);
		assistRequired = !isOK;
		return isOK;
	}

	int Tactical_MakeSwitchInterval() {
		return AiRandom(Global::RoleSettings::Sea::MinAiSwitchTime, Global::RoleSettings::Sea::MaxAiSwitchTime) * SECOND;
	}

	/******************************************************************************

	MILITARY HOOKS

	******************************************************************************/
    

	/******************************************************************************

	BUILDER HOOKS

	******************************************************************************/ 

	void Tactical_BuilderAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
	{

	}

	void Tactical_BuilderAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
	{

	}

	// A construction ship - the one SEA donates (manager/sea_assist.as) or any
	// other - runs SEA's naval ladder with SEA's numbers: T2 shipyard, mex
	// upgrades, naval converter, nanos for the shipyard, tidals. Before this
	// the ship had its seeded shipyard and nothing else it could reach, so it
	// built the yard and idled (D-042).
	IUnitTask@ Tactical_SeaConstructor_AiMakeTask(CCircuitUnit@ builder, IUnitTask@ defaultTask)
	{
		if (!Global::RoleSettings::Tactical::SeaConstructorMimicsSea) return defaultTask;
		const CCircuitDef@ udef = builder.circuitDef;
		SeaConstructor::Settings@ s = SeaConstructor::FromSea();
		IUnitTask@ t = null;
		if (SeaConstructor::IsT1(udef)) {
			if (builder is Builder::primaryT1SeaConstructor) {
				@t = SeaConstructor::T1Ladder(builder, s, "TACTICAL");
			} else {
				@t = SeaConstructor::AssistPrimary(builder, s, 160 * SECOND);
			}
		} else if (SeaConstructor::IsT2(udef)) {
			@t = SeaConstructor::T2Ladder(builder, s, "TACTICAL");
			if (t is null) @t = SeaConstructor::AssistPrimary(builder, s, 120 * SECOND);
		}
		return (t !is null) ? t : defaultTask;
	}

	IUnitTask@ Tactical_BuilderAiMakeTask(CCircuitUnit@ builder) {
		GenericHelpers::LogUtil("[Tactical_BuilderAiMakeTask] called for builder", 3);
		// Create default task only at return sites via Builder helper (no pre-creation)
		// Try builder-group objectives first in order: TACTICAL -> PRIMARY -> SECONDARY
		IUnitTask@ defaultTask = Builder::MakeDefaultTaskWithLog(builder.id, "TACTICAL");

		const CCircuitDef@ udef = builder.circuitDef;
		if (udef is null) return defaultTask;

		// Early return: if the default task represents a resource expansion (MEX/GEO variants), keep it.
		IBuilderTask@ defaultBuilderTask = cast<IBuilderTask>(defaultTask);
		if (defaultBuilderTask !is null) {
			Task::BuildType dbt = Task::BuildType(defaultBuilderTask.GetBuildType());
			if (dbt == Task::BuildType::MEX || dbt == Task::BuildType::MEXUP ||
				dbt == Task::BuildType::GEO || dbt == Task::BuildType::GEOUP ||
				dbt == Task::BuildType::ENERGY) {
				GenericHelpers::LogUtil("[TACTICAL] defaultTask is MEX/MEXUP/GEO/GEOUP/ENERGY; returning early", 3);
				return defaultTask;
			}

			// If the default task is a radar but we're low on stored energy (<90% of storage),
			// prefer building a solar collector instead to stabilize the grid.
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
		if (SeaConstructor::IsT1(udef) || SeaConstructor::IsT2(udef)) {
			return Tactical_SeaConstructor_AiMakeTask(builder, defaultTask);
		}
		CCircuitUnit@ tactical = Builder::GetTacticalConstructor();
		if (tactical !is null && builder is tactical) {
			IUnitTask@ t = Tactical_TryHandleObjective(builder, Objectives::BuilderGroup::TACTICAL);
			if (t !is null) return t;

			return defaultTask;
		}

		if (builder is Builder::primaryT1HoverConstructor) {
			IUnitTask@ t1 = Tactical_TryHandleObjective(builder, Objectives::BuilderGroup::PRIMARY);
			if (t1 !is null) return t1;
			// After objectives, consider advancing to vehicles when economy supports it.
			// Build a T2 Vehicle Lab at 25+ metal income using preferred factory placement.
			{
				float mi = aiEconomyMgr.metal.income;
				// Enforce single plant and avoid duplicate queueing
				int t2VehCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2VehicleLabs());
				bool queued = Factory::IsT2VehPlantBuildQueued();
				if (EconomyHelpers::ShouldBuildAdvancedVehiclePlant(
					mi,
					/*requiredMetalIncome*/ Global::RoleSettings::Tactical::RequiredMetalIncomeForT2VehiclePlant,
					t2VehCount,
					/*maxAllowed*/ 1,
					queued
				)) {
					string side = Global::AISettings::Side;
					string labName = (side == "armada" ? "armavp" : (side == "cortex" ? "coravp" : (side == "legion" ? "legavp" : "armavp")));
					CCircuitDef@ labDef = ai.GetCircuitDef(labName);
					if (labDef !is null && labDef.IsAvailable(ai.frame)) {
						AIFloat3 pos = Factory::GetPreferredFactoryPos();
						return aiBuilderMgr.Enqueue(
							TaskB::Factory(Task::Priority::NOW, labDef, pos, labDef, /*shake*/ SQUARE_SIZE * 24, /*active*/ false, /*mustBeBuilt*/ true, /*timeout*/ 600 * SECOND)
						);
					}
				}
			}

			// Income-scaled Hover Plant expansion: 1 base + 1 per 50 metal income
			// Place near preferred factory. Prefer land hover plant; fallback to floating variant if needed.
			{
				float mi2 = aiEconomyMgr.metal.income;
				// Allow 1 base plant + one per income step; clamp to configured maximum
				const float step = Global::RoleSettings::Tactical::MetalIncomePerExtraHoverPlant;
				int allowedHoverPlants = 1 + int(step > 0.0f ? (mi2 / step) : 0);
				const int maxHoverPlants = Global::RoleSettings::Tactical::MaxHoverPlants;
				if (allowedHoverPlants > maxHoverPlants) { allowedHoverPlants = maxHoverPlants; }

				int t1HoverCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1HoverPlants());
				int floatHoverCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllFloatingHoverPlants());
				int totalHoverPlants = t1HoverCount + floatHoverCount;

				if (totalHoverPlants < allowedHoverPlants) {
					string side2 = Global::AISettings::Side;
					AIFloat3 pos2 = Factory::GetPreferredFactoryPos();

					// Try land hover plant first via builder helper (90s cooldown)
					IUnitTask@ thp = Builder::EnqueueT1HoverPlant(side2, pos2, /*shake*/ SQUARE_SIZE * 24, /*timeout*/ 600 * SECOND, Task::Priority::NOW);
					if (thp !is null) return thp;

					// Fallback to floating hover plant (shares cooldown)
					IUnitTask@ tfhp = Builder::EnqueueFloatingHoverPlant(side2, pos2, /*shake*/ SQUARE_SIZE * 24, /*timeout*/ 600 * SECOND, Task::Priority::NOW);
					if (tfhp !is null) return tfhp;
				}
			}
			// Fallback: simple eco structures if no objective was actionable
			return Tactical_FallbackEcoTask(builder);
		}

		if (builder is Builder::secondaryT1HoverConstructor) {
			IUnitTask@ t2 = Tactical_TryHandleObjective(builder, Objectives::BuilderGroup::SECONDARY);
			if (t2 !is null) return t2;
			// Secondary fallback: assist primary if energy is very low, else default
			Objectives::StrategicObjective@ secObj = ObjectiveManager::GetSelectedForGroup(AiRole::TACTICAL, Objectives::BuilderGroup::SECONDARY);
			bool pending = _Tactical_HasPendingChain(secObj, Global::AISettings::Side);
			if (!pending && aiEconomyMgr.energy.income < Global::RoleSettings::Sea::AssistPrimaryWorkerEnergyIncomeMinimum) {
				return GuardHelpers::AssignWorkerGuard(builder, Builder::primaryT1HoverConstructor, Task::Priority::HIGH, true, 160 * SECOND);
			}
		}

		// Fallback to default with logging
		return defaultTask;
	}

	void Tactical_BuilderAiTaskAdded(IUnitTask@ task) {
		GenericHelpers::LogUtil("[Tactical_BuilderAiTaskAdded] called for task", 3);
	}

	void Tactical_BuilderAiTaskRemoved(IUnitTask@ task, bool done) {

	}


	/******************************************************************************

	BUILDER LOGIC

	******************************************************************************/

	IUnitTask@ Tactical_FallbackEcoTask(CCircuitUnit@ builder)
	{
		if (builder is null || builder.circuitDef is null) return null;
		float mi = aiEconomyMgr.metal.income;
		float ei = aiEconomyMgr.energy.income;
		bool isEnergyFull = aiEconomyMgr.isEnergyFull;
		AIFloat3 pos = builder.GetPos(ai.frame);
		string side = UnitHelpers::GetSideForUnitName(builder.circuitDef.GetName());

		// Energy converter first if needed
		if (isEnergyFull && mi >= 1.0f && ei < Global::RoleSettings::Sea::TidalEnergyIncomeMinimum) {
			IUnitTask@ tConv = Builder::EnqueueT1EnergyConverter(side, pos, SQUARE_SIZE * 32, SECOND * 30);
			if (tConv !is null) return tConv;
		}

		// Nano caretaker: income-based OR reserves-based
		float energyPercent = (aiEconomyMgr.energy.storage > 0.0f)
			? (aiEconomyMgr.energy.current / aiEconomyMgr.energy.storage)
			: 0.0f;
		// Only build nanos if we have a preferred factory to anchor around
		if (Factory::GetPreferredFactory() !is null && EconomyHelpers::ShouldBuildT1Nano(
			ei,
			mi,
			Global::RoleSettings::Sea::NanoEnergyPerUnit,
			Global::RoleSettings::Sea::NanoMetalPerUnit,
			Global::RoleSettings::Sea::NanoMaxCount,
			aiEconomyMgr.metal.current,
			Global::RoleSettings::Sea::NanoBuildWhenOverMetal,
			energyPercent
		)) {
			AIFloat3 nanoPos = Factory::GetPreferredFactoryPos();
			IUnitTask@ tNano = Builder::EnqueueT1Nano(side, nanoPos, /*shake*/ SQUARE_SIZE * 16, /*timeout*/ 30);
			if (tNano !is null) return tNano;
		}

		// Prefer advanced solar when within Tactical thresholds; otherwise fallback to basic solar if energy remains low
		if (EconomyHelpers::ShouldBuildT1AdvancedSolar(
			/*energyIncome*/ ei,
			/*metalIncome*/ mi,
			/*energyIncomeMinimumThreshold*/ Global::RoleSettings::Tactical::AdvancedSolarEnergyIncomeMinimum,
			/*energyIncomeMaximumThreshold*/ Global::RoleSettings::Tactical::AdvancedSolarEnergyIncomeMaximum,
			/*t2ConstructorCount*/ 0,
			/*t2FactoryCount*/ 0,
			/*isT2FactoryQueued*/ false,
			/*enableT2ProgressGate*/ false,
			/*metalIncomeFallbackMinimum*/ 6.0f
		)) {
			IUnitTask@ tAdv = Builder::EnqueueT1AdvancedSolar(builder.id, side, pos, SQUARE_SIZE * 32, SECOND * 30);
			if (tAdv !is null) return tAdv;
		} else if (EconomyHelpers::ShouldBuildT1Solar(
			/*energyIncome*/ ei,
			/*minEnergyIncome*/ Global::RoleSettings::Tactical::SolarEnergyIncomeMinimum
		)) {
			IUnitTask@ tSolar = Builder::EnqueueT1Solar(builder.id, side, pos, SQUARE_SIZE * 32, SECOND * 30);
			if (tSolar !is null) return tSolar;
		}
		return null;
	}

	/******************************************************************************

	OBJECTIVES

	******************************************************************************/

	// Objectives are assigned on MakeTask time; store per-group references here
	// Stored tactical objective for this role (selected once; may be refreshed if invalid)
	Objectives::StrategicObjective@ tacticalObjective = null;
	// Track per-group objectives to allow PRIMARY and SECONDARY to also act on strategic objectives
	Objectives::StrategicObjective@ primaryObjective = null;
	Objectives::StrategicObjective@ secondaryObjective = null;

	// Return true if the objective has at least one eco-satisfied step with remaining count
	bool _Tactical_HasPendingChain(const Objectives::StrategicObjective@ currentObjective, const string &in side)
	{
		if (currentObjective is null || currentObjective.steps.length() == 0) return false;
		for (uint i = 0; i < currentObjective.steps.length(); ++i) {
			auto@ s = currentObjective.steps[i]; if (s is null) continue;
			if (!ObjectiveHelpers::StepEcoSatisfied(s)) continue;
			string unitName = UnitHelpers::GetObjectiveUnitNameForSide(side, s.type);
			if (unitName.length() == 0) continue;
			int q = ObjectiveHelpers::GetObjectiveBuildingsQueuedCount(currentObjective.id, unitName);
			if (q < s.count) return true;
		}
		return false;
	}

	void Tactical_SelectObjectiveForGroup(Objectives::BuilderGroup group)
	{
		string side = Global::AISettings::Side;
		const AIFloat3 ref = Global::Map::StartPos;
		array<Objectives::StrategicObjective@> candidates = ObjectiveHelpers::Find(
			AiRole::TACTICAL, side, Objectives::ConstructorClass::HOVER, 1, ref, ai.frame, group
		);
		string label = ObjectiveManager::GetBuilderGroupLabel(group);
		if (candidates.length() > 0) {
			Objectives::StrategicObjective@ chosen = candidates[0];
			ObjectiveManager::SetSelectedForGroup(AiRole::TACTICAL, group, chosen);
			float d = ObjectiveHelpers::DistanceFrom(ref, chosen);
			GenericHelpers::LogUtil("[TACTICAL][" + label + "] selected id=" + chosen.id + " prio=" + chosen.priority + " d=" + d, 2);
		} else {
			ObjectiveManager::SetSelectedForGroup(AiRole::TACTICAL, group, null);
			GenericHelpers::LogUtil("[TACTICAL][" + label + "] no objective candidates found", 2);
		}
	}

	// Back-compat wrapper used earlier
	void Tactical_SelectTacticalObjective() { Tactical_SelectObjectiveForGroup(Objectives::BuilderGroup::TACTICAL); }

	IUnitTask@ Tactical_TryHandleObjective(CCircuitUnit@ builder, Objectives::BuilderGroup group)
	{
		// 1) Acquire or refresh the objective for the group
		Objectives::StrategicObjective@ currentObjective = _Tactical_GetOrRefreshObjective(group);
		string label = ObjectiveManager::GetBuilderGroupLabel(group);
		if (currentObjective is null || ObjectiveHelpers::IsAssigned(currentObjective.id)) return null;

		GenericHelpers::LogUtil("[TACTICAL][" + label + "] Handling objective '" + currentObjective.id + "'", 2);
		// 2) Execute chain steps first if present (shared logic)
		if (currentObjective.steps.length() > 0) {
			string sideC = Global::AISettings::Side;
			AIFloat3 anchorC = ObjectiveHelpers::PreferredBuildPos(currentObjective, builder.GetPos(ai.frame));

			GenericHelpers::LogUtil("[TACTICAL][" + label + "] Attempting to execute chain step for objective '" + currentObjective.id + "'", 2);

			IUnitTask@ chainTask = ObjectiveExecutor::ExecuteNextChainStep(currentObjective, sideC, anchorC, "Tactical_" + label);
			if (chainTask !is null) return chainTask;
		}

		// All single-step logic is now handled via ObjectiveExecutor; no local first-type handling

		GenericHelpers::LogUtil("[TACTICAL][" + label + "] Objective not handled'" + currentObjective.id, 2);
		return null;
	}

	// Acquire the current objective for a group; refresh if missing or completed
	Objectives::StrategicObjective@ _Tactical_GetOrRefreshObjective(Objectives::BuilderGroup group)
	{
		Objectives::StrategicObjective@ currentObjective = ObjectiveManager::GetSelectedForGroup(AiRole::TACTICAL, group);
		if (currentObjective is null || ObjectiveHelpers::IsCompleted(currentObjective.id)) {
			Tactical_SelectObjectiveForGroup(group);
			@currentObjective = ObjectiveManager::GetSelectedForGroup(AiRole::TACTICAL, group);
		}
		return currentObjective;
	}

	// Try to get the first actionable type on the objective
	bool _Tactical_TryGetNextType(Objectives::StrategicObjective@ currentObjective, Objectives::BuildingType &out t)
	{
		if (currentObjective is null) return false;
		if (!ObjectiveHelpers::HasAnyTypes(currentObjective)) return false;
		t = ObjectiveHelpers::GetFirstType(currentObjective);
		return true;
	}

	// Handle seaplane platform step with assignment and queued count management
	IUnitTask@ _Tactical_TryHandleSeaplaneFactory(Objectives::StrategicObjective@ currentObjective, const string &in label, const string &in side, const AIFloat3 &in pos)
	{
		string platName = UnitHelpers::GetSeaplanePlatformNameForSide(side);
		int alreadyQueued = ObjectiveHelpers::GetObjectiveBuildingsQueuedCount(currentObjective.id, platName);
		if (alreadyQueued > 0) return null; // ensure only one platform
		string token = "Tactical_" + label + "_SEAPLANE";
		if (!ObjectiveHelpers::TryAssign(currentObjective.id, token)) return null;
		IUnitTask@ tFac = Builder::EnqueueSeaplanePlatform(side, pos, SQUARE_SIZE * 24, 600 * SECOND);
		if (tFac is null) { ObjectiveHelpers::Unassign(currentObjective.id); return null; }
		ObjectiveHelpers::IncrementDefenseQueued(currentObjective.id, platName, 1);
		ObjectiveHelpers::Unassign(currentObjective.id);
		GenericHelpers::LogUtil("[TACTICAL][" + label + "] Enqueued seaplane platform '" + platName + "' for objective '" + currentObjective.id + "'", 2);
		return tFac;
	}

	// Handle standard defensive structure build based on objective type
	IUnitTask@ _Tactical_TryHandleStandardBuild(Objectives::StrategicObjective@ currentObjective, const string &in label, const string &in side, const AIFloat3 &in pos, Objectives::BuildingType t)
	{
		string unitToBuild = _Tactical_GetDefNameFor(side, t);
		if (unitToBuild.length() == 0) return null;

		CCircuitDef@ def = ai.GetCircuitDef(unitToBuild);
		if (def is null || !def.IsAvailable(ai.frame)) return null;

		string assignTag = "Tactical_" + label;
		if (!ObjectiveHelpers::TryAssign(currentObjective.id, assignTag)) return null;

		Task::Priority prio = Task::Priority::NORMAL; // priority is now chain-driven
		Task::BuildType btype = ObjectiveExecutor::ResolveBuildTypeForStep(t);
		IUnitTask@ task = aiBuilderMgr.Enqueue(
			TaskB::Common(btype, prio, def, pos, /*shake*/ SQUARE_SIZE * 16, /*active*/ true, /*timeout*/ 800)
		);
		if (task is null) { ObjectiveHelpers::Unassign(currentObjective.id); return null; }
		ObjectiveHelpers::IncrementDefenseQueued(currentObjective.id, unitToBuild, 1);
		GenericHelpers::LogUtil("[TACTICAL][" + label + "] Enqueued '" + unitToBuild + "' for objective '" + currentObjective.id + "' at (" + pos.x + "," + pos.z + ")", 2);
		return task;
	}

	// Choose a build position for an objective: prefer explicit point; else first polyline point; else fallback
	AIFloat3 _Tactical_GetObjectiveBuildPos(const Objectives::StrategicObjective@ objective, const AIFloat3 &in fallback)
	{
		if (objective is null) return fallback;
		if (objective.pos.x != 0.0f || objective.pos.z != 0.0f) return objective.pos;
		if (objective.line.length() > 0) return objective.line[0];
		return fallback;
	}

	// Minimal side->unit mapping for key defence types used by tactical objectives
	string _Tactical_GetDefNameFor(const string &in side, Objectives::BuildingType t)
	{
		return UnitHelpers::GetObjectiveUnitNameForSide(side, t);
	}

	IUnitTask@ _Tactical_TryExecuteChain(Objectives::StrategicObjective@ currentObjective, CCircuitUnit@ builder, const string &in label)
	{
		string side = Global::AISettings::Side;
		AIFloat3 anchor = _Tactical_GetObjectiveBuildPos(currentObjective, builder.GetPos(ai.frame));
		// Before executing, check if all steps are satisfied; if so, complete the objective
		bool allSatisfied = true;
		bool hasStep = false;
		for (uint iCheck = 0; iCheck < currentObjective.steps.length(); ++iCheck) {
			auto@ sc = currentObjective.steps[iCheck]; if (sc is null) continue;
			hasStep = true;
			string unitCheck = UnitHelpers::GetObjectiveUnitNameForSide(side, sc.type);
			// For tidal, count via tidal unit name
			// All unit names now resolved via UnitHelpers for the new typed schema
			if (unitCheck.length() == 0) { allSatisfied = false; break; }
			int q = ObjectiveHelpers::GetObjectiveBuildingsQueuedCount(currentObjective.id, unitCheck);
			int b = ObjectiveHelpers::GetObjectiveBuildingsBuiltCount(currentObjective.id, unitCheck);
			int progress = (b > q ? b : q);
			if (progress < sc.count || !ObjectiveHelpers::StepEcoSatisfied(sc)) {
				allSatisfied = false;
				GenericHelpers::LogUtil("[TACTICAL][" + label + "] Chain check step " + iCheck + ": unit='" + unitCheck + "' progress=" + progress + "/" + sc.count + " ecoOK=" + ObjectiveHelpers::StepEcoSatisfied(sc), 3);
				break;
			}
		}
		if (hasStep && allSatisfied) {
			ObjectiveHelpers::Complete(currentObjective.id);
			GenericHelpers::LogUtil("[TACTICAL][" + label + "] Objective '" + currentObjective.id + "' chain completed", 2);
			return null;
		}

		// Find the next step (eco-satisfied) and whether remaining count exists by checking queued counts of resolved unit
		for (uint i = 0; i < currentObjective.steps.length(); ++i) {
			auto@ s = currentObjective.steps[i]; if (s is null) continue;
			if (!ObjectiveHelpers::StepEcoSatisfied(s)) continue;
			// Standard unit-based step
			string unitName = UnitHelpers::GetObjectiveUnitNameForSide(side, s.type);
			if (unitName.length() == 0) { GenericHelpers::LogUtil("[TACTICAL][" + label + "] Chain step " + i + ": unresolved unit for type=" + int(s.type), 3); continue; }
			int queued = ObjectiveHelpers::GetObjectiveBuildingsQueuedCount(currentObjective.id, unitName);
			int built = ObjectiveHelpers::GetObjectiveBuildingsBuiltCount(currentObjective.id, unitName);
			int progress = (built > queued ? built : queued);
			if (progress >= s.count) { GenericHelpers::LogUtil("[TACTICAL][" + label + "] Chain step " + i + ": already satisfied progress=" + progress + "/" + s.count, 4); continue; }
			// Enqueue this step
			CCircuitDef@ def = ai.GetCircuitDef(unitName);
			if (def is null || !def.IsAvailable(ai.frame)) continue;
			string token = "Tactical_" + label + "_STEP_" + i;
			if (!ObjectiveHelpers::TryAssign(currentObjective.id, token)) continue;
			// Factory step uses Factory task for correct behavior
			if (s.type == Objectives::BuildingType::SEAPLANE_FACTORY) {
				float fshake = (currentObjective.radius > 0.0f ? currentObjective.radius : (SQUARE_SIZE * 32.0f));
				IUnitTask@ tFac = aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::NOW, def, anchor, def, fshake, false, true, 600 * SECOND));
				if (tFac is null) { ObjectiveHelpers::Unassign(currentObjective.id); continue; }
				ObjectiveHelpers::IncrementDefenseQueued(currentObjective.id, unitName, 1);
				ObjectiveHelpers::Unassign(currentObjective.id);
				GenericHelpers::LogUtil("[TACTICAL][" + label + "] Chain step " + i + ": enqueued factory '" + unitName + "' for objective '" + currentObjective.id + "'", 2);
				return tFac;
			}

			Task::BuildType btype = ObjectiveExecutor::ResolveBuildTypeForStep(s.type);
			// Use objective radius as shake if provided to allow multiple placements within area
			float shake = (currentObjective.radius > 0.0f ? currentObjective.radius : (SQUARE_SIZE * 48.0f));
			IUnitTask@ task = aiBuilderMgr.Enqueue(
				TaskB::Common(btype, Task::Priority::NOW, def, anchor, /*shake*/ shake, /*active*/ true, /*timeout*/ 800)
			);
			if (task is null) { ObjectiveHelpers::Unassign(currentObjective.id); continue; }
			ObjectiveHelpers::IncrementDefenseQueued(currentObjective.id, unitName, 1);
			ObjectiveHelpers::Unassign(currentObjective.id);
			GenericHelpers::LogUtil("[TACTICAL][" + label + "] Chain step " + i + ": enqueued '" + unitName + "' (queued=" + queued + "/" + s.count + ") for objective '" + currentObjective.id + "'", 2);
			return task;
		}
		return null;
	}

	/******************************************************************************

	ROLE CONFIGURATION

	******************************************************************************/

	bool Tactical_RoleMatch(AiRole preferredMapRole, const string &in side, const AIFloat3& in pos, const string &in defaultStartFactory) {
		bool match = false;

		if (preferredMapRole == AiRole::TACTICAL) match = true;
     
		if (match) { 
			GenericHelpers::LogUtil("[RoleMatch] TACTICAL", 2); 
		}

		return match;
	}

	void Register() {
		if (RoleConfigs::Get(AiRole::TACTICAL) !is null) return;
		RoleConfig@ cfg = RoleConfig(AiRole::TACTICAL, cast<MainUpdateDelegate@>(@Tactical_MainUpdate));

		@cfg.InitHandler = cast<InitDelegate@>(@Tactical_Init);

		@cfg.AiIsSwitchTimeHandler = cast<AiIsSwitchTimeDelegate@>(@Tactical_AiIsSwitchTime);
		@cfg.AiIsSwitchAllowedHandler = cast<AiIsSwitchAllowedDelegate@>(@Tactical_AiIsSwitchAllowed);
		@cfg.MakeSwitchIntervalHandler = cast<MakeSwitchIntervalDelegate@>(@Tactical_MakeSwitchInterval);

		@cfg.BuilderAiUnitAdded = cast<AiUnitAddedDelegate@>(@Tactical_BuilderAiUnitAdded);
		@cfg.BuilderAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Tactical_BuilderAiUnitRemoved);

		@cfg.BuilderAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Tactical_BuilderAiMakeTask);
		@cfg.FactoryAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Tactical_FactoryAiMakeTask);

		@cfg.BuilderAiTaskAddedHandler = cast<AiTaskAddedDelegate@>(@Tactical_BuilderAiTaskAdded);
		@cfg.BuilderAiTaskRemovedHandler = cast<AiTaskRemovedDelegate@>(@Tactical_BuilderAiTaskRemoved);

		@cfg.SelectFactoryHandler = cast<SelectFactoryDelegate@>(@Tactical_SelectFactoryHandler);
		@cfg.EconomyUpdateHandler = cast<EconomyUpdateDelegate@>(@Tactical_EconomyUpdate);


		@cfg.RoleMatchHandler = cast<RoleMatchDelegate@>(@Tactical_RoleMatch);

		RoleConfigs::Register(cfg);
	}
}
