// D-175: allocation arithmetic; the caller owns settings, snapshots and sends.
namespace TeamShareMath {
    float Budget(float current, float storage, float threshold, float fraction, bool ready)
    {
        if (!ready || storage <= 0.0f || current <= 0.0f || current < threshold * storage) return 0.0f;
        const float amount = fraction * storage;
        if (amount <= 0.0f) return 0.0f;
        return amount < current ? amount : current;
    }

    float Amount(float freeStorage, float budget, float minimum)
    {
        const float amount = freeStorage < budget ? freeStorage : budget;
        return amount > 0.0f && amount >= minimum ? amount : 0.0f;
    }
}
