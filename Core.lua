-- Core.lua - the event frame, the module registry, saved settings, dispatch,
-- the shared group/aura/silencer helpers, and alerts.
--
-- First in Tattle.toc, and it owns the one event frame. Every file after this
-- one receives the same namespace table as the loader's second argument
-- (`local _, Tattle = ...`), so no file has to declare or defend the global and
-- a wrong TOC order fails at load with a nil namespace instead of quietly
-- building a second one.

local ADDON_NAME, Tattle = ...

Tattle.VERSION = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "Unknown"

-- ============================================================================
-- Localize Globals
-- ============================================================================

local pairs = pairs
local ipairs = ipairs
local print = print
local type = type
local table_concat = table.concat
local table_wipe = table.wipe
local math_min = math.min
local string_format = string.format

local IsInRaid = IsInRaid
local UnitExists = UnitExists
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
local CreateFrame = CreateFrame
local UIParent = UIParent
local pcall = pcall

-- ============================================================================
-- The Event Frame
-- ============================================================================
--
-- One frame for the whole addon. The cast events it registers are driven by
-- CAST_EVENTS so there is a single list of them: the dispatcher below filters
-- on that same table, so an event that is not in it could never be dispatched
-- anyway, and an event in it but not registered here would be silently dead.
-- GROUP_ROSTER_UPDATE is registered here rather than left to the modules
-- because the core caches the group's unit tokens and has to drop them whether
-- or not any module wants them.

local CAST_EVENTS = {
    UNIT_SPELLCAST_START          = true,
    UNIT_SPELLCAST_SUCCEEDED      = true,
    UNIT_SPELLCAST_FAILED         = true,
    UNIT_SPELLCAST_INTERRUPTED    = true,
    UNIT_SPELLCAST_CHANNEL_START  = true,
    UNIT_SPELLCAST_CHANNEL_STOP   = true,
}
Tattle.CAST_EVENTS = CAST_EVENTS   -- the probe and the test harness read this

-- How combat gates a module's casts, by declared policy. Each value maps to the
-- set of cast events the dispatcher judges against the caster's combat state.
--
--   "start" -- judge only the cast *start*. For a spell that cannot begin while
--       its caster is fighting (the Swapblaster refuses to fire in combat), a
--       start during a fight cannot be real, but the landing of a cast that
--       began out of combat can and should still be reported: dropping a
--       SUCCEEDED that arrives after combat started would throw away the one
--       alert that mattered (see Modules/Swapblaster.lua).
--
--   "all"   -- judge every event of the cast. For the instant utility spells
--       (Life Grip, Rescue), a grab that resolves while the caster is fighting
--       is a raid tool doing its job, not the out-of-combat mugging this addon
--       exists to announce. Requiring the whole cast to be out of combat also
--       keeps the modules' per-caster bookkeeping honest: they only ever arm a
--       cast out of combat, so if a failure or interrupt could reach them mid-
--       fight, a stale armed entry from an earlier out-of-combat cast would be
--       mistaken for the explanation of a failure that had nothing to do with it.
--
-- Living here rather than in each module lets the modules drop four copies of the
-- same UnitAffectingCombat branch, and keeps that API call out of module code
-- entirely -- the one place this addon is careful about calling it at all.
local OUT_OF_COMBAT_EVENTS = {
    start = CAST_START_EVENTS,
    all   = CAST_EVENTS,
}

Tattle.eventFrame = CreateFrame("Frame", nil, UIParent)
Tattle.eventFrame:RegisterEvent("ADDON_LOADED")
Tattle.eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
for event in pairs(CAST_EVENTS) do
    Tattle.eventFrame:RegisterEvent(event)
end

-- ============================================================================
-- Module Registry
-- ============================================================================
--
-- A module registers itself when its file runs, which is during load and always
-- after this file, so registration needs no queue: the frame above already
-- exists and the listeners are wired in ADDON_LOADED once every module is in.

Tattle.modules = {}
-- Registration order (= TOC order), so tabs, /tattle status and the order
-- modules are called for a shared event are all reproducible. pairs() over a
-- string-keyed table has no defined order.
Tattle.moduleOrder = {}

