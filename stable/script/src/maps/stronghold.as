#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace Stronghold {
	// NOTE: This map file intentionally holds only static data (start spots & MapConfig).
	// Role determination and factory selection occur in Main::AiMain using shared helpers.
	//
	// Source: BAR map-list export, springName "Stronghold v5.0.1" (Player Count 16).
	// MapConfig's first argument is matched as a case-sensitive PREFIX of the engine's map
	// name (MapConfig::CheckMatch, types/map_config.as), so the version suffix is dropped
	// here and "Stronghold" keeps matching when the map is revved.
	//
	// Spawn layout: 16 points, the number the export defines roles for. P1-P8 are one team
	// and P9-P16 the other (the export's playersPerTeam is 8 across two sides), which lets the
	// same file serve both North-vs-South and South-vs-North.
	//
	// Coordinates are the exported x / y pair fed in as AIFloat3(x, 0, y) -- the export's "y"
	// is the map's z axis.
	//
	// Role mapping applied to the exported role strings:
	//   front                                            -> FRONT
	//   air, air/front                                   -> AIR
	//   tech, tech/air, air/tech, tech/front, front/tech -> TECH
	//   sea                                              -> SEA
	//   anything else / unlisted                         -> FRONT
	//
	// landLocked heuristic: not yet surveyed on this map; every spot passes false. A future
	// pass may flag isolated starts that need hover/amphibious to break out.
	StartSpot@[] spots = {
		StartSpot(AIFloat3( 525, 0, 1831), AiRole::FRONT,   false), // P1  front
		StartSpot(AIFloat3(1097, 0,  663), AiRole::FRONT, false), // P2  front
		StartSpot(AIFloat3(1633, 0, 1795), AiRole::FRONT, false), // P3  front
		StartSpot(AIFloat3(3403, 0,  724), AiRole::FRONT, false), // P4  front
		StartSpot(AIFloat3(4559, 0, 1531), AiRole::FRONT, false), // P5  front
		StartSpot(AIFloat3(6402, 0, 1718), AiRole::FRONT, false), // P6  front
		StartSpot(AIFloat3(7526, 0, 1260), AiRole::FRONT, false), // P7  front
		StartSpot(AIFloat3(6425, 0,  496), AiRole::FRONT,  false), // P8  front
		StartSpot(AIFloat3(7673, 0, 6442), AiRole::FRONT,   false), // P9  front
		StartSpot(AIFloat3(7014, 0, 7533), AiRole::FRONT, false), // P10 front
		StartSpot(AIFloat3(6484, 0, 6441), AiRole::FRONT, false), // P11 front
		StartSpot(AIFloat3(4686, 0, 7491), AiRole::FRONT, false), // P12 front
		StartSpot(AIFloat3(3641, 0, 6649), AiRole::FRONT, false), // P13 front
		StartSpot(AIFloat3(1711, 0, 6504), AiRole::FRONT, false), // P14 front
		StartSpot(AIFloat3( 612, 0, 6906), AiRole::FRONT, false), // P15 front
		StartSpot(AIFloat3(1704, 0, 7657), AiRole::FRONT,  false) // P16 front
	};

	// Base per-map unit limits
	dictionary mapUnitLimits; // add per-map unit restrictions here if needed

	MapConfig config = MapConfig("Stronghold", mapUnitLimits, spots, getFactoryWeights());

	// Factory weights per role (higher weight = more likely).
	// Schema: role -> ( side -> (factory -> weight) )
	dictionary getFactoryWeights() {
		dictionary root; // role -> sideDict

		// FRONT role: side specific dictionaries
		dictionary frontArm; frontArm.set("armlab",2);
		dictionary frontCor; frontCor.set("corlab",2);
		dictionary frontLeg; frontLeg.set("leglab",2);
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
