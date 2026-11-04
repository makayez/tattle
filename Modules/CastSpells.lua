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
    local armedCasts = {}     -- unitToken -> true, for a START awaiting its outcome

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

        local sourceName = Tattle.GetUnitShortName(unitToken)
        if not sourceName then return end

        local action = spec.action

        -- Anything reaching this point is about a caster who was not fighting:
        -- the core dropped the rest (outOfCombat = "all").
        if event == "UNIT_SPELLCAST_START" then
            -- No aura exists yet -- the pull has not landed -- so the passenger is
            -- unknown rather than "nobody", and an unknown passenger is never a
            -- reason to stay quiet.
            if Tattle.ScopeDrops(MODULE_ID, unitToken, nil) then return end

            armedCasts[unitToken] = true
            Tattle.SendAlert(string_format("%s is casting %s (out of combat)!", sourceName, action), MODULE_ID)
            Tattle.DebugPrint(action, "START (out of combat):", sourceName)

        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            -- Deliberately does not require a preceding START: neither spell sends
            -- one, because neither spell has a cast time.
            local passengers = Passengers(unitToken)
            if Tattle.ScopeDrops(MODULE_ID, unitToken, passengers) then
                Tattle.DebugPrint(action, "not reported: your scope is \"only me\" and this landed on someone else:", sourceName)
                return
            end

            armedCasts[unitToken] = nil

            if passengers[1] then
                -- Someone is wearing the aura, so the move landed and nothing
                -- blocked it; a Neural Silencer note here would be noise.
                Tattle.SendAlert(string_format("%s used %s on %s!",
                    sourceName, action, Tattle.TargetPhrase(passengers)), MODULE_ID)
            else
                -- A grab that resolved and marked nobody has one ordinary
                -- explanation: the passenger was wearing a Neural Silencer, so the
                -- move was refused and no aura ever appeared. Only worth claiming
                -- when somebody in the group is actually protected -- and Rescue is
                -- not documented as blocked by the buff, which is why the shared
                -- wording stays at "attempted". /tattle probe lists the wearers if
                -- you want to confirm the behaviour on your build.
                local blocked = Tattle.BlockedBySilencer(sourceName, action, nil, unitToken)
                if blocked then
                    Tattle.SendAlert(blocked, MODULE_ID)
                    Tattle.DebugPrint(action, "blocked:", sourceName)
                    return
                end
                Tattle.SendAlert(string_format("%s used %s (target unknown)!", sourceName, action), MODULE_ID)
            end
            Tattle.DebugPrint(action, "SUCCESS (out of combat):", sourceName, Tattle.TargetPhrase(passengers))

        elseif event == "UNIT_SPELLCAST_FAILED" then
            if not armedCasts[unitToken] then return end
            armedCasts[unitToken] = nil
            -- A grab can fail for plenty of reasons, so this states who is immune
            -- rather than blaming them for the failure.
            Tattle.SendAlert(string_format("%s's %s failed.%s",
                sourceName, action, Tattle.SilencerNote(unitToken)), MODULE_ID)
            Tattle.DebugPrint(action, "FAILED:", sourceName)

        else  -- UNIT_SPELLCAST_INTERRUPTED
            if not armedCasts[unitToken] then return end
            armedCasts[unitToken] = nil
            Tattle.SendAlert(string_format("%s's %s was interrupted.", sourceName, action), MODULE_ID)
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
