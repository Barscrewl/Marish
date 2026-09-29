#include "define.as"
// Strategies enum and helpers
#include "types/strategy.as"
//#include "types/profile.as"
#include "types/profile_controller.as"

// D-077: a role may veto an energy def by name before any act orders it (the
// shared builder helpers and the eco planner ask); TECH sets it to
// TechBuild::EnergyAllowed so no wind or solar is ordered once a fusion
// stands and no advanced solar once an advanced fusion is under way.
funcdef bool EnergyAllowedFn(const string &in defName);

namespace Global {

    EnergyAllowedFn@ energyAllowed = null;

    namespace Map {
        StartSpot@ NearestMapStartPosition;

        // Commander start capture state (populated via Main::AiUnitAdded)
        bool HasStart = false;
        AIFloat3 StartPos(0,0,0);
        AiRole StartRole = AiRole::FRONT;
    
        const float BASE_RADIUS = 1400.0f; // tune
        
        bool MapResolved;
        string MapName;
        bool LandLocked;

        MapConfig Config;

        // Merged map + role unit limits for this game
        // Populated during Setup::setupMap via LimitsHelpers
        dictionary MergedUnitLimits;
    }

    namespace Lookups {
        dictionary LabTerrainDict = UnitHelpers::GetLabsTerrainDict();
    }

    namespace AISettings {
        AiRole Role;
        string Side; // faction side (armada/cortex/legion)
        string StartFactory;
        RoleConfig@ RoleCfg;
    }

    // Mod options pulled from engine/lobby; set during Setup::CheckModOptions
    namespace ModOptions {
        // Set in Setup::CheckModOptions. Content options gate whole unit tiers,
        // so policy that picks units - the porcupine chain above all - has to
        // know which are on.
        bool ExperimentalLegionFaction = false;
        bool ExperimentalExtraUnits = false;
        bool ScavUnitsForPlayers = false;
        int MapWaterLevel = 0;
        bool MapWaterIsLava = false;
        int MaxUnits = 0;
    }

	ProfileController profileController;

    // Shared porcupine (static defence) policy, see manager/porc_policy.as.
    // Applies to every role without its own AiMakeDefenceHandler; TECH routes
    // through it after its own income gate.
    namespace Porc {
        // Late game: from either threshold on, every visited cluster may take the
        // full porcupine order within its income budget (native mode FULL). Before
        // that the native front-line heuristic decides (mode AUTO).
        int LateGameMinutes = 25;
        float LateGameMetalIncome = 120.0f;
        float LateGameEnergyIncome = 1500.0f;   // the income route needs both incomes
        float LateBudgetMod = 1.0f;          // per-point budget multiplier once late
        // Energy: while energy is stalling the late phase falls back to the native
        // heuristic and no budget bonus applies (defences are energy-heavy); a full
        // energy store raises the budget like a full metal store does.
        float ExcessEnergyPercent = 0.9f;
        float ExcessEnergyBudgetMod = 1.5f;
        // Construction turrets with late-game porc: while the mode is FULL and both
        // incomes are strong (no stall), one caretaker per cluster is placed at the
        // defence point being reinforced, so builders and the porc chain get help.
        bool NanoWithPorc = true;
        float NanoMetalIncome = 150.0f;
        float NanoEnergyIncome = 3000.0f;
        int NanosPerCluster = 1;
        // Pressure: enemy surface army (metal per enemy player, from aiEnemyMgr role
        // costs) versus our army cost. Forces FULL in any phase after the grace period.
        int PressureMinMinutes = 10;
        float PressureRatio = 1.2f;
        float PressureBudgetMod = 1.5f;
        // Banked metal: when the store is this full, raise the budget so it is spent
        // on defence instead of overflowing.
        float ExcessMetalPercent = 0.9f;
        float ExcessMetalBudgetMod = 2.0f;
    }

    // FRONT and AIR near max metal, see manager/build_power.as. While the bank
    // sits near full - from income or from metal TECH trades in - construction
    // turrets go on the T2 plants and gantries; if it stays maxed, another gantry.
    namespace BuildPower {
        bool Enabled = true;
        bool Front = true;
        bool Air = true;
        int MinMinutes = 3;
        int IntervalSeconds = 6;         // one step at most this often
        float CapFill = 0.80f;           // bank / storage at which metal counts as near max
        float ReleaseFill = 0.55f;       // below this the capped stretch ends
        int SustainSeconds = 15;         // near max this long before the first turret
        float TargetFill = 0.50f;        // the bank above this is drained over DrainSeconds
        int DrainSeconds = 120;
        float MetalPerNano = 8.0f;       // metal/s one 200 build power turret spends
        int MaxPerStep = 2;
        int MaxInFlight = 3;             // our turret tasks queued at once
        int MaxNanos = 60;               // all T1 turrets, ours and the roles'
        float MinEnergyFill = 0.25f;     // nothing added below this energy fill, or while stalling
        int NanosPerT2Factory = 12;      // ours per plant, on top of the roles' own
        int NanosPerGantry = 16;
        bool T1Fallback = true;          // T1 plants take turrets only while there is no T2 plant or gantry
        int NanosPerT1Factory = 6;
        int TaskTimeoutSeconds = 120;
        int MissRestSeconds = 90;        // a plant whose turret ended unbuilt is skipped this long
        // Another land gantry once the bank has stayed at GantryFill without a
        // break for GantrySeconds (the turrets did not drain it).
        float GantryFill = 0.90f;
        int GantrySeconds = 180;
        float GantryMinIncome = 60.0f;
        int GantryMinMinutes = 12;
        int GantryIntervalSeconds = 300; // between gantries queued here
        int MaxGantries = 3;             // land gantries in all
    }

    // Frigates and destroyers of every faction: held at base, then every held
    // ship launched as one attack, see manager/naval_waves.as.
    namespace NavalWaves {
        bool Enabled = true;
        array<string> Ships = {
            "armpship", "armroy",               // Armada: Ellysaw frigate, destroyer
            "corpship", "corroy",               // Cortex: Riptide frigate, destroyer
            "legnavyfrigate", "legnavydestro"   // Legion: Argonaut frigate, destroyer
        };
        // Each wave launches the whole hold once it holds a size drawn fresh per
        // wave from [MinWaveSize, MaxWaveSize], frigates and destroyers combined.
        int MinWaveSize = 7;
        int MaxWaveSize = 10;
        // Time-out: a hold of at least TimeoutMinSize that has waited this long
        // launches anyway, so a yard that cannot reach the drawn size never parks
        // for good (main's 4 minutes and 3 ships). 0 turns it off.
        int TimeoutMinSize = 3;
        int MaxHoldSeconds = 240;
        // Released ships re-enter Military::AiMakeTask within a few seconds and
        // take the wave's attack task while this window is open.
        int ReleaseWindowSeconds = 15;
    }

    // Spam: economy-gated mass production on parallel routes, see manager/spam.as
    // and doc/spam-routes.md. Units need "attribute": ["spam"] in behaviour.json.
    // Air transport ferry (Team::Ferry, manager/ferry.as). AIR builds one
    // transport for the TECH player on its team when TECH starts its first T2
    // lab; TECH uses it to fly donated T2 constructors to their recipients.
    namespace Ferry {
        float DropPullback = 300.0f;
        float ParkDistance = 450.0f;      // D-112: gifts wait this far behind our start (away from the map centre)
        float ParkSpacing = 80.0f;        // D-112: gifts park this far apart
        int ParkWaitSeconds = 900;        // D-112: a gift's park (renewed at every ask)
        float GiveNearDrop = 800.0f;      // D-112: a failed run gives its cargo only within this of the drop
        int FerryRunAttempts = 2;         // D-112: flown runs tried for one gift before it walks     // D-110: the drop point is this far short of the teammate's start, toward our base (open ground)
        bool Enabled = true;
        // The light transports. They carry one unit of transportsize <= 3
        // and mass <= 750; a T2 constructor is 2x2 and, because the engine
        // defaults a unit's mass to its metal cost when the def sets none
        // (Recoil UnitDef.cpp: GetFloat("mass", cost.metal)), weighs 410-470.
        // The heavy ones (armhvytrans / corhvytrans / legatrans) lift more but
        // cost 190 against 68-74, and the ferry never carries anything the
        // light one cannot. All six come from the T1 air plant.
        dictionary TransportBySide = {
            {"armada", "armatlas"},
            {"cortex", "corvalk"},
            {"legion", "leglts"}
        };
        // Every transport def the ferry could be asked to build. They are all
        // capped at 0 for every role, and AIR raises the one it owes to
        // owned+1 only while a request is open. Without the cap the native
        // recruiter treats a transport with a role entry as ordinary air
        // production and builds extras that idle with nothing to carry.
        array<string> AllTransportDefs = {
            "armatlas", "corvalk", "leglts",
            "armhvytrans", "corhvytrans", "legatrans"
        };
        // When TECH asks on its own: sliding-minimum metal income it must
        // clear while owning no transport. Not tied to the T2 lab - that
        // trigger fired on the lab being *planned* and delivered far too early.
        float RequestMinMetalIncome = 20.0f;
        // A requester waits this long before asking again (transport died,
        // or AIR was busy serving someone else).
        float RequestCooldownSeconds = 180.0f;
        // How close the transport must get to the requester's base before AIR
        // hands ownership across.
        float ArriveRadius = 320.0f;
        // How long one transport order is allowed to produce nothing before
        // AIR orders another. Only a safety net: the normal path clears the
        // latch the moment the unit appears.
        float OrderTimeoutSeconds = 120.0f;
    }

    // SEA hands a TACTICAL ally one construction ship so it can work the
    // coast beside it (Team::SeaAssist, manager/sea_assist.as).
    namespace SeaAssist {
        bool Enabled = true;
        // SEA's sliding-minimum metal income before it can spare one.
        float MinMetalIncome = 50.0f;
        // Construction ships SEA keeps for itself before donating the surplus.
        int KeepConstructors = 1;
        // TACTICAL's shipyard caps once it owns a sea constructor. They start
        // at 0 in RoleSettings::Tactical, which is what stops it building any
        // naval structure at all.
        int UnlockedT1Shipyards = 2;
        int UnlockedT2Shipyards = 1;
        // Placement slack for the seeded shipyard around the ship's position.
        float SeedShake = 256.0f;
    }

    namespace ConstructorRequest {
        // T2 constructors from TECH on request (Team::Donation, D-041). TECH
        // always answers a request: one extra constructor from its advanced
        // lab, flown by the ferry transport when it owns one.
        bool Enabled = true;
        // Requester side: a non-TECH BARb with no T2 constructor and no T2 lab
        // of its own asks once its sliding-minimum metal income clears this.
        float RequestMinMetalIncome = 15.0f;
        int MaxRequests = 1;               // automatic requests per game
        int RequestCooldownSeconds = 300;  // between re-asks (no TECH on the team yet)
        // TECH side: an order the lab has not delivered within this is re-placed.
        int OrderTimeoutSeconds = 240;
        // SUPPORT ("front tech") techs on its own: no automatic request from it
        // (D-046). An explicit RequestConstructor() is still always served.
        bool AutoRequestFromSupport = false;
    }

    // Attack-wave policy for every role (a role overrides in its Init).
    // A DEFEND squad promotes to ATTACK when its power reaches a bar that native
    // re-sets every 5 s from the enemy's groups. The legacy bar was the map-wide
    // second-strongest group - a naval squad waited to outweigh a land army it
    // could never reach, and cruisers massed for most of a game; sprinters and
    // blitz did the same in a TECH base. AttackScale > 0 switches the bar to the
    // strongest group the squad can actually REACH, times this; AttackWaitSeconds
    // > 0 sends any squad that has waited that long at or above quota.attack.
    // Either at 0 restores the legacy rule for that half.
    namespace Military {
        float AttackWaitSeconds = 180.0f;
        float AttackScale = 0.8f;
    }

