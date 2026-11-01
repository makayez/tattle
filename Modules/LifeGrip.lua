-- Modules/LifeGrip.lua

Snitch = Snitch or {}

local string_format = string.format
local ipairs = ipairs
local type = type
local C_Spell = C_Spell
local UnitAffectingCombat = UnitAffectingCombat

local MODULE_ID          = "lifegrip"
local MODULE_NAME        = "Life Grip Detector"
local MODULE_DESCRIPTION = "Alerts when a Priest yanks a group member with Leap of Faith out of combat"

-- "Life Grip" is what everyone calls it; the game has always named the spell
-- Leap of Faith. Verified against the live 12.1.5 database (wowhead.com/
-- spell=73325) and the 12.1.7 PTR: same ID, no rename in 12.x. Instant, 40 yd,
-- Priest talent, Mechanic: Gripped.
--
-- The pull marks the *victim* with a 4-second "Leap of Faith" aura ("Being
-- pulled toward the Priest"), which is how this module can name the target even
-- though the combat log is gone.
local LIFEGRIP_SPELL_IDS = {
    73325,
}

-- Resolved at Initialize() time. OnEvent compares names, never spellID directly.
local lifeGripNames = {}

-- activeCasts keyed on unitToken (a plain string, always safe)
local activeCasts = {}

-- The IDs the user entered in-game win; otherwise the shipped ones apply.
-- An empty or missing SnitchDB list falls back to the built-in default.
local function GetWatchedSpellIDs()
    local settings = Snitch.GetModuleSettings(MODULE_ID)
    local stored = settings and settings.spellIDs
    if type(stored) == "table" and #stored > 0 then return stored end
    return LIFEGRIP_SPELL_IDS
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function IsWatchedSpell(spellID, nameSet)
    local info = C_Spell.GetSpellInfo(spellID)
    if not info or not info.name then return false end
    return nameSet[info.name] == true
end

-- The cast's own name is also the aura name it puts on the victim, so one set
-- covers both. Carriers exclude the caster.
local function Victims(casterToken)
    return Snitch.AuraCarriers(lifeGripNames, "HELPFUL", casterToken)
end

-- ============================================================================
-- Event Handler
-- ============================================================================

local function OnEvent(event, unitToken, castGUID, spellID)
    if not IsWatchedSpell(spellID, lifeGripNames) then return end
    if not Snitch.IsGroupMemberToken(unitToken) then return end

    local sourceName = Snitch.GetUnitShortName(unitToken)
    if not sourceName then return end

    if event == "UNIT_SPELLCAST_START" then
        -- Only a timed cast reaches here. Leap of Faith is instant, so this is a
        -- bonus path for any slow variant; SUCCEEDED below is the real signal.
        if UnitAffectingCombat(unitToken) then
            Snitch.DebugPrint("Life Grip (in combat, ignoring):", sourceName)
            return
        end

        -- No aura yet: the pull has not landed, so the target is unknown (nil).
        if Snitch.ShouldReport(MODULE_ID, unitToken, nil) == false then return end

        activeCasts[unitToken] = true
        Snitch.SendAlert(string_format("%s is casting Life Grip (out of combat)!", sourceName), MODULE_ID)
        Snitch.DebugPrint("Life Grip START OOC:", sourceName)

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Do not require a prior START: an instant cast never sends one.
        if UnitAffectingCombat(unitToken) then
            Snitch.DebugPrint("Life Grip success (in combat, ignoring):", sourceName)
            activeCasts[unitToken] = nil
            return
        end

        -- The victim is wearing the aura the moment the cast resolves, which is
        -- the only destination information left in 12.x.
        -- An empty list reads as "target unknown" inside ShouldReport, so a
        -- failed aura read cannot suppress the warning.
        local victims = Victims(unitToken)
        if Snitch.ShouldReport(MODULE_ID, unitToken, victims) == false then
            Snitch.DebugPrint("Life Grip (scope self, someone else was gripped):", sourceName)
            return
        end

        activeCasts[unitToken] = nil

        if victims[1] then
            Snitch.SendAlert(string_format("%s used Life Grip on %s!", sourceName, Snitch.TargetPhrase(victims)), MODULE_ID)
        else
            Snitch.SendAlert(string_format("%s used Life Grip (target unknown)!", sourceName), MODULE_ID)
        end
        Snitch.DebugPrint("Life Grip SUCCESS OOC:", sourceName, Snitch.TargetPhrase(victims))

    elseif event == "UNIT_SPELLCAST_FAILED" then
        if not activeCasts[unitToken] then return end
        activeCasts[unitToken] = nil
        Snitch.SendAlert(string_format("%s's Life Grip failed.", sourceName), MODULE_ID)
        Snitch.DebugPrint("Life Grip FAILED OOC:", sourceName)

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        if not activeCasts[unitToken] then return end
        activeCasts[unitToken] = nil
        Snitch.SendAlert(string_format("%s's Life Grip was interrupted.", sourceName), MODULE_ID)
        Snitch.DebugPrint("Life Grip INTERRUPTED OOC:", sourceName)
    end
end

-- ============================================================================
-- Init & Registration
-- ============================================================================

local function Initialize()
    Snitch.DebugPrint("Life Grip module initialized")
    for _, id in ipairs(GetWatchedSpellIDs()) do
        local info = C_Spell.GetSpellInfo(id)
        if info and info.name then
            lifeGripNames[info.name] = true
            Snitch.DebugPrint("  Watching:", info.name, "(" .. id .. ")")
        else
            Snitch.DebugPrint("  WARNING: spell ID", id, "not found — may need updating")
        end
    end
end

Snitch:RegisterModule(MODULE_ID, {
    name        = MODULE_NAME,
    tabName     = "Life Grip",     -- short: six tabs have to fit one row
    description = MODULE_DESCRIPTION,
    initialize  = Initialize,
    onEvent     = OnEvent,
    spellIDs    = LIFEGRIP_SPELL_IDS,
    events      = {
        "UNIT_SPELLCAST_START",
        "UNIT_SPELLCAST_SUCCEEDED",
        "UNIT_SPELLCAST_FAILED",
        "UNIT_SPELLCAST_INTERRUPTED",
    },
})
