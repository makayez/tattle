-- Modules/Swapblaster.lua - the toy that trades your position with a group
-- member, fired at someone who was not asking. Out of combat only, which is the
-- whole point: it cannot be used in a fight, so a swap is a decision.

local _, Tattle = ...

local string_format = string.format
local pcall = pcall   -- every cast-window read goes through it
local ipairs = ipairs
local type = type
local GetTime = GetTime
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo

local MODULE_ID          = "swapblaster"
local MODULE_NAME        = "Swapblaster Detector"
local MODULE_DESCRIPTION = "Alerts when a group member fires the Swapblaster toy"

-- Verified against the live 12.1.5 spell database (wowhead.com/spell=161399).
-- The item is "Swapblaster" (item 111820); the cast it triggers is a spell
-- actually named "Swap" (161399): 40 yd range, 1.5 sec cast, channeled,
-- "Swaps your location with another party member. Cannot be used in combat."
-- Do not confuse it with 162217 (the 2 sec *crafting* spell) or 182081
-- ("Swapblaster Explosion", the backfire you eat if the target was wearing a
-- Neural Silencer).
-- Midnight 12.0+ makes the spellID argument of UNIT_SPELLCAST_* a "secret value"
-- in restricted contexts: it cannot index a table or be compared with ==. So the
-- IDs below are resolved to spell names once, at initialize, and every comparison
-- this module makes is against a name the core handed it.
local SWAPBLASTER_SPELL_IDS = {
    161399,
}

-- The backfire a caster eats when the Swapblaster's target was protected. It is
-- the only event that says "a Swapblaster was fired and did nothing", and since
-- the swap itself marks nobody it is also the only chance to call an attempt
-- what it was. Verified against the live 12.1.5 database (wowhead.com/
-- spell=182081). Not user-editable: it is a signal, not a watched cast.
local BACKFIRE_SPELL_IDS = {
    182081,
}

-- Both name sets are filled at initialize (see Initialize below). The Neural
-- Silencer half of the wording is shared: Modules/Silencer.lua owns those spell
-- IDs and fills Tattle.silencerNames, and every module reads the result.
local swapNames = {}    -- populated in Initialize
local backfireNames = {}  -- populated in Initialize

-- Built in Initialize from the name sets above.
local isSwap, isBackfire

-- Cast state keyed on unitToken (a plain string, always safe).
local activeCasts = {}

-- How long a settled record keeps suppressing its cast's other terminal events.
-- The events for one cast arrive within a second or two of each other; anything
-- later than this from the same unit belongs to a different cast, and must not be
-- silenced by the tombstone the first one left behind.
local RESOLVED_TTL = 8

-- A record whose cast is over and whose TTL has run out. Without this the record
-- is a permanent mute: a caster who fires twice, in a pattern where the second
-- cast's start never reaches us (out of range, a /reload mid-channel, a client
-- that reports only the completion), would be announced once ever.
local function IsStale(cast)
    return cast.resolved and cast.resolvedAt ~= nil
        and (GetTime() - cast.resolvedAt) > RESOLVED_TTL
end

-- Settles a record so the other half of the same cast cannot announce it twice.
local function Resolve(cast)
    cast.resolved = true
    cast.resolvedAt = GetTime()
end

-- ============================================================================
-- Helpers
-- ============================================================================

-- The core owns the sentence; this module only ever has the list in hand already.
local SilencerNote = Tattle.SilencerNoteList

-- Swap is channeled, so its cast window comes from UnitChannelInfo; a plain cast
-- window comes from UnitCastingInfo. Both return
-- (name, text, texture, startTime, endTime, ...). nil is fine -- an instant
-- spell or a restricted API call -- and just means "cannot tell".
local function CastWindowSeconds(unitToken, channelled)
    local getter = channelled and UnitChannelInfo or UnitCastingInfo
    if not getter then return nil end
    local ok, _, _, _, startTime, endTime = pcall(getter, unitToken)
    if ok and type(startTime) == "number" and type(endTime) == "number" then
        return endTime - startTime
    end
    return nil
end

