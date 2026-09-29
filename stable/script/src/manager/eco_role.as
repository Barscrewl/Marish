// Which labs and constructors TECH's experimental economy works with, per role.
#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../global.as"
#include "../helpers/unit_helpers.as"
#include "factory.as"
#include "builder.as"

/******************************************************************************

ECO ROLE

TECH's experimental build system (D-066: roles/tech_build.as, tech_rules.as,
tech_chain.as, tech_plan.as, manager/layout.as, eco_planner.as) was written
around the bot labs: a throwaway T1 bot lab, the advanced bot lab it pays for,
and bot constructors. AIR runs the same system on its aircraft plants, so every
place that system names a lab or counts constructors asks here:

                      TECH                          AIR
  T1 lab              T1 bot lab                    T1 aircraft plant
  T2 lab              T2 bot lab                    T2 aircraft plant
  constructors        bot constructors              air constructors (and any bots)
  lab reclaim         the T1 lab once T2 begins,    never: AIR keeps its plants
                      the T2 lab once an advanced
                      fusion is under way
  land-only rows      forward constructors, front   skipped
                      factory clusters, spam labs

For TECH every answer is what the code said before, so TECH is unchanged.
The switch for AIR is Global::RoleSettings::Air::ExperimentalEco.

******************************************************************************/
namespace EcoRole {

    bool IsAir() { return Global::AISettings::Role == AiRole::AIR; }

    // The experimental system runs for this instance.
    bool Enabled()
    {
        if (IsAir()) return Global::RoleSettings::Air::ExperimentalEco;
        return Global::RoleSettings::Tech::ExperimentalBuild;
    }

    // TECH eats its labs to fund the economy (D-066, D-078); AIR keeps them.
    bool ReclaimsLabs() { return !IsAir(); }

    string T1LabName(const string &in side)
    {
        if (IsAir()) return UnitHelpers::GetT1AirPlantForSide(side);
        return UnitHelpers::GetT1BotLabForSide(side);
    }

    string T2LabName(const string &in side)
    {
        if (IsAir()) return UnitHelpers::GetT2AirPlantForSide(side);
        return UnitHelpers::GetT2BotLabForSide(side);
    }

    array<string> AllT1Labs()
    {
        if (IsAir()) return UnitHelpers::GetAllT1AircraftPlants();
        return UnitHelpers::GetAllT1BotLabs();
    }

    array<string> AllT2Labs()
    {
        if (IsAir()) return UnitHelpers::GetAllT2AircraftPlants();
        return UnitHelpers::GetAllT2BotLabs();
    }

    CCircuitUnit@ PrimaryT1Lab()
    {
        if (IsAir()) return Factory::primaryT1AirPlant;
        return Factory::primaryT1BotLab;
    }

    CCircuitUnit@ PrimaryT2Lab()
    {
        if (IsAir()) return Factory::primaryT2AirPlant;
        return Factory::primaryT2BotLab;
    }

    array<string> AllT1Cons()
    {
        array<string> ids = UnitHelpers::GetAllT1BotConstructors();
        if (IsAir()) {
            array<string> air = UnitHelpers::GetAllT1AirConstructors();
            for (uint i = 0; i < air.length(); ++i) ids.insertLast(air[i]);
        }
        return ids;
    }

    array<string> AllT2Cons()
    {
        array<string> ids = UnitHelpers::GetAllT2BotConstructors();
        if (IsAir()) {
            array<string> air = UnitHelpers::GetAllT2AirConstructors();
            for (uint i = 0; i < air.length(); ++i) ids.insertLast(air[i]);
        }
        return ids;
    }

    bool T2LabOffCooldown()
    {
        if (IsAir()) return Builder::IsT2FactoryOffCooldown();
        return Builder::IsT2BotFactoryOffCooldown();
    }

    void MarkT2LabEnqueued()
    {
        if (IsAir()) Builder::MarkT2FactoryEnqueued();
        else Builder::MarkT2BotFactoryEnqueued();
    }

    IUnitTask@ EnqueueT1Lab(const string &in side, const AIFloat3 &in pos, float shake, int timeout, Task::Priority prio)
    {
        if (IsAir()) return Builder::EnqueueT1AirFactory(side, pos, shake, timeout, prio);
        return Builder::EnqueueT1BotLab(side, pos, shake, timeout, prio);
    }

    // The T2 lab when the layout has no footprint for it.
    IUnitTask@ EnqueueT2LabFallback(const string &in side, const AIFloat3 &in pos, float shake, int timeout)
    {
        if (IsAir()) return Builder::EnqueueT2AirPlant(side, pos, shake, timeout);
        return Builder::EnqueueT2BotLabIfNeeded(side, pos, shake, timeout);
    }
}  // namespace EcoRole
