// LandArmy: Marish's land roster and factory bans.
#include "../define.as"
#include "../global.as"
#include "../types/ai_role.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/unit_helpers.as"

/******************************************************************************

LAND ARMY

Every faction's bot labs and gantry build one fixed sequence of combat units.
Each lab level (T1 lab, T2 lab, gantry) has its steps; a step is the set of
units allowed from a metal income on (sliding 10 s minimum, the figure FRONT
already uses for its T2 lab and gantry triggers). Every roster unit outside
its lab's active step is capped at 0, so the native factory.json pick, the
FRONT openers and anything else that asks IsAvailable() can only produce the
active step. factory.json lists nothing but these units and constructors.

  Armada   T1  ticks -> pawns -> maces & rocketeers
           T2  fatboys & sharpshooters
           T3  razorbacks -> titans
  Cortex   T1  grunts -> thugs & aggravators
           T2  fiends, sheldons & arbiters -> mammoths
           T3  shivas & karganeths -> juggernauts
  Legion   T1  goblins -> satyrs & karkinos
           T2  hoplites, arquebuses & thanatos
           T3  keres, daedalus & myrmidons -> sol invictus

The T2 lab and the gantry come from FRONT's own income triggers
(MinimumMetalIncomeForFirstT2Lab, MetalIncomeForGantry). Thresholds live in
Global::LandArmy.

Factory bans: vehicle plants (T1 and T2) are capped at 0 for every role.
FRONT also never builds hover plants, amphibious complexes or underwater
gantries: its only factories are bot labs and the land gantry. Both are
re-asserted on every economy update, after the role's own limits.

******************************************************************************/
namespace LandArmy {

    class Step {
        float minIncome;
        array<string> units;
        Step(float m, const array<string> &in u) { minIncome = m; units = u; }
    }

    class Sequence {
        string label;
        array<Step@> steps;
        int active = -1;
        int changedFrame = 0;   // ai.frame of the last step change
        Sequence(const string &in l) { label = l; }
        void Add(float minIncome, const array<string> &in units) { steps.insertLast(Step(minIncome, units)); }
    }

    array<Sequence@> sequences;
    // Unit name -> maxThisUnit before Marish first touched it (map and role
    // limits included), restored while the unit's step is active.
    dictionary baseCap;
    bool loaded = false;

    Sequence@ NewSequence(const string &in label)
    {
        Sequence@ s = Sequence(label);
        sequences.insertLast(s);
        return s;
    }

    void Load()
    {
        if (loaded) return;
        loaded = true;
        Sequence@ s;

        @s = NewSequence("armada T1");
        s.Add(0.0f, array<string> = {"armflea"});
        s.Add(Global::LandArmy::ArmadaPawnIncome, array<string> = {"armpw"});
        s.Add(Global::LandArmy::ArmadaMaceIncome, array<string> = {"armham", "armrock"});
        @s = NewSequence("armada T2");
        s.Add(0.0f, array<string> = {"armfboy", "armsnipe"});
        @s = NewSequence("armada T3");
        s.Add(0.0f, array<string> = {"armraz"});
        s.Add(Global::LandArmy::GantryHeavyIncome, array<string> = {"armbanth"});

        @s = NewSequence("cortex T1");
        s.Add(0.0f, array<string> = {"corak"});
        s.Add(Global::LandArmy::CortexT1Income, array<string> = {"corthud", "corstorm"});
        @s = NewSequence("cortex T2");
        s.Add(0.0f, array<string> = {"corpyro", "cormort", "corhrk"});
        s.Add(Global::LandArmy::CortexMammothIncome, array<string> = {"corsumo"});
        @s = NewSequence("cortex T3");
        s.Add(0.0f, array<string> = {"corshiva", "corkarg"});
        s.Add(Global::LandArmy::GantryHeavyIncome, array<string> = {"corkorg"});

        @s = NewSequence("legion T1");
        s.Add(0.0f, array<string> = {"leggob"});
        s.Add(Global::LandArmy::LegionT1Income, array<string> = {"leglob", "legkark"});
        @s = NewSequence("legion T2");
        s.Add(0.0f, array<string> = {"legstr", "legsrail", "leghrk"});
        @s = NewSequence("legion T3");
        s.Add(0.0f, array<string> = {"legkeres", "legerailtank", "legeallterrainmech"});
        s.Add(Global::LandArmy::GantryHeavyIncome, array<string> = {"legeheatraymech"});
    }

    string Join(const array<string> &in names)
    {
        string joined = "";
        for (uint i = 0; i < names.length(); ++i) joined += (i > 0 ? ", " : "") + names[i];
        return joined;
    }

    void Append(array<string>@ dest, const array<string> &in src)
    {
        for (uint i = 0; i < src.length(); ++i) dest.insertLast(src[i]);
    }

    void SetAllowed(const string &in name, bool allowed)
    {
        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (d is null) return;   // Legion off, or not in this game
        int base;
        if (!baseCap.get(name, base)) {
            base = d.maxThisUnit;
            baseCap.set(name, base);
        }
        const int cap = allowed ? base : 0;
        if (d.maxThisUnit != cap) d.maxThisUnit = cap;
    }

    // Highest step the income reaches. A step already reached is kept until
    // income falls below StepDownFraction of its threshold, so a dip at the
    // boundary does not flip the lab back and forth. ApplyRoster also holds
    // every step for at least MinStepSeconds.
    int TargetStep(const Sequence@ s, float income)
    {
        int target = 0;
        for (uint i = 1; i < s.steps.length(); ++i) {
            float threshold = s.steps[i].minIncome;
            if (int(i) <= s.active) threshold *= Global::LandArmy::StepDownFraction;
            if (income < threshold) break;
            target = int(i);
        }
        return target;
    }

    void ApplyRoster(float income)
    {
        Load();
        for (uint i = 0; i < sequences.length(); ++i) {
            Sequence@ s = sequences[i];
            const int target = TargetStep(s, income);
            const bool held = (s.active >= 0) && (ai.frame - s.changedFrame < Global::LandArmy::MinStepSeconds * SECOND);
            if (target != s.active && !held) {
                GenericHelpers::LogUtil("[LandArmy] " + s.label + " step " + target + " (income " + int(income) + "): "
                    + Join(s.steps[target].units), 1);
                s.active = target;
                s.changedFrame = ai.frame;
            }
            for (uint j = 0; j < s.steps.length(); ++j) {
                const bool allowed = (int(j) == s.active);
                for (uint k = 0; k < s.steps[j].units.length(); ++k) {
                    SetAllowed(s.steps[j].units[k], allowed);
                }
            }
        }
    }

    void ApplyFactoryBans()
    {
        array<string> banned = UnitHelpers::GetAllT1VehicleLabs();
        Append(@banned, UnitHelpers::GetAllT2VehicleLabs());
        if (Global::AISettings::Role == AiRole::FRONT) {
            Append(@banned, UnitHelpers::GetAllT1HoverPlants());
            Append(@banned, UnitHelpers::GetAllFloatingHoverPlants());
            Append(@banned, array<string> = {"armamsub", "coramsub", "legamphlab"});
            Append(@banned, UnitHelpers::GetAllWaterGantries());
        }
        UnitHelpers::BatchApplyUnitCaps(banned, 0);
    }

    // Economy::AiUpdateEconomy, after the role's handler, and once at the end of setup.
    void Apply(float income)
    {
        ApplyFactoryBans();
        ApplyRoster(income);
    }
}