-- A channeled cast that stopped early was cut short, not completed. Without a
-- known window we cannot tell, and the caller says so plainly instead of
-- guessing.
-- " on Pancakes" / " at you" / "". The empty string is the honest answer on a
-- client that was not told other players' targets: the sentence then reads exactly
-- as it did before the victim was knowable at all. Two forms because a cast start
-- describes where the toy was pointed and a completion says the swap happened;
-- both name the same group member, read once when the cast was armed.
local function VictimPhrase(cast, preposition)
    local who = cast and Tattle.UnitDisplayName(cast.victim)
    if not who then return "" end
    return " " .. preposition .. " " .. who
end

local function AimPhrase(cast)     return VictimPhrase(cast, "at") end
local function OnPhrase(cast)      return VictimPhrase(cast, "on") end

local function FinishedAsExpected(cast)
    if not cast.duration then return nil end
    return (GetTime() - cast.startedAt) >= (cast.duration - 0.35)
end

-- ============================================================================
-- Cast bookkeeping
-- ============================================================================

-- Both event families describe the same 1.5 s cast: a channeled spell can reach
-- us as CHANNEL_START/CHANNEL_STOP, as START/SUCCEEDED, or as both. A record is
-- armed by either start event and resolved by whichever terminal event lands
-- first, so one cast is never announced twice.
local function ArmCast(unitToken, channelled)
    local existing = activeCasts[unitToken]
    if existing and not existing.resolved then return nil end

    activeCasts[unitToken] = {
        -- Recorded now, on purpose: every alert this cast produces describes the
        -- group as it was when the swap was fired, and one sweep per cast is
        -- cheaper than one per message.
        wearers   = Tattle.SilencerWearerNames(),
        -- Also now, and for a different reason: the toy swaps you with whoever you
        -- have targeted, so at this instant the caster's target *is* the other
        -- half of the swap. Read once here rather than at every message, because a
        -- caster who retargets two seconds later is not griefing somebody else.
        victim    = Tattle.GroupMemberTargetOf(unitToken),
        startedAt = GetTime(),
        duration  = CastWindowSeconds(unitToken, channelled),
        resolved  = false,
    }
    return activeCasts[unitToken]
end

-- Claims a cast for a terminal event. Returns nil when that cast has already
-- been reported. A cast with no record at all still gets claimed so a spell we
-- only ever see the completion of is not dropped.
local function ClaimCast(unitToken)
    local cast = activeCasts[unitToken]
    if cast and not IsStale(cast) then
        if cast.resolved then return nil end
        Resolve(cast)
        return cast
    end

    -- A cast with no record gets one now, and the target is read here too: it is
    -- weaker evidence than the read taken when the cast started (the caster may
    -- have moved on), but "we never heard the start" is not a reason to name
    -- nobody. The wearer list stays empty -- a sweep at this point would describe
    -- a group that had already reacted to the swap.
    activeCasts[unitToken] = {
        wearers   = {},
        victim    = Tattle.GroupMemberTargetOf(unitToken),
        startedAt = GetTime(),
        duration  = nil,
        resolved  = true,
        resolvedAt = GetTime(),
    }
    return activeCasts[unitToken]
end

-- ============================================================================
-- Event Handler
-- ============================================================================

-- A completed swap. When the caster is the protected one, that is the story worth
-- telling: they fired a movement toy at someone who cannot answer in kind, and the
-- generic "worn by" note is dropped because the clause already names the wearer.
--
-- The cheat check is asked first because it is one aura lookup on one unit, where
-- the fallback is a sweep of every member. Computing the wearer list up front and
-- passing it in would pay for the sweep on the branch that throws it away.
--
-- Never reached for a cast that *began* in combat: the core's "start" policy
-- dropped that start, so the only completion that gets here belongs to a swap
-- that started out of combat.
local function CompletionMessage(sourceName, unitToken, cast)
    local on = OnPhrase(cast)
    if not Tattle.UnitInCombat(unitToken) then
        local clause = Tattle.SilencerCheatClause(unitToken, sourceName)
        if clause then
            -- The clause already names the protected wearer, so the generic "worn
            -- by" note stays off this sentence.
            return string_format("%s used Swapblaster%s%s", sourceName, on, clause)
        end
    end
    return string_format("%s used Swapblaster%s%s",
        sourceName, on, SilencerNote(Tattle.SilencerWearerNames()))
