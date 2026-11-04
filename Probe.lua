-- Probe.lua - the /tattle probe: a debug instrument, not a feature.
--
-- It dumps what the client actually exposes for a cast, so spell IDs and --
-- crucially whether a destination is available at all -- can be verified in the
-- field instead of guessed from a tooltip. Nothing here is load-bearing for an
-- alert; the file exists so the guesses above stay checkable.
--
-- Secret-value safe by construction: nothing a cast event hands over is compared
-- or printed raw. Names come from the API, which accepts secret values, and
-- every probe of a possibly-secret value runs inside a pcall.
--
-- Like the modules, the probe only reports while you are grouped. Everything it
-- measures (a swap, a grip, a rescue) needs a group, so a solo cast teaches
-- nothing and the aura and target sweeps below would be pure waste.

local _, Tattle = ...

local print = print
local CreateFrame = CreateFrame
local GetTime = GetTime
local UnitName = UnitName
local UnitExists = UnitExists
local UnitIsUnit = UnitIsUnit
local C_Spell = C_Spell
local ipairs = ipairs
local pairs = pairs
local type = type
local string_format = string.format
local table_concat = table.concat
local table_sort = table.sort
local pcall = pcall

-- The three auras whose visibility decides what Tattle can say. Not guessed at:
-- Leap of Faith is what a completed grip leaves on the person who was pulled,
-- Rescue is what a completed rescue leaves on both halves of the flight, and
-- Neural Silencer is the buff every "it failed because ..." alert is built on.
-- If the first two come back "none visible", naming a victim is impossible on
-- this client; if the third does, the watch list and the blocked-cast wording
-- both go quiet. Same IDs the modules watch, listed here on purpose: a probe that
-- reads its expectations out of the modules it is checking proves nothing.
local PROBE_AURA_SPELL_IDS = { 73325, 370666, 156779 }

function Tattle.ToggleProbe()
    if Tattle._probeFrame then
        Tattle._probeFrame:SetScript("OnEvent", nil)
        Tattle._probeFrame = nil
        print("Tattle probe OFF.")
        return
    end

    -- Resolve the aura names from spell IDs rather than typing English strings, so
    -- the report is right whatever language the client is running.
    local probeAuras, probeAuraNames = {}, {}
    for _, id in ipairs(PROBE_AURA_SPELL_IDS) do
        local info = C_Spell.GetSpellInfo(id)
        if info and info.name and not probeAuras[info.name] then
            probeAuras[info.name] = true
            probeAuraNames[#probeAuraNames + 1] = info.name
        end
    end
    table_sort(probeAuraNames)

    local f = CreateFrame("Frame")
    f:RegisterEvent("UNIT_SPELLCAST_START")
    f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    f:RegisterEvent("UNIT_SPELLCAST_FAILED")
    f:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    f:RegisterEvent("UNIT_SPELLCAST_SENT")
    -- The Swapblaster's cast is flagged channeled, so without these two the probe
    -- can sit through a swap and print nothing at all.
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")

    -- Group context (who is protected, who is targeting you) does not change
    -- between one cast event and the next, so it is reported at most once a
    -- second. A raid-wide pull produces dozens of casts per second, and sweeping
    -- every member's auras for each of them would make the debug tool the most
    -- expensive thing in the addon.
    local lastContext = 0

    f:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5, arg6)
        if not Tattle.IsGrouped() then return end

        -- Resolve the spell name safely (works even if the spell ID is a secret).
        local spellArg = (event == "UNIT_SPELLCAST_SENT") and (arg5 or arg3) or arg3
        local info = spellArg and C_Spell.GetSpellInfo(spellArg)
        local spellName = info and info.name or "?"

        -- Is the caster argument a plain token we can name, or a secret?
        local okName, casterName = pcall(UnitName, arg1)
        local casterText = (okName and type(casterName) == "string" and casterName) or "secret/unnameable"
        local okMe, isMe = pcall(UnitIsUnit, arg1, "player")
        local casterIsMe = (okMe and type(isMe) == "boolean") and (isMe and "YES" or "no") or "?"

        -- Hunt for a usable destination argument on UNIT_SPELLCAST_SENT. This is
        -- the question the whole victim-naming design turns on: if a build ever
        -- exposes one here, an alert can stop guessing from auras.
        local destText, destIsMe = "none exposed", "n/a"
        if event == "UNIT_SPELLCAST_SENT" then
            for _, candidate in ipairs({ arg4, arg5, arg6 }) do
                if candidate ~= nil and candidate ~= spellArg and candidate ~= arg1 then
                    local okDn, dn = pcall(UnitName, candidate)
                    local okDm, dm = pcall(UnitIsUnit, candidate, "player")
                    if okDm and type(dm) == "boolean" then
                        destIsMe = dm and "YES" or "no"
                        destText = (okDn and type(dn) == "string" and dn) or "secret (usable only via UnitIsUnit)"
                        break
                    end
                end
            end
        end

        print(string_format("|cffff6600[Tattle Probe]|r %s | spell: %s | caster: %s (isMe=%s) | dest: %s (isMe=%s)",
            event, spellName, casterText, casterIsMe, destText, destIsMe))

        if (GetTime() - lastContext) < 1 then return end
        lastContext = GetTime()

        -- Second question: can this build see another member's aura at all?
        -- "none visible" means the "on Pancakes" half of an alert is impossible.
        for _, auraName in ipairs(probeAuraNames) do
            local visible = Tattle.AuraCarrierNames({ [auraName] = true }, "ALL")
            print(string_format("|cffff6600[Tattle Probe]|r   aura %-18s -> %s",
                auraName, visible[1] and table_concat(visible, ", ") or "none visible"))
        end

        -- Third: is the Neural Silencer buff readable? The watch list and every
        -- "it failed because ..." alert are built on this one lookup.
        local wearers = Tattle.SilencerWearerNames()
        print(string_format("|cffff6600[Tattle Probe]|r   neural silencers    -> %s",
            wearers[1] and table_concat(wearers, ", ") or "none"))

        -- Fourth: does this client expose other players' targets? "<member>target"
        -- is all the watch list has to work with, and a build that never syncs it
        -- shows nothing but "none / not synced" no matter who is looking at you.
        -- Reading your own target off another player is not possible, so a blank
        -- here is not evidence that nobody is aiming at you.
        local entries = Tattle.GroupTargetEntries()
        local shown, watchers = 0, {}
        for _, entry in ipairs(entries) do
            local name = Tattle.GetUnitShortName(entry.owner) or entry.owner
            local targetName = UnitExists(entry.target) and UnitName(entry.target)
            if UnitIsUnit(entry.target, "player") then
                watchers[#watchers + 1] = name
                targetName = name .. " (you)"
            end
            if shown < 5 then
                shown = shown + 1
                print(string_format("|cffff6600[Tattle Probe]|r   target of %-14s -> %s",
                    name, targetName or "none / not synced"))
            end
        end
        print(string_format("|cffff6600[Tattle Probe]|r   targeting you        -> %s",
            watchers[1] and table_concat(watchers, ", ") or "nobody we can read"))
    end)

    Tattle._probeFrame = f
    print("Tattle probe ON (grouped only). Cast Swapblaster / Life Grip / Rescue -- on yourself AND on a friend -- and watch chat.")
end
