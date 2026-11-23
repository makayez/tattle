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

-- Cast state keyed on the caster. The core hands cast events a canonical group
-- token - "player" for you whatever index the client reported you under, otherwise
-- the group's own raidN/partyN - so one cast cannot leave two records behind under
-- two names for the same person, and a restricted client's secret caster token
-- never reaches a table key.
local activeCasts = {}

-- How long a record may still claim to describe the cast it was made for, whether
-- that cast has settled or not. This is the backstop, not the primary rule: the
-- events for one cast arrive within a second or two of each other, and anything
-- later than this from the same unit belongs to a different cast and must not be
-- silenced by - or described by - what the first one left behind.
--
-- The primary rule is which event family a start arrived as (see BelongsToRecord),
-- because two halves of one cast and two attempts at a swap can be the same number
-- of seconds apart, and time cannot tell them apart.
local RESOLVED_TTL = 8

-- The two families a cast can start with. One cast has at most one start of each:
-- a plain one and a channeled one, which is why the family of a start event says
-- something about whether it can be a cast this record already describes.
local FAMILY_PLAIN, FAMILY_CHANNEL = "plain", "channel"

local function FamilyOf(channelled)
    return channelled and FAMILY_CHANNEL or FAMILY_PLAIN
end

-- A record whose cast is over. Two kinds of permanent mute were possible here:
-- the settled record outliving its usefulness (which alpha.3 fixed), and the
-- record that was armed by a start and never terminated at all - a caster who
-- was interrupted by an API the client does not report, a /reload mid-channel, a
-- start with no end. That second kind suppressed every later cast from that unit
-- forever, because its age was never asked: the check only looked at resolved
-- records.
local function IsStale(cast)
    return (GetTime() - (cast.resolvedAt or cast.startedAt)) > RESOLVED_TTL
end

-- Settles a record so the other half of the same cast cannot announce it twice.
local function Resolve(cast)
    cast.resolved = true
    cast.resolvedAt = GetTime()
end

-- ============================================================================
-- Helpers
-- ============================================================================

-- The core owns the two sentences this module is allowed to borrow: the one that
-- names a protected *target*, and the one that calls an attempt blocked. Neither
-- takes a group wearer list any more -- see SilencerTargetClause in Core.lua, where a
-- beta's "every alert says somebody has one on" became a question about one unit.

-- Swap is channeled, so its cast window comes from UnitChannelInfo; a plain cast
-- window comes from UnitCastingInfo. Both return (name, displayName, texture,
-- startTimeMs, endTimeMs, ...), and the suffix on those two names is the whole
-- comment: the client's own cast bar divides them before comparing against GetTime
-- (Interface/AddOns/Blizzard_UIPanels_Game/Shared/CastingBarFrame.lua, identical in
-- 12.1.5 and 12.1.7):
--
--     self.maxValue = (endTime - startTime) / 1000;
--     self.value    = (endTime / 1000) - GetTime();
--
-- So this function's name is a promise about its return, and the divide is what
-- keeps it. Returning the raw difference instead - which this did - hands
-- FinishedAsExpected 1500 to compare against two elapsed seconds, so every swap that
-- finished is reported as one that was cut short: the addon tells the group the
-- griefer failed when the griefer succeeded. The test stub used to hand back a
-- seconds-based pair, which is why nothing noticed.
--
-- nil is still fine - an instant spell or a restricted API call - and means "cannot
-- tell", which the caller says out loud rather than guessing at.
local function CastWindowSeconds(unitToken, channelled)
    local getter = channelled and UnitChannelInfo or UnitCastingInfo
    if not getter then return nil end
    local ok, _, _, _, startTime, endTime = pcall(getter, unitToken)
    if ok and type(startTime) == "number" and type(endTime) == "number"
       and not Tattle.IsSecretValue(startTime) and not Tattle.IsSecretValue(endTime) then
        return (endTime - startTime) / 1000
    end
    return nil
end