end

-- "Swapblaster Explosion" is what the caster eats when the player they tried to
-- swap with was protected. It is the one event that says "a Swapblaster was fired
-- and did nothing", and because the swap itself marks nobody it is the only
-- chance to call a blocked attempt what it was. The victim still cannot be named,
-- but a backfire can only be caused by a protected player, so the group's
-- Neural Silencer wearers are the candidate list.
local function HandleBackfire(unitToken, sourceName)
    if not sourceName then return end

    -- Whichever half of the cast we hear about last must not announce it twice --
    -- unless the record is a stale one, in which case this backfire belongs to a
    -- later cast and deserves its own alert.
    local cast = activeCasts[unitToken]
    if cast and not IsStale(cast) then
        if cast.resolved then return end
        Resolve(cast)
    end

    -- The read is fresh rather than the one stored on the cast record: the backfire
    -- is its own spell and can be the first thing we hear about. Passing it as the
    -- victim list is safe rather than presumptuous -- BlockedBySilencer only names a
    -- victim it can confirm is protected, and falls back to the group's wearer list
    -- when the read is empty or lands on somebody without the buff.
    local victim = Tattle.GroupMemberTargetOf(unitToken)
    local message = Tattle.BlockedBySilencer(sourceName, "Swapblaster",
        victim and { victim } or nil, unitToken)
        or string_format("%s's Swapblaster%s backfired", sourceName, OnPhrase({ victim = victim }))
    Tattle.SendAlert(message, MODULE_ID)
    Tattle.DebugPrint("Swapblaster backfire:", sourceName)
end

-- Swap applies no aura to either side, so the swap itself cannot be attributed the
-- way Life Grip and Rescue can: the destination lived only in the combat log, and
-- 12.0.0 removed it. What is left is the caster's own target, which the toy
-- requires ("Swaps your location with another party member") and which the client
-- exposes as `<caster>target` when it exposes it at all. So the alerts name the
-- victim when your client was told who the caster had targeted, and say nothing
-- about the victim when it was not -- they never guess, and never claim the swap
-- landed on somebody the caster was not looking at.
local function OnEvent(event, unitToken, castGUID, spellID, spellName)
    -- A guard, not the primary filter: the dispatcher has already dropped casts
    -- by anyone who is not one of your group's players. It stays because that
    -- filter is per-event, and another module's `allCasters` flag would widen the
    -- same event for everybody.
    if not Tattle.IsGroupMemberToken(unitToken) then return end

    local backfire = isBackfire(spellName, spellID)
    if not backfire and not isSwap(spellName, spellID) then return end

    local sourceName = Tattle.GetUnitShortName(unitToken)

    -- The backfire is a different spell from the cast, so it is settled here,
    -- before the scope filter that governs the cast itself: it is worth reporting
    -- whoever fired it, and it has no visible victim to filter on.
    if backfire then
        HandleBackfire(unitToken, sourceName)
        return
    end

    -- Scope "self" only drops casts we can prove missed you. The target read is
    -- deliberately NOT fed to that decision: it is strong evidence of intent and
    -- good enough to put a name in a sentence, but suppressing an alert on it would
    -- mean a swap you never saw coming goes unreported because the caster's target
    -- field was momentarily somewhere else. So a Swapblaster aimed at a friend is
    -- still reported to someone watching only for themselves.
    if Tattle.ScopeDrops(MODULE_ID, unitToken) then return end

    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        local cast = ArmCast(unitToken, event == "UNIT_SPELLCAST_CHANNEL_START")
        if not cast then return end

        local note = SilencerNote(cast.wearers)
        Tattle.SendAlert(string_format("%s is casting Swapblaster%s%s",
            sourceName, AimPhrase(cast), note), MODULE_ID)
        Tattle.DebugPrint("Swapblaster START:", sourceName, note)

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local claimed = ClaimCast(unitToken)
        if not claimed then return end

        Tattle.SendAlert(CompletionMessage(sourceName, unitToken, claimed), MODULE_ID)
        Tattle.DebugPrint("Swapblaster SUCCESS:", sourceName)

    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local cast = activeCasts[unitToken]
        if not cast or (cast.resolved and not IsStale(cast)) then return end
        Resolve(cast)

        local finished = FinishedAsExpected(cast)

        if finished == true then
            Tattle.SendAlert(CompletionMessage(sourceName, unitToken, cast), MODULE_ID)
        else
            -- "cut short" when the channel clearly stopped early, and a plainer
            -- "cast ended" when there was no window to measure against. The wearers
            -- are the ones recorded when the channel started, same as the other
            -- alerts for this cast - no second sweep for a message in the same
            -- breath as the cast.
            local note = SilencerNote(cast.wearers)
            Tattle.SendAlert(string_format("%s's Swapblaster%s %s%s",
                sourceName, OnPhrase(cast),
                finished == false and "was cut short" or "cast ended", note), MODULE_ID)
        end
        Tattle.DebugPrint("Swapblaster CHANNEL_STOP:", sourceName, finished)

    elseif event == "UNIT_SPELLCAST_FAILED" then
        local cast = activeCasts[unitToken]
        if not cast or (cast.resolved and not IsStale(cast)) then return end
        Resolve(cast)

        local note = SilencerNote(cast.wearers)
        Tattle.SendAlert(string_format("%s's Swapblaster%s failed%s",
            sourceName, OnPhrase(cast), note), MODULE_ID)
        Tattle.DebugPrint("Swapblaster FAILED:", sourceName, note)

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        local cast = activeCasts[unitToken]
        if not cast or (cast.resolved and not IsStale(cast)) then return end
        Resolve(cast)

        Tattle.SendAlert(string_format("%s's Swapblaster%s was interrupted",
            sourceName, OnPhrase(cast)), MODULE_ID)
        Tattle.DebugPrint("Swapblaster INTERRUPTED:", sourceName)
    end
