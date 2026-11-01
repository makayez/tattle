-- Core.lua - Main addon logic
-- EventListener.lua MUST be listed before this in the TOC.

local ADDON_NAME = ...
Snitch = Snitch or {}

Snitch.VERSION = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "Unknown"

-- ============================================================================
-- Localize Globals
-- ============================================================================

local pairs = pairs
local ipairs = ipairs
local print = print
local type = type
local table_concat = table.concat
local math_min = math.min
local string_format = string.format

local IsInRaid = IsInRaid
local UnitInRaid = UnitInRaid
local UnitInParty = UnitInParty
local UnitIsUnit = UnitIsUnit
local UnitName = UnitName
local GetNumGroupMembers = GetNumGroupMembers
local SendChatMessage = SendChatMessage
local PlaySound = PlaySound
local C_Timer = C_Timer
local C_UnitAuras = C_UnitAuras
local GetTime = GetTime

-- ============================================================================
-- Module Registry
-- ============================================================================

Snitch.modules = {}
-- Registration order, so tabs (and anything else that wants a stable order)
-- do not depend on pairs() order.
Snitch.moduleOrder = {}
Snitch._pendingModules = Snitch._pendingModules or {}

function Snitch:RegisterModule(moduleId, config)
    if self._modulesReady then
        self:_RegisterModuleNow(moduleId, config)
    else
        table.insert(self._pendingModules, { id = moduleId, config = config })
    end
end

function Snitch:_RegisterModuleNow(moduleId, config)
    if self.modules[moduleId] then
        print(string_format("Snitch: Module %s already registered", moduleId))
        return
    end
    self.modules[moduleId] = {
        id          = moduleId,
        name        = config.name,
        description = config.description,
        onEvent     = config.onEvent,
        initialize  = config.initialize,
        events      = config.events or {},
        tabName     = config.tabName or config.name,
        buildContent = config.buildContent,
        defaultSpellIDs = config.spellIDs,
    }
    table.insert(self.moduleOrder, moduleId)

    -- RegisterEvent here so a module's declared `events` actually reach it.
    -- EventListener.lua only hard-registers the built-in cast events.
    if self.eventFrame then
        for _, ev in ipairs(config.events or {}) do
            self.eventFrame:RegisterEvent(ev)
        end
    end
end

-- ============================================================================
-- Saved Variables & Settings
-- ============================================================================

SnitchDB = SnitchDB or {}

local function InitializeSettings()
    if SnitchDB.enabled == nil then SnitchDB.enabled = true end
    if SnitchDB.debug   == nil then SnitchDB.debug   = false end
    SnitchDB.modules = SnitchDB.modules or {}
end

local function InitializeModuleSettings(moduleId)
    local defaults = {
        enabled = true,
        -- "group" = report any group member's cast; "self" = only casts involving you
        scope   = "group",
        alerts  = {
            console   = true,
            chat      = false,
            chatType  = "PRIVATE",  -- PRIVATE | SAY | YELL | PARTY | RAID
            audioFile = SOUNDKIT.RAID_WARNING or 8959,
            audio     = false,
            screen    = false,
        },
    }

    local stored = SnitchDB.modules[moduleId]
    if not stored then
        SnitchDB.modules[moduleId] = defaults
        return
    end

    -- Migrate pre-existing entries without clobbering the user's choices.
    if stored.enabled == nil then stored.enabled = true end
    if stored.scope == nil then stored.scope = defaults.scope end
    if not stored.alerts then
        stored.alerts = defaults.alerts
        return
    end

    local a = stored.alerts
    if a.console   == nil then a.console   = true end
    if a.chat      == nil then a.chat      = false end
    if a.chatType  == nil then a.chatType  = defaults.alerts.chatType end
    if a.audioFile == nil then a.audioFile = defaults.alerts.audioFile end
    if a.audio     == nil then a.audio     = false end
    if a.screen    == nil then a.screen    = false end
end

-- ============================================================================
-- Utility
-- ============================================================================

local function DebugPrint(...)
    if SnitchDB and SnitchDB.debug then
        print("|cff00ff00[Snitch Debug]|r", ...)
    end
end
Snitch.DebugPrint = DebugPrint

-- Group guard. These abilities can only be used on someone you are grouped
-- with, so party and raid both matter -- a raid-only gate is silent for the
-- 2-5s / open-world griefing this addon exists for.
-- GetNumGroupMembers() covers party and raid without leaning on IsInGroup's
-- ever-shifting argument signature.
local function IsGrouped()
    return IsInRaid() or GetNumGroupMembers() > 0
end
Snitch.IsGrouped = IsGrouped
Snitch.IsInRaidGroup = IsGrouped  -- back-compat alias