    namespace Spam {
        bool Enabled = true;
        // Both sliding-minimum incomes must clear these to activate ...
        //
        // These are deliberately fusion-era. Below this economy the units spam
        // produces - Pawn, Grunt, Goblin, Blitz - are ordinary front-line
        // combat units and the roles should go on spending them as such. Spam
        // is what a mature economy does with the T1 factories it no longer
        // needs for the front line, which is why UnitByFactory lists only T1
        // factories. Do not lower these to "make spam happen sooner": that
        // takes combat units away from the roles that still need them.
        float MinMetalIncome = 60.0f;
        // A start the land army cannot leave (Global::Map::LandLocked, from the
        // map config's start spots) never spams: the units would walk to the
        // shore and stand there. TECH on Tundra Continents was making Grunts
        // for nothing (D-052). True lets such a start spam anyway.
        bool AllowLandLocked = false;
        float MinEnergyIncome = 1500.0f;
        // ... and either falling under this fraction of its threshold deactivates
        float ReleaseFraction = 0.7f;
        // Destination lies this far past the focus along our line of approach
        float BehindEnemyDistance = 2500.0f;
        // Sideways offset between the lanes of different factories
        float LaneSpacing = 900.0f;
        // Within one factory's line: units are dealt lanes 0, +1, -1, +2, -2 ...
        // up to UnitLanes, offset UnitLaneSpacing apart, so the stream is a
        // band rather than a single file. EndSpread scales that offset at the
        // final waypoint - 0 converges every lane on the same endpoint, 1 keeps
        // full width; the run is aimed at one backline, so keep it small.
        int UnitLanes = 5;
        int RepeatStallSeconds = 45;         // D-111: a factory on repeat that produced no spam unit for this long gets its build again
        float UnitLaneSpacing = 160.0f;
        float EndSpread = 0.35f;
        // Waypoints stay this far from the map edge
        float MapMargin = 200.0f;
        // Rebuild every lane when the AI's combat focus moves further than
        // this. Small enough to follow a front that is actually shifting,
        // large enough that a squad shuffling in place does not re-issue
        // orders to every spam unit on the map.
        float FrontMoveThreshold = 1200.0f;
        // Rotate the focus to the next enemy start spot this often
        int RefocusMinutes = 6;
        // Which unit each T1 factory spams; factories not listed keep their role logic
        dictionary UnitByFactory = {
            {"armlab", "armpw"},   {"corlab", "corak"},    {"leglab", "leggob"},
            {"armvp", "armflash"}, {"corvp", "corgator"},  {"legvp", "leghades"}
            // Hover plants are deliberately absent: hovers are wanted as
            // ordinary combat units all game (D-038), so armsh/corsh/legsh no
            // longer carry the spam attribute either.
        };
    }

    // Role-specific overrideable variables in a dedicated namespace
    namespace BomberStock {
        // Every T2 bomber built (UnitHelpers::GetAllT2WaveBombers) is counted,
        // and while the count builds its def's main role and attribute are
        // replaced with "support". At the current wave size of live counted
        // bombers the defs get their regular role and attribute back (bomber /
        // siege) and the batch is launched as an attack wave. See
        // manager/bomber_stock.as.
        bool Enabled = true;

        // Wave N launches at FirstWaveSize + WaveSizeGrowth * (N - 1) live
        // bombers - 5, 8, 11, 14, 17, 20 - then 20 every wave until the game
        // ends (40 once the late-game lift opens, Air::LateBomberWaveMaxSize).
        // A launch never takes more than MaxWaveSize; extras stay parked
        // for the next wave. This is a per-wave size, not a limit on how many
        // bombers the AI owns: the plant refills the stock after every launch.
        int FirstWaveSize = 5;
        int WaveSizeGrowth = 3;
        int MaxWaveSize = 20;

        // Upper bound on how long the defs stay on their regular role after a
        // launch while the released bombers re-task. The window closes early
        // once every released bomber has taken its new task.
        int ReleaseWindowSeconds = 12;

        // A stock that has not grown for this long launches what it holds, as long
        // as that is at least the last wave's size (FirstWaveSize before the first)
        // and StallLaunchMinPercent of the current wave size. Without the second
        // floor a stall sent 5, 6, 8 and 9 bombers at a wave size of 20 (Supreme
        // Isthmus 2026-09-27, 23 500 - 77 500 metal of AA, no survivors in any).
        int StallLaunchSeconds = 60;
        int StallLaunchMinPercent = 75;
    }

    namespace RoleSettings {        
        /******************** MEX UPGRADE PRIORITY ********************/
        // A mex upgrade is the best metal-per-metal available and spots are
        // finite, so every role ranks it ahead of its energy ladder. Radius is
        // measured from the role's economy anchor; MaxConcurrent 0 disables it.
        bool MexUpgradeFirst = true;
        float MexUpgradeRadius = 2500.0f;
        int MexUpgradeMaxConcurrent = 1;

       

        // Max number of workers assigned as guards to a single leader (primary or secondary)
        // Applies to builder guard distribution logic (bots/veh/air/sea). Can be tuned per-profile.
        int BuilderMaxGuardsPerLeader = 10;

        // Max number of workers assigned as guards to a tactical constructor (per category)
        // Independent from primary/secondary caps. Default 0 disables tactical guarding.
        int BuilderMaxGuardsPerTacticalLeader = 0;

        namespace Tech {
            // Role switch cadence (seconds)
            int MinAiSwitchTime = 400;
            int MaxAiSwitchTime = 500;

            // NukeLimit: maximum number of nukes allowed for TECH role
            int NukeLimit = 20;

            /******************** FLOATING METAL ********************/
            // Every gate in the T2 constructor ladder is income-based, so a
            // full bank on a modest income built nothing: the converter wanted
            // 1200 energy income, the fusions their own floors, the silo its
            // own - and the T1 constructors, whose only floating rule was "metal
            // over 1000 -> another nano", spammed construction turrets. This
            // ladder runs first while metal is floating and spends the bank.
            float FloatMetalCurrent = 2500.0f;     // or aiEconomyMgr.isMetalFull
            float FloatMetalIncome = 25.0f;        // floor, so a dead economy does not qualify
            float FloatConverterMinEnergyIncome = 800.0f;   // a converter needs energy to convert
            float FloatAFUSMetalCurrent = 6000.0f;          // advanced fusion above this, fusion below
            int FloatMaxNukeSilos = 1;             // silos this ladder will start (NukeLimit still caps)
            // Reserve-driven nanos beyond the income target (see ShouldBuildT1Nano).
            int NanoReserveSurplus = 2;

            /******************** ENERGY FOCUS ********************/
            // One energy structure at a time: before any energy rung, a
            // constructor assists the T1 energy structure already under
            // construction (Builder::EnqueueAssistEnergy), up to this many on
            // it. Build power on one solar finishes it sooner than two half
            // built, and the assist ends with the structure.
            bool EnergyFocusAssist = true;
            int EnergyFocusMaxAssists = 3;