end

-- ============================================================================
-- Init & Registration
-- ============================================================================

local function Initialize()
    Tattle.DebugPrint("Swapblaster module initialized")

    -- Resolve IDs to names while they are still safe plain numbers, and hand the
    -- names to the core: an event for a spell nobody registered is dropped before
    -- any module is woken. The backfire is registered too, even though it is not
    -- part of the user-editable list -- it is a signal this module reads, not a
    -- cast the user chose to follow, and the core would otherwise filter it out.
    Tattle.ResolveSpellNames(swapNames, Tattle.MakeSpellIDs(MODULE_ID, SWAPBLASTER_SPELL_IDS))
    Tattle.ResolveSpellNames(backfireNames, BACKFIRE_SPELL_IDS)

    isSwap     = Tattle.MakeSpellMatcher(swapNames)
    isBackfire = Tattle.MakeSpellMatcher(backfireNames)
end

Tattle:RegisterModule(MODULE_ID, {
    name        = MODULE_NAME,
    tabName     = "Swapblaster",   -- short: six tabs have to fit one row
    description = MODULE_DESCRIPTION,
    initialize  = Initialize,
    onEvent     = OnEvent,
    spellIDs    = SWAPBLASTER_SPELL_IDS,
    -- "Cannot be used in combat" is on the item: while the caster is fighting a
    -- cast start cannot exist, so the core drops those. The landing still gets
    -- through, because a swap begun out of combat can be what started the fight.
    outOfCombat = "start",
    events      = {
        "UNIT_SPELLCAST_START",
        "UNIT_SPELLCAST_SUCCEEDED",
        "UNIT_SPELLCAST_FAILED",
        "UNIT_SPELLCAST_INTERRUPTED",
        -- Swap is flagged channeled, so these are the events it most likely
        -- actually uses.
        "UNIT_SPELLCAST_CHANNEL_START",
        "UNIT_SPELLCAST_CHANNEL_STOP",
    },
})