-- event name -> { moduleId, ... }, built from moduleOrder by
-- RebuildModuleListeners below.
local moduleEvents = {}

-- Cast events whose caster filter has been switched off by some listening module
-- (see the `allCasters` registration flag). Precomputed at registration: the
-- filter runs before the listener list is walked, so it cannot ask each module
-- per event.
local eventAcceptsAnyCaster = {}

-- Declared here, defined with the rest of the settings below: a module that
-- registers after ADDON_LOADED has already fired needs a settings row as well as
-- listeners, or it would arrive wired up and switched off at the same time.
local InitializeModuleSettings

local function RebuildModuleListeners()
    table_wipe(moduleEvents)
    table_wipe(eventAcceptsAnyCaster)
    for _, moduleId in ipairs(Tattle.moduleOrder) do
        local module = Tattle.modules[moduleId]
        for _, ev in ipairs(module.events) do
            local listeners = moduleEvents[ev]
            if not listeners then
                listeners = {}
                moduleEvents[ev] = listeners
            end
            listeners[#listeners + 1] = moduleId
            -- One module opting out lifts the caster filter for the whole event,
            -- because the filter runs before the listeners are consulted.
            if CAST_EVENTS[ev] and module.allCasters then
                eventAcceptsAnyCaster[ev] = true
            end
        end
    end
    Tattle._listenersReady = true
end
Tattle.RebuildModuleListeners = RebuildModuleListeners

function Tattle:RegisterModule(moduleId, config)
    self:_RegisterModuleNow(moduleId, config)
    -- Every file in the TOC registers long before ADDON_LOADED, so this is the
    -- unusual path. But "registered and then never called" is the kind of failure
    -- that costs an hour to find, so a module that shows up late is given what a
    -- module that arrived on time gets: a settings row, and a place in the
    -- listener lists.
    if self._listenersReady then
        InitializeModuleSettings(moduleId)
        RebuildModuleListeners()
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
        extraContent = config.extraContent,
        -- Set by modules that do not filter casts, so their tab skips the
        -- "Monitor: whole group / only me" control they would ignore.
        noScope = config.noScope,
        defaultSpellIDs = config.spellIDs,
        -- "start" or "all" -- see OUT_OF_COMBAT_EVENTS. Validated at
        -- registration so a typo fails loudly at login rather than quietly
        -- gating nothing at all.
        outOfCombat = config.outOfCombat,
        -- Opts a module out of the dispatcher's "only your group's players cast
        -- this" filter. Nothing in Tattle needs it today: the Swapblaster is a
        -- toy and Life Grip, Leap of Faith and Rescue are player spells, so a
        -- pet, a minion or an NPC cannot be the caster. A module watching
        -- something an NPC *can* cast would set this.
        allCasters = config.allCasters,
    }
    if config.outOfCombat and not OUT_OF_COMBAT_EVENTS[config.outOfCombat] then
        print(string_format("Tattle: module %s asked for outOfCombat policy %q, which is not a thing -- its casts will not be combat-gated at all",
            moduleId, tostring(config.outOfCombat)))
    end

    table.insert(self.moduleOrder, moduleId)

    -- RegisterEvent here so a module's declared `events` actually reach the frame
    -- the dispatcher reads. The built-in cast events are registered up top.
    if self.eventFrame then
        for _, ev in ipairs(config.events or {}) do
            self.eventFrame:RegisterEvent(ev)
        end
    end
end

-- ============================================================================
-- Saved Variables & Settings
-- ============================================================================
-- TattleDB is the one deliberate global besides the slash command: SavedVariables
-- are global by definition and a module cannot read another addon's file.

TattleDB = TattleDB or {}

local function InitializeSettings()
    if TattleDB.enabled == nil then TattleDB.enabled = true end
    if TattleDB.debug   == nil then TattleDB.debug   = false end
    TattleDB.modules = TattleDB.modules or {}
end