-- A channeled cast that stopped early was cut short, not completed. Without a
-- known window we cannot tell, and the caller says so plainly instead of guessing.
-- Both sides of this comparison are in seconds: GetTime() is, and
-- CastWindowSeconds converts the client's milliseconds. A 0.35 s slack absorbs the
-- stop event landing a moment before the nominal end of the channel - which is what
-- the channel was always going to do - without being so wide that a cast interrupted
-- at half its length counts as finished.
-- " on Pancakes" / " at you" / "". The empty string is the honest answer on a
-- client that was not told other players' targets: the sentence then reads exactly
-- as it did before the victim was knowable at all.
--
-- Which phrase a cast may use is decided by how its victim was learned, recorded on the
-- record as `victimSource` when the cast was armed. The two sources do not mean the same
-- thing about the same person:
--
--   * "spell-target" came from the client's own cast-target API - this spell was pointed
--     at that member. It is the only evidence that supports "used Swapblaster on".
--   * "unit-target" came from the caster's interface, `<caster>target`. It says their
--     button was pointed there. A @mouseover macro, which is how somebody grieves with
--     this toy without disturbing their own interface, leaves that reading sitting on
--     whoever they last clicked - so it can name a member who was never involved.
--
-- Aiming is the most either source supports, so every sentence about a cast that did not
-- land says that. Only a landing may say "on", and only on the first kind of evidence.
local function VictimPhrase(cast, preposition)
    local who = cast and Tattle.UnitDisplayName(cast.victim)
    if not who then return "" end
    return " " .. preposition .. " " .. who
end

local function AimPhrase(cast)     return VictimPhrase(cast, "at") end

-- " on Pancakes" for a completed swap, or nothing. Nothing means the landing was not
-- witnessed, and the caller then says where the caster was aiming. Two functions rather
-- than one that quietly degrades into the other, because a nameless completion is still
-- worth announcing and a witnessed-but-unnamed one is a different sentence again.
local function OnPhrase(cast)
    if not cast or cast.victimSource ~= "spell-target" then return "" end
    return VictimPhrase(cast, "on")
end

-- " - aiming at Pancakes", for a completed swap whose landing nobody witnessed. The swap
-- undeniably happened and whom the caster had selected is worth telling the group, but the
-- sentence must not put that member in the grammatical place where a victim belongs. What
-- it claims is about the caster's interface, which is what this evidence is about.
local function AimingClause(cast)
    if not cast or cast.victimSource == "spell-target" then return "" end
    local who = Tattle.UnitDisplayName(cast.victim)
    if not who then return "" end
    return " - aiming at " .. who
end

-- The phrase for a swap that completed, on the strongest evidence this client gave.
local function LandingPhrase(cast)
    local on = OnPhrase(cast)
    if #on > 0 then return on end
    return AimingClause(cast)
end

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
--
-- What settles a cast is the record and its age, not the identity the client put on
-- the event - and alpha.3 got that wrong twice over. A settled record only
-- suppressed *terminal* events, so the other half of a *start* that arrived late was
-- free to arm a second record: "CHANNEL_START, INTERRUPTED, and only then the plain
-- START that the channeled-spell hack also sends" announced one swap twice. And
-- comparing the client's cast identity would not have caught it either, because the
-- plain half and the channeled half are separate client records carrying *different*
-- GUIDs - which is as well as it is, since a restricted client hands the GUID as a
-- secret value and will not say whether two of them match.
--
-- So the rule is the record and the event family, and the window is only the
-- backstop: two halves of one cast are a second or two apart, so a record stops
-- describing a cast after eight seconds no matter what. What a start event decides
-- is in BelongsToRecord below - and what it must not decide is that a second attempt
-- is a duplicate, which is what "suppress any start while a fresh record exists"
-- meant in practice: the duplicate a player reported (the same swap announced twice)
-- and the second swap they never heard about at all, from the same branch.

