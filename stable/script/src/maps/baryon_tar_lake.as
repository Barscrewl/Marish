#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace BaryonTarLake {
	// NOTE: This map file intentionally holds only static data (start spots & MapConfig).
	// Role determination and factory selection occur in Main::AiMain using shared helpers.
	//
	// Source: BAR map-list export (popular16p pool), springName "Baryon Tar Lake v1.1".
	// MapConfig's first argument is matched as a case-sensitive PREFIX of the engine's map
	// name (MapConfig::CheckMatch, types/map_config.as), so the version suffix is dropped
	// here and "Baryon Tar Lake" keeps matching when the map is revved.
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
		StartSpot(AIFloat3(2004, 0,  565), AiRole::FRONT, false), // P1  front
		StartSpot(AIFloat3(2010, 0, 1554), AiRole::FRONT, false), // P2  front
		StartSpot(AIFloat3( 579, 0, 1732), AiRole::FRONT,   false), // P3  front
		StartSpot(AIFloat3(2057, 0, 2814), AiRole::FRONT, false), // P4  front
		StartSpot(AIFloat3(2038, 0, 3628), AiRole::FRONT, false), // P5  front
		StartSpot(AIFloat3(2054, 0, 4555), AiRole::FRONT, false), // P6  front
		StartSpot(AIFloat3( 296, 0, 4967), AiRole::FRONT,  false), // P7  front
		StartSpot(AIFloat3(1993, 0, 5752), AiRole::FRONT, false), // P8  front
		StartSpot(AIFloat3(8241, 0,  565), AiRole::FRONT, false), // P9  front
		StartSpot(AIFloat3(8223, 0, 1572), AiRole::FRONT, false), // P10 front
		StartSpot(AIFloat3(9650, 0, 1725), AiRole::FRONT,   false), // P11 front
		StartSpot(AIFloat3(8184, 0, 2809), AiRole::FRONT, false), // P12 front
		StartSpot(AIFloat3(8211, 0, 3619), AiRole::FRONT, false), // P13 front
		StartSpot(AIFloat3(8224, 0, 4546), AiRole::FRONT, false), // P14 front
		StartSpot(AIFloat3(9954, 0, 4818), AiRole::FRONT,  false), // P15 front
		StartSpot(AIFloat3(8242, 0, 5749), AiRole::FRONT, false) // P16 front
	};

	// Base per-map unit limits
	dictionary mapUnitLimits; // add per-map unit restrictions here if needed

	MapConfig config = MapConfig("Baryon Tar Lake", mapUnitLimits, spots, getFactoryWeights());

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
