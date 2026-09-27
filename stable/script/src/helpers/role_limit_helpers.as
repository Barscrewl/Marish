// Centralize unit lists in UnitHelpers
#include "unit_helpers.as"
#include "../types/ai_role.as"
#include "../define.as"
//#include "../types/profile_controller.as" // for MainUpdateDelegate

// Helpers for quickly disabling tiers of combat units by side.
// NOTE: Unit names are placeholders where uncertain; verify against resources/data/units.json.
// Policy: Only combat units are targeted (not constructors or factories).
namespace RoleLimitHelpers {
    void _setAll(dictionary@ d, array<string>@ names, int cap) {
        for (uint i = 0; i < names.length(); ++i) { d.set(names[i], cap); }
    }

    // Disable Tier 1 combat units
    void DisableT1Combat(dictionary@ d, const string &in side) {
        if (side == "armada") { array<string> arm = UnitHelpers::GetArmadaT1CombatUnits(); _setAll(d, arm, 0); }
        else if (side == "cortex") { array<string> cor = UnitHelpers::GetCortexT1CombatUnits(); _setAll(d, cor, 0); }
        else if (side == "legion") { array<string> leg = UnitHelpers::GetLegionT1CombatUnits(); _setAll(d, leg, 0); }
        else { array<string> all = UnitHelpers::GetAllT1CombatUnits(); _setAll(d, all, 0); }
    }

    // Disable Tier 2 combat units
    void DisableT2Combat(dictionary@ d, const string &in side) {
        // Lists are centralised in UnitHelpers so this stays in step with the labs' buildoptions.
        array<string> arm = UnitHelpers::GetArmadaT2CombatUnits();
        array<string> cor = UnitHelpers::GetCortexT2CombatUnits();
        array<string> leg = UnitHelpers::GetLegionT2CombatUnits();

        if (side == "armada") { _setAll(d, arm, 0); }
        else if (side == "cortex") { _setAll(d, cor, 0); }
        else if (side == "legion") { _setAll(d, leg, 0); }
        else { _setAll(d, arm, 0); _setAll(d, cor, 0); _setAll(d, leg, 0); }
    }

    // Disable Tier 3 combat units (heavies/experimental); if uncertain, leave placeholders
    void DisableT3Combat(dictionary@ d, const string &in side) {
        // Armada T3 combat
        array<string> arm = { 
            "armbanth",  // Titan
            "armraz",    // Razorback
            "armvang",   // Vanguard
            "armthor",   // Thor
            "armmar",    // Marauder
            "armlun"     // Lunkhead
        };

        // Cortex T3 combat
        array<string> cor = { 
            "corkorg",   // Juggernaut
            "corjugg",   // Behemoth
            "corshiva",  // Shiva
            "corkarg",   // Karganeth
            "corcat",    // Catapult
            "corsok",    // Cataphract
            "cordemon"   // Demon
        };

        // Legion T3 combat
        array<string> leg = { 
            "legeheatraymech",    // Sol Invictus
            "legeallterrainmech", // Myrmidon
            "legerailtank",       // Daedalus
            "legelrpcmech",       // Astraeus
            "legeshotgunmech",    // Praetorian
            "legehovertank",      // Charybdis
            "legjav",             // Javelin
            "legkeres"            // Keres
        };

        if (side == "armada") { _setAll(d, arm, 0); }
        else if (side == "cortex") { _setAll(d, cor, 0); }
        else if (side == "legion") { _setAll(d, leg, 0); }
        else { _setAll(d, arm, 0); _setAll(d, cor, 0); _setAll(d, leg, 0); }
    }

    // Convenience for TECH role default: disable T1 + T2 combat
    void ApplyTechDefaults(dictionary@ d, const string &in side) {
        DisableT1Combat(d, side);
        DisableT2Combat(d, side);
    }

    // Disable experimental gantry factories by side
    void DisableGantries(dictionary@ d, const string &in side) {
        array<string> arm = { "armshltx", "armshltxuw" };
        array<string> cor = { "corgant", "corgantuw" };
        array<string> leg = { "leggant", "leggantuw" };
        if (side == "armada") { _setAll(d, arm, 0); }
        else if (side == "cortex") { _setAll(d, cor, 0); }
        else if (side == "legion") { _setAll(d, leg, 0); }
        else { _setAll(d, arm, 0); _setAll(d, cor, 0); _setAll(d, leg, 0); }
    }

    // Set gantry caps to a specific value (used to lift the gate after threshold)
    void SetGantriesCap(dictionary@ d, const string &in side, int cap) {
        array<string> arm = { "armshltx", "armshltxuw" };
        array<string> cor = { "corgant", "corgantuw" };
        array<string> leg = { "leggant", "leggantuw" };
        if (side == "armada") { _setAll(d, arm, cap); }
        else if (side == "cortex") { _setAll(d, cor, cap); }
        else if (side == "legion") { _setAll(d, leg, cap); }
        else { _setAll(d, arm, cap); _setAll(d, cor, cap); _setAll(d, leg, cap); }
    }

    // Dynamic gate: if metal income < threshold, cap gantries at 0; else set to capWhenOpen
    void GateGantriesByIncome(dictionary@ d, const string &in side, float threshold, int capWhenOpen) {
        float income = aiEconomyMgr.metal.income;
        if (income < threshold) {
            DisableGantries(d, side);
        } else {
            SetGantriesCap(d, side, capWhenOpen);
        }
    }
}