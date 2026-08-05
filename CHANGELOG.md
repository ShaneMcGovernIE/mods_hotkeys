# Changelog

## [0.1.10] - 2026-08-05

- Fixed: B on a hotkey submenu no longer closes the OPTIONS menu beneath it
  too. `exit()` was popping the stack itself, but `StateStack:pop` already
  runs `exit()` as cleanup, so the submenu popped twice — both screens
  closed and two beeps played. `exit()` is now cleanup-only.

- Fixed: `joyN` (raw analog-stick) buttons can no longer be bound. The rebind
  tick has no joystick channel and emission has no way to hold a raw stick
  button, so such a combo could never fire. Capturing one now flashes
  NOT BINDABLE like the reserved keys.

- Fixed: ending a capture clears all live combo holds and virtual holds, so
  a partial hold before the capture or a release swallowed mid-capture can
  no longer fire a stale combo the instant the capture box closes.

- Changed: the seven source-detection branches in `detectFromFiles` were
  deduplicated behind a `record()` builder (~50 lines removed).

## [0.1.9] - 2026-08-04

- Added: Dex Radar's overworld hotkey (default `R`, configurable through its own OPTIONS -> HOTKEY KEY) is now detected and rebindable. The scanner understands the direct keyboard-poll idiom (`love.keyboard.isDown(key)` with an edge latch, the key read from `mod.options:get`), which also covers any other mod that polls the keyboard directly. Rebound triggers hold the polled key virtually for the combo's duration, so the source mod's own poll sees the press exactly as if the key had been pressed.

- Added: Quick Select's SELECT trigger is now detected and rebindable. The scanner understands the pressQueue-polling idiom (`queued(input, "select")` and direct `input.state.select` reads, gated on `pressQueue` so movement code is never claimed), which also covers any other mod that polls Input's queue directly.

## [0.1.8] - 2026-08-03

- Mod names longer than the row label window now scroll as a ticker (hold at the start, scroll to the end, hold, scroll back — the MoveRelearn name ticker) instead of bleeding over the box border.

## [0.1.7] - 2026-08-03

- Hotkeys are now split into two pages: OPTIONS -> PC HOTKEYS (keyboard triggers) and OPTIONS -> PAD HOTKEYS (controller triggers). A row's page is fixed by its default trigger, so rebinds never shuffle rows between pages.

## [0.1.6] - 2026-08-03

- Added: the engine's built-in game-speed hotkeys now appear as rebindable rows (SPEED UP / SPEED DOWN) when the running engine has them — the `1` key and the L2/R2 bumpers (upstream `Game:_cycleSpeed`). Old engines without the feature contribute no rows.
- The `1` key joins the reserved list (the engine consumes it for the speed cycle, so a combo containing it would also change speed).
- README now carries a quick guide for mod developers: the idioms this mod detects and how to write a hotkey so it shows up.

## [0.1.5] - 2026-08-03

- Combo separator is now "×" (T×Y, SELECT×A) instead of ASCII "+" — the charmap has no "+" glyph, so it rendered as a blank tile in the menu rows and the capture box.

## [0.1.4] - 2026-08-03

- Fixed the capture dialog text layout: every line now sits on an interior glyph row, so "ESC CANCELS" no longer overlaps the box's bottom border.

## [0.1.3] - 2026-08-03

- Capture overlay is now a full-screen white pass with two boxes, so the options list underneath can never peek through the seams.
- Removed the "ENGINE KEYS N/A" line; pressing a reserved engine key during capture now flashes "<KEY> NOT BINDABLE" for a moment instead.

## [0.1.2] - 2026-08-03

- Capture overlay redesigned: full-width instruction box (no clipped lines) and a separate centered box for the live combo being pressed.
- Long 4-piece combos are capped with a trailing "+" in the menu rows and the live box instead of clipping mid-glyph.

## [0.1.1] - 2026-08-03

- Added: configurable GB-button triggers are now detected — a `*BUTTONS` list (DexNav's `DEXNAV_BUTTONS = { "select", "start", "a", "b" }`) polled through a dynamic `wasPressed(helper(game))` call becomes a rebindable hotkey (default = the list's first button).
- Filtered random-pick arrays like `dirs = {"up", "down", "left", "right"}` out of that detection.

## [0.1.0] - 2026-08-03

- OPTIONS -> MODS HOTKEYS submenu listing hotkeys detected from other installed mods (wrapped keypressed keys, gamepadpressed buttons, held pad combos, GB-button combos).
- Multi-button rebinding: press a combo like SELECT + A or TAB + LB, release to set.
- Rebind translation layer at game.ready (outermost input wrap): the new trigger re-emits the original trigger's press edges, so the source mod is never modified.
- Rebind persistence in options.lua's per-mod bucket; SELECT resets a row, START resets all.
- Fixed: a captured combo now commits all its pieces (the pending list used to be emptied before the commit read it, so no rebind was ever stored).
