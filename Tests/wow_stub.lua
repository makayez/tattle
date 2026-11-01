--[[ Tests/wow_stub.lua

A stub WoW client so Snitch can be smoke-tested without the game.

Usage:
    lua Tests/wow_stub.lua            # from the addon folder
    lua Tests/wow_stub.lua /path/to/snitch

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
local eventFrames = {}     -- event name -> { frame, ... }
local timers = {}
local sentMessages = {}
local printLog = {}

local newFrame
do
    local frame_mt = {
        __index = function(f, key)
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

        f.SetScript = function(_, script, fn) f._scripts[script] = fn end
        f.GetScript = function(_, script) return f._scripts[script] end
        f.RegisterEvent = function(_, event)
            eventFrames[event] = eventFrames[event] or {}
            table.insert(eventFrames[event], f)
        end
        f.UnregisterEvent = function() end

        f.Show = function() f._shown = true end
        f.Hide = function() f._shown = false end
        f.IsShown = function() return f._shown end
        f.IsVisible = function() return f._shown end

        f.SetText = function(_, text) f._text = tostring(text) end
        f.GetText = function() return f._text end
        -- FontString: CreateTabButton measures the label to size tab buttons,
        -- so this must return a number or the width arithmetic explodes.
        f.GetStringWidth = function() return 60 end

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
        f.SetWidth = function(_, w) if type(w) == "number" then f._width = w end end
        f.SetSize = function(_, w, h)
            if type(w) == "number" then f._width = w end
            if type(h) == "number" then f._height = h end
        end
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
}
local function runTimers()
    local pending = timers
    timers = {}
    for _, fn in ipairs(pending) do fn() end
end

local clock = 1000
GetTime = function() return clock end
time = function() return clock end

-- Tests move the clock by hand so a channeled cast can be made to look either
-- completed or cut short.
local function setClock(t) clock = t end

-- UnitCastingInfo/UnitChannelInfo return
-- (name, text, texture, startTime, endTime, isTrade, notInterruptible, spellID).
UnitCastingInfo = function()
    return "Swap", nil, nil, clock, clock + 1.5, false, false, 161399
end
UnitChannelInfo = function()
    return "Swap", nil, nil, clock, clock + 1.5, false, false, 161399
end

PlaySound = function() return true end
SendChatMessage = function(message, channel)
    table.insert(sentMessages, { message = message, channel = channel })
end

SlashCmdList = {}

-- ============================================================================
-- Group / unit state
-- ============================================================================

local unitNames = { raid1 = "Donut", raid2 = "Pancakes", player = "Me" }

IsInRaid = function() return true end
IsInGroup = function() return true end
IsInGuild = function() return true end
GetNumGroupMembers = function() return 2 end

UnitExists = function(unit) return unitNames[unit] ~= nil end
UnitName = function(unit) return unitNames[unit] end
UnitIsUnit = function(a, b) return a == b end
UnitInRaid = function(unit)
    if unit == "raid1" then return 1 end
    if unit == "raid2" then return 2 end
    return nil
end
UnitInParty = function() return nil end
UnitAffectingCombat = function() return false end

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
        local name = spellNames[id]
        if not name then return nil end
        return { spellID = id, name = name }
    end,
}

-- auras[unit][spellName] = spellID, driven by the checks that need a target.
local auras = {}
local function setAura(unit, spellName, spellID)
    auras[unit] = auras[unit] or {}
    auras[unit][spellName] = spellID
end
local function clearAuras()
    for unit in pairs(auras) do auras[unit] = nil end
end

C_UnitAuras = {
    GetAuraDataBySpellName = function(unit, spellName, filter)
        local byUnit = auras[unit]
        local spellID = byUnit and byUnit[spellName]
        if not spellID then return nil end
        return { spellID = spellID, name = spellName, auraInstanceID = spellID }
    end,
}

C_AddOns = {
    GetAddOnMetadata = function(_, key)
        if key == "Version" then return "0.2.0" end
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
Settings = {
    RegisterCanvasLayoutCategory = function(frame, name)
        return { frame = frame, name = name }
    end,
    RegisterAddOnCategory = function()
        interfaceOptionsRegistered = interfaceOptionsRegistered + 1
    end,
    Close = function() end,
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
    return pcall(SlashCmdList["SNITCH"], msg)
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

local function findMultiLineEditBox(root)
    return findFrame(root, function(f)
        return f.kind == "EditBox" and f._multiLine
    end)
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

-- ============================================================================
-- Load the addon in TOC order
-- ============================================================================

local function readTocFiles()
    local path = ADDON_DIR .. "/Snitch.toc"
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

local loadErrors = {}
for _, file in ipairs(files) do
    local chunk, err = loadfile(ADDON_DIR .. "/" .. file)
    if not chunk then
        table.insert(loadErrors, file .. ": " .. tostring(err))
    else
        local ok, runErr = pcall(chunk, "Snitch")
        if not ok then table.insert(loadErrors, file .. ": " .. tostring(runErr)) end
    end
end

realPrint("== Checks ==")

-- CHECKS (each one guards behaviour that must not regress):
--  1. every file loads and ADDON_LOADED completes without a Lua error
--  2. the load banner and the Interface Options entry both happen
--  3. modules register in TOC order (pairs() over a string-keyed table has no
--     defined order, so tabs and /snitch status would reshuffle run to run)
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
-- 12. /snitch probe toggles the event probe on and off

check("all files load", #loadErrors == 0, table.concat(loadErrors, "; "))

local eventErrors = dispatch("ADDON_LOADED", "Snitch")
runTimers()
check("ADDON_LOADED completes without error", #eventErrors == 0, table.concat(eventErrors, "; "))

check("load banner printed",
    lastPrintContaining("loaded. Type /snitch") ~= nil,
    "no load line (a Lua error in ADDON_LOADED aborts the rest of the handler)")
check("Interface Options category registered",
    interfaceOptionsRegistered == 1, "got " .. interfaceOptionsRegistered)

check("modules registered in TOC order",
    Snitch.moduleOrder[1] == "swapblaster" and Snitch.moduleOrder[2] == "lifegrip"
        and Snitch.moduleOrder[3] == "rescue",
    table.concat(Snitch.moduleOrder, ", "))

check("modules ship the spell IDs verified against the live 12.1.5 database",
    Snitch.modules.swapblaster.defaultSpellIDs[1] == 161399
        and Snitch.modules.lifegrip.defaultSpellIDs[1] == 73325
        and Snitch.modules.rescue.defaultSpellIDs[1] == 370666,
    "shipped spell IDs drifted from the verified ones")

-- /snitch status lists modules in registration order
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
for _, moduleId in ipairs(Snitch.moduleOrder) do
    expectedOrder[#expectedOrder + 1] = Snitch.modules[moduleId].name
end
check("/snitch status lists modules in registration order",
    table.concat(printedOrder, ", ") == table.concat(expectedOrder, ", "),
    table.concat(printedOrder, ", ") .. " vs " .. table.concat(expectedOrder, ", "))

local function alertMode(moduleId, chatType)
    local settings = SnitchDB.modules[moduleId]
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
    sentMessages[1] and sentMessages[1].message:find("Donut is casting SwapBlaster", 1, true),
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
    sentMessages[2] and sentMessages[2].message:find("Donut used SwapBlaster", 1, true),
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
        and messageContaining("Pancakes's SwapBlaster was cut short") ~= nil
        and messageContaining("Pancakes used SwapBlaster") == nil,
    sentMessages[1] and sentMessages[1].message)

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
SnitchDB.modules.swapblaster.alerts.console = true
table.wipe(sentMessages)
setClock(3000)
dispatch("UNIT_SPELLCAST_START", "raid1", "guid-7", 161399)
runTimers()
check("chatType PRIVATE sends nothing to chat", #sentMessages == 0, "got " .. #sentMessages)
check("chatType PRIVATE still prints to the console",
    lastPrintContaining("Donut is casting SwapBlaster") ~= nil)

-- scope "self" means "it involved me", not "I cast it": someone else's cast
-- aimed at you is the whole point of the addon.
SnitchDB.modules.lifegrip.scope = "self"
check("scope self rejects a resolved target that is not you",
    Snitch.ShouldReport("lifegrip", "raid2", { "raid1" }) == false)
check("scope self accepts a resolved target that includes you",
    Snitch.ShouldReport("lifegrip", "raid2", { "raid1", "player" }) == true)
check("scope self accepts your own cast",
    Snitch.ShouldReport("lifegrip", "player") == true)
check("scope self treats an unresolved target as reportable",
    Snitch.ShouldReport("lifegrip", "raid2") == nil
        and Snitch.ShouldReport("lifegrip", "raid2", {}) == nil)

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

SnitchDB.modules.lifegrip.scope = "group"
check("scope group accepts another member's cast",
    Snitch.ShouldReport("lifegrip", "raid2", { "raid1" }) == true)

-- Swap applies no aura to either side, so "self" can never rule it out.
alertMode("swapblaster", "YELL")
SnitchDB.modules.swapblaster.scope = "self"
check("scope self cannot rule out a Swapblaster",
    Snitch.ShouldReport("swapblaster", "raid2") == nil)
table.wipe(sentMessages)
setClock(4000)
dispatch("UNIT_SPELLCAST_START", "raid2", "guid-10", 161399)
runTimers()
check("scope self keeps a Swapblaster warning it cannot place", #sentMessages == 1,
    "got " .. #sentMessages)
SnitchDB.modules.swapblaster.scope = "group"

-- Config panel: one window, one tab per About/General/Screen Alerts + module.
local okPanel, errPanel = callSlash("")
check("config panel opens without error", okPanel, errPanel)
local panel = Snitch.Config.frame
check("panel has About + General + Screen Alerts + one tab per module",
    panel and panel.tabs and #panel.tabs == 3 + #Snitch.Config.moduleTabs,
    panel and panel.tabs and ("got " .. #panel.tabs))

-- Spell-ID editor on the first module tab (tabs: About, General, Screen Alerts, module...).
local moduleTab = panel and panel.tabs and panel.tabs[4]
local editBox = moduleTab and findMultiLineEditBox(moduleTab)
local saveBtn = moduleTab and findButton(moduleTab, "Save")
local resetBtn = moduleTab and findButton(moduleTab, "Reset to Defaults")
local consoleCheck = moduleTab and findCheckButton(moduleTab, "Console output")

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
    local saved = SnitchDB.modules.swapblaster.spellIDs
    check("save persists both IDs", saved and saved[1] == 161399 and saved[2] == 123456,
        saved and table.concat(saved, ", "))
    check("save reports the saved count",
        lastPrintContaining("Saved 2 spell ID(s)") ~= nil
            or (findFrame(moduleTab, function(f)
                    return f.kind == "FontString" and f._text:find("Saved 2 spell ID", 1, true) ~= nil
                end) ~= nil))

    local onReset = resetBtn:GetScript("OnClick")
    onReset(resetBtn)
    local reset = SnitchDB.modules.swapblaster.spellIDs
    check("reset restores the module defaults",
        reset and #reset == 1 and reset[1] == 161399,
        reset and table.concat(reset, ", "))
    check("reset re-disables save", not saveBtn:IsEnabled())
end

-- /snitch probe toggles
local okProbe1 = callSlash("probe")
check("/snitch probe arms the event probe", okProbe1 and Snitch._probeFrame ~= nil)
local okProbe2 = callSlash("probe")
check("/snitch probe disarms the event probe", okProbe2 and Snitch._probeFrame == nil)

-- Proxy audit: every key that resolved to the no-op proxy. These should all be
-- real FrameXML methods; anything else is a field the addon never defined.
local proxied = {}
for _, f in ipairs(frames) do
    for key in pairs(f._proxied) do proxied[key] = true end
end
local keys = {}
for key in pairs(proxied) do keys[#keys + 1] = key end
table.sort(keys)
realPrint("== proxied widget keys (" .. #keys .. ") ==")
realPrint("  " .. table.concat(keys, ", "))

realPrint("== passed " .. checks.passed .. ", failed " .. checks.failed .. " ==")
os.exit(checks.failed == 0 and 0 or 1)
