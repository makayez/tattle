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
local string_lower = string.lower

local IsInRaid = IsInRaid
local UnitExists = UnitExists
local UnitInRaid = UnitInRaid
local UnitInParty = UnitInParty
local UnitIsUnit = UnitIsUnit
local UnitName = UnitName
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
-- Utility
-- ============================================================================
--
-- Declared at the top because the registration path below reports through it, and a
-- Lua local is only visible to functions written after it.

local function DebugPrint(...)
    if TattleDB and TattleDB.debug then
        print("|cff00ff00[Tattle Debug]|r", ...)
    end
end
Tattle.DebugPrint = DebugPrint

-- ============================================================================
-- Restricted Values
-- ============================================================================
--
-- In restricted content (M+, rated PvP) the client hands cast events *secret*
-- values: the spell ID, any name derived from that ID, the unit name behind a
-- secret unit, and on some builds the unit token itself. A secret value may only
-- be handed to an API documented to accept one. Comparing it - with a literal,
-- with another secret, or with itself - concatenating it, indexing a table with
-- it, or printing it all raise:
--
--   attempt to compare local 'name' (a secret string value, while execution
--   tainted by 'Tattle')
--
-- `type()` is no help: a secret string still reports "string". That is provable
-- from the alpha.3 crash, which happened at `name ~= ""` - a line only reachable
-- after `type(name) == "string"` had already answered true. So nothing in this
-- addon may inspect a value that came from a restricted event. The rules:
--
--   1. Ask the client rather than the value. `UnitIsUnit` accepts a secret token
--      and answers with a plain boolean, so a secret token can be resolved to
--      whichever plain `player`/`partyN`/`raidN` token this addon built itself
--      (GroupSlotOf), and every table keyed on a caster keys on that.
--   2. Attempt the operation under pcall and treat a refusal as its own answer.
--      These helpers return nil for "the client would not say", which callers
--      must never read as "no" - same convention as ScopeDrops.
--   3. Where a name has to be matched against our own list and the name is
--      secret, use the client's sanctioned comparison API if this build has one.

-- Present in some 11.x/12.x clients and *not named anywhere in the 12.1.5 or 12.1.7
-- generated documentation*, which makes its absence the likeliest missing API in this
-- addon rather than a hypothetical one. Asked for at the moment it is needed instead of
-- captured while the addon loaded, and that is not tidiness: a load-time capture is the
-- one absence in this file no test can reach, because the harness loads the addon into
-- exactly one client and never a second time. A call-time lookup lets a check take the
-- namespace away, run the sentence that wants it, and put it back - so "this build has no
-- sanctioned comparison" stops being a claim in a comment and becomes a path a machine has
-- watched execute. The same reasoning covers `CanAccessValueApi` and `AuraReaderApi`
-- below; nothing else in the shipped files captures a client API at load time.
local function SecretComparisonApi()
    local namespace = C_SecretComparisons
    local equal = namespace and namespace.Equal
    if type(equal) ~= "function" then return nil end
    return equal
end

-- Asking "is this secret?" is itself a comparison, so the probe is the smallest
-- one possible: a plain value is equal to itself, and the client raises when a
-- secret value is compared at all. Nothing else about the value is looked at - not
-- its truthiness, not its length, not its type beyond what type() reports (and
-- type() reports "string" for a secret string, which is the trap).
local function SelfCompare(value) return value == value end

local function IsSecretValue(value)
    local kind = type(value)
    if kind ~= "string" and kind ~= "number" then return false end
    return not pcall(SelfCompare, value)
end
Tattle.IsSecretValue = IsSecretValue

-- The value, when it is safe to print, concatenate, or use as a key; nil when it
-- is not. A name this addon cannot read is a name it must not half-use.
local function PlainText(value)
    if type(value) ~= "string" then return nil end
    if not pcall(SelfCompare, value) then return nil end
    return value
end
Tattle.PlainText = PlainText

-- nameSet[name] == true, attempted rather than assumed: indexing a table with a
-- secret key is a refusal, not a miss.
local function LookupInNameSet(nameSet, name) return nameSet[name] == true end

-- "Is this secret spell name one of ours?" asked through the client, which is the
-- only side allowed to compare a secret value. Both argument orders are tried
-- because the sanctioned API is not documented as caring which side is which.
-- true/false when this build answered, nil when it would not answer at all.
local function SecretNameMatches(nameSet, secretName)
    local secretEqual = SecretComparisonApi()
    if not secretEqual then return nil end
    local answered = false
    for watched in pairs(nameSet) do
        local ok, same = pcall(secretEqual, secretName, watched)
        if not ok then ok, same = pcall(secretEqual, watched, secretName) end
        if ok and type(same) == "boolean" then
            answered = true
            if same then return true end
        end
    end
    -- `answered and false or nil` reads like the answer and is not: `true and
    -- false` is false, and `false or nil` is nil, so the idiom makes "the client
    -- said no" indistinguishable from "the client would not answer" -- which on a
    -- restricted build turns every unwatched cast in the instance into a reported
    -- refusal. Say it in two lines instead.
    if answered then return false end
    return nil
end

-- "Is this name in nameSet?" - true/false when answered, nil when the client
-- refused, which is neither yes nor no.
--
-- A string is tried as a key first, under pcall, because on a client that is not
-- restricted that is the whole answer and it costs one index. A secret string is a
-- refusal rather than a miss; a value that is not a string at all is not a key this
-- addon may use either way. Both end at the same place: ask the client.
local function NameMatches(nameSet, name)
    if type(name) == "string" then
        local ok, hit = pcall(LookupInNameSet, nameSet, name)
        if ok then return hit == true end
    end
    return SecretNameMatches(nameSet, name)
end
Tattle.NameMatches = NameMatches

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
-- or not any module wants them. The PLAYER_REGEN pair is registered for the same
-- reason: whether *this player* is fighting decides whether the addon does
-- anything at all (see "Idle while you fight" below), so the core has to know
-- about the transition even when no module asked.