            /******************** BASE LAYOUT ********************/
            // JSON permits the native mechanism for experimental profiles;
            // TECH is the only role that opts its AI instance in. Native owns
            // exact footprint geometry, atomic reservations and save/load.
            // Script owns candidate order and mature-module progression.
            // The experimental build system (D-066), one master switch. On:
            // TECH's own sequence (roles/tech_build.as) is the only source of
            // work, native's chooser and its start-factory and storage jobs
            // are silent for this instance, and native's site search never
            // spirals (planned slot, exact spot, or the free footprint nearest
            // the asked anchor within ExperimentalSearchRadius). Off: TECH runs
            // the stock ladder and stock placement like every other role.
            bool ExperimentalBuild = true;
            float ExperimentalBuildDirectRange = 1600.0f;   // D-064: the engine walks the last leg inside this
            float ExperimentalSearchRadius = 512.0f;        // D-066: how far from an anchor a site may be packed
            float ExpAssistRadius = 1500.0f;                // a constructor with nothing to build assists within this
            float ExpOrderRadius = 2000.0f;                 // native's queued defence/radar/repair orders are taken only within this of the base
            float ExpCommanderHomeRadius = 800.0f;          // the commander assists only within this of the base after the opening
            float ExpFirstLabRadius = 224.0f;               // the first (throwaway) T1 lab goes on the nearest footprint within this of the commander ...
            float ExpFirstLabClearance = 32.0f;             // ... but its footprint edge stays at least this far from the commander's position
            // D-114 (owner's rules): land factories move toward the front in front factory clusters
            float FrontMinShare = 0.2f;                     // D-114: a front cluster stands at least this share of the way from the base toward the front
            float FrontMaxShare = 0.8f;                     // D-114: and no further than this
            float FrontShareStep = 0.04f;                   // D-114: the search steps this share toward the front at a time
            int FrontLateralTries = 6;                      // D-114: positions tried each side of the line at each step
            float FrontMinFlat = 0.85f;                     // D-114: this share of the cluster's ground flat (LayoutBoxMaxSlope)
            float FrontRoomyShare = 0.9f;                   // D-114: first pass: this share of the ground round the cluster buildable (away from other buildings)
            int FrontClearCells = 4;                        // D-114: the room kept round a cluster in the first pass
            int FrontT1TurretCols = 2;                      // D-114: a T1 lab's turret block: 2 x 1
            int FrontT1TurretRows = 1;
            int FrontT2TurretCols = 2;                      // D-114: a T2 lab's: 2 x 2
            int FrontT2TurretRows = 2;
            int FrontT3TurretCols = 10;                     // D-119 (owner): a gantry's block holds up to 50 turrets: 10 x 5 (smaller blocks where the ground is smaller)
            int FrontT3TurretRows = 5;
            int FrontT3TurretsFirst = 10;                   // D-119: the gantry is ordered once this many of its turrets stand; the rest keep filling
            int FrontReclaimAtCount = 3;                    // D-114: this many land factories on the map retire the base's land factories
            float FrontBaseRadius = 1200.0f;                // D-114: a land factory within this of the base centre is the base's
            int FrontBaseReclaimSeconds = 240;              // D-114: INV-044: a base land factory still standing this long after the count is reached
            int FrontRowMaxLabs = 4;                        // D-117: T1 spam labs side by side in a row of up to this many
            int FrontRowGapCells = 3;                       // D-119: cells between two labs of a row: side by side, clear of the neighbour's blocker yard (block_map.json fac_bot: yard 6 = 3 cells each side; closer was always refused)
            int FrontT3LaneCells = 6;                       // D-117: the lane kept open beside every spam row: the largest T3 movement classes (HBOT7, HTANK7) are 7 map squares = 3.5 cells wide, plus room
            float FrontLaneMinFlat = 0.9f;                  // D-117: a lane counts as passable with this share of its ground flat (LayoutBoxMaxSlope) and free
            int FrontClusterStallSeconds = 300;             // D-114: a front factory order with no frame this long gives its cluster up
            int FrontClusterOpenSeconds = 600;              // D-114: INV-046: an open T2 or T3 front cluster without its factory this long after it was planned
            // D-109 (owner's rules): the land constructors leave the base once the air constructors carry it
            int T1AirReleaseAbove = 5;                      // D-109: more than this many T1 air constructors release the T1 land constructors
            int T1AirConstructorTarget = 6;                 // D-109: the T1 air plant keeps this many T1 air constructors
            float ForwardHomeRadius = 900.0f;               // D-109: a construction beyond this from the base centre is a forward job (dropped on a recall)
            float MexClusterRadius = 600.0f;                // D-109: a mex within this of a cluster's centre joins the cluster
            float MexDefenceBaseClear = 900.0f;             // D-109: mex clusters nearer the base centre are the eco layout's ground, not defended here
            float MexDefenceRadius = 400.0f;                // D-109: a defence within this of a cluster's centre counts for it
            float MexDefenceShake = 160.0f;                 // D-109: native picks the defence's site within this of the cluster's centre
            int ForwardOrderHoldSeconds = 120;              // D-109: an order at one place is not repeated within this
            int SpamLabGapCells = 2;                        // D-109, D-114: cells between side-by-side search positions of a front cluster (a lane each)
            float SpamClusterRadius = 600.0f;               // D-109: forward constructors assist what goes up within this of the spam cluster
            int SpamPadsMax = 2;                            // D-109: small 2x2 forward turret pads at the lab row's ends
            float ConverterStarveEnergyShare = 0.5f;        // D-107: the energy bank under this share of storage (or stalling) means the converters cannot stay on (BAR's conversion level is 75% by default)
            float TeamShareMetalAbove = 0.95f;              // D-106: our metal bank over this share of storage triggers the team economy check and a donation
            float TeamShareMetalBudget = 0.20f;             // D-106: at most this share of our metal storage is given per donation, the lowest-filled teammate first
            float TeamShareCheckSeconds = 5.0f;             // D-106: a donation at most this often (the engine's share command settles each slow update)
            float TeamShareMinAmount = 25.0f;               // D-106: smaller gifts are not sent
            float AfusFundedShare = 0.85f;                  // D-105: the advanced lab is not reclaimed when bank + income x the advanced fusion's remaining build time covers this share of its cost
            float AfusBuildTime = 330000.0f;                // D-105: the advanced fusion's buildtime (corafus 329200, armafus 312500, legafus 340000 in BAR's unitdefs)
            float AfusProjectionRadius = 600.0f;            // D-105: build power within this of the advanced fusion frame counts for its finish time
            float ReclaimOtherPowerRadius = 600.0f;         // D-105: a T2 constructor reclaims only when no other build power is within this of the target
            float LabEcoOnlineMetalIncome = 200.0f;         // D-102: the economy is online: no lab is reclaimed for its metal, T1 labs are for spam, the advanced lab is rebuilt
            int LabRebuildMinT1Cons = 3;                    // D-102: below LabEcoOnlineMetalIncome, this many T1 constructors and no lab is rebuilt
            float SpamLabMetalStep = 100.0f;                // D-105: one more spam lab per this much metal income over LabEcoOnlineMetalIncome
            int SpamLabsMax = 6;                            // D-105: the spam labs' ceiling
            int ExpSpamLabs = 1;                            // T1 labs kept for the spam economy once its gate is open and the advanced lab stands
            bool ExpTurretNearLab = true;                   // D-069: the next box turret slot is the one nearest a standing lab, not the one nearest the pair's centre
            float ExpLabBuildPowerReach = 260.0f;           // D-069: elmos within which static build power (turrets) counts for a lab site: a nano's build distance plus the lab's radius
            float ExpLabSiteRadius = 480.0f;                // D-069, superseded by D-073 (no longer read): the lab site is the turret-layout footprint the most turret slots reach
            string EndgamePlan = "auto";                   // D-080: nuke | t2rush | t3rush | lrpc | auto (deterministic from the team id) - what follows the rush objective
            float PlanCombatGate = 200.0f;                  // D-080: no mobile combat unit under this metal income (every plan)
            float PlanT3RushCombatGate = 500.0f;            // D-080: ... the t3rush plan's gate
            float PlanLrpcMetal = 300.0f;                   // D-080: the lrpc plan's income before the long-range cannon
            float PlanAirConstructorsFromMetal = 200.0f;    // D-080: from this income T2 construction aircraft are the mobile build power
            float PlanAirConstructorPerMetal = 40.0f;       // D-080: one T2 air constructor per this much income ...
            int PlanMaxAirConstructors = 12;                // D-080: ... at most this many
            int LadderParallelAfus = 2;                     // D-080: advanced fusions under construction at once on the ladder while the metal bank is full
            float InvariantLabReachSeconds = 90.0f;         // D-085 INV-016 / D-088 INV-017 patience         // D-085: INV-016 - the advanced lab standing this long with no static build power within ExpLabBuildPowerReach is a violation
            float InvariantDearOrderSeconds = 45.0f;        // D-084: INV-015 - a dear chain order with no frame this long is a violation
            float InvariantLadderFloatSeconds = 60.0f;      // D-080: INV-011 - the metal bank full this long with an income step unmet is a violation
            string RushObjective = "auto";                  // D-070: t2 | fusion | afus | nuke | gantry | titan | eco (no chain) | auto (the role picks: afus)
            // D-070: the commander's home mexes are the opening's (OpeningMexRadius / OpeningMexCap: the
            // spots within 700 of the start, at most 3 - three on Supreme Isthmus, one or none elsewhere),
            // the lab follows at once, and the constructors claim the rest within ChainMexFarRadius
            float ChainMexFarRadius = 2500.0f;
            float ChainMohoRadius = 2500.0f;                // D-100: the moho step upgrades every mex of ours within this of the start (0: the recipe's count only)
            int ChainMaxMexes = 6;                          // D-070: mexes the chain claims in all
            // D-070: energy by the map's wind, deterministically. Expected turbine output is the average of the
            // map's min and max wind (capped at a turbine's 25). Turbines are chosen when their metal per E/s is
            // under the solar's by ChainWindMargin and the max wind reaches ChainWindMaxMin (a lull must be worth
            // riding out). The first energy structure is a solar when the current wind is under ChainWindBootstrap.
            float ChainWindMargin = 1.25f;
            float ChainWindMaxMin = 12.0f;
            float ChainWindBootstrap = 5.0f;
            float ChainAssistRadius = 4000.0f;
            float ChainParallelCostM = 400.0f;
            float ChainStepStallSeconds = 120.0f;           // D-070: a chain step with no progress for this long is skipped (an unreachable frame must not end the rush)              // D-070: structures cheaper than this (metal) are built one per builder in parallel; dearer ones get every builder on one frame              // D-070: every builder inside this joins the current step's frame
            float ChainNearFrameRadius = 600.0f;            // D-075: a chain frame of a cheap step within this of the builder is finished before anything else
            float PowerTurretBankFactor = 1.5f;             // D-075: ... and the bank holds this many turret costs
            float PowerBuildPowerPerMetal = 20.0f;          // D-075: the rule stops at this much static build power (workertime) per metal/s of income (played: 45 turrets in three minutes without it)
            // D-097: how many construction turrets go up at once (Layout::TurretsAllowed):
            // as many as the nearby build power finishes within PowerTurretBatchSeconds
            // and the bank plus income pays for in full; never under 1, never over
            // PowerTurretsMax; the other builders assist the turret going up
            float PowerTurretBatchSeconds = 20.0f;
            int PowerTurretsMax = 8;
            float PowerTurretBuildTime = 5300.0f;           // the T1 construction turret's buildtime (cornanotc, armnanotc, legnanotc: 5300 in BAR's unitdefs)
            float InvariantTurretFlightSeconds = 30.0f;
            float InvariantNoRoomSeconds = 120.0f;          // D-099: INV-020's patience - the layout refusing economy structures for lack of room     // D-097: INV-019's patience
            int ExpDefenceMaxOrders = 3;                    // D-075: base-defence orders per def; native refusing the site this often ends the rung (played: 15 refusals in 2 min)
            float ExpDefenceRadius = 900.0f;                // D-075: base-defence site search radius around the factory centre (the box's cells are all held)
            float LifecycleMemorySeconds = 120.0f;         // D-076: a retired factory's position is remembered this long after it is gone (INV-001)
            float InvariantFactoryRadius = 200.0f;          // D-076: INV-001 - a mobile unit appearing within this of a retiring factory was produced by it
            float InvariantFrameRadius = 320.0f;            // D-076: INV-002 - build power counted within this of a frame
            float InvariantFrameSeconds = 60.0f;            // D-076: INV-002 - a frame with no build power for this long is abandoned
            float InvariantFloatPercent = 0.9f;             // D-076: INV-004 - the metal bank at this share of storage is floating
            float InvariantFloatSeconds = 60.0f;            // D-076: INV-004 - ... for this long while a structure is under construction with build power short
            bool ExpTurretCentreOut = true;                // D-077: turrets start at the box centre and grow outward as one connected cluster (NextSlotConnected); off = D-069 nearest-lab
            float ReclaimT1EnergyMargin = 1.25f;            // D-077: winds and solars are reclaimed once a fusion stands and energy income without them covers the pull by this
            float ReclaimAdvSolarMargin = 1.5f;             // D-077: advanced solars once income without every T1/adv source covers the pull by this; an advanced fusion reclaims all
            float ReclaimEnergyRadius = 2500.0f;            // D-077: energy structures within this of the base centre, nearest first
            int ReclaimEnergyConcurrent = 4;                // D-077: energy reclaims in flight at once
            float InvariantReclaimSeconds = 240.0f;         // D-077: INV-006 - T1 or advanced-solar energy standing this long after an advanced fusion is a violation
            float ReclaimTurretMargin = 48.0f;              // D-078: a turret within its build distance plus this of a reclaim target joins the reclaim at once
            float InvariantReclaimJoinSeconds = 10.0f;      // D-078: INV-008 - a turret in range of a reclaim of ours off it this long is a violation
            float InvariantT2ReclaimSeconds = 15.0f;        // D-078: INV-007 - an advanced lab not retiring this long into an advanced fusion with bank room is a violation
            float ChainEnergyFloatMax = 300.0f;             // D-079: ... or the bank at EcoConvertEnergyPercent with income over the pull by this now (played: the advanced fusion ordered 15 s after the fusion at +1,291)
            float ChainEnergyFloatRise = 100.0f;            // D-079: ... or the bank above half of storage, up by this over ChainEnergyFloatSeconds, with income over the pull by ChainEnergyFloatMax (the moment a fusion completes)
            int ConverterParallel = 3;                      // D-079: converters queued at once while energy floats (one at a time otherwise); the pull-inflated surplus is replaced by half the income while floating
            float ChainEnergyFloatSeconds = 15.0f;          // D-079: the energy bank at EcoConvertEnergyPercent of storage for this long = energy floats: no energy structure is ordered, converters first (the pull is inflated by the build in progress, so the bank is read, not the pull)
            float InvariantFloatOrderSeconds = 90.0f;        // D-079: INV-009 - an energy frame appearing after the bank has been full this long was ordered while floating
            float PowerAheadSeconds = 15.0f;                // D-075: the metal bank at InvariantFloatPercent of storage for this long, or risen by PowerAheadRise over it = income above spending
            float PowerAheadRise = 30.0f;                   // D-075: ... the rise over PowerAheadSeconds that counts as the bank rising
            float ExpCombatMetalIncome = 200.0f;            // D-068: under this 10 s metal income TECH's labs make no combat unit (rush bots stay capped, no scout/fast-bot batches); 0 = never
            float EcoMexExpandRadius = 2500.0f;             // constructors expand to the nearest open spot within this ...
            float EcoMexExpandUntilIncome = 60.0f;          // ... while metal income is under this
            bool LayoutEnabled = true;                      // the planned base (needs ExperimentalBuild)
            // The opening (D-063): the OpeningMexCap reachable mexes nearest
            // the start within this radius, taken nearest the commander first,
            // before any other structure (cap 0 = all of them). Played: the
            // fourth spot was 944 elmos out toward an ally, and the third
            // already drains the 1,000 E bank; three, then the next step.
            // Native's start factory is held until then, at most
            // OpeningMaxSeconds, never past the commander.
            // 700: the home cluster. Played on Supreme the third spot is 947
            // elmos out toward an ally and the commander walked there; with
            // 700 the opening takes the two home spots and the lab follows.
            float OpeningMexRadius = 700.0f;
            int OpeningMexCap = 3;
            int OpeningMaxSeconds = 240;
            // After the opening the commander stays home: native mex defaults
            // farther than this from the start are left to the constructors
            // (played: the ladder's mex-first rule sent it off to a fourth mex).
            float CommanderMexRadiusAfterOpening = 600.0f;
            int LayoutFactorySideStepCells = 4;
            int LayoutFactorySideTries = 4;
            int LayoutFactoryForwardStepCells = 4;
            int LayoutFactoryForwardTries = 2;
            // The turret box (D-063): the rectangle behind the factory pair
            // that holds the planned construction turrets (invisible until
            // built) and every economy structure, packed on the cells nearest
            // a turret. Searched largest first over rear and side offsets; a
            // size is taken when its best ground clears LayoutBoxMinScore.
            int LayoutBoxAcrossCells = 40;           // 640 elmos
            int LayoutBoxDepthCells = 44;            // 704 elmos: four turret rows at a 14-cell pitch
            int LayoutBoxShrinkCells = 8;
            int LayoutBoxMinAcrossCells = 24;
            int LayoutBoxMinDepthCells = 16;         // D-081: three touching turret rows (9 cells) and what is left is the shelf (played: 21 fit no box on Supreme Isthmus)
            int LayoutBoxSideStepCells = 6;          // D-082: wider side search, so the block can move off a mountain (6 x 6 = 36 cells = 576 elmos either way)
            int LayoutBoxSideTries = 8;              // D-082: up to 48 cells (768 elmos) either way, enough to stand beside the pair
            int LayoutBoxForwardTries = 4;           // D-082: box candidates level with or ahead of the pair's rear line (negative rear), only beside the pair
            int LayoutBoxBesideClearCells = 4;       // D-082: cells between the pair's footprints and a box standing beside them
            float LayoutHaloMin = 0.70f;             // D-087: a box whose halo scores this is good enough; among good enough the nearest the home mexes wins (played: 86 % halo 690 elmos away beat 75 % next to the mexes)
            float LayoutHaloQuantum = 0.05f;         // D-082: halo scores within this of each other tie; the nearer candidate wins
            int LayoutBoxRearStepCells = 4;
            int LayoutBoxRearTries = 3;
            float LayoutBoxMinScore = 0.75f;         // flat fraction x buildable fraction
            float LayoutBoxMaxSlope = 0.02f;         // engine slope (1 - cos), about 11 degrees
            bool LayoutSeedAtHomeMexes = true;       // D-086: the block, the first turret and the advanced lab are anchored on the centre of the home mex spots (where the builders are after the opening), not the start position
            float LayoutLabServedReach = 300.0f;
            int LayoutLabMinSlots = 4;               // D-090: 8 found no site on Supreme (best 7)               // D-088: a lab site needs this many turret slots within reach (weighted) to be considered
            int LayoutLabFrontGapCells = 3;          // D-096: the advanced lab's front-line site may stand this many cells ahead of turret row 0 (the zone's edge, a rock)
            int LayoutAfusSetSize = 3;               // D-101: advanced fusions per set: the first flush against a turret, the rest lined up away from it
            int LayoutConvSetSize = 5;               // D-101: advanced converters per set, the same way
            float LayoutSetHoldSeconds = 300.0f;     // D-101: a set's unserved slots are released when nothing asked for its def this long
            float LayoutFrontMinCost = 1500.0f;      // D-096: a seen enemy group counts as a front at this metal cost; until one is seen the front is the map centre
            float LayoutLabFlushElmos = 160.0f;      // D-088: INV-017 - the nearest turret to the advanced lab, centre to centre, flush like the pair's nanos at the T1 lab     // D-086: the advanced lab keeps its planned footprint only if a standing turret is within this; else it is packed nearest a standing turret
            bool LayoutBoxAtStart = true;            // D-083: the main cluster is planned around the start position (the home mexes), not behind the factory pair
            int LayoutBoxPairClearCells = 6;         // D-083: a candidate block whose rectangle plus this margin holds a pair factory slot is skipped
            float LayoutCanPlaceMemoSeconds = 2.0f;  // D-083: Layout::CanPlace remembers its answer per def this long (the native probe was asked hundreds of times a second: the 15 s freeze)
            int LayoutHaloCells = 18;                // D-082: the halo of packing ground on both sides and behind the turret block (288 elmos, inside a turret's 400 reach); the box is scored and its zone reserved with it
            float InvariantReachElmos = 450.0f;      // D-082: INV-014 - a packed economy structure further than this from every turret slot is a violation
            int LayoutBoxMaxExtra = 4;               // D-072: boxes grown behind the first when it is full (each with its own turret rows)
            int LayoutBoxShelfCells = 12;            // building depth between turret rows: 192 elmos, inside a turret's 400 reach
            int LayoutBoxNanoRows = 4;               // D-081: four turret rows per cluster (a MapConfig may override)
            bool LayoutTurretBlock = true;           // D-081: the rows touch (a solid block filled across every row), the shelf for other structures behind it; off = a shelf between rows
            int LayoutBoxMinRows = 3;                // D-081: a cluster with fewer rows than this is not planned (INV-012)
            int LayoutForwardGapCells = 8;           // D-081: clear cells between the main cluster's front and the forward cluster
            int LayoutForwardStepCells = 12;         // D-081: each re-plan of the forward cluster moves it this much further forward
            int LayoutForwardTries = 3;              // D-081: re-plans of the forward cluster when an ally takes its ground
            float InvariantForwardSeconds = 120.0f;  // D-081: INV-013 - a main cluster without a forward cluster this long is a violation
            float LayoutConverterNanoGap = 0.0f;     // elmos an advanced converter keeps from a turret slot (its death kills one within 173)
            float LayoutFusionNanoGap = 0.0f;        // ... a fusion (379); density and shared build power were chosen over firebreaks
            int LayoutFallbackShakeCells = 8;        // no box: economy within this of the factory nanos (the only spiral left)
            bool LayoutOverlay = false;              // push the plan to the team-link widget (/barblayout toggles it too)

