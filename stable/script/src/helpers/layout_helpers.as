// Base layout policy entry point and facing selection. Canonical footprint,
// orientation and slot geometry lives in native BaseLayoutGeometry.h.
#include "../define.as"
#include "../global.as"
#include "../types/role_config.as"
#include "generic_helpers.as"

/******************************************************************************

LAYOUT HELPERS

A role's plan is a handful of reservations pushed at setup, before the first
factory is placed (Setup runs from AiGetFactoryToBuild, the same frame the
native chooser picks the start factory). Native holds the ground
(aiTerrainMgr.ReserveBuilding / ReserveGrid) and serves each site back to the
first construction of that def; everything else is placed around it
(D-043). The helpers below only do the geometry: a facing, its forward and
side unit vectors, offsets in elmos, and footprint extents.

Facing is the engine's: SOUTH 0 = +z, EAST 1 = +x, NORTH 2 = -z, WEST 3 = -x.
A factory's exit is on its facing side. Native's ReserveGrid uses the same
side vectors as Side() here, so a grid and an offset agree on left and right.

******************************************************************************/
namespace LayoutHelpers {

    const int FACING_SOUTH = 0;
    const int FACING_EAST = 1;
    const int FACING_NORTH = 2;
    const int FACING_WEST = 3;
    // The facing whose forward points most nearly from `from` to `to`.
    int FacingToward(const AIFloat3& in from, const AIFloat3& in to)
    {
        const float dx = to.x - from.x;
        const float dz = to.z - from.z;
        const float ax = (dx < 0.0f) ? -dx : dx;
        const float az = (dz < 0.0f) ? -dz : dz;
        if (ax > az) return (dx > 0.0f) ? FACING_EAST : FACING_WEST;
        return (dz > 0.0f) ? FACING_SOUTH : FACING_NORTH;
    }

    AIFloat3 TerrainCentre()
    {
        return AIFloat3(float(AiTerrainWidth()) * 0.5f, 0.0f, float(AiTerrainHeight()) * 0.5f);
    }

    // Setup: run the role's plan once, after its caps and porc chain are in.
    void ApplyForRole()
    {
        RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
        if (cfg is null || cfg.LayoutPlanHandler is null) {
            GenericHelpers::LogUtil("[Layout] no plan for this role; placement is the native spiral", 2);
            return;
        }
        if (!Global::Map::HasStart) {
            GenericHelpers::LogUtil("[Layout] start position unknown at setup; no plan pushed", 1);
            return;
        }
        cfg.LayoutPlanHandler(Global::AISettings::Side);
    }
}
