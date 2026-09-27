# Dynamic Factory Production System

## Overview

The dynamic factory production system replaces static `factory.json` and `response.json` configuration with scriptable, threat-driven unit selection logic. It adapts production based on:

- **Economic tier**: Metal income determines which unit role probabilities to use
- **Enemy threat**: Boosts probabilities for roles that counter detected enemy composition
- **Batch production**: Repeats the same unit several times for efficiency
- **Priority queue**: Allows external systems to inject urgent build requests

## Architecture

### Core Components

1. **`manager/factory_production.as`**: Main production logic
   - Role probability tables per factory and tier
   - Threat-weighted role selection
   - Unit filtering and scoring
   - Batch reuse logic

2. **`global.as`**: Configuration toggle
   - `Global::RoleSettings::Sea::UseDynamicFactoryProduction` (default: `true`)

3. **`roles/sea.as`**: Integration point
   - Initializes system in `Sea_Init()`
   - Calls `FactoryProduction::MakeTask()` in `Sea_FactoryAiMakeTask()`
   - Falls back to legacy logic if dynamic system returns null

### Data Flow

```
Sea_FactoryAiMakeTask(factory)
  ↓
  1. Constructor guarantee (< 2 constructors)
  ↓
  2. FactoryProduction::MakeTask(factory)
      ↓
      a. Check priority queue
      ↓
      b. Get factory config by name
      ↓
      c. Determine economic tier from metal income
      ↓
      d. Apply threat weighting to role probabilities
      ↓
      e. Pick role via weighted dice roll
      ↓
      f. Get available units for role
      ↓
      g. Try batch reuse (repeat last 3x)
      ↓
      h. Pick cheapest unit and enqueue
  ↓
  3. (if null) Fall back to legacy rez-sub/default logic
```

## Configuration

### Factory Registration

Each factory must be registered with:
- **Factory name**: e.g., `"armsy"`, `"corsy"`, `"legsy"`
- **Roles**: Ordered list of role names (must match `behaviour.json`)
- **Tier probabilities**: Array of probability arrays (one per tier)
- **Unit mappings**: Dictionary of role → unit name arrays

Example:
```angelscript
FactoryConfig@ cfg = FactoryConfig("armsy");
cfg.AddRole("builder", array<string> = {"armcs"});
cfg.AddRole("scout", array<string> = {"armpt"});
cfg.AddRole("raider", array<string> = {"armsub"});
cfg.AddRole("assault", array<string> = {"armroy"});

cfg.SetTierProbabilities(0, array<float> = {0.15f, 0.25f, 0.35f, 0.15f});
cfg.SetTierProbabilities(1, array<float> = {0.10f, 0.15f, 0.30f, 0.35f});
// ... more tiers
```

### Economic Tiers

Defined by `TIER_INCOME_THRESHOLDS`:
- **Tier 0**: < 20 metal income (early game, focus scouts/raiders)
- **Tier 1**: 20-40 income (mid game, balanced production)
- **Tier 2**: 40-80 income (late T1, more assault units)
- **Tier 3**: 80+ income (high economy, premium units)

### Threat Response

`THREAT_RESPONSE_SCALE = 0.8f` controls how much enemy threat boosts role probabilities:
- Base probability: from tier table
- Weighted probability: `base * (1 + 0.8 * threatRatio)`
- Example: If 30% of enemy threat is "assault" role, assault probability gets 24% boost

## Key Functions

### `FactoryProduction::Initialize()`
Called once at role init. Builds role mask caches and registers factory configs.

### `FactoryProduction::MakeTask(CCircuitUnit@ factory)`
Main entry point. Returns `IUnitTask@` or null if no valid choice.

### `FactoryProduction::QueueUnitByName(string unitName)`
External API to inject priority builds (consumed before normal logic).

### `FactoryProduction::QueueUnitDef(CCircuitDef@ def)`
Alternative priority queue API using direct unit def reference.

## Extension Guide

### Adding New Factories

1. Create `FactoryConfig` instance in `RegisterFactoryConfigs()`
2. Define roles and unit mappings
3. Set tier probability arrays
4. Register in `factoryConfigs` dictionary

Example for bot lab:
```angelscript
void RegisterLandFactories() {
    FactoryConfig@ armlab = FactoryConfig("armlab");
    armlab.AddRole("builder", array<string> = {"armck"});
    armlab.AddRole("scout", array<string> = {"armflea"});
    armlab.AddRole("raider", array<string> = {"armpw"});
    // ... more roles
    
    armlab.SetTierProbabilities(0, array<float> = {0.12f, 0.20f, 0.40f, ...});
    // ... more tiers
    
    factoryConfigs.set("armlab", @armlab);
}
```