            /******************** ECO PLANNER (D-058) ********************/
            // EcoPlanner (manager/eco_planner.as): a deterministic function of
            // wind range, tidal, incomes, banks and what stands that names the
            // next economy structure; re-evaluated every time a constructor asks.
            // It replaces the solar / advanced solar / converter / fusion rungs
            // of this role's ladders; mexes stay native's. doc/eco-planner.md.
            bool EcoPlannerEnabled = true;
            float EcoEnergyRatioLow = 8.0f;          // E per M wanted at EcoEnergyRampStart metal
            float EcoEnergyRatioHigh = 20.0f;        // ... and from EcoEnergyRampEnd up (T2 economies)
            float EcoEnergyRampStart = 5.0f;
            float EcoEnergyRampEnd = 40.0f;
            float EcoEnergyReserve = 60.0f;          // E/s wanted on top (the commander's 30 and build draw)
            float EcoEnergyLowPercent = 0.25f;       // bank below this and pull over income = draining
            float EcoConvertEnergyPercent = 0.90f;   // bank at this = floating: convert the surplus
            float EcoFloatMetalPercent = 0.80f;      // metal bank at this = invest in energy anyway
            float EcoAffordSeconds = 90.0f;          // a lump is affordable within this many seconds of income
            float EcoWindMinimum = 7.0f;             // effective wind E/s under this and turbines are not an option
            float EcoWindLullFloor = 4.0f;           // min wind under this discounts the average ...
            float EcoWindLullFactor = 0.7f;          // ... by this
            float EcoAdvSolarMinMetalIncome = 6.0f;  // an advanced solar's 350 lump waits for this income (or the bank)
            int EcoStorageWinds = 4;                 // this many winds and no energy storage: build one
            float EcoStorageSeconds = 20.0f;         // energy storage under this many seconds of income: another
            int EcoMaxEnergyStorages = 1;
            float EcoStorageMinMetalBank = 150.0f;   // no storage order on an empty bank (played: the rule looped at 0 metal)
            float EcoConverterUse = 70.0f;           // a T1 converter's draw; a surplus of twice this converts even while energy is going up
            float EcoAssistRadius = 1200.0f;         // a builder assists the energy structure going up only within this of itself (bots are slow)
            float EcoFusionEnergyIncome = 300.0f;    // from this energy income, a T2 builder answers "energy" with a fusion (advanced when its metal gate passes); T1 builders leave energy alone
            int ExpDefenceLLT = 1;                   // base defence after the first turret: light laser turrets ...
            int ExpDefenceAA = 1;                    // ... and light AA turrets, near the factories
            int EcoMaxMetalStorages = 2;
            int EcoMetalMapSpots = 150;              // this many metal spots or more counts as a metal map
            bool EcoOneEnergyAtATime = true;         // no new energy structure while one is under construction (unless the bank drains)
            // Build power (D-063): a turret goes up when the assist power around
            // the base is under this much per metal income - about what T2 work
            // spends - or more when metal floats; the layout picks the slot,
            // nearest the factories first.
            float EcoBuildPowerPerMetal = 8.0f;
            float EcoBuildPowerFloatFactor = 1.5f;
            float EcoBuildPowerRadius = 700.0f;
            float EcoTurretMinMetalIncome = 8.0f;
            float EcoTurretBankFraction = 0.5f;      // this share of a turret's metal banked before one starts
            float EcoTurretAssistRadius = 1200.0f;   // a constructor assists a turret going up within this of the base centre

            /******************** ECONOMY SWITCH (D-054) ********************/
            // TECH starts on the shared economy.json defaults (native reclaim
            // efficiency 20, json energy limits, native assist nanos on) and
            // switches to its own settings below - ReclaimEnergyEff,
            // EnergyLimit*, AssistNano* - once both incomes reach these floors.
            // false: the settings apply at init, as before.
            bool EconomySwitchEnabled = true;
            float EconomySwitchMetalIncome = 20.0f;
            float EconomySwitchEnergyIncome = 1000.0f;

            /******************** ENERGY (per-role, D-047) ********************/
            // economy.json is shared by every role; these go through
            // aiEconomyMgr and change only this instance.
            // Old energy is reclaimed when a finished energy def scores more
            // than reclEnergyEff x the old def's score (native default 20 -
            // never for a solar against an advanced solar). 2 reclaims solars
            // once advanced solars stand and advanced solars once a fusion does.
            float ReclaimEnergyEff = 2.0f;
            bool ReclaimOldConvertersAlways = true;
            // Caps on the energy table for this role; -1 keeps economy.json's.
            int EnergyLimitSolar = -1;
            int EnergyLimitAdvSolar = -1;

            /******************** TECH BASE SETTINGS ********************/
            // All settings applied to tech role at game start, logic can change throughout game
            float AllyRange = 1000.0f;

            /******************** TECH STRATEGY TOGGLES ********************/
            // Bitmask of enabled high-level strategies for TECH role.
            // Use Strategy enum values as bit indices. Multiple strategies can be enabled simultaneously.
            uint StrategyMask = 0;

            // Enable a strategy flag (wrapper forwards to StrategyUtil)
            void EnableStrategy(const Strategy s) { StrategyMask = StrategyUtil::Enable(StrategyMask, s); }

            // Disable a strategy flag (wrapper forwards to StrategyUtil)
            void DisableStrategy(const Strategy s) { StrategyMask = StrategyUtil::Disable(StrategyMask, s); }

            // Check if a strategy is enabled (wrapper forwards to StrategyUtil)
            bool HasStrategy(const Strategy s) { return StrategyUtil::Has(StrategyMask, s); }

            // Enable default TECH strategies (can be adjusted per-profile)
            void EnableDefaultStrategies() {
                EnableStrategy(Strategy::T2_RUSH);
                EnableStrategy(Strategy::T3_RUSH);
                EnableStrategy(Strategy::NUKE_RUSH);
            }

            // Legacy knob used across TECH logic for rush count; keep for compatibility.
            // Consider reconciling with strategies in future refactors.
            int NukeRush = 1;

            /******************** TECH MILITARY QUOTAS ********************/
            // Scout unit cap for TECH role
            int MilitaryScoutCap = 0;
            // Attack gate (required power to trigger attack waves)
            float MilitaryAttackThreshold = 1.0f;
            // Raid thresholds (power)
            float MilitaryRaidMinPower = 30.0f;
            float MilitaryRaidAvgPower = 30.0f;
            // Defence helper gate: below this metal income, use default defence logic
            float MilitaryDefenceMetalIncomeThreshold = 300.0f;

            /******************** TECH ECONOMY SETTINGS ********************/
            //Minimum incomes levels before T2 bot lab will be built
            float MinimumMetalIncomeForT2Lab = 18.0f; 
            float MinimumEnergyIncomeForT2Lab = 250.0f;
            // Additional gating: require at least this much stored metal and cap total T2 bot labs
            float RequiredMetalCurrentForT2Lab = 1000.0f;
            int MaxT2BotLabs = 3;

            //Minimum incomes levels before normal Fusion will be built
            float MinimumMetalIncomeForFUS = 20.0f; 
            float MinimumEnergyIncomeForFUS = 700.0f;
            float MaxEnergyIncomeForFUS = 2000.0f;

            //Minimum incomes levels before Advanced Fusion will be built
            float MinimumMetalIncomeForAFUS = 70.0f; 
            float MinimumEnergyIncomeForAFUS = 2000.0f;

            //Continue building normal solars if ever below this energy income level
            float SolarEnergyIncomeMinimum = 160.0f; 

            //Stop building advanced solar if above this energy income level
            float AdvancedSolarEnergyIncomeMaximum = 1000.0f; 
            //Continue building advanced solars if ever below this energy income level
            float AdvancedSolarEnergyIncomeMinimum = 600.0f; 
            // Max number of advanced solars allowed for TECH role
            int MaxAdvancedSolars = 8;
            
