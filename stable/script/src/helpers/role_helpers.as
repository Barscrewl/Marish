// Role-related small helpers shared across roles
#include "../define.as"           // for AiRandom
#include "unit_helpers.as"        // for UnitHelpers lab lists
#include "../types/ai_role.as"  // for AiRole enum

namespace RoleHelpers {

	// Determine a default role based on the terrain type of the default factory.
	// Marish plays FRONT and SEA only: land factories -> FRONT,
	// water factories -> SEA. Unknown factories default to FRONT.
	AiRole DefaultRoleForFactory(const string &in defaultStartFactory)
	{
		if (UnitHelpers::FactoryIsLand(defaultStartFactory)) {
			return AiRole::FRONT;
		}
		if (UnitHelpers::FactoryIsWater(defaultStartFactory)) {
			return AiRole::SEA;
		}
		return AiRole::FRONT; // fallback for unknown factories
	}

	// Append all elements from src into dest
	void AppendAll(array<string>@ dest, const array<string>@ src)
	{
		for (uint i = 0; i < src.length(); ++i) {
			dest.insertLast(src[i]);
		}
	}

	// Returns a random T1 land factory for the given side.
	// side: "armada" | "cortex" | "legion" | other -> picks from all sides
	string RandomT1LandFactoryBySide(const string &in side)
	{
		array<string> labs;
		if (side == "armada") {
			labs = UnitHelpers::GetArmadaT1LandLabs();
		} else if (side == "cortex") {
			labs = UnitHelpers::GetCortexT1LandLabs();
		} else if (side == "legion") {
			labs = UnitHelpers::GetLegionT1LandLabs();
		} else {
			// Fallback: choose among all factions' T1 land labs
			AppendAll(labs, UnitHelpers::GetArmadaT1LandLabs());
			AppendAll(labs, UnitHelpers::GetCortexT1LandLabs());
			AppendAll(labs, UnitHelpers::GetLegionT1LandLabs());
		}

		if (labs.length() == 0) return "";
		int idx = AiRandom(0, int(labs.length()) - 1);
		return labs[idx];
	}

	// Returns a random T1 water factory for the given side.
	// side: "armada" | "cortex" | "legion" | other -> picks from all sides
	string RandomT1WaterFactoryBySide(const string &in side)
	{
		array<string> labs;
		if (side == "armada") {
			labs = UnitHelpers::GetArmadaT1WaterLabs();
		} else if (side == "cortex") {
			labs = UnitHelpers::GetCortexT1WaterLabs();
		} else if (side == "legion") {
			labs = UnitHelpers::GetLegionT1WaterLabs();
		} else {
			// Fallback: choose among all factions' T1 water labs
			AppendAll(labs, UnitHelpers::GetArmadaT1WaterLabs());
			AppendAll(labs, UnitHelpers::GetCortexT1WaterLabs());
			AppendAll(labs, UnitHelpers::GetLegionT1WaterLabs());
		}

		if (labs.length() == 0) return "";
		int idx = AiRandom(0, int(labs.length()) - 1);
		return labs[idx];
	}

}