### Custom Unit Scoring

Replace `PickBestUnit()` with custom logic:
```angelscript
CCircuitDef@ PickBestUnit(const array<CCircuitDef@> &in candidates) {
    // Current: cheapest by metal cost
    // Alternative: score by cost/DPS ratio, health, range, etc.
    
    CCircuitDef@ best = null;
    float bestScore = -1.0f;
    
    for (uint i = 0; i < candidates.length(); ++i) {
        float score = candidates[i].power / candidates[i].costM;
        if (score > bestScore) {
            @best = candidates[i];
            bestScore = score;
        }
    }
    
    return best;
}
```

### Integrating with Other Roles

1. Add factory configs for that role's factories
2. Include `factory_production.as` in role file
3. Call `FactoryProduction::Initialize()` in role init
4. Call `FactoryProduction::MakeTask()` in factory make task
5. Add role-specific toggle in `global.as`

Example for TECH role:
```angelscript
// In tech.as
#include "../manager/factory_production.as"

void Tech_Init() {
    // ... existing init logic
    
    if (Global::RoleSettings::Tech::UseDynamicFactoryProduction) {
        FactoryProduction::Initialize();
    }
}

IUnitTask@ Tech_FactoryAiMakeTask(CCircuitUnit@ u) {
    // ... constructor guarantees
    
    if (Global::RoleSettings::Tech::UseDynamicFactoryProduction) {
        IUnitTask@ task = FactoryProduction::MakeTask(u);
        if (task !is null) return task;
    }
    
    // ... fall back to legacy logic
}
```

## Debugging

### Enable Verbose Logging

Change log levels in `factory_production.as`:
```angelscript
GenericHelpers::LogUtil("[FactoryProduction] ...", 2); // Always logged
GenericHelpers::LogUtil("[FactoryProduction] ...", 3); // Debug
GenericHelpers::LogUtil("[FactoryProduction] ...", 4); // Trace
```

### Common Issues

**No units produced**:
- Check factory name matches registered config exactly
- Verify unit names exist in game (case-sensitive)
- Ensure tier probabilities sum to ~1.0 per tier
- Confirm units are unlocked (`IsAvailable()`)

**Wrong units produced**:
- Review tier threshold ranges (might be in wrong tier)
- Check threat weighting scale (too high = overreacts)
- Verify role definitions match `behaviour.json`

**Constructor spam**:
- Ensure fallback to builder role only triggers when no other units available
- Check that constructor counts are enforced before calling dynamic system

## Performance

- **Initialization**: O(n) where n = total unit defs (runs once at game start)
- **Per-factory call**: O(r + u) where r = roles, u = units per role
  - Typical: < 0.1ms per factory per frame
- **Memory**: ~50KB for caches + configs (negligible)

## Future Enhancements

1. **Multi-factory coordination**: Share production quotas across factories
2. **Build queue prediction**: Reserve roles for upcoming factories
3. **Advanced scoring**: ML-based unit value estimation
4. **Dynamic tier tuning**: Adjust thresholds based on map size/player count
5. **Response learning**: Track which counters are effective and boost those roles

## Migration from factory.json

Old `factory.json` entry:
```json
"armsy": {
    "importance": [1.0, 0.5],
    "income_tier": [0, 20, 40],
    "unit": ["armcs", "armpt", "armsub", "armroy"],
    "sea": {
        "tier0": [0.15, 0.25, 0.35, 0.25],
        "tier1": [0.10, 0.20, 0.30, 0.40]
    }
}
```

New AngelScript config:
```angelscript
FactoryConfig@ armsy = FactoryConfig("armsy");
armsy.AddRole("builder", array<string> = {"armcs"});
armsy.AddRole("scout", array<string> = {"armpt"});
armsy.AddRole("raider", array<string> = {"armsub"});
armsy.AddRole("assault", array<string> = {"armroy"});

armsy.SetTierProbabilities(0, array<float> = {0.15f, 0.25f, 0.35f, 0.25f});
armsy.SetTierProbabilities(1, array<float> = {0.10f, 0.20f, 0.30f, 0.40f});
```

Benefits:
- No JSON parsing overhead
- Type-safe unit references
- Runtime threat adaptation
- Easier debugging with stack traces