-- The two events that *begin* a cast. The core's `outOfCombat = "start"` policy
-- is judged against this set, so it has to name both families a cast can start
-- with: a plain cast sends UNIT_SPELLCAST_START, a channeled one (Swap is flagged
-- channeled) sends UNIT_SPELLCAST_CHANNEL_START. Listing only the first is how
-- the Swapblaster's gate silently gated nothing.
local CAST_START_EVENTS = {
    UNIT_SPELLCAST_START         = true,
    UNIT_SPELLCAST_CHANNEL_START = true,
}

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
Tattle.eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
Tattle.eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
Tattle.eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
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
        -- One entry per event per module. A module whose event list repeats an event
        -- is a duplicate alert waiting to happen - the dispatcher would wake it twice
        -- for one cast - and "two Swapblaster alerts per swap" is exactly the kind of
        -- report a repeated entry in that list produces. Dropped here so the mistake
        -- cannot reach a player, and said out loud in debug so it is not invisible.
        local seen = {}
        for _, ev in ipairs(module.events) do
            if not seen[ev] then
                seen[ev] = true
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
            else
                DebugPrint("module", moduleId, "listed", ev, "twice - registered once")
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
            -- What an alert does on an install that has never opened the config
            -- panel. The on-screen warning is the alert: it interrupts without putting
            -- words in somebody else's chat window. Chat is a deliberate shout into a
            -- channel, and audio is opt-in because five people in a raid all beeping at
            -- once is not information. Console output is *debugging* -- SendAlert
            -- switches it on for every module when /tattle debug is set, whatever is
            -- ticked here -- so it is off by default, which is the half a beta player
            -- found the hard way: a chat window full of [Tattle] lines nobody asked
            -- for, and no on-screen warning because that one was off too.
            console   = false,
            chat      = false,
            chatType  = "SAY",      -- SAY | YELL | PARTY | RAID | INSTANCE_CHAT | PRIVATE
            audioFile = SOUNDKIT.RAID_WARNING or 8959,
            audio     = false,
            screen    = true,
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

    -- Every key comes from `defaults` rather than from a literal typed next to it.
    -- Writing the same default twice is how a migration and a fresh install end up
    -- disagreeing about what "never set this" means.
    local a = stored.alerts
    if a.console   == nil then a.console   = defaults.alerts.console end
    if a.chat      == nil then a.chat      = defaults.alerts.chat end
    if a.chatType  == nil then a.chatType  = defaults.alerts.chatType end
    if a.audioFile == nil then a.audioFile = defaults.alerts.audioFile end
    if a.audio     == nil then a.audio     = defaults.alerts.audio end
    if a.screen    == nil then a.screen    = defaults.alerts.screen end
end

-- ============================================================================
-- Problems worth telling the user about
-- ============================================================================
--
-- A restricted-context refusal is invisible by design in a running game: it is
-- the client declining an API call, not the addon doing something loud. That is
-- also why "Tattle went quiet in my M+ run" was undiagnosable - every module
-- error was being printed only when /tattle debug happened to be on. Each kind
-- of swallowed problem is counted, announced once, and listed by /tattle status.

local sessionProblems = {}     -- kind -> { count = n, detail = "first one seen" }

function Tattle.ReportProblem(kind, detail)
    -- Always a string, because /tattle status prints it with %s and the client's
    -- Lua 5.1 string.format raises on a nil where a newer one prints "nil".
    if detail == nil then detail = "no detail" end
    local problem = sessionProblems[kind]
    if problem then
        problem.count = problem.count + 1
    else
        sessionProblems[kind] = { count = 1, detail = detail }
        print(string_format("Tattle: %s (%s) - later ones are counted by /tattle status",
            kind, tostring(detail)))
    end
    DebugPrint("problem:", kind, detail)
end


function Tattle.SessionProblems()
    return sessionProblems
end

-- Group guard. These abilities can only be used on someone you are grouped
-- with, so party and raid both matter -- a raid-only gate is silent for the
-- 2-5s / open-world griefing this addon exists for.
-- GetNumGroupMembers() covers party and raid without leaning on IsInGroup's
-- ever-shifting argument signature.
local function IsGrouped()
    return IsInRaid() or GetNumGroupMembers() > 0
end
Tattle.IsGrouped = IsGrouped

-- Returns short name (no realm) for a unit token, or nil when the client will not
-- name them. In restricted content UnitName answers for a group member with a
-- secret value, and `type()` still calls that a string - so the read is not enough,
-- the answer has to be proved printable before a string method touches it.
local function GetUnitShortName(unitToken)
    if not unitToken then return nil end
    -- pcall'd because the tokens handed to this are not always plain group
    -- indexes: the swap victim lookup asks about a unit that only exists if the
    -- client synced it, and a restricted context refuses the read rather than
    -- returning nil.
    local ok, fullName = pcall(UnitName, unitToken)
    if not ok then return nil end
    fullName = PlainText(fullName)
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
--
-- There is deliberately no `unitToken == "player"` shortcut. It was a fast path for
-- the common case and a crash for the restricted case, and UnitIsUnit("player",
-- "player") is already true.
local function IsYou(unitToken)
    if not unitToken then return false end
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

-- Which member of your group an event's caster token names, answered as a plain
-- token this addon built itself: "player" for you (whatever index the client used
-- to report you), otherwise the group's own "raidN"/"partyN". nil means "not a
-- member of your group", which includes pets, totems and NPCs.
--
-- Two separate problems, one answer:
--
--   * A restricted client can hand the caster in as a secret value. Every token a
--     module keys on, and every `<unit>target` string built from it, has to be
--     plain for the addon to store or print it. This is the only way to turn a
--     secret token into a plain one: the client answers UnitIsUnit for a secret
--     operand, and the token that comes back is one of ours.
--   * A client that reports you as your own raidN index reports the same cast
--     under a second token as well. Keying bookkeeping on whatever the event
--     carried means two records for one cast, and each record gets to announce
--     itself. Collapsing to one canonical token means one record.
--
-- Cost is at most one UnitIsUnit per group member, so callers ask only after the
-- spell name has already matched something worth announcing -- a handful of times
-- per fight, not per cast the raid produces.
local function GroupSlotOf(unitToken)
    if not unitToken then return nil end
    if IsYou(unitToken) then return "player" end
    for _, token in ipairs(GroupUnitTokens()) do
        -- "player" was the answer above; the rest are this addon's own strings.
        if token ~= "player" and IsSameUnit(unitToken, token) then return token end
    end
    return nil
end
Tattle.GroupSlotOf = GroupSlotOf

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

