-- Modules/CastSpells.lua - the two "someone picked you up and moved you" spells:
-- Life Grip (Priest) and Rescue (Evoker).
--
-- They are one module's worth of logic twice. Both are instant, both mark their
-- passenger with an aura and their caster with nothing useful, both are a way to
-- relocate a group member without their consent, and both are legitimate in a
-- raid -- which is exactly why the interesting case is the one where nobody was
-- fighting. Life Grip and Rescue share everything but their spell IDs and the
-- word to put in the sentence, so they are registered from one definition.
--
-- A Swapblaster does not belong here: it is channeled, it marks nobody at all,
-- and it has a backfire to interpret. That is Modules/Swapblaster.lua.

local _, Tattle = ...

local string_format = string.format
local ipairs = ipairs

-- What this addon listens for on a spell that has no visible cast time. START is
-- kept because a slow variant of either spell would still be worth hearing about
-- while it is going off; in practice the alert arrives on SUCCEEDED.
local GRIP_EVENTS = {
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED",
}

-- One definition, two registrations. `action` is the word the alerts use, which
-- is the only thing either spell says differently.
local function MakeGripModule(spec)
    local MODULE_ID    = spec.id
    local names        = {}   -- spell names, filled at initialize
    local isOurCast            -- matcher built at initialize
    -- unitToken -> { armedAt = ..., alerted = ... }, for a START awaiting its
    -- outcome. Not just a timestamp any more: `alerted` is how the outcome of that
    -- cast knows the noise was already made, which is what keeps one grab from
    -- beeping twice (see Tattle.AlertForCast).
    local armedCasts = {}

    -- A START that never got an outcome is not a promise about the next cast from
    -- that unit. Without an expiry, one FAILED cast that the client reported as a
    -- start and nothing else left the unit armed for the rest of the run, and any
    -- later INTERRUPTED - of a different cast entirely - was announced as this one.
    -- Eight seconds, the same span Swapblaster uses as the backstop on a record: a
    -- failure or interrupt belongs to the start this module watched for, and past
    -- that span it belongs to a cast this module never saw begin. Neither spell is
    -- channeled, so this module has no second start family to tell apart (see
    -- BelongsToRecord in Modules/Swapblaster.lua) and the window alone is the rule.
    local ARM_TTL = 8

    local function IsArmed(armed)
        return armed ~= nil and (GetTime() - armed.armedAt) <= ARM_TTL
    end

    -- The cast leaves an aura on whoever was picked up and on nobody else, so the
    -- carriers of the cast's own spell name are the passengers -- minus the caster,
    -- because Rescue puts the aura on the Evoker too and reading them back as their
    -- own passenger is how you accuse someone of carrying themselves.
    local function Passengers(casterToken)
        return Tattle.AuraCarriers(names, "HELPFUL", casterToken)
    end

    local function OnEvent(event, unitToken, castGUID, spellID, spellName)
        -- A guard, not the primary filter: the core has already dropped casts by
        -- anyone who is not one of your group's players. It stays because that
        -- filter is per-event, and another module's `allCasters` flag would widen
        -- the same event for everybody.
        if not Tattle.IsGroupMemberToken(unitToken) then return end
        if not isOurCast(spellName, spellID) then return end

        local sourceName = Tattle.CasterLabel(unitToken)

        local action = spec.action

        -- Anything reaching this point is about a caster who was not fighting:
        -- the core dropped the rest (outOfCombat = "all").
        if event == "UNIT_SPELLCAST_START" then
            -- No aura exists yet -- the pull has not landed -- so the passenger is
            -- unknown rather than "nobody", and an unknown passenger is never a
            -- reason to stay quiet.
            if Tattle.ScopeDrops(MODULE_ID, unitToken, nil) then return end

            -- A record first, then the alert: AlertForCast files the fact that this
            -- cast has spoken, on the record, and the outcome of the same cast reads
            -- it back to decide whether it may be loud too.
            local armed = { armedAt = GetTime() }
            armedCasts[unitToken] = armed
            Tattle.AlertForCast(armed,
                string_format("%s is casting %s (out of combat)!", sourceName, action), MODULE_ID)
            Tattle.DebugPrint(action, "START (out of combat):", sourceName)

        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            -- Deliberately does not require a preceding START: neither spell sends
            -- one, because neither spell has a cast time.
            local passengers = Passengers(unitToken)
            if Tattle.ScopeDrops(MODULE_ID, unitToken, passengers) then
                Tattle.DebugPrint(action, "not reported: your scope is \"only me\" and this landed on someone else:", sourceName)
                return
            end

            -- Taken before it is cleared: whichever sentence goes out next is the
            -- outcome of the START this unit is armed for, and the START made the
            -- noise if there was one. Neither of these spells has a cast time, so in
            -- practice `armed` is nil here and the landing is the first thing the
            -- player hears -- which is the case that should be loud.
            local armed = armedCasts[unitToken]
            armedCasts[unitToken] = nil

            if passengers[1] then
                -- Someone is wearing the aura, so the move landed and nothing
                -- blocked it; a Neural Silencer note here would be noise. The
                -- phrase gets a name because the alert and the debug line both
                -- want it, and TargetPhrase builds a table to say three words.
                local phrase = Tattle.TargetPhrase(passengers)
                Tattle.AlertForCast(armed,
                    string_format("%s used %s on %s!", sourceName, action, phrase), MODULE_ID)
                Tattle.DebugPrint(action, "SUCCESS (out of combat):", sourceName, phrase)
            else
                -- A grab that resolved and marked nobody *may* have bounced off a
                -- Neural Silencer, and when it clearly did that is worth more than
                -- "target unknown". What it is not allowed to be is an inference from
                -- "somebody in this raid is protected": that was the beta report --
                -- one wearer in the group, and every alert carrying their name. So the
                -- claim needs a target, and with the passenger aura never having
                -- appeared, some reading of the target is the only thing that can supply
                -- it - and it comes from the same source the swap alerts use, best evidence
                -- first: the client's answer about whom the spell was pointed at, and only
                -- then the caster's interface. These are instant casts, so by the time
                -- SUCCEEDED lands the spell is over and the stronger answer is often
                -- already gone; that is exactly when the weaker one is worth having, and it
                -- is also why this claim stays at "attempted" rather than "landed on".
                -- No read at all, or a readable one that lands on somebody who is not
                -- protected, and the sentence stays the honest one that admits the target
                -- is unknown. Rescue is not documented as blocked by the buff
                -- either, which is why the shared wording stays at "attempted".
                local target = (Tattle.CastTargetOf(unitToken))
                local blocked = Tattle.BlockedBySilencer(sourceName, action,
                    target and { target } or nil, unitToken)
                if blocked then
                    Tattle.AlertForCast(armed, blocked, MODULE_ID)
                    Tattle.DebugPrint(action, "blocked:", sourceName)
                    return
                end
                Tattle.AlertForCast(armed,
                    string_format("%s used %s (target unknown)!", sourceName, action), MODULE_ID)
                Tattle.DebugPrint(action, "SUCCESS with no passenger:", sourceName)
            end

        elseif event == "UNIT_SPELLCAST_FAILED" then
            local armed = armedCasts[unitToken]
            if not IsArmed(armed) then return end
            armedCasts[unitToken] = nil
            -- A grab can fail for plenty of reasons, so this only says what it can
            -- see: the failure, and the buff of whoever the caster had picked - the
            -- spell's own target where the client will name it, their interface where
            -- it will not. Nothing here claims the grab reached anybody, so the weaker
            -- source costs the sentence nothing. The old wording appended the group's
            -- whole wearer list to every failed cast, which read as an accusation and
            -- was not one.
            local note = Tattle.SilencerTargetClause((Tattle.CastTargetOf(unitToken)))
            Tattle.AlertForCast(armed,
                string_format("%s's %s failed%s.", sourceName, action, note), MODULE_ID)
            Tattle.DebugPrint(action, "FAILED:", sourceName)

        elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
            -- Named rather than `else`: an else branch reading as "the remaining
            -- registered event" is only true while the event list above is the whole
            -- list, and a module that later registers a channel event would find its
            -- CHANNEL_START reported as an interruption.
            local armed = armedCasts[unitToken]
            if not IsArmed(armed) then return end
            armedCasts[unitToken] = nil
            Tattle.AlertForCast(armed,
                string_format("%s's %s was interrupted.", sourceName, action), MODULE_ID)
            Tattle.DebugPrint(action, "INTERRUPTED:", sourceName)
        end
    end

    local function Initialize()
        Tattle.DebugPrint(spec.name, "module initialized")
        Tattle.ResolveSpellNames(names, Tattle.MakeSpellIDs(MODULE_ID, spec.shippedSpellIDs))
        isOurCast = Tattle.MakeSpellMatcher(names)
    end

    Tattle:RegisterModule(MODULE_ID, {
        name        = spec.name,
        tabName     = spec.tabName,   -- short: six tabs have to fit one row
        description = spec.description,
        initialize  = Initialize,
        onEvent     = OnEvent,
        spellIDs    = spec.shippedSpellIDs,
        -- Both of these are instant, so there is no landing to rescue from a
        -- combat filter: a grab that resolves while its caster is fighting is a
        -- raid tool doing a job, not a mugging.
        outOfCombat = "all",
        events      = GRIP_EVENTS,
    })
