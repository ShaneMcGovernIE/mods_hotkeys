# Mods Hotkeys

Detects the hotkeys other installed mods listen for and lets you rebind them from OPTIONS -> MODS HOTKEYS, multi-button combos included (SELECT + A, TAB + LB).

## What it does

- Scans every enabled mod's Lua sources for the input idioms mods actually use: wrapped `keypressed` key checks (`key == "q"`), wrapped `gamepadpressed` button checks (`button == "leftshoulder"`), held pad-button combos (`held.back and held.leftshoulder`), and GB-button combos (`wasPressed("select") and wasPressed("a")`).
- Each distinct trigger becomes a row in OPTIONS -> MODS HOTKEYS showing the current trigger (e.g. `Q`, `LB+BACK`, `SELECT+A`).
- A rebinds a row: press your new combo (any mix of keyboard keys and pad buttons), release to set. Escape cancels. SELECT resets one row, START resets everything.
- Rebinds persist in options.lua, so they survive NEW GAME, CONTINUE and quitting.

## How to try it

1. Install the mod and restart the game (the launcher's mods page or the mods folder).
2. Start or continue a save, open OPTIONS and pick MODS HOTKEYS.
3. Rebind e.g. Battle Move Info's `Q` to `F1`, or Game Speed Toggle's `9` to `LB + SELECT`.

## Notes

- Rebinding adds the new trigger; the original trigger keeps working too (the engine's rebind philosophy).
- Rebound combos are detected at the input layer, so the source mod never changes — it works with any mod, opt-in or not.
- Game Boy buttons (A/B/START/SELECT) can be part of a combo; when they fire the mod they also do their normal thing, exactly as if you pressed them.
- The engine's own hotkeys (F1/F2/F10, the 2/3/4/5 display cycles, -/= zoom, Escape) can't be bound, so a combo can never quicksave or cycle colours by surprise.
