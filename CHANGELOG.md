# Changelog

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