end

-- ============================================================================
-- Life Grip (Priest)
-- ============================================================================

-- "Life Grip" is what everyone calls it; the game has always named the spell
-- Leap of Faith. Verified against the live 12.1.5 database
-- (wowhead.com/spell=73325) and the 12.1.7 PTR: same ID, no rename in 12.x.
-- Instant, 40 yd, Priest talent, Mechanic: Gripped.
--
-- The pull marks the person who was dragged with a 4-second "Leap of Faith" aura
-- ("Being pulled toward the Priest"), which is how the passenger can be named at
-- all now that the combat log is gone.
MakeGripModule({
    id         = "lifegrip",
    name       = "Life Grip Detector",
    tabName    = "Life Grip",
    action     = "Life Grip",
    description = "Alerts when a Priest yanks a group member with Leap of Faith out of combat",
    shippedSpellIDs = {
        73325,
    },
})

-- ============================================================================
-- Rescue (Evoker)
-- ============================================================================

-- Verified against the live 12.1.5 database (wowhead.com/spell=370666): Rescue,
-- Requires Evoker, 100 yd range, instant, "Swoop to an ally and fly with them for
-- up to 3 sec", and it puts a 3-second "Rescue -- Flying with an ally" aura on the
-- pair.
--
-- 370667 is the passenger-side helper: same name, Evoker icon
-- (ability_evoker_flywithme), unlimited range, instant, 3 seconds, "Rescue --
-- Being escorted to safety". The adjacent ID and matching duration make it the
-- likely marker on the grabbed player, but Wowhead lists no link from 370666, so
-- treat it as a strong candidate rather than a confirmed one. Watching both is
-- harmless: matching is by spell name and the aura name is the same either way.
--
-- 264920 is also called "Rescued" but is an unrelated BfA-era spell, deliberately
-- not watched.
MakeGripModule({
    id         = "rescue",
    name       = "Rescue Detector",
    tabName    = "Rescue",
    action     = "Rescue",
    description = "Alerts when an Evoker scoops a group member up with Rescue out of combat",
    shippedSpellIDs = {
        370666,
        370667,
    },
})
