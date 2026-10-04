// LandArmy: Marish's land roster and factory bans.
#include "../define.as"
#include "../global.as"
#include "../types/ai_role.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/unit_helpers.as"
#include "../unit.as"
#include "../task.as"

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
           T2  hoplites, arquebuses & thanatos -> incinerators
           T3  keres, daedalus & myrmidons -> sol invictus

The T2 lab and the gantry come from FRONT's own income triggers
(MinimumMetalIncomeForFirstT2Lab, MetalIncomeForGantry). Thresholds live in
Global::LandArmy.

Support escorts: every T2 bot lab also lists its radar, jammer and T2 AA bot.
All three carry the support role in behaviour.json, so a squad never takes
one as its leader. Radars and jammers get the native CSupportTask, which walks
each into an army squad that it then moves with; in the experimental profiles
radars are rationed one per squad, most valuable squad first (behaviour.json
"sensor"), and jammers join the nearest squad. T2 AA bots are given a guard
task on the army's most valuable unit instead (MakeAAGuardTask): in tests the
native escort left them parked by the base. Each kind is capped at SupportMax
alive. T2 AA starts lower and grows with the army, and goes past SupportMax
when enemy bombers are scouted.

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
        s.Add(Global::LandArmy::LegionIncineratorIncome, array<string> = {"leginc"});
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

    array<string> RadarBots  = {"armmark", "corvoyr", "legaradk"};
    array<string> JammerBots = {"armaser", "corspec", "legajamk"};
    array<string> AABots     = {"armaak", "coraak", "legadvaabot"};
    int lastAACap = -1;

    // At most `cap` alive across one escort kind: each def may add only the
    // room the kind as a whole still has.
    void CapKind(const array<string> &in names, int cap)
    {
        array<CCircuitDef@> defs;
        int total = 0;
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d is null) continue;   // Legion off, or not in this game
            defs.insertLast(d);
            total += d.count;
        }
        const int room = (cap > total) ? cap - total : 0;
        for (uint i = 0; i < defs.length(); ++i) {
            const int m = defs[i].count + room;
            if (defs[i].maxThisUnit != m) defs[i].maxThisUnit = m;
        }
    }

    int AACap()
    {
        const int maxCap = Global::LandArmy::SupportMax;
        int cap = Global::LandArmy::SupportFirstAA + int(aiMilitaryMgr.armyCost / Global::LandArmy::ArmyMetalPerAA);
        if (cap > maxCap) cap = maxCap;
        const float bombers = aiEnemyMgr.GetEnemyCost(Unit::Role::BOMBER.type);
        if (bombers >= Global::LandArmy::ManyBombersMetal) {
            cap = maxCap + 1 + int((bombers - Global::LandArmy::ManyBombersMetal) / Global::LandArmy::BomberMetalPerExtraAA);
            if (cap > Global::LandArmy::AAMaxVsBombers) cap = Global::LandArmy::AAMaxVsBombers;
        }
        if (cap != lastAACap) {
            GenericHelpers::LogUtil("[LandArmy] T2 AA cap " + cap + " (army " + int(aiMilitaryMgr.armyCost)
                + " metal, enemy bombers " + int(bombers) + " metal)", 1);
            lastAACap = cap;
        }
        return cap;
    }

    // ---- T2 AA guards ------------------------------------------------------
    // Roster combat units alive (id -> 1) and each T2 AA bot's vip (id -> id).
    dictionary roster;
    dictionary army;
    dictionary aaVip;

    bool IsAABot(const CCircuitDef@ d)
    {
        return d !is null && AABots.find(d.GetName()) >= 0;
    }

    // Military::AiUnitAdded / AiUnitRemoved
    void OnUnitAdded(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null) return;
        if (roster.isEmpty()) {
            Load();
            for (uint i = 0; i < sequences.length(); ++i)
                for (uint j = 0; j < sequences[i].steps.length(); ++j)
                    for (uint k = 0; k < sequences[i].steps[j].units.length(); ++k)
                        roster.set(sequences[i].steps[j].units[k], true);
        }
        if (roster.exists(u.circuitDef.GetName())) army.set("" + u.id, int(u.id));
    }

    void OnUnitRemoved(CCircuitUnit@ u)
    {
        if (u is null) return;
        army.delete("" + u.id);
        aaVip.delete("" + u.id);
    }

    int GuardsOn(int vipId, int except)
    {
        int n = 0;
        array<string>@ keys = aaVip.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            int v = 0;
            if (keys[i] != "" + except && aaVip.get(keys[i], v) && v == vipId) ++n;
        }
        return n;
    }

    // The most expensive roster unit with fewer than AAPerVip AA guards; when
    // every one has its share, the most expensive one.
    CCircuitUnit@ PickVip(int aaId)
    {
        CCircuitUnit@ best = null;
        CCircuitUnit@ bestAny = null;
        array<string>@ keys = army.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            int id = 0;
            army.get(keys[i], id);
            CCircuitUnit@ v = ai.GetTeamUnit(id);
            if (v is null || v.circuitDef is null) { army.delete(keys[i]); continue; }
            const float cost = v.circuitDef.costM;
            if (bestAny is null || cost > bestAny.circuitDef.costM) @bestAny = v;
            if (GuardsOn(id, aaId) < Global::LandArmy::AAPerVip
                && (best is null || cost > best.circuitDef.costM)) @best = v;
        }
        return (best !is null) ? best : bestAny;
    }

    // Military::AiMakeTask: a T2 AA bot guards the army's most valuable unit,
    // so it walks with it and fires at aircraft near it. The native support
    // escort left them parked by the base. Null (no army yet) falls through to
    // the native task. When the vip dies the guard task ends and the bot comes
    // back here for the next one.
    IUnitTask@ MakeAAGuardTask(CCircuitUnit@ u)
    {
        if (u is null || !IsAABot(u.circuitDef)) return null;
        CCircuitUnit@ vip = PickVip(int(u.id));
        if (vip is null) return null;
        IUnitTask@ t = aiMilitaryMgr.Enqueue(TaskF::Guard(vip));
        if (t is null) return null;
        aaVip.set("" + u.id, int(vip.id));
        GenericHelpers::LogUtil("[LandArmy] " + u.circuitDef.GetName() + "(" + u.id + ") guards "
            + vip.circuitDef.GetName() + "(" + vip.id + ")", 2);
        return t;
    }

    void ApplySupportCaps()
    {
        CapKind(RadarBots, Global::LandArmy::SupportMax);
        CapKind(JammerBots, Global::LandArmy::SupportMax);
        CapKind(AABots, AACap());
    }

    // Economy::AiUpdateEconomy, after the role's handler, and once at the end of setup.
    void Apply(float income)
    {
        ApplyFactoryBans();
        ApplyRoster(income);
        ApplySupportCaps();
    }
}