-- Which group member a unit currently has targeted, as a group token, or nil when
-- the target is unreadable or is not one of ours.
--
-- This is the only remaining way to find out who a spell was aimed at: the combat
-- log was the one API that carried a destination, and 12.0.0 removed it. It is a
-- read of `raidNtarget`, which is group data of the same family the raid frames
-- use - so it is there or it is not, per patch and per context, and "nil" means
-- "your client was not told", never "nobody was targeted".
--
-- The existence check runs first on purpose. Resolving a target means a
-- UnitIsUnit per group member, which is twenty-odd calls in a raid; on a client
-- that was never told the target, or with a caster who has none, one UnitExists
-- answers the question and the loop never runs.

-- `<unit>target`, built without touching anything the client is not allowed to let
-- us touch. Concatenation is *attempted*: the plain token of the ordinary case
-- costs one string operation and no unit queries at all, and only when the client
-- refuses - which is what a secret token does - does this pay to resolve the
-- caster into one of this addon's own plain tokens, which is also the only way to
-- get a target token at all, since a secret value cannot be concatenated.
local function AppendSuffix(value, suffix) return value .. suffix end

local function TargetTokenOf(unitToken)
    local ok, token = pcall(AppendSuffix, unitToken, "target")
    if ok and type(token) == "string" then return token end
    local slot = GroupSlotOf(unitToken)
    if not slot then return nil end
    return slot .. "target"
end

local function GroupMemberTargetOf(unitToken)
    if not unitToken then return nil end
    local targetToken = TargetTokenOf(unitToken)
    if not targetToken then return nil end

    local ok, exists = pcall(UnitExists, targetToken)
    if not (ok and exists) then return nil end

    -- You first: it is the answer that matters most and it costs one call.
    if IsSameUnit(targetToken, "player") then return "player" end
    for _, member in ipairs(GroupUnitTokens()) do
        if member ~= "player" and IsSameUnit(targetToken, member) then
            return member
        end
    end
    -- A caster who has an NPC, a pet or a nameplate targeted. Nothing Tattle
    -- watches can be swapped with that, so there is no victim to name.
    return nil
end
Tattle.GroupMemberTargetOf = GroupMemberTargetOf

-- ============================================================================
-- Whom a cast was pointed at
-- ============================================================================
--
-- Every sentence this addon says about a victim rests on this section, so the
-- sources are worth stating exactly.
--
--   1. The client's own cast-target APIs. `PlayerIsSpellTarget(unit)` answers "did
--      this unit's spell land on me", and `UnitSpellTargetName(unit)` names the
--      spell's target behind `UnitShouldDisplaySpellTargetName(unit)`. In the 12.1.5
--      and 12.1.7 docs both value-returning ones carry `SecretReturns = true` - not
--      "during combat", not "inside a dungeon", just: for the general case of
--      somebody else's cast. A name that arrives secret is therefore the ordinary
--      outcome here rather than the exception, and every nil that leaves this section
--      means "this client would not say", never "no".
--   2. The caster's own target, `<caster>target`, read by GroupMemberTargetOf above.
--      That is a fact about the caster's interface, not about the spell: a
--      @mouseover macro leaves the hard target on whoever they last clicked, and a
--      target change mid-channel moves it again. It can name a group member who was
--      never involved, which is worse than naming nobody - so the source of an answer
--      travels with the answer, and no caller may claim more than its source
--      supports.
--   3. Nothing else. Not the combat log, whose entry readers are SecureOnly in
--      12.1.5 and therefore unreadable to an addon; not addon comms, which are
--      spoofable and which document `SecretArguments = "NotAllowed"`, so the one
--      place the answer is guaranteed to live is the griefer's own client.
--
-- Names come back as names, while nearly everything downstream - auras, protection
-- checks, display - works from unit tokens, so the resolution happens once here
-- rather than in each caller.

-- An API looked up at the moment it is called. Several of these were added, renamed
-- or removed across 11.x and 12.x, and "this build does not have it" has to come out
-- as itself rather than as a nil that a caller reads as an answer.
local function ApiNamed(...)
    for i = 1, select("#", ...) do
        local candidate = _G[select(i, ...)]
        if type(candidate) == "function" then return candidate end
    end
    return nil
end

-- A boolean the client actually answered with, or nil when it refused, said nothing,
-- or handed back a secret value that an `if` may not test. type() calls a secret
-- boolean "boolean", so attempting the comparison is the only way to tell them apart.
local function ReadableBool(value)
    if type(value) ~= "boolean" then return nil end
    if not pcall(SelfCompare, value) then return nil end
    return value
end

-- A call that answered, paired with the boolean it answered with - preserving *false* as an
-- answer. Every "did the client say no" question in this file has to keep three outcomes
-- apart (yes / no / would not say), and `ok and ReadableBool(x) or nil` collapses the last
-- two into one, which is how "refused" and "answered no" end up meaning the same thing.
local function BooleanAnswer(callSucceeded, answer)
    if not callSucceeded then return nil end
    return ReadableBool(answer)
end

-- "Did this unit's spell target me?" 12.0.0 added this as `UnitIsSpellTarget` and
-- the 12.1.x docs know only `PlayerIsSpellTarget`; which one a build carries is not
-- something an addon can look up, so both spellings are tried.
local function SpellTargetIsPlayer(unitToken)
    if not unitToken then return nil end
    local api = ApiNamed("PlayerIsSpellTarget", "UnitIsSpellTarget")
    if not api then return nil end
    local ok, answer = pcall(api, unitToken)
    if not ok then return nil end
    return ReadableBool(answer)
end
Tattle.SpellTargetIsPlayer = SpellTargetIsPlayer

-- Whether this client is willing to show the target's name for this unit's cast.
-- The docs put no secrecy flag on this one, which makes it the gate rather than the
-- answer: a false means the name API is not going to help, and asking it first keeps
-- a question that is already known to be refused out of the path.
local function ShouldShowSpellTargetName(unitToken)
    if not unitToken then return nil end
    local api = ApiNamed("UnitShouldDisplaySpellTargetName")
    if not api then return nil end
    local ok, answer = pcall(api, unitToken)
    if not ok then return nil end
    return ReadableBool(answer)
end
Tattle.ShouldShowSpellTargetName = ShouldShowSpellTargetName

