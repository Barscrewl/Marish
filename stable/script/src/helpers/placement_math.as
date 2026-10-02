// Pure placement geometry, shared by policy and the standalone AS tests.
namespace PlacementMath {
    bool FriendlyTerritory(float allyDistanceSquared, float enemyDistanceSquared)
    {
        return allyDistanceSquared >= 0.0f && enemyDistanceSquared >= 0.0f
            && allyDistanceSquared < enemyDistanceSquared;
    }
    bool CoversCore(float coverage, float distanceSquared, float coreRadius)
    {
        return coverage > 0.0f && coreRadius >= 0.0f && coverage >= coreRadius
            && distanceSquared >= 0.0f && distanceSquared <= (coverage - coreRadius) * (coverage - coreRadius);
    }
    bool FootprintIntersectsCircle(float x, float z, float halfX, float halfZ,
        float centreX, float centreZ, float radius)
    {
        if (halfX < 0.0f || halfZ < 0.0f || radius < 0.0f) return true;
        float dx = x - centreX;
        float dz = z - centreZ;
        if (dx < 0.0f) dx = -dx;
        if (dz < 0.0f) dz = -dz;
        dx = dx > halfX ? dx - halfX : 0.0f;
        dz = dz > halfZ ? dz - halfZ : 0.0f;
        return dx * dx + dz * dz <= radius * radius;
    }
}