            // Consider energy storage "low" when current < storage * percent
            float EnergyStorageLowPercent = 0.90f;

            // Radius used to consider mex-upgrade tasks "near base"
            float MexUpgradesNearBaseRadius = 400.0f;

            // Minimum energy income to allow assisting freelance T2 near mex upgrades
            float MexUpAssistMinEnergyIncome = 500.0f;

            // Minimum incomes for building advanced energy converter (moho maker)
            float MinimumMetalIncomeForAdvConverter = 18.0f;
            float MinimumEnergyIncomeForAdvConverter = 1200.0f;

            /******************** GANTRY THRESHOLDS ********************/
            // Income required per allowed Gantry (experimental superfactory)
            float MetalIncomePerGantry = 250.0f;
            float EnergyIncomePerGantry = 6000.0f;

            /******************** T2 BOT LAB THRESHOLDS (income-scaled) ********************/
            // Income required per allowed T2 Bot Lab (mirrors gantry logic). Allowed labs =
            // min(floor(mi / MetalIncomePerT2Lab), floor(ei / EnergyIncomePerT2Lab)), with a minimum of 1.
            // Defaults mirror legacy single-lab thresholds.
            float MetalIncomePerT2Lab = 100.0f;
            float EnergyIncomePerT2Lab = 1000.0f;

            /******************** TECH ECO PHASE THRESHOLDS ********************/
            // Metal income thresholds for bot-lab expansion behavior.
            // Default gate (affects both T1 and T2 expansion behaviors)
            float MetalIncomeThresholdForBotLabExpansion = 200.0f;
            // Early gate: used when the early-expansion strategy is enabled (formerly "rush")
            float MetalIncomeThresholdForEarlyBotLabExpansion = 100.0f; // TODO: tune per profile

            // Metal income thresholds for vehicle-plant expansion behavior.
            // Default gate (affects both T1 and T2 expansion behaviors)
            float MetalIncomeThresholdForVehiclePlantExpansion = 500.0f;
            // Early gate: used when the early-expansion strategy is enabled (formerly "rush")
            float MetalIncomeThresholdForEarlyVehiclePlantExpansion = 400.0f;

            // T1 Energy converter policy (configurable thresholds)
            // Build converters while metal income is below this threshold
            float BuildT1ConvertersUntilMetalIncome = 18.0f;
            // Require at least this much energy income
            float BuildT1ConvertersMinimumEnergyIncome = 200.0f;
            // Require current energy to be at least this fraction of storage (e.g., 0.90 = 90%)
            float BuildT1ConvertersMinimumEnergyCurrentPercent = 0.90f;

            // If metal income is below this, secondary T2 will assist primary T2
            float SecondaryT2AssistMetalIncomeMax = 160.0f;

            /******************** AIRCRAFT PLANT THRESHOLDS ********************/
            // Economy thresholds for building aircraft plants (used by generic rules)
            float RequiredMetalIncomeForAirPlant = 60.0f;
            float RequiredMetalCurrentForAirPlant = 1000.0f;
            float RequiredEnergyIncomeForAirPlant = 2000.0f;

            // T2 Aircraft Plant thresholds (TECH role)
            // Mirrors AIR role defaults; scoped to TECH so roles don't cross-reference
            float RequiredMetalIncomeForT2AircraftPlant = 200.0f;
            float RequiredMetalCurrentForT2AircraftPlant = 1000.0f;
            float RequiredEnergyIncomeForT2AircraftPlant = 2000.0f;

            /******************** LANDLOCKED WATER EXPANSION ********************/
            // Only on a start spot the map script flags landLocked (Global::Map::LandLocked).
            // Shipyards and hover plants stay capped at 0 until metal income reaches the
            // gate; then the caps below apply and Tech_TryEnqueueLandLockedWaterFactory
            // places them from the T2 constructor ladder. See tech.as, LANDLOCKED WATER EXPANSION.
            float MetalIncomeThresholdForLandLockedWaterExpansion = 200.0f;
            int LandLockedMaxT1Shipyards = 1;
            int LandLockedMaxT2Shipyards = 1;
            int LandLockedMaxHoverPlants = 1;   // land and floating variants combined
            // Energy income required on top of the metal gate before the T2 shipyard
            float LandLockedMinEnergyIncomeForT2Shipyard = 2000.0f;
            // How far (elmos) around the T2 bot lab the site search may look for water
            // when placing the T1 shipyard from a land base (120 map squares)
            float LandLockedShipyardSearchRadius = 960.0f;

            /******************** WORKFORCE MINIMUMS ********************/
            // Minimum desired numbers of constructor bots by tech tier
            int MinimumT1ConstructorBots = 2;
            int MinimumT2ConstructorBots = 1;
            int T2BotConstructorCap = 10;                   // D-119 (owner): T2 construction bots at most this many for TECH (the T2 air constructors keep T2ConstructorCap)
            int FastAssistBotCap = 10;                      // D-119 (owner): fast assist bots (Fark, Freaker, legaceb) at most this many
            int T2ConstructorCap = 60;                      // D-103: T2 constructors (bot and air) produced up to this while the metal bank is over T2ConstructorBankShare
            float T2ConstructorBankShare = 0.5f;            // D-103: the metal bank share of storage above which the advanced lab makes T2 constructors
            // T2 constructors TECH keeps before it builds any for an ally's
            // request (played: every one it made was ferried away, and the
            // advanced lab built nothing else).
            int DonationKeepT2Constructors = 2;

            /******************** BUILDER CAP LIMITS ********************/
            // Hard caps for T1/T2 land builders used when computing income-based limits
            int MaxT1Builders = 5;
            int MaxT2Builders = 3;

            /******************** TECH START LIMIT CAPS ********************/
            // Initial caps applied at game start for the TECH role
            int StartCapRezBots = 0;
            int StartCapFastAssistBots = 10;                // D-119 (owner): was 50

            int StartCapT1BotLabs = 1;
            int StartCapT2BotLabs = 1;
            int StartCapT1VehiclePlants = 0;

            // Aircraft plants (separate in case behavior diverges later)
            int StartCapT1AircraftPlants = 0;
            int StartCapT2AircraftPlants = 0;

            // Max allowed aircraft plants for TECH policy
            int MaxT1AircraftPlants = 1;
            int MaxT2AircraftPlants = 1;

            // Air combat units (non-construction aircraft)
            int StartCapT1AirCombatUnits = 0;
            int StartCapT2AirCombatUnits = 0;

            // Shipyards (water)
            int StartCapT1Shipyards = 0;
            int StartCapT2Shipyards = 0;

            // Energy structures
            int StartCapT1Solar = 4;
            int StartCapFusionReactors = 0;
            int StartCapAdvancedFusionReactors = 0;

            // Combat unit caps at start (TECH role disables T1/T2 combat by default)
            int StartCapT1CombatUnits = 0;
            int StartCapT2CombatUnits = 0;

            /******************** NANO POLICY ********************/
            // How much income per additional T1 nano caretaker; and cap.
            // 15 metal per nano (was 10): at +30 that is two turrets, not
            // three, while the T2 lab is still paying for its first
            // constructor (D-051).
            float NanoEnergyPerUnit = 200.0f; // energy per nano
            float NanoMetalPerUnit = 15.0f;   // metal per nano
            int NanoMaxCount = 200;
            // No new nano while the first T2 constructors are being paid for
            // (a T2 bot lab stands and fewer than MinimumT2ConstructorBots
            // exist), nor while the bank is below NanoMinMetalCurrent: a
            // turret then only deepens the stall on the constructor.
            bool NanoHoldForFirstT2Constructors = true;
            float NanoMinMetalCurrent = 150.0f;
            // Native assist nanos (CEconomyManager::CheckAssistRequired) are a
            // second, script-blind source of HIGH-priority turrets; TECH turns
            // them off and owns the count above. Set true to restore them,
            // AssistNanoIncomeMod then scales the income they must be covered by.
            bool AssistNanoEnabled = false;
            float AssistNanoIncomeMod = 1.0f;
            // Reserves-based nano condition: build when metalCurrent >= threshold
            float NanoBuildWhenOverMetal = 1000.0f;


            /******************** T2 BOT DONATION ********************/
            // Team::Donation (manager/donation.as): give N of the T2 combat bots
            // the advanced lab batches to the closest allies, N drawn once from
            // weight(k) = Decay^(k-Min) over Min..Max. Constructors are never part
            // of this; a teammate that wants one asks (Global::ConstructorRequest).
            int T2BotDonationMin = 2;
            int T2BotDonationMax = 7;
            float T2BotDonationDecay = 0.6f;

            /******************** NUCLEAR SILO THRESHOLDS ********************/
            // First strike: how long the first silo keeps the farthest Tech start as its
            // forced target (CSuperTask::SetTargetPos) before native targeting resumes
            int NukeFirstStrikeOverrideSeconds = 30;
            // Separate economy thresholds for rush vs regular nuclear silo builds
            // Rush thresholds: used when rushing up to NukeRush silos
            float MinimumMetalIncomeForNukeRush = 50.0f;
            float MinimumEnergyIncomeForNukeRush = 2000.0f;
            // Regular thresholds: used for non-rush nuking policy
            float MinimumMetalIncomeForNuke = 600.0f;
            float MinimumEnergyIncomeForNuke = 10000.0f;
            
            /******************** ANTI-NUKE THRESHOLDS ********************/
            // Minimum economy thresholds to allow building anti-nuke defenses
            // and the minimum number of anti-nuke structures to maintain
            float MinimumMetalIncomeForAntiNuke = 80.0f;
            float MinimumEnergyIncomeForAntiNuke = 3000.0f;
            int MinimumAntiNukeCount = 1;
            // Income-scaling for anti-nukes: allowed count = floor(metalIncome / MetalIncomePerAntiNuke)
            float MetalIncomePerAntiNuke = 80.0f;
            
        }

        namespace Air {
            // Role switch cadence (seconds)
            int MinAiSwitchTime = 20;
            int MaxAiSwitchTime = 60;

            // NukeLimit: maximum number of nukes allowed for AIR role
            int NukeLimit = 0;
            // legbastion stays capped at 0 until the native average metal income
            // (aiEconomyMgr.metal.income) reaches this. See Air_UpdateBastionGate.
            float BastionMinAvgMetalIncome = 115.0f;
            /******************** AIR BASE SETTINGS ********************/
            // All settings applied to air role at game start, logic can change throughout game
            float AllyRange = 1600.0f;

            /******************** AIR MILITARY QUOTAS ********************/
            // Scout unit cap for AIR role
            int MilitaryScoutCap = 10;
            // Attack gate (required power to trigger attack waves)
            float MilitaryAttackThreshold = 1.0f;
            // Raid thresholds (power)
            float MilitaryRaidMinPower = 1.0f;
            float MilitaryRaidAvgPower = 1.0f;

            /******************** DYNAMIC FACTORY PRODUCTION ********************/
            // Toggle for role-based dynamic factory production system for AIR role.
            // When enabled, AIR factories (T1/T2 aircraft plants, gantries that
            // produce aircraft, etc.) delegate unit selection to
            // FactoryProduction::MakeTask using threat-aware scoring.
            bool UseDynamicFactoryProduction = false;
            /******************** AIR DYNAMIC QUOTA SETTINGS ********************/
            // Enemy surface cost multiplier used to determine when AIR is underpowered.
            // If our estimated army metal cost is below enemySurfaceCostPerPlayer * multiplier,
            // AIR is considered underpowered and will switch to more aggressive quotas.
            float DynamicQuotaEnemyCostThresholdMultiplier = 0.9f;

            // Underpowered quotas: used when AIR is behind in army power vs enemy surface cost.
            float UnderpoweredAttackQuota = 100.0f;
            float UnderpoweredRaidMinQuota = 100.0f;
            float UnderpoweredRaidAvgQuota = 200.0f;

            // Delay (in seconds) before AIR starts applying dynamic quota adjustments.
            // Mirrors Front role behavior but scoped to AIR so roles can diverge if needed.
            int DynamicQuotaDelaySeconds = 5 * 60;

            /******************** AIR ECONOMY SETTINGS ********************/
            // Mostly delegate economy to AI for air, but give it an early start

