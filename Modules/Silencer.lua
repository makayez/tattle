-- Modules/Silencer.lua

Tattle = Tattle or {}
Tattle.Silencer = {}

local Silencer = Tattle.Silencer

-- ============================================================================
-- Localize Globals
-- ============================================================================

local string_format = string.format
local string_upper = string.upper
local ipairs = ipairs
local pairs = pairs
local type = type
local table_concat = table.concat
local C_Spell = C_Spell
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local GetTime = GetTime
local UIParent = UIParent

local MODULE_ID          = "silencer"
local MODULE_NAME        = "Neural Silencer Watch"
local MODULE_DESCRIPTION = "Tracks who in the group is wearing a Neural Silencer, for the blocked-cast alerts and an optional on-screen list"

-- Wearing one is never news on its own. This module does not announce that
-- somebody has the aura -- joining a raid must not fill chat with "Donut has one
-- on, Pancakes has one on, ..". A wearer only shows up two ways: in the optional
-- list you have to switch on and position yourself, or inside a cast alert from
-- the module that saw the cast -- "X tried a Swapblaster on Donut and it failed
-- because Donut is using a Neural Silencer". Please keep it that way.

-- Verified against the live 12.1.5 database (wowhead.com/spell=156779): the item
-- aura. 384129 is the craftable Mk3. Both apply the same 12-hour "Immune to some
-- annoyances" aura, which is what blocks a Swapblaster and a Leap of Faith, so
-- one name set covers both and every module reads it through Tattle.silencerNames
-- (filled here, at Initialize -- modules stay enabled or disabled independently
-- of each other, but this registration happens either way).
local SILENCER_SPELL_IDS = {
    156779,
    384129,
}

-- Refresh plumbing. The scan is a handful of aura lookups plus a UnitIsUnit per
-- group member, so the ceiling is about four tiny sweeps a second, and only
-- while something is switched on. Nothing runs per frame: refreshes come from
-- UNIT_AURA / UNIT_TARGET and this ticker, and the throttle stops an aura burst
-- in a raid from driving the sweep any faster.
local REFRESH_SECONDS = 0.5
local REFRESH_THROTTLE = 0.25

local DEFAULT_DISPLAY = {
    showList       = false,  -- the on-screen list is opt-in
    showWearers    = true,   -- ... and both sections are on when it is
    showWatchers   = false,  -- "who is targeting me" depends on client syncing
    showBackground = true,
    position = { point = "TOPRIGHT", relativePoint = "TOPRIGHT", xOffset = -16, yOffset = -180 },
}

-- A SavedVariables entry from a build that had more options is fine; one from a
-- build that had fewer must not be indexed blind. Keys that no longer exist are
-- simply ignored, so `announceGains` (removed: having the buff is not an event)
-- may still be sitting in a saved entry and does not matter.

-- ============================================================================
-- Settings
-- ============================================================================

-- The IDs the user entered in-game win; otherwise the shipped ones apply.
local function GetWatchedSpellIDs(settings)
    local stored = settings and settings.spellIDs
    if type(stored) == "table" and #stored > 0 then return stored end
    return SILENCER_SPELL_IDS
end

Silencer.GetWatchedSpellIDs = GetWatchedSpellIDs

local function copyPosition(position)
    return {
        point = position.point,
        relativePoint = position.relativePoint or position.point,
        xOffset = position.xOffset,
        yOffset = position.yOffset,
    }
end

-- Fills in whatever an older saved variable is missing. Never hands out the
-- shared DEFAULT_DISPLAY.position table: a later SavePosition would edit the
-- defaults for every session after this one.
local function MigrateDisplay(moduleSettings)
    local display = moduleSettings.display
    if type(display) ~= "table" then
        display = {}
        moduleSettings.display = display
    end

    for key, value in pairs(DEFAULT_DISPLAY) do
        if key ~= "position" and display[key] == nil then display[key] = value end
    end

    if type(display.position) ~= "table" or not display.position.point then
        display.position = copyPosition(DEFAULT_DISPLAY.position)
    end

    return display
end

-- GetSettings sits on the refresh path, which runs several times a second, so
-- it may not sweep DEFAULT_DISPLAY on every call. These are the keys the option
-- controls index directly; if all of them are present the entry is already in
-- the shape the rest of the module expects.
local function DisplayIsComplete(display)
    return type(display) == "table"
        and display.showList ~= nil
        and display.showWearers ~= nil
        and display.showWatchers ~= nil
        and display.showBackground ~= nil
        and type(display.position) == "table"
end

