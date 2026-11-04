-- Core.lua - Main addon logic
-- EventListener.lua MUST be listed before this in the TOC.

local ADDON_NAME = ...
Tattle = Tattle or {}

Tattle.VERSION = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "Unknown"

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
local UnitExists = UnitExists
local UnitAffectingCombat = UnitAffectingCombat
local GetNumGroupMembers = GetNumGroupMembers
local SendChatMessage = SendChatMessage
local PlaySound = PlaySound
local C_Timer = C_Timer
local C_UnitAuras = C_UnitAuras
local GetTime = GetTime

-- ============================================================================
-- Module Registry
-- ============================================================================

Tattle.modules = {}
-- Registration order, so tabs (and anything else that wants a stable order)
-- do not depend on pairs() order.
Tattle.moduleOrder = {}
Tattle._pendingModules = Tattle._pendingModules or {}

function Tattle:RegisterModule(moduleId, config)
    if self._modulesReady then
        self:_RegisterModuleNow(moduleId, config)
    else
        table.insert(self._pendingModules, { id = moduleId, config = config })
    end
end

function Tattle:_RegisterModuleNow(moduleId, config)
    if self.modules[moduleId] then
        print(string_format("Tattle: Module %s already registered", moduleId))
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
        extraContent = config.extraContent,
        -- Set by modules that do not filter casts, so their tab skips the
        -- "Monitor: whole group / only me" control they would ignore.
        noScope = config.noScope,
        defaultSpellIDs = config.spellIDs,
        -- True for modules whose spell cannot exist in combat at all (the
        -- Swapblaster refuses to fire while fighting). The dispatcher drops
        -- their events while the caster is in combat instead of letting each
        -- module pay for the check.
        outOfCombatOnly = config.outOfCombatOnly,
        -- Opts a module out of the dispatcher's "only your group's players cast
        -- this" filter. Nothing in Tattle needs it today: the Swapblaster is a
        -- toy and Life Grip, Leap of Faith and Rescue are player spells, so a
        -- pet, a minion or an NPC cannot be the caster. A module watching
        -- something an NPC *can* cast would set this.
        allCasters = config.allCasters,
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

TattleDB = TattleDB or {}

local function InitializeSettings()
    if TattleDB.enabled == nil then TattleDB.enabled = true end
    if TattleDB.debug   == nil then TattleDB.debug   = false end
    TattleDB.modules = TattleDB.modules or {}
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

    local stored = TattleDB.modules[moduleId]
    if not stored then
        TattleDB.modules[moduleId] = defaults
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
    if TattleDB and TattleDB.debug then
        print("|cff00ff00[Tattle Debug]|r", ...)
    end
end
Tattle.DebugPrint = DebugPrint

-- Group guard. These abilities can only be used on someone you are grouped
-- with, so party and raid both matter -- a raid-only gate is silent for the
-- 2-5s / open-world griefing this addon exists for.
-- GetNumGroupMembers() covers party and raid without leaning on IsInGroup's
-- ever-shifting argument signature.
local function IsGrouped()
    return IsInRaid() or GetNumGroupMembers() > 0
end
Tattle.IsGrouped = IsGrouped
Tattle.IsInRaidGroup = IsGrouped  -- back-compat alias

-- Returns short name (no realm) for a unit token.
local function GetUnitShortName(unitToken)
    if not unitToken then return nil end
    local fullName = UnitName(unitToken)
    if not fullName then return nil end
    return fullName:match("^([^-]+)") or fullName
end
Tattle.GetUnitShortName = GetUnitShortName