-- The name the client puts on this unit's cast, unexamined and on purpose: it may be
-- a secret string, and a caller that wants it has to prove it printable with
-- PlainText or report it as withheld with IsSecretValue. Returning nil here means
-- "there is no name to have", and the two are not interchangeable.
local function SpellTargetName(unitToken)
    if not unitToken then return nil end
    local api = ApiNamed("UnitSpellTargetName")
    if not api then return nil end
    local ok, name = pcall(api, unitToken)
    if not ok then return nil end
    -- A name, or nothing. `UnitSpellTargetName` is documented to return a string, and a
    -- secret string still reports "string" on a real client, so the refusals below are
    -- about nonsense answers rather than about secrecy. Checking for "string" exactly
    -- would be the mistake it looks like: the test harness can only stand in for a
    -- secret string with an object, and demanding the documented type here would mean
    -- the withheld-name path that GroupTokenForName exists to handle never runs in a
    -- test - which in this project has always been how a path reaches beta unexercised.
    local valueType = type(name)
    if valueType == "nil" or valueType == "boolean" or valueType == "number" then return nil end
    return name
end
Tattle.SpellTargetName = SpellTargetName

-- The sanctioned comparison, when this build has one, asked in both argument orders
-- because it is not documented as caring which side is which. A refusal says nothing
-- about whether the names match, so it is reported as no rather than as a miss -
-- which is safe here only because the caller treats "no match for anybody" as "no
-- answer", never as "certainly not this member".
local function ClientSaysSameName(a, b)
    local secretEqual = SecretComparisonApi()
    if not secretEqual then return false end
    -- No type gate. Asking whether two values are secret, or what type they report, is
    -- itself an inspection of a value the addon is not allowed to inspect; the only
    -- move available is to hand them to the client and accept whatever answer or refusal
    -- comes back. A value that is not comparable at all fails inside the pcall below and
    -- is reported as no answer, which is the same outcome and costs nothing.
    if a == nil or b == nil then return false end   -- nil is not a secret and never reaches the client
    -- `BooleanAnswer` rather than `ok and ReadableBool(same) or nil`: the idiom turns the
    -- client's *false* into nil, and here the fallthrough happened to reach the same verdict,
    -- which is the worst kind of correct.
    local answer = BooleanAnswer(pcall(secretEqual, a, b))
    if answer ~= nil then return answer end
    answer = BooleanAnswer(pcall(secretEqual, b, a))
    return answer == true
end

-- A name from a cast-target API resolved to one of this group's unit tokens, or nil.
--
-- A plain name is matched against the printable short names of the group: no realm
-- trimming is needed here because GetUnitShortName already strips it and proves the
-- name printable, and case is folded because the two sides arrive from different
-- APIs. A secret name cannot be printed or compared by an addon at all, so the
-- client is asked about one member at a time; a refusal for one member is that
-- member's answer rather than the whole question's, so the sweep continues.
local function GroupTokenForName(name)
    -- Only nil is refused outright. Whether a value is a string, a secret string, or
    -- something the harness is standing in for one is not a question this addon is
    -- allowed to answer about a value the client hid, and the two branches below each
    -- fail safe: the plain path needs the name to prove itself printable, and the other
    -- hands the value to the client and accepts its answer or its refusal.
    if name == nil then return nil end
    local plain = PlainText(name)
    local lowered = plain and string_lower(plain) or nil
    for _, token in ipairs(GroupUnitTokens()) do
        local memberName = GetUnitShortName(token)
        if lowered then
            if memberName and string_lower(memberName) == lowered then return token end
        else
            -- The name we were given is a secret value. The member's name may be one
            -- too, and asking the client to compare two values it hid from us is
            -- exactly the question it is allowed to refuse; that is why a refusal is
            -- skipped rather than treated as a negative.
            local ok, theirName = pcall(UnitName, token)
            if ok and ClientSaysSameName(name, theirName) then return token end
        end
    end
    return nil
end
Tattle.GroupTokenForName = GroupTokenForName

-- Whom a cast was pointed at: the unit token, and how that was learned.
--
-- The second return is not decoration. "spell-target" is a fact about the spell, so
-- an alert may say the spell arrived; "unit-target" is a fact about the caster's UI,
-- so an alert may say where they were aiming and nothing more. Callers that have
-- only the second are expected to change the sentence, not to deliver the first one
-- with a hedge - hedged accusations are still accusations.
--
-- (nil, nil) means nothing answered, which is a sentence alerts can and do carry: "it
-- landed on" and "there is no evidence" are different claims, and the difference is
-- the whole point.
--
-- A plain group token is passed to these APIs where one can be had, because they
-- document `SecretArguments = "AllowedWhenUntainted"` and an addon's execution is
-- tainted: handing them a secret token is a refusal rather than a question.
local function CastTargetOf(unitToken)
    if not unitToken then return nil, nil end
    local probeToken = GroupSlotOf(unitToken) or unitToken

    -- Yourself first: one call, and the answer a player cares most about.
    if SpellTargetIsPlayer(probeToken) then return "player", "spell-target" end

    if ShouldShowSpellTargetName(probeToken) ~= false then
        local token = GroupTokenForName(SpellTargetName(probeToken))
        if token then return token, "spell-target" end
        -- A name that could not be resolved to a group member stays unresolved. It is
        -- not turned into a token by guessing, and not printed as "somebody".
    end

    local target = GroupMemberTargetOf(unitToken)
    if target then return target, "unit-target" end
    return nil, nil
end
Tattle.CastTargetOf = CastTargetOf

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

-- A value this addon may act on: the client answered, and what it answered with is
-- something we are allowed to test. Presence of an aura arrives as an aura token or aura
-- info, and a hidden one arrives as a value that reports a type and refuses everything else.
-- Treating "there is a value here I may not read" as "they have the buff" names a person on
-- evidence that cannot be examined, so it is reported as no answer instead.
--
-- Deliberately not `value == value`, which is what this file's IsSecretValue does and why
-- that one has always had to lean on its type test rather than be trusted alone: a Lua VM
-- answers a value compared with *itself* without consulting anything, so the identity test
-- reports a hidden value as readable. Asked of the client where the build has the sanctioned
-- predicate, and otherwise by attempting the one operation that must fail for anything
-- hidden - turning it into a string, which is exactly the thing an addon is not allowed to do
-- with a name it was not given.
local function CanAccessValueApi()
    local predicate = canaccessvalue
    if type(predicate) ~= "function" then return nil end
    return predicate
