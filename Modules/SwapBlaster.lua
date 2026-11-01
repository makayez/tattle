-- Modules/SwapBlaster.lua

Snitch = Snitch or {}

local string_format = string.format
local ipairs = ipairs
local type = type
local C_Spell = C_Spell
local GetTime = GetTime
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo

local MODULE_ID          = "swapblaster"
local MODULE_NAME        = "SwapBlaster Detector"
local MODULE_DESCRIPTION = "Alerts when a group member fires the Swapblaster toy"

-- Verified against the live 12.1.5 spell database (wowhead.com/spell=161399).
-- The item is "Swapblaster" (item 111820); the cast it triggers is a spell
-- actually named "Swap" (161399): 40 yd range, 1.5 sec cast, channeled,
-- "Swaps your location with another party member. Cannot be used in combat."
-- Do not confuse it with 162217 (the 2 sec *crafting* spell) or 182081
-- ("Swapblaster Explosion", the backfire you eat if the target was wearing a
-- Neural Silencer).
local SWAPBLASTER_SPELL_IDS = {
    161399,
}

-- "Neurosilencer" (and the old ID 470344) does not exist -- 470344 resolves to
-- an unrelated hidden test aura called "Supercharged". The real thing is the
-- "Neural Silencer" aura: 156779 from the item, 384129 for the craftable Mk3.
-- Both apply the same 12-hour "Immune to some annoyances" aura that blocks
-- Swapblaster and Leap of Faith, so it is worth knowing who is wearing one.
local NEURAL_SILENCER_SPELL_IDS = {
    156779,
    384129,
}

-- Midnight 12.0+ makes the spellID argument from UNIT_SPELLCAST_* a "secret
-- value" in restricted contexts: you cannot index a table with it or compare it
-- with ==. The safe route is to hand it to a Blizzard API (those accept secret
-- values) and compare the plain string that comes back.
--
-- So: at Initialize() resolve our own plain IDs into spell names and cache
-- them; in OnEvent turn the incoming secret into a name with
-- C_Spell.GetSpellInfo and compare names.
local swapBlasterNames    = {}  -- populated in Initialize()
local neuralSilencerNames = {}  -- populated in Initialize()

-- Cast state keyed on unitToken (a plain string, always safe).
local activeCasts = {}

-- The IDs the user entered in-game win; otherwise the shipped ones apply.
-- An empty or missing SnitchDB list falls back to the built-in default.
local function GetWatchedSpellIDs()
    local settings = Snitch.GetModuleSettings(MODULE_ID)
    local stored = settings and settings.spellIDs
    if type(stored) == "table" and #stored > 0 then return stored end
    return SWAPBLASTER_SPELL_IDS
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function IsWatchedSpell(spellID, nameSet)
    -- spellID may be a secret value -- GetSpellInfo accepts it and hands back a
    -- safe plain string name. Never compare or index with spellID directly.
    local info = C_Spell.GetSpellInfo(spellID)
    if not info or not info.name then return false end
    return nameSet[info.name] == true
end

local function NeuralSilencerNote(wearers)
    if #wearers == 0 then return "" end
    return string_format(" (Neural Silencer worn by %s)", Snitch.FormatList(wearers))
end

local function WearersNow()
    return Snitch.AuraCarrierNames(neuralSilencerNames, "HELPFUL")
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
        wearers   = WearersNow(),
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

-- Swap applies no aura to either side, so nothing about this spell can say who
-- got swapped with whom: the destination lived only in the combat log. These
-- alerts name the caster and leave the victim to your own eyes.
local function OnEvent(event, unitToken, castGUID, spellID)
    if not IsWatchedSpell(spellID, swapBlasterNames) then return end
    if not Snitch.IsGroupMemberToken(unitToken) then return end
    -- scope == "self" only drops casts we can prove missed you, which for this
    -- spell is never, so a Swapblaster aimed at a friend is still reported.
    if Snitch.ShouldReport(MODULE_ID, unitToken) == false then return end

    local sourceName = Snitch.GetUnitShortName(unitToken)
    if not sourceName then return end

    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        local cast = ArmCast(unitToken, event == "UNIT_SPELLCAST_CHANNEL_START")
        if not cast then return end

        local note = NeuralSilencerNote(cast.wearers)
        Snitch.SendAlert(string_format("%s is casting SwapBlaster%s", sourceName, note), MODULE_ID)
        Snitch.DebugPrint("SwapBlaster START:", sourceName, note)

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if not ClaimCast(unitToken) then return end

        local note = NeuralSilencerNote(WearersNow())
        Snitch.SendAlert(string_format("%s used SwapBlaster%s", sourceName, note), MODULE_ID)
        Snitch.DebugPrint("SwapBlaster SUCCESS:", sourceName, note)

    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local cast = activeCasts[unitToken]
        if not cast or cast.resolved then return end
        cast.resolved = true

        local finished = FinishedAsExpected(cast)
        local note = NeuralSilencerNote(WearersNow())

        if finished == true then
            Snitch.SendAlert(string_format("%s used SwapBlaster%s", sourceName, note), MODULE_ID)
        elseif finished == false then
            Snitch.SendAlert(string_format("%s's SwapBlaster was cut short%s", sourceName, note), MODULE_ID)
        else
            Snitch.SendAlert(string_format("%s's SwapBlaster cast ended%s", sourceName, note), MODULE_ID)
        end
        Snitch.DebugPrint("SwapBlaster CHANNEL_STOP:", sourceName, finished)

    elseif event == "UNIT_SPELLCAST_FAILED" then
        local cast = activeCasts[unitToken]
        if not cast or cast.resolved then return end
        cast.resolved = true

        local note = NeuralSilencerNote(cast.wearers)
        Snitch.SendAlert(string_format("%s's SwapBlaster failed%s", sourceName, note), MODULE_ID)
        Snitch.DebugPrint("SwapBlaster FAILED:", sourceName, note)

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        local cast = activeCasts[unitToken]
        if not cast or cast.resolved then return end
        cast.resolved = true

        Snitch.SendAlert(string_format("%s's SwapBlaster was interrupted", sourceName), MODULE_ID)
        Snitch.DebugPrint("SwapBlaster INTERRUPTED:", sourceName)
    end
end

-- ============================================================================
-- Init & Registration
-- ============================================================================

local function Initialize()
    Snitch.DebugPrint("SwapBlaster module initialized")

    -- Resolve spell IDs to names while they are still safe plain numbers.
    -- OnEvent uses these name sets to identify secret-value spellIDs.
    for _, id in ipairs(GetWatchedSpellIDs()) do
        local info = C_Spell.GetSpellInfo(id)
        if info and info.name then
            swapBlasterNames[info.name] = true
            Snitch.DebugPrint("  Watching:", info.name, "(" .. id .. ")")
        else
            Snitch.DebugPrint("  WARNING: spell ID", id, "not found — may need updating")
        end
    end

    for _, id in ipairs(NEURAL_SILENCER_SPELL_IDS) do
        local info = C_Spell.GetSpellInfo(id)
        if info and info.name then
            neuralSilencerNames[info.name] = true
            Snitch.DebugPrint("  Neural Silencer:", info.name, "(" .. id .. ")")
        else
            Snitch.DebugPrint("  WARNING: Neural Silencer spell ID", id, "not found")
        end
    end
end

Snitch:RegisterModule(MODULE_ID, {
    name        = MODULE_NAME,
    tabName     = "SwapBlaster",   -- short: six tabs have to fit one row
    description = MODULE_DESCRIPTION,
    initialize  = Initialize,
    onEvent     = OnEvent,
    spellIDs    = SWAPBLASTER_SPELL_IDS,
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