local function GetSettings()
    local moduleSettings = Tattle.GetModuleSettings(MODULE_ID)
    if not moduleSettings then return nil end

    -- Six comparisons on a saved table, versus a pairs sweep over the defaults.
    if not DisplayIsComplete(moduleSettings.display) then
        MigrateDisplay(moduleSettings)
    end

    return moduleSettings
end

-- ============================================================================
-- The list
-- ============================================================================

local watchFrame
local ticker
local targetEntries = {}    -- { owner = "raid1", target = "raid1target" }, rebuilt on roster change
local lastText
local lastRefresh = 0
local dragMode = false

local function DisplayNameFor(token)
    if token == "player" then return "you" end
    return Tattle.GetUnitShortName(token) or "someone"
end

-- "nobody" / "you" / "Donut and Pancakes", capitalised for the start of a line.
local function NameListPhrase(names)
    if #names == 0 then return "nobody" end
    local text = Tattle.FormatList(names)
    return (text:gsub("^%l", string_upper))
end

local function WearerNames()
    local names = {}
    for _, token in ipairs(Tattle.GroupUnitTokens()) do
        if Tattle.IsSilencerWearer(token) then names[#names + 1] = DisplayNameFor(token) end
    end
    return names
end

local function BuildText(names, watchers)
    local settings = GetSettings()
    local display = settings and settings.display or DEFAULT_DISPLAY
    local lines = {}
    if display.showWearers then
        lines[#lines + 1] = string_format("Neural Silencer: %s", NameListPhrase(names))
    end
    if display.showWatchers then
        lines[#lines + 1] = string_format("Targeting you: %s", NameListPhrase(watchers))
    end
    return table_concat(lines, "\n")
end

-- ============================================================================
-- Frame
-- ============================================================================

local function AnchorFrame(frame, display)
    local pos = display.position or DEFAULT_DISPLAY.position
    local point = pos.point or DEFAULT_DISPLAY.position.point

    frame:ClearAllPoints()
    frame:SetPoint(point, UIParent, pos.relativePoint or point, pos.xOffset or -16, pos.yOffset or -180)

    -- The text hugs the same corner as the anchor, so a right-anchored list
    -- grows leftwards instead of hanging off the edge of the screen.
    local justify = point:find("LEFT") and "LEFT" or (point:find("RIGHT") and "RIGHT" or "CENTER")
    frame.text:ClearAllPoints()
    frame.text:SetPoint(point, point)
    frame.text:SetJustifyH(justify)
    frame.text:SetJustifyV(point:find("^TOP") and "TOP" or (point:find("^BOT") and "BOTTOM" or "MIDDLE"))

    frame:SetSize(frame.text:GetStringWidth() + 12, frame.text:GetStringHeight() + 8)
end

-- Created on demand, never per-load: a player who never turns the list on never
-- pays for a frame.
local function EnsureFrame()
    if watchFrame then return watchFrame end

    local frame = CreateFrame("Frame", "TattleWatchFrame", UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(40)

    frame.text = frame:CreateFontString(nil, "OVERLAY")
    local fonts = Tattle.ScreenAlert and Tattle.ScreenAlert.FONTS
    local fontPath = (fonts and fonts[1] and fonts[1].path) or "Fonts\\FRIZQT__.TTF"
    frame.text:SetFont(fontPath, 12, "OUTLINE")
    frame.text:SetTextColor(1, 0.82, 0)

    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetPoint("TOPLEFT", frame.text, "TOPLEFT", -6, 4)
    frame.bg:SetPoint("BOTTOMRIGHT", frame.text, "BOTTOMRIGHT", 6, -4)
    frame.bg:SetColorTexture(0, 0, 0, 0.65)

    frame:SetMovable(true)
    watchFrame = frame
    lastText = nil

    return watchFrame
end

function Silencer:ApplySettings()
    local settings = GetSettings()
    if not settings then return end
    local display = settings.display

    -- With the list off there is nothing to style, but a frame left over from
    -- when it was on still has to be hidden.
    if not display.showList then
        Silencer:ApplyVisibility()
        return
    end

    if not EnsureFrame() then return end

    if display.showBackground then watchFrame.bg:Show() else watchFrame.bg:Hide() end
    AnchorFrame(watchFrame, display)
    Silencer:ApplyVisibility()
end

function Silencer:ApplyVisibility()
    if not watchFrame or dragMode then return end
    local settings = GetSettings()
    local display = settings and settings.display or DEFAULT_DISPLAY

    if not display.showList or not Tattle.IsGrouped()
        or not (TattleDB and TattleDB.enabled) then
        watchFrame:Hide()
        return
    end
    if not display.showWearers and not display.showWatchers then
        watchFrame:Hide()
        return
    end

    local text = watchFrame.text:GetText()
    if text and text ~= "" then watchFrame:Show() else watchFrame:Hide() end
end

-- Returns true when the text actually changed. The caller uses that to decide
-- whether the frame needs re-measuring: SetText and SetPoint both invalidate the
-- frame's layout, and the refresh runs up to four times a second, so resizing on
-- every tick would keep handing layout work to the UI for a list whose two lines
-- of text almost never change.
local function SetListText(text)
    if not watchFrame then return false end
    if text == lastText then return false end
    lastText = text
    watchFrame.text:SetText(text)
    return true
end

function Silencer:Refresh(force)
    local settings = GetSettings()
    if not settings then return end
    local display = settings.display

    local now = GetTime()
    if not force and (now - lastRefresh) < REFRESH_THROTTLE then return end
    lastRefresh = now

    -- The ticker runs whether or not the addon is switched on, so both the
    -- group and the master switch are checked here: a frozen list of names from
    -- before you left the group or typed /tattle off is worse than none.
    if not Tattle.IsGrouped() or not (TattleDB and TattleDB.enabled) then
        if watchFrame then watchFrame:Hide() end
        return
    end

    -- Nothing in this module announces a wearer, so the names exist only to be
    -- drawn. With the list switched off (or being dragged, where the sample text
    -- is already in place) there is no drawing to do and no reason to sweep the
    -- group's auras at all.
    if not display.showList or dragMode then
        Silencer:ApplyVisibility()
        return
    end

    local names = WearerNames()

    if not EnsureFrame() then return end

    local watchers = display.showWatchers and Tattle.WatcherNames(targetEntries) or {}
    if SetListText(BuildText(names, watchers)) then
        AnchorFrame(watchFrame, display)
    end
    Silencer:ApplyVisibility()
end

-- ============================================================================
-- Drag mode (positioned from the config panel, like the screen alert)
-- ============================================================================

local function SavePosition()
    if not watchFrame then return end
    local settings = GetSettings()
    if not settings then return end

    local point, _, relativePoint, xOffset, yOffset = watchFrame:GetPoint()
    settings.display.position = {
        point = point or "TOPRIGHT",
        relativePoint = relativePoint or point or "TOPRIGHT",
        xOffset = xOffset or -16,
        yOffset = yOffset or -180,
    }
end

-- Works even with the list switched off, so "Reposition List" can be used to
-- place it before turning it on.
function Silencer:EnableDragMode()
    if not EnsureFrame() then return end

    dragMode = true
    local frame = watchFrame
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
        AnchorFrame(frame, (GetSettings() or DEFAULT_DISPLAY).display or DEFAULT_DISPLAY)
    end)

    frame.bg:Show()
    frame.bg:SetColorTexture(0.9, 0.75, 0, 0.25)
    SetListText("Neural Silencer: Donut, Pancakes\nTargeting you: nobody")
    frame:Show()
end

function Silencer:DisableDragMode()
    dragMode = false
    if not watchFrame then return end

    watchFrame:EnableMouse(false)
    watchFrame:SetScript("OnDragStart", nil)
    watchFrame:SetScript("OnDragStop", nil)
    watchFrame.bg:SetColorTexture(0, 0, 0, 0.65)

    lastText = nil
    Silencer:Refresh(true)
    Silencer:ApplySettings()
end

-- ============================================================================
-- Refresh plumbing
-- ============================================================================

local function EnsureTicker()
    if ticker then return end
    ticker = C_Timer.NewTicker(REFRESH_SECONDS, function() Silencer:Refresh(false) end)
end

local function KillTicker()
    if not ticker then return end
    ticker:Cancel()
    ticker = nil
end

-- Called from the config panel whenever a display option changes, so the list
-- reacts without a /reload.
function Silencer:OptionsChanged()
    local settings = GetSettings()
    if settings and settings.display.showList then EnsureTicker() else KillTicker() end
    Silencer:ApplySettings()
    Silencer:Refresh(true)
end

-- ============================================================================
-- Events
-- ============================================================================

local function OnEvent(event, unitToken)
    if event == "GROUP_ROSTER_UPDATE" then
        -- Member list changed: rebuild the target token cache and redraw. A
        -- roster change is silent by design -- whoever joined already wearing one
        -- is background, not an event (see the note at the top of this file).
        targetEntries = Tattle.GroupTargetEntries()
        Silencer:Refresh(true)
        return
    end

    -- Your own aura counts for the wearer list; your own target does not count
    -- for the watcher list (WatcherNames only ever matches other members).
    if unitToken ~= "player" and not Tattle.IsGroupMemberToken(unitToken) then return end

    local settings = GetSettings()
    if not settings then return end
    local display = settings.display

    -- UNIT_AURA is noisy in a raid, and with the announcements gone this module
    -- exists only to paint the list: no list, nothing to do here.
    if not display.showList then return end
    if event == "UNIT_TARGET" and not display.showWatchers then return end

    Silencer:Refresh(false)
end

-- ============================================================================
-- Config tab extras
-- ============================================================================

-- Appended after the shared alert controls by Config's module tab builder.
function Silencer.BuildOptions(container, moduleId, moduleSettings, y)
    local display = moduleSettings.display
    local Config = Tattle.Config

    local header = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", 0, y)
    header:SetText("On-screen watch list")
    y = y - 24

    Config.AddCheckbox(container, y, "Show the watch list on screen",
        function() return display.showList end,
        function(value)
            display.showList = value
            Silencer:OptionsChanged()
        end)
    y = y - 26

    Config.AddCheckbox(container, y, "List group members wearing a Neural Silencer",
        function() return display.showWearers end,
        function(value)
            display.showWearers = value
            Silencer:OptionsChanged()
        end)
    y = y - 26

    Config.AddCheckbox(container, y, "List group members targeting you (needs group target syncing)",
        function() return display.showWatchers end,
        function(value)
            display.showWatchers = value
            Silencer:OptionsChanged()
        end)
    y = y - 26

    local note = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", 0, y)
    note:SetWidth(360)
    note:SetTextColor(0.75, 0.75, 0.75)
    note:SetText("Wearing a Neural Silencer is never announced on its own - joining a raid " ..
        "should not fill chat with a roll call. Wearers appear here, and in the alert " ..
        "when somebody tries a Swapblaster, Life Grip or Rescue on one.")
    y = y - 42

    local isDragging = false
    local positionBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    positionBtn:SetSize(170, 24)
    positionBtn:SetPoint("TOPLEFT", 0, y)
    positionBtn:SetText("Reposition List")
    positionBtn:SetScript("OnClick", function(self)
        isDragging = not isDragging
        if isDragging then
            Silencer:EnableDragMode()
            self:SetText("Done Repositioning")
        else
            Silencer:DisableDragMode()
            self:SetText("Reposition List")
        end
    end)
    y = y - 30

    local help = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 0, y)
    help:SetPoint("TOPRIGHT", 0, y)
    help:SetJustifyH("LEFT")
    help:SetSpacing(2)
    help:SetText(
        "The list scans the group about twice a second while it is visible - nothing runs per frame. " ..
        "\"Targeting you\" can only work if your client is told other players' targets; /tattle probe " ..
        "prints what it can read. A Neural Silencer blocks Swapblaster and Life Grip, so a protected " ..
        "caster is the one group member who cannot be moved back."
    )
    return y - 60
end

-- ============================================================================
-- Init & Registration
-- ============================================================================

local function Initialize()
    Tattle.DebugPrint("Neural Silencer module initialized")

    local settings = GetSettings()

    for _, id in ipairs(GetWatchedSpellIDs(settings)) do
        local info = C_Spell.GetSpellInfo(id)
        if info and info.name then
            Tattle.silencerNames[info.name] = true
            Tattle.DebugPrint("  Neural Silencer:", info.name, "(" .. id .. ")")
        else
            Tattle.DebugPrint("  WARNING: Neural Silencer spell ID", id, "not found")
        end
    end

    targetEntries = Tattle.GroupTargetEntries()

    if settings and settings.display.showList then
        Silencer:ApplySettings()
        EnsureTicker()
        Silencer:Refresh(true)
    end
end

Tattle:RegisterModule(MODULE_ID, {
    name        = MODULE_NAME,
    tabName     = "Silencers",     -- short: five tabs have to fit one row
    description = MODULE_DESCRIPTION,
    initialize  = Initialize,
    onEvent     = OnEvent,
    spellIDs    = SILENCER_SPELL_IDS,
    extraContent = Silencer.BuildOptions,
    -- Nothing here is a cast, so a "whole group / only me" filter would be a
    -- control this module does not honour.
    noScope = true,
    events      = {
        "UNIT_AURA",
        "UNIT_TARGET",
        "GROUP_ROSTER_UPDATE",
    },
})
