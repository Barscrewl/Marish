// Deterministic AIR decisions. No engine state or hidden policy constants.
namespace AirMath {
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