            //Continue building normal solars if ever below this energy income level
            float SolarEnergyIncomeMinimum = 300.0f;

            // T1 Energy converter policy (Air-specific thresholds)
            // Build converters while metal income is below this threshold
            float BuildT1ConvertersUntilMetalIncome = 35.0f;
            // Require at least this much energy income
            float BuildT1ConvertersMinimumEnergyIncome = 150.0f;
            // Require current energy to be at least this fraction of storage (e.g., 0.90 = 90%)
            float BuildT1ConvertersMinimumEnergyCurrentPercent = 0.75f;

            //Continue building advanced solars if ever below this energy income level
            float AdvancedSolarEnergyIncomeMinimum = 1100.0f; 

            //Stop building advanced solar if above this energy income level
            float AdvancedSolarEnergyIncomeMaximum = 1200.0f; 
            // Barb4 has no timing gate here at all; keep only a small metal floor.
            int AdvancedSolarEarliestSeconds = 0;
            float AdvancedSolarMinimumMetalIncome = 6.0f;
            float AdvancedSolarMinimumMetalCurrent = 100.0f;

            // Prefer cheap wind generators before advanced solar when CircuitAI's
            // effective average wind output exceeds BAR's good-wind threshold.
            float GoodWindMinimumEnergy = 7.0f;
            int CommanderWindTargetCount = 6;
            float CommanderWindEnergyIncomeTarget = 300.0f;
            float CommanderWindMinimumMetalCurrent = 80.0f;

            // Eco crew: every T1 air constructor except the primary builds economy
            // (converter, advanced solar, wind or solar) before it assists a factory
            // project. See Air_TryEcoBuild.
            bool EcoCrewEnabled = true;
            // Seconds between two crew enqueues of the same building type, so several
            // constructors spread over types instead of stacking one kind.
            int EcoCrewCooldownSeconds = 6;
            // Metal the crew leaves in store for the factory projects.
            float EcoCrewMinMetalCurrent = 40.0f;

            /******************** METAL-STARVED MODE (Air_UpdateEcoPriority) ********************/
            // Starved from the moment the metal bank drops below EnterPercent of
            // storage until it is back above ExitPercent. While starved, metal goes
            // to wave bombers, fusions and AFUS only:
            //   T2 plant  wave bombers and the T2 air constructor minimum; no T2
            //             fighters or escorts, heavy air, T2 scouts, dynamic or
            //             native fallback production (the plant waits instead)
            //   T2 cons   straight to the reactor ladder (fusions to FusionsBeforeAFUS,
            //             then AFUS) at NOW priority - the only priority native hands
            //             to idle builders during a metal stall - no mex upgrade and
            //             no advanced converters
            //   porc      PREVENT: one structure per cluster, no budget bonus
            // The T1 plant and the T1 constructors are unchanged.
            /******************** ECO RETIREMENT (Air_UpdateEcoRetire) ********************/
            // Lower-tier energy is reclaimed to free build room once what replaces
            // it is up, and never built again: winds and solars once
            // RetireWindSolarAtFusions fusions have finished, advanced solars at
            // RetireAdvSolarAtFusions, T1 energy converters once
            // RetireT1ConvertersAtAdvConverters advanced converters have finished.
            // Each step latches. Up to EcoRetireConcurrentReclaims reclaim tasks run
            // at once; one nobody takes expires after EcoRetireReclaimTimeoutSeconds
            // and is queued again.
            bool EcoRetireEnabled = true;
            int RetireWindSolarAtFusions = 1;
            int RetireAdvSolarAtFusions = 2;
            int RetireT1ConvertersAtAdvConverters = 2;
            int EcoRetireConcurrentReclaims = 3;
            int EcoRetireReclaimTimeoutSeconds = 60;

            bool EcoPriorityEnabled = true;
            float EcoPriorityEnterPercent = 0.10f;
            float EcoPriorityExitPercent = 0.20f;
            int EcoPriorityFactoryWaitSeconds = 5;
            // Crew wind on good-wind maps: up to this many, below this energy income.
            int EcoCrewWindMaxCount = 24;
            float EcoCrewWindEnergyIncomeTarget = 600.0f;

            // Post-T2 reactor ladder (ReactorLadder::TryT2Economy, shared with FRONT). Fusion is uncapped for AIR
            // and advanced fusion is capped at MaxAdvancedFusionReactors; the ladder
            // only orders them:
            //   1. FusionsBeforeAFUS fusions (from MinimumMetalIncomeForFUS average income)
            //   2. the first AFUS, once those fusions are finished - AFUS stays capped
            //      at 0 until then so native energy tasks cannot jump the queue
            //   3. more AFUS whenever energy is below AdvConverterEnergyPercent of
            //      storage, advanced converters whenever it is above; the second AFUS
            //      is queued as soon as the first is finished
            //   4. once ReclaimFusionsAtAFUSCount AFUS exist (the second counts from
            //      the moment its nanoframe is down), the tracked fusions are
            //      reclaimed one at a time to fund it
            float MinimumMetalIncomeForFUS = 18.0f;
            int FusionsBeforeAFUS = 2;
            int ReclaimFusionsAtAFUSCount = 2;
            int MaxAdvancedFusionReactors = 20;
            float AdvConverterEnergyPercent = 0.80f;
            // Advanced converter ceiling per finished reactor (fusion ~1000 E,
            // AFUS ~3000 E, a converter draws ~600 E).
            int AdvConvertersPerFusion = 1;
            int AdvConvertersPerAFUS = 4;

            /******************** T2 AIRCRAFT PLANT THRESHOLDS (AIR role) ********************/
            // Economy thresholds and caps for building a T2 Aircraft Plant when in AIR role
            // Defaults mirror TECH thresholds but are scoped to AIR so air.as does not reference TECH settings.
            float RequiredMetalIncomeForT2AircraftPlant = 30.0f;
            float RequiredMetalCurrentForT2AircraftPlant = 50.0f;
            float RequiredEnergyIncomeForT2AircraftPlant = 1200.0f;
            // Extra advanced aircraft plants by native average metal income: the second
            // at 100, the third at 200, never more than MaxT2AircraftPlants. Enforced
            // as the def cap (Air_UpdateT2PlantCap), so native factory tasks obey it too.
            int MaxT2AircraftPlants = 3;
            float SecondT2AircraftPlantMetalIncome = 100.0f;
            float ThirdT2AircraftPlantMetalIncome = 200.0f;

            /******************** PORC: AIR DENIAL ********************/
            // AIR porcs earlier, harder, and for the whole team. Global::Porc
            // decides when a cluster gets the full chain (by time or income)
            // and how big each visit's budget is; these override it in
            // Air_Init so AIR reaches full porc mid game rather than late.
            int PorcLateGameMinutes = 12;
            float PorcLateGameMetalIncome = 50.0f;
            float PorcLateGameEnergyIncome = 800.0f;
            float PorcLateBudgetMod = 1.5f;
            // Build anti-air in allied clusters too (native porcAllyAA): the
            // enemy air goes where the allies are, and ground defence there
            // stays the ally's own business.
            bool PorcAlliedClustersAA = true;

            /******************** LATE-GAME EXPANSION ********************/
            // AIR sat at max metal late: one T2 air plant, nanos capped by
            // income, and nothing else to spend on. This ladder runs while
            // metal is floating and turns the surplus into build power, more
            // air production placed on a ring well outside the core, the energy
            // to carry it, and finally a gantry - the only route to T3 air,
            // since the experimental air plant is built solely by the T3 air
            // constructor the gantry produces.
            // "Floating": aiEconomyMgr.isMetalFull (> 80% of storage), or
            // current above LateMetalCurrent - and income above LateMetalIncome
            // either way, so a full bank on a dead economy does not trigger it.
            float LateMetalCurrent = 2500.0f;
            float LateMetalIncome = 35.0f;
            // Ring the late structures are placed on, around the start position,
            // and the site-search radius each gets. This is what grows the base.
            float LateExpansionRadius = 1400.0f;
            float LateExpansionShake = 384.0f;   // SQUARE_SIZE * 48
            int LateRingSlots = 6;
            // Build power first: nanos per T2 air plant beyond the income target.
            // 8 (was 4): with the bank floating past 10 000, four per plant left
            // the plants unable to spend it (All That Glitters 2026-09-27).
            int LateNanosPerT2Plant = 8;
            // Then production: total T2 air plants allowed while floating.
            int LateMaxT2AircraftPlants = 3;
            // Then energy: one fusion per this much energy income shortfall, and
            // an advanced fusion once income and bank both clear these.
            float LateEnergyPerT2Plant = 900.0f;
            float LateAFUSMetalIncome = 60.0f;
            float LateAFUSMetalCurrent = 6000.0f;
            // Then T3: a gantry once this rich. Gantry production is
            // FactoryProduction's business (EnqueueGantrySignatureBatch).
            float LateGantryMetalIncome = 60.0f;
            float LateGantryMetalCurrent = 6000.0f;

            /******************** AIR NANO POLICY ********************/
            // How much income per additional T1 nano caretaker; and cap
            float NanoEnergyPerUnit = 200.0f; // energy per nano
            float NanoMetalPerUnit = 10.0f;   // metal per nano
            int NanoMaxCount = 200;            // cap
            // Reserves-based nano condition threshold
            float NanoBuildWhenOverMetal = 1000.0f;

            // T1 air constructors, Barb4-style: the first is unconditional, then
            // MinT1AirConstructorCount outright and one per T1AirConstructorPerMetalIncome
            // of (10 s minimum) metal income, up to MaxT1AirConstructorCount, held back
            // only by an energy stall. Primary and secondary aside, the rest form the eco crew.
            int MinT1AirConstructorCount = 3;
            float T1AirConstructorPerMetalIncome = 5.0f;
            int MaxT1AirConstructorCount = 8;

            // Maximum staged T2 air-constructor target. When enabled, the first
            // is unconditional.
            int MinT2AirConstructorCount = 2;
            float SecondT2AirConstructorMetalIncome = 40.0f;
            float SecondT2AirConstructorEnergyIncome = 1200.0f;

            // Minimum number of air scouts to maintain globally for early map vision
            int MinAirScoutCount = 1;
            // After the opener, one air scout every this many seconds for the whole
            // game (0 = off), skipped while MaxAliveAirScouts are still alive.
            // See Air_TryAirScout.
            int ScoutIntervalSeconds = 4 * 60;
            int MaxAliveAirScouts = 4;

            // Small economy-gated interception reserve. Dynamic/native production
            // handles additional air-defense demand.
            int MinT1FighterCount = 2;
            float T1CombatProductionMetalIncome = 12.0f;
            float T1CombatProductionEnergyIncome = 250.0f;

            /******************** EARLY BUILD-POWER FOCUS ********************/
            // Keep one strategic lane and one expansion lane until the economy is
            // established or the deadline expires. Additional constructors assist
            // those active lanes.
            int BuildFocusDeadlineSeconds = 6 * 60;
            float BuildFocusMetalIncome = 20.0f;
            float BuildFocusEnergyIncome = 300.0f;
            int BuildFocusAssistTimeoutSeconds = 15;
            int BuildFocusIdleWaitSeconds = 5;

            // One-time T1 strike package. Keep this small so it does not delay economy growth.
            int T1StrikeOpenerSize = 3;
            float T1StrikeOpenerMinimumMetalIncome = 12.0f;
            float T1StrikeOpenerMinimumEnergyIncome = 250.0f;
            // Until the first T2 aircraft plant is finished, each T1 bomber / gunship
            // def (armthund, armkam, corshad, corbw, legmos, legcib, legkam) is capped
            // at this many alive; then the caps go back. See Air_UpdateT1StrikeCap.
            int T1StrikeCapBeforeT2 = 3;

