// Generic factory selection helpers (extracted from Supreme Isthmus specific logic).
// Marish: every land role opens on the T1 bot lab; only SEA opens on a shipyard.
#include "../types/start_spot.as"

namespace FactoryMapping {
	string FactoryFor(const string &in role, const string &in side, bool landLocked) {
		if (role == "") return "";
		if (side == "armada") {
			if (role == "sea") return "armsy";
			return "armlab";
		}
		if (side == "cortex") {
			if (role == "sea") return "corsy";
			return "corlab";
		}
		if (side == "legion") {
			if (role == "sea") return "legsy";
			return "leglab";
		}
		return "";
	}
}
