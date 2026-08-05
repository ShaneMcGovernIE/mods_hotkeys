-- Integration: simulate the whole runtime flow against the real Game
-- module -- detection over the repo's own mod sources, a persisted
-- rebind, the game.ready wrap installation, and the key press that must
-- be translated into the original trigger.
-- Run: POKEPORT_DATA_DIR=tests/fixture_data luajit mods/mods_hotkeys/tests/mods_hotkeys_integration.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()

local run = T.sdk.loadMod("mods/mods_hotkeys", { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")
local ex = run.loader.exports.mods_hotkeys

-- --------------------------------------------------- stub the engine seam

-- The real Game module table (main.lua requires it); stub the methods the
-- mod wraps and the loader seam it reads.
local Game = require("src.core.Game")
local received = {}

Game.keypressed = function(self, key) received[#received + 1] = { "key", key } end
Game.keyreleased = function(self, key) received[#received + 1] = { "rel", key } end
Game.gamepadpressed = function(self, joy, button) received[#received + 1] = { "pad", button } end
Game.gamepadreleased = function(self, joy, button) received[#received + 1] = { "padrel", button } end

-- loader seam: reuse the real loader; detection runs over the repo's own
-- mod sources read straight off disk (love.filesystem is absent headless)
local function repoFs()
  return {
    read = function(path)
      local rel = path:match("^mods/(.+)$")
      if not rel then return nil end
      local h = io.open("mods/" .. rel, "rb")
      if not h then return nil end
      local text = h:read("*a")
      h:close()
      return text
    end,
    getDirectoryItems = function(path)
      local ls = io.popen("ls " .. path .. " 2>/dev/null"):read("*a")
      local names = {}
      for f in ls:gmatch("[^\n]+") do
        local base = f:match("([^/]+)$")
        if base then names[#names + 1] = base end
      end
      return names
    end,
  }
end
local loader = run.loader
loader.fs = repoFs()
loader.mods = loader.mods or {}
local MANIFESTS = {
  battle_move_info = { name = "Battle Move Info", entry = "main.lua" },
  bag_999 = { name = "Bag 999", entry = "main.lua" },
  game_speed_toggle = { name = "Game Speed Toggle", entry = "main.lua" },
}
for id, manifest in pairs(MANIFESTS) do
  if not loader.mods[id] then
    loader.mods[id] = { manifest = manifest,
                        enabled = true, path = "mods/" .. id }
  end
end
Game.mods = loader

-- ---------------------------------------------------------- detection

ex.applyRebinds()
local found = ex.scanMods(loader, "mods_hotkeys")
T.eq(#found >= 6, true, "detects the reference mods' hotkeys")
local qId = "battle_move_info|main.lua|key:q"
ex.state.hotkeys = {}
for _, hk in ipairs(found) do ex.state.hotkeys[hk.id] = hk end
T.neq(ex.state.hotkeys[qId], nil, "battle_move_info Q detected")

-- ---------------------------------------------------- game.ready install

-- emit game.ready exactly like the engine does (Game:load)
run.loader.events:emit("game.ready", { game = Game })
T.neq(Game._modsHotkeysInstalled, nil, "wraps installed by game.ready")
T.neq(Game.keypressed, nil, "Game.keypressed wrapped")

-- ------------------------------------------- rebind + live translation

ex.setRebinds({ [qId] = { pieces = { { kind = "key", name = "f6" } } } })
ex.applyRebinds()
T.eq(ex.state.rebinds[qId] ~= nil, true, "rebind is live")
T.eq(ex.state.rebinds[qId].original[1].name, "q", "original kept for emission")

-- the user presses F6: the wrap must re-emit the original "q" press edge
received = {}
Game.keypressed(Game, "f6")
local sawQ, sawF6 = false, false
for _, ev in ipairs(received) do
  if ev[1] == "key" and ev[2] == "q" then sawQ = true end
  if ev[1] == "key" and ev[2] == "f6" then sawF6 = true end
end
T.eq(sawQ, true, "new key re-emits the original trigger (q)")
T.eq(sawF6, true, "new key passes through to the engine")

-- release: original release edge follows
received = {}
Game.keyreleased(Game, "f6")
local sawQRel = false
for _, ev in ipairs(received) do
  if ev[1] == "rel" and ev[2] == "q" then sawQRel = true end
end
T.eq(sawQRel, true, "release re-emits the original release")

-- auto-repeat while held never re-emits
received = {}
Game.keypressed(Game, "f6")
Game.keypressed(Game, "f6")
local qCount = 0
for _, ev in ipairs(received) do
  if ev[1] == "key" and ev[2] == "q" then qCount = qCount + 1 end
end
T.eq(qCount, 1, "held auto-repeat fires the original once")

-- --------------------------------------------------- multi-piece combo

local gsId = "game_speed_toggle|main.lua|combo:back+leftshoulder"
T.neq(ex.state.hotkeys[gsId], nil, "game_speed_toggle combo detected")
ex.setRebinds({ [gsId] = { pieces = { { kind = "key", name = "g" } } } })
ex.applyRebinds()

received = {}
Game.keypressed(Game, "g")
local sawBack, sawLB = false, false
for _, ev in ipairs(received) do
  if ev[1] == "pad" and ev[2] == "back" then sawBack = true end
  if ev[1] == "pad" and ev[2] == "leftshoulder" then sawLB = true end
end
T.eq(sawBack, true, "key rebind emits the pad combo (back)")
T.eq(sawLB, true, "key rebind emits the pad combo (leftshoulder)")

received = {}
Game.keyreleased(Game, "g")
local sawBackRel, sawLBRel = false, false
for _, ev in ipairs(received) do
  if ev[1] == "padrel" and ev[2] == "back" then sawBackRel = true end
  if ev[1] == "padrel" and ev[2] == "leftshoulder" then sawLBRel = true end
end
T.eq(sawBackRel, true, "release emits both pad releases")
T.eq(sawLBRel, true, "release emits both pad releases")

-- ------------------------------------------------------- capture commit

-- drive the screen's capture methods directly (they only touch
-- self.capture/pending), simulating the raw-input routing
local Menu = require("src.ui.Screens") -- screens registry lives in the loader
local screen = run.loader.content.screens:get("ModsHotkeysMenu")
local menu = screen.new(Game, "pc")
T.eq(#menu.rows >= 3, true, "pc page lists the detected hotkeys")

-- A on a row arms the capture
local row = nil
for _, r in ipairs(menu.rows) do
  if r.id == qId then row = r break end
end
T.neq(row, nil, "Q row present")
menu:beginCapture(row)

-- press TAB, press Z (still holding), release both: SELECT + A style
menu:captureKey("tab")
menu:captureKey("z")
T.eq(#menu.pending, 2, "capture collects both pieces")
T.eq(menu.heldCount, 2, "both pieces held")
menu:captureKeyRelease("z")
T.eq(menu.heldCount, 1, "first release keeps the combo armed")
menu:captureKeyRelease("tab")
T.eq(menu.capture, nil, "capture committed on the last release")

local stored = ex.getRebinds()[qId]
T.neq(stored, nil, "capture persisted the rebind")
T.eq(stored.pieces[1].name, "tab", "first captured piece")
T.eq(stored.pieces[2].name, "z", "second captured piece")
T.eq(ex.currentTrigger(qId), "TAB×Z", "row shows the new trigger")

-- escape cancels without storing
ex.setRebinds({})
ex.applyRebinds()
menu:beginCapture(row)
menu:captureKey("tab")
menu:captureKey("escape")
T.eq(menu.capture, nil, "escape ends the capture")
T.eq(ex.getRebinds()[qId], nil, "cancelled capture stores nothing")

-- reserved engine keys are skipped, not stored
menu:beginCapture(row)
menu:captureKey("f1")
menu:captureKey("tab")
T.eq(menu.heldCount, 1, "engine key skipped during capture")
menu:captureKeyRelease("tab")

-- SELECT resets the row
menu:resetRow(row)
T.eq(ex.getRebinds()[qId], nil, "reset row drops the rebind")
T.eq(ex.currentTrigger(qId), "Q", "row falls back to the default")

-- ------------------------------------------------------- exit pops once

-- StateStack:pop calls state:exit() as a cleanup hook, so the menu's own
-- exit must never pop the stack -- a pop inside exit re-enters exit and
-- pops the OPTIONS menu underneath.  B must close the submenu exactly once.
local exitMenu = screen.new(Game, "pc")
exitMenu.game = setmetatable({}, { __index = Game })
exitMenu.game.data = nil
exitMenu.game.input = { wasPressed = function(_, btn) return btn == "b" end }
local stackStates = { { id = "OptionsMenu" }, exitMenu }
exitMenu.game.stack = {
  pop = function()
    local s = table.remove(stackStates)
    if s and s.exit then s:exit() end
    return s
  end,
}
exitMenu:update(0)
T.eq(#stackStates, 1, "B closes the submenu with a single pop")
T.eq(stackStates[1].id, "OptionsMenu", "the OPTIONS menu survives the pop")

-- -------------------------------------------------------- joyN capture

-- raw-stick buttons arrive on the joystick path, which the rebind tick
-- never wraps and emission has no channel for: capturing one would build
-- a combo that can never fire, so it is rejected like a reserved key
menu:beginCapture(row)
menu:captureJoy(1)
T.eq(#menu.pending, 0, "joyN piece is rejected, not collected")
T.neq(menu.reject, nil, "joyN rejection flashes the not-bindable message")
menu:endCapture()

-- ------------------------------------------------------ stale-latch reset

-- a capture session suspends the rebind tick; ending it must clear every
-- live combo and virtual hold so a pre-capture partial press can't
-- false-fire the instant the capture box closes
ex.state.hotkeys[qId] = { id = qId, modName = "Battle Move Info",
                          pieces = { { kind = "key", name = "q" } } }
ex.setRebinds({ [qId] = { pieces = { { kind = "key", name = "f6" } } } })
ex.applyRebinds()
local staleRb = ex.state.rebinds[qId]
staleRb.combo.held["key:f6"] = true
staleRb.combo.fired = true
ex.state.virtual["r"] = true
menu:beginCapture(row)
menu:endCapture()
T.eq(next(staleRb.combo.held), nil, "capture end clears stale combo holds")
T.eq(staleRb.combo.fired, false, "capture end clears the fired latch")
T.eq(ex.state.virtual["r"], nil, "capture end clears virtual key holds")
ex.setRebinds({})
ex.state.hotkeys = {}

-- ---------------------------------------------------- gbcfg (DexNav) path

-- a configurable-trigger mod in the loader: DexNav ships a GB-button
-- list polled through a dynamic wasPressed(helper(...)) call
local DEXNAV_SRC = [[
local DEXNAV_BUTTONS = { "select", "start", "a", "b" }
local function dexNavButton(game)
  local saved = game.save and game.save.options and game.save.options.dexNavButton
  for _, btn in ipairs(DEXNAV_BUTTONS) do
    if btn == saved then return btn end
  end
  return "select"
end
if Game.input:wasPressed(dexNavButton(Game)) and Game.save.dexNavReg then
  search()
end
]]
local repoRead = loader.fs.read
local repoItems = loader.fs.getDirectoryItems
loader.mods["DexNav"] = {
  manifest = { name = "DexNav", entry = "main.lua" },
  enabled = true, path = "mods/DexNav",
}
loader.fs = {
  read = function(path)
    if path == "mods/DexNav/main.lua" then return DEXNAV_SRC end
    return repoRead(path)
  end,
  getDirectoryItems = function(path)
    if path == "mods/DexNav" then return { "main.lua" } end
    return repoItems(path)
  end,
}
ex.state.hotkeys = {}
for _, hk in ipairs(ex.scanMods(loader, "mods_hotkeys")) do
  ex.state.hotkeys[hk.id] = hk
end
local dexId = "DexNav|main.lua|gbcfg:select"
T.neq(ex.state.hotkeys[dexId], nil, "dexnav gbcfg hotkey detected")
T.eq(ex.state.hotkeys[dexId].dynamicField, "dexNavButton",
     "gbcfg carries the save field name")

-- the canonical select binding needs the engine maps for emission
local Input = require("src.core.Input")
Input.keyBindings = { tab = "select", z = "a", x = "b", escape = "start" }
Input.padBindings = { back = "select", a = "a", b = "b", start = "start" }

-- the row shows the player's saved DexNav trigger, not the shipped default
T.eq(ex.currentTrigger(dexId), "SELECT", "no save yet -> default trigger")
Game.save = { options = { dexNavButton = "b" } }
T.eq(ex.currentTrigger(dexId), "B", "row tracks OPTIONS > DEXNAV TRIGGER")

-- rebind the DexNav row to F while the saved trigger is B: pressing F
-- must emit B's canonical binding (x), never the default select (tab)
ex.setRebinds({ [dexId] = { pieces = { { kind = "key", name = "f" } } } })
ex.applyRebinds()

received = {}
Game.keypressed(Game, "f")
local sawX, sawTab = false, false
for _, ev in ipairs(received) do
  if ev[1] == "key" and ev[2] == "x" then sawX = true end
  if ev[1] == "key" and ev[2] == "tab" then sawTab = true end
end
T.eq(sawX, true, "F re-emits the SAVED trigger (b via x)")
T.eq(sawTab, false, "F does not re-emit the default trigger (select/tab)")

-- release follows the same resolution
received = {}
Game.keyreleased(Game, "f")
local sawXRel = false
for _, ev in ipairs(received) do
  if ev[1] == "rel" and ev[2] == "x" then sawXRel = true end
end
T.eq(sawXRel, true, "release re-emits the saved trigger release")

-- no saved choice -> falls back to the default select emission
Game.save = { options = {} }
received = {}
Game.keypressed(Game, "f")
local sawTab2 = false
for _, ev in ipairs(received) do
  if ev[1] == "key" and ev[2] == "tab" then sawTab2 = true end
end
T.eq(sawTab2, true, "no saved choice -> default select (tab) emission")

T.finish("mods_hotkeys_integration")
