#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace TropicalAssault {
	// NOTE: This map file intentionally holds only static data (start spots & MapConfig).
	// Role determination and factory selection occur in Main::AiMain using shared helpers.
	//
	// Source: BAR map-list export (16 players, 2 teams, 18 x 20 = 9216 x 10240 elmos),
	// springName "Tropical Assault v3.0". MapConfig's first argument is matched as a
	// case-sensitive PREFIX of the engine's map name (MapConfig::CheckMatch), so the
	// version suffix is dropped and "Tropical Assault" keeps matching when the map is revved.
	//
	// Spawn layout: 16 points. P1-P8 are the south team (owner's role list,
	// mapfiletest.txt), P9-P16 the north team. The map is 180-degree rotationally
	// symmetric: each north spawn is (9216 - x, 10240 - z) of its south partner to
	// within ~130 elmos; the north coordinates are the map's own (mapinfo.lua teams)
	// and keep the partner's role. Coordinates are x / y fed in as AIFloat3(x, 0, y).
	//
	// Roles per team: 4 FRONT across the inner line, AIR and TECH behind them, 2 SEA on
	// the back shore.
	//
	// landLocked heuristic: not yet surveyed on this map; every spot passes false.
	StartSpot@[] spots = {
		// South team
		StartSpot(AIFloat3( 5974, 0,  8398), AiRole::FRONT,  false), // P1  front   (mapinfo 16)
		StartSpot(AIFloat3( 2980, 0,  8400), AiRole::FRONT,   false), // P2  front    (mapinfo 14)
		StartSpot(AIFloat3( 7200, 0,  7200), AiRole::FRONT, false), // P3  front  (mapinfo 4)
		StartSpot(AIFloat3( 5500, 0,  7500), AiRole::FRONT, false), // P4  front  (mapinfo 12)
		StartSpot(AIFloat3( 3470, 0,  7425), AiRole::FRONT, false), // P5  front  (mapinfo 10)
		StartSpot(AIFloat3( 2200, 0,  7500), AiRole::FRONT, false), // P6  front  (mapinfo 2)
		StartSpot(AIFloat3( 6000, 0,  9900), AiRole::SEA,   false), // P7  sea    (mapinfo 8)
		StartSpot(AIFloat3( 3150, 0,  9800), AiRole::SEA,   false), // P8  sea    (mapinfo 6)
		// North team: P(n+8) mirrors P(n)
		StartSpot(AIFloat3( 3203, 0,  1860), AiRole::FRONT,  false), // P9  front   (mapinfo 15) mirrors P1
		StartSpot(AIFloat3( 6364, 0,  1886), AiRole::FRONT,   false), // P10 front    (mapinfo 13) mirrors P2
		StartSpot(AIFloat3( 2004, 0,  2986), AiRole::FRONT, false), // P11 front  (mapinfo 3)  mirrors P3
		StartSpot(AIFloat3( 3679, 0,  2757), AiRole::FRONT, false), // P12 front  (mapinfo 11) mirrors P4
		StartSpot(AIFloat3( 5741, 0,  2810), AiRole::FRONT, false), // P13 front  (mapinfo 9)  mirrors P5
		StartSpot(AIFloat3( 7016, 0,  2830), AiRole::FRONT, false), // P14 front  (mapinfo 1)  mirrors P6
		StartSpot(AIFloat3( 3160, 0,   308), AiRole::SEA,   false), // P15 sea    (mapinfo 7)  mirrors P7
		StartSpot(AIFloat3( 6195, 0,   373), AiRole::SEA,   false)  // P16 sea    (mapinfo 5)  mirrors P8
	};

	// Base per-map unit limits
	dictionary mapUnitLimits; // add per-map unit restrictions here if needed

	MapConfig config = MapConfig("Tropical Assault", mapUnitLimits, spots, getFactoryWeights());

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
