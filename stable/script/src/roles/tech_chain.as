/******************************************************************************

TECH rush chain (D-070): one objective, one computed build chain, every
builder on it, then the ordinary economy.

`Tech::RushObjective` names the goal: t2, fusion, afus, nuke, gantry, titan,
eco (no chain) or auto (the role's own choice). `Init` turns the objective
and the map (effective wind, the home mex cluster) into an ordered list of
cumulative targets - "6 mex, 2 solars, the lab, 4 solars, the advanced lab,
2 T2 mex upgrades, 12 solars, a T2 turret, the advanced fusion" - the lines
the rush simulator found fastest (rjm.bar.docs tools/knowledge/rush_sim.py,
the rush table in 70-strategy/77-eco-tech-player.md). `Next(u)` is the
`chain.next` row of the rule table: the first target not yet met is the
current step; a builder assists it when its frame exists, waits briefly when
an order for it is out, orders it when it can build it, and otherwise hands
back null so the economy rows keep it useful. Constructor counts go through
the factory rules (`MinimumT1ConstructorBots`, `MinimumT2ConstructorBots`),
caps through `Tick`. When every target is met the chain is done, once, and
the table continues as if there had been no chain.

Trace: `[TECH][Chain] objective ...: <steps>` at init; `[TECH][Chain] step
k/n <key> <have>/<target>: ordered|assist|waiting by <def> <id>` on change;
`[TECH][Chain] complete at <s> s`.

******************************************************************************/
namespace TechChain
{
    class Step
    {
        string key;          // mex solar wind advsolar lab alab moho nano nanot2 fusion afus silo gantry
        string defName;
        int target;          // cumulative count of this def that must stand
        int base;            // D-100: the recipe's count; the moho step's target never drops under it
        float radius;        // mex steps: the spots within this of the start; 0 = the default
        bool exhausted;      // mex steps: no open spot left in the radius
        Step(const string &in k, const string &in d, int t, float r = 0.0f) { key = k; defName = d; target = t; base = t; radius = r; exhausted = false; }
    }

    string objective = "eco";
    array<Step@> steps;
    float bonus = 1.0f;        // D-072: the income multiplier this AI plays with (1 = zero bonus, the benchmark baseline)

    // The engine's per-team income multiplier (the lobby's handicap) times
    // the ai_incomemultiplier modoption. Deterministic, read once.
    float IncomeBonus()
    {
        float b = ai.GetIncomeMultiplier();
        if (b <= 0.0f) b = 1.0f;
        dictionary@ mo = aiSetupMgr.GetModOptions();
        if (mo !is null && mo.exists("ai_incomemultiplier")) {
            string v; mo.get("ai_incomemultiplier", v);
            const float m = parseFloat(v);
            if (m > 0.0f) b *= m;
        }
        return b;
    }
    int wantCk = 2;
    int wantAck = 1;
    bool active = false;
    bool done = false;
    int startFrame = 0;
    string lastTrace = "";
    int stallStep = -1;        // the step last seen as current ...
    int stallHave = -1;        // ... with this count ...
    int stallFrame = 0;        // ... since this frame; no progress for ChainStepStallSeconds skips it
    array<bool> skipped;
    int pendingStep = -1;      // an order for this step went out ...
    int pendingFrame = 0;      // ... at this frame; invisible to the queued and unfinished counts until its frame exists
    int pendingHave = -1;      // ... when the step's count was this; a higher count means it stood (played: a met order blocked the next for 120 s)

    bool Active() { return active && !done; }

