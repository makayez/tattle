-- Modules/Rescue.lua

Snitch = Snitch or {}

local string_format = string.format
local ipairs = ipairs
local type = type
local C_Spell = C_Spell
local UnitAffectingCombat = UnitAffectingCombat

local MODULE_ID          = "rescue"
local MODULE_NAME        = "Rescue Detector"
local MODULE_DESCRIPTION = "Alerts when an Evoker scoops a group member up with Rescue out of combat"

-- Verified against the live 12.1.5 database (wowhead.com/spell=370666):
-- Rescue, Requires Evoker, 100 yd range, instant, "Swoop to an ally and fly
-- with them for up to 3 sec", and it puts a 3-second "Rescue -- Flying with an
-- ally" aura on the pair.
--
-- 370667 is the passenger-side helper: same name, Evoker icon
-- (ability_evoker_flywithme), unlimited range, instant, 3 seconds, "Rescue --
-- Being escorted to safety". Adjacent ID and matching duration make it the
-- likely marker on the grabbed player, but Wowhead lists no link from 370666, so
-- treat it as a strong candidate rather than a confirmed one. Watching both is
-- harmless: matching is by spell name, and the aura name is the same either way.
--
-- 264920 is also called "Rescued" but is an unrelated BfA-era spell; it is
-- deliberately not watched.
local RESCUE_SPELL_IDS = {
    370666,
    370667,
}

-- Resolved at Initialize() time. OnEvent compares names, never spellID directly.
local rescueNames = {}

-- activeCasts keyed on unitToken (a plain string, always safe)
local activeCasts = {}

-- The IDs the user entered in-game win; otherwise the shipped ones apply.
-- An empty or missing SnitchDB list falls back to the built-in default.
local function GetWatchedSpellIDs()
    local settings = Snitch.GetModuleSettings(MODULE_ID)
    local stored = settings and settings.spellIDs
    if type(stored) == "table" and #stored > 0 then return stored end
    return RESCUE_SPELL_IDS
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function IsWatchedSpell(spellID, nameSet)
    local info = C_Spell.GetSpellInfo(spellID)
    if not info or not info.name then return false end
    return nameSet[info.name] == true
end

-- Both halves of the flight carry an aura named "Rescue", so the caster has to
-- be excluded before the remaining carriers can be read as the passenger.
local function Passengers(casterToken)
    return Snitch.AuraCarriers(rescueNames, "HELPFUL", casterToken)
end

-- ============================================================================
-- Event Handler
-- ============================================================================

local function OnEvent(event, unitToken, castGUID, spellID)
    if not IsWatchedSpell(spellID, rescueNames) then return end
    if not Snitch.IsGroupMemberToken(unitToken) then return end

    local sourceName = Snitch.GetUnitShortName(unitToken)
    if not sourceName then return end

    if event == "UNIT_SPELLCAST_START" then
        if UnitAffectingCombat(unitToken) then
            Snitch.DebugPrint("Rescue (in combat, ignoring):", sourceName)
            return
        end

        if Snitch.ShouldReport(MODULE_ID, unitToken, nil) == false then return end

        activeCasts[unitToken] = true
        Snitch.SendAlert(string_format("%s is casting Rescue (out of combat)!", sourceName), MODULE_ID)
        Snitch.DebugPrint("Rescue START OOC:", sourceName)

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Rescue is instant, so no START ever precedes this.
        if UnitAffectingCombat(unitToken) then
            Snitch.DebugPrint("Rescue success (in combat, ignoring):", sourceName)
            activeCasts[unitToken] = nil
            return
        end

        local passengers = Passengers(unitToken)
        -- An empty list reads as "target unknown" inside ShouldReport, so a
        -- failed aura read cannot suppress the warning.
        if Snitch.ShouldReport(MODULE_ID, unitToken, passengers) == false then
            Snitch.DebugPrint("Rescue (scope self, someone else was carried):", sourceName)
            return
        end

        activeCasts[unitToken] = nil

        if passengers[1] then
            Snitch.SendAlert(string_format("%s used Rescue on %s!", sourceName, Snitch.TargetPhrase(passengers)), MODULE_ID)
        else
            Snitch.SendAlert(string_format("%s used Rescue (target unknown)!", sourceName), MODULE_ID)
        end
        Snitch.DebugPrint("Rescue SUCCESS OOC:", sourceName, Snitch.TargetPhrase(passengers))

    elseif event == "UNIT_SPELLCAST_FAILED" then
        if not activeCasts[unitToken] then return end
        activeCasts[unitToken] = nil
        Snitch.SendAlert(string_format("%s's Rescue failed.", sourceName), MODULE_ID)
        Snitch.DebugPrint("Rescue FAILED OOC:", sourceName)

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        if not activeCasts[unitToken] then return end
        activeCasts[unitToken] = nil
        Snitch.SendAlert(string_format("%s's Rescue was interrupted.", sourceName), MODULE_ID)
        Snitch.DebugPrint("Rescue INTERRUPTED OOC:", sourceName)
    end
end

-- ============================================================================
-- Init & Registration
-- ============================================================================

local function Initialize()
    Snitch.DebugPrint("Rescue module initialized")
    for _, id in ipairs(GetWatchedSpellIDs()) do
        local info = C_Spell.GetSpellInfo(id)
        if info and info.name then
            rescueNames[info.name] = true
            Snitch.DebugPrint("  Watching:", info.name, "(" .. id .. ")")
        else
            Snitch.DebugPrint("  WARNING: spell ID", id, "not found — may need updating")
        end
    end
end

Snitch:RegisterModule(MODULE_ID, {
    name        = MODULE_NAME,
    tabName     = "Rescue",        -- short: six tabs have to fit one row
    description = MODULE_DESCRIPTION,
    initialize  = Initialize,
    onEvent     = OnEvent,
    spellIDs    = RESCUE_SPELL_IDS,
    events      = {
        "UNIT_SPELLCAST_START",
        "UNIT_SPELLCAST_SUCCEEDED",
        "UNIT_SPELLCAST_FAILED",
        "UNIT_SPELLCAST_INTERRUPTED",
    },
})
