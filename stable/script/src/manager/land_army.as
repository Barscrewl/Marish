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
  Legion   T1  goblins -> satyrs, karkinos & ballistas
           T2  hoplites, arquebuses & thanatos -> incinerators
           T3  keres, daedalus & myrmidons -> sol invictus

Each T1 lab's first tier (ticks and pawns, grunts, goblins) leaves in early
waves (manager/rush.as), and the lab moves to the next tier only after one
last wave of Global::Rush::FinalWaveSize: ApplyRoster holds it before
Sequence.waveGate until Rush::FinalWaveSent.

The T2 lab and the gantry come from FRONT's own income triggers
(MinimumMetalIncomeForFirstT2Lab, MetalIncomeForGantry). Thresholds live in
Global::LandArmy.

Support escorts: every T2 bot lab also lists its radar, jammer and T2 AA bot.
All three carry the support role in behaviour.json, so a squad never takes
one as its leader. Radars and jammers get the native CSupportTask, which walks
each into an army squad that it then moves with; in warband and the experimental profiles
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
        string side;
        array<Step@> steps;
        int active = -1;
        int changedFrame = 0;   // ai.frame of the last step change
        // First step of the next tier past the scouts/raiders (T1 labs only):
        // the lab moves to it once the final early wave is away (Rush).
        int waveGate = -1;
        bool gateLogged = false;
        Sequence(const string &in l) { label = l; side = l.substr(0, l.findFirst(" ")); }
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
        s.waveGate = 2;
        @s = NewSequence("armada T2");
        s.Add(0.0f, array<string> = {"armfboy", "armsnipe"});
        @s = NewSequence("armada T3");
        s.Add(0.0f, array<string> = {"armraz"});
        s.Add(Global::LandArmy::GantryHeavyIncome, array<string> = {"armbanth"});

        @s = NewSequence("cortex T1");
        s.Add(0.0f, array<string> = {"corak"});
        s.Add(Global::LandArmy::CortexT1Income, array<string> = {"corthud", "corstorm"});
        s.waveGate = 1;
        @s = NewSequence("cortex T2");
        s.Add(0.0f, array<string> = {"corpyro", "cormort", "corhrk"});
        s.Add(Global::LandArmy::CortexMammothIncome, array<string> = {"corsumo"});
        @s = NewSequence("cortex T3");
        s.Add(0.0f, array<string> = {"corshiva", "corkarg"});
        s.Add(Global::LandArmy::GantryHeavyIncome, array<string> = {"corkorg"});

        @s = NewSequence("legion T1");
        s.Add(0.0f, array<string> = {"leggob"});
        s.Add(Global::LandArmy::LegionT1Income, array<string> = {"leglob", "legkark", "legbal"});
        s.waveGate = 1;
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

    // Our side's T1 lab sequence (the one with a wave gate), or null.
    Sequence@ OwnT1()
    {
        Load();
        for (uint i = 0; i < sequences.length(); ++i)
            if (sequences[i].waveGate > 0 && sequences[i].side == Global::AISettings::Side) return sequences[i];
        return null;
    }

    // The T1 lab is still on the scout/raider tier (Rush's early waves).
    bool EarlyTier()
    {
        Sequence@ s = OwnT1();
        return s !is null && s.active >= 0 && s.active < s.waveGate;
    }

    // Metal income at which our T1 lab moves past the scout/raider tier.
    float NextTierIncome()
    {
        Sequence@ s = OwnT1();
        return (s is null) ? 0.0f : s.steps[s.waveGate].minIncome;
    }

    void ApplyRoster(float income)
    {
        Load();
        for (uint i = 0; i < sequences.length(); ++i) {
            Sequence@ s = sequences[i];
            int target = TargetStep(s, income);
            // Our side's T1 lab leaves the scout/raider tier only after one
            // last full early wave (manager/rush.as); until then it stays on
            // the last step before the gate.
            if (s.waveGate > 0 && s.side == Global::AISettings::Side && s.active >= 0 && s.active < s.waveGate
                && target >= s.waveGate && !Rush::FinalWaveSent()) {
                Rush::RequestFinalWave();
                target = s.waveGate - 1;
                if (!s.gateLogged) {
                    s.gateLogged = true;
                    GenericHelpers::LogUtil("[LandArmy] " + s.label + " holds before step " + s.waveGate
                        + " (income " + int(income) + "): the final early wave goes first", 1);
                }
            }
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
        int cap = SupportCap();
        const float bombers = aiEnemyMgr.GetEnemyCost(Unit::Role::BOMBER.type);
        if (bombers >= Global::LandArmy::ManyBombersMetal) {
            cap = maxCap + 1 + int((bombers - Global::LandArmy::ManyBombersMetal) / Global::LandArmy::BomberMetalPerExtraAA);
            if (cap > Global::LandArmy::AAMaxVsBombers) cap = Global::LandArmy::AAMaxVsBombers;
        }
        if (cap != lastAACap) {
            GenericHelpers::LogUtil("[LandArmy] T2 AA cap " + cap + " (" + HeaviesAlive() + " heavies alive, enemy bombers "
                + int(bombers) + " metal)", 1);
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

    int armyMade = 0;   // roster units finished so far (the rezbot sprinkle counts them)

    void BuildRoster()
    {
        if (!roster.isEmpty()) return;
        Load();
        for (uint i = 0; i < sequences.length(); ++i)
            for (uint j = 0; j < sequences[i].steps.length(); ++j)
                for (uint k = 0; k < sequences[i].steps[j].units.length(); ++k)
                    roster.set(sequences[i].steps[j].units[k], true);
    }

    // A land roster combat unit, any side (Rush's army waves take these).
    bool IsArmyUnit(const CCircuitDef@ d)
    {
        if (d is null) return false;
        BuildRoster();
        return roster.exists(d.GetName());
    }

    // Military::AiUnitAdded / AiUnitRemoved
    void OnUnitAdded(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null) return;
        BuildRoster();
        if (RadarBots.find(u.circuitDef.GetName()) >= 0) radarAdded = ai.frame;
        if (JammerBots.find(u.circuitDef.GetName()) >= 0) jammerAdded = ai.frame;
        // the scout lab's output goes alone at the enemy (Rush::AddLateScout)
        if (scoutLabOn && u.circuitDef.GetName() == Rush::UnitFor("scout")) {
            CCircuitUnit@ lab = ActiveT1Lab();
            if (lab !is null && u.GetProducerId() == int(lab.id)) Rush::AddLateScout(u);
        }
        if (roster.exists(u.circuitDef.GetName())) {
            army.set("" + u.id, int(u.id));
            ++armyMade;
        }
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

    // Radar and jammer bots grow with the army they cover: at 5 each from the
    // start, the T2 lab made 10 sensors next to 3 combat units (bonus 100).
    // Mammoths, fatboys and incinerators alive (Global::LandArmy::HeavyUnits).
    int HeaviesAlive()
    {
        int n = 0;
        for (uint i = 0; i < Global::LandArmy::HeavyUnits.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(Global::LandArmy::HeavyUnits[i]);
            if (d !is null) n += d.count;
        }
        return n;
    }

    // Radar, jammer and T2 AA bots, each kind: one until two heavies stand,
    // then one per heavy, at most SupportMax.
    int SupportCap()
    {
        const int h = HeaviesAlive();
        const int cap = (h < 2) ? 1 : h;
        return (cap > Global::LandArmy::SupportMax) ? Global::LandArmy::SupportMax : cap;
    }

    int AliveOf(const array<string> &in names)
    {
        int n = 0;
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d !is null) n += d.count;
        }
        return n;
    }

    // While one of a kind is alive the T2 lab weighs it SupportWeightHave
    // instead of SupportWeight, so the fighting units come first. The weights
    // follow each lab's "unit" list in factory.json / factory_leg.json.
    array<string> lastSupportHave = {"", "", ""};
    void ApplySupportWeights()
    {
        array<array<string>> labUnits = {
            {"armalab", "armack", "armfboy", "armsnipe", "armmark", "armaser", "armaak"},
            {"coralab", "corack", "corpyro", "cormort", "corhrk", "corsumo", "corvoyr", "corspec", "coraak"},
            {"legalab", "legack", "legstr", "legsrail", "leghrk", "leginc", "legaradk", "legajamk", "legadvaabot"}};
        const bool radar = AliveOf(RadarBots) > 0, jammer = AliveOf(JammerBots) > 0, aa = AliveOf(AABots) > 0;
        const string have = (radar ? "r" : "-") + (jammer ? "j" : "-") + (aa ? "a" : "-");
        for (uint l = 0; l < labUnits.length(); ++l) {
            CCircuitDef@ lab = ai.GetCircuitDef(labUnits[l][0]);
            if (lab is null || lab.count == 0 || lastSupportHave[l] == have) continue;
            for (int surf = 0; surf <= 1; ++surf) {   // air and land tier sets (native ESurfType)
                array<float>@ w = aiFactoryMgr.GetTierWeights(lab, surf, 0);
                if (w is null || w.length() != labUnits[l].length() - 1) continue;
                for (uint i = 1; i < labUnits[l].length(); ++i) {
                    const string u = labUnits[l][i];
                    bool isSupport = true, has = false;
                    if (RadarBots.find(u) >= 0) has = radar;
                    else if (JammerBots.find(u) >= 0) has = jammer;
                    else if (AABots.find(u) >= 0) has = aa;
                    else isSupport = false;
                    if (isSupport) w[i - 1] = has ? Global::LandArmy::SupportWeightHave : Global::LandArmy::SupportWeight;
                }
                aiFactoryMgr.SetTierWeights(lab, surf, 0, w);
            }
            lastSupportHave[l] = have;
        }
    }

    int radarAdded = -100000;
    int jammerAdded = -100000;

    void ApplySupportCaps()
    {
        const int cap = SupportCap();
        const int gap = Global::LandArmy::SensorGapSeconds * SECOND;
        CapKind(RadarBots, (ai.frame - radarAdded < gap) ? 0 : cap);    // 0: no room, none more for now
        CapKind(JammerBots, (ai.frame - jammerAdded < gap) ? 0 : cap);
        CapKind(AABots, AACap());
        ApplySupportWeights();
    }

    // LRPCs only on massive income (Global::LandArmy::LRPCMinIncome)
    void ApplyLRPCGate()
    {
        const bool allowed = avgMinIncome >= Global::LandArmy::LRPCMinIncome;
        array<string> names = {"armbrtha", "corint", "leglrpc", "armvulc", "corbuzz", "legstarfall"};
        for (uint i = 0; i < names.length(); ++i) SetAllowed(names[i], allowed);
    }

    // ---- T2 production -----------------------------------------------------
    // See Global::LandArmy::MaxT2Labs. Native's factory makes a constructor on
    // half its picks while build power trails income, so the richer the team
    // the more of the T2 lab's time went into T2 constructors that then took
    // native's default jobs; and one T2 lab could not spend +100 metal.
    int lastT2LabCap = -1;
    int prodLog = -100000;

    int T2LabsWanted(float income)
    {
        const float over = income - Global::RoleSettings::Front::MinimumMetalIncomeForFirstT2Lab;
        int n = 1 + ((over > 0.0f) ? int(over / Global::LandArmy::IncomePerExtraT2Lab) : 0);
        return (n > Global::LandArmy::MaxT2Labs) ? Global::LandArmy::MaxT2Labs : n;
    }

    void ApplyT2ConstructorCap(float income)
    {
        if (Global::AISettings::Role != AiRole::FRONT) return;
        int cap = Global::LandArmy::T2ConMin + int(AiMax(0.0f, income) / Global::LandArmy::IncomePerT2Con);
        if (cap > Global::LandArmy::T2ConMax) cap = Global::LandArmy::T2ConMax;
        CapKind(UnitHelpers::GetAllT2BotConstructors(), cap);
    }

    int CountBuiltOrFramed(const array<string> &in names)
    {
        int n = 0;
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d !is null) n += d.count + aiBuilderMgr.GetUnfinishedCount(d);
        }
        return n;
    }

    // A finished T2 lab or gantry of ours for the next nano (they take turns);
    // before the T2 lab, a T1 bot lab that is not retiring.
    CCircuitUnit@ NanoHost(int turn)
    {
        array<CCircuitUnit@> hosts, t1;
        array<string> gantries = UnitHelpers::GetAllLandGantries();
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ f = ai.GetTeamUnit(ids[i]);
            if (f is null || f.circuitDef is null || f.GetBuildProgress() < 1.0f) continue;
            const string n = f.circuitDef.GetName();
            if (UnitHelpers::IsT2BotLab(n) || gantries.find(n) >= 0) hosts.insertLast(f);
            else if (UnitHelpers::IsT1BotLab(n) && !Lifecycle::IsRetiring(f)) t1.insertLast(f);
        }
        if (hosts.length() == 0) hosts = t1;
        return (hosts.length() == 0) ? null : hosts[uint(turn) % hosts.length()];
    }

    void LogProduction(const string &in what)
    {
        if (ai.frame - prodLog < 20 * SECOND) return;
        prodLog = ai.frame;
        GenericHelpers::LogUtil("[LandArmy] metal " + int(aiEconomyMgr.metal.current) + "/" + int(aiEconomyMgr.metal.storage)
            + " at +" + int(Economy::GetMinMetalIncomeLast10s()) + ": " + what, 1);
    }

    // FRONT's constructors, before their own jobs: the scout lab when it is
    // due; then, T2 constructors only (t2), while metal floats, the gantry and
    // more T2 labs; then nanos at the labs while the bank is over
    // NanoBankShare or there is less than one nano per NanoMetalPerNano of
    // metal income. Null when none is due.
    IUnitTask@ ProductionTask(CCircuitUnit@ u, const string &in side, bool t2)
    {
        if (u is null || Global::AISettings::Role != AiRole::FRONT) return null;
        IUnitTask@ s = ScoutLabBuildTask(side);
        if (s !is null) return s;
        const float bank = aiEconomyMgr.metal.current;
        const float storage = aiEconomyMgr.metal.storage;
        const float income = Economy::GetMinMetalIncomeLast10s();

        if (t2 && (bank >= Global::LandArmy::ProductionMinBank || bank >= storage * Global::LandArmy::ProductionBankShare)) {
            array<string> gantries = UnitHelpers::GetAllLandGantries();
            if (income >= Global::RoleSettings::Front::MetalIncomeForGantry && CountBuiltOrFramed(gantries) == 0) {
                IUnitTask@ g = Builder::EnqueueLandGantry(side);
                if (g !is null) { LogProduction("gantry"); return g; }
            }
            array<string> labs = UnitHelpers::GetAllT2BotLabs();
            const int labsHave = CountBuiltOrFramed(labs);
            if (labsHave > 0 && labsHave < T2LabsWanted(income)) {
                IUnitTask@ l = Builder::EnqueueT2BotLabIfNeeded(side, Factory::GetPreferredFactoryPos(), SQUARE_SIZE * 24, 300 * SECOND);
                if (l !is null) { LogProduction("T2 lab " + (labsHave + 1) + " of " + T2LabsWanted(income)); return l; }
            }
        }
        const int nanos = CountBuiltOrFramed(UnitHelpers::GetT1NanoUnitNames());
        const bool full = storage > 0.0f && bank >= storage * Global::LandArmy::NanoBankShare;
        const bool few = float(nanos) < income / Global::LandArmy::NanoMetalPerNano;
        if (!full && !few) return null;
        CCircuitUnit@ host = NanoHost(nanos);
        if (host is null) return null;
        IUnitTask@ n = Builder::EnqueueT1Nano(side, host.GetPos(ai.frame), Global::LandArmy::ProductionNanoShake, 120 * SECOND);
        if (n !is null) LogProduction("nano " + (nanos + 1) + " at " + host.circuitDef.GetName() + "(" + host.id + ")"
            + (full ? ", bank over " + int(Global::LandArmy::NanoBankShare * 100.0f) + " %" : "")
            + (few ? ", fewer than one per " + int(Global::LandArmy::NanoMetalPerNano) + " income" : ""));
        return n;
    }

    // ---- Scout lab ---------------------------------------------------------
    // See Global::LandArmy::ScoutLab. Once due it stays due until the gantry
    // is framed (or the T2 lab is lost); then the lab is retired and reclaimed.
    bool scoutLabOn = false;

    bool ScoutLabPhase()
    {
        if (!Global::LandArmy::ScoutLab || Global::AISettings::Role != AiRole::FRONT || !Rush::Enabled()) return false;
        if (!T2LabBegun() || CountBuiltOrFramed(UnitHelpers::GetAllLandGantries()) > 0) {
            if (scoutLabOn) GenericHelpers::LogUtil("[LandArmy] scout lab phase over (gantry framed or T2 lab lost)", 1);
            scoutLabOn = false;
            return false;
        }
        if (!scoutLabOn && avgMinIncome >= Global::LandArmy::ScoutLabMinIncome) {
            scoutLabOn = true;
            GenericHelpers::LogUtil("[LandArmy] scout lab phase: a T1 bot lab for " + Rush::UnitFor("scout") + " scouts until the gantry", 1);
        }
        return scoutLabOn;
    }

    // Our T1 bot lab that is not retiring, framed or finished; null if none.
    CCircuitUnit@ ActiveT1Lab()
    {
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ f = ai.GetTeamUnit(ids[i]);
            if (f !is null && f.circuitDef !is null && UnitHelpers::IsT1BotLab(f.circuitDef.GetName()) && !Lifecycle::IsRetiring(f)) return f;
        }
        return null;
    }

    IUnitTask@ ScoutLabBuildTask(const string &in side)
    {
        if (!ScoutLabPhase() || ActiveT1Lab() !is null) return null;
        IUnitTask@ t = Builder::EnqueueT1BotLab(side, Factory::GetPreferredFactoryPos(), SQUARE_SIZE * 24, 300 * SECOND, Task::Priority::HIGH);
        if (t !is null) GenericHelpers::LogUtil("[LandArmy] scout lab ordered", 1);
        return t;
    }

    // Front_FactoryAiMakeTask: the scout lab makes only the cheapest scout.
    IUnitTask@ ScoutLabFactoryTask(CCircuitUnit@ lab)
    {
        if (lab is null || lab.circuitDef is null || !UnitHelpers::IsT1BotLab(lab.circuitDef.GetName())) return null;
        if (Rush::Active() || !ScoutLabPhase()) return null;
        CCircuitDef@ d = ai.GetCircuitDef(Rush::UnitFor("scout"));
        if (d is null || !d.IsAvailable(ai.frame) || !lab.circuitDef.CanBuild(d)) return null;
        return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, d, lab.GetPos(ai.frame), 64.0f));
    }

    // ---- Commander escape --------------------------------------------------
    // See Global::LandArmy::CommanderFleeMetal. Checked every economy update,
    // never in AiMakeTask: the commander is taken off whatever it is doing.
    int commId = -1;
    int commFleeUntil = -1;
    int commFlees = 0;

    void NoteCommander(CCircuitUnit@ comm) { if (comm !is null) commId = int(comm.id); }

    // An enemy group worth CommanderFleeMetal within CommanderFleeRangeMult x
    // its weapon range, while it is away from our start.
    bool CommanderInDanger(CCircuitUnit@ comm)
    {
        if (comm is null || comm.circuitDef is null) return false;
        const AIFloat3 pos = comm.GetPos(ai.frame);
        const float home = Global::RoleSettings::Front::CrewPorcMinDistance;
        if (MapHelpers::SqDist(pos, Global::Map::StartPos) < home * home) return false;   // nowhere safer to go
        const AIFloat3 g = aiEnemyMgr.GetNearestGroupPos(pos, Global::LandArmy::CommanderFleeMetal);
        const float r = Global::LandArmy::CommanderFleeRangeMult * comm.circuitDef.GetMaxRange();
        return g.x >= 0.0f && MapHelpers::SqDist(g, pos) < r * r;
    }

    // Front_Commander_AiMakeTask: while fleeing, home is the only job.
    bool CommanderFleeing() { return ai.frame < commFleeUntil; }

    IUnitTask@ CommanderHomeTask()
    {
        return aiBuilderMgr.Enqueue(TaskB::Patrol(Task::Priority::HIGH, Global::Map::StartPos, Global::LandArmy::CommanderFleeSeconds * SECOND));
    }

    void CommanderTick()
    {
        if (commId < 0 || Global::AISettings::Role != AiRole::FRONT) return;
        CCircuitUnit@ comm = ai.GetTeamUnit(commId);
        if (comm is null) { commId = -1; return; }
        if (CommanderFleeing() || !CommanderInDanger(comm)) return;
        commFleeUntil = ai.frame + Global::LandArmy::CommanderFleeSeconds * SECOND;
        IUnitTask@ t = CommanderHomeTask();
        if (t is null) return;
        aiBuilderMgr.AssignTask(comm, t);
        if (++commFlees % 5 == 1)
            GenericHelpers::LogUtil("[LandArmy] commander " + comm.id + " runs home: an enemy group of "
                + int(Global::LandArmy::CommanderFleeMetal) + "+ metal within " + int(Global::LandArmy::CommanderFleeRangeMult * comm.circuitDef.GetMaxRange())
                + " (" + commFlees + " time(s))", 1);
    }

    // ---- Rezbots -----------------------------------------------------------
    // See Global::LandArmy::RezFirst. Factory weights alone (0.05 against 1.0
    // per combat unit) made none in 14 test games.
    array<string> RezBots = {"armrectr", "cornecro", "legrezbot"};
    IUnitTask@ rezPending = null;
    int rezTurn = 0;

    bool IsRezBot(const CCircuitDef@ d) { return d !is null && RezBots.find(d.GetName()) >= 0; }

    string RezBotFor(const string &in side)
    {
        return (side == "armada") ? "armrectr" : (side == "cortex") ? "cornecro" : "legrezbot";
    }

    int RezTarget()
    {
        const int n = Global::LandArmy::RezFirst + armyMade / Global::LandArmy::RezPerArmyUnits;
        return (n > Global::LandArmy::RezMax) ? Global::LandArmy::RezMax : n;
    }

    // Front_FactoryAiMakeTask, for a T1 bot lab once the rush is over.
    IUnitTask@ RezFactoryTask(CCircuitUnit@ lab)
    {
        if (lab is null || lab.circuitDef is null || Global::AISettings::Role != AiRole::FRONT || Rush::Active()) return null;
        if (!UnitHelpers::IsT1BotLab(lab.circuitDef.GetName())) return null;
        if (ScoutLabPhase()) return null;   // the scout lab makes scouts only
        if (rezPending !is null && !rezPending.IsDead()) return null;   // one at a time; the lab carries on meanwhile
        CCircuitDef@ d = ai.GetCircuitDef(RezBotFor(Global::AISettings::Side));
        if (d is null || !d.IsAvailable(ai.frame) || !lab.circuitDef.CanBuild(d)) return null;
        if (CountBuiltOrFramed(RezBots) + aiFactoryMgr.GetPendingRecruitCount(d) >= RezTarget()) return null;
        @rezPending = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::NORMAL, d, lab.GetPos(ai.frame), 64.0f));
        if (rezPending !is null)
            GenericHelpers::LogUtil("[LandArmy] rezbot " + d.GetName() + " " + (d.count + 1) + " of " + RezTarget() + " (" + armyMade + " army units made)", 1);
        return rezPending;
    }

    // Front_BuilderAiMakeTask, before anything else: a rezbot resurrects, and
    // reclaims every other turn, within RezRadius of the rally where the
    // waves form and the fights near our side leave their wrecks.
    IUnitTask@ RezBotTask(CCircuitUnit@ u)
    {
        if (u is null || !IsRezBot(u.circuitDef) || Global::AISettings::Role != AiRole::FRONT) return null;
        const AIFloat3 at = Rush::Enabled() ? Rush::RallyPos() : Global::Map::StartPos;
        ++rezTurn;
        if (rezTurn % 2 == 1)
            return aiBuilderMgr.Enqueue(TaskB::Resurrect(Task::Priority::NORMAL, at, 0.0f, 60 * SECOND, Global::LandArmy::RezRadius));
        return aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::NORMAL, at, 0.0f, 60 * SECOND, Global::LandArmy::RezRadius, true));
    }

    // ---- T2 lab gate and T1 lab retirement -------------------------------
    // No T2 bot lab before MinimumMetalIncomeForFirstT2Lab metal income
    // (sliding 10 s minimum): every T2 bot lab is capped at 0 below it while
    // none stands or is framed. One cap holds every path; played on All That
    // Glitters, native's factory switch (army cost over 1.2 x the lab's cost)
    // started a T2 lab on far less income than the script's own trigger.
    // While a T2 bot lab stands or is framed, no T1 bot lab is ordered, and
    // the T1 bot labs standing when it was framed are retired (production
    // stops) and reclaimed: their metal goes into the T2 lab (SMRTBARb TECH,
    // roles/tech_build.as ReclaimT1Lab). Losing the T2 lab lifts both caps.
    array<int> retiredT1Labs;
    int reclaimDeferLog = -100000;
    bool t2GateLogged = false;

    // The T2 lab's income: the sliding 10 s minimum averaged over the last
    // T2LabIncomeWindowSeconds. The 10 s minimum alone opened the gate on
    // reclaim: played on Starwatcher, a FRONT with five mexes read +37 for a
    // stretch of commander reclaim and framed its T2 lab on +10 real income.
    array<int> incomeFrames;
    array<float> incomeValues;
    float avgMinIncome = 0.0f;

    void SampleIncome(float income)
    {
        incomeFrames.insertLast(ai.frame);
        incomeValues.insertLast(income);
        const int oldest = ai.frame - Global::LandArmy::T2LabIncomeWindowSeconds * SECOND;
        while (incomeFrames.length() > 1 && incomeFrames[0] < oldest) {
            incomeFrames.removeAt(0);
            incomeValues.removeAt(0);
        }
        float sum = 0.0f;
        for (uint i = 0; i < incomeValues.length(); ++i) sum += incomeValues[i];
        avgMinIncome = sum / float(incomeValues.length());
    }

    bool T2LabIncomeMet()
    {
        return avgMinIncome >= Global::RoleSettings::Front::MinimumMetalIncomeForFirstT2Lab;
    }

    bool T2LabBegun()
    {
        array<string> labs = UnitHelpers::GetAllT2BotLabs();
        for (uint i = 0; i < labs.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(labs[i]);
            if (d !is null && (d.count > 0 || aiBuilderMgr.GetUnfinishedCount(d) > 0)) return true;
        }
        return false;
    }

    void ApplyLabGates(float income)
    {
        SampleIncome(income);
        const bool t2Begun = T2LabBegun();
        const bool t2Allowed = t2Begun || T2LabIncomeMet();
        if (t2Allowed && !t2Begun && !t2GateLogged) {
            t2GateLogged = true;
            GenericHelpers::LogUtil("[LandArmy] T2 lab allowed: income " + int(avgMinIncome) + " (10 s minimum, averaged over "
                + Global::LandArmy::T2LabIncomeWindowSeconds + " s)", 1);
        }
        array<string> t2 = UnitHelpers::GetAllT2BotLabs();
        if (Global::AISettings::Role == AiRole::FRONT) {
            // the first lab on the income gate, more as income grows (ProductionTask builds them)
            const int cap = !t2Allowed ? 0 : t2Begun ? T2LabsWanted(income) : 1;
            if (cap != lastT2LabCap && t2Begun) {
                GenericHelpers::LogUtil("[LandArmy] T2 lab cap " + cap + " at +" + int(income) + " metal income", 1);
                lastT2LabCap = cap;
            }
            for (uint i = 0; i < t2.length(); ++i) {
                CCircuitDef@ d = ai.GetCircuitDef(t2[i]);
                if (d !is null && d.maxThisUnit != cap) d.maxThisUnit = cap;
            }
        } else {
            for (uint i = 0; i < t2.length(); ++i) SetAllowed(t2[i], t2Allowed);
        }
        array<string> t1 = UnitHelpers::GetAllT1BotLabs();
        // No T1 bot lab once the T2 lab is under way, except the scout lab (one at a time)
        const bool scoutLab = t2Begun && ScoutLabPhase();
        const bool scoutLabStands = scoutLab && ActiveT1Lab() !is null;
        for (uint i = 0; i < t1.length(); ++i) {
            if (!scoutLab) { SetAllowed(t1[i], !t2Begun); continue; }
            CCircuitDef@ d = ai.GetCircuitDef(t1[i]);
            if (d is null) continue;
            const int cap = d.count + aiBuilderMgr.GetUnfinishedCount(d) + (scoutLabStands ? 0 : 1);
            if (d.maxThisUnit != cap) d.maxThisUnit = cap;
        }
        if (!t2Begun || Global::AISettings::Role != AiRole::FRONT) return;

        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ lab = ai.GetTeamUnit(ids[i]);
            if (lab is null || lab.circuitDef is null || !UnitHelpers::IsT1BotLab(lab.circuitDef.GetName())
                || Lifecycle::IsRetiring(lab)) continue;
            if (scoutLab) continue;   // the scout lab, until the gantry
            // native's recruit task would re-issue the build on idle; only a
            // recruit order is aborted (never the module's shared idle or wait task)
            if (lab.task !is null && Task::Type(lab.task.GetType()) == Task::Type::FACTORY) aiFactoryMgr.AbortTask(lab.task);
            Lifecycle::Retire(lab, "the T2 lab is under way; the T1 lab is reclaimed for its metal");
            retiredT1Labs.insertLast(int(lab.id));
        }
    }

    // A retired T1 lab within T1LabReclaimRadius of the builder, reclaimed
    // once the metal bank has room for its metal (past the cap it is lost).
    // Mobile builders only: turrets are never pulled onto it (see below).
    IUnitTask@ ReclaimT1LabTask(CCircuitUnit@ u)
    {
        if (u is null || retiredT1Labs.length() == 0) return null;
        const float r = Global::RoleSettings::Front::T1LabReclaimRadius;
        for (uint i = 0; i < retiredT1Labs.length(); ) {
            CCircuitUnit@ lab = ai.GetTeamUnit(retiredT1Labs[i]);
            if (lab is null) { retiredT1Labs.removeAt(i); continue; }
            ++i;
            if (lab is u || MapHelpers::SqDist(u.GetPos(ai.frame), lab.GetPos(ai.frame)) > r * r) continue;
            const float labMetal = lab.circuitDef.costM;
            if (aiEconomyMgr.metal.current + labMetal > aiEconomyMgr.metal.storage) {
                if (ai.frame - reclaimDeferLog > 30 * SECOND) {
                    reclaimDeferLog = ai.frame;
                    GenericHelpers::LogUtil("[LandArmy] T1 lab reclaim deferred: metal " + int(aiEconomyMgr.metal.current) + " of "
                        + int(aiEconomyMgr.metal.storage) + " leaves no room for its " + int(labMetal), 1);
                }
                return null;
            }
            IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, lab, 180 * SECOND));
            // No TurretsOnReclaim here: Marish's turrets belong to the factory
            // manager, and that builder-manager call left them owned by both,
            // which crashed four 8v8 games and the owner's (2026-10-04).
            return t;
        }
        return null;
    }

    // Economy::AiUpdateEconomy, after the role's handler, and once at the end of setup.
    void Apply(float income)
    {
        ApplyFactoryBans();
        ApplyLabGates(income);
        ApplyRoster(income);
        // The opening (manager/rush.as) builds its scouts and raiders whatever the step says
        Rush::Tick();
        if (Rush::Active()) {
            array<string> rush = Rush::Units();
            for (uint i = 0; i < rush.length(); ++i) SetAllowed(rush[i], true);
        }
        ApplySupportCaps();
        ApplyT2ConstructorCap(income);
        ApplyLRPCGate();
        CommanderTick();
        if (ScoutLabPhase()) SetAllowed(Rush::UnitFor("scout"), true);
    }
}