-- Does this start event belong to the cast `cast` already describes?
--
-- Time cannot answer that - two halves of one cast and two attempts at a swap can
-- both be two seconds apart - but the event family can, because one cast sends at
-- most one start of each family:
--
--   * a start of the *other* family is the second half of the recorded cast, and it
--     can arrive after that cast already settled: CHANNEL_START, INTERRUPTED, and
--     only then the plain START the channeled-spell hack also sends;
--   * a start of the *same* family with no outcome yet is one cast the client
--     reported twice - which is what a raid client does with your own casts, once
--     under your raidN index and once as player;
--   * a start of the *same* family after the record settled is the one shape that
--     cannot be this cast, and it is a second attempt: refused or out of range,
--     retargeted, fired again. That one gets its own record and its own alerts.
--
-- The last clause is what this module got wrong in the other direction. Suppressing
-- any start while a fresh record existed meant somebody who failed a Swapblaster and
-- landed a real one two seconds later was reported not at all - both its alerts were
-- swallowed by the first attempt's record, for as long as eight seconds. A missed
-- alert is the failure a watchdog cannot be allowed: an alert too few for something
-- already announced is, and the two are not the same trade.
local function BelongsToRecord(cast, channelled)
    -- A record this module built from a terminal event alone never saw a start, so
    -- it cannot tell a late half from a new attempt by family. It claims the start,
    -- which is the conservative choice and the old one: an out-of-order start is
    -- likelier than a second attempt nobody announced.
    if not cast.family then return true end
    if cast.family ~= FamilyOf(channelled) then return true end
    return not cast.resolved
end

local function ArmCast(unitToken, channelled)
    local existing = activeCasts[unitToken]
    if existing and not IsStale(existing) and BelongsToRecord(existing, channelled) then
        return nil
    end

    -- Read now, and for a specific reason: the toy swaps the caster with whoever they
    -- pointed it at, so at this instant the target *is* the other half of the swap. Read
    -- once here rather than at every message, because a caster who retargets two seconds
    -- later is not griefing somebody else. It is also the only thing that decides whether
    -- this cast may mention a Neural Silencer at all - and where the answer came from
    -- travels with it, because the two sources license different sentences (AimPhrase).
    local victim, victimSource = Tattle.CastTargetOf(unitToken)
    activeCasts[unitToken] = {
        victim       = victim,
        victimSource = victimSource,
        -- Whether this cast has made its first alert yet -- the one that is allowed
        -- to make a noise (Tattle.AlertForCast reads and sets it).
        alerted   = false,
        startedAt = GetTime(),
        duration  = CastWindowSeconds(unitToken, channelled),
        family    = FamilyOf(channelled),
        resolved  = false,
    }
    return activeCasts[unitToken]
end

-- Claims a cast for a terminal event: SUCCESS, CHANNEL_STOP, FAILED or
-- INTERRUPTED. Returns nil when that cast has already been reported by its other
-- half. A cast with no record at all still gets claimed, so a swap your client
-- only ever saw the end of - a start cast on somebody out of range, a start the
-- client never sent - is not dropped.
-- `family` says which half of the event families this terminal belongs to, so a
-- record built here can answer BelongsToRecord for a start that arrives later: the
-- client's CHANNEL_STOP is the channeled half and SUCCEEDED the plain one, while a
-- FAILED or INTERRUPTED could be either and claims both.
local function ClaimCast(unitToken, family)
    local cast = activeCasts[unitToken]
    if cast and not IsStale(cast) then
        if cast.resolved then return nil end
        Resolve(cast)
        return cast
    end

    -- A cast with no record gets one now, and the target is read here too: it is
    -- weaker evidence than the read taken when the cast started (the caster may
    -- have moved on), but "we never heard the start" is not a reason to name
    -- nobody.
    -- The read is taken here too, for the same reason and with the same label: a victim
    -- picked up after the fact does not get described more confidently than one caught in
    -- the act. By this point the spell is over, so the client's own cast-target answer may
    -- already be gone and the caster's interface is all that is left - which the source on
    -- the record will say, in the sentence.
    local victim, victimSource = Tattle.CastTargetOf(unitToken)
    activeCasts[unitToken] = {
        victim       = victim,
        victimSource = victimSource,
        alerted   = false,
        startedAt = GetTime(),
        duration  = nil,
        family    = family,
        resolved  = true,
        resolvedAt = GetTime(),
    }
    return activeCasts[unitToken]
