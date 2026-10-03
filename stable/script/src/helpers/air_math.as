// Deterministic AIR decisions. No engine state or hidden policy constants.
namespace AirMath {
    bool T1OpeningReady(int crew, int requiredCrew, int nanos, int requiredNanos, bool recovering)
    {
        return !recovering && requiredCrew > 0 && requiredNanos >= 0
            && crew >= requiredCrew && nanos >= requiredNanos;
    }
    float RadarSpacing(float radius, float overlap)
    {
        if (!Valid(radius) || radius <= 0 || !Valid(overlap) || overlap >= 1) return 0;
        return 2.0f * radius * (1.0f - overlap);
    }
    bool RadarReady(bool visited, float distanceSq, float radius)
    {
        return visited && Valid(distanceSq) && Valid(radius) && radius > 0 && distanceSq <= 4.0f*radius*radius;
    }
    int RadarColumns(int count, float span, float spacing)
    {
        if (count <= 0 || !Valid(span) || !Valid(spacing) || spacing <= 0) return 0;
        if (span / spacing >= float(count - 1)) return count;
        const int fit = 1 + int(span / spacing);
        return fit < count ? fit : count;
    }
    bool WorkforceTurn(bool missing, bool funded, bool emergency, int combatOrders, int maximum)
    {
        return missing && funded && maximum > 0 && (!emergency || combatOrders >= maximum);
    }
    bool SaveForLab(bool advanced, bool pending, bool recovering, bool screenReady,
        int seconds, int earliest, float metal, float energy, float minimumMetal,
        float minimumEnergy, float bank, float cost)
    {
        return !advanced && !pending && !recovering && screenReady && seconds >= earliest
            && Valid(metal) && Valid(energy) && Valid(bank) && Valid(cost) && cost > 0
            && metal >= minimumMetal && energy >= minimumEnergy && bank < cost;
    }
    bool TransitionStorage(bool advancedPlant, float bank, float capacity, float labCost)
    {
        return !advancedPlant && Valid(bank) && Valid(capacity) && Valid(labCost)
            && capacity>0 && labCost>capacity && bank>capacity*0.85f;
    }
    // Snapshot indexes can change while the same enemy is still alive.
    int RetainedContact(int current, const array<int> &in ids, const array<float> &in remaining)
    {
        if (current < 0 || ids.length() != remaining.length()) return -1;
        for (uint i=0;i<ids.length();++i)
            if (ids[i]==current && Valid(remaining[i]) && remaining[i]>0) return int(i);
        return -1;
    }
    int CampusSize(bool compact, int variant)
    {
        if (!compact || variant < 0) return 6;
        return variant % 3 == 0 ? 6 : variant % 3 == 1 ? 3 : 1;
    }
    int OperationSize(int available, int required, bool openingDone, int opening,
        bool front, bool defensive, int laterMinimum)
    {
        if (available <= 0 || required < 0 || opening <= 0 || laterMinimum <= 0) return 0;
        int count = opening;
        if (defensive) count = required > 3 ? required : 3;
        else if (front) count = available;
        else if (openingDone) count = required > laterMinimum ? required : laterMinimum;
        return count >= required && count <= available ? count : 0;
    }
    bool SustainedProduction(bool ready, float minimumMetal, float minimumEnergy,
        float requiredMetal, float energyPerMetal, float reserveEnergy)
    {
        return ready && Valid(minimumMetal) && Valid(minimumEnergy) && Valid(requiredMetal)
            && requiredMetal > 0 && Valid(energyPerMetal) && energyPerMetal > 0 && Valid(reserveEnergy)
            && minimumMetal >= requiredMetal && minimumEnergy >= requiredMetal*energyPerMetal+reserveEnergy;
    }
    bool PendingReactor(bool reactor, bool construction, bool hasTarget, float progress)
    {
        return reactor && construction && (!hasTarget || (Valid(progress) && progress < 1.0f));
    }
    // Conservative admission for a single additional reactor after the bomber
    // milestone: leave the configured share of future income to production.
    bool OverflowGrowth(bool floatingMetal, bool recovering, bool pendingReactor, float bankM, float bankE,
        float incomeM, float incomeE, float committedM, float committedE, float costM, float costE,
        float productionShare, float seconds)
    {
        if (!floatingMetal || recovering || pendingReactor || !Valid(bankM) || !Valid(bankE)
            || !Valid(incomeM) || !Valid(incomeE) || !Valid(committedM) || !Valid(committedE)
            || !Valid(costM) || costM <= 0.0f || !Valid(costE) || costE <= 0.0f
            || !Valid(productionShare) || productionShare > 1.0f || !Valid(seconds)) return false;
        const float share = 1.0f - productionShare;
        return bankM + incomeM * share * seconds >= committedM + costM + 150.0f
            && bankE + incomeE * share * seconds >= committedE + costE + 500.0f;
    }
    bool BayAllowed(int count, int ceiling) { return count >= 0 && (ceiling <= 0 || count < ceiling); }
    int PlannedBays(int completed, int minimum) {
        if (completed < 0) completed = 0;
        if (completed >= 2147483646) return 2147483647;
        return completed + 1 > minimum ? completed + 1 : minimum;
    }
    float BayPitch(float halfEnvelope, float gap) {
        return 2.0f * halfEnvelope + (gap > 0.0f ? gap : 0.0f);
    }
    bool GrowthPhase(bool windowReady, float minimumIncome, float threshold) {
        return windowReady && Valid(minimumIncome) && threshold > 0.0f && minimumIncome >= threshold;
    }
    bool MassBombersReady(int completedAfus, int required) { return required <= 0 || completedAfus >= required; }
    bool EnergyEraAllows(bool basicEnergy, bool advancedSolar, bool fusionUp, bool afusStarted) {
        if (basicEnergy) return !fusionUp && !afusStarted;
        if (advancedSolar) return !afusStarted;
        return true;
    }
    int OpeningWave(int low, int high, int roll) {
        if (low < 1) low = 1;
        if (high < low) high = low;
        if (high > 300) high = 300;
        if (low > high) low = high;
        return roll < low ? low : roll > high ? high : roll;
    }