-- Returns true if the unit token is in your party or raid.
local function IsGroupMemberToken(unitToken)
    if not unitToken then return false end

    -- Ask through the API rather than pattern-matching the token: in restricted
    -- content a cast event's caster argument may be a secret value, which these
    -- queries accept and a string comparison would not. Guarded, because the
    -- dispatcher now calls this for every cast event and an error here would
    -- abort the whole handler rather than just one module.
    local ok, inRaid = pcall(UnitInRaid, unitToken)
    if ok and inRaid then return true end
    local ok2, inParty = pcall(UnitInParty, unitToken)
    if ok2 and inParty then return true end

    -- And you. The numbered tokens exclude yourself -- there is no "party5" and
    -- no "raidN" that means you -- so membership is not complete without this,
    -- and without it your own Swapblaster or Life Grip is filtered out before any
    -- module ever sees it. UnitIsUnit is the secret-safe way to ask.
    local ok3, isMe = pcall(UnitIsUnit, unitToken, "player")
    return (ok3 and isMe) and true or false
end
Tattle.IsGroupMemberToken = IsGroupMemberToken
Tattle.IsRaidMemberToken = IsGroupMemberToken  -- back-compat alias

-- ============================================================================
-- Cached Group Snapshots
-- ============================================================================
--
-- Aura scans and the watch list both walk the whole group, and either can run
-- several times a second. Building the token list costs a fresh table plus a
-- fresh "raid"..i string per member, so rebuilding it on every sweep is pure
-- garbage. Both lists are built once and dropped on GROUP_ROSTER_UPDATE, which
-- is the only thing that changes them. Callers must treat the result as
-- read-only -- copy it first if you intend to sort or shuffle it.

local cachedTokens, cachedTargetEntries

local function InvalidateGroupCaches()
    cachedTokens, cachedTargetEntries = nil, nil
end
Tattle.InvalidateGroupCaches = InvalidateGroupCaches

