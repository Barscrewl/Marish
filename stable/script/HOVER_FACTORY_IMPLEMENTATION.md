# Hover Factory Production System

## Overview
Comprehensive hover factory support for all three factions (Armada, Cortex, Legion) using the dynamic factory production system. This extends the threat-driven, role-based unit selection to hover plants (both land-based and floating variants).

## Implementation Date
2025-01-XX (replace with actual date)

## Scope
- **6 Hover Factories**: armhp, armfhp, corhp, corfhp, leghp, legfhp
- **5 Roles per Factory**: builder, scout, raider, assault, support
- **4 Economic Tiers**: Same as SEA factories (20, 40, 80, 999999 metal income)
- **Threat Response**: Adaptive unit selection based on enemy composition

## Architecture

### Code Organization
```
manager/
  factory_production.as          # Core system (tier logic, threat weighting, batch reuse)
  factory_production/
    factory_configs_sea.as        # SEA factory configs (armsy, corsy, legsy)
    factory_configs_hover.as      # HOVER factory configs (6 hover plants)
```

### Modular Design
- **Separation of Concerns**: Factory configs isolated from core production logic
- **Namespace Organization**: `FactoryProduction::SeaConfigs` and `FactoryProduction::HoverConfigs`
- **Include Strategy**: Config files included at end of factory_production.as to avoid circular dependencies

## Factory Configurations

### Armada Hover Factories

#### armhp (Land Hover Plant)
- **Units**:
  - builder: armch (Hover Constructor)
  - scout: armsh (Hover Scout)
  - raider: armthovr (T1 Hover Tank), armanac (Anaconda Hover Raider)
  - assault: armmh (Medium Hover Tank)
  - support: armah (Advanced Hover)
- **Tier Probabilities** (builder, scout, raider, assault, support):
  - Tier 0 (< 20 metal): 15%, 30%, 40%, 10%, 5%
  - Tier 1 (20-40): 10%, 20%, 35%, 25%, 10%
  - Tier 2 (40-80): 8%, 15%, 30%, 35%, 12%
  - Tier 3 (80+): 5%, 10%, 25%, 45%, 15%

#### armfhp (Floating Hover Plant)
- **Units**: Identical to armhp (hovercrafts work on land and water)
- **Tier Probabilities**: Identical to armhp

### Cortex Hover Factories

#### corhp (Land Hover Plant)
- **Units**:
  - builder: corch (Hover Constructor)
  - scout: corsh (Hover Scout)
  - raider: corthovr (T1 Hover Tank), corsnap (Snapper Hover Raider)
  - assault: cormh (Medium Hover), corah (Advanced Hover), corhal (Halberd)
  - support: corah (Advanced Hover)
- **Tier Probabilities**: Same distribution as Armada

#### corfhp (Floating Hover Plant)
- **Units**: Identical to corhp
- **Tier Probabilities**: Identical to corhp

### Legion Hover Factories

#### leghp (Land Hover Plant)
- **Units**:
  - builder: legch (Hover Constructor)
  - scout: legsh (Hover Scout)
  - raider: legner (Nereid Hover Raider)
  - assault: legmh (Medium Hover), legah (Advanced Hover), legcar (Carrus Heavy Hover)
  - support: legah (Advanced Hover)
- **Tier Probabilities**: Same distribution as Armada/Cortex

#### legfhp (Floating Hover Plant)
- **Units**: Identical to leghp
- **Tier Probabilities**: Identical to leghp

## Integration with HOVER_SEA Role

### Global Toggle
```angelscript
Global::RoleSettings::HoverSea::UseDynamicFactoryProduction = true; // default
```

### Initialization (HoverSea_Init)
```angelscript
if (Global::RoleSettings::HoverSea::UseDynamicFactoryProduction) {
    FactoryProduction::Initialize();
    GenericHelpers::LogUtil("[HOVER_SEA] Dynamic factory production system initialized", 2);
}
```

### Factory Production (HoverSea_FactoryAiMakeTask)
1. **Constructor Guarantee**: Always ensure minimum hover constructor count first
2. **Dynamic Production**: Call `FactoryProduction::MakeTask(u)` for hover plants
3. **Fallback Logic**: Use `DefaultMakeTask` if dynamic system returns null
4. **T2 Vehicle Support**: Preserve existing T2 vehicle constructor logic

### Constructor Guarantee Logic
```angelscript
if (haveHoverCtors < Global::RoleSettings::HoverSea::MinHoverConstructorCount) {
    // Build hover constructor with HIGH priority
    return TaskS::Recruit(BUILDPOWER, HIGH, ctorDef, pos, 64.f);
}
```

## Production Flow (Hover Factories)

### Decision Chain
1. **Factory Query**: Is this a hover plant? (T1 land or floating)
2. **Constructor Check**: Do we have minimum hover constructors?
3. **Dynamic Selection**: Call `FactoryProduction::MakeTask()`
   - Priority queue check (existing tasks)
   - Economic tier calculation (metal income)
   - Role probability selection (threat-weighted)
   - Unit selection within role
   - Batch reuse (repeat 3x before reroll)
4. **Fallback**: `DefaultMakeTask` if all else fails

### Threat Weighting Example
```
Scenario: Enemy has heavy air presence
- Base assault probability: 0.35
- Enemy air threat: 500 power (40% of total threat)
- Boost: 1.0 + (0.8 * 0.4) = 1.32
- Weighted assault probability: 0.35 * 1.32 = 0.462
Result: More assault units built to counter air threat
```

## Backward Compatibility

### SEA Role Preservation
- Sea.as continues to function identically
- SEA factory configs unchanged (armsy, corsy, legsy)
- No modifications to SEA role logic
- Both SEA and HOVER_SEA can use dynamic production simultaneously

