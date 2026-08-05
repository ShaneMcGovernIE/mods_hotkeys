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
--   queued(input, "select") / input.state.select  (pressQueue polling)
--   love.keyboard.isDown(key) with an edge latch   (direct keyboard polls,
--     e.g. Dex Radar's HOTKEY read from mod.options:get)
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
local Font = require("src.render.Font")

-- ---------------------------------------------------------------- pure

-- Ticker pacing (the MoveRelearn name ticker's): hold at each end so the
-- player can read the whole name, scroll at 16px/s (half a second per
-- glyph).
local TICKER_HOLD = 1.6
local TICKER_SPEED = 16

-- Pure (mod.exports.tickerOffset for headless tests): horizontal offset
-- for an overflowing label at time t (seconds).  Cycle: hold at 0, scroll
-- out to -overflow, hold, scroll back to 0.  Labels that fit (overflow <=
-- 0) are static.
local function tickerOffset(t, overflow)
  if not (overflow and overflow > 0) then return 0 end
  local scroll = overflow / TICKER_SPEED
  local cycle = 2 * TICKER_HOLD + 2 * scroll
  local p = t % cycle
  if p < TICKER_HOLD then return 0 end
  p = p - TICKER_HOLD
  if p < scroll then return -p * TICKER_SPEED end
  p = p - scroll
  if p < TICKER_HOLD then return -overflow end
  p = p - TICKER_HOLD
  return -overflow + p * TICKER_SPEED
end

-- Label geometry for OptionRows rows: labels start at x=16 (OptionRows.draw)
-- and the engine's text convention pads 8px inside the box, so a label
-- clips at the inner right edge 152.  The GB font is a flat 8px/glyph, so
-- the window is 136px = 17 glyphs.  Labels wider than that ticker.
local LABEL_X = 16
local LABEL_CLIP_W = 152 - LABEL_X

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

-- Join with the multiply glyph: the charmap has no ASCII "+" (it would
-- render as a blank tile), and "×" is the vanilla separator idiom (the
-- bag's POTION ×12).  describe output is what the rows and the capture
-- box draw.
local function describe(pieces)
  local out = {}
  for _, p in ipairs(pieces or {}) do
    out[#out + 1] = pieceName(p)
  end
  return #out > 0 and table.concat(out, "×") or "--"
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
      local count, first, buttons = 0, nil, {}
      for lit in list:gmatch('["\'](%w+)["\']') do
        if GB_BUTTONS[lit] then
          count = count + 1
          if not first then first = lit end
          buttons[lit] = true
        end
      end
      if count >= 2 then
        lists[#lists + 1] = { first = first, buttons = buttons }
      end
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

-- The polled helper's name (dexNavButton in the DexNav idiom); the mod
-- stores its chosen trigger in the save under the same name
-- (save.options.dexNavButton), which the rebind layer re-reads live.
local function dynamicFieldName(text)
  return text:match('wasPressed%(%s*([%w_]+)%(')
      or text:match('isDown%(%s*([%w_]+)%(')
end

local function parseSource(text)
  local out = { keys = {}, pads = {}, held = {}, gb = {}, gbSingles = {},
                dynamic = false, buttonLists = {}, pollKeys = {},
                pollField = nil, pollDefault = nil }
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
  -- The state+queue polling idiom (Quick Select): a helper that checks a
  -- GB-button literal against input.pressQueue, and direct input.state.<b>
  -- reads.  Gated on pressQueue so ordinary movement state reads are never
  -- claimed as hotkeys; the set dedupes both forms of the same button.
  if text:find("pressQueue") then
    for lit in text:gmatch('%(%s*input%s*,%s*["\'](%w+)["\']%)') do
      if GB_BUTTONS[lit] then out.gbSingles[lit] = true end
    end
    for lit in text:gmatch('input%.state%.(%w+)') do
      if GB_BUTTONS[lit] then out.gbSingles[lit] = true end
    end
  end
  -- The direct keyboard-poll idiom (Dex Radar): a hotkey read straight
  -- off love.keyboard.isDown inside an input.step wrap, with an edge
  -- latch (`down and not keyWasDown`) so it fires once per press.  Gated
  -- on both the poll and the latch, so ordinary keyboard-state reads
  -- (hold-to-run and the like) are never claimed.  A literal poll yields
  -- one key hotkey; a dynamic poll (`local key = mod.options:get(...)`)
  -- yields a configurable one whose current key is read back from the
  -- loader's modOptions bucket, exactly where mod.options:get reads it.
  if text:find("love%.keyboard%.isDown") and text:find("down%s+and%s+not") then
    for lit in text:gmatch('love%.keyboard%.isDown%s*%(%s*["\'](%w+)["\']%s*%)') do
      out.pollKeys[lit] = true
    end
    local arg = text:match('love%.keyboard%.isDown%s*%(%s*([%w_]+)%s*%)')
    if arg and not out.pollKeys[arg] then
      -- the polled variable's own options assignment, so an unrelated
      -- earlier `x = mod.options:get(...)` is never claimed
      local field = text:match(arg
        .. '%s*=%s*mod%.options:get%s*%(%s*["\']([%w_]+)["\']%s*%)')
      if field then
        out.pollField = field
        -- the schema row's default (`default = "r"`) is the row's default
        -- trigger; `.-` crosses the row's other keys (type/label/choices)
        out.pollDefault = text:match('key%s*=%s*["\']'
          .. field .. '["\']%s*,.-default%s*=%s*["\'](%w+)["\']')
      end
    end
  end
  if hasDynamicPoll(text) then
    local lists = buttonLists(text)
    if #lists > 0 then
      out.dynamic = true
      out.dynamicField = dynamicFieldName(text)
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
  local function record(rel, kind, pieces, extra)
    local r = { id = ("%s|%s|%s"):format(modId, rel, kind),
                modId = modId, modName = modName, pieces = pieces }
    if extra then
      for k, v in pairs(extra) do r[k] = v end
    end
    return r
  end
  for rel, text in pairs(files) do
    local parsed = parseSource(text)
    for lit in pairs(parsed.keys) do
      out[#out + 1] = record(rel, "key:" .. lit,
        { { kind = "key", name = lit } })
    end
    local heldList = {}
    for lit in pairs(parsed.held) do heldList[#heldList + 1] = lit end
    if #heldList > 0 then
      table.sort(heldList)
      local pieces = {}
      for _, lit in ipairs(heldList) do
        pieces[#pieces + 1] = { kind = "pad", name = lit }
      end
      out[#out + 1] = record(rel, "combo:" .. table.concat(heldList, "+"),
        pieces)
    else
      for lit in pairs(parsed.pads) do
        out[#out + 1] = record(rel, "pad:" .. lit,
          { { kind = "pad", name = lit } })
      end
    end
    for _, pair in ipairs(parsed.gb) do
      out[#out + 1] = record(rel, ("gb:%s+%s"):format(pair[1], pair[2]),
        { { kind = "gb", name = pair[1] },
          { kind = "gb", name = pair[2] } })
    end
    -- single-button state/queue polls (Quick Select style): one hotkey
    -- per GB button the file reads straight off Input
    for lit in pairs(parsed.gbSingles) do
      out[#out + 1] = record(rel, "gb:" .. lit,
        { { kind = "gb", name = lit } })
    end
    -- keyboard polls (Dex Radar style): literal polls are plain key
    -- hotkeys marked poll -- the rebind holds the key virtually, since
    -- the source mod reads love.keyboard.isDown, not the input chain;
    -- the configurable poll carries its options field + schema default
    for lit in pairs(parsed.pollKeys) do
      out[#out + 1] = record(rel, "keypoll:" .. lit,
        { { kind = "key", name = lit } }, { poll = true })
    end
    if parsed.pollField and parsed.pollDefault then
      out[#out + 1] = record(rel, "keypoll:" .. parsed.pollField,
        { { kind = "key", name = parsed.pollDefault } },
        { poll = true, pollField = parsed.pollField,
          pollDefault = parsed.pollDefault })
    end
    -- configurable triggers: a GB-button list polled through a dynamic
    -- wasPressed/isDown; the list's first button is the default trigger,
    -- and dynamicField/buttons let the rebind layer re-read the player's
    -- current choice (save.options.<field>) at emission time
    if parsed.dynamic then
      for _, list in ipairs(parsed.buttonLists) do
        out[#out + 1] = record(rel, "gbcfg:" .. list.first,
          { { kind = "gb", name = list.first } },
          { dynamicField = parsed.dynamicField, buttons = list.buttons })
      end
    end
  end
  return out
end

-- The page a hotkey row belongs to, fixed by its DEFAULT trigger so a
-- rebind never shuffles rows between pages: any pad piece means the
-- player drives it from a controller, everything else (keyboard keys
-- and GB buttons) is the PC page.  The value column always shows the
-- current trigger wherever the row sits.
local function hotkeyPage(pieces)
  for _, p in ipairs(pieces or {}) do
    if p.kind == "pad" then return "controller" end
  end
  return "pc"
end

-- The engine's built-in game-speed hotkeys (upstream Game:_cycleSpeed:
-- keyboard 1 cycles faster; the L2/R2 bumpers slow down / speed up).
-- scanMods never sees them (they are engine code, not mod sources), so
-- they register explicitly.  Stable ids keep persisted rebinds alive
-- across boots; the guard means an engine without the feature (older
-- builds) simply contributes no rows.  Rebinding works like any mod
-- row: the new combo re-emits the original trigger (e.g. a rebound
-- GAME SPEED UP fires rightshoulder through Game.gamepadpressed).
local function engineHotkeys(game)
  local G = game or Game
  if type(G._cycleSpeed) ~= "function" then return {} end
  return {
    { id = "engine|builtin|speed:up", modId = "engine", modName = "ENGINE",
      label = "SPEED UP",
      pieces = { { kind = "pad", name = "rightshoulder" } } },
    { id = "engine|builtin|speed:down", modId = "engine", modName = "ENGINE",
      label = "SPEED DOWN",
      pieces = { { kind = "pad", name = "leftshoulder" } } },
    { id = "engine|builtin|speed:up:kb", modId = "engine", modName = "ENGINE",
      label = "SPEED UP",
      pieces = { { kind = "key", name = "1" } } },
  }
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

-- The LIVE trigger of a configurable (gbcfg) hotkey: the source mod's
-- own saved choice -- save.options.<dynamicField>, read at emission time
-- because the real save only exists after save.loaded -- when it is one
-- of the buttons that mod listens for, else the default (list first).
-- DexNav writes OPTIONS > DEXNAV TRIGGER to save.options.dexNavButton and
-- polls it through dexNavButton(game); the resolution mirrors that
-- helper's own validation so a rebind emits the button DexNav is actually
-- listening for, not the one it ships with.
local function resolveGBConfig(hk)
  local save = Game.save and Game.save.options
  local saved = save and save[hk.dynamicField]
  if type(saved) == "string" and hk.buttons and hk.buttons[saved] then
    return { { kind = "gb", name = saved } }
  end
  return nil
end

-- The LIVE key a keyboard-poll hotkey polls: the source mod's own choice
-- -- loader.modOptions[modId][field], the exact bucket mod.options:get
-- reads -- else its schema default, else the default captured at scan
-- time.  "off" (Dex Radar's disable value) resolves to the default: the
-- source mod short-circuits before polling anyway, so a rebind can never
-- resurrect a disabled hotkey.
local function loader()
  return Game.mods
end

local function resolvePollKey(hk)
  local l = loader()
  local bucket = l and l.modOptions and l.modOptions[hk.modId]
  local v = bucket and bucket[hk.pollField]
  if type(v) == "string" and v ~= "off" then return v end
  for _, row in ipairs(l and l.optionSchemas
      and l.optionSchemas[hk.modId] or {}) do
    if row.key == hk.pollField then
      local d = row.default
      if type(d) == "string" and d ~= "off" then return d end
    end
  end
  return hk.pollDefault
end

-- The pieces a rebind must re-emit: for gbcfg hotkeys the player's
-- current button choice, otherwise the detected default.
local function originalPieces(rb)
  if rb.dynamicField then
    local resolved = resolveGBConfig(rb)
    if resolved then return resolved end
  end
  return rb.original
end

-- ------------------------------------------------------------ runtime

local state = {
  hotkeys = {},   -- detected hotkeys by id (built at game.ready)
  rebinds = {},   -- live: id -> { pieces, combo, original }
  capturing = false, -- the rebind capture owns raw input
  virtual = {},   -- keys held virtually for keyboard-poll hotkeys
}
local lastJoy = nil -- most recent real joystick, for pad emissions

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
-- the live configurable trigger (gbcfg) or the detected default.
local function currentTrigger(id)
  local rb = state.rebinds[id]
  if rb then return describe(rb.pieces) end
  local hk = state.hotkeys[id]
  if not hk then return "--" end
  if hk.dynamicField then
    local resolved = resolveGBConfig(hk)
    if resolved then return describe(resolved) end
  end
  if hk.pollField then
    local k = resolvePollKey(hk)
    if k then return describe({ { kind = "key", name = k } }) end
  end
  return describe(hk.pieces)
end

-- Row value for the OptionRows viewport: the value line starts 24px in
-- and must end before the 160px box edge, so a long 4-piece combo is
-- capped with a trailing "+" instead of clipping mid-glyph.
local function rowValue(id)
  local t = currentTrigger(id)
  if #t > 15 then t = t:sub(1, 14) .. "+" end
  return t
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
                     original = hk.pieces,
                     dynamicField = hk.dynamicField,
                     buttons = hk.buttons,
                     poll = hk.poll, pollField = hk.pollField,
                     pollDefault = hk.pollDefault,
                     modId = hk.modId }
      end
    end
  end
  state.rebinds = live
end

-- A capture session suspends the rebind tick, so press/release edges that
-- land while it is open never reach the combo machines.  Clearing every
-- live combo on the way out stops two stale-latch bugs: a piece held
-- before the capture (its release swallowed by the suspended tick) can no
-- longer make the next partial press false-fire, and a poll hotkey's
-- virtual hold released during the capture can no longer stay stuck down.
local function resetRebindCombos()
  for _, rb in pairs(state.rebinds) do
    rb.combo.held = {}
    rb.combo.fired = false
  end
  state.virtual = {}
end

-- --------------------------------------------------------- the screen

-- Keys the engine consumes before Input (Game:keypressed) are not
-- bindable: a combo that fired one would also cycle speed or colours,
-- quicksave or open the mod manager.  Escape stays the capture's
-- cancel key.
local RESERVED_KEYS = {
  ["1"] = true, ["2"] = true, ["3"] = true, ["4"] = true, ["5"] = true,
  ["f1"] = true, ["f2"] = true, ["f5"] = true, ["f10"] = true,
  ["`"] = true, ["-"] = true, ["="] = true, escape = true,
}

local function isBindable(kind, name)
  if kind == "key" then return RESERVED_KEYS[name] == nil end
  -- raw-stick buttons ("joyN") arrive on the joystick path, which the
  -- rebind tick never wraps and emission has no channel for -- a combo
  -- holding one could never fire, so it is rejected like a reserved key
  if name and name:match("^joy%d+$") then return false end
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
  -- StateStack:pop calls state:exit() as a cleanup hook, so exit must never
  -- pop the stack itself: a pop here would re-enter exit() through the
  -- stack and pop the state underneath (the OPTIONS menu).  The handlers
  -- pop first; this only plays the sound and runs the caller's onCancel.
  if self.game.data then
    require("src.core.Sound").play(self.game.data, "Press_AB")
  end
  if self.onCancel then self.onCancel() end
end

function ModsHotkeysMenu:update(dt)
  -- advance the label tickers (the OptionRows.draw wrap reads row.tick)
  for _, row in ipairs(self.rows or {}) do
    if row.ticker then row.tick = (row.tick or 0) + (dt or 0) end
  end
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
      self.game.stack:pop() -- StateStack calls exit() (sound + onCancel)
    end
  elseif input:wasPressed("b") then
    self.game.stack:pop() -- StateStack calls exit() (sound + onCancel)
  end
  self.scroll = OptionRows.clampScroll(self.index, self.scroll or 0,
                                       #rows, cancelRow)
end

function ModsHotkeysMenu:draw()
  OptionRows.draw(self.game, self.rows, self.index, self.scroll or 0,
                  "CANCEL", #self.rows + 1)
  if self.capture then
    local Font = require("src.render.Font")
    -- full-screen white pass first: the capture boxes sit over the
    -- options list, and without this the underlying rows peek through
    -- the seams and look like clipped text
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 0, 0, 160, 144)
    -- instruction box (0,2,20,5): border rows y=16 and y=48, interior
    -- glyph rows at y=24/32/40 -- every line must live on an interior
    -- row or it collides with the border
    Font.drawBox(0, 2, 20, 5)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw("PRESS A COMBO", 24, 24)
    Font.draw("RELEASE TO SET", 24, 32)
    Font.draw("ESC CANCELS", 24, 40)
    -- the live combo gets its own box, centered (border rows y=72/120,
    -- interior rows y=80..112)
    Font.drawBox(0, 9, 20, 6)
    local label = describe(self.pending or {})
    if label ~= "--" then
      if #label > 18 then label = label:sub(1, 17) .. "+" end
      Font.draw(label, math.floor((160 - Font.width(label)) / 2), 80)
    end
    if self.reject and love.timer.getTime() < self.reject["until"] then
      local msg = self.reject.key .. " NOT BINDABLE"
      Font.draw(msg, math.floor((160 - Font.width(msg)) / 2), 96)
    end
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
  self.reject = nil
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
  self.reject = nil
  state.capturing = false
  resetRebindCombos()
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
  if not isBindable("key", key) then
    self.reject = { key = key:upper(),
                    ["until"] = love.timer.getTime() + 1.2 }
    return
  end
  self:addPiece("key", key)
end

function ModsHotkeysMenu:capturePad(button)
  self:addPiece("pad", button)
end

function ModsHotkeysMenu:captureJoy(button)
  local name = "joy" .. button
  if not isBindable("pad", name) then
    self.reject = { key = name:upper(),
                    ["until"] = love.timer.getTime() + 1.2 }
    return
  end
  self:addPiece("pad", name)
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
  row.value = function() return rowValue(row.hotkey.id) end
end

function ModsHotkeysMenu:resetRow(row)
  local map = getRebinds()
  if map[row.hotkey.id] then
    map[row.hotkey.id] = nil
    setRebinds(map)
    applyRebinds()
    row.value = function() return rowValue(row.hotkey.id) end
  end
end

function ModsHotkeysMenu:confirmResetAll()
  local ChoiceBox = require("src.ui.ChoiceBox")
  self.game.stack:push(ChoiceBox.new(self.game, function(yes)
    if not yes then return end
    setRebinds({})
    applyRebinds()
    for _, row in ipairs(self.rows) do
      row.value = function() return rowValue(row.hotkey.id) end
    end
  end, { defaultNo = true }))
end

-- ----------------------------------------------------------- the mod

return function(mod)
  local Strings = require("src.core.Strings")

  -- Long mod-name labels ticker in the hotkey rows: OptionRows.draw has no
  -- clip (a name wider than the box bleeds over its border), so the wrap
  -- blanks ticker rows for the vanilla pass and redraws their label itself,
  -- scissored to the label window and offset by the ticker.  Only rows
  -- carrying row.ticker are touched; every other OptionRows user (the
  -- OPTIONS menu, the mod manager) draws exactly as before.  The blank is
  -- guarded so a second ticker mod (QoL Toggles) composing its own wrap
  -- never clobbers the saved label: the first wrapper to see the row owns
  -- the blank/restore and the rest skip.
  if not OptionRows._modsHotkeysTickerInstalled then
    OptionRows._modsHotkeysTickerInstalled = true
    local vanillaRowsDraw = OptionRows.draw
    OptionRows.draw = function(game, rows, index, scroll, bottomLabel,
                               bottomRow)
      local ticked = {}
      for slot = 1, OptionRows.VISIBLE do
        local row = rows[(scroll or 0) + slot]
        if row and row.ticker and row._label == nil then
          ticked[#ticked + 1] = { slot = slot, row = row }
          row._label = row.label
          row.label = ""
        end
      end
      vanillaRowsDraw(game, rows, index, scroll, bottomLabel, bottomRow)
      for _, entry in ipairs(ticked) do
        local row = entry.row
        row.label = row._label
        row._label = nil
        local y = ((entry.slot - 1) * 4 + 1) * 8
        local g = love and love.graphics
        if g and g.setScissor then
          g.setScissor(row.ticker.x, y, row.ticker.w, 8)
        end
        Font.draw(row.label, row.ticker.x
            + tickerOffset(row.tick or 0, row.ticker.overflow), y)
        if g and g.setScissor then g.setScissor() end
      end
    end
  end

  mod.content.screens:register("ModsHotkeysMenu", { new = function(game, page)
    local rows = {}
    local ids = {}
    for id in pairs(state.hotkeys) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local hk = state.hotkeys[id]
      if hotkeyPage(hk.pieces) == page then
        local label = hk.label or Strings(hk.modName)
        local row = {
          id = id,
          label = label,
          value = function() return rowValue(id) end,
          hotkey = hk,
        }
        -- a mod name wider than the label window tickers instead of
        -- bleeding over the box border (row.tick is advanced in update)
        local w = Font.width(label)
        if w > LABEL_CLIP_W then
          row.ticker = { x = LABEL_X, w = LABEL_CLIP_W,
                         overflow = w - LABEL_CLIP_W }
          row.tick = 0
        end
        rows[#rows + 1] = row
      end
    end
    return setmetatable({
      game = game,
      page = page,
      rows = rows,
      index = 1, scroll = 0,
    }, ModsHotkeysMenu)
  end })

  mod.hooks:wrap("ui.options.rows", function(next, game, rows)
    rows = next(game, rows)
    local function pageCount(page)
      local n = 0
      for _, hk in pairs(state.hotkeys) do
        if hotkeyPage(hk.pieces) == page then n = n + 1 end
      end
      return n
    end
    rows[#rows + 1] = {
      id = "modsHotkeysPc",
      label = Strings("PC HOTKEYS"),
      value = function()
        return Strings("%d HOTKEYS", pageCount("pc"))
      end,
      activate = function(g)
        require("src.ui.Screens").push(g, "ModsHotkeysMenu", "pc")
      end,
    }
    rows[#rows + 1] = {
      id = "modsHotkeysPad",
      label = Strings("PAD HOTKEYS"),
      value = function()
        return Strings("%d HOTKEYS", pageCount("controller"))
      end,
      activate = function(g)
        require("src.ui.Screens").push(g, "ModsHotkeysMenu", "controller")
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
    for _, hk in ipairs(engineHotkeys(Game)) do state.hotkeys[hk.id] = hk end
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

    -- Poll-based hotkeys (Dex Radar) read love.keyboard.isDown directly,
    -- so edge re-emission can never reach them.  Instead the rebound
    -- combo holds the polled key virtually for its whole duration --
    -- down on fire, up on break -- and the isDown wrap below makes the
    -- source mod's poll see exactly the press it latches.
    local function holdPoll(rb, down)
      local key = rb.pollField and resolvePollKey(rb) or
        (rb.original and rb.original[1] and rb.original[1].name)
      if not key then return end
      if down then state.virtual[key] = true
      else state.virtual[key] = nil end
    end

    local function tick(ev, pKey, pPad, rKey, rPad, joy)
      if state.capturing then return end
      for _, rb in pairs(state.rebinds) do
        local _, tr = comboStep(rb.combo, ev)
        if tr == "fire" then
          if rb.poll then holdPoll(rb, true)
          else emit(originalPieces(rb), pKey, pPad, joy) end
        elseif tr == "break" then
          if rb.poll then holdPoll(rb, false)
          else emit(originalPieces(rb), rKey, rPad, joy) end
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

    -- Keyboard-poll hotkeys query love.keyboard.isDown, so a virtual
    -- hold must answer those polls too.  Only keys a rebind currently
    -- holds virtually are affected; every other query passes through.
    if love and love.keyboard and not Game._modsHotkeysPollInstalled then
      Game._modsHotkeysPollInstalled = true
      local vIsDown = love.keyboard.isDown
      love.keyboard.isDown = function(key, ...)
        if state.virtual[key] then return true end
        return vIsDown(key, ...)
      end
    end
  end, -100000)

  mod.exports = {
    parseSource = parseSource,
    detectFromFiles = detectFromFiles,
    scanMods = scanMods,
    engineHotkeys = engineHotkeys,
    hotkeyPage = hotkeyPage,
    describe = describe,
    isBindable = isBindable,
    comboState = comboState,
    comboStep = comboStep,
    canonicalFor = canonicalFor,
    getRebinds = getRebinds,
    setRebinds = setRebinds,
    currentTrigger = currentTrigger,
    applyRebinds = applyRebinds,
    resolveGBConfig = resolveGBConfig,
    originalPieces = originalPieces,
    resolvePollKey = resolvePollKey,
    resetRebindCombos = resetRebindCombos,
    tickerOffset = tickerOffset,
    state = state,
  }
end
