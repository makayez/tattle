--[[ Tests/wow_stub.lua

A stub WoW client so Tattle can be smoke-tested without the game.

Usage:
    lua Tests/wow_stub.lua            # from the addon folder
    lua Tests/wow_stub.lua /path/to/tattle

Exit code 0 = all checks passed, 1 = at least one failed.

It loads the files in TOC order, dispatches ADDON_LOADED, drives the slash
commands and simulated casts, builds the config panel, and asserts behaviour
that has previously regressed (see CHECKS below).

It is a harness, not a UI test: widget methods the harness does not model
resolve to a callable no-op proxy. Any key that fell back to the proxy is
recorded in frame._proxied and printed at the end, so a typo'd field name
(e.g. a call to a function that was never written) shows up as a proxied key
instead of passing silently.
--]]

local ADDON_DIR = (arg and arg[1]) or "."

-- The restricted-content value model, defined further down and used by the API
-- stubs above it. Declared up here because a function can only close over a local
-- that is already in scope where the function is written, and this harness is a
-- single chunk: written any other way these calls compile to a global lookup that
-- reads nil.
local Secret

-- ============================================================================
-- FrameXML-ish helpers
-- ============================================================================

function string:trim()
    return (self:gsub("^%s+", ""):gsub("%s+$", ""))
end
table.wipe = function(t)
    for k in pairs(t) do t[k] = nil end
end

-- Callable + indexable no-op, so widget chains (slider.Low:SetText) resolve.
local noop
noop = setmetatable({}, {
    __call = function() return noop end,
    __index = function() return noop end,
    __newindex = function() end,
    __tostring = function() return "noop" end,
})

local frames = {}          -- every frame created, for the proxy audit
-- Geometry setters that were handed a nil where the client demands a number. Real
-- WoW raises an error there; a stub that quietly ignores the nil lets a whole class
-- of "constant I forgot to define" bug walk past green. See the check that reads
-- this list at the end of the run.
local nilGeometry = {}
-- Geometry calls the client would have refused for a reason other than a nil: an
-- anchor point it has no such name for, or a region name it cannot resolve. Same
-- purpose as the list above, separate list because the failure is different - and
-- because this one *raises*, like the client does, so the code that was on the way
-- to showing a frame stops where the client would have stopped.
local badGeometry = {}

-- Every region the client can resolve by name. A *string* in SetPoint's second slot
-- is one of these, which is the whole trap: see auditSetPoint.
local namedRegions = {}
local POINT_NAMES = {
    TOP = true, BOTTOM = true, LEFT = true, RIGHT = true, CENTER = true,
    TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true,
}