            /******************** T2 BOMBER WAVES ********************/
            // T1 bombers keep the native trickle (each bomber attacks as it is built).
            // T2 bombers are held at base with an escort of T2 fighters and released
            // together in waves that grow from FirstSize towards MaxSize. The sizing
            // algorithm and the native primitives are documented in manager/air_waves.as.
            bool BomberWavesEnabled = true;
            int BomberWaveFirstSize = 10;          // bombers in the first wave, and the floor
            int BomberWaveMaxSize = 20;            // hard cap on bombers per launch (stock or held)
            // Late-game lift: 20-bomber waves die to mature AA before they reach
            // anything. From LateBomberWaveMinutes on, once the average metal income
            // (aiEconomyMgr.metal.income) reaches LateBomberWaveMetalIncome, both wave
            // caps - BomberWaveMaxSize and Global::BomberStock::MaxWaveSize - rise to
            // LateBomberWaveMaxSize. Latches: a later dip does not shrink the waves.
            // See BomberStock::WaveCap.
            int LateBomberWaveMinutes = 45;
            float LateBomberWaveMetalIncome = 400.0f;
            int LateBomberWaveMaxSize = 40;
            float BomberWaveFighterRatio = 1.0f;   // fighters held per bomber before a launch
            // Escorts do not soak AA (bombers are AA's first priority), so they
            // are only worth delaying a wave for when the enemy flies. Below the
            // first figure no escort is held; at the second the full ratio is.
            float EscortMinEnemyAirCost = 300.0f;
            float EscortFullEnemyAirCost = 3000.0f;
            // New wave fighters park (out of AI control, holding position) until
            // FighterGroupSize of them are waiting, then go into the fighter hold
            // together as one squad. A hold engages enemy air inside our defence
            // influence, and a lone fighter's hold did so on its own: on Baryon Tar
            // Lake (2026-09-26) AIR lost roughly one Hawk per Hawk built and launched
            // six waves with no escort. Parked fighters still go with a launching
            // wave as escorts. 1 = no parking.
            int FighterGroupSize = 4;
            // Growth applied to the previous wave size from its survival ratio, measured
            // EvaluateSeconds after launch: heavy losses mean the enemy anti-air is winning
            // and the next wave needs mass; light losses grow gently.
            float BomberWaveLowSurvival = 0.4f;
            float BomberWaveHighSurvival = 0.8f;
            float BomberWaveGrowthOnHeavyLoss = 2.0f;
            float BomberWaveGrowthDefault = 1.5f;
            float BomberWaveGrowthOnLightLoss = 1.25f;
            int BomberWaveEvaluateSeconds = 120;
            // Enemy anti-air floor: the wave's bomber metal must reach this fraction of the
            // enemy anti_air metal on the map (Military cost cache, refreshed every update).
            float BomberWaveEnemyAAMetalFraction = 0.5f;
            // Launch anyway once FirstSize bombers have been held this long, so production
            // that cannot reach the target in time never stalls the air war.
            int BomberWaveMaxHoldSeconds = 8 * 60;
            // After a launch, released units re-enter Military::AiMakeTask within a few
            // seconds; units that ask later than this rejoin the hold instead.
            int BomberWaveReleaseWindowSeconds = 15;
            // Minimum metal income before the T2 plant produces wave aircraft.
            float BomberWaveProductionMetalIncome = 40.0f;
            // Income floor on the wave size (D-045): every IncomeStep of metal
            // income adds SizePerIncomeStep bombers to what a wave must hold
            // before it launches - at +100 a wave is 50, at +200 it is 100.
            // The survival growth still applies above the floor.
            float BomberWaveIncomeStep = 100.0f;
            int BomberWaveSizePerIncomeStep = 50;

            /******************** WAVE ATTACK METHODS ********************/
            // Each launch draws a method by these weights (doc/air-wave-attacks.md).
            // 0 removes a method.
            float WaveWeightCarpet = 3.0f;
            float WaveWeightFlank = 2.0f;
            float WaveWeightPincer = 1.0f;
            float WaveWeightStrike = 2.0f;
            float WaveWeightDeep = 1.0f;
            float WaveWeightFeint = 1.0f;
            // Geometry, elmos: the line forms FormDistance short of the aim,
            // lanes Spacing apart, and runs Overrun past it.
            float WaveFormDistance = 1400.0f;
            float WaveLaneSpacing = 96.0f;
            float WaveOverrun = 900.0f;
            int WaveFormTimeoutSeconds = 45;   // go anyway if the line is not formed by then
            float WaveFlankMinDeg = 55.0f;     // FLANK bearing off the base->aim line
            float WaveFlankMaxDeg = 95.0f;
            float WavePincerDeg = 45.0f;       // PINCER: both lines this far off the line
            int WaveFeintHoldSeconds = 25;     // FEINT: hold the formed line this long
            // STRIKE / DEEP target filter: statics at or above this cost, plus T3 ("heavy") mobiles.
            float WaveStrikeMinStaticCost = 2500.0f;

            // Armada Liche in the waves: from this native average metal income, every
            // LicheEveryNthBomber-th wave bomber is armliche (8 = 7 Blizzards + 1 Liche).
            // 110 is where armaap's own factory.json weights (income_tier [50, 110])
            // raise the Liche from 10% to 30%.
            float LicheMinMetalIncome = 110.0f;
            int LicheEveryNthBomber = 8;

            /******************** HEAVY AIR STRIKE POLICY (Legion/Cortex) ********************/
            // Maintain a bounded late-game heavy-air force for Legion/Cortex.
            // 100, not 250: the AIR role spent a whole Hotlips match at 50-150
            // metal income (peak 261), so 250 never let a Tyrannus/Dragon through.
            float T2HeavyAirIncomeThreshold = 100.0f;
            int T2HeavyAirTargetCount = 6;
            // One heavy per heavy turn, and a heavy turn is one T2 production
            // decision in this many; the rest go to the bomber waves (legphoenix /
            // corhurc) and escorts. 1 = every turn, the old behaviour.
            int T2HeavyAirBatchPerFactory = 1;
            int T2HeavyAirEveryNthTurn = 4;

            /******************** COMMANDER FACTORY ASSIST ********************/
            // Maximum time spent assisting the opening aircraft plant. Assistance
            // ends sooner as soon as the first construction aircraft is complete.
            int CommanderFactoryAssistDeadlineSeconds = 90;

            // Duration (in seconds) for each guard assignment when assisting the
            // primary T1 aircraft plant. Tasks may be renewed while within the
            // assist deadline window.
            int CommanderFactoryAssistGuardTimeoutSeconds = 10; // default: 10-second guard tasks

        }

        namespace Front {
            // Role switch cadence (seconds)
            int MinAiSwitchTime = 20;
            int MaxAiSwitchTime = 60;

            // NukeLimit: maximum number of nukes allowed for FRONT role
            int NukeLimit = 0;
            /******************** FRONT BASE SETTINGS ********************/
            // All settings applied to front role at game start, logic can change throughout game
            float AllyRange = 900.0f;

            /******************** FRONT MILITARY QUOTAS ********************/
            // Scout unit cap for FRONT role (defaults)
            int MilitaryScoutCap = 2;
            // Attack gate (required power to trigger attack waves) (defaults)
            float MilitaryAttackThreshold = 20.0f;
            // Raid thresholds (power) (defaults)
            float MilitaryRaidMinPower = 40.0f;
            float MilitaryRaidAvgPower = 180.0f;

            // Split thresholds by opening: bots vs vehicles.
            // These default to the baseline values above; tweak per-profile as needed.
            int MilitaryScoutCapBots = 7;
            int MilitaryScoutCapVehicles = 2;
            float MilitaryAttackThresholdBots = 12.0f;
            float MilitaryAttackThresholdVehicles = 30.0f;
            float MilitaryRaidMinPowerBots = 12.0f;
            float MilitaryRaidMinPowerVehicles = 40.0f;
            float MilitaryRaidAvgPowerBots = 60.0f;
            float MilitaryRaidAvgPowerVehicles = 180.0f;

            // Number of T1 scouts/raiders to rush from the very first T1 land factory
            // Only applies to the first T1 Bot Lab or Vehicle Plant built; subsequent factories use normal logic
            int ScoutRushCount = 1;

             /******************** FRONT NANO POLICY ********************/
            // How much income per additional T1 nano caretaker; and cap
            float NanoEnergyPerUnit = 150.0f; // energy per nano
            float NanoMetalPerUnit = 10.0f;   // metal per nano
            int NanoMaxCount = 200; 
            int NanoMinCount = 1;
            float NanoEnergyIncomeThresholdForMax = 2000.0f;
            // Reserves-based nano condition threshold
            float NanoBuildWhenOverMetal = 1000.0f;

            // Base porc (Front_AiMakeDefence): clusters this close to the start walk
            // the whole porc order (the Beamer / Twin Guard / Dragon's Jaw opening)
            // from this minute on, instead of the native heuristic's single LLT.
            float BasePorcRadius = 1600.0f;
            int BasePorcFromMinutes = 3;

            // Minimum constructor maintenance targets for factory recruitment
            int MinT1BotConstructorCount = 1;
            int MinT1VehicleConstructorCount = 1;

            // Minimum T2 constructor targets for FRONT role.
            // These mirror TECH's MinimumT2ConstructorBots but are scoped to FRONT so
            // front.as can enforce its own T2 constructor policy without cross-referencing.
            int MinT2BotConstructorCount = 1;
            int MinT2VehicleConstructorCount = 1;

            // Time triggers for T2 lab construction
            int TimeTriggerForFirstT2LabSeconds = 22 * 60; // 22 minutes
            int TimeTriggerForT2EcoGatingSeconds = 20 * 60; // 20 minutes

            // Combat settings
            int DefaultT1CombatFireState = 3;

            // Start Caps
            int StartCapRezBots = 10;
            int StartCapT1AircraftPlants = 0;
            int StartCapNukeSilos = 0;

            // Dynamic Quota Settings
            float DynamicQuotaEnemyCostAttackThresholdMultiplier = 1.0f;
            float DynamicQuotaEnemyCostWithdrawThresholdMultiplier = 0.8f;
            float UnderpoweredAttackQuota = 100.0f;
            float UnderpoweredRaidMinQuota = 100.0f;
            float UnderpoweredRaidAvgQuota = 200.0f;
            int DynamicQuotaDelaySeconds = 2 * 60;

            // Economy Scaling Limits
            float MetalIncomePerLab = 35.0f;
            float MetalIncomeForGantry = 250.0f;
            float MetalIncomePerT1Builder = 20.0f;
            int MinBuilderCap = 5;
            float MetalIncomePerT2Builder = 40.0f;

            // Misc Logic Settings
            int RaiderOpenerCount = 10;
            float SwitchFactoryCostMultiplier = 1.2f;
            int ScoutAssignmentLimit = 5;
            float BuilderCostThresholdForBase = 200.0f;

            // Nano Policy Extras
            float NanoMinIncomeForFirst = 10.0f;
            float T2LabStoredMetalThresholdRatio = 0.9f;

            // Transition thresholds for switching between T1 factory types (Bot <-> Vehicle)
            float MinimumMetalIncomeForT1FactoryTransition = 200.0f;

            /******************** FRONT T2 LAB THRESHOLDS ********************/
            // Economy thresholds and caps for building a T2 Bot Lab when in FRONT role
            // Mirrors FrontTech defaults but scoped to Front so front.as does not reference FrontTech settings.
            // Special-case: first T2 lab/plant fast-track threshold (bot or vehicle) when none exist yet
            // If total T2 labs (bot + vehicle) < 1 and metal income >= this, FRONT will attempt to build one.
            float MinimumMetalIncomeForFirstT2Lab = 50.0f;
            float MinimumMetalIncomeForT2Lab = 40.0f;
            float MinimumEnergyIncomeForT2Lab = 2000.0f;
            float RequiredMetalCurrentForT2Lab = 200.0f;

            // Vehicle-specific T2 thresholds
            float MinimumMetalIncomeForFirstT2VehiclePlant = 50.0f;
            float MinimumMetalIncomeForT2VehiclePlant = 40.0f;
            float MinimumEnergyIncomeForT2VehiclePlant = 2000.0f;
            float RequiredMetalCurrentForT2VehiclePlant = 200.0f;

            int MaxT2BotLabs = 1;
            int MaxT2VehicleLabs = 1;

            /******************** DYNAMIC FACTORY PRODUCTION ********************/
            // Toggle for role-based dynamic factory production system (replaces factory.json logic)
            // When enabled, FRONT factories (labs, air plants, gantries, etc.) delegate unit
            // selection to FactoryProduction::MakeTask using threat-aware scoring.
            bool UseDynamicFactoryProduction = false;

