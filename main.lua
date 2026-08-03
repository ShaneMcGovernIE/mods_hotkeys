-- Mods Hotkeys: a OPTIONS -> MODS HOTKEYS submenu that detects the
-- hotkeys other installed mods listen for and lets the player rebind
-- them, multi-button combos included (SELECT + A, TAB + LB, ...).
--
-- Detection is static: every enabled mod's Lua sources are scanned for
-- the input idioms mods actually use --
--   key == "q"              (wrapped Game/Input:keypressed)
--   button == "leftshoulder" (wrapped Game/Input:gamepadpressed)
--   held.back and held.leftshoulder   (held pad-button combos)
--   wasPressed("select") and wasPressed("a")   (GB-button combos)
-- and each distinct trigger becomes one row in the submenu.
--
-- Rebinding is a translation layer, installed at game.ready (the lowest
-- priority, so the wrap lands OUTSIDE every other mod's input wrap):
-- when the player's new trigger fires (all its buttons held together),
-- the ORIGINAL trigger's press edges are re-emitted through the chain.
-- Pressing the new combo therefore behaves exactly as pressing the
-- original one would -- the source mod never knows the difference, and
-- the default trigger keeps working as an extra way in (the engine's
-- add-never-remove rebind philosophy, Input:applyBindings).
--
-- Rebind choices persist in options.lua's per-mod bucket
-- (loader.modOptions["mods_hotkeys"]), so they survive NEW GAME,
-- CONTINUE and quitting, exactly like QoL Toggles' switches.

local Game = require("src.core.Game")
-- required at module scope: the menu methods below (defined outside the
-- entry chunk) render through OptionRows
local OptionRows = require("src.ui.OptionRows")

-- ---------------------------------------------------------------- pure

-- short display names, same spirit as BindingsMenu's KEY_SHORT/PAD_SHORT
local SHORT = {
  escape = "ESC", ["return"] = "ENTER", kpenter = "ENTER",
  space = "SPACE", backspace = "BKSP",
  lshift = "LSHIFT", rshift = "RSHIFT",
  leftshoulder = "LB", rightshoulder = "RB",
  leftstick = "LS", rightstick = "RS",
  dpup = "D-UP", dpdown = "D-DN", dpleft = "D-LT", dpright = "D-RT",
  up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT",
  a = "A", b = "B", start = "START", select = "SELECT",
  back = "BACK", guide = "GUIDE",
}

-- a trigger piece is { kind = "key"|"pad"|"gb", name = <raw name> };
-- "gb" pieces are engine buttons (a/b/start/select/directions) that the
-- player triggers through a keyboard or pad binding
local function pieceName(p)
  local s = SHORT[p.name] or p.name:upper()
  return #s > 8 and s:sub(1, 8) or s
end

local function describe(pieces)
  local out = {}
  for _, p in ipairs(pieces or {}) do
    out[#out + 1] = pieceName(p)
  end
  return #out > 0 and table.concat(out, "+") or "--"
end

-- Scan one mod source file for hotkey idioms.  The key/button literal
-- patterns are gated on the file mentioning keypressed/gamepadpressed so
-- unrelated `spec.key == key` comparisons are never claimed as hotkeys.
local GB_BUTTONS = {
  select = true, start = true, a = true, b = true,
  up = true, down = true, left = true, right = true,
}

-- Table literals that read as GB-button trigger configs, the
-- configurable-trigger idiom (DexNav: DEXNAV_BUTTONS = { "select",
-- "start", "a", "b" } then wasPressed(dexNavButton(game))).  The
-- assignment name must read as a button config -- a random-pick array
-- like `dirs = {"up", "down", "left", "right"}` is not a trigger -- and
-- at least two literals must be Game Boy buttons.  The first is the
-- default trigger.
local function buttonLists(text)
  local lists = {}
  for name, list in text:gmatch("([%w_]+)%s*=%s*{([^{}]*)}") do
    if name:lower():find("button") then
      local count, first = 0, nil
      for lit in list:gmatch('["\'](%w+)["\']') do
        if GB_BUTTONS[lit] then
          count = count + 1
          if not first then first = lit end
        end
      end
      if count >= 2 then lists[#lists + 1] = { first = first } end
    end
  end
  return lists
end

-- wasPressed/isDown called with a non-literal argument (a helper that
-- resolves the button at runtime, the configurable-trigger idiom)
local function hasDynamicPoll(text)
  return text:find('wasPressed%(%s*[^"\']') ~= nil
      or text:find('isDown%(%s*[^"\']') ~= nil
end

local function parseSource(text)
  local out = { keys = {}, pads = {}, held = {}, gb = {},
                dynamic = false, buttonLists = {} }
  if type(text) ~= "string" then return out end
  if text:find("keypressed") then
    for lit in text:gmatch('key%s*[=~]=%s*["\'](%w+)["\']') do
      out.keys[lit] = true
    end
  end
  if text:find("gamepadpressed") then
    for lit in text:gmatch('button%s*[=~]=%s*["\'](%w+)["\']') do
      out.pads[lit] = true
    end
    for a, b in text:gmatch('held%.(%w+)%s+and%s+held%.(%w+)') do
      out.held[a] = true
      out.held[b] = true
    end
  end
  for a, b in text:gmatch('wasPressed%(%s*["\'](%w+)["\']%s*%)'
    .. '%s*and%s*[%w_.:]*wasPressed%(%s*["\'](%w+)["\']%s*%)') do
    out.gb[#out.gb + 1] = { a, b }
  end
  for a, b in text:gmatch('isDown%(%s*["\'](%w+)["\']%s*%)'
    .. '%s*and%s*[%w_.:]*isDown%(%s*["\'](%w+)["\']%s*%)') do
    out.gb[#out.gb + 1] = { a, b }
  end
  if hasDynamicPoll(text) then
    local lists = buttonLists(text)
    if #lists > 0 then
      out.dynamic = true
      out.buttonLists = lists
    end
  end
  return out
end

-- Turn scanned files ({ relPath = source }) into hotkey records.
-- A held-combo file yields one combo hotkey (its distinct pads); the
-- other idioms yield one hotkey per distinct literal.  Stable ids key the
-- persisted rebind map across boots.
local function detectFromFiles(files, modId, modName)
  local out = {}
  for rel, text in pairs(files) do
    local parsed = parseSource(text)
    for lit in pairs(parsed.keys) do
      out[#out + 1] = {
        id = ("%s|%s|key:%s"):format(modId, rel, lit),
        modId = modId, modName = modName,
        pieces = { { kind = "key", name = lit } },
      }
    end
    local heldList = {}
    for lit in pairs(parsed.held) do heldList[#heldList + 1] = lit end
    if #heldList > 0 then
      table.sort(heldList)
      local pieces = {}
      for _, lit in ipairs(heldList) do
        pieces[#pieces + 1] = { kind = "pad", name = lit }
      end
      out[#out + 1] = {
        id = ("%s|%s|combo:%s"):format(modId, rel,
          table.concat(heldList, "+")),
        modId = modId, modName = modName, pieces = pieces,
      }
    else
      for lit in pairs(parsed.pads) do
        out[#out + 1] = {
          id = ("%s|%s|pad:%s"):format(modId, rel, lit),
          modId = modId, modName = modName,
          pieces = { { kind = "pad", name = lit } },
        }
      end
    end
    for _, pair in ipairs(parsed.gb) do
      out[#out + 1] = {
        id = ("%s|%s|gb:%s+%s"):format(modId, rel, pair[1], pair[2]),
        modId = modId, modName = modName,
        pieces = { { kind = "gb", name = pair[1] },
                   { kind = "gb", name = pair[2] } },
      }
    end
    -- configurable triggers: a GB-button list polled through a dynamic
    -- wasPressed/isDown; the list's first button is the default trigger
    if parsed.dynamic then
      for _, list in ipairs(parsed.buttonLists) do
        out[#out + 1] = {
          id = ("%s|%s|gbcfg:%s"):format(modId, rel, list.first),
          modId = modId, modName = modName,
          pieces = { { kind = "gb", name = list.first } },
        }
      end
    end
  end
  return out
end

-- Read every Lua source a mod ships (entry + top-level files; tests are
-- not gameplay code and never scanned).
local function readLuaFiles(fs, path, entry)
  local files = {}
  if not (fs and fs.read) then return files end
  local names = {}
  if entry then names[#names + 1] = entry end
  if fs.getDirectoryItems then
    for _, name in ipairs(fs.getDirectoryItems(path) or {}) do
      if name:match("%.lua$") and not name:match("test") then
        names[#names + 1] = name
      end
    end
  end
  local seen = {}
  for _, name in ipairs(names) do
    if not seen[name] then
      seen[name] = true
      local text = fs.read(path .. "/" .. name)
      if type(text) == "string" then files[name] = text end
    end
  end
  return files
end

-- Detect hotkeys across every enabled, non-failed mod except ourselves.
-- `loader` is the Loader (Game.mods): .mods = { id -> {manifest, path,
-- enabled, failed} }, .fs = love.filesystem or a test stub.
local function scanMods(loader, selfId)
  local out = {}
  if not (loader and loader.mods) then return out end
  for id, mod in pairs(loader.mods) do
    if id ~= selfId and mod.enabled ~= false and not mod.failed then
      local files = readLuaFiles(loader.fs, mod.path, mod.manifest.entry)
      if next(files) then
        for _, hk in ipairs(detectFromFiles(files, id,
                                            mod.manifest.name or id)) do
          out[#out + 1] = hk
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.modName == b.modName then return a.id < b.id end
    return a.modName < b.modName
  end)
  return out
end

-- The combo state machine: pieces are {kind,name}; feed it one input
-- event ({kind,name,pressed}) per press/release edge; "fire" transitions
-- the first time every piece is held together, "break" when any piece
-- releases.  Auto-repeat presses while held never refire.
local function comboState(pieces)
  local key = {}
  for _, p in ipairs(pieces) do key[p.kind .. ":" .. p.name] = true end
  return { key = key, held = {}, fired = false }
end

local function comboStep(s, ev)
  local id = ev.kind .. ":" .. ev.name
  if not s.key[id] then return s, nil end
  if ev.pressed then s.held[id] = true else s.held[id] = nil end
  local complete = true
  for k in pairs(s.key) do
    if not s.held[k] then complete = false break end
  end
  if complete and not s.fired then
    s.fired = true
    return s, "fire"
  end
  if not complete and s.fired then
    s.fired = false
    return s, "break"
  end
  return s, nil
end

-- Preferred key/pad per engine button, in BindingsMenu's default order.
-- canonicalFor consults the LIVE maps (Input.keyBindings / padBindings)
-- so a rebound engine binding is honoured.
local KEY_PREF = {
  select = "tab", a = "z", b = "x", start = "escape",
  up = "up", down = "down", left = "left", right = "right",
}
local PAD_PREF = {
  select = "back", a = "a", b = "b", start = "start",
  up = "dpup", down = "dpdown", left = "dpleft", right = "dpright",
}

local function canonicalFor(button, keyBindings, padBindings)
  if keyBindings then
    local pref = KEY_PREF[button]
    if pref and keyBindings[pref] == button then
      return { kind = "key", name = pref }
    end
    for k, act in pairs(keyBindings) do
      if act == button then return { kind = "key", name = k } end
    end
  end
  if padBindings then
    local pref = PAD_PREF[button]
    if pref and padBindings[pref] == button then
      return { kind = "pad", name = pref }
    end
    for p, act in pairs(padBindings) do
      if act == button then return { kind = "pad", name = p } end
    end
  end
  return nil
end

-- ------------------------------------------------------------ runtime

local state = {
  hotkeys = {},   -- detected hotkeys by id (built at game.ready)
  rebinds = {},   -- live: id -> { pieces, combo, original }
  capturing = false, -- the rebind capture owns raw input
}
local lastJoy = nil -- most recent real joystick, for pad emissions

local function loader()
  return Game.mods
end

local MOD_ID = "mods_hotkeys"

local function getRebinds()
  local l = loader()
  local bucket = l and l.modOptions and l.modOptions[MOD_ID]
  return (bucket and bucket.rebinds) or {}
end

local function setRebinds(map)
  local l = loader()
  if not l then return end
  l.modOptions = l.modOptions or {}
  l.modOptions[MOD_ID] = l.modOptions[MOD_ID] or {}
  l.modOptions[MOD_ID].rebinds = map
  if Game.save and Game.save.options then
    Game.save.options.modOptions = Game.save.options.modOptions or {}
    Game.save.options.modOptions[MOD_ID] =
      Game.save.options.modOptions[MOD_ID] or {}
    Game.save.options.modOptions[MOD_ID].rebinds = map
  end
  if Game.writeOptions then Game:writeOptions() end
end

-- The current trigger for a hotkey row: the rebind if one exists, else
-- the detected default.
local function currentTrigger(id)
  local rb = state.rebinds[id]
  if rb then return describe(rb.pieces) end
  local hk = state.hotkeys[id]
  return hk and describe(hk.pieces) or "--"
end

-- Fold the persisted rebind map into live combo machines.
local function applyRebinds()
  local live = {}
  for id, rec in pairs(getRebinds()) do
    local hk = state.hotkeys[id]
    if hk and type(rec) == "table" and type(rec.pieces) == "table"
        and #rec.pieces > 0 then
      local pieces = {}
      for _, p in ipairs(rec.pieces) do
        if p and p.kind and p.name then
          pieces[#pieces + 1] = { kind = p.kind, name = p.name }
        end
      end
      if #pieces > 0 then
        live[id] = { pieces = pieces, combo = comboState(pieces),
                     original = hk.pieces }
      end
    end
  end
  state.rebinds = live
end

-- --------------------------------------------------------- the screen

-- Keys the engine consumes before Input (Game:keypressed) are not
-- bindable: a combo that fired one would also quicksave, cycle colours or
-- open the mod manager.  Escape stays the capture's cancel key.
local RESERVED_KEYS = {
  ["f1"] = true, ["f2"] = true, ["f5"] = true, ["f10"] = true,
  ["`"] = true, ["2"] = true, ["3"] = true, ["4"] = true, ["5"] = true,
  ["-"] = true, ["="] = true, escape = true,
}

local function isBindable(kind, name)
  if kind == "key" then return RESERVED_KEYS[name] == nil end
  return true -- pad buttons never reach Game:keypressed
end

local ModsHotkeysMenu = {}
ModsHotkeysMenu.__index = ModsHotkeysMenu
ModsHotkeysMenu.isOpaque = true
ModsHotkeysMenu.MAX_PIECES = 4

function ModsHotkeysMenu:sgbPalettes(game)
  return require("src.render.PaletteFX").wholeNamed(game.data, "MEWMON")
end

function ModsHotkeysMenu:exit()
  if self.game.data then
    require("src.core.Sound").play(self.game.data, "Press_AB")
  end
  self.game.stack:pop()
  if self.onCancel then self.onCancel() end
end

function ModsHotkeysMenu:update(dt)
  if self.capture then return end -- the raw capture owns the input
  local input = self.game.input
  if input:wasPressed("start") then
    return self:confirmResetAll()
  end
  local rows = self.rows
  local cancelRow = #rows + 1
  if input:wasPressed("up") then
    self.index = self.index > 1 and self.index - 1 or cancelRow
  elseif input:wasPressed("down") then
    self.index = self.index < cancelRow and self.index + 1 or 1
  elseif input:wasPressed("select") then
    local row = rows[self.index]
    if row then self:resetRow(row) end
  elseif input:wasPressed("a") then
    local row = rows[self.index]
    if row then
      self:beginCapture(row)
    else -- the CANCEL row
      self:exit()
    end
  elseif input:wasPressed("b") then
    self:exit()
  end
  self.scroll = OptionRows.clampScroll(self.index, self.scroll or 0,
                                       #rows, cancelRow)
end

function ModsHotkeysMenu:draw()
  OptionRows.draw(self.game, self.rows, self.index, self.scroll or 0,
                  "CANCEL", #self.rows + 1)
  if self.capture then
    local Font = require("src.render.Font")
    Font.drawBox(1, 5, 18, 7)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw("PRESS A COMBO", 24, 48)
    Font.draw("RELEASE TO SET", 24, 60)
    Font.draw("ESC CANCELS", 24, 72)
    Font.draw("ENGINE KEYS N/A", 24, 84)
    local live = describe(self.pending or {})
    if live ~= "--" then Font.draw(live, 24, 96) end
    love.graphics.setColor(1, 1, 1, 1)
  end
end

-- capture: pieces collect while held (up to MAX_PIECES); the bind
-- commits when every held piece has been released, so SELECT + A is
-- "press SELECT, press A, release both".  Escape cancels.
function ModsHotkeysMenu:beginCapture(row)
  self.capture = row
  self.pending = {}
  self.heldCount = 0
  state.capturing = true
  self.onKeyPressed = ModsHotkeysMenu.captureKey
  self.onGamepadPressed = ModsHotkeysMenu.capturePad
  self.onJoystickPressed = ModsHotkeysMenu.captureJoy
  self.onKeyReleased = ModsHotkeysMenu.captureKeyRelease
  self.onGamepadReleased = ModsHotkeysMenu.capturePadRelease
  self.onJoystickReleased = ModsHotkeysMenu.captureJoyRelease
end

function ModsHotkeysMenu:endCapture()
  self.capture = nil
  self.pending = nil
  self.heldCount = nil
  state.capturing = false
  self.onKeyPressed = nil
  self.onGamepadPressed = nil
  self.onJoystickPressed = nil
  self.onKeyReleased = nil
  self.onGamepadReleased = nil
  self.onJoystickReleased = nil
end

function ModsHotkeysMenu:addPiece(kind, name)
  if not self.capture or self.heldCount >= ModsHotkeysMenu.MAX_PIECES
      then return end
  for _, p in ipairs(self.pending) do
    if p.kind == kind and p.name == name then return end -- held repeat
  end
  self.pending[#self.pending + 1] = { kind = kind, name = name }
  self.heldCount = self.heldCount + 1
end

function ModsHotkeysMenu:dropPiece(kind, name)
  if not self.capture then return end
  for _, p in ipairs(self.pending) do
    if p.kind == kind and p.name == name then
      self.heldCount = self.heldCount - 1
      if self.heldCount <= 0 then
        -- every held piece is released: commit the whole combo while
        -- self.pending still holds every captured piece (endCapture
        -- clears the field inside commitCapture)
        self:commitCapture(self.pending)
      end
      return
    end
  end
end

function ModsHotkeysMenu:captureKey(key)
  if key == "escape" then return self:endCapture() end
  if not isBindable("key", key) then return end
  self:addPiece("key", key)
end

function ModsHotkeysMenu:capturePad(button)
  self:addPiece("pad", button)
end

function ModsHotkeysMenu:captureJoy(button)
  self:addPiece("pad", "joy" .. button)
end

function ModsHotkeysMenu:captureKeyRelease(key)
  self:dropPiece("key", key)
end

function ModsHotkeysMenu:capturePadRelease(button)
  self:dropPiece("pad", button)
end

function ModsHotkeysMenu:captureJoyRelease(button)
  self:dropPiece("pad", "joy" .. button)
end

function ModsHotkeysMenu:commitCapture(pieces)
  local row = self.capture
  pieces = pieces or {}
  self:endCapture()
  if not row or #pieces == 0 then return end
  local map = getRebinds()
  map[row.hotkey.id] = { pieces = pieces }
  setRebinds(map)
  applyRebinds()
  row.value = function() return currentTrigger(row.hotkey.id) end
end

function ModsHotkeysMenu:resetRow(row)
  local map = getRebinds()
  if map[row.hotkey.id] then
    map[row.hotkey.id] = nil
    setRebinds(map)
    applyRebinds()
    row.value = function() return currentTrigger(row.hotkey.id) end
  end
end

function ModsHotkeysMenu:confirmResetAll()
  local ChoiceBox = require("src.ui.ChoiceBox")
  self.game.stack:push(ChoiceBox.new(self.game, function(yes)
    if not yes then return end
    setRebinds({})
    applyRebinds()
    for _, row in ipairs(self.rows) do
      row.value = function() return currentTrigger(row.hotkey.id) end
    end
  end, { defaultNo = true }))
end

-- ----------------------------------------------------------- the mod

return function(mod)
  local Strings = require("src.core.Strings")

  mod.content.screens:register("ModsHotkeysMenu", { new = function(game)
    local rows = {}
    local ids = {}
    for id in pairs(state.hotkeys) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local hk = state.hotkeys[id]
      rows[#rows + 1] = {
        id = id,
        label = Strings(hk.modName),
        value = function() return currentTrigger(id) end,
        hotkey = hk,
      }
    end
    return setmetatable({
      game = game,
      rows = rows,
      index = 1, scroll = 0,
    }, ModsHotkeysMenu)
  end })

  mod.hooks:wrap("ui.options.rows", function(next, game, rows)
    rows = next(game, rows)
    rows[#rows + 1] = {
      id = "modsHotkeys",
      label = Strings("MODS HOTKEYS"),
      value = function()
        local n = 0
        for _ in pairs(state.hotkeys) do n = n + 1 end
        return Strings("%d HOTKEYS", n)
      end,
      activate = function(g)
        require("src.ui.Screens").push(g, "ModsHotkeysMenu")
      end,
    }
    return rows
  end)

  -- game.ready at the lowest priority runs LAST among listeners, so the
  -- input wraps installed here sit OUTSIDE every other mod's wrap.
  mod.events:on("game.ready", function()
    local detected = scanMods(loader(), MOD_ID)
    state.hotkeys = {}
    for _, hk in ipairs(detected) do state.hotkeys[hk.id] = hk end
    applyRebinds()

    if Game._modsHotkeysInstalled then return end
    Game._modsHotkeysInstalled = true

    local Input = require("src.core.Input")
    local vKey, vKeyRel = Game.keypressed, Game.keyreleased
    local vPad, vPadRel = Game.gamepadpressed, Game.gamepadreleased

    -- Re-emit one trigger's edges (press or release) through the chain.
    local function emit(pieces, keyFn, padFn, joy)
      for _, p in ipairs(pieces) do
        if p.kind == "key" then
          keyFn(p.name)
        elseif p.kind == "pad" then
          padFn(joy, p.name)
        elseif p.kind == "gb" then
          local c = canonicalFor(p.name, Input.keyBindings, Input.padBindings)
          if c then
            if c.kind == "key" then keyFn(c.name) else padFn(joy, c.name) end
          end
        end
      end
    end

    local function tick(ev, pKey, pPad, rKey, rPad, joy)
      if state.capturing then return end
      for _, rb in pairs(state.rebinds) do
        local _, tr = comboStep(rb.combo, ev)
        if tr == "fire" then
          emit(rb.original, pKey, pPad, joy)
        elseif tr == "break" then
          emit(rb.original, rKey, rPad, joy)
        end
      end
    end

    Game.keypressed = function(self, key)
      tick({ kind = "key", name = key, pressed = true },
        function(k) vKey(self, k) end,
        function(j, b) vPad(self, j, b) end,
        function(k) vKeyRel(self, k) end,
        function(j, b) vPadRel(self, j, b) end,
        lastJoy)
      return vKey(self, key)
    end

    Game.keyreleased = function(self, key)
      tick({ kind = "key", name = key, pressed = false },
        function(k) vKey(self, k) end,
        function(j, b) vPad(self, j, b) end,
        function(k) vKeyRel(self, k) end,
        function(j, b) vPadRel(self, j, b) end,
        lastJoy)
      return vKeyRel(self, key)
    end

    Game.gamepadpressed = function(self, joystick, button)
      if joystick then lastJoy = joystick end
      tick({ kind = "pad", name = button, pressed = true },
        function(k) vKey(self, k) end,
        function(j, b) vPad(self, j, b) end,
        function(k) vKeyRel(self, k) end,
        function(j, b) vPadRel(self, j, b) end,
        joystick)
      return vPad(self, joystick, button)
    end

    Game.gamepadreleased = function(self, joystick, button)
      if joystick then lastJoy = joystick end
      tick({ kind = "pad", name = button, pressed = false },
        function(k) vKey(self, k) end,
        function(j, b) vPad(self, j, b) end,
        function(k) vKeyRel(self, k) end,
        function(j, b) vPadRel(self, j, b) end,
        joystick)
      return vPadRel(self, joystick, button)
    end
  end, -100000)

  mod.exports = {
    parseSource = parseSource,
    detectFromFiles = detectFromFiles,
    scanMods = scanMods,
    describe = describe,
    isBindable = isBindable,
    comboState = comboState,
    comboStep = comboStep,
    canonicalFor = canonicalFor,
    getRebinds = getRebinds,
    setRebinds = setRebinds,
    currentTrigger = currentTrigger,
    applyRebinds = applyRebinds,
    state = state,
  }
end