    bool Valid(float value) { return value == value && value >= 0.0f && value < 1.0e12f; }
    float RaidResistance(float previous, float survival, float low, float high, float growth, float recovery, float ceiling)
    {
        if (!Valid(previous) || !Valid(survival) || !Valid(ceiling) || ceiling < 1.0f) return 1.0f;
        float factor = Clamp(previous, 1.0f, ceiling);
        if (survival < low && Valid(growth) && growth > 1.0f) factor *= growth;
        else if (survival > high && Valid(recovery)) factor *= Clamp(recovery, 0.0f, 1.0f);
        return Clamp(factor, 1.0f, ceiling);
    }
    float Clamp(float value, float lo, float hi) { return value < lo ? lo : value > hi ? hi : value; }
    int Missing(float required, float available, float unitCost)
    {
        if (!Valid(required) || !Valid(available) || !Valid(unitCost) || unitCost <= 0.0f) return 0;
        const float need = (required - available) / unitCost;
        if (need <= 0.0f) return 0;
        if (need >= 2147483520.0f) return 2147483647;
        const int whole = int(need);
        return whole + (float(whole) < need ? 1 : 0);
    }
    bool Emergency(float armedIntrusion, float homeValue, float ratio)
    {
        return Valid(armedIntrusion) && armedIntrusion > 0.0f && Valid(homeValue)
            && Valid(ratio) && armedIntrusion * ratio > homeValue;
    }
    // Order allocation, not a claim that unequal aircraft have equal costs.
    int BomberOrders(float homeValue, float enemyValue, int clearOrders, int parityOrders)
    {
        if (!Valid(homeValue) || !Valid(enemyValue) || homeValue <= 0.0f) return 0;
        if (enemyValue > homeValue) return 0;
        const float ratio = Clamp(enemyValue / homeValue, 0.0f, 1.0f);
        return int(Clamp(float(clearOrders) + float(parityOrders - clearOrders) * ratio, 0.0f, 9.0f));
    }
    bool BomberTurn(int sequence, int orders)
    {
        if (sequence < 0 || orders <= 0 || orders > 10) return false;
        const int slot = sequence % 10;
        return ((slot + 1) * orders / 10) > (slot * orders / 10);
    }
    int WaveTarget(int wave, int first, int increment, int cap, int held,
        float seconds, float rawRate, float metal, float energy, float costM, float costE)
    {
        if (wave < 0 || first <= 0 || increment < 0 || cap < first || held < 0 || !Valid(seconds)
            || !Valid(rawRate) || !Valid(metal) || !Valid(energy) || !Valid(costM) || costM <= 0.0f
            || !Valid(costE) || costE <= 0.0f) return first > 0 ? first : 1;
        float rate = rawRate;
        if (rate > metal / costM) rate = metal / costM;
        if (rate > energy / costE) rate = energy / costE;
        // Bound the float result before conversion; extreme valid configuration
        // must not overflow the schedule or a rate-times-duration integer cast.
        const float scheduled = float(first) + float(wave) * float(increment);
        const float reachable = float(held) + rate * seconds;
        const float target = scheduled < reachable ? scheduled : reachable;
        if (target <= float(first)) return first;
        if (target >= float(cap)) return cap;
        return int(target);
    }
    bool LaunchDue(int held, int target, int minimum, int age, int cadence, bool escortReady, bool active)
    {
        return !active && escortReady && minimum > 0 && target >= minimum && held >= minimum
            && (held >= target || (cadence > 0 && age >= cadence));
    }
    int SortieSize(int held, int scheduled, int minimum, int escorts, float ratio)
    {
        if (held < minimum || minimum <= 0 || scheduled < minimum || escorts < 0 || !Valid(ratio)) return 0;
        int count = held < scheduled ? held : scheduled;
        if (ratio > 0.0f) {
            const float supported = float(escorts) / ratio;
            if (supported < float(count)) count = int(supported);
        }
        return count >= minimum ? count : 0;
    }
}
