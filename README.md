# Mods Hotkeys

Detects the hotkeys other installed mods listen for — and the engine's own built-in ones — and lets you rebind them from OPTIONS -> MODS HOTKEYS, multi-button combos included (SELECT + A, TAB + LB).

## What it does

- Scans every enabled mod's Lua sources for the input idioms mods actually use: wrapped `keypressed` key checks (`key == "q"`), wrapped `gamepadpressed` button checks (`button == "leftshoulder"`), held pad-button combos (`held.back and held.leftshoulder`), GB-button combos (`wasPressed("select") and wasPressed("a")`), configurable GB-button triggers (DexNav's `DEXNAV_BUTTONS = { "select", "start", "a", "b" }` polled via `wasPressed(dexNavButton(game))`), and direct keyboard polls (Dex Radar's `love.keyboard.isDown(key)` read from its own options, with an edge latch).
- Includes the engine's built-in hotkeys when the running build has them: game speed via the `1` key and the L2/R2 bumpers (SPEED UP / SPEED DOWN rows, rebound like any mod hotkey).
- Each distinct trigger becomes a row on one of two pages — OPTIONS -> PC HOTKEYS (keyboard triggers) and OPTIONS -> PAD HOTKEYS (controller triggers) — showing the current trigger (e.g. `Q`, `LB+BACK`, `R2`, `SELECT+A`).
- A rebinds a row: press your new combo (any mix of keyboard keys and pad buttons), release to set. Escape cancels. SELECT resets one row, START resets everything.
- Rebinds persist in options.lua, so they survive NEW GAME, CONTINUE and quitting.
- Mod names longer than the row's label window scroll as a ticker (hold at the start, scroll to the end, hold, scroll back), so long names like "Crystal Animated Sprites With Shiny Visuals" stay readable instead of bleeding over the box border.

## How to try it

1. Install the mod and restart the game (the launcher's mods page or the mods folder).
2. Start or continue a save, open OPTIONS and pick PC HOTKEYS or PAD HOTKEYS.
3. Rebind e.g. Battle Move Info's `Q` to `F1`, or the engine's SPEED UP (`R2`) to `LB + SELECT`.

## For mod developers: making your hotkey detectable

No opt-in or API is needed — Mods Hotkeys reads your mod's Lua sources
and recognises the standard input idioms. Write your trigger with
literals and it shows up in the menu, rebindable by any player.
Rebinding just re-emits your original trigger's press through the input
chain, so your mod's code never changes.

### Single keyboard key

```lua
local vanilla = Input.keypressed
Input.keypressed = function(self, key)
  if key == "q" then toggle() end   -- detected as Q
  return vanilla(self, key)
end
```

### Single pad button (L/R bumpers, SELECT, START, ...)

```lua
local vanilla = Input.gamepadpressed
Input.gamepadpressed = function(self, joystick, button)
  if button == "leftshoulder" then toggle() end   -- detected as LB
  return vanilla(self, joystick, button)
end
```

### Pad hold-combo (SELECT + LB)

```lua
-- anywhere in a file that wraps gamepadpressed; the
-- held.back and held.leftshoulder pair is what gets detected
if held.back and held.leftshoulder then toggle() end
```

### Game Boy buttons

```lua
if input:wasPressed("select") and input:wasPressed("a") then toggle() end
```

### Configurable trigger (a selectable GB button)

```lua
local DEXNAV_BUTTONS = { "select", "start", "a", "b" }  -- name must contain "button"
if input:wasPressed(dexNavButton(game)) then search() end
```

### Direct keyboard poll (a polled key, configurable via options)

```lua
-- key = mod.options:get("hotkey")  -- defined in mod.options:define, default "r"
local down = love.keyboard.isDown(key)
local edge = down and not keyWasDown   -- the edge latch is what gets detected
keyWasDown = down
if edge then openRadar() end
```

Rebinding such a trigger holds the polled key virtually while your new
combo is held, so the source mod's own `love.keyboard.isDown` poll sees
the press — the current key is read back live from its options, so
changing the key in the source mod's OPTIONS menu updates the row.

### Rules of thumb

- Keep triggers as literals — `key == "q"`, never `key == spec.key`. Literals are what the scanner reads.
- The literal must appear in a file that mentions `keypressed` or `gamepadpressed`, so unrelated `spec.key == key` comparisons are never claimed.
- A direct `love.keyboard.isDown` poll needs the edge latch (`down and not keyWasDown`); keyboard-state reads without it are never claimed.
- Write pad combos as one `held.a and held.b` expression so the pieces are recognised as a single trigger.
- Put the trigger in the entry or a top-level `.lua` file; `tests/` are never scanned.

## Notes

- Rebinding adds the new trigger; the original trigger keeps working too (the engine's rebind philosophy).
- A row's page is fixed by its default trigger: pad triggers live on PAD HOTKEYS, keyboard and GB-button triggers on PC HOTKEYS. Rebinding never moves a row between pages — the value column always shows the current trigger wherever the row sits.
- Rebound combos are detected at the input layer, so the source mod never changes — it works with any mod, opt-in or not.
- Game Boy buttons (A/B/START/SELECT) can be part of a combo; when they fire the mod they also do their normal thing, exactly as if you pressed them.
- The engine's own hotkeys (F1/F2/F10, the 1/2/3/4/5 display and speed cycles, -/= zoom, Escape) can't be bound, so a combo can never quicksave, cycle colours or change speed by surprise.
