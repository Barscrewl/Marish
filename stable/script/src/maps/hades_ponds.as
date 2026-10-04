#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace HadesPonds {
	// NOTE: This map file intentionally holds only static data (start spots & MapConfig).
	// Role determination and factory selection occur in Main::AiMain using shared helpers.
	//
	// Source: BAR map-list export (popular16p pool), springName "Hades Ponds 1.1".
	// MapConfig's first argument is matched as a case-sensitive PREFIX of the engine's map
	// name (MapConfig::CheckMatch, types/map_config.as), so the version suffix is dropped
	// here and "Hades Ponds" keeps matching when the map is revved.
	//
	// Spawn layout: 16 points. P1-P8 are one team, P9-P16 the other, which lets the same
	// file serve both North-vs-South and South-vs-North. Coordinates are the exported
	// x / y pair fed in as AIFloat3(x, 0, y) -- the export's "y" is the map's z axis.
	//
	// Role mapping applied to the exported role strings:
	//   front                                          -> FRONT
	//   air, air/front                                 -> AIR
	//   tech, tech/air, air/tech, tech/front, front/tech -> TECH
	//   sea                                            -> SEA
	//   anything else / unlisted                       -> FRONT
	//
	// landLocked heuristic: not yet surveyed on this map; every spot passes false. A future
	// pass may flag isolated starts that need hover/amphibious to break out.
	StartSpot@[] spots = {
		StartSpot(AIFloat3( 560, 0,  685), AiRole::FRONT, false), // P1  front
		StartSpot(AIFloat3(1299, 0, 1339), AiRole::FRONT, false), // P2  front
		StartSpot(AIFloat3(1349, 0, 2397), AiRole::FRONT, false), // P3  front
		StartSpot(AIFloat3( 964, 0, 3363), AiRole::FRONT, false), // P4  front
		StartSpot(AIFloat3( 475, 0, 4429), AiRole::FRONT,   false), // P5  front/front
		StartSpot(AIFloat3(1164, 0, 5560), AiRole::FRONT, false), // P6  front
		StartSpot(AIFloat3(1654, 0, 6503), AiRole::FRONT, false), // P7  front
		StartSpot(AIFloat3(1006, 0, 6992), AiRole::FRONT, false), // P8  front
		StartSpot(AIFloat3(7654, 0, 7522), AiRole::FRONT, false), // P9  front
		StartSpot(AIFloat3(6906, 0, 6836), AiRole::FRONT, false), // P10 front
		StartSpot(AIFloat3(6856, 0, 5764), AiRole::FRONT, false), // P11 front
		StartSpot(AIFloat3(7212, 0, 4828), AiRole::FRONT, false), // P12 front
		StartSpot(AIFloat3(7728, 0, 3775), AiRole::FRONT,   false), // P13 front/front
		StartSpot(AIFloat3(7025, 0, 2652), AiRole::FRONT, false), // P14 front
		StartSpot(AIFloat3(6522, 0, 1692), AiRole::FRONT, false), // P15 front
		StartSpot(AIFloat3(7190, 0, 1195), AiRole::FRONT, false) // P16 front
	};

	// Base per-map unit limits
	dictionary mapUnitLimits; // add per-map unit restrictions here if needed

	MapConfig config = MapConfig("Hades Ponds", mapUnitLimits, spots, getFactoryWeights());

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
