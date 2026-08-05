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

local function findRow(id)
  local rows = Runtime.call("ui.options.rows", function(_, r) return r end,
    {}, {})
  for _, row in ipairs(rows) do
    if row.id == id then return row end
  end
  return nil
end

local rowPc = findRow("modsHotkeysPc")
T.neq(rowPc, nil, "the PC HOTKEYS row joins the options menu")
T.eq(rowPc.label, "PC HOTKEYS", "pc row label")
local rowPad = findRow("modsHotkeysPad")
T.neq(rowPad, nil, "the PAD HOTKEYS row joins the options menu")
T.eq(rowPad.label, "PAD HOTKEYS", "pad row label")

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

-- the state+queue polling idiom (Quick Select): a helper that checks a
-- GB-button literal against input.pressQueue, plus direct input.state reads
local SRC_QS = [[
local function queued(input, button)
  for _, value in ipairs(input.pressQueue or {}) do
    if value == button then return true end
  end
  return false
end
mod.hooks:wrap("input.step", function(nextFn, game, dt)
  nextFn(game, dt)
  local input = game and game.input
  if not input then return end
  local selectDown = input.state and input.state.select == true
  local selectPressed = queued(input, "select")
  local direction = directionFor(input, selectPressed)
  if direction and (selectDown or selectPressed) then
    consumeQueued(input, { "select", direction })
  end
end)
]]
local parsedQS = ex.parseSource(SRC_QS)
T.eq(parsedQS.gbSingles.select, true, "state+queue: select detected")
T.eq(next(parsedQS.keys), nil, "state+queue claims no key literals")
T.eq(#parsedQS.gb, 0, "state+queue claims no wasPressed pairs")

-- input.state reads without the pressQueue idiom are movement code
local SRC_STATE_ONLY = [[
local function isMoving(input)
  return input.state.up and input.state.down
end
]]
T.eq(next(ex.parseSource(SRC_STATE_ONLY).gbSingles), nil,
     "state reads without pressQueue are not claimed")

-- a pressQueue helper polling a variable (a direction in a loop) is not
-- a single-button trigger
local SRC_QS_VAR = [[
local function queued(input, button)
  for _, value in ipairs(input.pressQueue or {}) do
    if value == button then return true end
  end
  return false
end
for _, direction in ipairs(DIRECTIONS) do
  if queued(input, direction) then move(direction) end
end
]]
T.eq(next(ex.parseSource(SRC_QS_VAR).gbSingles), nil,
     "variable button polls are not single-button triggers")

-- the direct keyboard-poll idiom (Dex Radar): love.keyboard.isDown with
-- an edge latch, the key read from mod.options:get
local SRC_RADAR = [[
mod.options:define({
  { key = "hotkey_enabled", type = "toggle", label = "HOTKEY", default = true },
  { key = "hotkey", type = "choice", label = "HOTKEY KEY", default = "r",
    choices = HOTKEY_CHOICES },
})
mod.hooks:wrap("input.step", function(next, game, dt)
  next(game, dt)
  if not mod.options:get("hotkey_enabled") then return end
  local key = mod.options:get("hotkey")
  if not key or key == "off" then return end
  local down = love.keyboard.isDown(key)
  local edge = down and not keyWasDown
  keyWasDown = down
  if not edge then return end
  openRadar(game)
end)
]]
local parsedR = ex.parseSource(SRC_RADAR)
T.eq(parsedR.pollField, "hotkey", "poll field captured from options:get")
T.eq(parsedR.pollDefault, "r", "poll default captured from the schema row")
T.eq(next(parsedR.keys), nil, "poll file claims no keypressed keys")
T.eq(next(parsedR.gbSingles), nil, "poll file claims no queue polls")

-- a keyboard-state read without the edge latch is not a hotkey
local SRC_NO_LATCH = [[
local down = love.keyboard.isDown("q")
if down then run() end
]]
local parsedNL = ex.parseSource(SRC_NO_LATCH)
T.eq(next(parsedNL.pollKeys), nil, "no latch -> no poll hotkey")

-- a literal poll is a plain keypoll hotkey
local SRC_POLL_LIT = [[
local down = love.keyboard.isDown("q")
if down and not wasDown then toggle() end
]]
local foundLit = ex.detectFromFiles({ ["main.lua"] = SRC_POLL_LIT }, "m", "M")
T.eq(#foundLit, 1, "literal keyboard poll is a hotkey")
T.eq(foundLit[1].id, "m|main.lua|keypoll:q", "literal keypoll id")
T.eq(foundLit[1].poll, true, "literal poll marked poll")

local filesR = { ["main.lua"] = SRC_RADAR }
local foundR = ex.detectFromFiles(filesR, "dex_radar", "Dex Radar")
T.eq(#foundR, 1, "radar file yields one hotkey")
T.eq(foundR[1].id, "dex_radar|main.lua|keypoll:hotkey", "keypoll hotkey id")
T.eq(foundR[1].pieces[1].kind, "key", "keypoll default piece kind")
T.eq(foundR[1].pieces[1].name, "r", "keypoll default piece name")
T.eq(foundR[1].poll, true, "keypoll marked poll for virtual emission")
T.eq(foundR[1].pollField, "hotkey", "keypoll carries the options field")
T.eq(ex.hotkeyPage(foundR[1].pieces), "pc", "keypoll is the PC page")

-- the live key resolves from the loader's modOptions bucket (the exact
-- table mod.options:get reads), then the schema default, then the scan
-- default; "off" (Dex Radar's disable value) falls back to a real key
local savedMods = Game.mods
Game.mods = { modOptions = { dex_radar = { hotkey = "g" } },
              optionSchemas = { dex_radar = {
                { key = "hotkey", default = "r" } } } }
T.eq(ex.resolvePollKey(foundR[1]), "g",
     "resolvePollKey reads the live option")
T.eq(ex.currentTrigger(foundR[1].id), "--", "unseeded row has no trigger")
ex.state.hotkeys[foundR[1].id] = foundR[1]
T.eq(ex.currentTrigger(foundR[1].id), "G", "poll row shows the live key")
Game.mods = { modOptions = {}, optionSchemas = { dex_radar = {
  { key = "hotkey", default = "r" } } } }
T.eq(ex.resolvePollKey(foundR[1]), "r",
     "resolvePollKey falls back to the schema default")
Game.mods = { modOptions = { dex_radar = { hotkey = "off" } },
              optionSchemas = { dex_radar = {
                { key = "hotkey", default = "r" } } } }
T.eq(ex.resolvePollKey(foundR[1]), "r", "off resolves to the default")
Game.mods = savedMods
ex.state.hotkeys = {}

-- a poll hotkey folds into a rebind like any row, keeping the flags the
-- emission layer needs
ex.state.hotkeys[foundR[1].id] = foundR[1]
ex.setRebinds({ [foundR[1].id] = { pieces = { { kind = "key", name = "f7" } } } })
ex.applyRebinds()
T.eq(ex.state.rebinds[foundR[1].id].poll, true, "rebind keeps the poll flag")
T.eq(ex.state.rebinds[foundR[1].id].pollField, "hotkey",
     "rebind keeps the options field")
T.eq(ex.currentTrigger(foundR[1].id), "F7", "poll row rebinds like any row")
ex.setRebinds({})
ex.state.hotkeys = {}

-- configurable trigger idiom (DexNav): a GB-button list polled through a
-- dynamic wasPressed(helper(...)) call
local SRC_DEXNAV = [[
local DEXNAV_BUTTONS = { "select", "start", "a", "b" }
local function dexNavButton(game)
  local saved = game.save.options.dexNavButton
  for _, btn in ipairs(DEXNAV_BUTTONS) do
    if btn == saved then return btn end
  end
  return "select"
end
if Game.input:wasPressed(dexNavButton(Game)) and Game.save.dexNavReg then
  search()
end
]]
local parsed5 = ex.parseSource(SRC_DEXNAV)
T.eq(parsed5.dynamic, true, "dynamic wasPressed detected")
T.eq(#parsed5.buttonLists, 1, "one button list found")
T.eq(parsed5.buttonLists[1].first, "select", "list default is select")
T.eq(parsed5.buttonLists[1].buttons.b, true, "list carries every GB button")
T.eq(parsed5.dynamicField, "dexNavButton", "polled helper name captured")
T.eq(next(parsed5.keys), nil, "no raw keys claimed for the dexnav file")

-- a button list without any dynamic poll is not a hotkey
local SRC_LIST_ONLY = [[
local OPTIONS = { "select", "start" }
local function show() end
]]
local parsed6 = ex.parseSource(SRC_LIST_ONLY)
T.eq(parsed6.dynamic, false, "list alone is not a trigger")

-- a non-trigger list (random-pick directions) must not be claimed even
-- when the file has a dynamic poll
local SRC_DIRS = [[
local dirs = {"up", "down", "left", "right"}
local d = dirs[math.random(4)]
if Game.input:wasPressed(dexNavButton(Game)) then show() end
]]
local parsed7 = ex.parseSource(SRC_DIRS)
T.eq(#parsed7.buttonLists, 0, "dirs array is not a button config")
T.eq(#ex.detectFromFiles({ ["main.lua"] = SRC_DIRS }, "DexNav", "DexNav"),
     0, "no hotkey from the dirs array")

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

-- dexnav-style configurable trigger joins the detection
local files2 = { ["main.lua"] = SRC_DEXNAV }
local foundDex = ex.detectFromFiles(files2, "DexNav", "DexNav")
T.eq(#foundDex, 1, "dexnav file yields one hotkey")
T.eq(foundDex[1].id, "DexNav|main.lua|gbcfg:select", "gbcfg hotkey id")
T.eq(foundDex[1].pieces[1].kind, "gb", "gbcfg default piece kind")
T.eq(foundDex[1].pieces[1].name, "select", "gbcfg default piece name")
T.eq(foundDex[1].dynamicField, "dexNavButton", "gbcfg carries the save field")
T.eq(foundDex[1].buttons.a, true, "gbcfg carries the mod's button list")

-- quick-select style single-button poll joins the detection; both forms
-- of the same button fold into one row
local filesQS = { ["main.lua"] = SRC_QS }
local foundQS = ex.detectFromFiles(filesQS, "jj_quick_select", "Quick Select")
T.eq(#foundQS, 1, "quick select file yields one hotkey")
T.eq(foundQS[1].id, "jj_quick_select|main.lua|gb:select",
     "gb single hotkey id")
T.eq(foundQS[1].pieces[1].kind, "gb", "gb single piece kind")
T.eq(foundQS[1].pieces[1].name, "select", "gb single piece name")
T.eq(ex.describe(foundQS[1].pieces), "SELECT", "gb single described")

-- ------------------------------------------------------- describe

T.eq(ex.describe({ { kind = "key", name = "tab" },
                  { kind = "pad", name = "leftshoulder" } }),
     "TAB×LB", "key + pad combo described")
T.eq(ex.describe({ { kind = "gb", name = "select" },
                  { kind = "gb", name = "a" } }),
     "SELECT×A", "gb combo described")
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
T.eq(ex.isBindable("key", "1"), false, "1 (engine speed cycle) is not bindable")
T.eq(ex.isBindable("key", "f1"), false, "F1 (quicksave) is not bindable")
T.eq(ex.isBindable("key", "2"), false, "2 (colour cycle) is not bindable")
T.eq(ex.isBindable("key", "f10"), false, "F10 (mod manager) is not bindable")
T.eq(ex.isBindable("key", "escape"), false, "Escape (capture cancel) is not bindable")
T.eq(ex.isBindable("pad", "leftshoulder"), true, "pad buttons are bindable")
T.eq(ex.isBindable("pad", "joy1"), false,
     "raw-stick joyN buttons are not bindable (no re-emit channel)")
T.eq(ex.isBindable("pad", "back"), true, "named pad buttons stay bindable")

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

-- ------------------------------------------- engine built-in hotkeys

local stubEngine = { _cycleSpeed = function() end }
local eng = ex.engineHotkeys(stubEngine)
T.eq(#eng, 3, "engine with _cycleSpeed yields the three built-in rows")
local engBy = {}
for _, hk in ipairs(eng) do engBy[hk.id] = hk end
local up = engBy["engine|builtin|speed:up"]
T.neq(up, nil, "speed up row id")
T.eq(up.pieces[1].kind, "pad", "speed up is a pad row")
T.eq(up.pieces[1].name, "rightshoulder", "speed up default is R2")
T.eq(up.label, "SPEED UP", "speed up row label")
local down = engBy["engine|builtin|speed:down"]
T.eq(down.pieces[1].name, "leftshoulder", "speed down default is L2")
local kb = engBy["engine|builtin|speed:up:kb"]
T.eq(kb.pieces[1].kind, "key", "keyboard speed row is a key")
T.eq(kb.pieces[1].name, "1", "keyboard speed default is 1")
T.eq(#ex.engineHotkeys({}), 0, "engine without _cycleSpeed yields no rows")
T.eq(#ex.engineHotkeys(nil), 3, "the real engine contributes the built-in rows")

-- engine rows fold into rebinds like any detected hotkey
local engId = "engine|builtin|speed:up"
ex.state.hotkeys[engId] = engBy[engId]
ex.setRebinds({ [engId] = { pieces = { { kind = "key", name = "f7" } } } })
ex.applyRebinds()
T.eq(ex.currentTrigger(engId), "F7", "engine row rebinds and shows the new trigger")
T.eq(ex.state.rebinds[engId].original[1].name, "rightshoulder",
     "engine row keeps its original trigger for emission")
ex.setRebinds({})

-- ------------------------------------------- page classification

T.eq(ex.hotkeyPage({ { kind = "key", name = "q" } }), "pc",
     "key trigger is the PC page")
T.eq(ex.hotkeyPage({ { kind = "gb", name = "select" },
                     { kind = "gb", name = "a" } }), "pc",
     "GB-only combo is the PC page")
T.eq(ex.hotkeyPage({ { kind = "pad", name = "rightshoulder" } }),
     "controller", "pad trigger is the controller page")
T.eq(ex.hotkeyPage({ { kind = "key", name = "tab" },
                     { kind = "pad", name = "leftshoulder" } }),
     "controller", "mixed key+pad combo is the controller page")
T.eq(ex.hotkeyPage(nil), "pc", "no pieces -> PC page")

-- the engine rows land on their natural pages
for _, hk in ipairs(ex.engineHotkeys(stubEngine)) do
  if hk.pieces[1].kind == "pad" then
    T.eq(ex.hotkeyPage(hk.pieces), "controller",
         "engine pad row is the controller page (" .. hk.id .. ")")
  else
    T.eq(ex.hotkeyPage(hk.pieces), "pc",
         "engine key row is the PC page (" .. hk.id .. ")")
  end
end

-- the screen factory filters rows by page
local factory = run.loader.content.screens:get("ModsHotkeysMenu").new
ex.state.hotkeys = {
  ["engine|builtin|speed:up"] =
    { id = "engine|builtin|speed:up", modName = "ENGINE", label = "SPEED UP",
      pieces = { { kind = "pad", name = "rightshoulder" } } },
  ["engine|builtin|speed:up:kb"] =
    { id = "engine|builtin|speed:up:kb", modName = "ENGINE", label = "SPEED UP",
      pieces = { { kind = "key", name = "1" } } },
  ["battle_move_info|main.lua|key:q"] =
    { id = "battle_move_info|main.lua|key:q", modName = "Battle Move Info",
      pieces = { { kind = "key", name = "q" } } },
  ["long_name|main.lua|key:q"] =
    { id = "long_name|main.lua|key:q",
      modName = "Crystal Animated Sprites With Shiny Visuals",
      pieces = { { kind = "key", name = "q" } } },
}
local pcMenu = factory({}, "pc")
T.eq(#pcMenu.rows, 3, "pc page shows only key rows")
T.eq(pcMenu.page, "pc", "pc menu carries its page")
local padMenu = factory({}, "controller")
T.eq(#padMenu.rows, 1, "controller page shows only pad rows")
T.eq(padMenu.rows[1].hotkey.id, "engine|builtin|speed:up",
     "the R2 row lives on the controller page")

-- ------- the name ticker for overflowing mod names

-- a name that fits its window never ticks
T.eq(pcMenu.rows[1].ticker, nil,
     "a short label has no ticker (Battle Move Info fits)")
T.eq(pcMenu.rows[2].ticker, nil,
     "an explicit short label has no ticker (SPEED UP)")

-- the long mod name gets a ticker clamped to the label window
local long = pcMenu.rows[3]
T.neq(long, nil, "the long-name row exists")
T.neq(long.ticker, nil, "an overflowing name ticks")
T.eq(long.ticker.x, 16, "ticker starts at the label's x")
T.eq(long.ticker.w, 136, "ticker clips at the inner right edge (152-16)")
T.check(long.ticker.overflow > 0, "overflow is the pixels past the window")
T.eq(long.label, "Crystal Animated Sprites With Shiny Visuals",
     "the full name is kept on the row")
T.eq(long.tick, 0, "the tick starts at zero")
local tickMenu = factory({ input = { wasPressed = function() return false end } },
                         "pc")
local tickRow
for _, row in ipairs(tickMenu.rows) do
  if row.ticker then tickRow = row break end
end
T.neq(tickRow, nil, "the fresh menu still carries the ticker row")
tickMenu:update(1 / 60)
T.eq(tickRow.tick, 1 / 60, "update advances the ticker clock")

ex.state.hotkeys = {}

-- pure offset math: hold at each end, 16px/s between
local to = ex.tickerOffset
T.eq(to(0, 40), 0, "ticker starts at the label head")
T.eq(to(0.5, 40), 0, "start hold keeps the label still")
T.eq(to(1.6 + 0.5, 40), -8, "scrolls out at 16px/s")
T.check(math.abs(to(1.6 + 40 / 16, 40) + 40) < 1e-9,
        "fully scrolled to the label tail")
T.eq(to(1.6 + 2.5 + 0.6, 40), -40, "end hold keeps the tail visible")
T.check(math.abs(to(1.6 * 2 + 2.5 + 0.25, 40) + 36) < 1e-9,
        "scrolls back at 16px/s")
T.eq(to(1.6 * 2 + 2.5 * 2 + 0.1, 40), 0, "the cycle wraps to a new hold")
T.eq(to(5, 0), 0, "a fitting label never scrolls")
T.eq(to(5, nil), 0, "nil overflow never scrolls")
T.eq(to(0, 40), to(1.6 * 2 + 2.5 * 2, 40),
     "one cycle later the label is back at the head")

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

-- stale-latch guard: ending a capture session resets every live combo and
-- virtual hold, so a partial hold from before the capture (whose release
-- the suspended tick swallowed) can never false-fire afterwards
ex.state.hotkeys[id] = { id = id, modName = "Battle Move Info",
                         pieces = { { kind = "key", name = "q" } } }
ex.setRebinds({ [id] = { pieces = { { kind = "key", name = "f6" } } } })
ex.applyRebinds()
local latch = ex.state.rebinds[id]
latch.combo.held["key:f6"] = true
latch.combo.fired = true
ex.state.virtual["r"] = true
ex.resetRebindCombos()
T.eq(next(latch.combo.held), nil, "capture reset clears stale combo holds")
T.eq(latch.combo.fired, false, "capture reset clears the fired latch")
T.eq(ex.state.virtual["r"], nil, "capture reset clears virtual key holds")
ex.setRebinds({})
ex.state.hotkeys = {}

T.finish("mods_hotkeys")