    // D-084: a dear step (fusion, advanced lab, advanced fusion, silo, gantry)
    // has an order out and no frame yet: every builder belongs to it until
    // its frame exists (played: the advanced lab's order waited 95 s while
    // the builders converted and built turrets on a full bank).
    int dearPendingSince = -1;
    bool DearOrderPending()
    {
        if (!Active()) return false;
        for (uint i = 0; i < steps.length(); ++i) {
            Step@ s = steps[i];
            if (s.key == "income" || (i < skipped.length() && skipped[i])) continue;
            // D-101 (played: with the metal floating the builders went past the
            // upgrades (D-100), the last upgrade order waited with no frame, this
            // blocked the converters, energy floated 600 s and the chain held the
            // advanced fusion for the converters: none by 28 min): an upgrade is not
            // a dear order worth waiting on while the metal floats
            if (s.key == "moho" && TechBuild::MetalFullLong()) continue;
            CCircuitDef@ d = ai.GetCircuitDef(s.defName);
            if (d is null || d.costM < Global::RoleSettings::Tech::ChainParallelCostM) continue;
            if (Standing(s, d) >= s.target) continue;
            if (aiBuilderMgr.GetUnfinishedCount(d) > 0) return false;   // the frame exists: assists, turrets and converters as usual
            int queued = aiBuilderMgr.GetQueuedBuildCount(int(TypeFor(s.key)), d);
            if (s.key == "silo") queued += aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::BIG_GUN), d);
            const bool pending = (pendingStep == int(i)) && (ai.frame - pendingFrame < 120 * SECOND);
            return queued > 0 || pending;
        }
        return false;
    }
    float DearOrderPendingSeconds()
    {
        if (!DearOrderPending()) { dearPendingSince = -1; return 0.0f; }
        if (dearPendingSince < 0) dearPendingSince = ai.frame;
        return float(ai.frame - dearPendingSince) / float(SECOND);
    }

    string DefFor(const string &in key)
    {
        const string side = Global::AISettings::Side;
        if (key == "mex") return RoleTech::Tech_T1MexName(side);
        if (key == "moho") return UnitHelpers::GetT2MexNameForSide(side);
        if (key == "solar") return UnitHelpers::GetSolarNameForSide(side);
        if (key == "wind") return UnitHelpers::GetWindNameForSide(side);
        if (key == "advsolar") return UnitHelpers::GetAdvSolarNameForSide(side);
        if (key == "lab") return UnitHelpers::GetT1BotLabForSide(side);
        if (key == "alab") return UnitHelpers::GetT2BotLabForSide(side);
        if (key == "nano") return UnitHelpers::GetT1NanoNameForSide(side);
        if (key == "nanot2") { if (side == "cortex") return "cornanotct2"; if (side == "legion") return "legnanotct2"; return "armnanotct2"; }
        if (key == "fusion") return UnitHelpers::GetFusionNameForSide(side);
        if (key == "afus") return UnitHelpers::GetAdvFusionNameForSide(side);
        if (key == "silo") { if (side == "cortex") return "corsilo"; if (side == "legion") return "legsilo"; return "armsilo"; }
        if (key == "gantry") return UnitHelpers::GetLandGantryForSide(side);
        if (key == "aap") return UnitHelpers::GetT2AirPlantForSide(side);      // D-080
        if (key == "ap") return UnitHelpers::GetT1AirPlantForSide(side);       // D-103: its air constructor builds the advanced aircraft plant
        if (key == "lrpc") return UnitHelpers::GetLRPCNameForSide(side);       // D-080
        return "";
    }

    bool IsEnergyKey(const string &in key)
    {
        return key == "wind" || key == "solar" || key == "advsolar" || key == "fusion" || key == "afus";
    }

    // D-079 (owner's rule): energy is sufficient when the bank sits at
    // EcoConvertEnergyPercent of storage for ChainEnergyFloatSeconds (the pull is
    // not read); then no energy structure is ordered, whoever
    // asks: the surplus goes to converters and the AI chases metal. Played:
    // the advanced fusion was ordered at +1,450 energy over a full 10k bank.
    // The engine's pull is inflated by the build in progress (played: +1,159
    // over the pull a second after an order made at a full bank), so the bank
    // is read: full for ChainEnergyFloatSeconds means nothing can spend it.
    int energyFullSince = -1;
    array<float> energyBank;   // one sample a second, the last ChainEnergyFloatSeconds
    void TrackEnergy()
    {
        const float stor = aiEconomyMgr.energy.storage;
        const bool full = (stor > 0.0f) && (aiEconomyMgr.energy.current >= Global::RoleSettings::Tech::EcoConvertEnergyPercent * stor);
        if (!full) energyFullSince = -1;
        else if (energyFullSince < 0) energyFullSince = ai.frame;
        energyBank.insertLast(aiEconomyMgr.energy.current);
        const uint keep = uint(Global::RoleSettings::Tech::ChainEnergyFloatSeconds) + 1;
        while (energyBank.length() > keep) energyBank.removeAt(0);
    }
    bool EnergyRising() { return energyBank.length() >= 2 && energyBank[energyBank.length() - 1] - energyBank[0] >= Global::RoleSettings::Tech::ChainEnergyFloatRise; }
    float EnergyFullSeconds() { return (energyFullSince < 0) ? 0.0f : float(ai.frame - energyFullSince) / float(SECOND); }
    bool EnergyFloats()
    {
        if (EnergyFullSeconds() >= Global::RoleSettings::Tech::ChainEnergyFloatSeconds) return true;
        // a full bank with income clearly over the pull is floating now, however new
        // (played: the advanced fusion ordered 15 s after the fusion at +1,291)
        const float surplus = aiEconomyMgr.energy.income - aiEconomyMgr.energy.pull;
        if (energyFullSince >= 0 && surplus > Global::RoleSettings::Tech::ChainEnergyFloatMax) return true;
        // the bank rising with the surplus: floating within seconds, whatever
        // the level (played: the advanced fusion ordered the second the fusion
        // finished, bank 30 % and climbing at +700; a positive surplus reading
        // is honest, the build in progress can only make it smaller)
        return EnergyRising() && surplus > Global::RoleSettings::Tech::ChainEnergyFloatMax;
    }
    string FloatWhy()
    {
        return "energy floats (bank " + int(aiEconomyMgr.energy.current) + " of " + int(aiEconomyMgr.energy.storage) + " full for " + int(EnergyFullSeconds())
            + " s, +" + int(aiEconomyMgr.energy.income - aiEconomyMgr.energy.pull) + " over the pull): converters first";
    }

    Task::BuildType TypeFor(const string &in key)
    {
        if (key == "mex") return Task::BuildType::MEX;
        if (key == "moho") return Task::BuildType::MEXUP;
        if (key == "lab" || key == "alab" || key == "gantry" || key == "silo" || key == "aap" || key == "ap") return Task::BuildType::FACTORY;
        if (key == "lrpc") return Task::BuildType::BIG_GUN;   // D-080
        if (key == "nano" || key == "nanot2") return Task::BuildType::NANO;
        return Task::BuildType::ENERGY;
    }

    // D-103: air constructors of ours, T1 and T2
    int AirConstructors()
    {
        const string side = Global::AISettings::Side;
        int n = 0;
        CCircuitDef@ a1 = ai.GetCircuitDef(UnitHelpers::GetT1AirConstructorNameForSide(side));
        CCircuitDef@ a2 = ai.GetCircuitDef(UnitHelpers::GetT2AirConstructorNameForSide(side));
        if (a1 !is null) n += a1.count;
        if (a2 !is null) n += a2.count;
        return n;
    }

    void Add(const string &in key, int target, float radius = 0.0f)
    {
        steps.insertLast(Step(key, DefFor(key), target, radius));
    }

    // Expected turbine output: the average of the map's min and max wind,
    // capped at a turbine's 25 (the wind walks between the bounds; the
    // storage the economy rows add rides out the lulls).
    float WindExpected()
    {
        float avg = (ai.GetWindMin() + ai.GetWindMax()) * 0.5f;
        if (avg > 25.0f) avg = 25.0f;
        if (avg < 0.0f) avg = 0.0f;
        return avg;
    }

    // Turbines or solars, from the numbers: metal per E/s of a turbine at the
    // expected wind against the solar's, with a margin, and a max wind worth
    // riding the lulls for (Supreme Isthmus: min 1, max 19 -> 4.3 metal per
    // E/s against the solar's 7.8: turbines).
    string EnergyChoice(string &out why)
    {
        const string side = Global::AISettings::Side;
        CCircuitDef@ wind = ai.GetCircuitDef(UnitHelpers::GetWindNameForSide(side));
        CCircuitDef@ solar = ai.GetCircuitDef(UnitHelpers::GetSolarNameForSide(side));
        const float avg = WindExpected();
        if (wind is null || solar is null || avg < 1.0f) { why = "no turbine def or no wind"; return "solar"; }
        const float windMetalPerE = wind.costM / avg;
        const float solarMetalPerE = solar.costM / 20.0f;
        const bool useWind = (windMetalPerE * Global::RoleSettings::Tech::ChainWindMargin < solarMetalPerE)
            && (ai.GetWindMax() >= Global::RoleSettings::Tech::ChainWindMaxMin);
        why = "wind " + int(ai.GetWindMin()) + " to " + int(ai.GetWindMax()) + ", expected " + int(avg) + ", now " + int(ai.GetWindCur())
            + ": " + int(windMetalPerE * 10.0f) / 10.0f + " metal per E/s a turbine, " + int(solarMetalPerE * 10.0f) / 10.0f + " a solar";
        return useWind ? "wind" : "solar";
    }

    // The role's own pick when the setting says auto: the advanced fusion,
    // the eco player's core structure; the benchmarks set the others.
    string Choose()
    {
        return "afus";
    }

    void Init()
    {
        steps.resize(0);
        active = false; done = false;
        if (MetalEconomy::Active()) return; // field growth has no finite mex/converter recipe
        stallStep = -1; stallHave = -1; stallFrame = 0; pendingStep = -1;
        objective = Global::RoleSettings::Tech::RushObjective;
        if (objective == "auto") objective = Choose();
        if (!Global::RoleSettings::Tech::ExperimentalBuild || objective == "eco" || objective.length() == 0) {
            GenericHelpers::LogUtil("[TECH][Chain] no rush objective: the economy rules run from the start", 1);
            return;
        }
        string windWhy;
        const string energy = EnergyChoice(windWhy);
        const bool useWind = (energy == "wind");
        // solar counts from the simulator; turbines scaled to the same energy;
        // an income bonus (D-072: the engine's multiplier from the lobby's
        // handicap, times the ai_incomemultiplier modoption) makes every
        // generator and mex give more, so the counts shrink by it
        bonus = IncomeBonus();
        float scale = 1.0f / bonus;
        if (useWind) scale *= 20.0f / WindExpected();
        // played: the advanced lab starves on four solars (constructors and mexes drain what the simulator did not model) and floats energy on eight: six before it
        int e1 = int(2.0f * scale + 0.5f), e2 = int(6.0f * scale + 0.5f), e3 = int(14.0f * scale + 0.5f), e4 = int(10.0f * scale + 0.5f);
        const int mexes = Global::RoleSettings::Tech::ChainMaxMexes;
        wantCk = 2; wantAck = 1;

        // The commander claims the opening's home mexes (the spots within
        // OpeningMexRadius, at most OpeningMexCap: three on Supreme Isthmus,
        // one or none on other maps) and drops the lab at once; the far spots
        // are the constructors' (played: a commander sent 1,500 elmos out for
        // a fourth mex before the lab).
        Add("mex", Global::RoleSettings::Tech::OpeningMexCap, Global::RoleSettings::Tech::OpeningMexRadius);
        Add("lab", 1);
        Add(energy, e1);
        Add("mex", mexes, Global::RoleSettings::Tech::ChainMexFarRadius);
        Add(energy, e2);
        Add("alab", 1);
        if (objective == "fusion") {
            Add("fusion", 1);
        } else if (objective == "afus") {
            // owner's rule (D-072): the T2 mex upgrades before the fusion; the energy
            // block ahead of both because the upgrades drain 7,700 each and, in the
            // game, energy is the constraint after the advanced lab.
            // The T2 turret needs the extra-units pack (not in play): two T1
            // turrets carry the build power.
            wantAck = 2;
            Add(energy, e3); Add("moho", 2); Add("fusion", 1); Add("nano", 2); Add("afus", 1);
        } else if (objective == "nuke") {
            wantAck = 2;
            // played: two advanced solars cost four minutes on an energy-starved base; the fusion and the solars carry the silo
            Add(energy, e3); Add("moho", 2); Add("fusion", 1); Add("nano", 2); Add("silo", 1);
        } else if (objective == "gantry") {
            wantAck = 2;
            Add(energy, e3); Add("moho", 2); Add("fusion", 1); Add("nano", 2); Add("gantry", 1);
        } else if (objective == "titan") {
            wantAck = 2;
            Add(energy, e3); Add("moho", 4); Add("fusion", 1); Add("nano", 2); Add("gantry", 1);
        } else if (objective != "t2") {
            GenericHelpers::LogUtil("[TECH][Chain] unknown objective '" + objective + "': treated as t2", 1);
            objective = "t2";
        }
        active = true;
        startFrame = ai.frame;
        skipped.resize(steps.length());
        for (uint i = 0; i < skipped.length(); ++i) skipped[i] = false;
        Global::RoleSettings::Tech::MinimumT1ConstructorBots = wantCk;
        Global::RoleSettings::Tech::MinimumT2ConstructorBots = wantAck;
        // The chain owns the mexes: the opening's rows stay quiet.
        RoleTech::Opening::Finish("the rush chain owns the opening");
        string line = "";
        for (uint i = 0; i < steps.length(); ++i) line += (i > 0 ? ", " : "") + steps[i].key + " " + steps[i].target;
        GenericHelpers::LogUtil("[TECH][Chain] objective " + objective + " (" + energy + ": " + windWhy + "; income bonus x"
            + int(bonus * 100.0f) / 100.0f + "; " + wantCk + " T1 cons, " + wantAck + " T2 cons): " + line, 1);
        Tick();
    }

    // Caps re-asserted every economy update: the start caps and the merged
    // map limits would otherwise hide a solar past the fourth, a fusion, a
    // gantry or a silo from IsAvailable.
    // D-100: the moho step is not met and a mex within ChainMexFarRadius is
    // still T1 with no upgrade under way: the fusion waits for the upgrades
    bool MohosPending()
    {
        if (!Active() || TechBuild::MetalFullLong() || Global::RoleSettings::Tech::ChainMohoRadius <= 0.0f) return false;   // metal floating: the upgrades are not what it waits on
        for (uint i = 0; i < steps.length(); ++i) {
            Step@ s = steps[i];
            if (s.key != "moho" || (i < skipped.length() && skipped[i])) continue;
            CCircuitDef@ d = ai.GetCircuitDef(s.defName);
            if (d is null || Standing(s, d) >= s.target) return false;
            const AIFloat3 t1 = Economy::MexTracker::GetNearestNonUpgradedMexInRange(Global::Map::StartPos, Global::Map::StartPos,
                Global::RoleSettings::Tech::ChainMohoRadius);
            return t1.x >= 0.0f;
        }
        return false;
    }

    void Tick()
    {
        TrackEnergy();   // D-079
        Layout::TickSets();   // D-101
        if (!Active()) return;
        for (uint i = 0; i < steps.length(); ++i) {
            // D-100 (owner: the fusion started with the mexes near it still T1; it
            // would have come sooner upgraded): the moho step upgrades every mex of
            // ours within ChainMexFarRadius, the ground the mex steps took, the
            // recipe's count at least
            if (steps[i].key == "moho" && Global::RoleSettings::Tech::ChainMohoRadius > 0.0f) {
                const int near = Economy::MexTracker::GetOwnedMexCountInRange(Global::Map::StartPos, Global::RoleSettings::Tech::ChainMohoRadius);
                const int want = (near > steps[i].base) ? near : steps[i].base;
                if (want != steps[i].target) {
                    GenericHelpers::LogUtil("[TECH][Chain] moho step: " + want + " (every mex within " + int(Global::RoleSettings::Tech::ChainMohoRadius)
                        + " of the start, " + near + " owned; the recipe's " + steps[i].base + " at least)", 1);
                    steps[i].target = want;
                }
            }
            CCircuitDef@ d = ai.GetCircuitDef(steps[i].defName);
            if (d is null) continue;
            if (d.maxThisUnit < steps[i].target) d.maxThisUnit = steps[i].target;
        }
    }

    int Standing(const Step@ s, CCircuitDef@ d)
    {
        int have = d.count - aiBuilderMgr.GetUnfinishedCount(d);
        if (s.key == "mex") {
            CCircuitDef@ m = ai.GetCircuitDef(DefFor("moho"));
            if (m !is null) have += m.count;
        }
        return have;
    }

    void Trace(const string &in what, int i, const Step@ s, int have, CCircuitUnit@ u)
    {
        const string key = s.key + "|" + i + "|" + what + "|" + have;
        const bool changed = (key != lastTrace);
        lastTrace = key;
        GenericHelpers::LogUtil("[TECH][Chain] step " + (i + 1) + "/" + steps.length() + " " + s.key + " " + have + "/" + s.target + ": " + what
            + " by " + u.circuitDef.GetName() + " " + u.id, changed ? 1 : 3);
    }

    IUnitTask@ Order(int i, Step@ s, CCircuitDef@ d, CCircuitUnit@ u)
    {
        const string key = s.key;
        if (key == "mex") {
            const float radius = (s.radius > 0.0f) ? s.radius : Global::RoleSettings::Tech::OpeningMexRadius;
            // ally-aware (D-072): the allies' ground and the spots nearer their starts are theirs
            IUnitTask@ t = aiEconomyMgr.EnqueueMexWithin(u, Global::Map::StartPos, radius, 0, true);
            if (t is null && aiEconomyMgr.GetMexTaskCountWithin(Global::Map::StartPos, radius) == 0) {
                s.exhausted = true;
                GenericHelpers::LogUtil("[TECH][Chain] no open mex spot within " + int(radius) + ": mex step " + (i + 1) + " ends at " + Standing(s, d), 1);
            }
            return t;
        }
        if (key == "lab") return TechBuild::StartFactory(u);
        if (key == "alab") return Layout::T2LabTask(300 * SECOND);
        if (key == "moho") {
            AIFloat3 at = Economy::MexTracker::GetNearestNonUpgradedMexInRange(u.GetPos(ai.frame), Global::Map::StartPos, Global::RoleSettings::MexUpgradeRadius);
            if (at.x < 0.0f) return null;
            return aiBuilderMgr.Enqueue(TaskB::Spot(Task::BuildType::MEXUP, Task::Priority::NOW, d, at, -1));
        }
        if (key == "nano") return Layout::NanoTask(u, Task::Priority::HIGH);
        if (key == "silo") return Builder::EnqueueNukeSilo(Global::AISettings::Side, Layout::BaseCentre(), SQUARE_SIZE * 32, 300 * SECOND);
        if (key == "gantry") {
            bool routed;   // D-114: a front factory cluster from +200 metal
            IUnitTask@ ft = TechFactories::Route(UnitHelpers::GetLandGantryForSide(Global::AISettings::Side), u, routed);
            if (routed) return ft;
            return Builder::EnqueueLandGantry(Global::AISettings::Side);
        }
        // D-103: both air plants placed by the layout (a turret stands); the old
        // spiral only when the layout has no site
        if (key == "ap" || key == "aap") {
            IUnitTask@ lt = Layout::OrderFactory(d, 300 * SECOND);
            if (lt !is null) return lt;
            if (key == "ap") return Builder::EnqueueT1AirFactory(Global::AISettings::Side, Layout::BaseCentre(), SQUARE_SIZE * 32, 300 * SECOND);
        }
        if (key == "aap") return Builder::EnqueueT2AirPlant(Global::AISettings::Side, Layout::BaseCentre(), SQUARE_SIZE * 32, 300 * SECOND);   // D-080
        // D-080 phase 1: the cannon at the start position, native's site search;
        // high ground with sight beyond the front is KI-418
        if (key == "lrpc") return Builder::EnqueueLRPC(Global::AISettings::Side, Global::Map::StartPos, 400.0f, 300 * SECOND, Task::Priority::HIGH);
        // energy, the T2 turret: the turret box first, then the nearest free
        // footprint to the base centre (native packs it, D-066)
        if (key == "wind" && ai.GetWindCur() < Global::RoleSettings::Tech::ChainWindBootstrap) {
            // the first generator while the wind is down is a solar: a turbine
            // costs 175 energy the bank must lend and gives nothing back yet
            CCircuitDef@ solar = ai.GetCircuitDef(DefFor("solar"));
            CCircuitDef@ w = d;
            if (solar !is null && (w.count + solar.count) == 0) {
                GenericHelpers::LogUtil("[TECH][Chain] wind is " + int(ai.GetWindCur()) + " now and nothing generates: the first energy is a solar", 1);
                @d = solar;
            }
        }
        const Task::BuildType type = TypeFor(key);
        // short timeouts: an order nobody reaches is released in two minutes,
        // and the chain simply orders again
        IUnitTask@ t = Layout::Place(type, Task::Priority::HIGH, d, 120 * SECOND, u);
        if (t is null) {
            Invariants::Violation("INV-014", d.GetName(), d.GetName() + " ordered outside the layout (no room in the turret boxes): native's site search around the base centre");   // D-082
            @t = aiBuilderMgr.Enqueue(TaskB::Common(type, Task::Priority::HIGH, d, Layout::BaseCentre(), 600.0f, true, 120 * SECOND));
        }
        return t;
    }

    // D-074 (owner's rule, deterministic): while the T1 lab stands and no T1
    // constructor is alive, the commander's 300 build power goes on the lab -
    // the first constructor out is the early game's build power.
    int firstConLog = -100000;
    IUnitTask@ CommanderOnFirstConstructor(CCircuitUnit@ u)
    {
        if (!UnitHelpers::IsCommander(u.circuitDef)) return null;
        CCircuitUnit@ lab = Factory::primaryT1BotLab;
        if (lab is null || lab is u || Lifecycle::IsRetiring(lab)) return null;   // D-076
        if (TechFactories::IsSpamLab(lab)) return null;   // D-119
        if (UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1BotConstructors()) > 0) return null;
        IUnitTask@ g = GuardHelpers::AssignWorkerGuard(u, lab, Task::Priority::HIGH, true, 20 * SECOND);
        if (g !is null && ai.frame - firstConLog > 30 * SECOND) {
            firstConLog = ai.frame;
            GenericHelpers::LogUtil("[TECH][Chain] the commander assists the T1 lab until the first constructor is out", 1);
        }
        return g;
    }

    IUnitTask@ Next(CCircuitUnit@ u)
    {
        if (!Active() || u is null || u.circuitDef is null) return null;
        {
            IUnitTask@ g = CommanderOnFirstConstructor(u);
            if (g !is null) return g;
        }
        // D-075: a cheap step's frame beside the builder is finished before
        // anything else (played: two turret frames were left to decay while
        // every builder walked to the fusion, which comes first in the chain)
        {
            const AIFloat3 here = u.GetPos(ai.frame);
            for (uint i = 0; i < steps.length(); ++i) {
                Step@ s = steps[i];
                CCircuitDef@ d = ai.GetCircuitDef(s.defName);
                if (d is null || (i < skipped.length() && skipped[i])) continue;
                if (d.costM >= Global::RoleSettings::Tech::ChainParallelCostM) continue;
                if (IsEnergyKey(s.key) && TechBuild::EnergyRetired(s.defName)) continue;   // D-077
                const int have = Standing(s, d);
                if (have >= s.target || aiBuilderMgr.GetUnfinishedCount(d) == 0) continue;
                CCircuitUnit@ frame = aiBuilderMgr.FindUnfinishedNear(here, Global::RoleSettings::Tech::ChainNearFrameRadius, d);
                if (frame is null) continue;
                Trace("finishes the frame beside it", int(i), s, have, u);
                return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, frame, 60 * SECOND));
            }
        }
        bool unmet = false;   // some step is not met, whether or not this builder could help
        for (uint i = 0; i < steps.length(); ++i) {
            Step@ s = steps[i];
            // D-080: an income step is climbed, not built: converters while energy
            // floats, T2 mex upgrades, the next advanced fusion, until metal income
            // reaches the target (the economy rows get the builder when the ladder
            // has nothing for it)
            if (s.key == "income") {
                if (Economy::GetMinMetalIncomeLast10s() >= float(s.target)) continue;
                unmet = true;
                return Ladder(u, int(i), s);
            }
            CCircuitDef@ d = ai.GetCircuitDef(s.defName);
            if (d is null) continue;
            if (s.key == "mex" && s.exhausted) continue;
            // an energy step the veto refuses (a fusion stands, D-077) is met from
            // then on: its turbines were reclaimed on purpose (played: the chain
            // rebuilt them and never completed)
            if (IsEnergyKey(s.key) && TechBuild::EnergyRetired(s.defName)) continue;
            // the first lab is reclaimed once the advanced lab begins (D-066): its step is met from then on
            if (s.key == "lab" && TechBuild::WasIntoT2()) continue;   // D-102: met for good once the T2 phase has begun
            // the advanced lab is reclaimed once the advanced fusion is under way (D-078): its step is met from then on
            if (s.key == "alab" && TechBuild::IntoAfus()) continue;
            if (i < skipped.length() && skipped[i]) continue;
            const int have = Standing(s, d);
            if (have >= s.target) continue;
            unmet = true;
            const int unfinished = aiBuilderMgr.GetUnfinishedCount(d);
            // the current step: no progress for ChainStepStallSeconds skips it;
            // a frame under construction is progress (D-075; played: the
            // fusion was skipped at 11:21 while it was being built)
            // D-103: the advanced aircraft plant waits for the T1 air plant's air
            // constructor (only air constructors build it): not a stall
            // D-104: nor while the air constructor lives and the plant is not yet
            // framed (played: skipped while the constructor walked to the site)
            const bool waitsForAirCon = (s.key == "aap") && (AirConstructors() == 0 || unfinished == 0);
            if (stallStep != int(i) || stallHave != have || unfinished > 0 || waitsForAirCon) { stallStep = int(i); stallHave = have; stallFrame = ai.frame; }
            else if (i + 1 < steps.length() && ai.frame - stallFrame > int(Global::RoleSettings::Tech::ChainStepStallSeconds) * SECOND) {
                // never the objective itself (played: an advanced fusion whose site
                // the engine refused was skipped and the chain declared itself done)
                skipped[i] = true;
                Invariants::ChainStepSkipped(s.key, unfinished);   // D-076: INV-003
                if (s.key == "aap" || s.key == "ap")   // INV-027 (D-103): the air labs are built, not skipped
                    Invariants::Violation("INV-027", s.key, "the " + s.key + " step made no progress for " + int(Global::RoleSettings::Tech::ChainStepStallSeconds) + " s and was skipped");
                GenericHelpers::LogUtil("[TECH][Chain] step " + (i + 1) + "/" + steps.length() + " " + s.key + " " + have + "/" + s.target
                    + " made no progress for " + int(Global::RoleSettings::Tech::ChainStepStallSeconds) + " s: skipped", 1);
                continue;
            }
            int queued = aiBuilderMgr.GetQueuedBuildCount(int(TypeFor(s.key)), d);
            if (s.key == "silo") queued += aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::BIG_GUN), d);
            bool can = u.circuitDef.CanBuild(d);
            // the far mex step belongs to the constructors: the commander stays home
            if (s.key == "mex" && s.radius > Global::RoleSettings::Tech::OpeningMexRadius && UnitHelpers::IsCommander(u.circuitDef)) can = false;
            const bool cheap = (d.costM < Global::RoleSettings::Tech::ChainParallelCostM);
            // An order of this step that lost its builder (played: the engine drops
            // a builder off a fresh order without any event) is taken over by the
            // next builder that can build it, before anything else is ordered.
            if (queued > 0 && can) {
                IUnitTask@ q = aiBuilderMgr.FindQueuedTask(u, int(TypeFor(s.key)));
                IBuilderTask@ qb = (q is null) ? null : cast<IBuilderTask>(q);
                if (qb !is null && qb.buildDef is d) { Trace("takes the queued order", int(i), s, have, u); return q; }
            }
            // an order of ours that has no frame yet is invisible to both counts
            const bool pending = (pendingStep == int(i)) && (have == pendingHave) && (unfinished == 0) && (ai.frame - pendingFrame < 120 * SECOND);
            const int inFlight = unfinished + queued + (pending ? 1 : 0);
            if (cheap) {
                // one per builder, in parallel: a solar is not worth a walk to assist
                if (can && have + inFlight < s.target && IsEnergyKey(s.key) && EnergyFloats() && !TechBuild::MetalFullLong()) {   // D-105: no converter hold with the metal bank full
                    stallFrame = ai.frame;   // waiting for need is not a stall (D-079)
                    Trace(FloatWhy(), int(i), s, have, u);
                    continue;
                }
                if (can && have + inFlight < s.target) {
                    IUnitTask@ t = Order(int(i), s, d, u);
                    if (t !is null) { pendingStep = int(i); pendingFrame = ai.frame; pendingHave = have; Trace("ordered", int(i), s, have + inFlight, u); return t; }
                }
                if (unfinished > 0) {
                    // near first; when nothing else is left to order, anywhere
                    CCircuitUnit@ frame = aiBuilderMgr.FindUnfinishedNear(u.GetPos(ai.frame), 600.0f, d);
                    // D-097: a turret step at its parallel limit assists the turret going up, wherever it is
                    if (frame is null && (have + inFlight >= s.target || (s.key == "nano" && Layout::TurretsCapped())))
                        @frame = aiBuilderMgr.FindUnfinishedNear(Layout::BaseCentre(), Global::RoleSettings::Tech::ChainAssistRadius, d);
                    if (frame !is null) { Trace("assist", int(i), s, have, u); return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, frame, 60 * SECOND)); }
                }
                if (s.key == "mex" && s.exhausted) continue;
                // a builder that cannot build this step goes on to the next it can
                // (played: the commander idled two minutes while the constructors
                // fetched the far mexes); one that can, but has nothing to add,
                // is the economy rows' until the step stands
                // nothing to add to a cheap step in flight: on to the next step
                // (played: the advanced lab waited 84 s for the last turbine);
                // said at level 1 when the counts change (D-075: a turret step
                // went silent for four minutes)
                if (can) Trace("nothing to add (unfinished " + unfinished + ", queued " + queued + (pending ? ", pending" : "") + ")", int(i), s, have, u);
                continue;
            }
            // D-100: with the metal bank full for PowerAheadSeconds the upgrades are
            // not what the metal waits on (played: 9 upgrades one at a time, the
            // fusion 3 min later, 12,747 metal banked): an upgrade in flight keeps its
            // builder and the next builder goes on to the next step
            if (s.key == "moho" && (unfinished > 0 || queued > 0 || pending) && TechBuild::MetalFullLong()) {
                Trace("metal floats: an upgrade is in flight, on to the next step", int(i), s, have, u);
                continue;
            }
            if (unfinished > 0) {
                CCircuitUnit@ frame = aiBuilderMgr.FindUnfinishedNear(Layout::BaseCentre(), Global::RoleSettings::Tech::ChainAssistRadius, d);
                if (frame !is null) {
                    Trace("assist", int(i), s, have, u);
                    return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, frame, 60 * SECOND));
                }
            }
            if (!can) continue;   // the next step this builder can build
            if (queued > 0 || pending) {
                // an order is out and no frame exists yet: the economy rows keep
                // this builder useful (played: waiting here stalled the base for
                // the five minutes an abandoned solar order took to time out)
                Trace("order out; economy meanwhile", int(i), s, have, u);
                return null;
            }
            if (IsEnergyKey(s.key) && EnergyFloats() && !TechBuild::MetalFullLong()) {   // D-105
                stallFrame = ai.frame;   // waiting for need is not a stall (D-079)
                Trace(FloatWhy(), int(i), s, have, u);
                return null;   // the economy rows: energy.convert eats the surplus
            }
            // D-098 (owner's rule): a dear frame and a turret at once stall the
            // early economy; with a turret going up and no build-power slot free
            // for this step (Layout::TurretSlots), every hand finishes the turret
            // first, then the step is ordered with that power
            if (!Layout::BuildSlotFree()) {
                CCircuitUnit@ tf = Layout::TurretFrame();
                if (tf !is null) {
                    Trace("finishes the turret first (no build-power slot)", int(i), s, have, u);
                    return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, tf, 60 * SECOND));
                }
            }
            IUnitTask@ t = Order(int(i), s, d, u);
            if (t !is null) { pendingStep = int(i); pendingFrame = ai.frame; pendingHave = have; Trace("ordered", int(i), s, have, u); return t; }
            if (s.key == "mex" && s.exhausted) continue;
            Trace("cannot order yet", int(i), s, have, u);
            return null;
        }
        if (unmet) return null;   // this builder skipped what it cannot build; the chain goes on
        if (!done) {
            done = true;
            GenericHelpers::LogUtil("[TECH][Chain] complete: objective " + objective + " reached at " + int((ai.frame - startFrame) / SECOND)
                + " s; the economy rules continue", 1);
            // D-080: the plan's next phase, if it has one
            array<Step@>@ next = TechPlan::NextPhase(objective);
            if (next !is null && next.length() > 0) {
                steps = next;
                skipped.resize(0); skipped.resize(steps.length());
                stallStep = -1; stallHave = -1; stallFrame = 0; pendingStep = -1;
                done = false; startFrame = ai.frame;
                objective = TechPlan::PhaseName();
                string line = "";
                for (uint i = 0; i < steps.length(); ++i) line += (i > 0 ? ", " : "") + steps[i].key + " " + steps[i].target;
                GenericHelpers::LogUtil("[TECH][Chain] plan " + objective + ": " + line, 1);
            }
        }
        return null;
    }

    // D-080: one rung of the metal ladder for this builder.
    IUnitTask@ Ladder(CCircuitUnit@ u, int i, Step@ s)
    {
        const int have = int(Economy::GetMinMetalIncomeLast10s());
        if (EnergyFloats() && !TechBuild::MetalFullLong()) { Trace(FloatWhy(), i, s, have, u); return null; }   // energy.convert.float; D-105
        // T2 mex upgrades first: the cheapest metal there is
        CCircuitDef@ moho = ai.GetCircuitDef(DefFor("moho"));
        if (moho !is null && u.circuitDef.CanBuild(moho)) {
            Step tmp("moho", DefFor("moho"), 99);
            IUnitTask@ t = Order(i, @tmp, moho, u);
            if (t !is null) { Trace("mex upgrade", i, s, have, u); return t; }
        }
        // then the next advanced fusion, every builder on one frame
        CCircuitDef@ afus = ai.GetCircuitDef(DefFor("afus"));
        if (afus is null) return null;
        const int building = aiBuilderMgr.GetUnfinishedCount(afus);
        // a full metal bank means the ladder is build-power and order bound, not
        // metal bound: another advanced fusion in parallel, up to LadderParallelAfus
        const bool another = TechBuild::MetalFullLong() && building < Global::RoleSettings::Tech::LadderParallelAfus && u.circuitDef.CanBuild(afus);
        if (building > 0 && !another) {
            CCircuitUnit@ frame = aiBuilderMgr.FindUnfinishedNear(Layout::BaseCentre(), Global::RoleSettings::Tech::ChainAssistRadius, afus);
            if (frame !is null) { Trace("assist the advanced fusion", i, s, have, u); return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, frame, 60 * SECOND)); }
        }
        if (!u.circuitDef.CanBuild(afus)) return null;
        if (aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::ENERGY), afus) > 0) { Trace("advanced fusion order out", i, s, have, u); return null; }
        Step tmp2("afus", DefFor("afus"), 99);
        IUnitTask@ t2 = Order(i, @tmp2, afus, u);
        if (t2 !is null) Trace("advanced fusion ordered", i, s, have, u);
        return t2;
    }

    // D-080: an income step of the current phase is unmet (INV-011).
    bool LadderUnmet()
    {
        if (!Active()) return false;
        for (uint i = 0; i < steps.length(); ++i)
            if (steps[i].key == "income" && Economy::GetMinMetalIncomeLast10s() < float(steps[i].target)) return true;
        return false;
    }
}