end

local function ValueIsReadable(value)
    if value == nil then return false end
    local canAccessValue = CanAccessValueApi()
    if canAccessValue then
        local ok, answer = pcall(canAccessValue, value)
        if ok and type(answer) == "boolean" then
            -- The predicate's answer is only usable if it is a *plain* boolean, which is
            -- what the comparison below is for: comparing a secret boolean raises, so
            -- reaching the return means the answer can be trusted. Written as
            -- `(pcall(...)) and answer or nil` it looked equivalent and was not - a predicate
            -- that answered "this value is not readable" produced `true and false or nil`,
            -- which is nil, so the client's *refusal* was thrown away and the stringification
            -- fallback underneath answered instead. That is this file's own documented trap,
            -- in the function whose whole job is telling a refusal from an answer, and it made
            -- a hidden aura count as a protected member. Caught by the harness only once two
            -- secrecy surfaces were made to disagree with each other.
            if pcall(function() return answer == true end) then return answer == true end
        end
    end
    return (pcall(tostring, value)) ~= false
end

-- Was this member's aura list answered at all, and if it was, does it hold one of
-- nameSet's spells? Two answers rather than one, because "no" and "we may not look" are
-- different facts and the watch list has to be able to tell them apart. A call that raises
-- is a refusal; a call that returns nothing is a real "no".
-- The reader is fetched through a nil-safe lookup, which is not what the call below looks
-- like: `pcall(C_UnitAuras.GetAuraDataBySpellName, ...)` protects the *call*, but indexing
-- `C_UnitAuras` to get the function happens while building the argument list, outside any
-- protection - so a build without that namespace raises before `pcall` ever runs. Same for
-- a namespace that appears later in a session. `C_UnitAuras` is inside the interface range
-- this addon's TOC declares, so this is not a live-risk fix; it is what lets a check take
-- the aura reader away and confirm that every member comes back *unanswered* - "hidden by
-- the client" - instead of "nobody protected".
local function AuraReaderApi()
    -- `_G`, not this file's `local C_UnitAuras` upvalue: an upvalue is a load-time capture
    -- by another name, and the point of this lookup is that a check can take the namespace
    -- away mid-session and watch the answers change to "nobody answered".
    local namespace = _G.C_UnitAuras
    local reader = namespace and namespace.GetAuraDataBySpellName
    if type(reader) ~= "function" then return nil end
    return reader
end

local function AuraReadOutcome(unitToken, nameSet, auraFilter)
    local answered, has = false, false
    if not unitToken or not nameSet then return false, false end
    local reader = AuraReaderApi()
    if not reader then return false, false end   -- not "no aura": nobody answered
    for spellName in pairs(nameSet) do
        local ok, aura = pcall(reader, unitToken, spellName, auraFilter or "HELPFUL")
        if not ok then
            -- Refused outright. Not this member's answer, so nothing is recorded either way
            -- and the caller sees `answered == false`.
        elseif aura == nil then
            answered = true                       -- an ordinary "no such aura"
        elseif ValueIsReadable(aura) then
            answered, has = true, true            -- an ordinary "yes, this one"
        else
            -- A value that exists and may not be read. The client is saying there is
            -- something here without saying what, which is a refusal wearing different
            -- clothes: counting it as a wearer names a person on an unreadable signal, and
            -- counting it as an answer turns "we were not told" into "they are unprotected".
        end
    end
    return answered, has
end

-- True when unitToken carries an aura whose spell name is in nameSet, and only when the
-- client said so. 12.0.0 hid other players' auras; 12.1.0 relaxed that again out of combat;
-- this is the route left for naming a cast's destination now that the combat log is gone.
-- A refusal reads as "does not have it" here, which is the conservative half of a pair -
-- the other half is AuraCarrierSplit, which is what any sentence that *counts* people uses.
local function UnitHasAnyAura(unitToken, nameSet, auraFilter)
    local answered, has = AuraReadOutcome(unitToken, nameSet, auraFilter)
    if answered and has then return true end
    return false
end
Tattle.UnitHasAnyAura = UnitHasAnyAura