-- Every unit token that names a member of your group, you included.
-- GetNumGroupMembers() counts you as well, and a party addresses you as
-- "player", not "party5", so the party branch is capped at four.
local function GroupUnitTokens()
    if cachedTokens then return cachedTokens end

    local tokens = {}
    local count = GetNumGroupMembers()
    if IsInRaid() then
        for i = 1, count do tokens[#tokens + 1] = "raid" .. i end
    else
        for i = 1, math_min(count, 4) do tokens[#tokens + 1] = "party" .. i end
    end
    tokens[#tokens + 1] = "player"

    cachedTokens = tokens
    return tokens
end
Tattle.GroupUnitTokens = GroupUnitTokens

-- { owner = "raid1", target = "raid1target" } for every group member (you are
-- not included: nobody needs to watch their own target list).
--
-- Whether another player's target is synced to your client at all is a patch
-- and context question -- `<member>target` is the same family of group data the
-- raid frames read, but it is not guaranteed everywhere. Every caller therefore
-- treats "no target" as unproven rather than as proof that nobody is looking.
-- `/tattle probe` prints the resolved target names so this can be checked in game.
local function GroupTargetEntries()
    if cachedTargetEntries then return cachedTargetEntries end

    local entries = {}
    local count = GetNumGroupMembers()
    if IsInRaid() then
        for i = 1, count do
            local owner = "raid" .. i
            entries[#entries + 1] = { owner = owner, target = owner .. "target" }
        end
    else
        for i = 1, math_min(count, 4) do
            local owner = "party" .. i
            entries[#entries + 1] = { owner = owner, target = owner .. "target" }
        end
    end

    cachedTargetEntries = entries
    return entries
end
Tattle.GroupTargetEntries = GroupTargetEntries

-- Group members whose current target is you, by short name. Empty means "none
-- that we can read", not "nobody": see GroupTargetEntries.
local function WatcherNames(entries)
    local names = {}
    for _, entry in ipairs(entries or GroupTargetEntries()) do
        local ok, isMe = pcall(UnitIsUnit, entry.target, "player")
        if ok and isMe then
            names[#names + 1] = GetUnitShortName(entry.owner) or "someone"
        end
    end
    return names
end
Tattle.WatcherNames = WatcherNames

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
Tattle.UnitHasAnyAura = UnitHasAnyAura

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
Tattle.AuraCarriers = AuraCarriers

local function AuraCarrierNames(nameSet, auraFilter, excludeToken)
    local names = {}
    for _, token in ipairs(AuraCarriers(nameSet, auraFilter, excludeToken)) do
        local name = (token == "player") and "you" or GetUnitShortName(token)
        names[#names + 1] = name or "someone"
    end
    return names
end
Tattle.AuraCarrierNames = AuraCarrierNames

local function FormatList(t)
    if #t == 0 then return nil end
    if #t == 1 then return t[1] end
    if #t == 2 then return t[1] .. " and " .. t[2] end
    local parts = {}
    for i = 1, #t - 1 do parts[i] = t[i] end
    return table_concat(parts, ", ") .. " and " .. t[#t]
end
Tattle.FormatList = FormatList

-- "you" / "Donut" / "Donut and Pancakes", for the "used X on Y" alerts.
local function TargetPhrase(carrierTokens)
    local names = {}
    for i, token in ipairs(carrierTokens) do
        names[i] = (token == "player") and "you" or (GetUnitShortName(token) or "someone")
    end
    return FormatList(names) or "someone"
end
Tattle.TargetPhrase = TargetPhrase

-- ============================================================================
-- Neural Silencer Support (shared by every module)
-- ============================================================================

-- "Neural Silencer" (item aura 156779, craftable Mk3 384129) is a 12-hour
-- "Immune to some annoyances" aura: it is what makes a Swapblaster or a Life
-- Grip come off the target without taking them with it. Modules need two
-- questions answered about it, so the lookup lives here rather than in the
-- module that happens to own the display.
--
-- Modules/Silencer.lua fills this name set at Initialize(). It is created here
-- because Core loads before any module and these helpers are used by all of
-- them. An empty set means "we know nothing", and every helper below reads that
-- as "say nothing about silencers" rather than as "nobody is protected".
Tattle.silencerNames = Tattle.silencerNames or {}

local function KnowsSilencers()
    return next(Tattle.silencerNames) ~= nil
end

local function IsSilencerWearer(unitToken)
    if not unitToken or not KnowsSilencers() then return false end
    return UnitHasAnyAura(unitToken, Tattle.silencerNames, "HELPFUL")
end
Tattle.IsSilencerWearer = IsSilencerWearer

local function SilencerWearerNames(excludeToken)
    if not KnowsSilencers() then return {} end
    return AuraCarrierNames(Tattle.silencerNames, "HELPFUL", excludeToken)
end
Tattle.SilencerWearerNames = SilencerWearerNames

-- " (Neural Silencer worn by Donut)" -- "" when the group has none. A statement
-- of fact rather than an accusation, which is what a failed cast deserves: the
-- spell could have failed for any number of reasons, but it is still worth
-- knowing somebody in here is immune to it.
local function SilencerNote(excludeToken)
    local wearers = SilencerWearerNames(excludeToken)
    if #wearers == 0 then return "" end
    return string_format(" (Neural Silencer worn by %s)", FormatList(wearers))
end
Tattle.SilencerNote = SilencerNote

-- "Donut is" / "you are" / "Donut and Pancakes are".
local function SilencerSubject(names)
    if #names == 0 then return nil end
    if #names > 1 then return FormatList(names) .. " are" end
    if names[1] == "you" then return "you are" end
    return names[1] .. " is"
end

-- "Pancakes attempted a Life Grip on Donut, but it failed because Donut is
-- using a Neural Silencer", or nil when nothing about this cast points at a
-- silencer (so callers keep their normal wording).
--
-- targetTokens are the victims we positively identified from their own aura.
-- When the grab was blocked no victim aura lands at all, so there is nothing to
-- identify -- in that case the candidates are exactly the group's protected
-- members, because a protected player is the only kind of player one of these
-- spells bounces off. Naming one of them is safe when there is only one; with
-- several the alert says "a protected group member" rather than guessing.
local function BlockedBySilencer(casterName, action, targetTokens, excludeToken)
    if not casterName or not KnowsSilencers() then return nil end

    local protectedNames
    if targetTokens then
        protectedNames = {}
        for _, token in ipairs(targetTokens) do
            if IsSilencerWearer(token) then
                protectedNames[#protectedNames + 1] =
                    (token == "player") and "you" or (GetUnitShortName(token) or "someone")
            end
        end
    end

    if protectedNames and #protectedNames > 0 then
        return string_format("%s attempted a %s on %s, but it failed because %s using a Neural Silencer",
            casterName, action, FormatList(protectedNames), SilencerSubject(protectedNames))
    end

    local candidates = SilencerWearerNames(excludeToken)
    if #candidates == 0 then return nil end
    if #candidates > 1 then
        return string_format("%s attempted a %s on a protected group member, but it failed because %s using a Neural Silencer",
            casterName, action, SilencerSubject(candidates))
    end

    return string_format("%s attempted a %s on %s, but it failed because %s using a Neural Silencer",
        casterName, action, FormatList(candidates), SilencerSubject(candidates))
end
Tattle.BlockedBySilencer = BlockedBySilencer

-- Firing a Swapblaster is an out of combat act, and a caster who is themselves
-- wearing a Neural Silencer cannot be answered in kind. Worth naming.
local function SilencerCheatClause(casterToken, casterName)
    if not IsSilencerWearer(casterToken) then return nil end
    local who = (casterToken == "player") and "you are" or ((casterName or "they") .. " is")
    return string_format(", but %s using a Neural Silencer - that's not fair!", who)
end
Tattle.SilencerCheatClause = SilencerCheatClause

-- ============================================================================
-- Combat
-- ============================================================================

-- Combat state of the unit a cast event names. pcall because a restricted
-- context can refuse the read, and because the unit argument itself may not be
-- a plain token; "not known" reads as "not in combat" so the gate can only ever
-- skip work, never swallow a warning.
local function UnitInCombat(unitToken)
    if not unitToken or not UnitAffectingCombat then return false end
    local ok, inCombat = pcall(UnitAffectingCombat, unitToken)
    return (ok and inCombat) and true or false
end
Tattle.UnitInCombat = UnitInCombat

-- Settings for a module (enabled, scope, alerts). nil-safe.
function Tattle.GetModuleSettings(moduleId)
    return (TattleDB and TattleDB.modules and TattleDB.modules[moduleId]) or nil
end

-- The spell IDs a module shipped with, so the config can offer "Reset to
-- Defaults" without hardcoding IDs. Returns a fresh copy.
function Tattle.GetModuleDefaults(moduleId)
    local module = Tattle.modules[moduleId]
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
function Tattle.ShouldReport(moduleId, casterToken, targetTokens)
    local settings = Tattle.GetModuleSettings(moduleId)
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
-- Spell Name Resolution
-- ============================================================================
--
-- Cast events are the one genuinely noisy thing this addon listens to: during a
-- fight the client reports every raid member's every cast, plus their pets and
-- minions. Three modules each used to answer that by calling
-- C_Spell.GetSpellInfo on the spell ID, and GetSpellInfo hands back a fresh
-- table every time -- so most of the addon's steady-state work was burning API
-- calls and allocating garbage on casts nobody was watching.
--
-- The core now resolves the name once per event, using the allocation-free
-- C_Spell.GetSpellName where the client has it, and drops the event outright
-- unless a module registered that name.

local watchedSpellNames = {}   -- spell name -> true

-- Called from a module's Initialize with the name set it built from its own
-- spell IDs. This is only a gate on *whether* to dispatch: each module still
-- decides which of its own spells it is looking at.
local function WatchSpellNames(nameSet)
    for name in pairs(nameSet or {}) do
        if type(name) == "string" then watchedSpellNames[name] = true end
    end
end
Tattle.WatchSpellNames = WatchSpellNames
Tattle.WatchedSpellNames = watchedSpellNames   -- read-only; inspect with care

local function ResolveSpellName(spellID)
    if spellID == nil then return nil end

    -- A plain string with no table to allocate; GetSpellInfo is the fallback for
    -- a client without it. Both accept a secret spell ID and hand back a plain
    -- name, which is the only value we ever compare or store.
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        if ok and info and type(info.name) == "string" and info.name ~= "" then
            return info.name
        end
    end
    return nil
end
Tattle.ResolveSpellName = ResolveSpellName

-- Cast events all arrive as (unitToken, castGUID, spellID), which is what the
-- spell-name gate reads.
local CAST_EVENTS = {
    UNIT_SPELLCAST_START          = true,
    UNIT_SPELLCAST_SUCCEEDED      = true,
    UNIT_SPELLCAST_FAILED         = true,
    UNIT_SPELLCAST_INTERRUPTED    = true,
    UNIT_SPELLCAST_CHANNEL_START  = true,
    UNIT_SPELLCAST_CHANNEL_STOP   = true,
}

-- Cast events whose caster filter has been switched off by some listening module
-- (see the `allCasters` registration flag). Precomputed at registration: the
-- filter runs before the listener list is walked, so it cannot ask each module
-- per event.
local eventAcceptsAnyCaster = {}

-- ============================================================================
-- Alert System
-- ============================================================================

-- The channel a "Raid" or "Party" request actually has to be sent on.
--
-- A Looking for Raid group is a raid, but it is not a LE_GROUP_TYPE_RAID raid:
-- it runs its own instance channel and SendChatMessage(..., "RAID") there is
-- dropped on the floor with no error. Same class of bug tarballs-dadabase hit --
-- announcements landed in normal raids and vanished in LFR.
--
-- The group-type constant is read from the global rather than captured at load
-- time, and only consulted when it exists, so a client without it keeps the old
-- behaviour instead of sending everything to a channel it does not have.
function Tattle.ResolveChatChannel(requested)
    if requested == "PRIVATE" or requested == "SAY" or requested == "YELL"
        or requested == "INSTANCE_CHAT" then
        return requested
    end

    if not IsInRaid() then
        -- Only a party (SendAlert has already ruled out being solo). "Raid"
        -- goes nowhere here, so deliver it on the channel that exists.
        return "PARTY"
    end

    -- In a plain raid both requests are left alone: the client maps "Party"
    -- onto the group channel there, and "Raid" is exactly right.
    if not LE_GROUP_TYPE_RAID then return requested end

    local ok, normalRaid = pcall(IsInRaid, LE_GROUP_TYPE_RAID)
    if ok and not normalRaid then
        -- LFR / flex raid: it runs its own instance channel, and a plain "Raid"
        -- or "Party" send there vanishes without an error. INSTANCE_CHAT is the
        -- channel its members are actually listening on.
        return "INSTANCE_CHAT"
    end

    return requested
end

local ResolveChatChannel = Tattle.ResolveChatChannel

local function SendAlert(message, moduleId)
    if not TattleDB or not TattleDB.enabled then return end
    if not IsGrouped() then return end

    local moduleSettings = TattleDB.modules[moduleId]
    if not moduleSettings or not moduleSettings.enabled then return end

    local alerts = moduleSettings.alerts
    if not alerts then return end

    DebugPrint("Alert:", message)

    if alerts.console then
        print(string_format("|cffff6600[Tattle]|r %s", message))
    end

    -- chatType "PRIVATE" means console only: the console block above already
    -- printed it, so there is nothing to send.
    local channel = ResolveChatChannel(alerts.chatType or "PRIVATE")
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

    if alerts.screen and Tattle.ScreenAlert then
        local ok, err = pcall(Tattle.ScreenAlert.Show, Tattle.ScreenAlert, message)
        if not ok then DebugPrint("Screen alert failed:", err) end
    end
end
Tattle.SendAlert = SendAlert

-- ============================================================================
-- OnEvent
-- ============================================================================

local moduleEvents = {}
local addonReady   = false

-- The events that begin a cast. This is what an outOfCombatOnly module gets
-- gated on -- see the comment in the event handler.
local OOC_ONLY_START = {
    UNIT_SPELLCAST_START        = true,
    UNIT_SPELLCAST_CHANNEL_START = true,
}

-- Module callbacks are isolated: one module erroring must not stop the others
-- that listen for the same event.
local function CallModule(module, moduleId, event, ...)
    local ok, err = pcall(module.onEvent, event, ...)
    if not ok then
        DebugPrint(string_format("Error in module %s: %s", moduleId, err))
    end
end

Tattle.eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= ADDON_NAME then return end

        InitializeSettings()

        Tattle._modulesReady = true
        for _, entry in ipairs(Tattle._pendingModules) do
            Tattle:_RegisterModuleNow(entry.id, entry.config)
        end
        Tattle._pendingModules = {}

        for moduleId, module in pairs(Tattle.modules) do
            InitializeModuleSettings(moduleId)
            for _, ev in ipairs(module.events) do
                moduleEvents[ev] = moduleEvents[ev] or {}
                table.insert(moduleEvents[ev], moduleId)
                -- One module opting out lifts the caster filter for the whole
                -- event, because the filter has to run before listeners are known.
                if CAST_EVENTS[ev] and module.allCasters then
                    eventAcceptsAnyCaster[ev] = true
                end
            end
            if module.initialize then module.initialize() end
        end

        if Tattle.ScreenAlert then Tattle.ScreenAlert:Initialize() end
        if Tattle.Config then Tattle.Config:BuildModuleTabs() end
        if Tattle.Config then Tattle.Config:RegisterInterfaceOptions() end

        addonReady = true
        print("Tattle v" .. Tattle.VERSION .. " loaded. Type /tattle to configure, or /tattle probe to see what your client exposes.")
        return
    end

    if event == "GROUP_ROSTER_UPDATE" then
        -- Before the gates below: leaving a raid has to drop the cached token
        -- lists even when the addon is off or you have just gone solo, or a
        -- stale "raid25" would outlive the group it named.
        InvalidateGroupCaches()
    end

    if not addonReady then return end
    if not TattleDB or not TattleDB.enabled then return end
    if not IsGrouped() then return end  -- grouped only, bail early

    -- Cast events are filtered here, once, before any module is woken: the
    -- cheapest question first.
    --
    -- Only a player can cast anything Tattle watches. The Swapblaster is a toy,
    -- Life Grip / Leap of Faith and Rescue are player spells -- a hunter's pet, a
    -- warlock's minion, a totem and every NPC in the zone are incapable of them,
    -- and they all produce cast events of their own, which is a lot of noise in a
    -- raid. So the caster is rejected before the spell name is even resolved.
    local arg1, arg2, arg3 = ...
    local spellName
    if CAST_EVENTS[event] then
        if not eventAcceptsAnyCaster[event] and not IsGroupMemberToken(arg1) then return end
        spellName = ResolveSpellName(arg3)
        if not spellName or not watchedSpellNames[spellName] then return end
    end

    local listeners = moduleEvents[event]
    if not listeners then return end

    -- A module flagged outOfCombatOnly watches a spell that cannot be cast in
    -- combat at all (the Swapblaster refuses to fire while fighting), so while
    -- its caster is busy there is nothing for it to evaluate. Life Grip and
    -- Rescue are not gated: a grip or a rescue is still worth seeing in combat,
    -- and each of those modules decides for itself what to say about it.
    --
    -- Only cast *starts* are gated. A cast that began out of combat can finish
    -- the fight itself -- landing a swap next to a pack is a classic way to
    -- start one -- so its SUCCEEDED / CHANNEL_STOP can arrive after combat
    -- began, and dropping those would lose the alert that matters most.
    local gateStarts = OOC_ONLY_START[event]
    local casterInCombat = nil  -- resolved at most once per event

    -- Cast events also hand the module the name the core already resolved, so it
    -- never pays for the lookup again, and the caster has already been confirmed
    -- as one of your group's players. Every event this addon listens to arrives
    -- as at most (unitToken, castGUID, spellID), so unpacking three values loses
    -- nothing -- a wider event would have to be passed through with `...`.
    local moduleSettings = TattleDB.modules
    for _, moduleId in ipairs(listeners) do
        local module = Tattle.modules[moduleId]
        if module and module.onEvent then
            local settings = moduleSettings[moduleId]
            if settings and settings.enabled then
                if gateStarts and module.outOfCombatOnly then
                    if casterInCombat == nil then casterInCombat = UnitInCombat(arg1) end
                    if casterInCombat then
                        DebugPrint("Skipping", moduleId, "- caster is in combat")
                    else
                        CallModule(module, moduleId, event, arg1, arg2, arg3, spellName)
                    end
                else
                    CallModule(module, moduleId, event, arg1, arg2, arg3, spellName)
                end
            end
        end
    end
end)

-- ============================================================================
-- Event Probe (/tattle probe)
-- ============================================================================

-- Dumps what the cast events actually expose in this build, so spell IDs and --
-- crucially whether a destination is available at all -- can be verified
-- instead of guessed. Secret-value safe: nothing is compared or printed raw;
-- spell names come from C_Spell.GetSpellInfo, which accepts secret values.
--
-- Like the modules, the probe only reports while you are grouped: everything it
-- measures (a swap, a grip, a rescue) needs a group, so a solo cast teaches
-- nothing and the aura/target sweeps below are pure waste when you are alone.
function Tattle.ToggleProbe()
    if Tattle._probeFrame then
        Tattle._probeFrame:SetScript("OnEvent", nil)
        Tattle._probeFrame = nil
        print("Tattle probe OFF.")
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
    -- The Swapblaster's cast is flagged channeled, so without these two the
    -- probe can sit through a swap and print nothing at all.
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")

    -- Group context (who is protected, who is targeting you) does not change
    -- from one cast event to the next, so it is reported at most once a second.
    local lastContext = 0

    f:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5, arg6)
        if not Tattle.IsGrouped() then return end

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

        print(string_format("|cffff6600[Tattle Probe]|r %s | spell: %s | caster: %s (isMe=%s) | dest: %s (isMe=%s)",
            event, spellName, casterText, casterIsMe, destText, destIsMe))

        -- Everything below this line is group context, which does not change from
        -- one cast event to the next: a raid-wide pull produces dozens of casts a
        -- second, and sweeping every member's auras for each of them would make
        -- the debug tool the most expensive thing in the addon. Reported at most
        -- once a second.
        if (GetTime() - lastContext) < 1 then return end
        lastContext = GetTime()

        -- Second question: can this build still see a group member's aura at all?
        -- "none visible" here means the "on Pancakes" half of an alert is impossible.
        for _, auraName in ipairs(probeAuraNames) do
            local visible = Tattle.AuraCarrierNames({ [auraName] = true }, "ALL")
            print(string_format("|cffff6600[Tattle Probe]|r   aura %-18s -> %s",
                auraName, visible[1] and table_concat(visible, ", ") or "none visible"))
        end

        -- Third: is the Neural Silencer buff readable? The optional watch list
        -- and every "it failed because ..." alert are built on this one lookup.
        local wearers = Tattle.SilencerWearerNames()
        print(string_format("|cffff6600[Tattle Probe]|r   neural silencers    -> %s",
            wearers[1] and table_concat(wearers, ", ") or "none"))

        -- Fourth: does this client expose other players' targets? "<member>target"
        -- is all the watch list has to work with, and a build that never syncs it
        -- shows nothing but nils here no matter who is looking at you.
        local entries = Tattle.GroupTargetEntries()
        local shown, watchers = 0, {}
        for _, entry in ipairs(entries) do
            local name = Tattle.GetUnitShortName(entry.owner) or entry.owner
            local targetName = UnitExists(entry.target) and UnitName(entry.target)
            if UnitIsUnit(entry.target, "player") then
                watchers[#watchers + 1] = name
                targetName = name .. " (you)"
            end
            if shown < 5 then
                shown = shown + 1
                print(string_format("|cffff6600[Tattle Probe]|r   target of %-14s -> %s",
                    name, targetName or "none / not synced"))
            end
        end
        print(string_format("|cffff6600[Tattle Probe]|r   targeting you        -> %s",
            watchers[1] and table_concat(watchers, ", ") or "nobody we can read"))
    end)

    Tattle._probeFrame = f
    print("Tattle probe ON (grouped only). Cast Swapblaster / Life Grip / Rescue -- on yourself AND on a friend -- and watch chat.")
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

local function HandleSlashCommand(msg)
    msg = (msg or ""):lower():trim()

    if msg == "" then
        if Tattle.Config then Tattle.Config:Toggle() end

    elseif msg == "version" then
        print("Tattle version " .. Tattle.VERSION)

    elseif msg == "on" then
        TattleDB.enabled = true
        print("Tattle enabled.")

    elseif msg == "off" then
        TattleDB.enabled = false
        print("Tattle disabled.")

    elseif msg == "debug" then
        TattleDB.debug = not TattleDB.debug
        print("Tattle debug " .. (TattleDB.debug and "ON" or "OFF"))

    elseif msg == "probe" then
        Tattle.ToggleProbe()

    elseif msg == "status" then
        print("Tattle v" .. Tattle.VERSION)
        print("  Enabled:", TattleDB.enabled and "ON" or "OFF")
        print("  Grouped:", IsGrouped() and "YES" or "NO")
        print("  Debug:",   TattleDB.debug and "ON" or "OFF")
        print("Modules:")
        -- moduleOrder, not pairs(): a string-keyed table has no defined order, so
        -- pairs() would reshuffle this list (and the config tabs) between runs.
        for _, moduleId in ipairs(Tattle.moduleOrder) do
            local module = Tattle.modules[moduleId]
            local s = module and TattleDB.modules[moduleId]
            if s then
                local channel = (s.alerts and s.alerts.chatType) or "PRIVATE"
                -- Show what a chat alert would actually be sent on when that is
                -- not the channel named in the settings (an LFR raid, for one).
                local sent = (s.alerts and s.alerts.chat) and Tattle.ResolveChatChannel(channel) or nil
                local note = (sent and sent ~= channel)
                    and string_format(" (sent on %s in this group)", sent) or ""
                print("  [" .. module.name .. "]",
                    s.enabled and "ON" or "OFF",
                    "| scope:", module.noScope and "n/a" or (s.scope or "group"),
                    "| chat:", channel .. note)
            end
        end

        -- The watch list is the one piece of output that is not an alert, so it
        -- needs its own line to be debuggable.
        local display = TattleDB.modules.silencer and TattleDB.modules.silencer.display
        if display then
            local sections = {}
            if display.showWearers then sections[#sections + 1] = "Neural Silencers" end
            if display.showWatchers then sections[#sections + 1] = "targeting me" end
            print("  Watch list:", display.showList
                and ("ON (" .. (sections[1] and table_concat(sections, ", ") or "no sections") .. ")")
                or "OFF")
        end

    else
        print("Tattle: /tattle [version|on|off|debug|probe|status]")
    end
end

-- One command, and it is the name the addon has. Accepting the old name as a
-- hidden alias would mean shipping two spellings of the same thing forever - a
-- `/snitch` in someone's macro that quietly works is worse than one that fails
-- and sends them looking for the new command.
SLASH_TATTLE1 = "/tattle"
SlashCmdList["TATTLE"] = HandleSlashCommand