-- SetPoint's argument shapes are
--   (point), (point, regionOrRegionName), (point, region, relativePoint),
--   (point, region, relativePoint, x, y), (point, x, y)
-- and there is no (point, relativePoint) form -- that one died with the 1.x client,
-- which is why a string in slot two is a region *name* and never an anchor name.
-- `text:SetPoint("TOPRIGHT", "TOPRIGHT")` loaded fine here for its whole life and
-- threw `Couldn't find region named 'TOPRIGHT'` six times in a live raid, on the
-- watch list's own refresh path, which is also why the list never appeared.
local function auditSetPoint(...)
    local count = select("#", ...)
    local args = { ... }

    local function fail(msg)
        badGeometry[#badGeometry + 1] = "SetPoint " .. msg
        error("SetPoint(): " .. msg, 0)
    end

    local point = args[1]
    if point ~= nil and (type(point) ~= "string" or not POINT_NAMES[point]) then
        fail("unknown anchor point " .. tostring(point))
    end

    local second = args[2]
    if count >= 2 and second ~= nil then
        if type(second) == "string" then
            if not namedRegions[second] then
                fail("couldn't find region named '" .. second .. "'")
            end
        elseif type(second) ~= "table" and type(second) ~= "number" then
            fail("cannot anchor to " .. tostring(second))
        end
    end

    -- Slots past the second hold a relative point, then two offsets. A string there
    -- has to be an anchor name; anything that is neither is not a geometry argument.
    for i = 3, count do
        local value = args[i]
        if value ~= nil then
            if type(value) == "string" then
                if not POINT_NAMES[value] then
                    fail("unknown relative point '" .. value .. "'")
                end
            elseif type(value) ~= "number" then
                fail("argument #" .. i .. " is neither a point name nor an offset")
            end
        end
    end
end
local eventFrames = {}     -- event name -> { frame, ... }
local timers = {}
local tickers = {}         -- { interval = n, fn = f, Cancel = ... }, for manual sweeps
local sentMessages = {}
local chatRefusals = {}   -- chat lines the client itself refused to send
local printLog = {}

local newFrame
do
    -- A frame you did not model answers every unknown key with a no-op, so a
    -- wrong method name is invisible. Reading one is recorded in _proxied and
    -- printed at the end of the run: a new entry there is usually a typo, not a
    -- missing stub. Two kinds of read are not typos and stay out of that audit --
    -- a field the frame really has (its kind, or a name that is nil for an
    -- unnamed frame), and a field the addon put on the frame itself (a saved
    -- position, a colour, the warning banner a tab shows when the addon is off).
    local OWN_FIELDS = { name = true, kind = true, template = true }
    -- Which field names the addon uses for its own state, collected as it goes:
    -- `container.warning = banner` in one place means `if tab.warning then` on a
    -- tab that has no banner is a nil read, not a misspelled widget method. It is
    -- the set of names seen anywhere rather than per frame, because the read often
    -- happens on a different frame than the write -- which is the whole point.
    local writtenFields = {}
    local frame_mt = {
        __newindex = function(f, key, value)
            writtenFields[key] = true
            rawset(f, key, value)
        end,
        __index = function(f, key)
            if OWN_FIELDS[key] or writtenFields[key] then return rawget(f, key) end
            f._proxied[key] = true
            return noop
        end,
    }

    newFrame = function(kind, name, parent, template)
        local f = setmetatable({
            kind = kind, name = name, template = template,
            _scripts = {}, _children = {}, _proxied = {},
            _checked = false, _text = "", _value = 0,
            _enabled = true, _shown = false, _multiLine = false,
            _width = 100, _height = 24,
        }, frame_mt)

        if parent and parent._children then
            table.insert(parent._children, f)
        end
        table.insert(frames, f)
        -- A frame created with a name is addressable by that name from an anchor
        -- call, which is the only reason the harness needs to know the set.
        if name then namedRegions[name] = f end

        f.SetScript = function(_, script, fn) f._scripts[script] = fn end
        f.GetScript = function(_, script) return f._scripts[script] end
        f.RegisterEvent = function(_, event)
            -- Real WoW registers an event on a frame only once, no matter how
            -- many times RegisterEvent is called. Without this, a frame that
            -- registers a shared event from two places would get the handler
            -- called twice and the checks would report phantom duplicates.
            local list = eventFrames[event]
            if not list then
                eventFrames[event] = { f }
                return
            end
            for _, existing in ipairs(list) do
                if existing == f then return end
            end
            table.insert(list, f)
        end
        f.UnregisterEvent = function() end

        f.Show = function() f._shown = true end
        f.Hide = function() f._shown = false end
        f.IsShown = function() return f._shown end
        f.IsVisible = function() return f._shown end

        f.SetText = function(_, text) f._text = tostring(text) end
        f.GetText = function() return f._text end
        -- FontString: CreateTabButton measures the label to size tab buttons and
        -- the watch list sizes its frame from its text, so these must return
        -- numbers or the arithmetic explodes.
        f.GetStringWidth = function() return 60 end
        f.GetStringHeight = function() return 24 end

        f.SetChecked = function(_, v) f._checked = v and true or false end
        -- WoW's GetChecked returns true/nil, never false.
        f.GetChecked = function() return f._checked or nil end

        f.Enable = function() f._enabled = true end
        f.Disable = function() f._enabled = false end
        f.IsEnabled = function() return f._enabled end

        f.SetValue = function(_, v) f._value = v end
        f.GetValue = function() return f._value end

        f.CreateFontString = function() return newFrame("FontString", nil, f) end
        f.CreateTexture = function() return newFrame("Texture", nil, f) end
        f.SetMultiLine = function(_, v) f._multiLine = v and true or false end

        -- Width/position have to be real numbers: CreateTabButton packs tab
        -- buttons with `x + button:GetWidth() + gap`, and ScreenAlert reads
        -- GetPoint when saving a dragged position.
        -- Every argument the caller actually passed is inspected, including one
        -- that arrived as nil: select('#', ...) counts it, so f:SetSize(w, nil) is
        -- caught while f:SetSize(w, h) with a real h is not.
        local function audit(name, ...)
            local count = select("#", ...)
            for i = 1, count do
                if select(i, ...) == nil then
                    nilGeometry[#nilGeometry + 1] =
                        name .. " got nil argument #" .. i
                end
            end
        end

        f.SetWidth = function(_, w) audit("SetWidth", w); if type(w) == "number" then f._width = w end end
        f.SetHeight = function(_, ht) audit("SetHeight", ht); if type(ht) == "number" then f._height = ht end end
        f.SetSize = function(_, w, ht)
            audit("SetSize", w, ht)
            if type(w) == "number" then f._width = w end
            if type(ht) == "number" then f._height = ht end
        end
        f.SetPoint = function(_, ...) audit("SetPoint", ...); auditSetPoint(...) end
        f.SetFont = function(_, path, size) audit("SetFont", path, size) end
        f.GetWidth = function() return f._width or 100 end
        f.GetHeight = function() return f._height or 24 end
        f.GetPoint = function() return "TOP", "UIParent", "TOP", 0, -200 end

        return f
    end
end

CreateFrame = newFrame
UIParent = newFrame("Frame", "UIParent")
GameTooltip = newFrame("GameTooltip", UIParent)

C_Timer = {
    After = function(_, fn) table.insert(timers, fn) end,
    NewTimer = function(_, fn)
        table.insert(timers, fn)
        return { Cancel = function() end }
    end,
    -- Tickers are recorded rather than fired: a check that wants a sweep calls
    -- fireTickers(), and a check about switching the display off can see that
    -- the ticker was cancelled.
    NewTicker = function(interval, fn)
        local ticker = { interval = interval, fn = fn, cancelled = false }
        ticker.Cancel = function() ticker.cancelled = true end
        table.insert(tickers, ticker)
        return ticker
    end,
}

-- A client does not let one timer callback take down the addon: it catches the
-- error, shows the bubble and keeps ticking. So the harness catches it too, and
-- counts it - `callbackErrors` is what a player would have read as an error bag,
-- and the check at the end of the run is "nobody's watch list threw on a sweep".
local callbackErrors = {}

local function fireTickers()
    for _, ticker in ipairs(tickers) do
        if not ticker.cancelled then
            local ok, err = pcall(ticker.fn)
            if not ok then
                callbackErrors[#callbackErrors + 1] = "ticker: " .. tostring(err)
            end
        end
    end
end

local function activeTickers()
    local n = 0
    for _, ticker in ipairs(tickers) do
        if not ticker.cancelled then n = n + 1 end
    end
    return n
end

local function runTimers()
    local pending = timers
    timers = {}
    for _, fn in ipairs(pending) do
        local ok, err = pcall(fn)
        if not ok then
            callbackErrors[#callbackErrors + 1] = "C_Timer.After: " .. tostring(err)
        end
    end
end

local clock = 1000
GetTime = function() return clock end
time = function() return clock end

-- Tests move the clock by hand so a channeled cast can be made to look either
-- completed or cut short.
--
-- `setClock` may not wind it back. A client's clock does not, and a test that asked
-- for a round number earlier in the timeline than the one it replaced got a freebie
-- it had not paid for: a module record left behind by the scenario before it was
-- *newer* than the clock, so subtracting from the age made a stale record look fresh
-- (or a fresh one look ancient) and the check passed for a reason that could not
-- happen. `advanceClock` is the honest way to say "long enough for that record to
-- stop describing its cast". A rewind is refused, reported, and checked for.
local clockRewinds = {}
local function setClock(t)
    if t < clock then
        clockRewinds[#clockRewinds + 1] = string.format("line %d: %s -> %s",
            debug.getinfo(2).currentline, tostring(clock), tostring(t))
        return
    end
    clock = t
end

local function advanceClock(seconds) clock = clock + seconds end

Secret = (function()
    -- ========================================================================
    -- Restricted content: what a secret value is in this stub
    -- ========================================================================
    --
    -- A 12.x client runs M+ and rated PvP as *restricted content*: the cast events
    -- it delivers there carry secret values, and a secret value may only be handed
    -- to an API documented to accept one. Comparing it, concatenating it, taking its
    -- length, indexing it, printing it or formatting it all raise -- and `type()`
    -- still answers "string", which is the trap the alpha.3 crash walked into: it
    -- died at `name ~= ""`, one line after a `type(name) == "string"` test had
    -- already passed.
    --
    -- The model here is an unindexable table standing in for a value, with the
    -- client's refusals wired to its metamethods. The value it stands for lives in a
    -- registry only this file can read, which is what lets the stub answer
    -- UnitIsUnit, UnitExists or a spell name for a secret operand the way the client
    -- does -- and what keeps the addon from doing the same.
    --
    -- Two limits, stated because a check that cannot fail is worse than no check:
    --
    --   * Lua 5.1 consults __eq for two tables only, so `secret ~= "a literal"` -
    --     the actual alpha.3 line - cannot be made to raise here: Lua answers a
    --     table-versus-string comparison by type alone. The equality half of the
    --     class is guarded by the source audit at the end of the run instead.
    --   * Indexing a table with a secret key is a refusal on a real client and a
    --     plain miss here, so the core reaches its "ask the client instead" path
    --     through the type test rather than through the raise. Same helper either
    --     way, and the helper is what the checks exercise.

    local registry = {}      -- proxy -> the value it stands for
    local refusals = 0       -- how many times something tried to touch one

    local function asSecret(value)
        local proxy = setmetatable({}, {
            __index = function()
                refusals = refusals + 1
                error("attempt to index a secret value, while execution tainted by 'Tattle'", 0)
            end,
            __newindex = function()
                refusals = refusals + 1
                error("attempt to modify a secret value, while execution tainted by 'Tattle'", 0)
            end,
            __call = function()
                refusals = refusals + 1
                error("attempt to call a secret value, while execution tainted by 'Tattle'", 0)
            end,
            __concat = function()
                refusals = refusals + 1
                error("attempt to concatenate a secret string value, while execution tainted by 'Tattle'", 0)
            end,
            __len = function()
                refusals = refusals + 1
                error("attempt to get length of a secret string value, while execution tainted by 'Tattle'", 0)
            end,
            __tostring = function()
                refusals = refusals + 1
                error("attempt to convert a secret string value to a string", 0)
            end,
            __eq = function()
                refusals = refusals + 1
                error("attempt to compare two secret values, while execution tainted by 'Tattle'", 0)
            end,
            __lt = function()
                refusals = refusals + 1
                error("attempt to compare secret values, while execution tainted by 'Tattle'", 0)
            end,
            __le = function()
                refusals = refusals + 1
                error("attempt to compare secret values, while execution tainted by 'Tattle'", 0)
            end,
        })
        registry[proxy] = value
        return proxy
    end

    local function isSecretValue(value)
        return type(value) == "table" and registry[value] ~= nil
    end

    -- The stub's own look at a value the addon may not look at. The registry is
    -- indexed by identity - a lookup in *this file's* table, never an index into the
    -- value - which is the difference between a client answering a question about a
    -- secret unit and an addon being allowed to inspect one.
    local function underlying(value)
        if type(value) == "table" and registry[value] ~= nil then return registry[value] end
        return value
    end

    -- A spell ID that arrived as a secret value, back to an ID this stub's spell
    -- table can look up. Only this file may do that, and the whole point of the
    -- checks is that the addon cannot.
    local function spellIdValue(id)
        local plain = underlying(id)
        if type(plain) == "number" then return plain end
        return tonumber(plain) or plain
    end

    -- True while the checks are simulating restricted content.
    local context = false

    -- A restricted client will not name another player. Your own name is your own.
    local function nameForReporting(token, name)
        if not name then return nil end
        if not context then return name end
        if underlying(token) == "player" then return name end
        return asSecret(name)
    end

    return {
        asSecret = asSecret,
        isSecretValue = isSecretValue,
        underlying = underlying,
        spellIdValue = spellIdValue,
        nameForReporting = nameForReporting,
        setContext = function(on) context = on and true or false end,
        refusals = function() return refusals end,
        resetRefusals = function() refusals = 0 end,
    }
end)()

-- UnitCastingInfo/UnitChannelInfo return
-- (name, displayName, texture, startTimeMs, endTimeMs, isTrade, notInterruptible,
-- spellID). The two timing returns carry `Ms` in their documented names, and
-- Blizzard's own cast bar divides them by 1000 before comparing against GetTime, so
-- the stub answers in milliseconds as well. This is the fidelity fix behind the
-- module's window bug: a stub that returns seconds here makes a module that treats
-- the pair as seconds look correct in every check, right up to the moment a real
-- client reports a completed swap as one that was cut short.
UnitCastingInfo = function()
    return "Swap", nil, nil, clock * 1000, (clock + 1.5) * 1000, false, false, 161399
end
UnitChannelInfo = function()
    return "Swap", nil, nil, clock * 1000, (clock + 1.5) * 1000, false, false, 161399
end

-- Which units are fighting. Set per check with setCombatUnits.
local combatUnits = {}
UnitAffectingCombat = function(unit) return combatUnits[unit] == true end
local function setCombatUnits(...) combatUnits = {} for _, u in ipairs({...}) do combatUnits[u] = true end end

-- Recorded, because "one cast makes one noise" is a claim about how many times
-- PlaySound runs, and a stub that plays and forgets cannot answer it.
local soundPlays = {}
PlaySound = function(soundId)
    table.insert(soundPlays, soundId)
    return true
end
-- Chat lockdown, the restricted-content behaviour: while it is in effect the client
-- refuses to let an addon's SendChatMessage reach anybody. A switch rather than a
-- constant because the scenario it happens in - a restricted raid or key - is where a
-- griefer's casts and Tattle's chat alerts both land, so what is under test is what the
-- addon does when the client says no, not whether it believes the client.
local chatMessagingLockedDown = false

C_ChatInfo = {
    InChatMessagingLockdown = function() return chatMessagingLockedDown end,
}

-- The client's own questions about hidden values. Both are documented in 12.1.x, both take a
-- value rather than inspecting it, and `canaccessvalue` in particular is what lets an addon
-- ask "may I use this?" without doing anything to it - which is the only legitimate test an
-- addon has. Answered from the registry, so they can see what the addon cannot.
issecretvalue = function(value) return Secret.isSecretValue(value) end
canaccessvalue = function(value) return not Secret.isSecretValue(value) end

-- Counted at the very top, before any refusal, because "the addon never attempted the
-- send" and "the addon attempted it and the client said no" are two different outcomes and
-- the difference is the whole behaviour the chat gates exist to produce. A check that only
-- looks at what arrived cannot tell them apart, and said so itself for one full run.
local chatSendAttempts = 0

SendChatMessage = function(message, channel)
    chatSendAttempts = chatSendAttempts + 1
    if chatMessagingLockedDown then
        table.insert(chatRefusals, tostring(message))
        error("SendChatMessage is not allowed while chat messaging is locked down", 0)
    end
    -- The client's rule, applied at the boundary: a secret value does not belong in
    -- a chat message. A message *built* out of one failed earlier, so this is the
    -- backstop for a name handed straight through.
    if Secret.isSecretValue(message) then
        table.insert(chatRefusals, tostring(message))
        error("attempt to send a secret string value, while execution tainted by 'Tattle'", 0)
    end
    table.insert(sentMessages, { message = message, channel = channel })
end

SlashCmdList = {}

-- ============================================================================
-- Group / unit state
-- ============================================================================

-- Names for the units a check can see. In a raid of three you are raid3, so the
-- named *other* members are raid1 and raid2 -- the shape every check below
-- assumes. The party branch never numbers you, so party1..party4 are the others.
local RAID_NAMES  = { "Donut", "Pancakes", "Waffles", "Syrup", "Maple" }
local PARTY_NAMES = { "Donut", "Pancakes", "Waffles", "Syrup" }

-- Group shape, driven by setGroup() so a check can be solo, a party, a plain
-- raid, or an LFR raid. `normalRaid` is what IsInRaid(LE_GROUP_TYPE_RAID) sees:
-- false in LFR, which is exactly the difference Tattle.ResolveChatChannel needs.
--
-- Modelled the way the client numbers a group, because the difference is load
-- bearing: in a raid you hold one of the raidN indexes and GetNumGroupMembers()
-- counts you, while a party numbers only the other four and calls you "player".
-- A stub in which raid1 and raid2 are both *other* players inside a raid of two
-- is not a shape the game can produce, and it is what let the addon scan itself
-- twice without a single check noticing.
local group = { inRaid = true, normalRaid = true, count = 3, party = false, selfIndex = 3 }
local function setGroup(opts)
    group.inRaid = opts.raid or false
    group.normalRaid = opts.normalRaid == nil and (opts.raid or false) or opts.normalRaid
    group.party = opts.party or false
    group.count = opts.count or (group.inRaid and 3 or (group.party and 3 or 0))
    -- Which raidN is you. Meaningless in a party, where there is no index for you.
    group.selfIndex = opts.selfIndex or group.count
    -- A real client fires GROUP_ROSTER_UPDATE after any of this, and the core
    -- drops its cached unit-token lists on that event. Drop them here too, or
    -- every check below would read a stale group.
    if Tattle and Tattle.InvalidateGroupCaches then Tattle.InvalidateGroupCaches() end
end

-- Two different tokens name the same player when one of them is your raid index.
-- underlying() first, because a restricted client reports the *same* unit under a
-- secret token, and every question in this file is about the unit, not about the
-- spelling of its name.
local function isMe(token)
    token = Secret.underlying(token)
    return token == "player" or (group.inRaid and token == "raid" .. group.selfIndex)
end

local function nameFor(token)
    if token == "player" then return "Me" end
    if group.inRaid then
        local n = tonumber(string.match(token, "^raid(%d+)$"))
        if n then
            if n > group.count then return nil end
            if n == group.selfIndex then return "Me" end
            return RAID_NAMES[n]
        end
    end
    if group.party then
        local n = tonumber(string.match(token, "^party(%d+)$"))
        -- A party of five has party1..party4 and no party5: you are "player".
        if n then
            if n > group.count - 1 then return nil end
            return PARTY_NAMES[n]
        end
    end
    return nil
end

IsInRaid = function(groupType)
    if groupType then return group.inRaid and group.normalRaid or false end
    return group.inRaid
end
IsInGroup = function() return group.inRaid or group.party end
IsInGuild = function() return true end
IsInLFGGroup = function() return group.inRaid and not group.normalRaid end
GetNumGroupMembers = function() return group.count end
LE_GROUP_TYPE_RAID = "raid"

-- "<member>target" tokens: targets["raid2target"] = "player" means Pancakes has
-- you targeted. nil means the token resolves to nothing, as it does for a client
-- that is not told other players' targets.
local targets = {}

-- Where every unit is standing, in yards. This exists because the probe's position
-- channel has to be tested against a world rather than against a wish: an exchange is
-- two members arriving at each other's starting points, and nothing about that is
-- expressible without coordinates.
--
-- Members with no position set start one fixed distance apart, not at the origin.
-- A world in which everybody overlaps would let a distance test pass on a distance of
-- zero, which is the one way a corroborator like this can be made to look correct
-- while it accuses whoever happens to be standing nearest.
local MAP_ID = 980
local positions = {}

-- Your own raid index and "player" are one unit, and the core collapses them into
-- one token wherever it can. Anything keyed by unit has to collapse the same way or a
-- check sets up a fact about "raid4" that the addon then asks about as "player".
local function canonicalToken(token)
    if type(token) ~= "string" then return token end
    local n = tonumber(string.match(token, "^raid(%d+)$"))
    if n and group.inRaid and n == group.selfIndex then return "player" end
    return token
end

local function defaultPosition(token)
    local n = tonumber(string.match(token, "^raid(%d+)$"))
        or tonumber(string.match(token, "^party(%d+)$"))
        or 0
    return { x = 1000 + n * 50, y = 1000, z = 0, mapID = MAP_ID }
end

-- Counted, so a check can prove that "your client was not told" is answered by one
-- cheap question rather than a UnitIsUnit per raid member.
unitExistsCalls, unitIsUnitCalls = 0, 0

local function unitExists(unit)
    unit = Secret.underlying(unit)
    if string.match(unit, "target$") then return targets[unit] ~= nil end
    return nameFor(unit) ~= nil
end
UnitExists = function(unit)
    unitExistsCalls = unitExistsCalls + 1
    return unitExists(unit)
end
UnitName = function(unit)
    local token = Secret.underlying(unit)
    local owner = string.match(token, "^(.-)target$")
    if owner then
        local who = targets[token]
        return Secret.nameForReporting(token, who and (nameFor(who) or who))
    end
    return Secret.nameForReporting(token, nameFor(token))
end
local function unitIsUnit(a, b)
    -- `<unit>target` tokens answer as whoever they point at, and a target the
    -- client was never told about is not the same unit as anything. Comparing the
    -- raw strings, as this did, says "raid1target is not raid3" while also saying
    -- "raid1target is player" -- the same person under two tokens, which is exactly
    -- the mistake the addon is supposed to stop making.
    local function resolve(u)
        u = Secret.underlying(u)
        if type(u) ~= "string" then return nil end
        if string.match(u, "target$") then return targets[u] end
        return u
    end
    local ra, rb = resolve(a), resolve(b)
    if not ra or not rb then return false end
    if isMe(ra) then return isMe(rb) and true or false end
    if isMe(rb) then return isMe(ra) and true or false end
    return ra == rb
end
UnitIsUnit = function(a, b)
    unitIsUnitCalls = unitIsUnitCalls + 1
    return unitIsUnit(a, b)
end
-- Documented in both 12.1.5 and 12.1.7 as `UnitPosition(unit) -> positionX,
-- positionY, positionZ, mapID`, with no secrecy flag on any return, so this answers
-- plainly. A unit this client has no position for answers nothing at all - the raid
-- member in another instance - which is the case the probe has to report as a gap in
-- its sample rather than as a member standing at zero, zero.
unitPositionCalls = 0
UnitPosition = function(unit)
    unitPositionCalls = unitPositionCalls + 1
    local token = Secret.underlying(unit)
    if type(token) ~= "string" or not unitExists(token) then return nil end
    local p = positions[token]
    if p == false then return nil end
    if not p then p = defaultPosition(token) end
    return p.x, p.y, p.z, p.mapID
end

-- The cast-target APIs, modelled with the flags the generated docs give them rather
-- than in the friendliest way available. `UnitSpellTargetName` carries
-- `SecretReturns = true`, and the case this addon lives in is another player's cast,
-- so the harness has to walk the same "here is a value you may not read" path a beta
-- will. The two switches below are what let one check take that away and another put
-- it back, because the fallback chain is the behaviour under test.
local spellTargets = {}
local spellTargetNamesAreSecret = true
local spellTargetNamesDisplayable = true

-- Stored as a name plus an optional token, because the interesting cases are "the
-- target is somebody outside this group" and "the target is in the group", and both
-- have to be nameable by a check.
local function spellTargetFor(unit)
    return spellTargets[canonicalToken(Secret.underlying(unit))]
end

-- Flagged SecretReturns with no content predicate attached, so it answers plainly:
-- "did that cast land on me" is the one target question a player is always allowed.
PlayerIsSpellTarget = function(unit)
    local entry = spellTargetFor(unit)
    if not entry or not entry.token then return false end
    return isMe(entry.token) and true or false
end

-- The gate. Documented with no secrecy flag, which is why the core asks it before
-- paying for a name it may not be allowed to have.
UnitShouldDisplaySpellTargetName = function(unit)
    if not spellTargetFor(unit) then return nil end
    return spellTargetNamesDisplayable and true or false
end

UnitSpellTargetName = function(unit)
    local entry = spellTargetFor(unit)
    if not entry or not entry.name then return nil end
    local caster = canonicalToken(Secret.underlying(unit))
    if spellTargetNamesAreSecret and not isMe(caster) then
        return Secret.asSecret(entry.name)
    end
    return entry.name
end
-- Both membership queries answer for you as well as for the numbered members, the
-- way they do on a real client: UnitInRaid("player") is true in a raid, and
-- UnitInParty("player") is not.
UnitInRaid = function(unit)
    if not group.inRaid then return nil end
    unit = Secret.underlying(unit)
    if isMe(unit) then return group.selfIndex end
    local n = tonumber(string.match(unit, "^raid(%d+)$"))
    if n and n <= group.count then return n end
    return nil
end
UnitInParty = function(unit)
    if not group.party then return nil end
    unit = Secret.underlying(unit)
    if unit == "player" then return nil end
    local n = tonumber(string.match(unit, "^party(%d+)$"))
    if n and n <= group.count - 1 then return n end
    return nil
end

-- ============================================================================
-- Spell / aura state (spell IDs verified against the live 12.1.5 database)
-- ============================================================================

local spellNames = {
    [161399] = "Swap",                  -- the cast the Swapblaster item triggers
    [162217] = "Swapblaster",           -- the crafting spell, deliberately unused
    [182081] = "Swapblaster Explosion", -- the Neural Silencer backfire
    [156779] = "Neural Silencer",
    [384129] = "Neural Silencer",       -- Mk3, same aura name
    [73325]  = "Leap of Faith",         -- what everyone calls Life Grip
    [370666] = "Rescue",
    [370667] = "Rescue",                -- passenger-side helper aura
}

C_Spell = {
    GetSpellInfo = function(id)
        local name = spellNames[Secret.spellIdValue(id)]
        if not name then return nil end
        -- A name derived from a secret spell ID is itself secret: safe to hand to
        -- another API, useless to compare, print or store as a key.
        if Secret.isSecretValue(id) then name = Secret.asSecret(name) end
        return { spellID = id, name = name }
    end,
    -- The allocation-free name lookup the real client has. The core prefers this
    -- and only falls back to GetSpellInfo without it, which a later check proves
    -- by taking it away.
    GetSpellName = function(id)
        local name = id and spellNames[Secret.spellIdValue(id)] or nil
        if name and Secret.isSecretValue(id) then name = Secret.asSecret(name) end
        return name
    end,
}

-- The client's sanctioned way to ask a question about a secret value: compare it
-- with a plain one, and get a plain answer back. `secretCompareSupported` models a
-- build that has the table but refuses the comparison - which for the addon is the
-- same dead end as not having it, and which the core captured at load time, so it
-- has to be switched inside this stub rather than by deleting the global.
local secretCompareSupported = true
C_SecretComparisons = {
    Equal = function(a, b)
        if not secretCompareSupported then
            error("attempt to compare a secret value on a client that will not compare one", 0)
        end
        local left, right = Secret.underlying(a), Secret.underlying(b)
        if type(left) ~= type(right) then return false end
        return left == right
    end,
}

-- Instrumented so a check can count how often the core resolves a spell name.
spellNameLookups = 0
do
    local real = C_Spell.GetSpellName
    C_Spell.GetSpellName = function(id)
        spellNameLookups = spellNameLookups + 1
        return real(id)
    end
end

-- auras[unit][spellName] = spellID, driven by the checks that need a target.
local auras = {}
-- Auras belong to a person, not to a token: setting one on your raid index puts it
-- on you, and reading it back through "player" finds it. Matches the aliasing in
-- C_UnitAuras.GetAuraDataBySpellName below, and is what lets a check set an aura
-- where a raidN-walking sweep would look for it.
local function auraKey(unit)
    return isMe(unit) and "player" or unit
end
local function setAura(unit, spellName, spellID)
    local key = auraKey(unit)
    auras[key] = auras[key] or {}
    auras[key][spellName] = spellID
end
-- Restricted content, modelled as the client *refusing* an aura read rather than answering
-- "no aura". `GetAuraDataBySpellName` carries `SecretWhenUnitAuraRestricted`, and none of
-- the spells Tattle watches carries a per-spell secrecy exemption, so inside a key or a
-- raid encounter a refusal is the ordinary outcome for another player's auras. A switch
-- rather than a constant because what the watch list says about a wall of refusals is the
-- behaviour under test, and the wrong answer to it is "nobody".
local aurasRefused = false

-- The other shape a refusal arrives in: the call succeeds and hands over a value the addon
-- may not look at. Some restricted reads answer this way instead of raising, and it changes
-- what "answered" means - an unreadable something is not a "no aura", and treating it as one
-- is how a watch list reports an unprotected group on a client that never said so.
local aurasReturnSecrets = false

local function refuseAuraReads()
    aurasRefused = true
end

local function secreteAuraReads()
    aurasReturnSecrets = true
end

local function clearAuras()
    for unit in pairs(auras) do auras[unit] = nil end
    aurasRefused = false
    aurasReturnSecrets = false
end

C_UnitAuras = {}
do
    local function getAuraData(unit, spellName, filter)
        -- An aura on you is readable through your raid index as well as through
        -- "player", so auras are keyed by person, not by token. That is what makes a
        -- double-counting sweep observable: read you twice and the wearer list gains
        -- a second copy of you.
        local byUnit = auras[auraKey(unit)]
        local spellID = byUnit and byUnit[spellName]
        if not spellID then return nil end
        return { spellID = spellID, name = spellName, auraInstanceID = spellID }
    end
    -- Counted, so a check can prove a switched-off feature really does nothing.
    auraLookups = 0
    C_UnitAuras.GetAuraDataBySpellName = function(unit, spellName, filter)
        auraLookups = auraLookups + 1
        -- Your own auras stay readable; the predicate is about other people.
        if aurasRefused and not isMe(unit) then
            error("attempt to access a secret value while execution tainted by 'Tattle'", 0)
        end
        local data = getAuraData(unit, spellName, filter)
        if aurasReturnSecrets and not isMe(unit) and data then
            return Secret.asSecret(data.spellID)
        end
        return data
    end
end

-- The TOC's own version, not a copy of it typed into this file. A second string that
-- has to be remembered is one that drifts: this said "0.2.0" while Tattle.toc said
-- 0.2.0-alpha.3, which made a check about the version line uninteresting, and the
-- version a player reads in /tattle status is the one this function feeds it.
local function readTocVersion()
    local handle = io.open(ADDON_DIR .. "/Tattle.toc", "r")
    if not handle then return nil end
    local version = nil
    for line in handle:lines() do
        version = line:match("^##%s*Version:%s*(.+)%s*$") or version
    end
    handle:close()
    return version
end
local TOC_VERSION = readTocVersion()

C_AddOns = {
    GetAddOnMetadata = function(_, key)
        if key == "Version" then return TOC_VERSION end
        return nil
    end,
}

SOUNDKIT = {
    RAID_WARNING = 8959, READY_CHECK = 8960, ALARM_CLOCK_WARNING_3 = 12867,
    LEVEL_UP = 888, ACHIEVEMENT_MENU_OPEN = 3337, MAP_PING = 3175,
}

UIDropDownMenu_CreateInfo = function() return {} end
UIDropDownMenu_AddButton = function() end
UIDropDownMenu_SetWidth = function() end
UIDropDownMenu_SetText = function() end
UIDropDownMenu_Initialize = function() end

local interfaceOptionsRegistered = 0
-- Deliberately *not* stubbed: `Settings.Close`. The shipping client this addon was
-- tested against does not have it, and a stub that supplied a no-op let
-- `Settings.Close()` sit unguarded in the Interface Options button's OnClick until a
-- player produced `Config.lua:833: attempt to call a nil value`. A client-owned
-- helper that is not in this table is a helper this addon has to ask for first.
Settings = {
    RegisterCanvasLayoutCategory = function(frame, name)
        return { frame = frame, name = name }
    end,
    RegisterAddOnCategory = function()
        interfaceOptionsRegistered = interfaceOptionsRegistered + 1
    end,
}

-- print goes to the log as well as stdout so tests can assert on it.
local realPrint = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    local line = table.concat(parts, " ")
    table.insert(printLog, line)
    realPrint(line)
end

-- ============================================================================
-- Harness utilities
-- ============================================================================

local checks = { passed = 0, failed = 0 }

local function check(name, ok, detail)
    if ok then
        checks.passed = checks.passed + 1
        realPrint("  PASS  " .. name)
    else
        checks.failed = checks.failed + 1
        realPrint("  FAIL  " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end

-- Run a module's display/settings plumbing the way the client runs it: anything it
-- throws is caught, kept, and the UI is left in whatever state it reached. Letting one
-- of these abort the file hid every check behind it, which is how the watch list's
-- broken anchor presented itself as a broken harness instead of as "the list never
-- appears" -- the actual bug report.
local displayErrors = {}
local function attempt(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then displayErrors[#displayErrors + 1] = tostring(err) end
    return ok, err
end

local function dispatch(event, ...)
    local errors = {}
    for _, f in ipairs(eventFrames[event] or {}) do
        local handler = f:GetScript("OnEvent")
        if handler then
            local ok, err = pcall(handler, f, event, ...)
            if not ok then errors[#errors + 1] = tostring(err) end
        end
    end
    return errors
end

local function callSlash(msg)
    return pcall(SlashCmdList["TATTLE"], msg)
end

-- Depth-first search over a frame's descendants.
local function findFrame(root, predicate)
    for _, child in ipairs(root._children or {}) do
        if predicate(child) then return child end
        local found = findFrame(child, predicate)
        if found then return found end
    end
end

local function findButton(root, label)
    return findFrame(root, function(f)
        return f.kind == "Button" and f._text == label
    end)
end

local function findCheckButton(root, label)
    return findFrame(root, function(f)
        return f.kind == "CheckButton" and f.text and f.text._text == label
    end)
end

local function findLabel(root, text)
    return findFrame(root, function(f)
        return f.kind == "FontString" and f._text == text
    end)
end

local function findMultiLineEditBox(root)
    return findFrame(root, function(f)
        return f.kind == "EditBox" and f._multiLine
    end)
end

-- Same search, bounded to the lines printed after a mark in the log - which is what a
-- check about "what the addon said just now" needs, and what an unbounded backwards
-- search quietly is not.
local function lastPrintFrom(mark, needle)
    for i = #printLog, mark + 1, -1 do
        if printLog[i]:find(needle, 1, true) then return printLog[i] end
    end
    return nil
end

local function lastPrintContaining(needle)
    for i = #printLog, 1, -1 do
        if printLog[i]:find(needle, 1, true) then return printLog[i] end
    end
end

local function messageContaining(needle)
    for _, entry in ipairs(sentMessages) do
        if entry.message:find(needle, 1, true) then return entry end
    end
end

local function findFrameByName(name)
    for _, f in ipairs(frames) do
        if f.name == name then return f end
    end
end

-- Silence every output but chat, so a check can count chat sends (or chat
-- silence) without console prints and sound calls in the way.
local function muteAllModules()
    TattleDB.debug = false
    for _, moduleId in ipairs(Tattle.moduleOrder) do
        local alerts = TattleDB.modules[moduleId].alerts
        alerts.console, alerts.chat, alerts.audio, alerts.screen = false, false, false, false
    end
end

local function resetWorld()
    setGroup({ raid = true })
    setCombatUnits()
    clearAuras()
    for token in pairs(targets) do targets[token] = nil end
    for token in pairs(positions) do positions[token] = nil end
    for token in pairs(spellTargets) do spellTargets[token] = nil end
    spellTargetNamesAreSecret, spellTargetNamesDisplayable = true, true
    chatMessagingLockedDown = false
    chatSendAttempts = 0
    table.wipe(soundPlays)
end

-- Sound on, everything else off, for the checks that count PlaySound calls. Those
-- checks are about *which* alert of a cast makes the noise, so nothing else should
-- be making one and nothing else should be in the message log either.
local function soundMode(moduleId)
    local settings = TattleDB.modules[moduleId]
    settings.enabled = true
    settings.scope = "group"
    settings.alerts.console, settings.alerts.chat, settings.alerts.screen = false, false, false
    settings.alerts.audio = true
end

-- Who a group member currently has targeted. No helper for "the client was not
-- told": that is what `resetWorld` leaves the table at.
local function setTarget(owner, target)
    targets[owner .. "target"] = target
end

local function positionKey(token)
    return canonicalToken(token)
end

-- Put a unit somewhere. `z` and the map default to the world's single floor, so a
-- check that wants a cross-floor or cross-continent member asks for one explicitly.
local function moveUnit(token, x, y, z, mapID)
    positions[positionKey(token)] = { x = x, y = y, z = z or 0, mapID = mapID or MAP_ID }
end

-- A member whose position this client is not told - the raid member still in another
-- instance. Distinct from "standing at the origin": a missing sample must never be
-- readable as a position, or a corroborator will match against it.
local function unpositionUnit(token)
    positions[positionKey(token)] = false
end

-- Whom the client's own cast-target APIs believe a unit's current cast is on. This is
-- deliberately separate from setTarget: the two disagreeing is the interesting case,
-- and it is what a @mouseover cast looks like.
local function setSpellTarget(caster, target)
    spellTargets[canonicalToken(caster)] = { token = target, name = nameFor(target) }
end

-- A target the group has no token for: a name the APIs will happily hand over that must
-- not be resolved into a member by proximity or resemblance.
local function setSpellTargetName(caster, name)
    spellTargets[canonicalToken(caster)] = { name = name }
end

-- A group member with a Neural Silencer up, by short name. "Me" is you, and you
-- are addressed as "player" here even though you also hold a raidN index -- the
-- core is what has to reconcile those two, so the helper uses the plain token.
local function silenceWho(name)
    local token = (name == "Me") and "player" or (name == "Donut") and "raid1" or "raid2"
    setAura(token, "Neural Silencer", 156779)
end

-- ============================================================================
-- Load the addon in TOC order
-- ============================================================================

local function readTocFiles()
    local path = ADDON_DIR .. "/Tattle.toc"
    local file = io.open(path, "r")
    if not file then return nil, "cannot open " .. path end
    local files = {}
    for rawLine in file:lines() do
        local line = rawLine:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\", "/")
        if line ~= "" and not line:match("^##") and line:match("%.lua$") then
            table.insert(files, line)
        end
    end
    file:close()
    return files
end

realPrint("== Loading addon from " .. ADDON_DIR .. " ==")
local files, tocErr = readTocFiles()
if not files then
    realPrint("FATAL: " .. tostring(tocErr))
    os.exit(1)
end

-- The client hands each file in the TOC the addon name and one shared namespace
-- table, and every Tattle file takes them as `local _, Tattle = ...`. So the
-- harness has to pass the same table to every chunk: passing it once per file is
-- what makes the addon's files see each other's exports, and passing nothing at
-- all is what makes them fail loudly rather than quietly build a parallel global.
--
-- It is then published as the global `Tattle` for the checks below, which are
-- written against the addon's public surface the way any other addon would be.
local namespace = {}

-- Every global the addon leaves in the client, captured before its files run. The
-- namespace arrives as a vararg (`local _, Tattle = ...`), so a file that assigns
-- a global at load time is doing something it no longer has a reason to do.
-- `Tattle` is on the allow list because *this* harness publishes the namespace as
-- a global for its own checks; the addon never does.
local ALLOWED_GLOBALS = { Tattle = true, TattleDB = true, SLASH_TATTLE1 = true }
local globalsBeforeLoad = {}
for key in pairs(_G) do globalsBeforeLoad[key] = true end

local loadErrors = {}
for _, file in ipairs(files) do
    local chunk, err = loadfile(ADDON_DIR .. "/" .. file)
    if not chunk then
        table.insert(loadErrors, file .. ": " .. tostring(err))
    else
        local ok, runErr = pcall(chunk, "Tattle", namespace)
        if not ok then table.insert(loadErrors, file .. ": " .. tostring(runErr)) end
    end
end

Tattle = namespace

do
-- ---------------------------------------------------------------------------
-- One scope for the checks. This harness is a single chunk, and Lua caps a
-- function at 200 locals: the stub client above plus the checks below together
-- outrun that, and the limit is a limit rather than a suggestion. Everything the
-- audits after this block need (frames, printLog, checks, nilGeometry) is declared
-- outside it.
-- ---------------------------------------------------------------------------

realPrint("== Checks ==")

-- CHECKS (each one guards behaviour that broke once, or would break silently):
--  1. every file loads, ADDON_LOADED completes without a Lua error, and the addon
--     leaves no globals behind beyond TattleDB and its slash command (the
--     namespace comes from the TOC vararg, so a global is a file forgetting that)
--  2. the load banner and the Interface Options entry both happen
--  3. modules register in TOC order (pairs() over a string-keyed table has no
--     defined order, so tabs and /tattle status would reshuffle run to run), and a
--     module that registers after ADDON_LOADED still gets settings and listeners
--  4. Swapblaster's real cast (spell 161399) is channeled: CHANNEL_START and
--     CHANNEL_STOP drive it, and the START/SUCCEEDED twins must not announce
--     the same cast twice
--  5. a channel that stops early is "cut short", not a completed swap
--  6. an instant cast alerts on success with no preceding START at all
--     (Life Grip never sends START; it used to be dropped for that reason)
--  7. the victim is named from the aura they are wearing, because 12.0 removed
--     the only API that carried a destination
--  8. chatType PRIVATE sends nothing to chat and stays in the console
--  9. scope "self" suppresses a cast we can prove missed us and still reports
--     one whose target we cannot resolve
-- 10. the config panel is one window with About + General + Screen Alerts plus
--     one tab per registered module
-- 11. the spell-ID editor loads defaults, collapses duplicates, gates Save on
--     real edits, persists on Save, and restores defaults on Reset
-- 12. /tattle probe toggles the event probe on and off, and prints nothing while
--     you are solo (nothing it measures can happen without a group)
-- 13. the combat gate the core applies: a Swapblaster start while its caster is
--     fighting is dropped, but a swap that started out of combat still announces a
--     landing that happens after combat began; the grab spells are dropped at any
--     phase while their caster is fighting
-- 14. the group's unit tokens name you once, as "player", and never as your own
--     raid index too -- which is what the watch list, the protected-person
--     sentences and the Rescue passenger list are all built from
-- 15. "Raid" chat is delivered on the instance channel in an LFR raid, which is
--     where a plain RAID send vanishes
-- 16. a grab or swap that a Neural Silencer bounced says so, naming the protected
--     member when there is only one candidate, and a protected caster firing a
--     Swapblaster out of combat is called out for it
-- 17. the optional watch list names the protected members and whoever has you
--     targeted, hides itself when you leave the group, and stops its timer when
--     switched off -- and a group member who puts one on says nothing at all
-- 18. what a cast event costs: one spell-name resolution per event however many
--     modules listen, alerts survive a client without C_Spell.GetSpellName, and
--     the cached group token lists die with the roster that produced them
-- 19. joining says nothing: wearing a Neural Silencer is never announced, only
--     being involved in a cast mentions it; pets, minions and NPCs are rejected
--     before their spell is ever named, unless a module asked for every caster,
--     and your own casts still alert
-- 20. one cast, one alert: the two event halves of a swap - and the same cast
--     reported once as your raid index and once as "player" - cannot announce a
--     swap twice, and neither a record that never terminated nor a settled
--     tombstone is allowed to mute that caster's next cast
-- 21. restricted content, which is where this addon's whole reason for existing
--     happens: with the spell ID, the cast GUID and the caster token all secret
--     values, a swap is still announced, is never given a name the client refused
--     to give, touches nothing the client forbids, and - on a build with no
--     secret-comparison API - is reported to the player as a refusal rather than
--     answered as "not a cast we watch". The probe reads the same events without
--     throwing, and `/tattle status` lists what was refused and how often.
-- 22. the core's start gate is proven to *drop* as well as to allow. A policy that
--     gated nothing is invisible to every other check in this file, and "start"
--     gating nothing is exactly what alpha.3 shipped.
-- 23. idle while you fight: while *this player* is fighting nothing is announced and
--     nothing is asked of the client, the same cast alerts once PLAYER_REGEN_ENABLED
--     fires, /tattle status says which state the addon believes it is in, the probe is
--     the one thing that keeps reporting, and /tattle off disarms it.
--
-- A module that throws while initializing is also in here, registered deliberately
-- before ADDON_LOADED: an unguarded initialize used to abort the handler after the
-- registry was filled, which produced an addon that had registered its modules and
-- then done nothing at all.
--
-- Five audits run alongside the checks. Two are about the stub: widget keys it does
-- not model are printed at the end (a new one is usually a typo), and a widget
-- setter handed `nil` where the client demands a number is a failure rather than a
-- shrug. Three are about the source, because part of the restricted-value bug class
-- cannot be made to raise at runtime in a Lua 5.1 harness at all.

check("all files load", #loadErrors == 0, table.concat(loadErrors, "; "))

local leakedGlobals = {}
for key in pairs(_G) do
    if not globalsBeforeLoad[key] and not ALLOWED_GLOBALS[key] then
        leakedGlobals[#leakedGlobals + 1] = key
    end
end
table.sort(leakedGlobals)
check("the addon leaves no globals behind beyond its saved variables and its slash command",
    #leakedGlobals == 0, table.concat(leakedGlobals, ", "))

-- Session problems, read the way /tattle status reads them. Needed here, at the first
-- check that cares about them, and by the restricted-content checks a thousand lines on.
local function countProblemOf(kind)
    local problems = Tattle.SessionProblems()
    local problem = problems[kind]
    return problem and problem.count or 0
end

local function problemSummary()
    local problems = Tattle.SessionProblems()
    local kinds = {}
    for kind in pairs(problems) do kinds[#kinds + 1] = kind end
    table.sort(kinds)
    local parts = {}
    for _, kind in ipairs(kinds) do parts[#parts + 1] = kind .. " x" .. problems[kind].count end
    return table.concat(parts, "; ") ~= "" and table.concat(parts, "; ") or "none"
end

local function countProblems()
    local total = 0
    for _, problem in pairs(Tattle.SessionProblems()) do total = total + problem.count end
    return total
end

-- Two modules registered before ADDON_LOADED, which is the only way to exercise the
-- module initialize loop from here: the late-registration path does not run initialize
-- at all. The first one throws. Before the loop was guarded, a throw here aborted
-- ADDON_LOADED after the module registry was filled but before the listener lists were
-- built, the settings were applied and the config tabs existed - an addon that had
-- registered three modules and then silently did nothing, noticed only as a taint line.
-- The second module exists to answer the question the first one raises: did the loop
-- carry on past it, or did everything after it in TOC order never initialize?
local initializedAfterThrow = 0
Tattle:RegisterModule("thrower", {
    name = "Deliberately broken",
    events = {},
    initialize = function() error("this module refuses to initialize", 0) end,
    onEvent = function() end,
})
Tattle:RegisterModule("survivor", {
    name = "Registered after the thrower",
    events = {},
    initialize = function() initializedAfterThrow = initializedAfterThrow + 1 end,
    onEvent = function() end,
})

local eventErrors = dispatch("ADDON_LOADED", "Tattle")
runTimers()
check("ADDON_LOADED completes without error", #eventErrors == 0, table.concat(eventErrors, "; "))

check("load banner printed",
    lastPrintContaining("loaded. Type /tattle") ~= nil,
    "no load line (a Lua error in ADDON_LOADED aborts the rest of the handler)")
check("Interface Options category registered",
    interfaceOptionsRegistered == 1, "got " .. interfaceOptionsRegistered)

-- The three together are the whole claim: the failing module was reported rather than
-- swallowed, the module behind it still got its initialize, and the rest of the handler
-- ran. Any one of them alone is what a half-fixed version still passes.
check("a module that throws while initializing is reported",
    countProblemOf("module thrower failed to initialize") == 1,
    "problems: " .. problemSummary())
check("and it does not stop the module registered behind it from initializing",
    initializedAfterThrow == 1, "initialize ran " .. initializedAfterThrow .. " time(s) for the survivor")

check("modules registered in TOC order",
    Tattle.moduleOrder[1] == "swapblaster" and Tattle.moduleOrder[2] == "lifegrip"
        and Tattle.moduleOrder[3] == "rescue",
    table.concat(Tattle.moduleOrder, ", "))

-- One event, one call per listener. The reported bug was alerts arriving twice, and
-- there are two ways for that to be the core's fault rather than a module's: a module
-- listing the same event twice in its own registration, and something waking the
-- dispatcher twice for one client event. Neither shows up in any other check here,
-- because a module that is called twice and dedupes internally *looks* correct. So the
-- counting happens on the module's own door, not on what it says.
local onEventCalls = {}
local originalHandlers = {}
for _, moduleId in ipairs(Tattle.moduleOrder) do
    local module = Tattle.modules[moduleId]
    originalHandlers[moduleId] = module.onEvent
    onEventCalls[moduleId] = 0
    local id = moduleId
    module.onEvent = function(event, ...)
        onEventCalls[id] = onEventCalls[id] + 1
        return originalHandlers[id](event, ...)
    end
end
-- raid3 in a five-deep raid is the one numbered token no other scenario in this file
-- dispatches a Swapblaster on, which is what keeps the record this arms from leaking
-- into a check after it. The clock is deliberately left alone, because a scenario that
-- moves it forward makes every absolute setClock after it a rewind.
resetWorld()
setGroup({ raid = true, count = 5, selfIndex = 4 })
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid3", "guid-one-call", 161399)
runTimers()
local callComplaints = {}
for _, moduleId in ipairs(Tattle.moduleOrder) do
    local wanted = 0
    for _, ev in ipairs(Tattle.modules[moduleId].events) do
        if ev == "UNIT_SPELLCAST_CHANNEL_START" then wanted = 1 end
    end
    if onEventCalls[moduleId] ~= wanted then
        callComplaints[#callComplaints + 1] = string.format("%s called %d time(s), wanted %d",
            moduleId, onEventCalls[moduleId], wanted)
    end
end
for _, moduleId in ipairs(Tattle.moduleOrder) do
    Tattle.modules[moduleId].onEvent = originalHandlers[moduleId]
end
check("one cast event wakes each listening module exactly once",
    #callComplaints == 0, table.concat(callComplaints, "; "))

-- A module that asks for the same event twice is the same mistake in its own file, and
-- the core now absorbs it -- which is why it has to be said out loud here: a repeat the
-- core quietly swallows is a repeat nobody ever fixes.
local duplicateEvents = {}
for _, moduleId in ipairs(Tattle.moduleOrder) do
    local seen = {}
    for _, ev in ipairs(Tattle.modules[moduleId].events) do
        if seen[ev] then
            duplicateEvents[#duplicateEvents + 1] = moduleId .. " lists " .. ev .. " twice"
        end
        seen[ev] = true
    end
end
check("no module asks for the same event twice",
    #duplicateEvents == 0, table.concat(duplicateEvents, "; "))

check("modules ship the spell IDs verified against the live 12.1.5 database",
    Tattle.modules.swapblaster.defaultSpellIDs[1] == 161399
        and Tattle.modules.lifegrip.defaultSpellIDs[1] == 73325
        and Tattle.modules.rescue.defaultSpellIDs[1] == 370666,
    "shipped spell IDs drifted from the verified ones")

-- /tattle status lists modules in registration order
local function statusModuleNames()
    local start = #printLog
    callSlash("status")
    local names = {}
    for i = start + 1, #printLog do
        local name = printLog[i]:match("^  %[(.-)%]")
        if name then names[#names + 1] = name end
    end
    return names
end
local printedOrder = statusModuleNames()
local expectedOrder = {}
for _, moduleId in ipairs(Tattle.moduleOrder) do
    expectedOrder[#expectedOrder + 1] = Tattle.modules[moduleId].name
end
check("/tattle status lists modules in registration order",
    table.concat(printedOrder, ", ") == table.concat(expectedOrder, ", "),
    table.concat(printedOrder, ", ") .. " vs " .. table.concat(expectedOrder, ", "))

local function alertMode(moduleId, chatType)
    local settings = TattleDB.modules[moduleId]
    settings.enabled = true
    settings.scope = "group"
    settings.alerts.console = false
    settings.alerts.chat = true
    settings.alerts.chatType = chatType
    settings.alerts.audio = false
    settings.alerts.screen = false
end

-- Swapblaster's real cast is the channeled spell 161399 ("Swap"), 1.5 sec, so
-- CHANNEL_START/CHANNEL_STOP are the events it actually produces.
alertMode("swapblaster", "YELL")
table.wipe(sentMessages)
setClock(1000)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-1", 161399)
runTimers()
check("channeled cast alerts on start", #sentMessages == 1, "got " .. #sentMessages)
check("start alert names the caster and the spell",
    sentMessages[1] and sentMessages[1].message:find("Donut is casting Swapblaster", 1, true),
    sentMessages[1] and sentMessages[1].message)
check("start alert uses the configured channel",
    sentMessages[1] and sentMessages[1].channel == "YELL",
    sentMessages[1] and sentMessages[1].channel)

-- START can arrive for the same cast as CHANNEL_START; that must not double up.
dispatch("UNIT_SPELLCAST_START", "raid1", "guid-1", 161399)
runTimers()
check("START alongside CHANNEL_START does not duplicate the alert",
    #sentMessages == 1, "got " .. #sentMessages)

setClock(1002)  -- 2.0 s elapsed on a 1.5 s window: the channel ran its full length
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-1", 161399)
runTimers()
check("channeled cast alerts on completion", #sentMessages == 2, "got " .. #sentMessages)
check("completion alert reports the swap",
    sentMessages[2] and sentMessages[2].message:find("Donut used Swapblaster", 1, true),
    sentMessages[2] and sentMessages[2].message)

dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid1", "guid-1", 161399)
runTimers()
check("SUCCEEDED alongside CHANNEL_STOP does not duplicate the alert",
    #sentMessages == 2, "got " .. #sentMessages)

-- A channel that ends early is not a completed swap.
table.wipe(sentMessages)
setClock(2000)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-2", 161399)
setClock(2001)  -- 1.0 s into a 1.5 s window
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid2", "guid-2", 161399)
runTimers()
check("a channel cut short is not reported as a completed swap",
    #sentMessages == 2
        and messageContaining("Pancakes's Swapblaster was cut short") ~= nil
        and messageContaining("Pancakes used Swapblaster") == nil,
    sentMessages[1] and sentMessages[1].message)

-- ============================================================================
-- Naming the other half of a swap
-- ============================================================================

-- The swap wears no aura, so unlike a grip there is no destination marker to read.
-- What is left is the caster's own target, which the toy requires ("Swaps your
-- location with another party member") and which the client exposes as
-- `<caster>target` when it exposes it at all. Both halves matter: the name when the
-- read works, and the old victim-free sentence, not a guess, when it does not.

resetWorld()
alertMode("swapblaster", "YELL")

setTarget("raid1", "raid2")
table.wipe(sentMessages)
setClock(4000)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-victim-1", 161399)
setClock(4002)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-victim-1", 161399)
runTimers()
local victimPair = (sentMessages[1] and sentMessages[1].message or "(none)")
    .. " / " .. (sentMessages[2] and sentMessages[2].message or "(none)")
-- "aiming at", not "on". This is the whole correction of this revision: all this client
-- was told is that Donut's interface had Pancakes selected, and that reading is exactly as
-- consistent with a @mouseover swap that never touched Pancakes as with one that did. The
-- check below covers the case where the client says more; until it does, this sentence is
-- the strongest thing either source supports.
check("a swap names the caster's target as where they were aiming, not as the victim",
    messageContaining("Donut is casting Swapblaster at Pancakes") ~= nil
    and messageContaining("Donut used Swapblaster - aiming at Pancakes") ~= nil
    and messageContaining("Donut used Swapblaster on") == nil,
    victimPair)

-- ============================================================================
-- The @mouseover swap, which is what that wording exists for
-- ============================================================================

-- Somebody grieving with this toy points it at one member through a macro while their own
-- target frame still shows another. The client's cast-target API knows the difference;
-- `<caster>target` does not, and reading only the second used to report Maple's swap as
-- Pancakes' to the whole raid. With the name readable, the spell's own target wins and the
-- bystander must not appear at all.
resetWorld()
-- Five members, and I hold raid4 so that raid5 is somebody else: the bystander/victim
-- distinction needs two members who are neither me nor the caster.
setGroup({ raid = true, count = 5, selfIndex = 4 })
alertMode("swapblaster", "YELL")
spellTargetNamesAreSecret = false
setSpellTarget("raid1", "raid5")                 -- the spell's target: Maple
setTarget("raid1", "raid2")                      -- their interface, still on Pancakes
table.wipe(sentMessages)
setClock(4050)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-mouse-1", 161399)
setClock(4052)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-mouse-1", 161399)
runTimers()
local mouseoverPair = (sentMessages[1] and sentMessages[1].message or "(none)")
    .. " / " .. (sentMessages[2] and sentMessages[2].message or "(none)")
check("a @mouseover swap names the member the spell was actually pointed at",
    messageContaining("Donut used Swapblaster on Maple") ~= nil,
    mouseoverPair)
-- Checked as its own claim rather than riding along as a condition of the one above,
-- because naming the bystander is the specific harm this whole chain exists to prevent.
check("and the bystander left sitting in the caster's target frame is not named",
    messageContaining("Pancakes") == nil,
    mouseoverPair)

-- The same cast on a client that hands the name over as a secret value, which the 12.1.x
-- docs treat as the ordinary answer for another player's cast. Resolved through the
-- sanctioned comparison it is still the spell's own target, so it still gets the stronger
-- sentence: secrecy on its own must not quietly downgrade a real answer to "aiming".
resetWorld()
setGroup({ raid = true, count = 5, selfIndex = 4 })
alertMode("swapblaster", "YELL")
spellTargetNamesAreSecret = true
secretCompareSupported = true
setSpellTarget("raid1", "raid5")
setTarget("raid1", "raid2")
table.wipe(sentMessages)
setClock(4060)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-mouse-2", 161399)
setClock(4062)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-mouse-2", 161399)
runTimers()
local secretNamed = (sentMessages[1] and sentMessages[1].message or "(none)")
    .. " / " .. (sentMessages[2] and sentMessages[2].message or "(none)")
check("a secret target name the client compared for us still gets the stronger sentence",
    messageContaining("Donut used Swapblaster on Maple") ~= nil,
    secretNamed)

-- Its own world: the block above left a spell target registered for raid1, and a check
-- that inherits somebody else's evidence is measuring the wrong thing.
resetWorld()
setGroup({ raid = true, count = 5, selfIndex = 4 })
setTarget("raid1", "player")
table.wipe(sentMessages)
setClock(4100)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-victim-2", 161399)
setClock(4102)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-victim-2", 161399)
runTimers()
check("being only the caster's target reads as aiming, both about you and at you",
    messageContaining("Donut is casting Swapblaster at you") ~= nil
    and messageContaining("Donut used Swapblaster - aiming at you") ~= nil,
    (sentMessages[1] and sentMessages[1].message or "(none)")
    .. " / " .. (sentMessages[2] and sentMessages[2].message or "(none)"))

-- And when the client will say the spell itself was pointed at you, that deserves the
-- stronger sentence - "am I the one being teleported" is the question a player actually
-- has, and "did that spell target me" is the one target question with no secrecy flag on
-- it at all.
resetWorld()
setGroup({ raid = true, count = 5, selfIndex = 4 })
alertMode("swapblaster", "YELL")
setSpellTarget("raid1", "player")
table.wipe(sentMessages)
setClock(4150)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-victim-self", 161399)
setClock(4152)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-victim-self", 161399)
runTimers()
check("being the spell's own target reads as landing on you",
    messageContaining("Donut used Swapblaster on you") ~= nil,
    (sentMessages[1] and sentMessages[1].message or "(none)")
    .. " / " .. (sentMessages[2] and sentMessages[2].message or "(none)"))

-- No target synced at all: the victim stays out of the sentence rather than being
-- guessed or announced as unknown.
resetWorld()
alertMode("swapblaster", "YELL")
table.wipe(sentMessages)
setClock(4200)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-victim-3", 161399)
setClock(4202)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-victim-3", 161399)
runTimers()
local unreadable = (sentMessages[1] and sentMessages[1].message or "")
    .. " / " .. (sentMessages[2] and sentMessages[2].message or "")
check("an unreadable target names nobody rather than guessing",
    messageContaining("Donut is casting Swapblaster") ~= nil
    and messageContaining("Donut used Swapblaster") ~= nil
    and unreadable:find(" at ") == nil and unreadable:find(" on ") == nil,
    unreadable)

-- A caster looking at something that is not a player: the swap cannot have used
-- it, so there is no victim to name.
setTarget("raid1", "npc1")
table.wipe(sentMessages)
setClock(4300)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-victim-4", 161399)
setClock(4302)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-victim-4", 161399)
runTimers()
local notPlayer = (sentMessages[1] and sentMessages[1].message or "")
    .. " / " .. (sentMessages[2] and sentMessages[2].message or "")
check("a caster with an NPC targeted names nobody",
    notPlayer:find(" at ") == nil and notPlayer:find(" on ") == nil, notPlayer)

-- Cost, since this runs on every swap in a 25-man raid: the target lookup answers
-- "your client was not told" with one UnitExists, and spends no UnitIsUnit at all.
-- Back to a group with no synced targets first (the checks above left one set), and
-- with the token cache warm so the counters hold only this lookup's own calls.
resetWorld()
Tattle.GroupUnitTokens()   -- warm the cache, so the count is the lookup's own
local existsBefore, isUnitBefore = unitExistsCalls, unitIsUnitCalls
check("reading an unreadable target costs one UnitExists and no UnitIsUnit",
    Tattle.GroupMemberTargetOf("raid1") == nil
    and unitExistsCalls - existsBefore == 1
    and unitIsUnitCalls - isUnitBefore == 0,
    "UnitExists +" .. (unitExistsCalls - existsBefore)
    .. ", UnitIsUnit +" .. (unitIsUnitCalls - isUnitBefore))

setTarget("raid1", "raid2")
existsBefore, isUnitBefore = unitExistsCalls, unitIsUnitCalls
check("a readable target is resolved by identity, not by string",
    Tattle.GroupMemberTargetOf("raid1") == "raid2"
    and unitExistsCalls - existsBefore == 1
    and unitIsUnitCalls - isUnitBefore >= 1,
    "resolved " .. tostring(Tattle.GroupMemberTargetOf("raid1")))

-- The read also has to survive the two-token problem: set the target where only
-- your raid index would match, and the answer must still be "player".
setTarget("raid1", "raid" .. group.selfIndex)
check("a target that is you resolves to \"player\", not to your raid index",
    Tattle.GroupMemberTargetOf("raid1") == "player",
    tostring(Tattle.GroupMemberTargetOf("raid1")))

-- Two swaps from the same caster, the second one reaching us only as a completion
-- (the classic shapes: out of range, a /reload mid-channel, a client that reports
-- the toy only when it resolves). Deduplicating the two halves of *one* cast must
-- not turn into muting every later cast by that unit.
resetWorld()
alertMode("swapblaster", "YELL")
table.wipe(sentMessages)
setClock(4500)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid1", "guid-swap-a", 161399)
runTimers()
setClock(4600)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid1", "guid-swap-b", 161399)
runTimers()
check("a second swap from the same caster is not muted by the first one's record",
    #sentMessages == 2, "got " .. #sentMessages)

-- ...and the dedupe that record exists for still holds inside one cast.
resetWorld()
table.wipe(sentMessages)
setClock(4700)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid1", "guid-swap-c", 161399)
setClock(4701)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-swap-c", 161399)
runTimers()
check("the two halves of one cast are still announced once",
    #sentMessages == 1, "got " .. #sentMessages)

-- A dump for the duplicate-alert checks below: when a count is wrong, "got 4" on
-- its own tells you nothing about which four.
local function messageLog()
    local parts = {}
    for i = 1, #sentMessages do table.insert(parts, "[" .. i .. "] " .. sentMessages[i].message) end
    return "got " .. #sentMessages .. ": " .. table.concat(parts, "  |  ")
end

-- Every scenario below runs in a five-deep raid, on the two raid tokens no
-- neighbouring check uses, and puts the alert settings it changed back when it is
-- done. Two reasons, both of them about leaks:
--
--   * A module's cast records survive resetWorld(). Resetting the *world* is not
--     wiping what a module remembers, and a scenario that quietly inherited a record
--     from the one before it - or handed one to the check after it - would pass, or
--     fail, for the wrong reason. Fresh tokens make the records uninheritable.
--   * alertMode() writes into the shipped settings, which the checks after this one
--     read as they found them.
local savedSettings = {}
local function isolateAlerts(moduleId)
    local settings = TattleDB.modules[moduleId]
    if savedSettings[moduleId] then return end
    local snapshot = { scope = settings.scope, enabled = settings.enabled, alerts = {} }
    for key, value in pairs(settings.alerts) do snapshot.alerts[key] = value end
    savedSettings[moduleId] = snapshot
    alertMode(moduleId, "YELL")
end

local function fiveDeepRaid(selfIndex)
    resetWorld()
    setGroup({ raid = true, count = 5, selfIndex = selfIndex })
end

local function restoreAlertSettings()

    for moduleId, snapshot in pairs(savedSettings) do
        local settings = TattleDB.modules[moduleId]
        settings.scope, settings.enabled = snapshot.scope, snapshot.enabled
        for key, value in pairs(snapshot.alerts) do settings.alerts[key] = value end
    end
    table.wipe(savedSettings)
    resetWorld()
end

-- The other half of a cast can arrive *after* that cast was already settled. A
-- resolved record used to suppress terminal events only, so the order a live client
-- really produces for an interrupted channeled swap - CHANNEL_START, INTERRUPTED, and
-- then the plain START that the channeled-spell hack also sends - armed a second
-- record for a cast that had already been announced, and every alert for it came out
-- twice. That is the reported "Malloc is casting Swapblaster" and "Malloc's
-- Swapblaster was interupted", both x2, for one swap.
fiveDeepRaid(5)
isolateAlerts("swapblaster")
table.wipe(sentMessages)
setClock(4800)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid4", "guid-half-late", 161399)
setClock(4801)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "raid4", "guid-half-late", 161399)
setClock(4802)
local halfLate = dispatch("UNIT_SPELLCAST_START", "raid4", "guid-half-late", 161399)
runTimers()
check("a late start half of a settled cast is not armed as a second cast",
    #halfLate == 0 and #sentMessages == 2, messageLog())
check("and what survives is the start and the interrupt, in that order",
    sentMessages[1] and sentMessages[1].message:find("is casting Swapblaster", 1, true) ~= nil
        and sentMessages[2] and sentMessages[2].message:find("was interrupted", 1, true) ~= nil,
    messageLog())

-- The mirror image: a settled plain cast whose channeled half arrives late, its own
-- terminal half included.
fiveDeepRaid(5)
table.wipe(sentMessages)
setClock(4900)
dispatch("UNIT_SPELLCAST_START", "raid5", "guid-half-early", 161399)
setClock(4901)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "raid5", "guid-half-early", 161399)
setClock(4902)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid5", "guid-half-early", 161399)
local lateChannel = dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid5", "guid-half-early", 161399)
runTimers()
check("and the same in the other order: a late channel half changes nothing",
    #lateChannel == 0 and #sentMessages == 2, messageLog())

-- (The clocks in this whole section run forward in file order, by a slice each.
-- A module's records outlive a world reset, so a scenario that reused a token *or*
-- a timestamp from the one before it would inherit that record and pass or fail for
-- the wrong reason.)
--
-- The halves of one client-side action do not have to arrive carrying the same
-- identity. The plain half and the channeled half are separate client records of one
-- cast, each with its own GUID -- which is exactly why keying the dedupe on the GUID
-- *alone* would satisfy the check above and leave the reported duplicate untouched.
fiveDeepRaid(5)
table.wipe(sentMessages)
setClock(4940)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid5", "guid-half-b1", 161399)
setClock(4941)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "raid5", "guid-half-b1", 161399)
setClock(4941.5)
dispatch("UNIT_SPELLCAST_START", "raid5", "guid-half-b2", 161399)
setClock(4942)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "raid5", "guid-half-b2", 161399)
runTimers()
check("the two halves of one swap, each carrying its own identity, are still one alert",
    #sentMessages == 2, messageLog())

fiveDeepRaid(5)
table.wipe(sentMessages)
setClock(4960)
dispatch("UNIT_SPELLCAST_START", "raid5", "guid-half-c1", 161399)
setClock(4961)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "raid5", "guid-half-c1", 161399)
setClock(4961.5)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid5", "guid-half-c2", 161399)
setClock(4962)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid5", "guid-half-c2", 161399)
runTimers()
check("and neither half is announced on its own once that cast has an outcome",
    #sentMessages == 2, messageLog())

-- The other way one cast becomes two alerts: a raid client that lists you as your own
-- raidN index reports your casts both as "player" and as that index. State keyed on
-- whichever token an event happened to carry holds two records for one cast, and each
-- record gets to announce it.
fiveDeepRaid(4)   -- you are raid4 here, so raid4 and player name the same player
table.wipe(sentMessages)
setClock(5000)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid4", "guid-two-tokens", 161399)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "player", "guid-two-tokens", 161399)
runTimers()
check("one cast reported under your raid index and as player is one alert",
    #sentMessages == 1, messageLog())

fiveDeepRaid(4)
table.wipe(sentMessages)
setClock(5100)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid4", "guid-two-tokens", 161399)
setClock(5101)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "player", "guid-two-tokens", 161399)
setClock(5102)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "raid4", "guid-two-tokens", 161399)
runTimers()
check("and its interrupt, reported under both tokens again, is one alert",
    #sentMessages == 2, messageLog())

-- The cost of the rule above, and the side of the trade that matters more. This toy has
-- no cooldown worth speaking of, so "refused, retargeted, fired again" is two seconds
-- apart and entirely ordinary - and suppressing every start while a fresh record exists
-- meant the second swap produced no alerts at all, for the whole eight second window.
-- What tells a second attempt from the late half of the first cast is which event family
-- the start arrived as, not how many seconds have passed: one cast sends at most one
-- plain start and one channeled start, so a second plain start after the cast already
-- has an outcome cannot be that cast.
--
-- What it cannot tell apart, and does not pretend to: a second attempt whose first event
-- happens to be of the *other* family is read as the late half of the first, and stays
-- unannounced. Nothing in the event stream separates those two, and the choice made is
-- to lose one alert rather than to announce a cast twice.
fiveDeepRaid(5)
table.wipe(sentMessages)
setClock(5140)
dispatch("UNIT_SPELLCAST_START", "raid3", "guid-second-attempt-1", 161399)
setClock(5141)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "raid3", "guid-second-attempt-1", 161399)
runTimers()
local refusedFirst = #sentMessages
setClock(5143)   -- two seconds later: a second, separate, real attempt
dispatch("UNIT_SPELLCAST_START", "raid3", "guid-second-attempt-2", 161399)
setClock(5144)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "raid3", "guid-second-attempt-2", 161399)
runTimers()
check("two separate swaps two seconds apart are announced as two swaps",
    refusedFirst == 2 and #sentMessages == 4, messageLog())
check("which is the start and then the interrupt, not the same message twice",
    sentMessages[1].message:find("is casting", 1, true) ~= nil
        and sentMessages[2].message:find("was interrupted", 1, true) ~= nil
        and sentMessages[1].message ~= sentMessages[2].message,
    messageLog())

-- A record armed by a start that never terminated used to hang around forever, and an
-- unresolved record suppresses everything that follows: one cast whose end this client
-- never reported muted that unit's Swapblaster for the rest of the session.
fiveDeepRaid(5)
table.wipe(sentMessages)
setClock(5200)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid5", "guid-never-ended", 161399)
runTimers()
local mutedFirst = #sentMessages
setClock(5260)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid5", "guid-the-next-one", 161399)
runTimers()
check("a cast that was never terminated stops muting the unit once it is stale",
    mutedFirst == 1 and #sentMessages == 2, messageLog())

-- And the settled record must expire the same way, or its tombstone outlives the cast
-- it was a tombstone for. Same GUID on purpose: GUID equality cannot be what keeps a
-- mute alive forever.
fiveDeepRaid(5)
table.wipe(sentMessages)
setClock(5300)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid4", "guid-ancient", 161399)
setClock(5301)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "raid4", "guid-ancient", 161399)
runTimers()
local settledFirst = #sentMessages
setClock(5360)
local ancient = dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid4", "guid-ancient", 161399)
runTimers()
check("a settled record older than its window does not mute a fresh cast",
    #ancient == 0 and settledFirst == 2 and #sentMessages == 3, messageLog())

-- The same permanent-mute shape in the grip modules, which keyed their state on a
-- boolean rather than on any time at all: a START that never got an outcome left the
-- unit armed for the rest of the run, so any later INTERRUPTED - of a different cast
-- entirely - was announced as if it belonged to the first one.
fiveDeepRaid(5)
isolateAlerts("lifegrip")
table.wipe(sentMessages)
setClock(5400)
dispatch("UNIT_SPELLCAST_START", "raid5", "grip-abandoned", 73325)
runTimers()
local gripArmedCount = #sentMessages
setClock(5460)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "raid5", "grip-someone-else", 73325)
runTimers()
check("an abandoned arm does not announce a much later interrupt as its own",
    gripArmedCount == 1 and #sentMessages == 1, messageLog())

fiveDeepRaid(5)
table.wipe(sentMessages)
setClock(5500)
dispatch("UNIT_SPELLCAST_START", "raid4", "grip-fresh", 73325)
setClock(5501)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "raid4", "grip-fresh", 73325)
runTimers()
check("while an interrupt inside the window for the cast it belongs to is announced",
    #sentMessages == 2, messageLog())

restoreAlertSettings()

-- ==========================================================================
-- Restricted content: M+, rated PvP, and the values a 12.x client will not
-- hand this addon
-- ==========================================================================
--
-- The alpha.3 crash was not a nil check somebody forgot. In restricted content
-- the client hands cast events *secret* values - the spell ID, the name derived
-- from it, the caster token, the cast GUID - and a secret value may only be given
-- to an API documented to accept one. `type()` still answers "string", so the
-- guard that looked correct (`if type(name) == "string"`) passed, and the next
-- line died comparing that string with a literal. Restricted content is also the
-- only place M+ and rated PvP griefing happens, so this is not an edge case the
-- feature can afford to get wrong: it is the case the feature exists for.
--
-- The checks below run the real dispatch path with every event argument secret.
-- They assert three separate things: the alert still happens, the alert never
-- claims a name the client refused to give, and the addon never touches a value
-- the client forbids (the stub counts each refusal it was asked to make).

fiveDeepRaid(5)
isolateAlerts("swapblaster")
table.wipe(sentMessages)
Secret.setContext(true)
local secretRefusals = Secret.refusals()
local problemsQuiet = countProblems()

-- Caster token, cast GUID and spell ID, all three secret, exactly as a Mythic+
-- client delivers them.
setClock(5600)
local restrictedCast = dispatch("UNIT_SPELLCAST_CHANNEL_START",
    Secret.asSecret("raid4"), Secret.asSecret("guid-restricted"), Secret.asSecret(161399))
runTimers()
check("a swap inside restricted content is still announced",
    #restrictedCast == 0 and #sentMessages == 1, messageLog())
check("naming it falls back to someone, never to a name this client would not print",
    messageContaining("someone is casting Swapblaster") ~= nil, messageLog())

setClock(5601)
local restrictedEnd = dispatch("UNIT_SPELLCAST_INTERRUPTED",
    Secret.asSecret("raid4"), Secret.asSecret("guid-restricted"), Secret.asSecret(161399))
runTimers()
check("its secret-carrying interrupt half is announced once, not twice",
    #restrictedEnd == 0 and #sentMessages == 2, messageLog())

-- The reported duplicate, in the content it was actually reported from: one cast
-- of yours, delivered once as "player" and once as your own raid index, both
-- under secret tokens.
fiveDeepRaid(4)
table.wipe(sentMessages)
setClock(5700)
dispatch("UNIT_SPELLCAST_CHANNEL_START",
    Secret.asSecret("raid4"), Secret.asSecret("guid-self-a"), Secret.asSecret(161399))
dispatch("UNIT_SPELLCAST_CHANNEL_START",
    Secret.asSecret("player"), Secret.asSecret("guid-self-b"), Secret.asSecret(161399))
runTimers()
check("your own swap, reported twice under two secret tokens, alerts once",
    #sentMessages == 1, messageLog())

fiveDeepRaid(4)
table.wipe(sentMessages)
setClock(5800)
dispatch("UNIT_SPELLCAST_CHANNEL_START",
    Secret.asSecret("raid4"), Secret.asSecret("guid-self-c"), Secret.asSecret(161399))
setClock(5801)
dispatch("UNIT_SPELLCAST_INTERRUPTED",
    Secret.asSecret("player"), Secret.asSecret("guid-self-c"), Secret.asSecret(161399))
setClock(5802)
dispatch("UNIT_SPELLCAST_INTERRUPTED",
    Secret.asSecret("raid4"), Secret.asSecret("guid-self-c"), Secret.asSecret(161399))
runTimers()
check("and its interrupt, delivered under both secret tokens, alerts once",
    #sentMessages == 2, messageLog())

check("the addon never tried to look inside a value the client forbids",
    Secret.refusals() == secretRefusals,
    "the client was asked to refuse " .. (Secret.refusals() - secretRefusals) .. " more time(s)")
check("and none of it needed a problem reported to work",
    countProblems() == problemsQuiet,
    "reported problems: " .. tostring(countProblems() - problemsQuiet))

-- A secret spell that is *not* one Tattle watches - which in a Mythic+ key is most of
-- what the raid is casting. "The client compared it and said no" and "the client would
-- not compare it at all" are different answers, and the code that decided that used to
-- compute them with `answered and false or nil`, an idiom that cannot produce `false`.
-- Mistake the two and every other player's cooldown in the instance becomes a reported
-- refusal, `/tattle status` fills with a single line repeated hundreds of times, and the
-- one place that distinguishes a real restriction from ordinary casting stops being
-- readable. So: no alert, and no problem either.
fiveDeepRaid(5)
table.wipe(sentMessages)
local problemsBeforeUnwatched = countProblems()
Secret.setContext(true)
setClock(5840)
local unwatchedSecret = dispatch("UNIT_SPELLCAST_CHANNEL_START",
    Secret.asSecret("raid4"), Secret.asSecret("guid-unwatched"), Secret.asSecret(162217))
Secret.setContext(false)
runTimers()
check("a secret cast of a spell Tattle does not watch is not announced",
    #unwatchedSecret == 0 and #sentMessages == 0, messageLog())
check("and it is not treated as a refusal either, because the client did answer",
    countProblems() == problemsBeforeUnwatched,
    "reported " .. (countProblems() - problemsBeforeUnwatched) .. " extra problem(s): " .. problemSummary())

-- The client named the cast and then refused to say whether it was one of ours:
-- a build with no secret-comparison API. Answering that "no" would silently drop
-- every swap in the exact content the alerts are for, which is the failure the
-- original bug report was about ("nothing fired in M+"). It has to be said out
-- loud, and counted, and it must never be reported as an ordinary non-cast.
fiveDeepRaid(5)
table.wipe(sentMessages)
local beforeDenied = countProblems()
secretCompareSupported = false
setClock(5900)
local denied = dispatch("UNIT_SPELLCAST_CHANNEL_START",
    Secret.asSecret("raid4"), Secret.asSecret("guid-denied"), Secret.asSecret(161399))
secretCompareSupported = true
Secret.setContext(false)
runTimers()
check("a cast the client will not compare is announced as nothing rather than as no cast",
    #denied == 0 and #sentMessages == 0, messageLog())
check("and that refusal is told to you, once, in chat",
    lastPrintContaining("would not say whether a cast was one Tattle watches") ~= nil)
check("and it is counted where /tattle status can reach it",
    countProblems() == beforeDenied + 1)
-- Belt for the same command: whatever a module or the core decides to report, the line
-- it reports has to be something /tattle status can print. The client's Lua 5.1
-- string.format raises on a nil where a newer one prints "nil", so a report without a
-- detail used to break the one command that exists to show reports - and only on the
-- Lua that ships with the game, which is the kind of bug no local run ever sees.
-- A report that arrived with no detail at all, which is what a module that just wants
-- to say "something went wrong" writes. Reported here on purpose, before the loop below,
-- so that loop is reading a real mixture rather than the only shape the core happens to
-- report today.
Tattle.ReportProblem("a problem reported with no detail, for the printer's sake")
do
    local unprintable = {}
    for kind, problem in pairs(Tattle.SessionProblems()) do
        if type(problem.detail) ~= "string" then
            unprintable[#unprintable + 1] = kind .. " (detail is " .. type(problem.detail) .. ")"
        end
    end
    check("every problem this session reported has something /tattle status can print",
        #unprintable == 0, table.concat(unprintable, "; "))
end
do
    -- And printing them all has to work. The client's Lua 5.1 string.format raises on a
    -- nil where a newer one prints "nil", so this is the check that only fails in CI if
    -- the two guards in Core.lua and Commands.lua both come back out.
    local printedOK, printErr = callSlash("status")
    check("so /tattle status prints every report, detail or none",
        printedOK and lastPrintContaining("a problem reported with no detail") ~= nil,
        tostring(printErr))
end
callSlash("status")
check("so /tattle status names the problem and its count",
    lastPrintContaining("the client would not say whether a cast was one Tattle watches") ~= nil
        and lastPrintContaining("C_SecretComparisons is unavailable") ~= nil)

-- The probe reads the same event arguments a module sees, and it reads them for
-- units a module would never ask about. It has to describe what it was refused
-- instead of dying on it.
fiveDeepRaid(5)
Secret.setContext(true)
callSlash("probe")
setClock(5910)
local probeErrors = dispatch("UNIT_SPELLCAST_CHANNEL_START",
    Secret.asSecret("raid4"), Secret.asSecret("guid-probe"), Secret.asSecret(161399))
runTimers()
Secret.setContext(false)
callSlash("probe")
do
    -- The probe prints one line per cast event, with each argument described rather
    -- than read. On a real client the description of a secret value is
    -- "secret (not printable)"; in this stub the stand-in is an unindexable table,
    -- so the wording is "not readable". What the check cares about is that it said
    -- it could not look, printed no name the client had refused, and survived.
    local probeLine = lastPrintContaining("UNIT_SPELLCAST_CHANNEL_START") or ""
    local described = probeLine:find("not readable", 1, true) ~= nil
        or probeLine:find("not printable", 1, true) ~= nil
    check("the probe reads a restricted event without throwing",
        #probeErrors == 0 and described, probeLine)
    check("and does not print a caster name this client would not print",
        probeLine:find("Syrup", 1, true) == nil, probeLine)
end

-- Position scenarios run with your own index at raid4, so that raid5 is somebody
-- else: the probe collapses your raid index into "player" and names you "Me", and a
-- check that pulled a swap on your own index would be testing the wrong sentence.
--
-- The two argument-order mistakes this file had, pinned down. They were not style
-- problems: both made the probe print "none exposed" about a client that had
-- answered, so every destination report the beta sent back was read through them.
-- UNIT_SPELLCAST_SENT is (unit, target:cstring, castGUID, spellID) in the client's
-- own docs - so arg 3 is the cast GUID, not the spell, and a destination searched for
-- from arg 4 upwards cannot find the one argument that carries it.
resetWorld()
fiveDeepRaid(5)
callSlash("probe")
setClock(5914)
local sentMark = #printLog
local sentErrors = dispatch("UNIT_SPELLCAST_SENT", "raid1", "Pancakes", "guid-1", 161399)
runTimers()
callSlash("probe")
do
    local line = lastPrintFrom(sentMark, "UNIT_SPELLCAST_SENT") or ""
    check("the probe reads SENT's spell ID from arg 4 rather than the cast GUID at arg 3",
        #sentErrors == 0 and line:find("spell: Swap", 1, true) ~= nil, line)
    check("and reads SENT's destination from arg 2, resolved to the member it belongs to",
        line:find("dest: Pancakes [raid2]", 1, true) ~= nil
            and line:find("none exposed", 1, true) == nil, line)
    -- The payload dump is what a future patch gets caught on, so it has to print a
    -- number as a number. "none" in this addon means "the client sent nothing", and a
    -- spell ID shown as "none" is the exact false negative the two checks above exist
    -- to prevent - one step further down the same line.
    local payload = lastPrintFrom(sentMark, "payload:") or ""
    check("and dumps the payload with plain numbers printed as numbers, not as \"none\"",
        payload:find("arg2=Pancakes", 1, true) ~= nil
            and payload:find("arg3=guid-1", 1, true) ~= nil
            and payload:find("arg4=161399", 1, true) ~= nil, payload)
end

-- The same line where the client withholds the name. A withheld destination is still
-- a destination, and the two need to read differently: "this client exposes nothing"
-- and "this client answered and we were not allowed to look" are different answers for
-- anybody deciding whether an alert may name a victim. (The stub stands in for a
-- secret string with an unindexable table, so its wording is the "not readable" one;
-- a real client says "secret", and the check accepts either.)
resetWorld()
fiveDeepRaid(5)
callSlash("probe")
Secret.setContext(true)
setClock(5918)
dispatch("UNIT_SPELLCAST_SENT", "raid1", Secret.asSecret("Pancakes"), "guid-2", 161399)
runTimers()
Secret.setContext(false)
callSlash("probe")
do
    local line = lastPrintContaining("UNIT_SPELLCAST_SENT") or ""
    check("a withheld SENT destination is reported as withheld rather than as absent",
        line:find("none exposed", 1, true) == nil
            and (line:find("secret", 1, true) ~= nil or line:find("not readable", 1, true) ~= nil)
            and line:find("Pancakes", 1, true) == nil, line)
end

-- And the position channel the corroborator is going to rest on: two samples of a
-- swap, and the claim it is allowed to make from them. The cast is the module's own
-- 161399, the movers are the caster and one member, and everybody else stands still
-- so that a match here is the exchange being found rather than a tolerance being
-- generous. Where the probe says an exchange happened, it also has to say whether the
-- caster's own target read agrees - the disagreement a @mouseover cast produces.
resetWorld()
fiveDeepRaid(4)
alertMode("swapblaster", "YELL")
callSlash("probe")
setClock(5922)
-- Donut (raid1) channels a swap on Maple (raid5), who is 30 yards away, and has
-- Maple targeted as well: the ordinary case, where the caster's own target read and
-- what physically happened say the same thing.
setTarget("raid1", "raid5")
moveUnit("raid1", 100, 100)
moveUnit("raid5", 130, 100)
moveUnit("raid2", 105, 100)
local swapMark = #printLog
local posErrors = dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-swap", 161399)
runTimers()
setClock(5923)
-- Halfway through the channel, Pancakes walks fifteen yards across the room. The
-- probe takes its third sample here, which is how an allowance for "the victim was
-- moving" ends up justified by what this group was actually doing instead of by an
-- assumption about who was mounted where.
moveUnit("raid2", 120, 100)
dispatch("UNIT_SPELLCAST_CHANNEL_UPDATE", "raid1", "guid-swap", 161399)
runTimers()
setClock(5924)
-- The swap resolves: the two have traded places.
moveUnit("raid1", 130, 100)
moveUnit("raid5", 100, 100)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-swap", 161399)
runTimers()
callSlash("probe")
do
    local line = lastPrintFrom(swapMark, "traded places") or ""
    check("a measured trade of places is reported as an exchange, with the partner named",
        #posErrors == 0 and line:find("Maple [raid5]", 1, true) ~= nil, line)
    local targetLine = lastPrintFrom(swapMark, "target read:") or ""
    check("and says the caster's target read agrees with the exchange when it does",
        targetLine:find("agrees with the exchange", 1, true) ~= nil, targetLine)
    local driftLine = lastPrintFrom(swapMark, "mid-channel - group drifted") or ""
    check("a mid-channel sample measures how far the group moved while the channel ran",
        driftLine:find("up to 15.0 yd", 1, true) ~= nil
            and driftLine:find("(1 of 5 readable members moving", 1, true) ~= nil, driftLine)
    check("and the drift it measured is still there to be read at the end of the cast",
        lastPrintFrom(swapMark, "drift observed before the swap resolved: up to 15.0 yd") ~= nil, driftLine)
    -- The channel window printed raw rather than as a verdict. The real client returns
    -- these returns in milliseconds and the Swapblaster module subtracts them as
    -- seconds; the beta's own output is what proves it, so the probe prints the pair
    -- and both readings instead of picking one and being possibly wrong about it.
    check("and logs the channel's raw timing pair with both readings of its units",
        lastPrintFrom(swapMark, "channel window: pair") ~= nil
            and lastPrintFrom(swapMark, "milliseconds means") ~= nil, driftLine)
end

-- The case the whole victim-naming question turns on: a @mouseover cast leaves the
-- caster's hard target on somebody who was never involved. The swap still happens and
-- the coordinates still show who was moved, so an alert built on the target read
-- would accuse the bystander. The probe's job is to print that disagreement as the
-- loud thing it is.
resetWorld()
fiveDeepRaid(4)
callSlash("probe")
setClock(5928)
setTarget("raid1", "raid2")   -- Pancakes is the last hard target; Maple is the real victim
moveUnit("raid1", 100, 100)
moveUnit("raid5", 130, 100)
local mouseMark = #printLog
local mouseErrors = dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-mouse", 161399)
runTimers()
setClock(5929)
moveUnit("raid1", 130, 100)
moveUnit("raid5", 100, 100)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-mouse", 161399)
runTimers()
callSlash("probe")
do
    local line = lastPrintFrom(mouseMark, "DISAGREES") or ""
    check("a target read that names the wrong member is printed as a disagreement, not as a victim",
        #mouseErrors == 0
            and line:find("read Pancakes [raid2]", 1, true) ~= nil
            and line:find("exchange says Maple [raid5]", 1, true) ~= nil, line)
    check("and the exchange still names the member who was actually moved",
        lastPrintFrom(mouseMark, "Maple [raid5] traded places") ~= nil, line)
end

-- Two members who both end up where the caster began is an ambiguity, and the probe
-- has to refuse to choose rather than accuse one of them.
resetWorld()
fiveDeepRaid(4)
callSlash("probe")
setClock(5932)
moveUnit("raid1", 100, 100)
moveUnit("raid2", 100, 2)
moveUnit("raid3", 100, -2)
local ambMark = #printLog
local ambErrors = dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-amb", 161399)
runTimers()
setClock(5933)
moveUnit("raid1", 100, 0)
moveUnit("raid2", 100, 100)
moveUnit("raid3", 100, 100)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-amb", 161399)
runTimers()
callSlash("probe")
do
    local line = lastPrintFrom(ambMark, "no exchange reported") or ""
    check("two members who both match the caster's start is refused as ambiguous",
        #ambErrors == 0
            and line:find("2 members ended up where the mover began", 1, true) ~= nil
            and lastPrintFrom(ambMark, "traded places") == nil, line)
end

-- Nobody traded places: the caster moved and nobody arrived where they started. The
-- honest output is "no exchange", and it must not name anybody.
resetWorld()
fiveDeepRaid(4)
callSlash("probe")
setClock(5936)
moveUnit("raid1", 100, 100)
local noneMark = #printLog
local noneErrors = dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-none", 161399)
runTimers()
setClock(5937)
moveUnit("raid1", 140, 100)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-none", 161399)
runTimers()
callSlash("probe")
do
    local line = lastPrintFrom(noneMark, "no exchange reported") or ""
    check("a cast that moved nobody is reported as no exchange, naming nobody",
        #noneErrors == 0 and line:find("nobody ended up where the mover began", 1, true) ~= nil
            and lastPrintFrom(noneMark, "traded places") == nil, line)
end

-- A member whose position this client is not told cannot be found by an exchange at
-- all, and that has to come out as a hole in the sample rather than as a member
-- standing at the origin. The failure mode worth guarding here is a corroborator that
-- matches somebody against a missing sample and then names them for it.
resetWorld()
fiveDeepRaid(4)
callSlash("probe")
setClock(5940)
moveUnit("raid1", 100, 100)
unpositionUnit("raid5")
local gapMark = #printLog
local gapErrors = dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-gap", 161399)
runTimers()
setClock(5941)
moveUnit("raid1", 130, 100)
local stopGapErrors = dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-gap", 161399)
runTimers()
callSlash("probe")
do
    local line = lastPrintFrom(gapMark, "refused or had no position") or ""
    check("a member with no readable position is reported as a hole in the sample",
        #gapErrors == 0 and #stopGapErrors == 0
            and line:find("1 member(s) refused or had no position", 1, true) ~= nil, line)
    check("and nobody is named as the partner on a sample that cannot see them",
        lastPrintFrom(gapMark, "traded places") == nil, line)
end

-- ============================================================================
-- Where a victim's name comes from
-- ============================================================================

-- What these checks care about is not which member gets named but whether the answer
-- carries how it was learned. "spell-target" is a fact about the spell and entitles an
-- alert to say the spell arrived; "unit-target" is a fact about the caster's interface
-- and entitles it to say only where they were aiming. Naming the wrong member is the
-- failure this whole design exists to prevent, so the weaker source has to stay
-- identifiable at the call site rather than arrive as a bare token.

resetWorld()
fiveDeepRaid(4)
setSpellTarget("raid1", "raid5")                 -- what the client's own target API believes
setTarget("raid1", "raid2")                      -- whom the caster last clicked
spellTargetNamesAreSecret = false                -- this build lets the name be read
do
    local token, source = Tattle.CastTargetOf("raid1")
    check("a readable cast-target name wins over the caster's hard target",
        token == "raid5" and source == "spell-target",
        tostring(token) .. " / " .. tostring(source))
end

-- The last resort has to be identifiable as the last resort. Here the name API answers
-- nothing at all, so the only thing left is the caster's own target - a fact about their
-- interface, and one that a @mouseover cast leaves sitting on whoever they last clicked.
-- A module that could not tell this answer from the one above would say "landed on
-- Pancakes" about a swap that landed on Maple.
resetWorld()
fiveDeepRaid(4)
setSpellTargetName("raid1", nil)                 -- there is a target; the name is not being given
setTarget("raid1", "raid2")
do
    local token, source = Tattle.CastTargetOf("raid1")
    check("no name at all falls back to the caster's target, labelled as weaker evidence",
        token == "raid2" and source == "unit-target",
        tostring(token) .. " / " .. tostring(source))
end

-- A secret name is not the same situation. It is a value that exists, that the client
-- will not let an addon read, and that the client *can* compare on the addon's behalf -
-- which is why the fallback is the last resort rather than the automatic consequence of
-- secrecy. Getting this wrong would quietly downgrade real answers to "they were aiming
-- at" every time the name came back secret, which in 12.1.x is most of the time.
resetWorld()
fiveDeepRaid(4)
setSpellTarget("raid1", "raid5")                 -- a target there is, and a name the client will hide
setTarget("raid1", "raid2")
do
    spellTargetNamesAreSecret = true             -- which is the documented default for another player's cast
    secretCompareSupported = true
    local token, source = Tattle.CastTargetOf("raid1")
    check("a secret name resolves through the client's own comparison when it answers",
        token == "raid5" and source == "spell-target",
        tostring(token) .. " / " .. tostring(source))
end

-- And only when that comparison is refused too does the weaker source get used, still
-- labelled. A refusal for a member is that member's answer, so the sweep has to walk the
-- whole group before it concludes nothing was learned.
secretCompareSupported = false
do
    local token, source = Tattle.CastTargetOf("raid1")
    check("a build that will not compare names falls back rather than guessing",
        token == "raid2" and source == "unit-target",
        tostring(token) .. " / " .. tostring(source))
end
secretCompareSupported = true

-- A display gate that answered false is an answer. Asking the name API anyway is what
-- the gate exists to make unnecessary, and a build that says the name should not be
-- shown is a build that will not hand over something safe to print.
resetWorld()
fiveDeepRaid(4)
setSpellTarget("raid1", "raid5")
setTarget("raid1", "raid2")
spellTargetNamesDisplayable = false
do
    local token, source = Tattle.CastTargetOf("raid1")
    check("a display gate answered false is honoured instead of overridden",
        token == "raid2" and source == "unit-target",
        tostring(token) .. " / " .. tostring(source))
end
spellTargetNamesDisplayable = true

-- Being the target is the one thing a player is always allowed to know, and it decides
-- the question outright: no weaker source gets to argue that Pancakes was the victim of
-- a spell that landed on you.
resetWorld()
fiveDeepRaid(4)
setSpellTarget("raid1", "player")
setTarget("raid1", "raid2")
do
    local token, source = Tattle.CastTargetOf("raid1")
    check("being the spell's target answers before anything weaker is asked",
        token == "player" and source == "spell-target",
        tostring(token) .. " / " .. tostring(source))
end

-- And when nothing answers, that comes back as nothing. A nil here is the client
-- declining; an earlier draft of this chain was one `or "unknown"` away from describing
-- a nil as a member who was not there.
resetWorld()
fiveDeepRaid(4)
do
    local token, source = Tattle.CastTargetOf("raid1")
    check("nothing answering comes back as nothing rather than as a placeholder",
        token == nil and source == nil,
        tostring(token) .. " / " .. tostring(source))
end

-- A target that is not in the group is not forced into the group. The swap and the
-- teleports all refuse non-party targets on a real client, but the addon does not get to
-- assume that about whatever the API hands back: an unresolved name stays unresolved
-- instead of becoming the nearest member's token.
resetWorld()
fiveDeepRaid(4)
spellTargetNamesAreSecret = false
setSpellTargetName("raid1", "Stranger")          -- a name no member of this group answers to
do
    local token, source = Tattle.CastTargetOf("raid1")
    check("a target outside the group is not resolved to a member who happens to be nearby",
        token == nil and source == nil,
        tostring(token) .. " / " .. tostring(source))
end
-- The same "not in this group" verdict arrived at through the sanctioned comparison instead
-- of a printed name: the client is asked whether the hidden name belongs to each member in
-- turn and every one answers *no*. Those are answers, and they have to produce the same
-- outcome as a readable name that matches nobody - the weaker evidence, labelled - rather
-- than a member named as the spell's target. This is the path a name belonging to an
-- out-of-group player takes, and it is worth separating from the refusal above: a refusal
-- says nothing about who the name is, while these answers say who it is not.
spellTargetNamesAreSecret = true
resetWorld()
fiveDeepRaid(4)
setSpellTargetName("raid1", "Stranger")          -- secret, and matching nobody in this group
setTarget("raid1", "raid2")
do
    local token, source = Tattle.CastTargetOf("raid1")
    check("a hidden name the client matches against nobody in the group yields the labelled fallback",
        token == "raid2" and source == "unit-target",
        tostring(token) .. " / " .. tostring(source))
end

spellTargetNamesAreSecret = true

-- A swap whose start this client never delivered: the record is built by the terminal event
-- and its victim is read there instead, on a spell that has already finished and whose
-- target the client may therefore already have forgotten. It gets the same treatment and the
-- same label rather than a claim inherited from a moment nobody witnessed.
-- raid3, and a clock well clear of the swap casts the probe scenarios above put on raid1:
-- a caster with a fresh cast already on the books is the module deciding an event belongs to
-- a cast it already reported, which is correct behaviour and a different question. This one
-- asks only what happens when the sole thing this client ever delivered was the end.
resetWorld()
setGroup({ raid = true, count = 5, selfIndex = 4 })
alertMode("swapblaster", "YELL")
spellTargetNamesAreSecret = false
setSpellTarget("raid3", "raid5")
setTarget("raid3", "raid2")
table.wipe(sentMessages)
setClock(6100)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid3", "guid-late-only", 161399)
runTimers()
-- With no start there is no window to measure, so this is not claimed as a completed swap
-- and the sentence is the "cast ended" one. What is under test is whose name is in it: the
-- spell's target read at the terminal event, not the bystander the caster's interface was
-- still showing. The count is part of the claim, because a check that reads whatever happens
-- to be in the log passes on whoever else's alert is sitting there - which is how this very
-- check passed for one run without ever having sent anything.
check("a cast heard only at its end names the spell's target, not the stale interface",
    #sentMessages == 1
        and messageContaining("Maple") ~= nil
        and messageContaining("Pancakes") == nil,
    tostring(#sentMessages) .. " alerts, first: "
        .. (sentMessages[1] and sentMessages[1].message or "(none)"))

-- A swap that stopped early never landed on anybody, and that is true even when the client
-- named the spell's target out loud - which is why this sentence keeps the aiming
-- preposition on the *strongest* evidence rather than the weakest. The mistake it prevents
-- is the tidy one: "strong evidence, so say on", when the cast did not complete.
resetWorld()
setGroup({ raid = true, count = 5, selfIndex = 4 })
alertMode("swapblaster", "YELL")
spellTargetNamesAreSecret = false
setSpellTarget("raid3", "raid5")
setTarget("raid3", "raid2")
table.wipe(sentMessages)
setClock(6110)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid3", "guid-cut-1", 161399)
setClock(6111)                                  -- 1.0 s into a 1.5 s window
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid3", "guid-cut-1", 161399)
runTimers()
check("a cut-short swap says where it was pointed even when the target is well evidenced",
    #sentMessages == 2
        and messageContaining("Waffles's Swapblaster at Maple was cut short") ~= nil
        and messageContaining("on Maple") == nil,
    tostring(#sentMessages) .. " alerts, last: "
        .. (sentMessages[2] and sentMessages[2].message or "(none)"))

-- ============================================================================
-- What is allowed to leave the machine
-- ============================================================================

-- Chat is the one alert channel other people read, so it carries two gates the console and
-- the screen have no use for. They are checked here, at the boundary, rather than in a
-- module: every module composes its own sentence and any of them could be the one holding a
-- name that must not be broadcast.

local function chatOnly(moduleId, chatType)
    resetWorld()
    TattleDB.debug = false
    local settings = TattleDB.modules[moduleId]
    settings.enabled = true
    settings.scope = "group"
    settings.alerts.console = false
    settings.alerts.chat = true
    settings.alerts.chatType = chatType
    settings.alerts.audio = false
    settings.alerts.screen = false
    table.wipe(sentMessages)
end

chatOnly("swapblaster", "SAY")
Tattle.SendAlert("Donut used Swapblaster on Maple", "swapblaster")
runTimers()
check("a plain alert reaches the chat channel the player configured",
    #sentMessages == 1 and sentMessages[1].channel == "SAY" and chatSendAttempts == 1,
    "arrived " .. #sentMessages .. ", attempted " .. chatSendAttempts)

-- The client's own lockdown, which is what a restricted raid or a keyed dungeon looks like
-- from an addon's side. Without this gate the send happens anyway and the pcall swallows the
-- client's refusal, which is indistinguishable from an alert that never fired - the exact
-- confusion this project has already been bitten by twice, from the other side.
chatOnly("swapblaster", "SAY")
-- Set after chatOnly, whose resetWorld() clears it back to unlocked.
chatMessagingLockedDown = true
Tattle.SendAlert("Donut used Swapblaster on Maple", "swapblaster")
runTimers()
-- The attempt count is the point of the check. Sent messages alone would stay empty either
-- way, because this stub's SendChatMessage refuses a locked-down send on the client's
-- behalf, and a gate that was deleted would still look green.
check("chat the client will not carry is not even attempted",
    #sentMessages == 0 and chatSendAttempts == 0,
    "arrived " .. #sentMessages .. ", attempted " .. chatSendAttempts)

-- And the alert is not lost, which is the half that makes the gate above safe to have. What
-- gets locked down is chat traffic; the player's own interface is untouched, and the
-- restricted content where the lockdown happens is exactly where a griefer's casts land.
chatOnly("swapblaster", "SAY")
chatMessagingLockedDown = true
TattleDB.modules.swapblaster.alerts.screen = true
Tattle.SendAlert("Donut used Swapblaster on Maple", "swapblaster")
local lockedFrame = findFrameByName("TattleScreenAlertFrame")
check("while chat is locked down the alert still reaches the player on screen",
    lockedFrame ~= nil and lockedFrame:IsShown()
        and lockedFrame.text:GetText() == "Donut used Swapblaster on Maple",
    lockedFrame and (lockedFrame.text:GetText() or "<no text>") or "<no frame>")
chatMessagingLockedDown = false
runTimers()

-- The gate that does not ask the client's permission. A name the client handed over as a
-- secret value may be displayed to the player alone and may not be pushed at whoever else
-- is reading SAY, and this one holds even on a build with no lockdown in effect and no
-- cooperation from any API.
chatOnly("swapblaster", "SAY")
Tattle.SendAlert(Secret.asSecret("Maple"), "swapblaster")
runTimers()
-- Same shape, and the reason the two are separate checks: this gate is the one that does
-- not depend on the client cooperating, so it has to be seen to stop the attempt even when
-- nothing is locked down and the client would have accepted the bytes.
check("a message holding a value the client hides is never offered to chat",
    #sentMessages == 0 and chatSendAttempts == 0,
    "arrived " .. #sentMessages .. ", attempted " .. chatSendAttempts)

-- A backfire with several protected members is usually a guessing game. With the
-- caster's target readable, the guess is unnecessary: the buffed player they were
-- looking at is the one whose protection set the blast off.
resetWorld()
alertMode("swapblaster", "YELL")
silenceWho("Donut")
setAura("player", "Neural Silencer", 156779)   -- a second candidate
setTarget("raid2", "raid1")
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-backfire-read", 182081)
runTimers()
check("a backfire whose target is readable names that victim instead of hedging",
    messageContaining("Pancakes attempted a Swapblaster on Donut, but it failed because Donut is using a Neural Silencer") ~= nil,
    sentMessages[1] and sentMessages[1].message)
resetWorld()

-- An instant cast: Life Grip sends no START, so SUCCEEDED must stand alone.
alertMode("lifegrip", "PARTY")
table.wipe(sentMessages)
clearAuras()
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-3", 73325)
runTimers()
check("instant cast alerts on success with no preceding START",
    #sentMessages == 1 and sentMessages[1].channel == "PARTY",
    "got " .. #sentMessages)
check("instant cast names the caster",
    messageContaining("Pancakes used Life Grip") ~= nil,
    sentMessages[1] and sentMessages[1].message)
check("an unresolvable target is reported as unknown, not dropped",
    messageContaining("target unknown") ~= nil,
    sentMessages[1] and sentMessages[1].message)

-- The gripped player wears a 4-second "Leap of Faith" aura, which is the only
-- destination information 12.x leaves us.
table.wipe(sentMessages)
clearAuras()
setAura("raid1", "Leap of Faith", 73325)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-4", 73325)
runTimers()
check("the gripped player is named from their aura",
    messageContaining("Pancakes used Life Grip on Donut!") ~= nil,
    sentMessages[1] and sentMessages[1].message)

table.wipe(sentMessages)
clearAuras()
setAura("player", "Leap of Faith", 73325)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-5", 73325)
runTimers()
check("being the victim reads as \"on you\"",
    messageContaining("Pancakes used Life Grip on you!") ~= nil,
    sentMessages[1] and sentMessages[1].message)

-- Rescue marks the Evoker and the passenger with the same-named aura, so the
-- caster must be excluded before the rest counts as the passenger.
alertMode("rescue", "RAID")
table.wipe(sentMessages)
clearAuras()
setAura("raid2", "Rescue", 370666)
setAura("raid1", "Rescue", 370667)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-6", 370666)
runTimers()
check("Rescue names the passenger, not the Evoker who cast it",
    #sentMessages == 1 and messageContaining("Pancakes used Rescue on Donut!") ~= nil,
    sentMessages[1] and sentMessages[1].message)

-- PRIVATE must not reach chat at all.
alertMode("swapblaster", "PRIVATE")
TattleDB.modules.swapblaster.alerts.console = true
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_START", "raid1", "guid-7", 161399)
runTimers()
check("chatType PRIVATE sends nothing to chat", #sentMessages == 0, "got " .. #sentMessages)
check("chatType PRIVATE still prints to the console",
    lastPrintContaining("Donut is casting Swapblaster") ~= nil)

-- Scope "self" means "it involved me", not "I cast it": someone else's cast
-- aimed at you is the whole point of the addon. The gate is asked in the
-- negative -- "may this be dropped?" -- so that "I cannot tell" and "not mine"
-- are the same answer, and the answer is always a boolean.
TattleDB.modules.lifegrip.scope = "self"
check("scope self drops a resolved target that is not you",
    Tattle.ScopeDrops("lifegrip", "raid2", { "raid1" }) == true)
check("scope self keeps a resolved target that includes you",
    Tattle.ScopeDrops("lifegrip", "raid2", { "raid1", "player" }) == false)
check("scope self keeps your own cast",
    Tattle.ScopeDrops("lifegrip", "player") == false)
check("an unresolved target is never provably not you",
    Tattle.ScopeDrops("lifegrip", "raid2") == false
        and Tattle.ScopeDrops("lifegrip", "raid2", {}) == false)
check("the scope gate says yes or no, never maybe",
    type(Tattle.ScopeDrops("lifegrip", "raid2")) == "boolean"
        and type(Tattle.ScopeDrops("lifegrip", "raid2", {})) == "boolean"
        and type(Tattle.ScopeDrops("nosuchmodule", "raid2")) == "boolean")

table.wipe(sentMessages)
clearAuras()
setAura("raid1", "Leap of Faith", 73325)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-8", 73325)
runTimers()
check("scope self suppresses a grip that landed on someone else",
    #sentMessages == 0, "got " .. #sentMessages)

table.wipe(sentMessages)
clearAuras()
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-9", 73325)
runTimers()
check("scope self still reports when the target cannot be resolved",
    #sentMessages == 1, "got " .. #sentMessages)

TattleDB.modules.lifegrip.scope = "group"
check("scope group keeps another member's cast",
    Tattle.ScopeDrops("lifegrip", "raid2", { "raid1" }) == false)

-- Swap applies no aura to either side, so "self" can never rule it out.
alertMode("swapblaster", "YELL")
TattleDB.modules.swapblaster.scope = "self"
check("scope self cannot rule out a Swapblaster",
    Tattle.ScopeDrops("swapblaster", "raid2") == false)
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_START", "raid2", "guid-10", 161399)
runTimers()
check("scope self keeps a Swapblaster warning it cannot place", #sentMessages == 1,
    "got " .. #sentMessages)
TattleDB.modules.swapblaster.scope = "group"

-- ============================================================================
-- Combat: the Swapblaster is judged at the start, the grab spells everywhere
-- ============================================================================

-- "Cannot be used in combat" is printed on the toy, so a cast start cannot exist
-- while the caster is fighting and the core must not evaluate the module at all.
muteAllModules()
alertMode("swapblaster", "YELL")
resetWorld()
setCombatUnits("raid1")
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-combat", 161399)
runTimers()
check("a Swapblaster cast start is not evaluated while the caster is fighting",
    #sentMessages == 0, "got " .. #sentMessages)

-- But a swap that *began* out of combat still has to be announced when it lands:
-- landing a swap next to a pack is a classic way to start a fight, so its
-- completion event can arrive after combat did.
setCombatUnits()
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-straddle", 161399)
advanceClock(2)
setCombatUnits("raid1")
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-straddle", 161399)
runTimers()
check("a swap that started out of combat still announces its completion",
    messageContaining("Donut used Swapblaster") ~= nil,
    sentMessages[1] and sentMessages[1].message)

-- Life Grip and Rescue are gated wholesale (outOfCombat = "all"): both are
-- instant, so a grab that resolves while its caster is fighting is a raid tool
-- doing its job, not a mugging. The policy lives in the core so the modules do
-- not each carry a copy -- which means this check is now about the core's gate
-- rather than a module's own filter. Either way the observable contract is the
-- same: a caster who is fighting does not get announced, and the same caster a
-- moment later does.
alertMode("lifegrip", "PARTY")
resetWorld()
table.wipe(sentMessages)
setCombatUnits("raid2")
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-lg-combat", 73325)
runTimers()
check("the core's combat gate drops an in-combat Life Grip",
    #sentMessages == 0, "got " .. #sentMessages)
setCombatUnits()
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-lg-ooc", 73325)
runTimers()
check("and the same caster alerts once out of combat", #sentMessages == 1, "got " .. #sentMessages)
resetWorld()

-- The *drop* half of the "start" policy had no check at all, and the drop half is
-- the one that can fail invisibly. In alpha.3 OUT_OF_COMBAT_EVENTS.start was built
-- from a global that had not been defined yet, so the entry was nil, the gate matched
-- nothing, and every check in this file still passed - while the harness printed
-- "module swapblaster asked for outOfCombat policy \"start\", which is not a thing"
-- and nobody was looking at the harness output. A gate that gates nothing is
-- indistinguishable from a gate that gates correctly, except to the raid that gets
-- told about casts the game does not allow to happen.
fiveDeepRaid(5)
isolateAlerts("swapblaster")
table.wipe(sentMessages)
advanceClock(60)
setCombatUnits("raid4")
dispatch("UNIT_SPELLCAST_START", "raid4", "guid-gated-plain", 161399)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid4", "guid-gated-channel", 161399)
runTimers()
check("the start gate really drops a Swapblaster cast that cannot legally be happening",
    #sentMessages == 0, messageLog())
setCombatUnits()
advanceClock(10)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid4", "guid-gate-open", 161399)
runTimers()
check("and lets the same cast through a moment later, once the caster is not fighting",
    #sentMessages == 1, messageLog())
restoreAlertSettings()

-- ============================================================================
-- Idle while you fight
-- ============================================================================

-- Everything this addon watches is an out-of-combat act - the toy says "Cannot be used
-- in combat" on its tooltip, and the alerts exist to tell a group that somebody is
-- griefing them at a mining node or in a city. So while *this player* is fighting, the
-- addon does nothing at all: no module woken, no alert sent, nothing asked of the
-- client. That is a different question from the per-module gate above, which asks about
-- the *caster*: you can be standing still while somebody else is fighting.
--
-- The state is a cached flag kept current by PLAYER_REGEN_DISABLED / _ENABLED and
-- re-read on PLAYER_ENTERING_WORLD, so these checks have to move it the way a client
-- would - by firing the transition - rather than only setting combat for "player".
-- A check that only set combatUnits would be proving nothing, because the cached flag
-- would still say "not fighting" and the addon would keep alerting for the wrong reason.
muteAllModules()
alertMode("swapblaster", "YELL")
alertMode("lifegrip", "PARTY")
resetWorld()
fiveDeepRaid(5)
table.wipe(sentMessages)
local lookupsBeforeFight = spellNameLookups
setCombatUnits("player")
dispatch("PLAYER_REGEN_DISABLED")
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid4", "guid-me-fighting", 161399)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-me-fighting-grip", 73325)
runTimers()
check("nothing is announced while you are fighting, whichever module would have spoken",
    #sentMessages == 0, messageLog())
check("and nothing was asked of the client to decide that",
    spellNameLookups == lookupsBeforeFight,
    "spell names resolved: " .. (spellNameLookups - lookupsBeforeFight))
check("the core knows it is holding quiet, which is what /tattle status reads",
    Tattle.IAmInCombat() == true, "IAmInCombat answered " .. tostring(Tattle.IAmInCombat()))

callSlash("status")
check("so /tattle status says the addon is silent because you are fighting",
    lastPrintContaining("silent while you fight") ~= nil,
    "no in-combat line in /tattle status")

-- And the gate opens. A rule that only ever closes is indistinguishable from a
-- disconnect, and every positive-alert check in this file runs with you out of combat,
-- so a gate stuck shut would be caught here rather than by the next hour of testing.
setCombatUnits()
dispatch("PLAYER_REGEN_ENABLED")
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid4", "guid-me-after-fight", 161399)
runTimers()
check("the same cast is announced once you are out of combat", #sentMessages == 1, messageLog())
-- Read out of the status output printed *after* this call: lastPrintContaining searches
-- the whole session, and the earlier status call in this same scenario said the opposite.
local statusLines = #printLog
callSlash("status")
local claimsFighting = false
for i = statusLines + 1, #printLog do
    if printLog[i]:find("silent while you fight", 1, true) then claimsFighting = true end
end
check("and the status line stops claiming you are fighting",
    not claimsFighting and lastPrintFrom(statusLines, "In combat:") ~= nil,
    "stale in-combat state in /tattle status")

-- The probe is the one thing the rule lets through, on purpose: the question it exists
-- to answer is what a client sends and withholds *during* a fight. Pinned here because
-- the next reasonable reader of this file will try to make it consistent with the rest
-- of the addon, and the inconsistency is the point.
local probeLinesBefore = #printLog
callSlash("probe")
setCombatUnits("player")
dispatch("PLAYER_REGEN_DISABLED")
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid4", "guid-probe-in-fight", 161399)
runTimers()
check("while the addon is silent, the probe a player armed still reports",
    #sentMessages == 0 and #printLog > probeLinesBefore
        and lastPrintContaining("UNIT_SPELLCAST_CHANNEL_START") ~= nil,
    "probe printed nothing while you were fighting")

-- Left armed on purpose: it is the one component that rides its own frame rather than
-- the module pipeline, so /tattle off would otherwise leave it printing a chat line for
-- every watched cast after the player had asked for the addon to be off. The probe is
-- still armed here, which is what makes the next check say something.
setCombatUnits()
dispatch("PLAYER_REGEN_ENABLED")
callSlash("off")
local linesAfterOff = #printLog
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid4", "guid-after-off", 161399)
runTimers()
check("turning the addon off disarms the probe with everything else",
    #printLog == linesAfterOff, "the probe kept printing after /tattle off")
callSlash("on")
check("and the probe stays disarmed rather than coming back with the addon",
    Tattle._probeFrame == nil, "probe frame still wired up")
restoreAlertSettings()

-- ============================================================================
-- The group's unit tokens
-- ============================================================================

-- In a raid you are one of raid1..raidN and GetNumGroupMembers() counts you; in a
-- party you are "player" and the numbers are other people. The core has to hand
-- back a list in which you appear exactly once, as "player", or every group-wide
-- sweep reads you twice -- cosmetic in the watch list ("you and you"), real in the
-- Rescue attribution, where an Evoker who rescued Pancakes is reported as having
-- also been rescued by themselves.

local unitTokens = Tattle.GroupUnitTokens()
local playerEntries, selfIndexEntries = 0, 0
for _, token in ipairs(unitTokens) do
    if token == "player" then playerEntries = playerEntries + 1 end
    if token == "raid" .. group.selfIndex then selfIndexEntries = selfIndexEntries + 1 end
end
check("you are in the group's unit list exactly once",
    playerEntries == 1, "found 'player' " .. playerEntries .. " time(s)")
check("your own raid index is not in that list as well",
    selfIndexEntries == 0, "found raid" .. group.selfIndex .. " " .. selfIndexEntries .. " time(s)")

local ownTargetEntries = 0
for _, entry in ipairs(Tattle.GroupTargetEntries()) do
    if entry.owner == "raid" .. group.selfIndex then ownTargetEntries = ownTargetEntries + 1 end
end
check("the watcher sweep never reads its own target",
    ownTargetEntries == 0, "found " .. ownTargetEntries .. " entry(ies) for your own raid index")

-- One protected person, named once. Set on your raid index -- where a sweep that
-- walks raidN really would find it -- and read out through the core's helper.
setAura("raid" .. group.selfIndex, "Neural Silencer", 156779)
local protected = Tattle.SilencerWearerNames({ "you" })
check("you are named once in a protected list, not once per token",
    #protected == 1 and protected[1] == "you",
    table.concat(protected, " / ") or "(nobody)")

-- Rescue marks the Evoker with the same aura as the passenger, so a sweep that
-- read you twice would report you as your own passenger. Real marks: you cast it,
-- you and Pancakes both carry it, and only Pancakes was moved.
setAura("player", "Rescue", 370666)
setAura("raid2", "Rescue", 370666)
alertMode("rescue", "PARTY")
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "player", "guid-self-rescue", 370666)
runTimers()
local selfRescue = messageContaining("used Rescue")
check("your own Rescue mark is not read as a second passenger",
    selfRescue ~= nil
    and (selfRescue.message or ""):find("Pancakes", 1, true) ~= nil
    and (selfRescue.message or ""):find("you", 1, true) == nil,
    selfRescue and selfRescue.message)
resetWorld()

-- ============================================================================
-- Chat channel routing (LFR raid chat)
-- ============================================================================

alertMode("lifegrip", "RAID")

-- A plain raid: "Raid" means the RAID channel.
resetWorld()
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-raid1", 73325)
runTimers()
check("raid chat in a normal raid goes to RAID",
    sentMessages[1] and sentMessages[1].channel == "RAID",
    sentMessages[1] and sentMessages[1].channel)

-- LFR: it is a raid, but not a LE_GROUP_TYPE_RAID one, and a plain RAID send
-- there vanishes silently. This is the tarballs-dadabase bug.
setGroup({ raid = true, normalRaid = false, count = 2 })
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-lfr1", 73325)
runTimers()
check("raid chat in LFR goes to the instance channel instead of vanishing",
    sentMessages[1] and sentMessages[1].channel == "INSTANCE_CHAT",
    sentMessages[1] and sentMessages[1].channel)
check("ResolveChatChannel keeps SAY and YELL alone",
    Tattle.ResolveChatChannel("SAY") == "SAY" and Tattle.ResolveChatChannel("YELL") == "YELL")
setGroup({ party = true, count = 3 })
check("ResolveChatChannel sends Raid to PARTY when you are only in a party",
    Tattle.ResolveChatChannel("RAID") == "PARTY", Tattle.ResolveChatChannel("RAID"))
resetWorld()

-- ============================================================================
-- Neural Silencer: blocked attempts and cheating casters
-- ============================================================================

alertMode("lifegrip", "PARTY")

-- The victim's "Leap of Faith" aura never appeared, the caster had the protected
-- member targeted, and exactly one member is protected: the pull bounced off them,
-- which is worth more than "target unknown".
--
-- The target read is doing the work in this sentence. It was not there before: the
-- alert used to fall back to "whoever in the raid is protected", so one wearer put
-- their name on every grip, rescue and swap the group produced. That reading is now
-- the failing case, and the two checks below are what replaced it.
resetWorld()
silenceWho("Donut")
setTarget("raid2", "raid1")       -- Pancakes had Donut targeted
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-lg-blocked", 73325)
runTimers()
check("a grip that marked nobody is called a blocked attempt, naming the protected member",
    messageContaining("Pancakes attempted a Life Grip on Donut, but it failed because Donut is using a Neural Silencer") ~= nil,
    sentMessages[1] and sentMessages[1].message)

-- Whom the spell was pointed at, when the client is willing to say, outranks whom the
-- caster's interface was showing - and the case that proves the difference is a griefer
-- whose macro pointed the grip at a protected member while their target frame sat on
-- somebody unprotected. Read from the interface alone, this alert would have said
-- "attempted on Waffles, blocked by their Neural Silencer" about a member who has no
-- Neural Silencer and was never involved.
resetWorld()
setGroup({ raid = true, count = 5, selfIndex = 4 })
silenceWho("Donut")
spellTargetNamesAreSecret = false
setSpellTarget("raid2", "raid1")     -- the grip's target: Donut, protected
setTarget("raid2", "raid3")          -- their interface: Waffles, wearing nothing
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-lg-spelltarget", 73325)
runTimers()
check("a grip's blocked attempt is attributed to the spell's target, not the caster's frame",
    messageContaining("attempted a Life Grip on Donut") ~= nil
        and messageContaining("Waffles") == nil,
    sentMessages[1] and sentMessages[1].message)

-- The same reading working against the alert, which is the half that makes it a gate
-- rather than a source of claims. A readable spell target that is *not* protected is
-- evidence the bounce did not happen for that reason, and the alert falls back to
-- admitting it does not know - rather than to the protected member still sitting in the
-- caster's target frame.
resetWorld()
setGroup({ raid = true, count = 5, selfIndex = 4 })
silenceWho("Donut")
spellTargetNamesAreSecret = false
setSpellTarget("raid2", "raid3")     -- the grip's target: Waffles, unprotected
setTarget("raid2", "raid1")          -- their interface: Donut, protected
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-lg-notblocked", 73325)
runTimers()
check("a spell target readable as unprotected stops the blocked-attempt claim",
    messageContaining("target unknown") ~= nil and messageContaining("Donut") == nil,
    sentMessages[1] and sentMessages[1].message or "(none)")

-- Same thing happening to you.
resetWorld()
silenceWho("Me")
setTarget("raid2", "player")
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-lg-blocked-me", 73325)
runTimers()
check("and the sentence switches to you correctly",
    messageContaining("Pancakes attempted a Life Grip on you, but it failed because you are using a Neural Silencer") ~= nil,
    sentMessages[1] and sentMessages[1].message)

-- One protected member in the raid, and the client was not told who the grab was
-- aimed at. Saying "Donut" here is a guess about a bystander, and it is the sentence
-- a beta player reported on every alert all evening: the alert now keeps to what it
-- saw, which is a grab that landed on nobody it could identify.
resetWorld()
silenceWho("Donut")
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-lg-no-target-read", 73325)
runTimers()
check("a passenger-less grip whose target cannot be read names nobody as protected",
    messageContaining("Pancakes used Life Grip (target unknown)!") ~= nil
        and messageContaining("Neural Silencer") == nil,
    sentMessages[1] and sentMessages[1].message)

-- And the same with the read pointing at somebody who is *not* protected: the group's
-- wearer list is not a stand-in for the victim, however confident it sounds.
resetWorld()
silenceWho("Donut")
setTarget("raid2", "player")      -- you, and you have no silencer on
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-lg-target-not-protected", 73325)
runTimers()
check("a passenger-less grip aimed at an unprotected member blames nobody",
    messageContaining("Pancakes used Life Grip (target unknown)!") ~= nil
        and messageContaining("Neural Silencer") == nil,
    sentMessages[1] and sentMessages[1].message)

-- A *failed* cast could have failed for any number of reasons, so it states one
-- fact it can see: the buff of the member the caster was looking at.
resetWorld()
silenceWho("Donut")
setTarget("raid2", "raid1")
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_START", "raid2", "guid-lg-fail", 73325)
dispatch("UNIT_SPELLCAST_FAILED", "raid2", "guid-lg-fail", 73325)
runTimers()
check("a failed cast names the protected member it was aimed at, as a fact not a cause",
    messageContaining("Pancakes's Life Grip failed (Donut is using a Neural Silencer).") ~= nil,
    sentMessages[2] and sentMessages[2].message)

-- The same fact read from the better source. The failed cast's note is the weakest claim
-- this module makes - a buff somebody is wearing, attached to a cast that arrived nowhere -
-- and it is still attached to the member the *spell* was pointed at rather than whoever the
-- caster's interface happened to be showing, because "Waffles is wearing a Neural Silencer"
-- is a sentence about Waffles either way.
resetWorld()
setGroup({ raid = true, count = 5, selfIndex = 4 })
silenceWho("Donut")
spellTargetNamesAreSecret = false
setSpellTarget("raid2", "raid1")     -- the grip's target: Donut, protected
setTarget("raid2", "raid3")          -- their interface: Waffles, unprotected
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_START", "raid2", "guid-lg-fail-spelltarget", 73325)
dispatch("UNIT_SPELLCAST_FAILED", "raid2", "guid-lg-fail-spelltarget", 73325)
runTimers()
check("a failed cast's protection note follows the spell's target, not the caster's frame",
    messageContaining("(Donut is using a Neural Silencer)") ~= nil
        and messageContaining("Waffles") == nil,
    sentMessages[2] and sentMessages[2].message or "(none)")

-- ...and the failure of a cast whose target it cannot see says nothing about anyone.
resetWorld()
silenceWho("Donut")
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_START", "raid2", "guid-lg-fail-blind", 73325)
dispatch("UNIT_SPELLCAST_FAILED", "raid2", "guid-lg-fail-blind", 73325)
runTimers()
check("a failed cast with no target read says nothing about a Neural Silencer",
    messageContaining("Pancakes's Life Grip failed.") ~= nil
        and messageContaining("Neural Silencer") == nil,
    sentMessages[2] and sentMessages[2].message)

alertMode("rescue", "RAID")
resetWorld()
silenceWho("Donut")
setTarget("raid2", "raid1")
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-res-blocked", 370666)
runTimers()
check("Rescue reads a passenger-less flight the same way",
    messageContaining("Pancakes attempted a Rescue on Donut, but it failed because Donut is using a Neural Silencer") ~= nil,
    sentMessages[1] and sentMessages[1].message)

alertMode("swapblaster", "YELL")

-- The backfire spell is the only evidence a Swapblaster attempt exists at all,
-- since a swap that lands marks nobody either way.
resetWorld()
silenceWho("Donut")
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-backfire", 182081)
runTimers()
check("a Swapblaster backfire is reported as an attempt blocked by the target's silencer",
    messageContaining("Pancakes attempted a Swapblaster on Donut, but it failed because Donut is using a Neural Silencer") ~= nil,
    sentMessages[1] and sentMessages[1].message)

-- One attempt, one alert, whichever half of the cast we hear about first.
resetWorld()
silenceWho("Donut")
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-bf-both", 161399)
advanceClock(1)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-bf-both", 182081)
advanceClock(1)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid2", "guid-bf-both", 161399)
runTimers()
check("a backfired swap is announced once, not once per event",
    #sentMessages == 2, "got " .. #sentMessages)

-- A protected caster firing the toy is protecting themselves while shuffling
-- someone who cannot answer in kind.
resetWorld()
silenceWho("Pancakes")
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-cheat", 161399)
advanceClock(2)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid2", "guid-cheat", 161399)
runTimers()
local cheatMsg = messageContaining("Pancakes used Swapblaster")
check("a protected caster is called out while doing it",
    cheatMsg and cheatMsg.message ==
        "Pancakes used Swapblaster, but Pancakes is using a Neural Silencer - that's not fair!",
    cheatMsg and cheatMsg.message)
check("the call-out replaces the generic wearer note instead of doubling up",
    cheatMsg and not cheatMsg.message:find("worn by", 1, true),
    cheatMsg and cheatMsg.message)

-- Same caster, no silencer: no accusation.
resetWorld()
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-clean", 161399)
advanceClock(2)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid2", "guid-clean", 161399)
runTimers()
check("an unprotected caster gets the plain completion alert",
    messageContaining("Pancakes used Swapblaster") ~= nil
        and messageContaining("that's not fair") == nil,
    sentMessages[2] and sentMessages[2].message)
resetWorld()

-- ============================================================================
-- Which alerts may mention a Neural Silencer: only the ones about its wearer
-- ============================================================================

-- The beta's report was that one protected member in the raid was enough to put
-- "so-and-so has a Neurosilencer" on every alert that followed, including the ones
-- about a completely different player. The old note was built by sweeping the group,
-- so it could not say anything else. These four checks are the shape of the rule that
-- replaced it: the protected member is named when they are the target, and the alerts
-- about everybody else stay clean.

resetWorld()
silenceWho("Donut")
setTarget("raid2", "raid1")
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-swap-on-protected", 161399)
runTimers()
check("a swap aimed at a protected member says so on its own alert",
    messageContaining("Pancakes is casting Swapblaster at Donut (Donut is using a Neural Silencer)") ~= nil,
    sentMessages[1] and sentMessages[1].message)

resetWorld()
silenceWho("Donut")
setTarget("raid2", "player")      -- the swap is coming at you; Donut is just standing there
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-swap-past-bystander", 161399)
runTimers()
check("a swap aimed at somebody else leaves the group's protected member out of it",
    messageContaining("Pancakes is casting Swapblaster at you") ~= nil
        and messageContaining("Neural Silencer") == nil,
    sentMessages[1] and sentMessages[1].message)

resetWorld()
silenceWho("Donut")
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-swap-blind", 161399)
runTimers()
check("and a swap whose target cannot be read names nobody, protected or not",
    messageContaining("Pancakes is casting Swapblaster") ~= nil
        and messageContaining("Neural Silencer") == nil,
    sentMessages[1] and sentMessages[1].message)

resetWorld()
silenceWho("Donut")
setTarget("raid2", "raid1")
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-swap-failed-protected", 161399)
advanceClock(1)
dispatch("UNIT_SPELLCAST_FAILED", "raid2", "guid-swap-failed-protected", 161399)
runTimers()
-- "at Donut" rather than "on Donut", and the difference is not cosmetic: the cast failed,
-- so nothing landed on anybody, and the only thing known about Donut here is where
-- Pancakes's interface was pointed. The protected member is still the useful half of the
-- sentence - that is what made the swap fail.
check("a swap that failed against a protected member says whose buff it hit",
    messageContaining("Pancakes's Swapblaster at Donut failed (Donut is using a Neural Silencer)") ~= nil,
    sentMessages[2] and sentMessages[2].message)

-- ============================================================================
-- One cast, one noise
-- ============================================================================

-- Audio is the part of an alert that interrupts, and one Swapblaster used to make it
-- two or three times: the start, then the landing or the failure wording for the same
-- cast. The rule now is that the *first* alert a cast produces is the one that may be
-- loud, which also covers the two instant spells (no START, so the landing is the
-- first thing you hear) and a swap that only ever arrived as a completion.

soundMode("swapblaster")

resetWorld()
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-noise-swap", 161399)
advanceClock(2)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid2", "guid-noise-swap", 161399)
runTimers()
check("a swap that starts and lands makes one sound, not two",
    #soundPlays == 1, "sounds: " .. #soundPlays)

resetWorld()
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-noise-swap-fail", 161399)
advanceClock(1)
dispatch("UNIT_SPELLCAST_FAILED", "raid2", "guid-noise-swap-fail", 161399)
runTimers()
check("and its failure wording is silent", #soundPlays == 1, "sounds: " .. #soundPlays)

resetWorld()
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid2", "guid-noise-completion-only", 161399)
runTimers()
check("a swap heard only as a completion is the first alert it got, so it sounds",
    #soundPlays == 1, "sounds: " .. #soundPlays)

resetWorld()
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-noise-backfire", 161399)
advanceClock(1)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-noise-backfire", 182081)
runTimers()
check("a backfire following a start the player already heard is silent",
    #soundPlays == 1, "sounds: " .. #soundPlays)

resetWorld()
advanceClock(60)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-noise-backfire-only", 182081)
runTimers()
check("a backfire that is all the player hears about an attempt makes the noise",
    #soundPlays == 1, "sounds: " .. #soundPlays)

soundMode("lifegrip")

resetWorld()
advanceClock(60)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-noise-grip", 73325)
runTimers()
check("an instant grab's landing is its first alert, so it sounds", #soundPlays == 1,
    "sounds: " .. #soundPlays)

resetWorld()
advanceClock(60)
dispatch("UNIT_SPELLCAST_START", "raid2", "guid-noise-grip-both", 73325)
advanceClock(1)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-noise-grip-both", 73325)
runTimers()
check("a grab that announced its start does not also sound when it lands",
    #soundPlays == 1, "sounds: " .. #soundPlays)

resetWorld()
advanceClock(60)
dispatch("UNIT_SPELLCAST_START", "raid2", "guid-noise-grip-int", 73325)
advanceClock(1)
dispatch("UNIT_SPELLCAST_INTERRUPTED", "raid2", "guid-noise-grip-int", 73325)
runTimers()
check("and its interrupt wording is silent too", #soundPlays == 1, "sounds: " .. #soundPlays)

alertMode("swapblaster", "YELL")
alertMode("lifegrip", "PARTY")
alertMode("rescue", "RAID")
resetWorld()

-- ============================================================================
-- Alert routing: which of the four outputs an alert actually reaches
-- ============================================================================

-- Screen alerts had no coverage at all until a beta player could not say whether
-- they had ever seen one. They had not: the wiring is fine, and the default was off.
-- Every link is asserted here anyway, because "the frame got built, positioned and
-- never shown" is exactly what that report was.

muteAllModules()
local swap = TattleDB.modules.swapblaster
resetWorld()
advanceClock(60)
table.wipe(sentMessages)
swap.alerts.screen = true
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-screen-on", 161399)
local screenFrame = findFrameByName("TattleScreenAlertFrame")
check("an alert with the screen warning on puts that message on screen",
    screenFrame ~= nil and screenFrame:IsShown()
        and screenFrame.text:GetText() == "Pancakes is casting Swapblaster",
    screenFrame and (screenFrame.text:GetText() or "<no text>"))
-- Not runTimers() before the check above: the hide timer is armed inside Show, so it
-- is already in the pending pile and running it early would hide the frame the check
-- is about to look at.
runTimers()
check("and the frame hides itself when the display duration is up",
    screenFrame ~= nil and not screenFrame:IsShown())

-- The negative half, with a baseline: the frame has to have been *up* just before for
-- "it is not up now" to mean anything. A check that only ever inspects a frame nobody
-- created passes for the wrong reason, which is a shape of green this file has already
-- been burned by three times.
resetWorld()
advanceClock(60)
swap.alerts.screen = true
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-screen-off-baseline", 161399)
local shownBeforeTheSwitchOff = screenFrame ~= nil and screenFrame:IsShown()
runTimers()

resetWorld()
advanceClock(60)
swap.alerts.screen = false
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-screen-off", 161399)
runTimers()
check("a module with the screen warning off never puts anything on screen",
    shownBeforeTheSwitchOff and screenFrame ~= nil and not screenFrame:IsShown(),
    "baseline frame was shown: " .. tostring(shownBeforeTheSwitchOff))

-- Console output is debugging. Unticked and debug off, an alert says nothing in the
-- chat window; that is the state a fresh install is in, and the state the beta was
-- not in (their console line was on by default and the screen warning was not).
local function alertPrinted(mark, message)
    return lastPrintFrom(mark, "[Tattle]|r " .. message) ~= nil
end
local ALERT_LINE = "Pancakes is casting Swapblaster"

muteAllModules()
TattleDB.debug = false
swap.alerts.console = false
resetWorld()
advanceClock(60)
local markNoConsole = #printLog
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-console-off", 161399)
runTimers()
check("an alert does not print to the chat window unless somebody asked for it",
    not alertPrinted(markNoConsole, ALERT_LINE))

TattleDB.debug = true
resetWorld()
advanceClock(60)
local markDebug = #printLog
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-console-debug", 161399)
runTimers()
check("and /tattle debug prints it for every module, ticked or not",
    alertPrinted(markDebug, ALERT_LINE))
TattleDB.debug = false

resetWorld()
advanceClock(60)
swap.alerts.console = true
local markBox = #printLog
dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid2", "guid-console-box", 161399)
runTimers()
check("the per-module Console output box still works with debug off",
    alertPrinted(markBox, ALERT_LINE))
swap.alerts.console = false
resetWorld()

-- ============================================================================
-- The optional watch list
-- ============================================================================

local silSettings = TattleDB.modules.silencer
check("the Silencer module ships its aura IDs and no Monitor scope",
    Tattle.modules.silencer.defaultSpellIDs[1] == 156779
        and Tattle.modules.silencer.noScope == true
        and silSettings ~= nil and type(silSettings.display) == "table",
    "module defaults or display settings missing")
check("the watch list is off by default", silSettings.display.showList == false)
check("the watch list starts with no timer", activeTickers() == 0)

-- A saved entry written by an older build must be repaired rather than trusted:
-- the options code indexes straight into `display`.
silSettings.display = { showList = false, showBackground = true }
attempt(Tattle.Silencer.ApplySettings, Tattle.Silencer)
local repaired = silSettings.display
check("a partial saved display config is filled in",
    repaired.showWearers == true and repaired.showWatchers == false
        and type(repaired.position) == "table" and repaired.position.point == "TOPRIGHT",
    "migration left holes")
silSettings.display = nil
attempt(Tattle.Silencer.ApplySettings, Tattle.Silencer)
check("a missing display config is rebuilt from defaults",
    silSettings.display ~= nil and silSettings.display.showList == false
        and type(silSettings.display.position) == "table",
    "no rebuild")

muteAllModules()
alertMode("silencer", "PARTY")
resetWorld()
silenceWho("Donut")
targets["raid2target"] = "player"      -- Pancakes has you targeted
silSettings.display.showList = true
silSettings.display.showWatchers = true
attempt(Tattle.Silencer.OptionsChanged, Tattle.Silencer)
fireTickers()

local watch = findFrameByName("TattleWatchFrame")
check("enabling the list creates the frame and its timer",
    watch ~= nil and activeTickers() == 1, "watch frame: " .. tostring(watch ~= nil))
check("the list names the protected member",
    watch and (watch.text:GetText() or ""):find("Neural Silencer: Donut", 1, true) ~= nil,
    watch and watch.text:GetText())
check("the list names whoever is targeting you",
    watch and (watch.text:GetText() or ""):find("Targeting you: Pancakes", 1, true) ~= nil,
    watch and watch.text:GetText())
check("the list is visible while grouped", watch and watch:IsShown())

-- Leaving the group must blank it, even though GROUP_ROSTER_UPDATE never reaches
-- a module through the core dispatcher once you are solo.
setGroup({})
setClock(8000)
fireTickers()
check("the list hides itself when you are not grouped", watch and not watch:IsShown())
setGroup({ raid = true })
setClock(8100)
fireTickers()
check("and returns when you group up again", watch and watch:IsShown())

-- Restricted content. The client refuses an aura read rather than answering "no aura", and
-- the list has to say it was not told instead of reporting an unprotected group. This is
-- the exact shape of the wrongness the 12.1.x spell data predicts: the aura reads Tattle
-- depends on carry `SecretWhenUnitAuraRestricted`, none of the watched spells has a secrecy
-- exemption, and this frame redraws on a timer for the whole time you are in the key - so
-- the default failure is a confident "nobody" in front of a raid where several members are
-- protected, shown to the very people trying to spot a griefer.
refuseAuraReads()
setClock(8110)
fireTickers()
check("a refused aura read is reported as unknown, not as nobody",
    watch and (watch.text:GetText() or ""):find("Neural Silencer: Unknown (+2 hidden by the client)", 1, true) ~= nil,
    watch and watch.text:GetText())

-- Your own auras stay readable, because the predicate is about other people - so a partly
-- readable group names who it may and counts the rest instead of implying the count is the
-- whole list.
silenceWho("Me")
setClock(8120)
fireTickers()
check("a partly readable group is named, with the unreadable members counted",
    watch and (watch.text:GetText() or ""):find("Neural Silencer: You (+2 hidden by the client)", 1, true) ~= nil,
    watch and watch.text:GetText())

-- The same problem arriving as a value instead of an error. The member who really does have
-- the aura is not named (the client would not say, and an unreadable token is not evidence
-- about a person), and the line still says it was not told rather than "nobody".
resetWorld()
silenceWho("Donut")
silenceWho("Pancakes")
silSettings.display.showList = true
silSettings.display.showWatchers = true
attempt(Tattle.Silencer.OptionsChanged, Tattle.Silencer)
secreteAuraReads()
setClock(8130)
fireTickers()
check("an aura handed back unreadable is neither counted as a wearer nor as an answer",
    watch and (watch.text:GetText() or ""):find("Neural Silencer: Unknown (+2 hidden by the client)", 1, true) ~= nil
        and (watch.text:GetText() or ""):find("Donut") == nil,
    watch and watch.text:GetText())

-- Back to a group the client will talk about, for the checks that follow.
resetWorld()

-- Wearing one is never news on its own. A fresh aura, a fresh group, a fresh
-- sweep: chat stays quiet. Joining must not read out who is protected -- a
-- wearer only surfaces in the list you switched on, or in a cast alert from the
-- module that saw somebody try a swap, a grip or a rescue on them.
silenceWho("Pancakes")
table.wipe(sentMessages)
setClock(8200)
dispatch("UNIT_AURA", "raid2")
runTimers()
setClock(8300)
fireTickers()
runTimers()
setClock(8310)
dispatch("GROUP_ROSTER_UPDATE", "player")   -- a fresh raid joins, half of them protected
runTimers()
setClock(8320)
fireTickers()
runTimers()
check("nobody is ever announced for wearing a Neural Silencer",
    #sentMessages == 0, sentMessages[1] and sentMessages[1].message)
check("and the list still shows who is protected",
    watch and (watch.text:GetText() or ""):find("Pancakes", 1, true) ~= nil,
    watch and watch.text:GetText())

-- The craftable Mk3 shares the aura name; the list must not care which it is.
setClock(8400)
clearAuras()
silenceWho("Donut")
setAura("raid1", "Neural Silencer", 384129)
table.wipe(sentMessages)
setClock(8500)
dispatch("UNIT_AURA", "raid1")
runTimers()
check("the Mk3 aura ID counts too, and still says nothing",
    watch and (watch.text:GetText() or ""):find("Donut", 1, true) ~= nil
        and #sentMessages == 0,
    watch and watch.text:GetText())

-- Switching the list off must also stop its timer.
local tickersBefore = activeTickers()
silSettings.display.showList = false
attempt(Tattle.Silencer.OptionsChanged, Tattle.Silencer)
-- With the list off there is nothing to draw, and since nothing is announced
-- either, the module should be completely inert: no sweep, no scan.
auraLookups = 0
dispatch("UNIT_AURA", "raid1")
dispatch("UNIT_TARGET", "raid2")
dispatch("GROUP_ROSTER_UPDATE")
fireTickers()
runTimers()
check("with the list off the module scans nothing at all",
    auraLookups == 0, auraLookups .. " aura lookups")

check("turning the list off hides it and cancels its timer",
    not watch:IsShown() and activeTickers() == tickersBefore - 1,
    "tickers " .. tickersBefore .. " -> " .. activeTickers())
resetWorld()

-- Config panel: one window, one tab per About/General/Screen Alerts + module.
local okPanel, errPanel = callSlash("")
check("config panel opens without error", okPanel, errPanel)
local panel = Tattle.Config.frame
check("panel has About + General + Screen Alerts + one tab per module",
    panel and panel.tabs and #panel.tabs == 3 + #Tattle.Config.moduleTabs,
    panel and panel.tabs and ("got " .. #panel.tabs))

-- The Interface Options panel's own button: it opens Tattle's window and then asks the
-- client to close the settings frame. That second half is the client's business -- the
-- client this beta ran on has no `Settings.Close`, so the button threw *after* it had
-- worked (`Config.lua:833: attempt to call a nil value`), which is the worst shape of
-- that bug: the feature appears to work and an error bag says it did not. The stub
-- deliberately does not supply the method, so this click exercises the guarded path.
-- Found through the category the addon registered rather than by frame name:
-- `CreateFrame("Frame", "TattleSettingsPanel")` is immediately followed by
-- `settingsPanel.name = "Tattle"`, which is the label the Settings list shows and
-- which overwrites the widget's own name. A check that looked the panel up by the
-- name in the source would have been a check that ran zero assertions.
local optionsPanel = Tattle.Config.category and Tattle.Config.category.frame
local openConfigBtn = optionsPanel and findButton(optionsPanel, "Open Configuration")
check("the Settings page hands over a button that opens the config window",
    openConfigBtn ~= nil, "no Open Configuration button on the registered category frame")
if openConfigBtn then
    local okOpen, openErr = pcall(openConfigBtn:GetScript("OnClick"), openConfigBtn)
    check("the Interface Options button opens the panel without assuming the client's UI API",
        okOpen, openErr)
end

-- Tabs found by module rather than by position. These read "the last tab" and "tab 4",
-- which was true only while exactly three modules existed in exactly this order - and
-- this file now registers two throwaway modules of its own to test load-time failure,
-- which took the last two tabs. A UI check that passes because of where a tab happens to
-- sit is one added module away from testing nothing.
local function moduleTabOf(moduleId)
    if not (panel and panel.tabs) then return nil end
    for i, tab in ipairs(Tattle.Config.moduleTabs or {}) do
        if tab.moduleId == moduleId then return panel.tabs[3 + i] end
    end
end

-- A module that watches auras rather than casts must not be handed a filter it
-- ignores, but it does get its own section on the shared tab.
local silencerTab = moduleTabOf("silencer")
check("the Silencers tab offers the watch list options",
    silencerTab and findCheckButton(silencerTab, "Show the watch list on screen") ~= nil
        and findCheckButton(silencerTab, "List group members targeting you (needs group target syncing)") ~= nil,
    "watch list controls missing")
check("a module that filters no casts gets no Monitor control",
    silencerTab and not findLabel(silencerTab, "Monitor:")
        and findLabel(moduleTabOf("swapblaster"), "Monitor:") ~= nil,
    "Monitor dropdown present on the Silencers tab, or missing from Swapblaster's")

local showListCheck = silencerTab and findCheckButton(silencerTab, "Show the watch list on screen")
if showListCheck then
    local tickersBefore = activeTickers()
    showListCheck:SetChecked(true)
    local onShowList = showListCheck:GetScript("OnClick")
    -- Guarded so a throw reads as two FAIL lines below rather than as an aborted
    -- harness run: that is exactly what the watch list's own anchor did in a live
    -- raid, and the interesting half of that report was that the list never appeared.
    local okClick, clickErr = pcall(onShowList, showListCheck)
    runTimers()
    local watchOn = findFrameByName("TattleWatchFrame")
    check("switching the watch list on does not throw on the way to drawing it",
        okClick, clickErr)
    check("and the list is on screen the moment it is switched on",
        watchOn ~= nil and watchOn:IsShown(),
        watchOn and (watchOn.text:GetText() or "<no text>"))
    check("ticking the watch list option arms the display and its timer without a /reload",
        TattleDB.modules.silencer.display.showList == true
            and activeTickers() == tickersBefore + 1
            and findFrameByName("TattleWatchFrame") ~= nil,
        "tickers " .. tickersBefore .. " -> " .. activeTickers())
    TattleDB.modules.silencer.display.showList = false
    attempt(Tattle.Silencer.OptionsChanged, Tattle.Silencer)
    resetWorld()
end

-- Repositioning has to work before the list is switched on, so it can be placed
-- in one visit to the panel.
local repositionBtn = silencerTab and findButton(silencerTab, "Reposition List")
check("the Silencers tab offers a reposition button", repositionBtn ~= nil)
if repositionBtn then
    TattleDB.modules.silencer.display.showList = false
    attempt(Tattle.Silencer.OptionsChanged, Tattle.Silencer)
    table.wipe(sentMessages)

    local onReposition = repositionBtn:GetScript("OnClick")
    attempt(onReposition, repositionBtn)
    local preview = findFrameByName("TattleWatchFrame")
    check("Reposition List previews the list even while it is switched off",
        preview ~= nil and preview:IsShown()
            and (preview.text:GetText() or ""):find("Targeting you", 1, true) ~= nil,
        preview and preview.text:GetText())

    local onDragStop = preview and preview:GetScript("OnDragStop")
    if onDragStop then attempt(onDragStop, preview) end
    check("dragging it records a position",
        type(TattleDB.modules.silencer.display.position) == "table"
            and TattleDB.modules.silencer.display.position.point ~= nil,
        "position not saved")

    local doneBtn = findButton(silencerTab, "Done Repositioning") or repositionBtn
    attempt(doneBtn:GetScript("OnClick"), doneBtn)
    check("Done Repositioning puts the list back to sleep while it is switched off",
        preview ~= nil and not preview:IsShown() and repositionBtn._text == "Reposition List",
        repositionBtn._text)
    resetWorld()
end

-- Spell-ID editor on the Swapblaster tab (tabs: About, General, Screen Alerts, module...).
local moduleTab = moduleTabOf("swapblaster")
local editBox = moduleTab and findMultiLineEditBox(moduleTab)
local saveBtn = moduleTab and findButton(moduleTab, "Save")
local resetBtn = moduleTab and findButton(moduleTab, "Reset to Defaults")
local consoleCheck = moduleTab and findCheckButton(moduleTab, "Console output (also on with /tattle debug)")

check("module tab builds editor, save, reset and alert controls",
    editBox and saveBtn and resetBtn and consoleCheck, "widget lookup failed")

if editBox and saveBtn and resetBtn then
    local function typeText(text)
        editBox:SetText(text)
        local onTextChanged = editBox:GetScript("OnTextChanged")
        if onTextChanged then onTextChanged(editBox, true) end
    end

    check("editor starts with the built-in default IDs",
        editBox:GetText():find("161399", 1, true) ~= nil, editBox:GetText())
    check("save starts disabled (nothing edited)", not saveBtn:IsEnabled())

    typeText("161399, 161399")
    check("duplicate IDs are not an edit", not saveBtn:IsEnabled(),
        "duplicates should collapse to the stored list")

    typeText("161399, 123456")
    check("a real edit enables save", saveBtn:IsEnabled())

    local onSave = saveBtn:GetScript("OnClick")
    onSave(saveBtn)
    local saved = TattleDB.modules.swapblaster.spellIDs
    check("save persists both IDs", saved and saved[1] == 161399 and saved[2] == 123456,
        saved and table.concat(saved, ", "))
    check("save reports the saved count",
        lastPrintContaining("Saved 2 spell ID(s)") ~= nil
            or (findFrame(moduleTab, function(f)
                    return f.kind == "FontString" and f._text:find("Saved 2 spell ID", 1, true) ~= nil
                end) ~= nil))

    local onReset = resetBtn:GetScript("OnClick")
    onReset(resetBtn)
    local reset = TattleDB.modules.swapblaster.spellIDs
    check("reset restores the module defaults",
        reset and #reset == 1 and reset[1] == 161399,
        reset and table.concat(reset, ", "))
    check("reset re-disables save", not saveBtn:IsEnabled())
end

-- The rebrand is complete: `/tattle` is the command, and the old spelling is not
-- wired up. A stale keybind should fail visibly and send the player looking for
-- the real command, not keep working behind a hidden alias nobody documents.
muteAllModules()
check("/tattle is the chat command",
    callSlash("version") and lastPrintContaining("Tattle version") ~= nil)
check("the old chat command is not registered",
    SlashCmdList["SNITCH"] == nil and SLASH_SNITCH1 == nil,
    SlashCmdList["SNITCH"] ~= nil and "SlashCmdList[SNITCH] is still wired up" or nil)

-- The version a player reads in /tattle status is the one the client would read out
-- of the TOC, and this harness used to hand the addon a second, hand-typed copy of
-- it ("0.2.0" against a TOC that said 0.2.0-alpha.3). Two places that must agree and
-- are not checked are two places that drift - and the tag, the TOC and that printed
-- line are how a bug report says which build someone is holding.
check("the version the addon reports is the version in the TOC",
    TOC_VERSION ~= nil and Tattle.VERSION == TOC_VERSION,
    "addon says " .. tostring(Tattle.VERSION) .. ", Tattle.toc says " .. tostring(TOC_VERSION))

-- /tattle probe toggles
local okProbe1 = callSlash("probe")
check("/tattle probe arms the event probe", okProbe1 and Tattle._probeFrame ~= nil)

-- The probe exists to measure group casts. Alone, nobody can swap, grip or grip
-- you, and every aura and target sweep it would run is wasted.
muteAllModules()
resetWorld()
local probeLogBefore = #printLog
setGroup({})
dispatch("UNIT_SPELLCAST_SUCCEEDED", "player", "guid-solo-probe", 161399)
local probePrintsSolo = #printLog - probeLogBefore

probeLogBefore = #printLog
setGroup({ raid = true })
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid1", "guid-grouped-probe", 161399)
local probePrintsGrouped = #printLog - probeLogBefore
check("/tattle probe prints nothing while solo", probePrintsSolo == 0,
    "got " .. probePrintsSolo .. " lines")
check("/tattle probe prints the cast when grouped", probePrintsGrouped > 0)
check("/tattle probe reports the group's Neural Silencers and target syncing",
    lastPrintContaining("neural silencers") ~= nil
        and lastPrintContaining("targeting you") ~= nil)
resetWorld()

local okProbe2 = callSlash("probe")
check("/tattle probe disarms the event probe", okProbe2 and Tattle._probeFrame == nil)

-- Proxy audit: every key that resolved to the no-op proxy. These should all be
-- real FrameXML methods; anything else is a field the addon never defined.
-- ============================================================================
-- Registering a module after ADDON_LOADED
-- ============================================================================

-- Nothing should register late -- the TOC loads every module before Core's
-- ADDON_LOADED fires -- but a module that does must not be left half wired: it
-- needs settings, and it needs its listeners installed, because the core
-- registered its events at start-up and has no second chance to rebuild them. The
-- first version of the core skipped both, and skipped them silently.

local lateEvents = 0
Tattle:RegisterModule("latecomer", {
    name = "Late joiner",
    allCasters = true,   -- opts out of the group-member filter outright
    events = { "UNIT_SPELLCAST_SUCCEEDED" },
    onEvent = function() lateEvents = lateEvents + 1 end,
})
check("a module registered late still gets settings",
    type(TattleDB.modules.latecomer) == "table"
    and type(TattleDB.modules.latecomer.alerts) == "table"
    and TattleDB.modules.latecomer.enabled == true)

-- Read off `latecomer` because it is the only module in this file whose settings
-- nobody has edited: it registers after every scenario above has been ticking boxes
-- on the shipped modules. This is what a fresh install gets, and it is the second
-- half of the beta report - the shipped defaults had the console line on and the
-- on-screen warning off, which is the opposite of an alert.
local freshAlerts = TattleDB.modules.latecomer.alerts
check("a fresh install alerts on screen, and only on screen",
    freshAlerts.screen == true and freshAlerts.console == false
        and freshAlerts.chat == false and freshAlerts.audio == false,
    string.format("console=%s chat=%s audio=%s screen=%s",
        tostring(freshAlerts.console), tostring(freshAlerts.chat),
        tostring(freshAlerts.audio), tostring(freshAlerts.screen)))
check("and its chat type is a channel rather than the no-op default, for when chat is ticked",
    freshAlerts.chatType == "SAY", tostring(freshAlerts.chatType))

-- A cast by a pet is dropped for every module that takes the default group-member
-- filter and still delivered to the one that asked for every caster. That opt-out
-- had no test at all.
setGroup({ party = true, count = 3 })
resetWorld()
setClock(12000)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "partypet1", "guid-late-pet", 73325)
runTimers()
check("allCasters delivers a pet cast to the module that asked for it",
    lateEvents == 1, "the late module saw " .. lateEvents .. " event(s)")

-- Unregistered again, so the checks after this one still describe four modules.
Tattle.modules.latecomer = nil
for i = #Tattle.moduleOrder, 1, -1 do
    if Tattle.moduleOrder[i] == "latecomer" then table.remove(Tattle.moduleOrder, i) end
end
Tattle.RebuildModuleListeners()

-- ============================================================================
-- What a cast event costs
-- ============================================================================
-- These run last: they lean on module state the checks above have already
-- exercised, and none of the assertions above depends on what happens here.

alertMode("swapblaster", "RAID")
alertMode("lifegrip", "RAID")
alertMode("rescue", "RAID")
setGroup({ raid = true })

-- Four modules listen to cast events. Resolving the spell name per module --
-- what this used to do -- multiplies the count below four times over, on every
-- cast the raid produces.
spellNameLookups = 0
dispatch("UNIT_SPELLCAST_START",     "raid2", "guid-cost-1", 122)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-cost-1", 122)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-cost-2", 370666)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-cost-3", 999999)  -- watched by nobody
check("one spell-name resolution per cast event, not one per module",
    spellNameLookups == 4, spellNameLookups .. " resolutions for 4 cast events")

-- Only players can cast anything Tattle watches: a toy, Life Grip / Leap of
-- Faith and Rescue. Pets, minions, totems and NPCs all produce cast events of
-- their own, and those must be dropped so cheaply they do not even cost a name
-- lookup.
spellNameLookups = 0
runTimers()            -- drain chat queued by earlier checks before counting
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raidpet1",   "guid-pet1", 73325)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "partypet1",  "guid-pet2", 370666)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "pet",        "guid-pet3", 122)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "guid-npc",  73325)
runTimers()
check("a pet, minion or NPC cast is dropped before the spell name is resolved",
    spellNameLookups == 0 and #sentMessages == 0,
    spellNameLookups .. " lookups and " .. #sentMessages .. " alerts")

-- And you: the numbered tokens do not cover yourself, so membership has to
-- include you explicitly or your own casts are filtered out before any module
-- ever sees them.
alertMode("swapblaster", "RAID")
resetWorld()
setGroup({ raid = true })
runTimers()   -- drain, as above
table.wipe(sentMessages)
advanceClock(60)
dispatch("UNIT_SPELLCAST_CHANNEL_START", "player", "guid-me", 161399)
advanceClock(2)
dispatch("UNIT_SPELLCAST_CHANNEL_STOP",  "player", "guid-me", 161399)
runTimers()
check("your own casts alert too - you are not partyN or raidN",
    messageContaining("used Swapblaster") ~= nil,
    sentMessages[1] and sentMessages[1].message)

-- A client without the allocation-free name lookup still gets alerts: the core
-- falls back to GetSpellInfo rather than dropping every cast.
resetWorld()
setGroup({ raid = true })
local savedGetSpellName = C_Spell.GetSpellName
C_Spell.GetSpellName = nil
table.wipe(sentMessages)
dispatch("UNIT_SPELLCAST_SUCCEEDED", "raid2", "guid-fallback", 73325)
runTimers()
C_Spell.GetSpellName = savedGetSpellName
check("cast alerts survive a client without C_Spell.GetSpellName",
    messageContaining("Pancakes used Life Grip") ~= nil,
    sentMessages[1] and sentMessages[1].message)

-- The cached group lists must not outlive the group they described.
setGroup({ raid = true, count = 5 })
local cachedTokens = Tattle.GroupUnitTokens()
check("the group token list is reused between scans", cachedTokens == Tattle.GroupUnitTokens())
dispatch("GROUP_ROSTER_UPDATE")
check("GROUP_ROSTER_UPDATE drops the cached group lists",
    Tattle.GroupUnitTokens() ~= cachedTokens)

-- A nil where the client wants a number is an error on a real client, so it is a
-- failure here too. Without this, the harness treats SetSize(700, nil) as a shrug.
end

-- ============================================================================
-- Source audits
-- ============================================================================
--
-- The alpha.3 crash line was `name ~= ""`, and this harness cannot make that raise.
-- Lua 5.1 consults __eq for tables only, so a value that stands in for a secret
-- *string* has to be some other kind of value before it can have metamethods at all
-- - which is why the stub models a secret as an unindexable table and says so in the
-- comment above its definition. What the checks prove is what happens when the addon
-- *uses* such a value through the APIs that accept one. What they cannot prove is
-- that the addon never compares one with a literal, so the text is checked instead.
--
-- The rule is deliberately narrow: comparing anything with an empty-string literal
-- is only ever correct about a string this addon wrote itself. A client that will not
-- name somebody does not answer with the empty string - it answers by refusing the
-- read, or with a value that cannot be read - so `x ~= ""` is a guess about a value
-- the addon is not allowed to look at, wherever `x` came from the client. A line that
-- genuinely compares something plain has to declare that on the line, where the next
-- person reading it can see what was considered.

local auditOffenders = {}
for _, file in ipairs(files) do
    local handle = io.open(ADDON_DIR .. "/" .. file, "r")
    if handle then
        local lineNo = 0
        for rawLine in handle:lines() do
            lineNo = lineNo + 1
            local line = rawLine:gsub("^%s+", "")
            -- Comments are where the rule gets explained, including in this file.
            if not line:match("^%-%-") and not line:find("-- plain") then
                if line:find('== ""', 1, true) or line:find('~= ""', 1, true)
                    or line:find('"" ==', 1, true) or line:find('"" ~=', 1, true)
                    or line:find('==""', 1, true) or line:find('~=""', 1, true) then
                    table.insert(auditOffenders, file .. ":" .. lineNo .. ": " .. line)
                end
            end
        end
        handle:close()
    end
end
check("nothing that came from the client is compared with an empty string",
    #auditOffenders == 0, "\n  " .. table.concat(auditOffenders, "\n  "))

-- How faithfully this file's fake secret values model a real client, stated rather than
-- assumed. The stand-ins are proxy tables and the metamethods they install are the ones
-- a client refuses - but `__len` on a table only exists from Lua 5.2, so on CI's lua5.1
-- taking the length of a fake secret answers 0 instead of raising, and a check written
-- against `#` would see cooperation the real client never gives. Local Lua is 5.5 and CI
-- runs 5.1, so the two runs are not modelling the same client, and the difference is
-- recorded here instead of being discovered by whoever trusts it next. Nothing in the
-- addon may take the length of a value it did not create; the client-API audit above is
-- what keeps that true.
local lenRefused = not pcall(function() return #Secret.asSecret("a secret string") end)
realPrint("== this interpreter (" .. _VERSION .. ") "
    .. (lenRefused and "refuses" or "does NOT refuse") .. " # on a secret value ==")
check("the fake secret values are as strict as this interpreter can be",
    lenRefused or _VERSION == "Lua 5.1",
    _VERSION .. " answered # on a secret value where a client would refuse")

-- The core is the only place that knows which client APIs accept a secret value and
-- which refuse it. A module calling UnitName or C_Spell.GetSpellName directly has
-- stepped around that one layer, which is how the crash got into a module's reach in
-- the first place. Probe is exempt: its whole job is finding out what a given client
-- exposes, and every read in it is guarded for exactly that reason.
--
-- Each needle is a frontier pattern, `%f[%.%w]Name%(`: a match only where the name
-- starts a word and is not preceded by a dot. Two reasons, and the audit was wrong
-- without both:
--
--   * `Tattle.UnitDisplayName(x)` is the wrapper this addon *wants* modules to call,
--     and a plain substring needle flags it, which is how an audit gets turned off;
--   * the set is the set of characters that mean "not a boundary" - `.`, letters,
--     digits, underscore. `%f[^%.%w]` looks like the same thing and is its opposite:
--     a complemented class inside %f matches *inside* every run of those characters,
--     so it finds nothing and the audit passes green on code it never looked at.
--
-- Which is also why the file list is built with `file:match("^Modules/")` and not
-- `file:find("^Modules/", 1, true)`: with plain find turned on the second argument is
-- a starting index, not a pattern, so the needle searched for was the nine characters
-- `^Modules/` - which appears in no source line. This audit ran over exactly one file,
-- Commands.lua, and reported clean for the three modules it exists to police.
local RAW_VALUE_APIS = {
    "%f[%.%w]UnitName%(",
    "%f[%.%w]UnitDisplayName%(",
    "%f[%.%w]UnitIsUnit%(",
    "%f[%.%w]UnitExists%(",
    "%f[%.%w]UnitAffectingCombat%(",
    "C_Spell%.GetSpellName%(",
    "C_Spell%.GetSpellInfo%(",
    "%f[%.%w]C_UnitAuras%.",
}
local apiOffenders = {}
local apiScanned = 0
for _, file in ipairs(files) do
    if file:match("^Modules/") or file == "Commands.lua" then
        local handle = io.open(ADDON_DIR .. "/" .. file, "r")
        if handle then
            apiScanned = apiScanned + 1
            local lineNo = 0
            for rawLine in handle:lines() do
                lineNo = lineNo + 1
                local line = rawLine:gsub("^%s+", "")
                if not line:match("^%-%-") then
                    for _, api in ipairs(RAW_VALUE_APIS) do
                        if line:match(api) then
                            table.insert(apiOffenders, file .. ":" .. lineNo .. ": " .. line)
                        end
                    end
                end
            end
            handle:close()
        end
    end
end
-- An audit that read no files is not a passing audit, and the bug above is exactly
-- one of those: the count is asserted, so a broken file list fails instead of shipping
-- the illusion of a rule.
check("the client-API audit actually opened the files it polices",
    apiScanned >= 4,
    "scanned " .. apiScanned .. " file(s); every module and Commands.lua should be in it")
check("no module or command reaches past the core's accessors for a client value",
    #apiOffenders == 0, "\n  " .. table.concat(apiOffenders, "\n  "))

-- A module whose declared out-of-combat policy resolves to nothing gates nothing,
-- and alpha.3 shipped precisely that: the policy table entry was built from a global
-- that had not been defined yet. The behaviour check above (the gate has to drop as
-- well as allow) is the real guard; this one is what makes the mistake obvious rather
-- than merely detectable.
local KNOWN_POLICIES = { start = true, all = true }
local policyOffenders = {}
for moduleId, module in pairs(Tattle.modules) do
    local policy = module.outOfCombat
    if policy ~= nil and not KNOWN_POLICIES[policy] then
        table.insert(policyOffenders, moduleId .. " asks for \"" .. tostring(policy) .. "\"")
    end
end
check("every module asks for an out-of-combat policy the core implements",
    #policyOffenders == 0, table.concat(policyOffenders, "; "))

-- A developer machine runs whatever Lua Homebrew installed (this one reports 5.5.1);
-- CI installs lua5.1, because that is the closest thing to the game's own Lua. Code
-- that only exists in 5.2+ compiles happily here and dies in CI, on a line no review
-- comment would catch, so the constructs themselves are audited - in the addon and in
-- this file, which CI runs under 5.1 as well.
local FUTURE_LUA = {
    "//", "<<", ">>", "bit32.", "math.type(", "math.tointeger(", "math.maxinteger",
    "math.atan(", "table.move(", "table.pack(", "table.unpack(", "utf8.", "string.pack(",
    "warn(", "<close>", "<const>", "goto ", "::",
}
local luaOffenders = {}
local ownPath = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
-- Every file that ships, from the TOC, plus this one - not a hand-written list of
-- the files somebody remembered. A hard-coded list silently stops covering the addon
-- the moment a file is added or renamed, and the three UI files this list used to
-- omit (Config.lua, ScreenAlert.lua, ConfigSpellIDs.lua) are ones a player will
-- notice: a `//` in any of them kills the config panel in the game, in silence.
local toRead = { { ownPath, "Tests/wow_stub.lua" } }
for _, file in ipairs(files) do
    toRead[#toRead + 1] = { ADDON_DIR .. "/" .. file, file }
end
-- Again: opened, not intended. An empty or mistyped list would pass.
check("the Lua-version audit reads every file that ships",
    #toRead >= #files + 1,
    "read " .. (#toRead - 1) .. " of " .. #files .. " shipped files")
local luaScanned = 0
for _, source in ipairs(toRead) do
    local handle = io.open(source[1], "r")
    if handle then
        luaScanned = luaScanned + 1
        local lineNo = 0
        for rawLine in handle:lines() do
            lineNo = lineNo + 1
            local line = rawLine:gsub("^%s+", "")
            if not line:match("^%-%-") then
                -- String literals are taken out first, so a URL or a WoW colour code
                -- is not read as an operator.
                local code = line:gsub('".-"', '""'):gsub("'[^']*'", "''")
                for _, token in ipairs(FUTURE_LUA) do
                    if code:find(token, 1, true) then
                        table.insert(luaOffenders, source[2] .. ":" .. lineNo .. ": " .. line)
                        break
                    end
                end
            end
        end
        handle:close()
    end
end
-- Opened, not merely listed: a file that is in the TOC but not on disk would leave
-- this audit saying "clean" about a file it never read.
check("the Lua-version audit read every file it claims to",
    luaScanned == #toRead,
    "opened " .. luaScanned .. " of " .. #toRead)
check("nothing here needs a Lua newer than the one CI runs",
    #luaOffenders == 0, "\n  " .. table.concat(luaOffenders, "\n  "))

-- ============================================================================
-- A build that does not have the API.
--
-- Everything above runs against a client that owns every API this addon asks for and
-- answers every question cooperatively. That is the friendliest world available, and it is
-- not the world the documentation describes: `C_SecretComparisons` is not named anywhere in
-- the generated 12.1.5 or 12.1.7 docs, and the four cast-target APIs are two patch levels
-- old. An addon that *assumes* an API produces a line in someone's error bag - which is
-- literally how this release cycle opened (`Config.lua:833: attempt to call a nil value`,
-- from a `Settings.Close` nobody had asked the client about). So each API here is taken
-- away and the same sentence is run again, which asks two questions at once: nothing
-- raises, and what comes back is degraded rather than optimistic.
--
-- These checks are only possible because the shipped code looks every one of these up at
-- the moment it calls it. That is why the two load-time captures in Core.lua became
-- call-time lookups on this section's account: a capture at load time cannot be exercised
-- by a harness that loads the addon exactly once into exactly one client, and an absence
-- nobody can test is a guard that has quietly become a comment.
--
-- Everything is inside one `do` block for a reason that cost a debugging round to learn:
-- several of this file's helper functions (`alertMode`, `chatOnly`, `fiveDeepRaid`) are
-- `local function` declarations written at indent 0 *inside the body of the
-- `for _, moduleId in ipairs(Tattle.moduleOrder)` loop further up*, so they are invisible
-- down here and reading them is a nil global rather than a compile error. Anything this
-- section needs is declared locally.
-- ============================================================================

do
    -- Nil the *globals* for the duration of one scenario - the shape a build has when it
    -- never had the function - and put them back whatever the scenario did to them.
    -- An array of { name, value } rather than a table keyed by name: `pairs` cannot carry an
    -- absent global, and "absent" is most of what this section asks about.
    local function withGlobals(entries, label, scenario)
        local saved = {}
        for _, entry in ipairs(entries) do
            saved[#saved + 1] = { name = entry.name, value = _G[entry.name] }
            _G[entry.name] = entry.value
        end
        local ok, err = pcall(scenario)
        for _, slot in ipairs(saved) do _G[slot.name] = slot.value end
        check("asking about " .. label .. " did not raise", ok, tostring(err))
    end

    local function withoutApis(names, scenario)
        local entries = {}
        for _, name in ipairs(names) do entries[#entries + 1] = { name = name } end
        withGlobals(entries, "a build without " .. table.concat(names, " / "), scenario)
    end

    local function raidOfFive()
        resetWorld()
        setGroup({ raid = true, count = 5, selfIndex = 4 })
    end

    -- The alert routing this section needs, written out rather than borrowed: chat on the
    -- channel under test, nothing else, so an alert either arrives in `sentMessages` or does
    -- not and there is no screen frame to confuse the count with.
    local function chatOnlyAlerts(moduleId, chatType)
        local settings = TattleDB.modules[moduleId]
        settings.enabled = true
        settings.scope = "group"
        settings.alerts.console = false
        settings.alerts.chat = true
        settings.alerts.chatType = chatType
        settings.alerts.audio = false
        settings.alerts.screen = false
        table.wipe(sentMessages)
        -- The body's own `chatOnly` gets this reset from the `resetWorld` it calls; this
        -- section's version does not reset the world, so it clears the counter itself.
        -- Without this line the two chat checks below measure one counter across two
        -- scenarios, which is how "the attempt was suppressed" starts reporting the
        -- previous scenario's attempt.
        chatSendAttempts = 0
    end

    local function joinedAlerts()
        local parts = {}
        for i = 1, #sentMessages do parts[i] = tostring(sentMessages[i].message) end
        return table.concat(parts, " | ")
    end

    -- The whole 12.1.x answer set missing. The alert must still happen - a swap nobody can
    -- attribute is still a swap - and the weaker evidence must still be used, still labelled.
    withoutApis({ "PlayerIsSpellTarget", "UnitIsSpellTarget", "UnitShouldDisplaySpellTargetName",
                  "UnitSpellTargetName", "UnitSpellTargetClass" }, function()
        raidOfFive()
        chatOnlyAlerts("swapblaster", "YELL")
        spellTargetNamesAreSecret = false
        setSpellTarget("raid1", "raid5")      -- what a build carrying the API would have said
        setTarget("raid1", "raid2")           -- whom the caster's interface is pointed at
        local errors = {}
        setClock(GetTime() + 60)
        for _, err in ipairs(dispatch("UNIT_SPELLCAST_CHANNEL_START", "raid1", "guid-gone-1", 161399)) do
            errors[#errors + 1] = err
        end
        setClock(GetTime() + 2)
        for _, err in ipairs(dispatch("UNIT_SPELLCAST_CHANNEL_STOP", "raid1", "guid-gone-1", 161399)) do
            errors[#errors + 1] = err
        end
        runTimers()
        check("a cast whose target APIs do not exist is still reported",
            messageContaining("Donut used Swapblaster") ~= nil and #errors == 0,
            joinedAlerts() .. " ;; " .. table.concat(errors, " ;; "))
        check("a build with no target API still uses the weaker evidence, and still calls it aiming",
            messageContaining("aiming at Pancakes") ~= nil, joinedAlerts())
        -- The failure this third check exists for: an implementation that reads "no API" as
        -- "no target" and then reaches for the strongest sentence it knows anyway.
        check("and it never claims the swap landed on somebody it was not told about",
            messageContaining("Swapblaster on ") == nil, joinedAlerts())
    end)

    -- The two target questions are independent, and a build may carry only one of them.
    withoutApis({ "PlayerIsSpellTarget", "UnitIsSpellTarget" }, function()
        raidOfFive()
        spellTargetNamesAreSecret = false
        setSpellTarget("raid1", "raid5")
        setTarget("raid1", "raid2")
        local token, source = Tattle.CastTargetOf("raid1")
        check("the name path does not depend on the is-it-me boolean",
            token == "raid5" and source == "spell-target",
            tostring(token) .. " / " .. tostring(source))
    end)

    -- And the other way round, which is the case that matters most: *you* were the target,
    -- and that answer never needed a name from anybody.
    withoutApis({ "UnitSpellTargetName", "UnitSpellTargetClass" }, function()
        raidOfFive()
        setSpellTarget("raid1", "player")
        setTarget("raid1", "raid2")
        local token, source = Tattle.CastTargetOf("raid1")
        check("being the spell's target is answered with no name API in the build",
            token == "player" and source == "spell-target",
            tostring(token) .. " / " .. tostring(source))
    end)

    -- Absent and "answered no" are different facts, and this is where an implementation
    -- could confuse them for the price of every target name on a build that has no gate.
    withoutApis({ "UnitShouldDisplaySpellTargetName" }, function()
        raidOfFive()
        spellTargetNamesAreSecret = false
        setSpellTarget("raid1", "raid5")
        setTarget("raid1", "raid2")
        local token, source = Tattle.CastTargetOf("raid1")
        check("a build with no display gate is not read as a gate that answered false",
            token == "raid5" and source == "spell-target",
            tostring(token) .. " / " .. tostring(source))
    end)

    -- The API with the weakest claim to existing at all, asked about a name the client will
    -- not read. Falls back to the weaker source; never invents a member.
    withoutApis({ "C_SecretComparisons" }, function()
        raidOfFive()
        spellTargetNamesAreSecret = true
        setSpellTarget("raid1", "raid5")
        setTarget("raid1", "raid2")
        local token, source = Tattle.CastTargetOf("raid1")
        check("with no sanctioned comparison in the build the name stays unresolved, not guessed",
            token == "raid2" and source == "unit-target",
            tostring(token) .. " / " .. tostring(source))
    end)

    -- Two secrecy-detection paths, one of them a fallback. With the sanctioned predicate
    -- missing, a hidden aura read must still be withheld rather than counted as an answered
    -- "no aura" - the watch list's whole claim rests on that difference.
    local silenced = { ["Neural Silencer"] = true }
    raidOfFive()
    silenceWho("Donut")          -- somebody who does have one, so the read has something to hide
    secreteAuraReads()
    local controlCarriers, controlHidden = Tattle.AuraCarrierSplit(silenced, "HELPFUL")
    check("a protected member whose aura comes back hidden is withheld (baseline)",
        #controlCarriers == 0 and #controlHidden == 1,
        #controlCarriers .. " carriers, " .. #controlHidden .. " hidden")
    withoutApis({ "canaccessvalue" }, function()
        local carriers, hidden = Tattle.AuraCarrierSplit(silenced, "HELPFUL")
        check("the fallback secrecy test reaches the same withheld answer",
            #carriers == #controlCarriers and #hidden == #controlHidden and #hidden > 0,
            #carriers .. " carriers, " .. #hidden .. " hidden")
    end)

    -- And that the fallback above is not the only thing ever consulted. The two checks so far
    -- turn out to be *one* check if they run against a value that refuses `tostring` as well
    -- as the predicate: then the sanctioned path and the heuristic answer alike, and deleting
    -- the predicate's use entirely stays green (it took running the mutation to find that).
    -- So this scenario turns the secrecy off at the aura and puts the refusal only in the
    -- predicate - a deliberately synthetic disagreement between two client surfaces, which is
    -- the only way to see which of the two the code actually asked.
    aurasReturnSecrets = false
    withGlobals({ { name = "canaccessvalue", value = function() return false end } },
        "a predicate that refuses everything it is asked about", function()
        local carriers, hidden = Tattle.AuraCarrierSplit(silenced, "HELPFUL")
        check("the sanctioned secrecy predicate is asked, and obeyed, before any fallback",
            #carriers == 0 and #hidden == 1,
            #carriers .. " carriers, " .. #hidden .. " hidden")
    end)

    -- The rule from the other side: a build with no aura reader at all must not report an
    -- unprotected group. Readable auras first, so the baseline proves the member shows.
    raidOfFive()
    silenceWho("Donut")
    local readableCarriers, readableHidden = Tattle.AuraCarrierSplit(silenced, "HELPFUL")
    local groupSize = #Tattle.GroupUnitTokens()
    check("a readable protected member is named (baseline)",
        #readableCarriers == 1 and groupSize >= 2,
        #readableCarriers .. " carriers of " .. groupSize .. " members, " .. #readableHidden .. " hidden")
    withoutApis({ "C_UnitAuras" }, function()
        local carriers, hidden = Tattle.AuraCarrierSplit(silenced, "HELPFUL")
        check("a build with no aura reader leaves every member unanswered, none unprotected",
            #carriers == 0 and #hidden == groupSize,
            #carriers .. " carriers, " .. #hidden .. " hidden of " .. groupSize)
    end)

    -- Chat's two gates on a build that cannot answer the first question. The permissive side
    -- is a decision, so it is asserted as one; the printability gate is asserted to hold
    -- without any client cooperation, which is what makes that decision safe.
    withoutApis({ "C_ChatInfo" }, function()
        raidOfFive()
        chatOnlyAlerts("swapblaster", "SAY")
        Tattle.SendAlert("Donut used Swapblaster on Maple", "swapblaster")
        runTimers()
        check("with no lockdown API the send is still attempted - the permissive side, on purpose",
            chatSendAttempts == 1 and #sentMessages == 1,
            "attempted " .. chatSendAttempts .. ", arrived " .. #sentMessages)
        chatOnlyAlerts("swapblaster", "SAY")
        Tattle.SendAlert(Secret.asSecret("Maple"), "swapblaster")
        runTimers()
        check("and the gate that does not ask the client holds without any client help",
            chatSendAttempts == 0 and #sentMessages == 0,
            "attempted " .. chatSendAttempts .. ", arrived " .. #sentMessages)
    end)
end

local geometrySeen = {}
for _, line in ipairs(nilGeometry) do
    if not geometrySeen[line] then geometrySeen[#geometrySeen + 1] = line end
end
check("no widget geometry call was handed a nil",
    #nilGeometry == 0, table.concat(geometrySeen, "; "))

-- The live-raid version of the check above: arguments the client would not have
-- accepted, which the stub used to accept. The string in a region slot that started
-- this list is invisible to a nil audit because it is not nil.
-- Deduplicated the same way the nil list above is, because one broken anchor throws
-- once per sweep and the interesting part of the message is the region name.
local function unique(lines)
    local seen, out = {}, {}
    for _, line in ipairs(lines) do
        if not seen[line] then
            seen[line] = true
            out[#out + 1] = line
        end
    end
    return out
end
check("no widget geometry call was refused by the client's argument rules",
    #badGeometry == 0, table.concat(unique(badGeometry), "; "))

-- Everything the client runs for you on a timer - the watch list's sweep, a deferred
-- chat send - ran here without raising. In the game each of these was an error bag.
check("no timer or ticker callback threw",
    #callbackErrors == 0, table.concat(unique(callbackErrors), "; "))

-- Same rule for the calls this file drives by hand: a widget call that raises in the
-- game is an error bag the player sees and the addon survives, so here it is a line in
-- this list and the checks after it still describe the wreckage.
check("no display or settings call the harness drove by hand threw",
    #displayErrors == 0, table.concat(unique(displayErrors), "; "))

local proxied = {}
for _, f in ipairs(frames) do
    for key in pairs(f._proxied) do proxied[key] = true end
end
local keys = {}
for key in pairs(proxied) do keys[#keys + 1] = key end
table.sort(keys)
realPrint("== proxied widget keys (" .. #keys .. ") ==")
realPrint("  " .. table.concat(keys, ", "))

check("no scenario rewound the client clock to make a module's record look stale",
    #clockRewinds == 0, table.concat(clockRewinds, "; "))

realPrint("== passed " .. checks.passed .. ", failed " .. checks.failed .. " ==")
os.exit(checks.failed == 0 and 0 or 1)