-- Who carries nameSet, and which members this client would not tell us about.
--
-- The second list is the one a restricted instance fills. Callers that announce a count or
-- a list - the Silencer watch list above all, since it is a standing statement about the
-- whole group - have to say "we were not told" when it is non-empty. Printing "nobody" over
-- a wall of refusals is a watch list telling lies, and it is the specific way this addon
-- could make a protected raid look unprotected to the people trying to spot a griefer.
local function AuraCarrierSplit(nameSet, auraFilter, excludeToken)
    local carriers, hidden = {}, {}
    for _, token in ipairs(GroupUnitTokens()) do
        if not IsSameUnit(token, excludeToken) then
            local answered, has = AuraReadOutcome(token, nameSet, auraFilter)
            if answered then
                if has then carriers[#carriers + 1] = token end
            else
                hidden[#hidden + 1] = token
            end
        end
    end
    return carriers, hidden
end
Tattle.AuraCarrierSplit = AuraCarrierSplit

-- Which group members currently carry one of nameSet's auras, as unit tokens.
-- excludeToken drops the caster, whose own aura would otherwise look like a
-- target (Rescue marks both the Evoker and the passenger with the same name).
local function AuraCarriers(nameSet, auraFilter, excludeToken)
    local carriers = AuraCarrierSplit(nameSet, auraFilter, excludeToken)
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

-- One group member, named the way an alert names anybody: "you" for yourself, so
-- an alert about you reads "Donut used Swapblaster on you" rather than using the
-- name your client reports for your own unit.
local function UnitDisplayName(unitToken)
    if not unitToken then return nil end
    if IsYou(unitToken) then return "you" end
    return GetUnitShortName(unitToken)
end
Tattle.UnitDisplayName = UnitDisplayName

-- The word an alert uses for whoever cast something: their name, or "someone"
-- when the client will not name them. Not UnitDisplayName - an alert about your own
-- cast names you the way it names anybody else, and "you" is reserved for the side
-- of the move being described. The fallback is what restricted content needs: there
-- UnitName answers with a secret value this addon may not print, and a cast that is
-- really happening should still be reported rather than swallowed because the
-- client would not say who fired it.
local function CasterLabel(unitToken)
    return GetUnitShortName(unitToken) or "someone"
end
Tattle.CasterLabel = CasterLabel

-- "you" / "Donut" / "Donut and Pancakes", for the "used X on Y" alerts.
local function TargetPhrase(carrierTokens)
    local names = {}
    for i, token in ipairs(carrierTokens) do
        names[i] = UnitDisplayName(token) or "someone"
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

-- "Donut is" / "you are" / "Donut and Pancakes are".
local function SilencerSubject(names)
    if #names == 0 then return nil end
    if #names > 1 then return FormatList(names) .. " are" end
    if names[1] == "you" then return "you are" end
    return names[1] .. " is"
end

-- " (Pancakes is using a Neural Silencer)" -- "" in every other case, including
-- "there is no target to ask about" and "this target is not protected".
--
-- This replaces " (Neural Silencer worn by Donut, Pancakes)", which was built by
-- sweeping the group and was therefore appended to *every* Swapblaster, Life Grip and
-- Rescue alert for as long as exactly one member was protected. The beta report was
-- right: that is a statement about a bystander stapled to a sentence about somebody
-- else. A Neural Silencer is named in an alert now only because the target of the
-- cast being described has one, which is the only claim these events support -- and
-- that is why the question is put to one unit token rather than to the raid.
--
-- "" is also the answer when the target could not be read, and every caller keeps its
-- old wording on hearing it: "your client was not told" is not licence to name the
-- protected member who happens to be standing nearby.
local function SilencerTargetClause(unitToken)
    if not IsSilencerWearer(unitToken) then return "" end
    local names = { UnitDisplayName(unitToken) or "someone" }
    return string_format(" (%s using a Neural Silencer)", SilencerSubject(names))
end
Tattle.SilencerTargetClause = SilencerTargetClause

-- "Pancakes attempted a Life Grip on Donut, but it failed because Donut is
-- using a Neural Silencer", or nil when nothing about *this cast* points at a
-- silencer (so callers keep their normal wording).
--
-- targetTokens are the victims the calling module can put forward. One of them is
-- named only when its own aura says it is protected. The group's wearer list is no
-- longer a fallback here, for the reason given on SilencerTargetClause: with no
-- target read, "Donut is protected" is a fact about the raid and not a fact about
-- the cast, and it was being said as if it were the second.
--
-- `proven` is the one exception, and exactly one event earns it: the Swapblaster's
-- backfire, which nothing except a protected target causes. There the group's wearers
-- genuinely are the candidate list, because a protected player is the only kind of
-- player one of these spells bounces off. Naming one of them is safe when there is
-- only one; with several the alert says "a protected group member" rather than
-- guessing.
local function BlockedBySilencer(casterName, action, targetTokens, excludeToken, proven)
    if not casterName or not KnowsSilencers() then return nil end

    local protectedNames = {}
    for _, token in ipairs(targetTokens or {}) do
        if IsSilencerWearer(token) then
            protectedNames[#protectedNames + 1] =
                IsYou(token) and "you" or (GetUnitShortName(token) or "someone")
        end
    end

    if #protectedNames > 0 then
        return string_format("%s attempted a %s on %s, but it failed because %s using a Neural Silencer",
            casterName, action, FormatList(protectedNames), SilencerSubject(protectedNames))
    end

    -- Nothing about this cast says a silencer was involved, so nothing goes in the
    -- sentence. This is the branch the beta report was about.
    if not proven then return nil end

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

-- ---------------------------------------------------------------------------
-- Idle while you fight
-- ---------------------------------------------------------------------------
--
-- Everything Tattle watches is an out-of-combat act: the Swapblaster cannot be
-- used in combat at all, and the alerts exist to tell a group that somebody is
-- griefing them in a city, a mining node or a resting pull. So while *you* are
-- fighting the addon does nothing: no module is woken, no alert is sent, no
-- problem is reported. What it does not do is decide on your behalf that a fight
-- you are in is uninteresting one cast at a time.
--
-- This is a separate rule from a module's `outOfCombat` policy, which asks about
-- the *caster*: you can be standing still while a group member is fighting, and a
-- caster who is fighting cannot be griefing anybody.
--
-- One consequence worth stating, because it is a behaviour the modules used to keep
-- deliberately: a swap that *began* out of combat and lands after this player is
-- fighting is no longer announced. Swapblaster's `outOfCombat = "start"` policy exists
-- precisely to keep that alert (landing a swap next to a pack is a way to start a fight,
-- and the completion event can arrive after combat did). It still applies to the caster;
-- this player's combat state now overrides it. The alternative is a per-cast latch - a
-- cast accepted while out of combat keeps its alerts after the pull - which is a
-- different reading of "nothing while in combat" than the one implemented here, and the
-- trade is in the harness check "nothing is announced while you are fighting".
--
-- Kept as a cached flag updated by PLAYER_REGEN_DISABLED/ENABLED rather than
-- asked per event: the dispatcher runs for every cast event the raid produces,
-- and a boolean it already knows is cheaper than a client call it does not need.
-- The flag has to be seeded, because those two events only fire on a transition -
-- loading the UI already inside combat would otherwise leave it saying "not
-- fighting" for the rest of the session.
local iAmInCombat = nil      -- nil until first read: never guess in either direction

local function RefreshOwnCombatState()
    iAmInCombat = UnitInCombat("player")
end

local function IAmInCombat()
    if iAmInCombat == nil then RefreshOwnCombatState() end
    return iAmInCombat == true
end
Tattle.IAmInCombat = IAmInCombat

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
        -- Only plain names can be stored as keys, and every name a module builds
        -- from its own public spell IDs is plain. A name that is not is reported
        -- rather than stored, because a secret key would raise here.
        local plain = PlainText(name)
        if plain then watchedSpellNames[plain] = true end
    end
end
Tattle.WatchSpellNames = WatchSpellNames

-- The name a spell ID reports, exactly as the client reports it -- which in
-- restricted content means a *secret* name, safe to hand to another API and not safe
-- to inspect. Nothing here may look at the answer: no `~= ""`, no `#name`, no
-- tostring, and no filtering it down to "a string we can see", because dropping a
-- name the matcher could still have asked about is how the feature goes silent in
-- the exact content the feature is for. Whether the name may be used is the
-- matcher's question, asked in NameMatches.
local function FieldOf(object, key) return object[key] end

local function ResolveSpellName(spellID)
    if type(spellID) == "nil" then return nil end

    -- A plain string with no table to allocate; GetSpellInfo is the fallback for a
    -- client without it. Both accept a secret spell ID and hand back a name, and a
    -- name derived from a secret ID is itself secret.
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        if ok and type(name) ~= "nil" then return name end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        if ok and type(info) ~= "nil" then
            -- Reading the field is an index into the table the client handed back,
            -- which is allowed; the *value* in it may still be secret, which the
            -- matcher below has to be ready for.
            local ok2, name = pcall(FieldOf, info, "name")
            if ok2 and type(name) ~= "nil" then return name end
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
-- IDs is what survives a spell being renumbered by a patch -- but it only works
-- when both sides can be compared, which is what the matching below is for.
-- An ID the client does not know is named in the debug log instead of being
-- silently unwatched.
function Tattle.ResolveSpellNames(nameSet, spellIDs)
    for _, id in ipairs(spellIDs or {}) do
        local name = ResolveSpellName(id)
        local plain = PlainText(name)
        if plain then
            nameSet[plain] = true
            DebugPrint("  watching", plain, "(" .. tostring(id) .. ")")
        elseif type(name) ~= "nil" then
            -- A name this addon cannot store as a key is a spell it cannot watch
            -- by name. Loud, because it means a shipped spell ID stopped being a
            -- plain value and every alert for it is dead.
            --
            -- `type()`, not `elseif name`: a value this addon is not allowed to read
            -- may still be a value it is not allowed to test for truthiness, and a
            -- report that raises while building its own message is a bad trade.
            Tattle.ReportProblem("a spell name could not be read from spell ID " .. tostring(id),
                "the client returned a value this addon is not allowed to store")
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
-- Secret-safe: the name is matched by indexing when it is plain and through the
-- client when it is not.
function Tattle.MakeSpellMatcher(nameSet)
    return function(spellName, spellID)
        local hit = NameMatches(nameSet, spellName)
        if hit ~= nil then return hit end
        if not spellID then return false end
        -- An unanswered question answers false here, which is the right place for
        -- it: the dispatcher is what reports the refusal, so a module never has to
        -- tell "not ours" apart from "not allowed to say".
        return NameMatches(nameSet, ResolveSpellName(spellID)) == true
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

-- Whether this client currently refuses to let an addon's chat messages out. Documented
-- on `C_ChatInfo.InChatMessagingLockdown` as "Returns true if API security restrictions
-- regarding chat messaging are in effect" - a plain boolean, available in every
-- environment, which matters because the scenario it fires in is the one this addon
-- exists for: a restricted raid or key, where a griefer's casts land and where a chat
-- alert is most wanted.
--
-- An absent API or a refused call answers "not restricted", deliberately the permissive
-- side: this gate only decides whether to attempt a send the client may refuse. The
-- check that holds safety is the printability check below, and that one does not depend
-- on any API existing.
local function ChatMessagingRestricted()
    local api = (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown) or nil
    if type(api) ~= "function" then return false end
    local ok, answer = pcall(api)
    if not ok then return false end
    return ReadableBool(answer) == true
end
Tattle.ChatMessagingRestricted = ChatMessagingRestricted

-- The alert API: route one sentence to the channels this module has switched
-- on. A module speaking *about a cast* goes through AlertForCast below instead, which
-- is what decides the sound question; nothing in the shipped modules calls this one
-- directly any more.
--
-- `opts` is optional and currently carries one thing: `sound = false`, meaning
-- "this sentence is about a cast the player has already been heard about".
--
-- The audio alert is the part of an alert that interrupts, and one cast used to make
-- it two or three times: the start, then the landing, then the failure wording for the
-- same Swapblaster. A player with a protected member in the raid heard it on every
-- alert of that kind all evening. The sound belongs to a cast's first alert; the
-- follow-ups are for reading. See AlertForCast, which is what decides that.
local function SendAlert(message, moduleId, opts)
    if not TattleDB or not TattleDB.enabled then return end
    if not IsGrouped() then return end

    local moduleSettings = TattleDB.modules[moduleId]
    if not moduleSettings or not moduleSettings.enabled then return end

    local alerts = moduleSettings.alerts
    if not alerts then return end

    DebugPrint("Alert:", message)

    -- Debug means "show me everything", so it prints for every module whether or not
    -- that module's own Console output box is ticked. With debug off this is the
    -- addon's debugging line, and it stays off unless somebody asks for it: the alert
    -- a player asked for is the on-screen warning, and the chat line if they switched
    -- that on too.
    if TattleDB.debug or alerts.console then
        print(string_format("|cffff6600[Tattle]|r %s", message))
    end

    -- chatType "PRIVATE" means no chat at all: the console block above may or may not
    -- have printed the line, depending on debug and that module's Console output, and
    -- that is the honest answer -- the dropdown calls this option "None" for the same
    -- reason. A module with only this switched on alerts nobody but whoever is
    -- watching their own chat window with debug on.
    local channel = ResolveChatChannel(alerts.chatType or "PRIVATE")
    if alerts.chat and channel ~= "PRIVATE" then
        if ChatMessagingRestricted() then
            -- Do not attempt a send this client has said it will refuse. The screen
            -- warning below is untouched: what gets locked down is chat traffic, not the
            -- player's own interface - and the alert a restricted key most needs is the
            -- one that never leaves the machine. Silence here is the client's decision
            -- about the channel, not the addon deciding the alert was unimportant.
            DebugPrint("Chat suppressed: client has chat messaging locked down")
        elseif not PlainText(message) then
            -- The one gate that does not ask permission. A message carrying something the
            -- client will not let an addon print - typically a target name it handed over
            -- as a secret value - is not a message to push at whoever else is reading that
            -- channel. Console and screen may still carry it for the player alone.
            DebugPrint("Chat suppressed: message holds a value the client hides")
        else
            C_Timer.After(0.1, function()
                local ok, err = pcall(SendChatMessage, message, channel)
                if not ok then DebugPrint("Chat send failed:", err) end
            end)
        end
    end

    if alerts.audio and alerts.audioFile and not (opts and opts.sound == false) then
        local ok, err = pcall(PlaySound, alerts.audioFile)
        if not ok then DebugPrint("Sound failed:", err) end
    end

    if alerts.screen and Tattle.ScreenAlert then
        local ok, err = pcall(Tattle.ScreenAlert.Show, Tattle.ScreenAlert, message)
        if not ok then DebugPrint("Screen alert failed:", err) end
    end
end
Tattle.SendAlert = SendAlert

-- Send one alert about one cast, and make a noise only if this is the first alert
-- that cast has produced. `cast` is the calling module's own record for the cast --
-- any table it already keeps -- and this files the fact that it spoke on it, which is
-- why the record has to outlive the event that made it (see the cast bookkeeping in
-- Modules/Swapblaster.lua). `nil` means the module has no record to speak for, so
-- this alert is all the player gets and it is allowed to be loud.
--
-- Keying on "has this cast already been announced" rather than on the event kind is
-- deliberate. Neither Life Grip nor Rescue has a cast time, so for those the landing
-- *is* the first alert and should sound; a Swapblaster that only ever reached us as a
-- completion is in the same position. The two channeled halves of one swap, or a
-- start and its failure, are not.
local function AlertForCast(cast, message, moduleId)
    local first = not (cast and cast.alerted)
    if cast then cast.alerted = true end
    SendAlert(message, moduleId, { sound = first })
end
Tattle.AlertForCast = AlertForCast

-- ============================================================================
-- OnEvent
-- ============================================================================

local addonReady = false

-- Module callbacks are isolated: one module erroring must not stop the others
-- that listen for the same event.
local function CallModule(module, moduleId, event, ...)
    local ok, err = pcall(module.onEvent, event, ...)
    if not ok then
        -- Reported rather than debug-printed. Until now a module that threw on
        -- every single cast was indistinguishable from a module with nothing to
        -- say, because the error only reached chat when /tattle debug happened to
        -- be on -- which is exactly how "no Swapblaster alerts in my M+ key" was
        -- readable as "the gate decided not to fire".
        Tattle.ReportProblem(string_format("module %s failed on %s", moduleId, event), err)
    end
end

Tattle.eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED"
        or event == "PLAYER_ENTERING_WORLD" then
        -- Before everything else, like the group caches: whether the addon is
        -- allowed to act at all is not something a module gets to veto, and
        -- PLAYER_ENTERING_WORLD is the re-read that catches a combat state carried
        -- across a login, a /reload or a realm hop.
        RefreshOwnCombatState()
    end

    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName ~= ADDON_NAME then return end

        InitializeSettings()

        -- moduleOrder, not pairs(): this loop decides the order modules get to
        -- initialize, and RebuildModuleListeners uses the same order for the
        -- listeners, so pairs() cannot reshuffle either between sessions. No
        -- module reads another's initialize() output today -- that is luck, not
        -- design -- but TOC order is at least a defined order to have luck in.
        -- Guarded like a module's event handler, and for the same reason plus one:
        -- a module that throws here used to abort this loop, so every module after
        -- it in TOC order, the listener lists, the config tabs and the load line
        -- were all simply gone, with one taint line as the whole notice. An
        -- uninitialised module is a dead feature; an aborted handler is the addon.
        for _, moduleId in ipairs(Tattle.moduleOrder) do
            InitializeModuleSettings(moduleId)
            local module = Tattle.modules[moduleId]
            if module.initialize then
                local ok, err = pcall(module.initialize)
                if not ok then
                    Tattle.ReportProblem(string_format("module %s failed to initialize", moduleId), err)
                end
            end
        end

        -- Combat state only announces transitions, so it has to be read once here:
        -- a UI loaded (or reloaded) mid-fight would otherwise believe itself idle
        -- until the fight ended and began again.
        RefreshOwnCombatState()

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
    if IAmInCombat() then return end   -- you are fighting: this addon says nothing
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
    local casterToken, spellName
    if CAST_EVENTS[event] then
        if not eventAcceptsAnyCaster[event] and not IsGroupMemberToken(arg1) then return end
        spellName = ResolveSpellName(arg3)
        -- Asked through type() rather than `if not spellName`, because testing a
        -- secret value for truthiness is itself an operation on it. An ID this client
        -- has no name for is ordinary - a hidden spell, a cast from a toy Tattle does
        -- not follow - and is dropped without a word.
        if type(spellName) == "nil" then return end
        local matched = NameMatches(watchedSpellNames, spellName)
        if matched == nil then
            -- The client named the cast and then refused to say whether it was one
            -- of ours: the name descends from a secret spell ID, and this build has
            -- no comparison API to ask with. That silence is the addon being denied,
            -- not the addon deciding, and a player cannot tell the two apart without
            -- being told. It is reported once and counted after that.
            Tattle.ReportProblem(
                "the client would not say whether a cast was one Tattle watches",
                "restricted content on this build, and C_SecretComparisons is unavailable")
            return
        end
        if not matched then return end
        -- Only now, for a cast worth announcing, is the caster resolved to one of
        -- this addon's own tokens: it turns a secret caster into a printable, storable
        -- key, and folds the two tokens a raid client can report one cast under into
        -- a single identity for the modules' per-cast bookkeeping.
        --
        -- A group member this addon cannot place is reported and dropped rather than
        -- passed through as the client's own token. Modules key their per-cast state
        -- on this value, so handing them an unresolved token means handing them a
        -- value that may be secret -- and a secret value used as a table key raises.
        -- The only module allowed to receive an unplaceable caster is one that opted
        -- out of the group filter (`allCasters`), which is asking about pets, minions
        -- and nameplates: those tokens are plain strings by construction, and there is
        -- no group slot for them to resolve to in the first place.
        local slot = GroupSlotOf(arg1)
        if not slot and not eventAcceptsAnyCaster[event] then
            Tattle.ReportProblem(
                "a group member's cast could not be placed in the group",
                "the client said this caster is one of ours and then would not say which one")
            return
        end
        casterToken = slot or arg1
    end
    local dispatchToken = casterToken or arg1

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
                    if casterInCombat == nil then casterInCombat = UnitInCombat(dispatchToken) end
                    drop = casterInCombat
                end

                if drop then
                    DebugPrint("Skipping", moduleId, "- its caster is in combat")
                else
                    CallModule(module, moduleId, event, dispatchToken, arg2, arg3, spellName)
                end
            end
        end
    end
end)
