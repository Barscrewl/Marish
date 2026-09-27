// Allied BARb roster: who is on our team, where they started, what they play.
#include "../define.as"
#include "../global.as"
#include "../types/ai_role.as"
#include "../helpers/generic_helpers.as"
#include "../helpers/map_helpers.as"
#include "widget_link.as"

/******************************************************************************

TEAM ROSTER

Every BARb instance on an ally team announces itself to the others with
AiSendMessage, and keeps what the others announce. The transport is in-process
(CInitScript::SendMessage queues a job on each allied instance's scheduler, so
delivery is asynchronous but same-frame-ordered and never re-entrant); human
allies and enemies never see it. The message is one line:

    roster|<version>|teamId|skirmishAIId|role|side|startFactory|x|z|landLocked|spotIndex|isLeader

Announcing starts as soon as this instance knows its own role and start
position (Setup resolves the role on the first factory choice, the start
position is captured from the commander), and repeats every RebroadcastFrames
until every allied team id from ai.GetTeamIds() has answered or GiveUpFrames
have passed. An instance that receives an announcement from a team it did not
know answers with its own, so late starters get the roster too; an instance
that already knew the sender just refreshes the entry, which ends the exchange.

Consumers read Team::Roster::Get / All / WithRole / Leader / Nearest. The lead
team (ai.GetLeadTeamId(), the instance that owns the native ally-team object)
is marked so donation logic can find it without a second query.

******************************************************************************/
namespace Team {
namespace Roster {
    const string Prefix = "roster|";
    const int Version = 1;
    const int RebroadcastFrames = 30 * SECOND;   // between announcements while allies are missing
    const int GiveUpFrames = 5 * MINUTE;         // stop repeating after this; replies still work

    class Entry {
        int teamId = -1;
        int skirmishAIId = -1;
        AiRole role = AiRole::FRONT;
        string side;
        string startFactory;
        AIFloat3 startPos;
        bool landLocked = false;
        int spotIndex = -1;        // index into Global::Map::Config.StartSpots, -1 when none
        bool isLeader = false;
        int receivedFrame = -1;
    }

    dictionary entries;            // team id string -> Entry@
    int firstBroadcastFrame = -1;
    int lastBroadcastFrame = -1;

    string RoleName(AiRole r)
    {
        switch (r) {
            case AiRole::FRONT: return "FRONT";
            case AiRole::AIR: return "AIR";
            case AiRole::TECH: return "TECH";
            case AiRole::SEA: return "SEA";
            case AiRole::SUPPORT: return "SUPPORT";
            case AiRole::TACTICAL: return "TACTICAL";
        }
        return "FRONT";
    }

    AiRole RoleFromName(const string &in n)
    {
        if (n == "AIR") return AiRole::AIR;
        if (n == "TECH") return AiRole::TECH;
        if (n == "SEA") return AiRole::SEA;
        if (n == "SUPPORT") return AiRole::SUPPORT;
        if (n == "TACTICAL") return AiRole::TACTICAL;
        return AiRole::FRONT;
    }

    // Own role and start position are known.
    bool IsReady()
    {
        return Global::Map::MapResolved && Global::Map::HasStart;
    }

    int OwnSpotIndex()
    {
        StartSpot@[]@ spots = Global::Map::Config.StartSpots;
        if (spots is null || spots.length() == 0) return -1;
        return MapHelpers::NearestSpotIdx(Global::Map::StartPos, spots);
    }

    string Encode()
    {
        const AIFloat3 pos = Global::Map::StartPos;
        return Prefix + Version
            + "|" + ai.teamId
            + "|" + ai.skirmishAIId
            + "|" + RoleName(Global::AISettings::Role)
            + "|" + Global::AISettings::Side
            + "|" + Global::AISettings::StartFactory
            + "|" + int(pos.x)
            + "|" + int(pos.z)
            + "|" + (Global::Map::LandLocked ? 1 : 0)
            + "|" + OwnSpotIndex()
            + "|" + ((ai.teamId == ai.GetLeadTeamId()) ? 1 : 0);
    }

    // Returns null when the message is not a roster line of a supported version.
    Entry@ Decode(const string &in msg)
    {
        if (msg.length() < Prefix.length() || msg.substr(0, Prefix.length()) != Prefix) return null;
        array<string>@ parts = msg.split("|");
        if (parts.length() < 12 || int(parseInt(parts[1])) != Version) return null;
        Entry e;
        e.teamId = int(parseInt(parts[2]));
        e.skirmishAIId = int(parseInt(parts[3]));
        e.role = RoleFromName(parts[4]);
        e.side = parts[5];
        e.startFactory = parts[6];
        e.startPos = AIFloat3(float(parseInt(parts[7])), 0.0f, float(parseInt(parts[8])));
        e.landLocked = (parseInt(parts[9]) != 0);
        e.spotIndex = int(parseInt(parts[10]));
        e.isLeader = (parseInt(parts[11]) != 0);
        e.receivedFrame = ai.frame;
        return e;
    }

