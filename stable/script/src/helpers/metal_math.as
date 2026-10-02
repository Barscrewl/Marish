// Pure metal-field investment arithmetic; inputs are runtime costs/income.
namespace MetalMath {
    float Positive(float value) { return value > 0.0f ? value : 0.0f; }
    float Sustainable(float metal, float energy, float otherEnergy, float ratio) {
        if (ratio <= 0.0f) return 0.0f;
        const float funded = Positive(energy - otherEnergy) / ratio;
        return metal < funded ? Positive(metal) : funded;
    }
    float EnergyGoal(float desiredMetal, float ratio, float upkeep, float pull, float margin) {
        const float desired = Positive(desiredMetal) * Positive(ratio) + Positive(upkeep);
        const float busy = Positive(pull) * (1.0f + Positive(margin));
        return desired > busy ? desired : busy;
    }
    bool OpeningDone(int claimed, int budget, int seconds, int deadline) {
        return claimed >= budget || seconds >= deadline;
    }
    bool NeedMex(float metal, float energy, float ratio, float bank, float storage, float pull) {
        if (ratio <= 0 || storage <= 0 || bank >= storage * .75f) return false;
        return metal < Positive(energy - 30.0f) / ratio * 1.25f
            || (bank < storage * .2f && pull > metal * 1.05f);
    }
    bool CanInvest(float metal, float energy, float bankM, float bankE, float costM, float costE, float horizon) {
        return horizon > 0 && costM > 0 && costE >= 0
            && bankM + Positive(metal) * horizon * .35f >= costM
            && bankE + Positive(energy) * horizon * .35f >= costE;
    }
    bool NeedInvestmentStorage(float bank, float storage, float nextCost) {
        return storage > 0 && nextCost > storage && bank >= storage * .9f;
    }
    bool RetirePower(float income, float removed, float committedPull, float target, float reserve) {
        const float need = committedPull > target ? committedPull : target;
        return removed > 0 && income - removed >= need * (1.0f + Positive(reserve));
    }
}
