# NeedleStorm Survival

NeedleStorm Survival is a BeamNG mini survival mode where AI traffic is boosted by dynamic trigger pulses inspired by Fast Traffic Autobahn.

## Core features

- Dynamic trigger boosts per AI vehicle (map-independent).
- Autobahn-style logic: boost is applied only when the AI speed is below a threshold.
- Big HUD with:
  - Large score display.
  - Large stop timer display.
- Automatic game over when player vehicle stays stopped for more than 10 seconds.

## Current default tuning

- Trigger condition: `speed < 20 m/s` (`72 km/h`).
- Trigger boost speed: `120 m/s` (`432 km/h`).
- Dynamic trigger spacing: `66 m`.

## In-game usage

1. Open the UTS / NeedleStorm menu.
2. Spawn traffic.
3. Start survival.
4. Optional:
   - `PRESET TRIGGER (20 m/s)` for Autobahn-like behavior.
   - `PRESET EXTREME` for higher speed chaos.

## Files

- `lua/ge/extensions/uts.lua` - core gameplay and UI logic.
- `scripts/modScript.lua` - extension loader.
- `info.json` - mod metadata.
