// Resource amounts are engine units; time is simulation seconds. No role state.
namespace BuildPowerMath {
    bool Valid(float x) { return x >= 0.0f && x < 1.0e12f; }
    float Max(float a, float b) { return a > b ? a : b; }
    float Min(float a, float b) { return a < b ? a : b; }

    // Cost is paid during construction, then the new worker starts its job.
    // Piecewise-linear balance needs testing at both breakpoints, not just end.
    bool Funded(float bank, float reserve, float income, float usage, float committed,
        float cost, float finishSeconds, float additionalUsage, float horizon)
    {
        if (!Valid(bank) || !Valid(reserve) || !Valid(income) || !Valid(usage)
            || !Valid(committed) || !Valid(cost) || !Valid(finishSeconds) || finishSeconds <= 0.0f
            || !Valid(additionalUsage) || !Valid(horizon) || horizon <= 0.0f) return false;
        const float start = bank - reserve - committed;
        if (start < 0.0f) return false;
        const float finish = Min(finishSeconds, horizon);
        const float paid = cost * finish / finishSeconds;
        const float atFinish = start + (income - usage) * finish - paid;
        const float atEnd = atFinish + (income - usage - additionalUsage) * (horizon - finish);
        // If completion lies outside the horizon, reserve the rest of the order.
        return atFinish >= 0.0f && atEnd >= Max(0.0f, cost - paid);
    }
    float Room(float bank, float reserve, float income, float usage, float committed, float horizon)
    {
        if (!Valid(bank) || !Valid(reserve) || !Valid(income) || !Valid(usage)
            || !Valid(committed) || !Valid(horizon) || horizon <= 0.0f) return 0.0f;
        return Max(0.0f, income - usage + Max(0.0f, bank - reserve - committed) / horizon);
    }
    float Power(float metalRate, float energyRate, float work, float costM, float costE)
    {
        if (!Valid(metalRate) || !Valid(energyRate) || !Valid(work) || work <= 0.0f
            || !Valid(costM) || !Valid(costE) || (costM <= 0.0f && costE <= 0.0f)) return 0.0f;
        const float fromM = costM > 0.0f ? metalRate * work / costM : 1.0e10f;
        const float fromE = costE > 0.0f ? energyRate * work / costE : 1.0e10f;
        return Min(fromM, fromE);
    }
    bool Pressure(float bank, float storage, float oldest, int samples, int window,
        int fullSamples, float high, float rise)
    {
        if (!Valid(bank) || !Valid(storage) || storage <= 0.0f || !Valid(oldest)
            || window <= 0 || !Valid(high) || !Valid(rise)) return false;
        return (samples >= window && bank >= oldest + rise)
            || (fullSamples >= window && bank >= storage * high);
    }
    int Batch(float availablePower, float work, float seconds, int pending, int safety)
    {
        if (!Valid(availablePower) || !Valid(work) || work <= 0.0f || !Valid(seconds)
            || seconds <= 0.0f || pending < 0 || safety <= 0) return 0;
        const int capacity = int(Min(float(safety), Max(1.0f, availablePower * seconds / work)));
        return capacity > pending ? capacity - pending : 0;
    }
    bool Refilling(const array<float>& in banks, float storage, float low, float high) {
        if (!Valid(storage) || storage <= 0 || low < 0 || high <= low || high > 1) return false;
        bool dipped = false;
        int refills = 0;
        for (uint i = 0; i < banks.length(); ++i) {
            if (banks[i] <= storage * low) dipped = true;
            if (dipped && banks[i] >= storage * high) { ++refills; dipped = false; }
        }
        return refills >= 2;
    }
    float Shortage(float wanted, float available, float arriving)
    {
        if (!Valid(wanted) || !Valid(available) || !Valid(arriving)) return 0.0f;
        return Max(0.0f, wanted - available - arriving);
    }
    float ProjectShortage(float working, float extra, float remaining, float minimumSeconds,
        float assigned, float queued)
    {
        if (!Valid(working) || !Valid(extra) || !Valid(remaining) || !Valid(minimumSeconds)
            || minimumSeconds <= 0 || !Valid(assigned) || !Valid(queued)) return 0;
        // Assigned includes travellers and workers temporarily limited by energy.
        // They can consume the newly available budget before we buy more power.
        return Max(0.0f, Min(working + extra, remaining / minimumSeconds) - assigned - queued);
    }
}