InitializeModuleSettings = function(moduleId)
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

    -- And you. A party numbers only the other four -- there is no "party5" that
    -- means you -- so without this your own Swapblaster or Life Grip would be
    -- filtered out before any module ever saw it. In a raid you do hold a raidN
    -- index and the branch above usually catches you already, but UnitIsUnit is
    -- the one question that is right in both group types, and it is secret-safe
    -- where comparing the token is not.
    local ok3, isMe = pcall(UnitIsUnit, unitToken, "player")
    return (ok3 and isMe) and true or false
end
Tattle.IsGroupMemberToken = IsGroupMemberToken

-- Same unit, asked through the API. Never with `==`: in restricted content a
-- unit token can be a secret value, and comparing one raises an error rather
-- than returning false. Two different tokens can also name the same unit ("you"
-- is "player" and also your own raidN), which string equality cannot see.
local function IsSameUnit(a, b)
    if not a or not b then return false end
    local ok, same = pcall(UnitIsUnit, a, b)
    return (ok and same) and true or false
end
Tattle.IsSameUnit = IsSameUnit

-- Whether a token names you. In a raid you hold one of the raidN indexes as well
-- as being "player", so raw string comparison answers that question wrongly about
-- half the time -- which is how the watch list came to say "you and you" and an
-- Evoker came to be reported as their own Rescue passenger. It is pcall'd for the
-- same reason as above: comparing units is the cheap way to touch a restricted
-- token, and a refusal means "not provably you", which is the safe answer.
local function IsYou(unitToken)
    if not unitToken then return false end
    if unitToken == "player" then return true end
    return IsSameUnit(unitToken, "player")
end
Tattle.IsYou = IsYou

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

