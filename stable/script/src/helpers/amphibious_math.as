// Pure wave policy, shared by the runtime controller and standalone tests.
namespace AmphibiousMath {
    int FormationLane(int index) {
        if (index<=0) return 0;
        return index%2==1 ? (index+1)/2 : -index/2;
    }
    bool Scope(bool tech, bool air, bool experimental) { return experimental && (tech || air); }
    bool Gathered(int alive, int arrived, float fraction) {
        return alive > 0 && arrived > 0 && float(arrived) >= float(alive) * fraction;
    }
    bool Release(int alive, int arrived, int target, int minimum, int age, int timeout, float fraction) {
        return alive >= minimum && (alive >= target || age >= timeout) && Gathered(alive, arrived, fraction);
    }
    bool Secured(int alive, int arrived, float fraction, bool contact, int quietFrames, int requiredFrames) {
        return !contact && quietFrames >= requiredFrames && Gathered(alive, arrived, fraction);
    }
    bool Landing(bool crossedWater, float height) { return crossedWater && height >= 0.0f; }
    bool MayAdvance(bool assembling, bool secured) { return assembling || secured; }
    float TargetScore(bool raider, bool economy, float cost, float distance, float threat) {
        return (raider && economy ? 4.0f : 1.0f) * cost / (1.0f + distance / 800.0f + threat);
    }
    bool RecruitReady(float minimumIncome, float gate, int stableFrames, int windowFrames,
        float bankM, float costM, float reserveM, float bankE, float energyBuffer, bool energyStalling) {
        return minimumIncome >= gate && stableFrames >= windowFrames && costM > 0.0f
            && bankM >= costM + reserveM && bankE >= energyBuffer && !energyStalling;
    }
    float RecruitSeconds(float costM, float costE, float incomeM, float incomeE, float shareM, float shareE) {
        if (costM <= 0 || costE < 0 || incomeM <= 0 || incomeE <= 0 || shareM <= 0 || shareE <= 0) return -1.0f;
        const float metalSeconds = costM / (incomeM * shareM), energySeconds = costE / (incomeE * shareE);
        return metalSeconds > energySeconds ? metalSeconds : energySeconds;
    }
    int GuardAllocation(int alive, int desired, int assaultMinimum, int groups, int maximum) {
        if (groups >= maximum || alive < desired + assaultMinimum || desired <= 0 || assaultMinimum <= 0) return 0;
        return desired;
    }
    float BeachScore(float assets, float navalDistance, float travel, float threat) {
        if (assets <= 0 || threat < 0) return 0.0f;
        const float naval = navalDistance < 1000.0f ? 2.0f : 1.0f;
        return naval * assets / (1.0f + travel / 2400.0f + threat);
    }
    bool GuardRelease(bool assets, int absentFrames, int graceFrames, bool claimLost) {
        return claimLost || (!assets && absentFrames >= graceFrames);
    }
    bool ClaimPrecedes(int team, int serial, int ownTeam, int ownSerial) {
        return team < ownTeam || (team == ownTeam && serial < ownSerial);
    }
}
