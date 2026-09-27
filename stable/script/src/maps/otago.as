#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace Otago {
	// NOTE: This map file intentionally holds only static data (start spots & MapConfig).
	// Role determination and factory selection occur in Main::AiMain using shared helpers.
	//
	// Source: BAR map-list export 2026-09-27 (in no map list), springName "Otago 1.43".
	// MapConfig's first argument is matched as a case-sensitive PREFIX of the engine's map
	// name (MapConfig::CheckMatch, types/map_config.as), so the version suffix is dropped
	// here and "Otago" keeps matching when the map is revved.
	//
	// Spawn layout: 18 points, 16 assigned. P1 P2 P3 P4 P5 P6 P7 P8 are one team,
	// P10 P11 P12 P13 P14 P15 P16 P17 the other; P9 and P18 have no role in the export and are left out.
	// Coordinates are the exported x / y pair fed in as AIFloat3(x, 0, y) -- the export's
	// "y" is the map's z axis.
	//
	// Role mapping applied to the exported role strings:
	//   front                                            -> FRONT
	//   air, air/front, front/air                        -> AIR
	//   tech, tech/air, air/tech, tech/front, front/tech -> TECH
	//   sea                                              -> SEA
	//   anything else / unlisted                         -> FRONT
	//
	// landLocked heuristic: not yet surveyed on this map; every spot passes false. A future
	// pass may flag isolated starts that need hover/amphibious to break out.
	StartSpot@[] spots = {
		StartSpot(AIFloat3(2365, 0,  365), AiRole::FRONT, false), // P1  front
		StartSpot(AIFloat3( 612, 0, 1709), AiRole::FRONT, false), // P2  front
		StartSpot(AIFloat3(2422, 0, 2358), AiRole::FRONT, false), // P3  front
		StartSpot(AIFloat3(1811, 0, 3375), AiRole::FRONT, false), // P4  front
		StartSpot(AIFloat3( 432, 0, 4506), AiRole::TECH,  false), // P5  tech
		StartSpot(AIFloat3( 849, 0, 5348), AiRole::AIR,   false), // P6  air
		StartSpot(AIFloat3(1778, 0, 5912), AiRole::FRONT, false), // P7  front
		StartSpot(AIFloat3(2243, 0, 3903), AiRole::FRONT, false), // P8  front
		StartSpot(AIFloat3(7435, 0,  260), AiRole::FRONT, false), // P10 front
		StartSpot(AIFloat3(8368, 0,  790), AiRole::AIR,   false), // P11 air
		StartSpot(AIFloat3(8786, 0, 1631), AiRole::TECH,  false), // P12 tech
		StartSpot(AIFloat3(6934, 0, 5735), AiRole::FRONT, false), // P13 front
		StartSpot(AIFloat3(8604, 0, 4421), AiRole::FRONT, false), // P14 front
		StartSpot(AIFloat3(6853, 0, 3772), AiRole::FRONT, false), // P15 front
		StartSpot(AIFloat3(7433, 0, 2742), AiRole::FRONT, false), // P16 front
		StartSpot(AIFloat3(6868, 0, 2218), AiRole::FRONT, false) // P17 front
	};

	// Base per-map unit limits
	dictionary mapUnitLimits; // add per-map unit restrictions here if needed

	MapConfig config = MapConfig("Otago", mapUnitLimits, spots, getFactoryWeights());

	// Factory weights per role (higher weight = more likely).
	// Schema: role -> ( side -> (factory -> weight) )
	dictionary getFactoryWeights() {
		dictionary root; // role -> sideDict

		// FRONT role: side specific dictionaries
		dictionary frontArm; frontArm.set("armlab",2); frontArm.set("armvp",5);
		dictionary frontCor; frontCor.set("corlab",2); frontCor.set("corvp",5);
		dictionary frontLeg; frontLeg.set("leglab",2); frontLeg.set("legvp",5);
		dictionary frontRole; frontRole.set("armada", @frontArm); frontRole.set("cortex", @frontCor); frontRole.set("legion", @frontLeg);
		root.set("FRONT", @frontRole);

		// AIR role
		dictionary airArm; airArm.set("armap",3);
		dictionary airCor; airCor.set("corap",3);
		dictionary airLeg; airLeg.set("legap",3);
		dictionary airRole; airRole.set("armada", @airArm); airRole.set("cortex", @airCor); airRole.set("legion", @airLeg);
		root.set("AIR", @airRole);

		// SEA role
		dictionary seaArm; seaArm.set("armsy",4);
		dictionary seaCor; seaCor.set("corsy",4);
		dictionary seaLeg; seaLeg.set("legsy",4);
		dictionary seaRole; seaRole.set("armada", @seaArm); seaRole.set("cortex", @seaCor); seaRole.set("legion", @seaLeg);
		root.set("SEA", @seaRole);

		// TACTICAL role
		dictionary tacticalArm; tacticalArm.set("armhs",4); tacticalArm.set("armhp",4); tacticalArm.set("armsy",4);
		dictionary tacticalCor; tacticalCor.set("corhs",4); tacticalCor.set("corhp",4); tacticalCor.set("corsy",4);
		dictionary tacticalLeg; tacticalLeg.set("leghs",4); tacticalLeg.set("leghp",4); tacticalLeg.set("legsy",4);
		dictionary tacticalRole; tacticalRole.set("armada", @tacticalArm); tacticalRole.set("cortex", @tacticalCor); tacticalRole.set("legion", @tacticalLeg);
		root.set("TACTICAL", @tacticalRole);

		// TECH role
		dictionary techArm; techArm.set("armlab",4);
		dictionary techCor; techCor.set("corlab",4);
		dictionary techLeg; techLeg.set("leglab",4);
		dictionary techRole; techRole.set("armada", @techArm); techRole.set("cortex", @techCor); techRole.set("legion", @techLeg);
		root.set("TECH", @techRole);

		// SUPPORT role
		dictionary supportArm; supportArm.set("armlab",4);
		dictionary supportCor; supportCor.set("corlab",4);
		dictionary supportLeg; supportLeg.set("leglab",4);
		dictionary supportRole; supportRole.set("armada", @supportArm); supportRole.set("cortex", @supportCor); supportRole.set("legion", @supportLeg);
		root.set("SUPPORT", @supportRole);

		return root;
	}

}