### Legacy Fallback
- Toggle can be disabled: `UseDynamicFactoryProduction = false`
- Falls back to `DefaultMakeTask` (factory.json logic)
- Constructor guarantees always enforced regardless of toggle

## Differences from JSON Configuration

### Removed Features
- **Importance Weights**: No longer used (all factories treated equally by role)
- **require_energy**: Not implemented (economic tiers are metal-only)
- **Environment-Specific Probabilities**: Single probability array per tier (no land/air/water split)
- **Caretaker Counts**: Nano management is builder role logic, not factory config

### Enhanced Features
- **Threat Response**: Dynamic adaptation to enemy composition
- **Batch Production**: Repeat units 3x before reroll for consistency
- **On-Demand Role Queries**: GetUnitsWithRole() supports runtime role discovery
- **Extensibility**: Easy to add new factories or roles

## Configuration Values (Global Settings)

### HOVER_SEA Role Settings
```angelscript
// Constructor policy
int MinHoverConstructorCount = 10; // Minimum hover constructors to maintain

// Hover plant expansion (income-scaled)
float MetalIncomePerExtraHoverPlant = 50.0f; // +1 plant per 50 metal income
int MaxHoverPlants = 3; // Maximum total hover plants (land + floating)

// Dynamic production toggle
bool UseDynamicFactoryProduction = true; // Enable threat-driven production
```

## Testing Checklist

### Functional Tests
- [x] Hover factories registered in FactoryProduction system
- [x] HoverSea_Init calls FactoryProduction::Initialize() when enabled
- [x] HoverSea_FactoryAiMakeTask calls MakeTask() for hover plants
- [x] Constructor guarantee enforced before dynamic production
- [x] Toggle disables dynamic system correctly
- [ ] Test on hover-friendly map (e.g., Coast to Coast, Canis River)
- [ ] Verify all 6 hover factories produce units
- [ ] Confirm threat weighting adjusts production
- [ ] Test Legion hover factories (leghp, legfhp)

### Compatibility Tests
- [ ] Verify sea.as continues to work (sea maps)
- [ ] Test both SEA and HOVER_SEA roles in same game (multi-AI)
- [ ] Confirm no namespace collisions
- [ ] Check logging output for both roles

### Performance Tests
- [ ] Monitor frame time impact of hover factory production
- [ ] Verify no crashes during initialization
- [ ] Confirm batch reuse reduces decision overhead

## Known Limitations

### Current Implementation
1. **Single Tier Array**: No environment-specific probabilities (land/air/water)
2. **No Factory Importance**: All factories treated equally by production system
3. **Metal-Only Tiers**: Energy income not considered for tier calculation
4. **No Response Logic**: Counter-unit logic from response.json not yet implemented

### Future Enhancements
1. **Response System**: Implement counter-unit logic (e.g., anti_air vs bomber)
2. **Factory Priority**: Add importance weights for factory selection
3. **Environment Awareness**: Use terrain analysis for land/water probability adjustments
4. **Energy Gating**: Consider energy income for high-tier unit production
5. **T2 Hover Support**: Add advanced hover units when T2 hover tech implemented

## Files Modified

### New Files
- `manager/factory_production/factory_configs_sea.as` (extracted from main file)
- `manager/factory_production/factory_configs_hover.as` (new hover configs)

### Modified Files
- `manager/factory_production.as` (modular registration, includes)
- `roles/hover_sea.as` (Initialize + MakeTask integration)
- `global.as` (added `UseDynamicFactoryProduction` toggle for HoverSea)

### Unchanged Files
- `roles/sea.as` (SEA role continues to work identically)
- All JSON configuration files (preserved for legacy/reference)

## Migration Notes

### JSON to AngelScript Mapping
- **factory.json hover configs** → `factory_configs_hover.as::RegisterHoverFactories()`
- **factory_leg.json hover configs** → Legion section in `factory_configs_hover.as`
- **Unit arrays** → `cfg.AddRole()` calls
- **Tier probabilities** → `cfg.SetTierProbabilities()` calls

### JSON Config Reference
Original factory.json entries for hover factories:
- armhp: importance=[0.2, 0.1], 4 income tiers, 6 units
- corhp: importance=[0.2, 0.1], 4 income tiers, 7 units
- armfhp/corfhp: Similar to land versions
- leghp/legfhp: importance=[0.1, 0.0], 4 income tiers, 6 units each

## Logging

### Initialization Logs
```
[FactoryProduction] RegisterHoverFactories: Starting registration
[FactoryProduction] RegisterHoverFactories: Registering armhp
[FactoryProduction] RegisterHoverFactories: armhp registered
... (repeated for all 6 factories)
[FactoryProduction] RegisterHoverFactories: Registered 6 HOVER factory configs
[HOVER_SEA] Dynamic factory production system initialized
```

### Production Logs
```
[FactoryProduction] MakeTask: Factory 'armhp' requesting task
[FactoryProduction] Economic tier: 1 (metal income: 32.4)
[FactoryProduction] Selected role 'raider' (index 2, prob: 0.35)
[FactoryProduction] Factory 'armhp' building 'armthovr' (role: raider, tier: 1, cost: 150)
```

## Summary
Comprehensive hover factory support implemented with:
- **6 factories** across 3 factions (2 per faction: land + floating)
- **5 roles** per factory (builder, scout, raider, assault, support)
- **Modular architecture** for scalability
- **Threat-driven production** matching SEA system
- **Backward compatibility** with existing SEA role
- **Toggle support** for legacy fallback

The system is complete, organized, and ready for testing on hover-friendly maps.