    // Allied team ids other than our own.
    array<int> AllyTeamIds()
    {
        array<int> result;
        array<Id>@ teams = ai.GetTeamIds();
        if (teams is null) return result;
        for (uint i = 0; i < teams.length(); ++i) {
            if (int(teams[i]) != ai.teamId) result.insertLast(int(teams[i]));
        }
        return result;
    }

    bool IsComplete()
    {
        array<int> allies = AllyTeamIds();
        for (uint i = 0; i < allies.length(); ++i) {
            if (!entries.exists("" + allies[i])) return false;
        }
        return true;
    }

    // Main::AiUpdate (every 30 frames): announce until the roster is complete.
    void Update()
    {
        if (!IsReady()) return;
        if (AllyTeamIds().length() == 0) return;              // no allied BARb to talk to
        if (lastBroadcastFrame >= 0 && IsComplete()) return;  // everyone answered
        if (firstBroadcastFrame >= 0 && (ai.frame - firstBroadcastFrame) >= GiveUpFrames) return;
        if (lastBroadcastFrame >= 0 && (ai.frame - lastBroadcastFrame) < RebroadcastFrames) return;

        AiSendMessage(Encode());
        if (firstBroadcastFrame < 0) {
            firstBroadcastFrame = ai.frame;
            GenericHelpers::LogUtil("[Team][Roster] Announced: " + Encode(), 1);
            WidgetLink::Send("roster", "self|" + Encode());
        }
        lastBroadcastFrame = ai.frame;
    }

    // After a runtime role change: broadcast the new line now and keep announcing
    // until everyone has it again.
    void Reannounce()
    {
        if (!IsReady()) return;
        AiSendMessage(Encode());
        WidgetLink::Send("roster", "self|" + Encode());
        firstBroadcastFrame = ai.frame;
        lastBroadcastFrame = ai.frame;
        GenericHelpers::LogUtil("[Team][Roster] Re-announced: " + Encode(), 1);
    }

    // Main::AiMessage. Returns true when the message was a roster line.
    bool HandleMessage(const string &in msg, int fromTeamId)
    {
        Entry@ e = Decode(msg);
        if (e is null) return false;
        const string key = "" + e.teamId;
        const bool isNew = !entries.exists(key);
        entries.set(key, @e);
        if (isNew && e.teamId != ai.teamId) {
            // D-072: a metal spot belongs to the team whose start is nearest; the
            // ally-aware mex enqueue needs the allies' starts
            aiEconomyMgr.AddAllyStart(e.startPos);
        }
        if (isNew) {
            GenericHelpers::LogUtil("[Team][Roster] Team " + e.teamId + " (AI " + e.skirmishAIId + "): role=" + RoleName(e.role)
                + " side=" + e.side + " start=(" + int(e.startPos.x) + "," + int(e.startPos.z) + ") factory=" + e.startFactory
                + " landLocked=" + (e.landLocked ? "yes" : "no") + " spot=" + e.spotIndex + (e.isLeader ? " leader" : "")
                + " known=" + entries.getSize() + "/" + AllyTeamIds().length(), 1);
            // Answer a newcomer directly so it learns about us without waiting for
            // the next broadcast. An instance that already knew us does not answer
            // again, which terminates the exchange.
            if (IsReady()) AiSendMessage(Encode(), fromTeamId);
            WidgetLink::Send("roster", "ally|" + msg);
        }
        return true;
    }

    /**************************************************************************
     Queries for coordinated planning.
     **************************************************************************/
    Entry@ Get(int teamId)
    {
        Entry@ e = null;
        entries.get("" + teamId, @e);
        return e;
    }

    array<Entry@>@ All()
    {
        array<Entry@> result;
        array<string>@ keys = entries.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            Entry@ e = null;
            if (entries.get(keys[i], @e) && e !is null) result.insertLast(e);
        }
        return result;
    }

    array<Entry@>@ WithRole(AiRole role)
    {
        array<Entry@> result;
        array<Entry@>@ all = All();
        for (uint i = 0; i < all.length(); ++i) {
            if (all[i].role == role) result.insertLast(all[i]);
        }
        return result;
    }

    Entry@ Leader()
    {
        array<Entry@>@ all = All();
        for (uint i = 0; i < all.length(); ++i) {
            if (all[i].isLeader) return all[i];
        }
        return null;
    }

    // Allied start closest to a position (e.g. our own start for "who is next to us").
    Entry@ Nearest(const AIFloat3 &in pos)
    {
        Entry@ best = null;
        float bestDist = 1e30f;
        array<Entry@>@ all = All();
        for (uint i = 0; i < all.length(); ++i) {
            const float d = MapHelpers::SqDist(pos, all[i].startPos);
            if (d < bestDist) { bestDist = d; @best = all[i]; }
        }
        return best;
    }

    int Count() { return int(entries.getSize()); }
}  // namespace Roster
}  // namespace Team