-- Every unit token that names a member of your group, with you appearing
-- exactly once and always as "player".
--
-- Getting that single appearance right matters more than it looks. In a raid you
-- hold one of the raidN indexes and GetNumGroupMembers() counts you, so
-- appending "player" on top of raid1..raidN scans you twice: the watch list
-- reads "Neural Silencer: you and you", the blocked-cast wording falls into its
-- plural branch for a single protected person, and AuraCarriers -- which excludes
-- the caster, because Rescue marks both halves of the flight -- leaves your own
-- raidN entry in, so you turn up as your own Rescue passenger. In a party the
-- numbered tokens exclude you and stop at four, which is why the two branches
-- cannot share a tail.
--
-- A token whose UnitExists fails is skipped rather than kept: a solo-queue party
-- of one reports a member count of one without a "party1" to name it.
local function GroupUnitTokens()
    if cachedTokens then return cachedTokens end

    local tokens = {}
    local count = GetNumGroupMembers()
    if IsInRaid() then
        for i = 1, count do
            local token = "raid" .. i
            if UnitExists(token) and not IsYou(token) then
                tokens[#tokens + 1] = token
            end
        end
    else
        for i = 1, math_min(count, 4) do
            local token = "party" .. i
            if UnitExists(token) then tokens[#tokens + 1] = token end
        end
    end
    tokens[#tokens + 1] = "player"   -- you, in either group shape, exactly once

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
            -- Your own index is in this range, and a watcher list that names you
            -- looking at yourself is noise, not information.
            if UnitExists(owner) and not IsYou(owner) then
                entries[#entries + 1] = { owner = owner, target = owner .. "target" }
            end
        end
    else
        for i = 1, math_min(count, 4) do
            local owner = "party" .. i
            if UnitExists(owner) then
                entries[#entries + 1] = { owner = owner, target = owner .. "target" }
            end
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
        if not IsSameUnit(token, excludeToken) and UnitHasAnyAura(token, nameSet, auraFilter) then
            carriers[#carriers + 1] = token
        end
    end
    return carriers
end
Tattle.AuraCarriers = AuraCarriers

local function AuraCarrierNames(nameSet, auraFilter, excludeToken)
    local names = {}
    for _, token in ipairs(AuraCarriers(nameSet, auraFilter, excludeToken)) do
        local name = IsYou(token) and "you" or GetUnitShortName(token)
        names[#names + 1] = name or "someone"
    end
    return names
end
Tattle.AuraCarrierNames = AuraCarrierNames

local function FormatList(t)
    local n = #t
    if n == 0 then return nil end
    if n == 1 then return t[1] end
    if n == 2 then return t[1] .. " and " .. t[2] end
    -- concat over a range of the original list: copying all but the last item
    -- into a fresh table to join them would allocate on every alert.
    return table_concat(t, ", ", 1, n - 1) .. " and " .. t[n]
end
Tattle.FormatList = FormatList

-- "you" / "Donut" / "Donut and Pancakes", for the "used X on Y" alerts.
local function TargetPhrase(carrierTokens)
    local names = {}
    for i, token in ipairs(carrierTokens) do
        names[i] = IsYou(token) and "you" or (GetUnitShortName(token) or "someone")
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

-- " (Neural Silencer worn by Donut)" -- "" when the list is empty. A statement of
-- fact rather than an accusation, which is what a failed cast deserves: the spell
-- could have failed for any number of reasons, but it is still worth knowing
-- somebody in here is immune to it.
--
-- This is the only place that sentence is written. Modules that already swept the
-- group (the Swapblaster records its wearers when a cast starts, so a late alert
-- describes the group as it was then) pass the list; everyone else passes a token
-- to exclude and lets the sweep happen here.
local function SilencerNoteList(wearers)
    if not wearers or #wearers == 0 then return "" end
    return string_format(" (Neural Silencer worn by %s)", FormatList(wearers))
end
Tattle.SilencerNoteList = SilencerNoteList

local function SilencerNote(excludeToken)
    return SilencerNoteList(SilencerWearerNames(excludeToken))
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
                    IsYou(token) and "you" or (GetUnitShortName(token) or "someone")
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
    local who = IsYou(casterToken) and "you are" or ((casterName or "they") .. " is")
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

-- Scope gate: may this cast be dropped because it provably did not involve you?
-- Returns true only when that is known; anything unproven returns false, so the
-- cast is reported.
--
-- Asking it this way round is deliberate. The natural phrasing -- "should I
-- report this?" -- needs three answers (yes, no, and "I cannot tell, so yes"),
-- and every call site then has to remember to write `== false` rather than the
-- `not` that is sitting right there. A mis-typed check would silently swallow a
-- warning. Here a plain `if Tattle.ScopeDrops(...) then return end` is correct,
-- and "unknown" is simply the same answer as "not mine? no".
--
-- Scope "self" means: you cast it, or it landed on you. The caster being someone
-- else is NOT enough to drop the alert -- a Swapblaster or Life Grip aimed at you
-- is exactly the event this addon exists to warn about.
--
-- IMPORTANT: UNIT_SPELLCAST_* events name the caster but never the destination
-- (destination lived only in COMBAT_LOG_EVENT_UNFILTERED, removed in 12.0), and
-- a Swapblaster cast marks nobody. An empty targetTokens list therefore means
-- "could not resolve", never "provably not you", so a failed aura read cannot
-- silently drop a warning.
local function ScopeDrops(moduleId, casterToken, targetTokens)
    local settings = Tattle.GetModuleSettings(moduleId)
    if not settings or settings.scope ~= "self" then return false end

    if casterToken then
        local ok, isMe = pcall(UnitIsUnit, casterToken, "player")
        if ok and isMe then return false end
    end

    -- No victims identified: unknown, and unknown is not evidence of innocence.
    if not targetTokens or #targetTokens == 0 then return false end

    for _, token in ipairs(targetTokens) do
        local ok, isMe = pcall(UnitIsUnit, token, "player")
        if ok and isMe then return false end
    end
    return true
end
Tattle.ScopeDrops = ScopeDrops

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

-- ---------------------------------------------------------------------------
-- Shared module plumbing
-- ---------------------------------------------------------------------------
--
-- Every cast module needs the same three things: which IDs to watch (the user's
-- list if they typed one, the shipped list otherwise), those IDs turned into the
-- names this client actually reports, and a way to ask "is this cast one of
-- mine?". Each module used to carry its own copy -- four copies of logic that
-- has to agree -- so they live here once.

-- The IDs this module should watch right now.
function Tattle.MakeSpellIDs(moduleId, shippedIDs)
    local settings = Tattle.GetModuleSettings(moduleId)
    local stored = settings and settings.spellIDs
    if type(stored) == "table" and #stored > 0 then return stored end
    return shippedIDs
end

-- Fill nameSet with the names this client reports for spellIDs, and register
-- them so the dispatcher wakes this module for them. Comparing names rather than
-- IDs is what survives a spell being renumbered by a patch, and it is also the
-- only comparison that is safe on a spell ID that arrived as a secret value.
-- An ID the client does not know is named in the debug log instead of being
-- silently unwatched.
function Tattle.ResolveSpellNames(nameSet, spellIDs)
    for _, id in ipairs(spellIDs or {}) do
        local name = ResolveSpellName(id)
        if name then
            nameSet[name] = true
            DebugPrint("  watching", name, "(" .. tostring(id) .. ")")
        else
            DebugPrint("  WARNING: spell ID", id, "is not in this client's spell database")
        end
    end
    WatchSpellNames(nameSet)
    return nameSet
end

-- A predicate answering "is this cast one of mine?", using the name the
-- dispatcher already resolved when it has one and falling back to the ID when it
-- does not. Built once, at initialize, so no module re-walks its own list.
function Tattle.MakeSpellMatcher(nameSet)
    return function(spellName, spellID)
        if spellName then return nameSet[spellName] == true end
        if not spellID then return false end
        local name = ResolveSpellName(spellID)
        return (name ~= nil) and (nameSet[name] == true)
    end
end

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

local addonReady = false

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
        local loadedName = ...
        if loadedName ~= ADDON_NAME then return end

        InitializeSettings()

        -- moduleOrder, not pairs(): this loop decides the order modules get to
        -- initialize, and RebuildModuleListeners uses the same order for the
        -- listeners, so pairs() cannot reshuffle either between sessions. No
        -- module reads another's initialize() output today -- that is luck, not
        -- design -- but TOC order is at least a defined order to have luck in.
        for _, moduleId in ipairs(Tattle.moduleOrder) do
            InitializeModuleSettings(moduleId)
            local module = Tattle.modules[moduleId]
            if module.initialize then module.initialize() end
        end

        RebuildModuleListeners()

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

    -- Cast events are filtered here, once, before any module is woken.
    --
    -- Only a player can cast anything Tattle watches: the Swapblaster is a toy,
    -- Life Grip / Leap of Faith and Rescue are player spells, and nothing that is
    -- not a player can use them. Pets, minions, totems and every nameplate in the
    -- zone produce cast events of their own, and during a fight they outnumber the
    -- casts that matter by orders of magnitude.
    --
    -- The caster is asked first, even though asking it costs up to three unit
    -- queries where naming the spell costs one. Naming a spell means indexing a
    -- table with a name derived from the event's spell ID, and in restricted
    -- content that name descends from a secret value -- indexing a table with one
    -- is an error, not a false. The unit queries are documented to accept secret
    -- values, so this order sends the noise out through the safe door. The
    -- cheaper-looking order widens what can throw, on the busiest path there is,
    -- and a throw here silences the addon for the remainder of the event.
    local arg1, arg2, arg3 = ...
    local spellName
    if CAST_EVENTS[event] then
        if not eventAcceptsAnyCaster[event] and not IsGroupMemberToken(arg1) then return end
        spellName = ResolveSpellName(arg3)
        if not spellName or not watchedSpellNames[spellName] then return end
    end

    local listeners = moduleEvents[event]
    if not listeners then return end

    -- Combat gating, by the policy each module declares (see
    -- OUT_OF_COMBAT_EVENTS). The caster's combat state is asked at most once per
    -- event, and only when some listening module actually cares about it.
    local casterInCombat = nil

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
                local gate = module.outOfCombat and OUT_OF_COMBAT_EVENTS[module.outOfCombat]
                local drop = (gate ~= nil) and (gate[event] == true)
                if drop then
                    if casterInCombat == nil then casterInCombat = UnitInCombat(arg1) end
                    drop = casterInCombat
                end

                if drop then
                    DebugPrint("Skipping", moduleId, "- its caster is in combat")
                else
                    CallModule(module, moduleId, event, arg1, arg2, arg3, spellName)
                end
            end
        end
    end
end)
