// Pure, role-neutral arithmetic. No engine calls, settings or mutable state.
namespace ProductionMath {
    // Shared TECH/AIR threshold; callers require a completed reactor and no stall.
    bool LowTierEnergyReclaim(bool completedAfus, float income, float retiringOutput, float pull, float margin)
    {
        return completedAfus || income - retiringOutput >= pull * margin;
    }
    bool StrikeReady(float homeValue, float enemyAirValue, bool intrusion, float ratio)
    {
        return !intrusion && Valid(homeValue) && homeValue > 0.0f && Valid(enemyAirValue)
            && Valid(ratio) && ratio > 0.0f && homeValue >= enemyAirValue * ratio;
    }
    bool ConstructorTurn(int consecutive, int maximum)
    {
        return consecutive >= 0 && maximum > 0 && consecutive < maximum;
    }
    bool ConstructorFunded(float bankM, float bankE, float incomeM, float incomeE, float costM, float costE)
    {
        return Valid(costM) && costM > 0.0f && bankM >= costM * 0.5f
            && Funded(bankM, incomeM * 0.35f, 100.0f, 0.0f, costM, 30.0f)
            && Funded(bankE, incomeE * 0.3f, 200.0f, 0.0f, costE, 30.0f);
    }
    bool AssistUseful(float assigned, float work, float progress, float seconds)
    {
        if (!Valid(assigned) || !Valid(work) || !Valid(progress) || progress >= 1.0f
            || !Valid(seconds) || seconds <= 0.0f) return false;
        return assigned < work * (1.0f - progress) / seconds;
    }
    bool ExpansionSupportReady(int factories, int finishedFactories, int leastSupport, int required)
    {
        if (factories < 0 || finishedFactories < 0 || leastSupport < 0 || required <= 0) return false;
        return factories == finishedFactories && (factories == 0 || leastSupport >= required);
    }
    bool MetalFloating(float bank, float storage)
    {
        return Valid(bank) && Valid(storage) && storage > 0.0f
            && bank >= (storage * 0.75f > 300.0f ? storage * 0.75f : 300.0f);
    }
    float ConstructionPower(float income, float bank, float storage, float perMetal, float floatFactor, float drainSeconds)
    {
        if (!Valid(income) || !Valid(bank) || !Valid(storage) || !Valid(perMetal)
            || !Valid(floatFactor) || !Valid(drainSeconds) || drainSeconds <= 0.0f) return 0.0f;
        const bool floating = MetalFloating(bank, storage);
        const float draw = floating && bank > storage * 0.5f ? (bank - storage * 0.5f) / drainSeconds : 0.0f;
        return (income + draw) * perMetal * (floating ? floatFactor : 1.0f);
    }
    bool SupportQueueReady(int pending, int parallel, float bankM, float bankE, float incomeM, float incomeE, float costM, float costE)
    {
        if (pending < 0 || parallel <= 0 || pending >= parallel || !Valid(costM) || !Valid(costE)) return false;
        return Funded(bankM, incomeM * 0.5f, 150.0f, float(pending) * costM, costM, 20.0f)
            && Funded(bankE, incomeE * 0.25f, 300.0f, float(pending) * costE, costE, 20.0f);
    }
    bool LabIncomeReady(float minimum, bool fullWindow, float threshold, float bank, float cost)
    {
        if (!Valid(minimum) || !Valid(threshold) || !Valid(bank) || !Valid(cost) || cost <= 0.0f || threshold <= 0.0f) return false;
        return bank >= cost || (fullWindow && minimum >= threshold);
    }
    int StrikeTarget(float income, float perUnit, int floor, int cap)
    {
        if (!Valid(income) || !Valid(perUnit) || perUnit <= 0.0f || floor < 0 || cap < floor) return 0;
        const int value = int(income / perUnit);
        return value < floor ? floor : value > cap ? cap : value;
    }
    // Conversion capacity follows surplus, not a fixed metal-income ceiling.
    int ConverterTarget(float income, float aircraft, float reserve, float draw)
    {
        if (!Valid(income) || !Valid(aircraft) || !Valid(reserve) || !Valid(draw)
            || draw <= 0.0f || income <= aircraft + reserve) return 0;
        const float value = (income - aircraft - reserve) / draw;
        const int whole = int(value);
        return whole + (value > float(whole) ? 1 : 0);
    }
    bool ConverterMayQueue(int target, int planned, int queued, int parallel)
    {
        return planned >= 0 && target > planned && queued >= 0 && queued < parallel;
    }

