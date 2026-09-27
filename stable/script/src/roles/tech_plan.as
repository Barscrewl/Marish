#include "../global.as"
#include "../helpers/unit_helpers.as"
#include "../helpers/economy_helpers.as"
#include "tech_chain.as"

// D-080: what the TECH role does once its rush objective stands. The owner's
// list: (A) nuke - a silo the fastest way; (B) t2rush - +200 metal, then T2
// fast assault units while the economy climbs to +500, then T3 in mass with
// many turrets; (C) t3rush - +500 metal before any combat unit, then T3; (D)
// lrpc - +300 metal, then the long-range plasma cannon. Every plan climbs the
// metal ladder the same way (TechChain's income steps: converters when energy
// floats, T2 mex upgrades, the next advanced fusion) and no plan produces a
// mobile combat unit under its income gate. From +200 metal the T2 air plant
// and T2 construction aircraft become the mobile build power. Phase 2 (native,
// KI-417 and KI-418): the nuke's first shot at the enemy tech location, the
// cannon on high ground with sight, land constructors guarding allied ones.
namespace TechPlan {
    string plan = "";        // nuke | t2rush | t3rush | lrpc
    int phase = 0;           // 0 = the rush objective, then 1, 2 ...

    string Choose()
    {
        const string want = Global::RoleSettings::Tech::EndgamePlan;
        if (want == "nuke" || want == "t2rush" || want == "t3rush" || want == "lrpc") return want;
        // auto: deterministic from the team id, so an 8v8 with several TECH
        // players spreads the plans and the same lobby gives the same plan
        array<string> plans = { "nuke", "t2rush", "t3rush", "lrpc" };
        return plans[uint(ai.teamId) % plans.length()];
    }

    void Init()
    {
        plan = Choose();
        phase = 0;
        GenericHelpers::LogUtil("[TECH][Plan] " + plan + " (combat gate +" + int(CombatGate()) + " metal; T2 air constructors from +"
            + int(Global::RoleSettings::Tech::PlanAirConstructorsFromMetal) + ")", 1);
    }

    // The metal income under which no mobile combat unit is produced.
    float CombatGate()
    {
        if (plan == "t3rush") return Global::RoleSettings::Tech::PlanT3RushCombatGate;
        return Global::RoleSettings::Tech::PlanCombatGate;
    }

    // T2 construction aircraft wanted: none before PlanAirConstructorsFromMetal,
    // then one per PlanAirConstructorPerMetal of income, at most PlanMaxAirConstructors.
    int AirConstructorsWanted()
    {
        const float mi = Economy::GetMinMetalIncomeLast10s();
        if (mi < Global::RoleSettings::Tech::PlanAirConstructorsFromMetal) return 0;
        int n = int(mi / Global::RoleSettings::Tech::PlanAirConstructorPerMetal);
        if (n > Global::RoleSettings::Tech::PlanMaxAirConstructors) n = Global::RoleSettings::Tech::PlanMaxAirConstructors;
        return n;
    }

    // The steps of the next phase after `objective` stood; empty = no more.
    // Income steps are metal-income targets the chain's ladder climbs.
    array<TechChain::Step@>@ NextPhase(const string &in objective)
    {
        array<TechChain::Step@> s;
        ++phase;
        const int gate200 = int(Global::RoleSettings::Tech::PlanCombatGate);
        const int gate500 = int(Global::RoleSettings::Tech::PlanT3RushCombatGate);
        const int lrpcAt = int(Global::RoleSettings::Tech::PlanLrpcMetal);
        if (plan == "nuke") {
            if (phase == 1) {
                if (objective != "nuke") s.insertLast(TechChain::Step("silo", TechChain::DefFor("silo"), 1));
                s.insertLast(TechChain::Step("income", "", gate200));
            } else if (phase == 2) {
                s.insertLast(TechChain::Step("ap", TechChain::DefFor("ap"), 1));   // D-103: only an air constructor builds the advanced aircraft plant
                s.insertLast(TechChain::Step("aap", TechChain::DefFor("aap"), 1));
                s.insertLast(TechChain::Step("income", "", gate500));
            }
        } else if (plan == "t2rush") {
            if (phase == 1) {
                s.insertLast(TechChain::Step("ap", TechChain::DefFor("ap"), 1));   // D-103: only an air constructor builds the advanced aircraft plant
                s.insertLast(TechChain::Step("aap", TechChain::DefFor("aap"), 1));
                s.insertLast(TechChain::Step("income", "", gate200));
            } else if (phase == 2) {
                s.insertLast(TechChain::Step("income", "", gate500));
                s.insertLast(TechChain::Step("gantry", TechChain::DefFor("gantry"), 1));
            }
        } else if (plan == "t3rush") {
            if (phase == 1) {
                s.insertLast(TechChain::Step("ap", TechChain::DefFor("ap"), 1));   // D-103: only an air constructor builds the advanced aircraft plant
                s.insertLast(TechChain::Step("aap", TechChain::DefFor("aap"), 1));
                s.insertLast(TechChain::Step("income", "", gate500));
                s.insertLast(TechChain::Step("gantry", TechChain::DefFor("gantry"), 1));
            }
        } else if (plan == "lrpc") {
            if (phase == 1) {
                s.insertLast(TechChain::Step("ap", TechChain::DefFor("ap"), 1));   // D-103: only an air constructor builds the advanced aircraft plant
                s.insertLast(TechChain::Step("aap", TechChain::DefFor("aap"), 1));
                s.insertLast(TechChain::Step("income", "", lrpcAt));
                s.insertLast(TechChain::Step("lrpc", TechChain::DefFor("lrpc"), 1));
            } else if (phase == 2) {
                s.insertLast(TechChain::Step("income", "", gate500));
            }
        }
        return s;
    }

    string PhaseName() { return plan + " phase " + phase; }
}