-- Returns short name (no realm) for a unit token.
local function GetUnitShortName(unitToken)
    if not unitToken then return nil end
    local fullName = UnitName(unitToken)
    if not fullName then return nil end
    return fullName:match("^([^-]+)") or fullName
end
Snitch.GetUnitShortName = GetUnitShortName

-- Returns true if the unit token is in your party or raid.
local function IsGroupMemberToken(unitToken)
    if not unitToken then return false end
    return (UnitInRaid(unitToken) or UnitInParty(unitToken)) and true or false
end
Snitch.IsGroupMemberToken = IsGroupMemberToken
Snitch.IsRaidMemberToken = IsGroupMemberToken  -- back-compat alias

-- Every unit token that names a member of your group, you included.
-- GetNumGroupMembers() counts you as well, and a party addresses you as
-- "player", not "party5", so the party branch is capped at four.
local function GroupUnitTokens()
    local tokens = {}
    local count = GetNumGroupMembers()
    if IsInRaid() then
        for i = 1, count do tokens[#tokens + 1] = "raid" .. i end
    else
        for i = 1, math_min(count, 4) do tokens[#tokens + 1] = "party" .. i end
    end
    tokens[#tokens + 1] = "player"
    return tokens
end
Snitch.GroupUnitTokens = GroupUnitTokens

-- True when unitToken carries an aura whose spell name is in nameSet.
-- 12.0.0 hid other players' auras; 12.1.0 relaxed that again out of combat, so
-- this is the route left for naming a cast's destination now that the combat
-- log is gone. pcall because a restricted context can refuse the read.
local function UnitHasAnyAura(unitToken, nameSet, auraFilter)
    if not unitToken or not nameSet then return false end
    for spellName in pairs(nameSet) do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, unitToken, spellName, auraFilter or "HELPFUL")
        if ok and aura then return true end
    end
    return false
end
Snitch.UnitHasAnyAura = UnitHasAnyAura

-- Which group members currently carry one of nameSet's auras, as unit tokens.
-- excludeToken drops the caster, whose own aura would otherwise look like a
-- target (Rescue marks both the Evoker and the passenger with the same name).
local function AuraCarriers(nameSet, auraFilter, excludeToken)
    local carriers = {}
    for _, token in ipairs(GroupUnitTokens()) do
        if token ~= excludeToken and UnitHasAnyAura(token, nameSet, auraFilter) then
            carriers[#carriers + 1] = token
        end
    end
    return carriers
end
Snitch.AuraCarriers = AuraCarriers

local function AuraCarrierNames(nameSet, auraFilter, excludeToken)
    local names = {}
    for _, token in ipairs(AuraCarriers(nameSet, auraFilter, excludeToken)) do
        local name = (token == "player") and "you" or GetUnitShortName(token)
        names[#names + 1] = name or "someone"
    end
    return names
end
Snitch.AuraCarrierNames = AuraCarrierNames

local function FormatList(t)
    if #t == 0 then return nil end
    if #t == 1 then return t[1] end
    if #t == 2 then return t[1] .. " and " .. t[2] end
    local parts = {}
    for i = 1, #t - 1 do parts[i] = t[i] end
    return table_concat(parts, ", ") .. " and " .. t[#t]
end
Snitch.FormatList = FormatList

-- "you" / "Donut" / "Donut and Pancakes", for the "used X on Y" alerts.
local function TargetPhrase(carrierTokens)
    local names = {}
    for i, token in ipairs(carrierTokens) do
        names[i] = (token == "player") and "you" or (GetUnitShortName(token) or "someone")
    end
    return FormatList(names) or "someone"
end
Snitch.TargetPhrase = TargetPhrase

-- Settings for a module (enabled, scope, alerts). nil-safe.
function Snitch.GetModuleSettings(moduleId)
    return (SnitchDB and SnitchDB.modules and SnitchDB.modules[moduleId]) or nil
end

-- The spell IDs a module shipped with, so the config can offer "Reset to
-- Defaults" without hardcoding IDs. Returns a fresh copy.
function Snitch.GetModuleDefaults(moduleId)
    local module = Snitch.modules[moduleId]
    if not module then return nil end

    local spellIDs = {}
    for i, id in ipairs(module.defaultSpellIDs or {}) do
        spellIDs[i] = id
    end
    return { spellIDs = spellIDs }
end

-- Scope gate. Returns false only when we KNOW the cast does not involve you.
--
-- "self" means: you cast it, or it landed on you. Note that the caster being
-- someone else is NOT enough to drop the alert -- a Swapblaster or Life Grip
-- aimed at you is exactly the event this addon exists to warn about.
--
-- IMPORTANT: UNIT_SPELLCAST_* events name the caster but never the destination
-- (destination lived only in COMBAT_LOG_EVENT_UNFILTERED, removed in 12.0), and
-- Swapblaster's cast applies no aura at all. An empty targetTokens list is read
-- as "could not resolve", not as "provably not you", so a failed aura read can
-- never silently drop a warning.
function Snitch.ShouldReport(moduleId, casterToken, targetTokens)
    local settings = Snitch.GetModuleSettings(moduleId)
    if not settings or settings.scope ~= "self" then return true end

    if casterToken then
        local ok, isMe = pcall(UnitIsUnit, casterToken, "player")
        if ok and isMe then return true end
    end

    if not targetTokens or #targetTokens == 0 then return nil end  -- unknown: still report

    for _, token in ipairs(targetTokens) do
        local ok, isMe = pcall(UnitIsUnit, token, "player")
        if ok and isMe then return true end
    end
    return false
end

-- ============================================================================
-- Alert System
-- ============================================================================

local function SendAlert(message, moduleId)
    if not SnitchDB or not SnitchDB.enabled then return end
    if not IsGrouped() then return end

    local moduleSettings = SnitchDB.modules[moduleId]
    if not moduleSettings or not moduleSettings.enabled then return end

    local alerts = moduleSettings.alerts
    if not alerts then return end

    DebugPrint("Alert:", message)

    if alerts.console then
        print(string_format("|cffff6600[Snitch]|r %s", message))
    end

    -- chatType "PRIVATE" means console only: the console block above already
    -- printed it, so there is nothing to send.
    local channel = alerts.chatType or "PRIVATE"
    if alerts.chat and channel ~= "PRIVATE" then
        C_Timer.After(0.1, function()
            local ok, err = pcall(SendChatMessage, message, channel)
            if not ok then DebugPrint("Chat send failed:", err) end
        end)
    end

    if alerts.audio and alerts.audioFile then
        local ok, err = pcall(PlaySound, alerts.audioFile)
        if not ok then DebugPrint("Sound failed:", err) end
    end

    if alerts.screen and Snitch.ScreenAlert then
        local ok, err = pcall(Snitch.ScreenAlert.Show, Snitch.ScreenAlert, message)
        if not ok then DebugPrint("Screen alert failed:", err) end
    end
end
Snitch.SendAlert = SendAlert

-- ============================================================================
-- OnEvent
-- ============================================================================

local moduleEvents = {}
local addonReady   = false

Snitch.eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= ADDON_NAME then return end

        InitializeSettings()

        Snitch._modulesReady = true
        for _, entry in ipairs(Snitch._pendingModules) do
            Snitch:_RegisterModuleNow(entry.id, entry.config)
        end
        Snitch._pendingModules = {}

        for moduleId, module in pairs(Snitch.modules) do
            InitializeModuleSettings(moduleId)
            for _, ev in ipairs(module.events) do
                moduleEvents[ev] = moduleEvents[ev] or {}
                table.insert(moduleEvents[ev], moduleId)
            end
            if module.initialize then module.initialize() end
        end

        if Snitch.ScreenAlert then Snitch.ScreenAlert:Initialize() end
        if Snitch.Config then Snitch.Config:BuildModuleTabs() end
        if Snitch.Config then Snitch.Config:RegisterInterfaceOptions() end

        addonReady = true
        print("Snitch v" .. Snitch.VERSION .. " loaded. Type /snitch to configure, or /snitch probe to see what your client exposes.")
        return
    end

    if not addonReady then return end
    if not SnitchDB or not SnitchDB.enabled then return end
    if not IsGrouped() then return end  -- grouped only, bail early

    local listeners = moduleEvents[event]
    if not listeners then return end

    local moduleSettings = SnitchDB.modules
    for _, moduleId in ipairs(listeners) do
        local module = Snitch.modules[moduleId]
        if module and module.onEvent then
            local settings = moduleSettings[moduleId]
            if settings and settings.enabled then
                local ok, err = pcall(module.onEvent, event, ...)
                if not ok then
                    DebugPrint(string_format("Error in module %s: %s", moduleId, err))
                end
            end
        end
    end
end)

-- ============================================================================
-- Event Probe (/snitch probe)
-- ============================================================================

-- Dumps what the cast events actually expose in this build, so spell IDs and --
-- crucially whether a destination is available at all -- can be verified
-- instead of guessed. Secret-value safe: nothing is compared or printed raw;
-- spell names come from C_Spell.GetSpellInfo, which accepts secret values.
function Snitch.ToggleProbe()
    if Snitch._probeFrame then
        Snitch._probeFrame:SetScript("OnEvent", nil)
        Snitch._probeFrame = nil
        print("Snitch probe OFF.")
        return
    end

    -- Target attribution depends on reading another player's aura. Resolve the
    -- aura names from the verified spell IDs (rather than typing English names)
    -- so this check is correct whatever the client language is.
    local probeAuras = {}
    local probeAuraNames = {}
    for _, id in ipairs({ 73325, 370666, 156779 }) do
        local info = C_Spell.GetSpellInfo(id)
        if info and info.name and not probeAuras[info.name] then
            probeAuras[info.name] = true
            probeAuraNames[#probeAuraNames + 1] = info.name
        end
    end
    table.sort(probeAuraNames)

    local f = CreateFrame("Frame")
    f:RegisterEvent("UNIT_SPELLCAST_START")
    f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    f:RegisterEvent("UNIT_SPELLCAST_FAILED")
    f:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    f:RegisterEvent("UNIT_SPELLCAST_SENT")

    f:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5, arg6)
        -- Resolve the spell name safely (works even if spellID is a secret).
        local spellArg = (event == "UNIT_SPELLCAST_SENT") and (arg5 or arg3) or arg3
        local info = spellArg and C_Spell.GetSpellInfo(spellArg)
        local spellName = info and info.name or "?"

        -- Is the caster argument a plain token we can name, or a secret?
        local okName, casterName = pcall(UnitName, arg1)
        local casterText = (okName and type(casterName) == "string" and casterName) or "secret/unnameable"
        local okMe, isMe = pcall(UnitIsUnit, arg1, "player")
        local casterIsMe = (okMe and type(isMe) == "boolean") and (isMe and "YES" or "no") or "?"

        -- Hunt for a usable destination argument on UNIT_SPELLCAST_SENT.
        local destText, destIsMe = "none exposed", "n/a"
        if event == "UNIT_SPELLCAST_SENT" then
            for _, candidate in ipairs({ arg4, arg5, arg6 }) do
                if candidate ~= nil and candidate ~= spellArg and candidate ~= arg1 then
                    local okDn, dn = pcall(UnitName, candidate)
                    local okDm, dm = pcall(UnitIsUnit, candidate, "player")
                    if okDm and type(dm) == "boolean" then
                        destIsMe = dm and "YES" or "no"
                        destText = (okDn and type(dn) == "string" and dn) or "secret (usable only via UnitIsUnit)"
                        break
                    end
                end
            end
        end

        print(string_format("|cffff6600[Snitch Probe]|r %s | spell: %s | caster: %s (isMe=%s) | dest: %s (isMe=%s)",
            event, spellName, casterText, casterIsMe, destText, destIsMe))

        -- Second question: can this build still see a group member's aura at all?
        -- "none visible" here means the "on Pancakes" half of an alert is impossible.
        for _, auraName in ipairs(probeAuraNames) do
            local visible = Snitch.AuraCarrierNames({ [auraName] = true }, "ALL")
            print(string_format("|cffff6600[Snitch Probe]|r   aura %-18s -> %s",
                auraName, visible[1] and table_concat(visible, ", ") or "none visible"))
        end
    end)

    Snitch._probeFrame = f
    print("Snitch probe ON. Cast SwapBlaster / Life Grip / Rescue -- on yourself AND on a friend -- and watch chat.")
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

SLASH_SNITCH1 = "/snitch"

SlashCmdList["SNITCH"] = function(msg)
    msg = (msg or ""):lower():trim()

    if msg == "" then
        if Snitch.Config then Snitch.Config:Toggle() end

    elseif msg == "version" then
        print("Snitch version " .. Snitch.VERSION)

    elseif msg == "on" then
        SnitchDB.enabled = true
        print("Snitch enabled.")

    elseif msg == "off" then
        SnitchDB.enabled = false
        print("Snitch disabled.")

    elseif msg == "debug" then
        SnitchDB.debug = not SnitchDB.debug
        print("Snitch debug " .. (SnitchDB.debug and "ON" or "OFF"))

    elseif msg == "probe" then
        Snitch.ToggleProbe()

    elseif msg == "status" then
        print("Snitch v" .. Snitch.VERSION)
        print("  Enabled:", SnitchDB.enabled and "ON" or "OFF")
        print("  Grouped:", IsGrouped() and "YES" or "NO")
        print("  Debug:",   SnitchDB.debug and "ON" or "OFF")
        print("Modules:")
        -- moduleOrder, not pairs(): a string-keyed table has no defined order, so
        -- pairs() would reshuffle this list (and the config tabs) between runs.
        for _, moduleId in ipairs(Snitch.moduleOrder) do
            local module = Snitch.modules[moduleId]
            local s = module and SnitchDB.modules[moduleId]
            if s then
                local channel = (s.alerts and s.alerts.chatType) or "PRIVATE"
                print("  [" .. module.name .. "]",
                    s.enabled and "ON" or "OFF",
                    "| scope:", s.scope or "group",
                    "| chat:", channel)
            end
        end

    else
        print("Snitch: /snitch [version|on|off|debug|probe|status]")
    end
end
