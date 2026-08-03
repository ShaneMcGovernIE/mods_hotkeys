-- Standalone: luajit mods/mods_hotkeys/tests/mods_hotkeys_test.lua
-- Loads the mod through the real headless loader and asserts the source
-- scanning (parseSource/detectFromFiles/scanMods), the combo state
-- machine, canonical GB-button emission, the OPTIONS row and the
-- persistence round-trip.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Runtime = require("src.mods.Runtime")
local Data = require("src.core.Data")
Data:load()

local run = T.sdk.loadMod("mods/mods_hotkeys", { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")
local ex = run.loader.exports.mods_hotkeys
T.neq(ex, nil, "exports reachable")

-- ------------------------------------------------------- registry + row

T.neq(run.loader.content.screens:get("ModsHotkeysMenu"), nil,
      "ModsHotkeysMenu registered")
local Game = require("src.core.Game")
Game.mods = run.loader

local function findRow()
  local rows = Runtime.call("ui.options.rows", function(_, r) return r end,
    {}, {})
  for _, row in ipairs(rows) do
    if row.id == "modsHotkeys" then return row end
  end
  return nil
end

local row = findRow()
T.neq(row, nil, "the MODS HOTKEYS row joins the options menu")
T.eq(row.label, "MODS HOTKEYS", "row label")

-- ------------------------------------------------ source scanning

local SRC_KEY = [[
local Input = require("src.core.Input")
local vanilla = Input.keypressed
Input.keypressed = function(self, key)
  if key == "q" then state.qHeld = true end
  return vanilla(self, key)
end
local vp = Input.gamepadpressed
Input.gamepadpressed = function(self, joystick, button)
  if button == "start" then state.edge = true end
  return vp(self, joystick, button)
end
]]

local parsed = ex.parseSource(SRC_KEY)
T.eq(parsed.keys.q, true, "detects the wrapped key literal (q)")
T.eq(parsed.pads.start, true, "detects the wrapped pad literal (start)")
T.eq(next(parsed.held), nil, "no held combo in this file")

local SRC_COMBO = [[
function Game.gamepadpressed(self, joystick, button, ...)
  if button == "back" or button == "leftshoulder" then
    held[button] = true
    return held.back and held.leftshoulder
  end
  return originalPadPressed(self, joystick, button, ...)
end
]]

local parsed2 = ex.parseSource(SRC_COMBO)
T.eq(parsed2.pads.back, true, "combo: pad literal back")
T.eq(parsed2.pads.leftshoulder, true, "combo: pad literal leftshoulder")
T.eq(parsed2.held.back, true, "combo: held pair back")
T.eq(parsed2.held.leftshoulder, true, "combo: held pair leftshoulder")

local SRC_GB = [[
if input:wasPressed("select") and input:wasPressed("a") then open() end
if input:isDown("b") and input:isDown("select") then close() end
]]
local parsed3 = ex.parseSource(SRC_GB)
T.eq(#parsed3.gb, 2, "gb combos: wasPressed pair + isDown pair")
T.eq(parsed3.gb[1][1], "select", "gb combo first piece")
T.eq(parsed3.gb[1][2], "a", "gb combo second piece")

-- a `spec.key == key` comparison in a file with no keypressed wrap must
-- never be claimed as a hotkey
local SRC_NOOP = [[
local function get(key)
  for _, spec in ipairs(TOGGLES) do
    if spec.key == key then return spec.default end
  end
end
]]
local parsed4 = ex.parseSource(SRC_NOOP)
T.eq(next(parsed4.keys), nil, "no keypressed wrap -> no key hotkeys")
T.eq(next(parsed4.pads), nil, "no gamepadpressed wrap -> no pad hotkeys")

-- ------------------------------------------------- detectFromFiles

local files = { ["main.lua"] = SRC_KEY, ["speed.lua"] = SRC_COMBO }
local found = ex.detectFromFiles(files, "battle_move_info", "Battle Move Info")
local byId = {}
for _, hk in ipairs(found) do byId[hk.id] = hk end
T.eq(byId["battle_move_info|main.lua|key:q"] ~= nil, true, "key hotkey id")
T.eq(byId["battle_move_info|main.lua|pad:start"] ~= nil, true,
     "single pad hotkey id")
local combo = byId["battle_move_info|speed.lua|combo:back+leftshoulder"]
T.neq(combo, nil, "held combo hotkey id (sorted pieces)")
T.eq(#combo.pieces, 2, "combo carries both pads")
T.eq(#found, 3, "two files -> three hotkeys (singles folded into combo)")

-- ------------------------------------------------------- describe

T.eq(ex.describe({ { kind = "key", name = "tab" },
                  { kind = "pad", name = "leftshoulder" } }),
     "TAB+LB", "key + pad combo described")
T.eq(ex.describe({ { kind = "gb", name = "select" },
                  { kind = "gb", name = "a" } }),
     "SELECT+A", "gb combo described")
T.eq(ex.describe({ { kind = "key", name = "return" } }),
     "ENTER", "return -> ENTER")
T.eq(ex.describe({ { kind = "key", name = "leftshoulder" } }),
     "LB", "leftshoulder -> LB")
T.eq(ex.describe({}), "--", "empty trigger")

-- -------------------------------------------------- combo state machine

local cs = ex.comboState({ { kind = "key", name = "f1" } })
local _, t1 = ex.comboStep(cs, { kind = "key", name = "f1", pressed = true })
T.eq(t1, "fire", "single piece fires on press")
local _, t2 = ex.comboStep(cs, { kind = "key", name = "f1", pressed = true })
T.eq(t2, nil, "auto-repeat press never refires")
local _, t3 = ex.comboStep(cs, { kind = "key", name = "f1", pressed = false })
T.eq(t3, "break", "release breaks the combo")

local cs2 = ex.comboState({ { kind = "key", name = "tab" },
                            { kind = "key", name = "z" } })
local _, c1 = ex.comboStep(cs2, { kind = "key", name = "tab", pressed = true })
T.eq(c1, nil, "first piece of a combo does not fire")
local _, c2 = ex.comboStep(cs2, { kind = "key", name = "z", pressed = true })
T.eq(c2, "fire", "combo fires when the last piece lands")
local _, c3 = ex.comboStep(cs2, { kind = "key", name = "z", pressed = false })
T.eq(c3, "break", "combo breaks when any piece releases")
local _, c4 = ex.comboStep(cs2, { kind = "pad", name = "back", pressed = true })
T.eq(c4, nil, "unrelated events never touch the combo")

-- ------------------------------------------------- canonicalFor

local kb = { tab = "select", z = "a", x = "b", escape = "start" }
local pb = { back = "select", a = "a", b = "b", start = "start" }
local ck = ex.canonicalFor("select", kb, pb)
T.eq(ck.kind, "key", "select canonical kind")
T.eq(ck.name, "tab", "select canonical key")
T.eq(ex.canonicalFor("start", kb, pb).name, "escape", "start canonical key")
local kb2 = { f7 = "select", z = "a", x = "b", escape = "start" }
T.eq(ex.canonicalFor("select", kb2, pb).name, "f7",
     "canonical follows a rebound engine binding")
local cp = ex.canonicalFor("select", {}, pb)
T.eq(cp.kind, "pad", "no key maps it -> pad fallback")
T.eq(cp.name, "back", "pad fallback is back")
T.eq(ex.canonicalFor("select", {}, {}), nil, "nothing maps it -> nil")

-- ------------------------------------------------- isBindable (capture)

T.eq(ex.isBindable("key", "tab"), true, "TAB is bindable")
T.eq(ex.isBindable("key", "9"), true, "digits other than the engine's are bindable")
T.eq(ex.isBindable("key", "f1"), false, "F1 (quicksave) is not bindable")
T.eq(ex.isBindable("key", "2"), false, "2 (colour cycle) is not bindable")
T.eq(ex.isBindable("key", "f10"), false, "F10 (mod manager) is not bindable")
T.eq(ex.isBindable("key", "escape"), false, "Escape (capture cancel) is not bindable")
T.eq(ex.isBindable("pad", "leftshoulder"), true, "pad buttons are bindable")

-- ---------------------------------------------------- scanMods (fake fs)

local fakeFs = {
  read = function(path)
    local files = {
      ["mods/battle_move_info/main.lua"] = SRC_KEY,
      ["mods/game_speed_toggle/main.lua"] = SRC_COMBO,
      ["mods/qol_toggles/main.lua"] = SRC_NOOP,
    }
    return files[path]
  end,
  getDirectoryItems = function(path)
    if path:find("battle_move_info") then return { "main.lua" } end
    if path:find("game_speed_toggle") then return { "main.lua" } end
    return { "main.lua" }
  end,
}
local fakeMods = {
  battle_move_info = { manifest = { name = "Battle Move Info", entry = "main.lua" },
    enabled = true, path = "mods/battle_move_info" },
  game_speed_toggle = { manifest = { name = "Game Speed Toggle", entry = "main.lua" },
    enabled = true, path = "mods/game_speed_toggle" },
  qol_toggles = { manifest = { name = "QoL Toggles", entry = "main.lua" },
    enabled = true, path = "mods/qol_toggles" },
  off_mod = { manifest = { name = "Off", entry = "main.lua" },
    enabled = false, path = "mods/off_mod" },
  mods_hotkeys = { manifest = { name = "Mods Hotkeys", entry = "main.lua" },
    enabled = true, path = "mods/mods_hotkeys" },
}
local scanned = ex.scanMods({ mods = fakeMods, fs = fakeFs }, "mods_hotkeys")
T.eq(#scanned, 3, "scan skips self and disabled mods")
T.eq(scanned[1].id, "battle_move_info|main.lua|key:q",
     "sorted: first battle_move_info key hotkey")
T.eq(scanned[1].modName, "Battle Move Info", "hotkey carries the mod name")

-- ---------------------------------------------------- persistence + fold

local id = "battle_move_info|main.lua|key:q"
local empty = {}
ex.setRebinds(empty)
T.eq(next(ex.getRebinds()), nil, "reset leaves the bucket empty")

ex.setRebinds({ [id] = { pieces = { { kind = "key", name = "f6" } } } })
T.eq(ex.getRebinds()[id].pieces[1].name, "f6",
     "rebind persists in the loader bucket")

-- the fold needs a detected hotkey for that id, so seed the live table
ex.state.hotkeys[id] = { id = id, modName = "Battle Move Info",
                         pieces = { { kind = "key", name = "q" } } }
ex.applyRebinds()
T.eq(ex.currentTrigger(id), "F6", "rebound trigger shows in the row")
T.eq(ex.state.rebinds[id].original[1].name, "q",
     "the original trigger is kept for emission")

-- a rebind whose id is no longer detected is dropped silently
ex.setRebinds({ [id] = { pieces = { { kind = "key", name = "f6" } } },
                ["ghost|main.lua|key:q"] =
                  { pieces = { { kind = "key", name = "f6" } } } })
ex.applyRebinds()
T.eq(ex.currentTrigger("ghost|main.lua|key:q"), "--",
     "stale rebinds for removed mods are ignored")
T.eq(ex.currentTrigger(id), "F6", "live rebind survives the stale fold")

-- unbinding: an empty pieces list is ignored (no live combo)
ex.setRebinds({ [id] = { pieces = {} } })
ex.applyRebinds()
T.eq(ex.currentTrigger(id), "Q", "empty rebind falls back to the default")
T.eq(ex.state.rebinds[id], nil, "no live combo for an empty rebind")

T.finish("mods_hotkeys")
