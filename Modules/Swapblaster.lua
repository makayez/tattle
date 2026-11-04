-- Modules/Swapblaster.lua - the toy that trades your position with a group
-- member, fired at someone who was not asking. Out of combat only, which is the
-- whole point: it cannot be used in a fight, so a swap is a decision.

local _, Tattle = ...

local string_format = string.format
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

-- ============================================================================
-- Helpers
-- ============================================================================

local function SilencerNote(wearers)
    if #wearers == 0 then return "" end
    return string_format(" (Neural Silencer worn by %s)", Tattle.FormatList(wearers))
end

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
        wearers   = Tattle.SilencerWearerNames(),
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
    if cast then
        if cast.resolved then return nil end
        cast.resolved = true
        return cast
    end

    activeCasts[unitToken] = { wearers = {}, startedAt = GetTime(), duration = nil, resolved = true }
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
local function CompletionMessage(sourceName, unitToken)
    if not Tattle.UnitInCombat(unitToken) then
        local clause = Tattle.SilencerCheatClause(unitToken, sourceName)
        if clause then
            return string_format("%s used Swapblaster%s", sourceName, clause)
        end
    end
    return string_format("%s used Swapblaster%s",
        sourceName, SilencerNote(Tattle.SilencerWearerNames()))
end

-- "Swapblaster Explosion" is what the caster eats when the player they tried to
-- swap with was protected. It is the one event that says "a Swapblaster was fired
-- and did nothing", and because the swap itself marks nobody it is the only
-- chance to call a blocked attempt what it was. The victim still cannot be named,
-- but a backfire can only be caused by a protected player, so the group's
-- Neural Silencer wearers are the candidate list.
local function HandleBackfire(unitToken, sourceName)
    if not sourceName then return end

    -- Whichever half of the cast we hear about last must not announce it twice.
    local cast = activeCasts[unitToken]
    if cast then
        if cast.resolved then return end
        cast.resolved = true
    end

    local message = Tattle.BlockedBySilencer(sourceName, "Swapblaster", nil, unitToken)
        or string_format("%s's Swapblaster backfired", sourceName)
    Tattle.SendAlert(message, MODULE_ID)
    Tattle.DebugPrint("Swapblaster backfire:", sourceName)
end

-- Swap applies no aura to either side, so nothing about this spell can say who
-- got swapped with whom: the destination lived only in the combat log. These
-- alerts name the caster and leave the victim to your own eyes -- except when the
-- target was protected, which the backfire announces.
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

    -- Scope "self" only drops casts we can prove missed you, which for this spell
    -- is never -- the swap marks nobody -- so a Swapblaster aimed at a friend is
    -- still reported.
    if Tattle.ScopeDrops(MODULE_ID, unitToken) then return end

    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        local cast = ArmCast(unitToken, event == "UNIT_SPELLCAST_CHANNEL_START")
        if not cast then return end

        local note = SilencerNote(cast.wearers)
        Tattle.SendAlert(string_format("%s is casting Swapblaster%s", sourceName, note), MODULE_ID)
        Tattle.DebugPrint("Swapblaster START:", sourceName, note)

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if not ClaimCast(unitToken) then return end

        Tattle.SendAlert(CompletionMessage(sourceName, unitToken), MODULE_ID)
        Tattle.DebugPrint("Swapblaster SUCCESS:", sourceName)

    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local cast = activeCasts[unitToken]
        if not cast or cast.resolved then return end
        cast.resolved = true

        local finished = FinishedAsExpected(cast)

        if finished == true then
            Tattle.SendAlert(CompletionMessage(sourceName, unitToken), MODULE_ID)
        else
            -- "cut short" when the channel clearly stopped early, and a plainer
            -- "cast ended" when there was no window to measure against.
            local note = SilencerNote(Tattle.SilencerWearerNames())
            Tattle.SendAlert(string_format("%s's Swapblaster %s%s",
                sourceName, finished == false and "was cut short" or "cast ended", note), MODULE_ID)
        end
        Tattle.DebugPrint("Swapblaster CHANNEL_STOP:", sourceName, finished)

    elseif event == "UNIT_SPELLCAST_FAILED" then
        local cast = activeCasts[unitToken]
        if not cast or cast.resolved then return end
        cast.resolved = true

        local note = SilencerNote(cast.wearers)
        Tattle.SendAlert(string_format("%s's Swapblaster failed%s", sourceName, note), MODULE_ID)
        Tattle.DebugPrint("Swapblaster FAILED:", sourceName, note)

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        local cast = activeCasts[unitToken]
        if not cast or cast.resolved then return end
        cast.resolved = true

        Tattle.SendAlert(string_format("%s's Swapblaster was interrupted", sourceName), MODULE_ID)
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