    float Progress(int count, int first, int full)
    {
        if (count <= first || first < 0 || full <= first) return 0.0f;
        return count >= full ? 1.0f : float(count - first) / float(full - first);
    }
    float BoundedBlend(float first, float last, float progress)
    {
        if (!Valid(first) || !Valid(last) || !Valid(progress)) return 0.0f;
        return first + (last - first) * (progress > 1.0f ? 1.0f : progress);
    }
    bool WithinReach(float distanceSquared, float reach, float margin = 16.0f)
    {
        return Valid(distanceSquared) && Valid(reach) && Valid(margin) && reach >= margin
            && distanceSquared <= (reach - margin) * (reach - margin);
    }
    // Projected counts suppress duplicate orders; only completed units release an assistant.
    bool CrewReady(int completed, int target) { return target > 0 && completed >= target; }
    bool FactoryAssistUseful(bool crewReady, bool factoryFinished, bool recruiting)
    {
        return !crewReady || !factoryFinished || recruiting;
    }
    int DefenceRecruitTarget(int target, int otherDefenders, int committedElsewhere)
    {
        if (target < 0 || otherDefenders < 0 || committedElsewhere < 0) return 0;
        return (target > otherDefenders ? target - otherDefenders : 0) + committedElsewhere;
    }
    int WorkforceTarget(float targetWork, float unitWork, int floor, int cap)
    {
        if (!Valid(targetWork) || !Valid(unitWork) || unitWork <= 0.0f || floor < 0 || cap < floor) return 0;
        for (int n = floor; n < cap; ++n)
            if (float(n) * unitWork >= targetWork) return n;
        return cap;
    }
    float ClusterAcross(int slot, float width) { return float(slot % 3 - 1) * width; }
    float ClusterAlong(int slot, float depth) { return (float(slot / 3) - 0.5f) * depth; }
    float ClusterDiameterSquared(float width, float depth) { return 9.0f * width * width + 4.0f * depth * depth; }
    bool MexNeedsUpgrade(float extraction, float advancedExtraction)
    {
        return Valid(extraction) && extraction > 0.0f
            && (!Valid(advancedExtraction) || advancedExtraction <= 0.0f || extraction < advancedExtraction);
    }
    bool ReactorMayStart(int basicMexes, int unfinishedMexes, int queuedMexes)
    {
        return basicMexes == 0 && unfinishedMexes == 0 && queuedMexes == 0;
    }
    bool PreparationDue(int seconds, int targetSeconds, int leadSeconds)
    {
        return seconds >= 0 && targetSeconds > 0 && leadSeconds >= 0 && seconds >= targetSeconds - leadSeconds;
    }
    bool Valid(float value) { return value >= 0.0f && value < 1.0e12f; }
    float Rate(float work, float power, float warmGap)
    {
        if (!Valid(work) || work <= 0.0f || !Valid(power) || power <= 0.0f || !Valid(warmGap)) return 0.0f;
        return power / (work + warmGap * power);
    }
    float FundedRate(float rate, float metalCost, float energyCost, float metal, float energy)
    {
        if (!Valid(rate) || !Valid(metal) || !Valid(energy) || !Valid(metalCost) || !Valid(energyCost)) return 0.0f;
        if (metalCost > 0.0f && rate * metalCost > metal) rate = metal / metalCost;
        if (energyCost > 0.0f && rate * energyCost > energy) rate = energy / energyCost;
        return rate;
    }
    // Costs and work are totals over a count-weighted batch, not averaged rates.
    float BatchRate(float work, float power, float warmGap, int count)
    {
        if (count <= 0) return 0.0f;
        return Rate(work, power, warmGap * float(count));
    }
    bool Funded(float bank, float income, float reserve, float committed, float cost, float seconds)
    {
        if (!Valid(bank) || !Valid(income) || !Valid(reserve) || !Valid(committed) || !Valid(cost) || !Valid(seconds)) return false;
        return bank + income * seconds >= reserve + committed + cost;
    }
    // Smallest usable support allocation; pending support is future capacity.
    int SupportTarget(float work, float factoryPower, float nanoPower, float gap, float wantedRate, int cap)
    {
        if (!Valid(work) || work <= 0.0f || !Valid(factoryPower) || !Valid(nanoPower) || !Valid(gap)
            || !Valid(wantedRate) || wantedRate <= 0.0f || nanoPower <= 0.0f || cap <= 0) return 0;
        for (int n = 0; n < cap; ++n)
            if (Rate(work, factoryPower + float(n) * nanoPower, gap) >= wantedRate) return n;
        return cap;
    }
    // Two five-wide banks, two rows deep. No turret lies in the aircraft pad.
    float BayAcross(int slot, float factoryHalf, float nanoWidth, float gap)
    {
        const int bank = slot / 10;
        const int row = (slot % 10) / 5;
        return (bank == 0 ? -1.0f : 1.0f) * (factoryHalf + gap + nanoWidth * (0.5f + float(row)));
    }
    float BayAlong(int slot, float nanoWidth) { return float((slot % 10) % 5 - 2) * nanoWidth; }
    bool Inside(float x, float z, float width, float height, float margin)
    {
        return Valid(x) && Valid(z) && Valid(width) && Valid(height) && Valid(margin)
            && x < width && z < height
            && x >= margin && z >= margin && x <= width - margin && z <= height - margin;
    }
    bool CapacityReady(int count, int ceiling, int stableFrames, int requiredFrames, float bank, float cost)
    {
        return count >= 0 && count < ceiling && stableFrames >= requiredFrames && requiredFrames >= 0
            && Valid(bank) && Valid(cost) && bank >= cost;
    }
}
