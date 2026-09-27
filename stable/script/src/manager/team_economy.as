#include "../global.as"
#include "../helpers/generic_helpers.as"

/******************************************************************************

TEAM ECONOMY (D-106)

The latest economic state of every allied team, human players included. The
engine lets an AI read an allied team's resources (Game::GetTeamResource*);
native keeps one snapshot per teammate from the ally team's list (the start
script's [teamN] entries of our allyteam, our own team excluded) and refreshes
it only when asked, so a decision that needs it asks first:

    TeamEconomy::UpdateAll();              // every teammate
    TeamEconomy::UpdateTeam(teamId);       // one teammate
    TeamEconomy::Metal(teamId, TeamEconomy::FREE)   // then read

Fields, per resource: CURRENT (bank), STORAGE, INCOME, USAGE, PULL, SHARE (the
share slider), SENT, RECEIVED, EXCESS (what overflowed), FREE (storage - bank).
A team counts as alive while its metal income is above 0 (every live team has
at least its commander's income; the engine has no dead-team query for an AI).
Sending resources goes through the engine's own share command.

******************************************************************************/
namespace TeamEconomy {

    const int METAL = 0;
    const int ENERGY = 1;

    const int CURRENT = 0;
    const int STORAGE = 1;
    const int INCOME = 2;
    const int USAGE = 3;
    const int PULL = 4;
    const int SHARE = 5;
    const int SENT = 6;
    const int RECEIVED = 7;
    const int EXCESS = 8;
    const int FREE = 9;

    // refresh one teammate's snapshot; false when it is not a teammate
    bool UpdateTeam(int teamId) { return aiEconomyMgr.UpdateTeamEconomy(teamId); }
    // refresh every teammate's snapshot; the number refreshed
    int UpdateAll() { return aiEconomyMgr.UpdateAllTeamEconomy(); }

    int Count() { return aiEconomyMgr.GetAllyTeamCount(); }
    int TeamAt(int index) { return aiEconomyMgr.GetAllyTeamIdAt(index); }
    bool Alive(int teamId) { return aiEconomyMgr.IsTeamAlive(teamId); }
    int Frame(int teamId) { return aiEconomyMgr.GetTeamEcoFrame(teamId); }   // -1: never refreshed

    float Metal(int teamId, int field) { return aiEconomyMgr.GetTeamEco(teamId, METAL, field); }
    float Energy(int teamId, int field) { return aiEconomyMgr.GetTeamEco(teamId, ENERGY, field); }
    float OwnMetal(int field) { return aiEconomyMgr.GetOwnEco(METAL, field); }
    float OwnEnergy(int field) { return aiEconomyMgr.GetOwnEco(ENERGY, field); }

    // the metal bank as a share of storage, 1 when storage is unknown
    float MetalFill(int teamId)
    {
        const float s = Metal(teamId, STORAGE);
        return (s > 0.0f) ? Metal(teamId, CURRENT) / s : 1.0f;
    }

    bool SendMetal(int teamId, float amount) { return aiEconomyMgr.SendResourceTo(METAL, amount, teamId); }
    bool SendEnergy(int teamId, float amount) { return aiEconomyMgr.SendResourceTo(ENERGY, amount, teamId); }

    // one line per teammate, for the log
    string Describe(int teamId)
    {
        return "team " + teamId + (Alive(teamId) ? "" : " (not alive)") + ": metal " + int(Metal(teamId, CURRENT)) + "/" + int(Metal(teamId, STORAGE))
            + " +" + int(Metal(teamId, INCOME)) + " (free " + int(Metal(teamId, FREE)) + "), energy " + int(Energy(teamId, CURRENT)) + "/"
            + int(Energy(teamId, STORAGE)) + " +" + int(Energy(teamId, INCOME));
    }
}