end

-- ============================================================================
-- Event Handler
-- ============================================================================

-- A completed swap. When the caster is the protected one, that is the story worth
-- telling: they fired a movement toy at someone who cannot answer in kind, and that
-- clause is the only mention of protection this sentence gets.
--
-- A swap that *completed* is a swap a Neural Silencer did not stop, so the target's
-- buff is not the story of this alert -- the start alert named it, if it was up when
-- the toy was fired. This line used to end with the group's wearer list, which is the
-- sentence the beta reported as "every alert says so-and-so has one".
--
-- Never reached for a cast that *began* in combat: the core's "start" policy
-- dropped that start, so the only completion that gets here belongs to a swap
-- that started out of combat.
local function CompletionMessage(sourceName, unitToken, cast)
    local on = LandingPhrase(cast)
    if not Tattle.UnitInCombat(unitToken) then
        local clause = Tattle.SilencerCheatClause(unitToken, sourceName)
        if clause then
            -- The clause already names the protected wearer, so nothing else about
            -- protection goes on this sentence.
            return string_format("%s used Swapblaster%s%s", sourceName, on, clause)
        end
    end
    return string_format("%s used Swapblaster%s", sourceName, on)
end

-- "Swapblaster Explosion" is what the caster eats when the player they tried to
-- swap with was protected. It is the one event that says "a Swapblaster was fired
-- and did nothing", and because the swap itself marks nobody it is the only
-- chance to call a blocked attempt what it was. The victim is named when the
-- caster's target can be read; when it cannot, a backfire can only be caused by a
-- protected player, so the group's protected members are the candidate list -- and
-- with more than one of those the alert refuses to pick.
local function HandleBackfire(unitToken, sourceName)
    -- Whichever half of the cast we hear about last must not announce it twice --
    -- unless the record is a stale one, in which case this backfire belongs to a
    -- later cast and deserves its own alert.
    --
    -- `thisCast` is that decision made once: a stale record is not a record for this
    -- attempt, so whether the older swap made a noise says nothing about this one.
    local record = activeCasts[unitToken]
    local thisCast = (record and not IsStale(record)) and record or nil
    if thisCast then
        if thisCast.resolved then return end
        Resolve(thisCast)
    end

    -- The read is fresh rather than the one stored on the cast record: the backfire
    -- is its own spell and can be the first thing we hear about.
    local victim = (Tattle.CastTargetOf(unitToken))
    -- That last argument says *this event* proves the target was protected. Nothing
    -- else a Swapblaster sends does, which is why this is the one alert allowed to
    -- name the group's lone protected member with no target read pointing at them -
    -- and why it still refuses to pick one when there is more than one.
    local message = Tattle.BlockedBySilencer(sourceName, "Swapblaster",
        victim and { victim } or nil, unitToken, true)
        -- AimPhrase, because a backfire is the one outcome where nobody moved: whoever is
        -- named here was pointed at, not swapped.
        or string_format("%s's Swapblaster%s backfired", sourceName,
            AimPhrase({ victim = victim }))
    -- Loud only when this is the first thing the player hears about the attempt; a
    -- start they already heard made the noise.
    Tattle.AlertForCast(thisCast, message, MODULE_ID)
    Tattle.DebugPrint("Swapblaster backfire:", sourceName)
end