            /******************** FRONT ECONOMY SETTINGS ********************/
            // Consider energy storage "low" when current < storage * percent
            float EnergyStorageLowPercent = 0.90f;

            // Minimum incomes levels before normal Fusion will be built
            float MinimumMetalIncomeForFUS = 40.0f; 
            float MinimumEnergyIncomeForFUS = 1200.0f;
            float MaxEnergyIncomeForFUS = 4000.0f;
        }

        namespace Support {
            /******************** SUPPORT BASE SETTINGS ********************/
            // All settings applied to support role at game start, logic can change throughout game
            float AllyRange = 1300.0f;

            /******************** SUPPORT MILITARY QUOTAS ********************/
            // Scout unit cap for SUPPORT role
            int MilitaryScoutCap = 2;
            // Attack gate (required power to trigger attack waves)
            float MilitaryAttackThreshold = 40.0f;
            // Raid thresholds (power)
            float MilitaryRaidMinPower = 60.0f;
            float MilitaryRaidAvgPower = 80.0f;

            /******************** SUPPORT ECONOMY SETTINGS ********************/
            // Continue building normal solars if ever below this energy income level
            float SolarEnergyIncomeMinimum = 160.0f;
            // T1 Energy converter policy (Support-specific thresholds)
            // Build converters while metal income is below this threshold
            float BuildT1ConvertersUntilMetalIncome = 18.0f;
            // Require at least this much energy income
            float BuildT1ConvertersMinimumEnergyIncome = 250.0f;
            // Require current energy to be at least this fraction of storage (e.g., 0.90 = 90%)
            float BuildT1ConvertersMinimumEnergyCurrentPercent = 0.90f;
            // Continue building advanced solars if ever below this energy income level
            float AdvancedSolarEnergyIncomeMinimum = 600.0f;
            // Stop building advanced solars if above this energy income level
            float AdvancedSolarEnergyIncomeMaximum = 1000.0f;

            // T2 lab build thresholds for Support role
            float MinimumMetalIncomeForT2Lab = 17.0f;
            float MinimumEnergyIncomeForT2Lab = 550.0f;
            float RequiredMetalCurrentForT2Lab = 800.0f;

            int MaxT2BotLabs = 1;

            /******************** BUILDER CAP LIMITS ********************/
            // Hard caps for T1/T2 land builders used when computing income-based limits
            int MaxT1Builders = 5;
            int MaxT2Builders = 5;

            /******************** FRONT TECH NANO POLICY ********************/
            float NanoEnergyPerUnit = 200.0f; // energy per nano
            float NanoMetalPerUnit = 10.0f;   // metal per nano
            int NanoMaxCount = 200;            // cap
            // Reserves-based nano condition threshold
            float NanoBuildWhenOverMetal = 1000.0f;

            /******************** FRONT TECH ASSIST POLICY ********************/
            // If metal income is below this, secondary T1 will assist primary T1
            float SecondaryT1AssistMetalIncomeMax = 80.0f;

            /******************** COMMANDER FACTORY ASSIST (SUPPORT) ********************/
            // Duration (in seconds) from game start during which the SUPPORT commander
            // will prioritize guarding the primary T1 land factory (bot lab or vehicle plant)
            // instead of falling back to default builder behavior.
            int CommanderFactoryAssistDeadlineSeconds = 80; // default: first 2 minutes

            // Duration (in seconds) for each guard assignment when assisting the
            // primary T1 land factory. Tasks may be renewed while within the
            // assist deadline window.
            int CommanderFactoryAssistGuardTimeoutSeconds = 10; // default: 10-second guard tasks
        }

        namespace Sea {
            // Role switch cadence (seconds)
            int MinAiSwitchTime = 20;
            int MaxAiSwitchTime = 60;

            // NukeLimit: maximum number of nukes allowed for SEA role
            int NukeLimit = 0;
            /******************** SEA BASE SETTINGS ********************/
            // All settings applied to sea role at game start, logic can change throughout game
            float AllyRange = 2000.0f;

            /******************** SEA MILITARY QUOTAS ********************/
            // Scout unit cap for SEA role
            int MilitaryScoutCap = 3;
            // Attack gate (required power to trigger attack waves)
            float MilitaryAttackThreshold = 1.0f;
            // SEA waves: shorter wait and a lower bar than the global default -
            // a navy that sits is a navy that loses the water.
            float MilitaryAttackWaitSeconds = 120.0f;
            float MilitaryAttackScale = 0.7f;
            // Raid thresholds (power)
            float MilitaryRaidMinPower = 1.0f;
            float MilitaryRaidAvgPower = 5.0f;

            /******************** SEA ECONOMY SETTINGS ********************/
            // Prefer tidals over solars at sea; consider adding tidals if energy income is below this
            float TidalEnergyIncomeMinimum = 1200.0f; // tune per map; tidals vary
            // If energy is low, allow assisting the primary T1 sea worker
            float AssistPrimaryWorkerEnergyIncomeMinimum = 500.0f;

            // Early resurrection-sub policy toggle and tuning
            // When enabled, T1 shipyards may produce resurrection submarines early based on income scaling
            bool EnableEarlyRezSub = false;
            // Income scaling: allowed rez-sub count = floor(metalIncome / MetalIncomePerRezSub)
            float MetalIncomePerRezSub = 60.0f;

            // Consider energy storage "low" when current < storage * percent (SEA scope)
            float EnergyStorageLowPercent = 0.90f;

            // Minimum incomes for building advanced (T2) energy converter at sea
            float MinimumMetalIncomeForAdvConverter = 18.0f;
            float MinimumEnergyIncomeForAdvConverter = 1200.0f;

            // T1 Energy converter policy (SEA-specific thresholds)
            // Build converters while metal income is below this threshold
            float BuildT1ConvertersUntilMetalIncome = 40.0f;
            // Require at least this much energy income
            float BuildT1ConvertersMinimumEnergyIncome = 250.0f;
            // Require current energy to be at least this fraction of storage (e.g., 0.90 = 90%)
            float BuildT1ConvertersMinimumEnergyCurrentPercent = 0.90f;

            // Fusion Reactor thresholds (SEA scope)
            float MinimumMetalIncomeForFUS = 30.0f; 
            float MinimumEnergyIncomeForFUS = 1200.0f;
            float MaxEnergyIncomeForFUS = 999999.0f;

            /******************** SEA BUILDER GUARD CAPS ********************/
            // Max number of workers assigned as guards to a single leader (primary or secondary) for SEA
            // Defaults mirror global caps; tune down to limit construction ships guarding.
            int BuilderMaxGuardsPerLeader = 2;
            // Max number of workers assigned as guards to a tactical SEA constructor
            int BuilderMaxGuardsPerTacticalLeader = 0;

            /******************** SEA NANO POLICY ********************/
            float NanoEnergyPerUnit = 200.0f; // energy per nano
            float NanoMetalPerUnit = 20.0f;   // metal per nano
            int NanoMaxCount = 200;            // cap
            // Reserves-based nano condition threshold
            float NanoBuildWhenOverMetal = 1000.0f;

            /******************** SEA T2 SHIPYARD THRESHOLDS ********************/
            // Economy thresholds and caps for building an Advanced Shipyard (T2)
            // Require primary T1 shipyard to exist before attempting T2
            float MinimumMetalIncomeForT2Shipyard = 40.0f;
            float MinimumEnergyIncomeForT2Shipyard = 800.0f;
            float RequiredMetalCurrentForT2Shipyard = 800.0f;
            int MaxT2Shipyards = 1;

            /******************** DYNAMIC FACTORY PRODUCTION ********************/
            // Toggle for role-based dynamic factory production system (replaces factory.json logic)
            // When enabled, uses threat-driven unit selection with tier scaling
            bool UseDynamicFactoryProduction = false;

            /******************** SEA FACTORY OUTPUT TARGETS ********************/
            // Maintain at least this many T2 destroyers; when below, enqueue in batches
            int MinT2DestroyerCount = 5;
            int T2DestroyerBatchSize = 5;

            /******************** COMMANDER FACTORY ASSIST (SEA) ********************/
            // Duration (in seconds) from game start during which the SEA commander
            // will prioritize guarding the primary T1 shipyard instead of falling
            // back to default builder behavior.
            int CommanderFactoryAssistDeadlineSeconds = 3 * 60; // default: first 2 minutes

            // Duration (in seconds) for each guard assignment when assisting the
            // primary T1 shipyard. Tasks may be renewed while within the
            // assist deadline window.
            int CommanderFactoryAssistGuardTimeoutSeconds = 10; // default: 10-second guard tasks

            /******************** SEA DYNAMIC QUOTA SETTINGS ********************/
            // Enemy surface cost multiplier used to determine when SEA is underpowered.
            float DynamicQuotaEnemyCostThresholdMultiplier = 1.0f;

            // Underpowered quotas: used when SEA is behind in army power vs enemy surface cost.
            float UnderpoweredAttackQuota = 100.0f;
            float UnderpoweredRaidMinQuota = 100.0f;
            float UnderpoweredRaidAvgQuota = 200.0f;

            // Delay (in seconds) before SEA starts applying dynamic quota adjustments.
            int DynamicQuotaDelaySeconds = 6 * 60;
        
        }

    namespace Tactical {
            /******************** SEA BASE SETTINGS ********************/
            // All settings applied to sea role at game start, logic can change throughout game
            float AllyRange = 3000.0f;

            /******************** SEA MILITARY QUOTAS ********************/
            // Scout unit cap for SEA role
            int MilitaryScoutCap = 4;
            // Attack gate (required power to trigger attack waves)
            float MilitaryAttackThreshold = 20.0f;
            // Raid thresholds (power)
            float MilitaryRaidMinPower = 30.0f;
            float MilitaryRaidAvgPower = 60.0f;

            /******************** HOVER SEA NANO POLICY ********************/
            // How much income per additional T1 nano caretaker; and cap
            float NanoEnergyPerUnit = 200.0f; // energy per nano
            float NanoMetalPerUnit = 10.0f;   // metal per nano
            int NanoMaxCount = 300; 
            // Reserves-based nano condition threshold
            float NanoBuildWhenOverMetal = 1000.0f;


            /******************** TACTICAL ECONOMY SETTINGS (formerly HOVER_SEA) ********************/
            
            //Continue building normal solars if ever below this energy income level
            float SolarEnergyIncomeMinimum = 160.0f; 
            // Continue building advanced solars if ever below this energy income level
            float AdvancedSolarEnergyIncomeMinimum = 1200.0f;
            // Stop building advanced solars if above this energy income level
            float AdvancedSolarEnergyIncomeMaximum = 3000.0f;

            // Minimum metal income to trigger building an Advanced Vehicle Plant (T2 Vehicle Lab)
            float RequiredMetalIncomeForT2VehiclePlant = 25.0f;

            // Minimum number of T1 hover constructors to maintain via Hover plant production
            int MinHoverConstructorCount = 10;

            // Income-scaled Hover Plant policy
            // Build allowance: 1 base plant + floor(metalIncome / MetalIncomePerExtraHoverPlant),
            // clamped to MaxHoverPlants. Defaults: +1 per 50 metal income, max 3 plants total.
            float MetalIncomePerExtraHoverPlant = 50.0f;
            int MaxHoverPlants = 3;
            // A construction ship TACTICAL owns runs SEA's naval ladder with
            // SEA's numbers (helpers/sea_constructor_helpers.as, D-042).
            bool SeaConstructorMimicsSea = true;

            /******************** DYNAMIC FACTORY PRODUCTION ********************/
            // Toggle for role-based dynamic factory production system (replaces factory.json logic)
            // When enabled, uses threat-driven unit selection with tier scaling for hover factories
            bool UseDynamicFactoryProduction = false;

            /******************** TACTICAL START LIMIT CAPS ********************/
            // Initial caps applied at game start for the TACTICAL role (formerly HOVER_SEA)
            int StartCapT1BotLabs = 0;
            int StartCapT2BotLabs = 0;
            int StartCapT1VehiclePlants = 0;

            // Aircraft plants
            int StartCapT1AircraftPlants = 0;
            int StartCapT2AircraftPlants = 0;

            // Shipyards (water)
            int StartCapT1Shipyards = 0;
            int StartCapT2Shipyards = 0;
        }

        // --- End role-specific settings ---
    }

}