-- Swap applies no aura to either side, so the swap itself cannot be attributed the
-- way Life Grip and Rescue can: the destination lived only in the combat log, and
-- 12.0.0 removed it. What is left is the client's own cast-target API, which answers for
-- the spell and may hand the name back as a value an addon may not read, and the caster's
-- own target, which answers for their interface.
--
-- So the alerts name the victim when the client's target API named one, describe a
-- completed swap as landing on the member the caster's UI pointed at only when that is all
-- there was and say it in aiming words, and say nothing about the victim when neither
-- answered. They never guess.
--
-- That aiming rule is the correction in this revision. Treating `<caster>target` as the
-- spell's destination is true of a hard-targeted cast and false of the @mouseover macro a
-- griefer uses, and the difference between those two is which group member the raid is
-- told to watch.
local function OnEvent(event, unitToken, castGUID, spellID, spellName)
    -- `castGUID` is received and deliberately unused. See Cast bookkeeping above for
    -- why the window a record covers, rather than the identity the client put on the
    -- event, is what decides whether this is a cast already announced.
    --
    -- A guard, not the primary filter: the dispatcher has already dropped casts
    -- by anyone who is not one of your group's players. It stays because that
    -- filter is per-event, and another module's `allCasters` flag would widen the
    -- same event for everybody.
    if not Tattle.IsGroupMemberToken(unitToken) then return end

    local backfire = isBackfire(spellName, spellID)
    if not backfire and not isSwap(spellName, spellID) then return end

    local sourceName = Tattle.CasterLabel(unitToken)

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

        -- The one place a swap alert may mention protection: the aura of the member
        -- this cast was aimed at.
        local note = Tattle.SilencerTargetClause(cast.victim)
        Tattle.AlertForCast(cast, string_format("%s is casting Swapblaster%s%s",
            sourceName, AimPhrase(cast), note), MODULE_ID)
        Tattle.DebugPrint("Swapblaster START:", sourceName, note)

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local claimed = ClaimCast(unitToken, FAMILY_PLAIN)
        if not claimed then return end

        Tattle.AlertForCast(claimed, CompletionMessage(sourceName, unitToken, claimed), MODULE_ID)
        Tattle.DebugPrint("Swapblaster SUCCESS:", sourceName)

    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local cast = ClaimCast(unitToken, FAMILY_CHANNEL)
        if not cast then return end

        local finished = FinishedAsExpected(cast)

        if finished == true then
            Tattle.AlertForCast(cast, CompletionMessage(sourceName, unitToken, cast), MODULE_ID)
        else
            -- "cut short" when the channel clearly stopped early, and a plainer
            -- "cast ended" when there was no window to measure against. The only
            -- protection note is the one about the member this swap was aimed at --
            -- not the group's wearer list, which is what put the same bystander's
            -- name on every alert of the evening.
            local note = Tattle.SilencerTargetClause(cast.victim)
            Tattle.AlertForCast(cast, string_format("%s's Swapblaster%s %s%s",
                -- AimPhrase, not the landing phrase: a swap that stopped early landed on
                -- nobody, so the most a victim can be called is where it was pointed.
                sourceName, AimPhrase(cast),
                finished == false and "was cut short" or "cast ended", note), MODULE_ID)
        end
        Tattle.DebugPrint("Swapblaster CHANNEL_STOP:", sourceName, finished)

    elseif event == "UNIT_SPELLCAST_FAILED" then
        local cast = ClaimCast(unitToken)
        if not cast then return end

        local note = Tattle.SilencerTargetClause(cast.victim)
        Tattle.AlertForCast(cast, string_format("%s's Swapblaster%s failed%s",
            -- Failed before it landed: aiming is all this can claim.
            sourceName, AimPhrase(cast), note), MODULE_ID)
        Tattle.DebugPrint("Swapblaster FAILED:", sourceName, note)

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        local cast = ClaimCast(unitToken)
        if not cast then return end

        Tattle.AlertForCast(cast, string_format("%s's Swapblaster%s was interrupted",
            -- Interrupted before it landed, same reasoning.
            sourceName, AimPhrase(cast)), MODULE_ID)
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
