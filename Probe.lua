-- Probe.lua - the /tattle probe: a debug instrument, not a feature.
--
-- It dumps what the client actually exposes for a cast, so spell IDs and --
-- crucially whether a destination is available at all -- can be verified in the
-- field instead of guessed from a tooltip. Nothing here is load-bearing for an
-- alert; the file exists so the guesses above stay checkable.
--
-- Secret-value safe, and not by claiming to be: every value a cast event handed
-- over goes through the core's helpers before it is printed, compared or used as a
-- key. `type()` cannot tell a secret string from a plain one (a secret still
-- reports "string"), so the probe asks the core - which asks by attempting the
-- operation and seeing whether the client refused - and reports the refusal as the
-- finding it is. "secret (not printable)" in a probe line is a result about your
-- client, not a failure of the probe.
--
-- Like the modules, the probe only reports while you are grouped. Everything it
-- measures (a swap, a grip, a rescue) needs a group, so a solo cast teaches
-- nothing and the aura and target sweeps below would be pure waste.
--
-- Unlike the modules, it is not silenced while you are fighting - which is the one
-- part of this addon that the core's "idle while you fight" rule lets through, and
-- deliberately: the question this instrument exists to answer is what the client
-- sends and withholds during a fight, and a diagnostic that goes quiet exactly when
-- the interesting events begin is not a diagnostic. It reports only when a player
-- arms it with /tattle probe, and /tattle off disarms it.

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
local select = select
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

-- How the probe writes about a value it may not be allowed to look at: the value
-- when the client will let it be printed, and a sentence about what stopped it when
-- it will not. The probe exists to answer "what does this client expose", so
-- "secret (not printable)" is an answer, and "none" is a different answer.
local function describe(value)
    local plain = Tattle.PlainText(value)
    if plain then return plain end
    if Tattle.IsSecretValue(value) then return "secret (not printable)" end
    if type(value) == "table" then return "table (fields not readable)" end
    return "none"
end

-- C_Spell.GetSpellInfo on a spell ID we own (public, plain) - but the probe is a
-- measuring instrument, and an API that raises on one build must show up as a
-- finding rather than ending the report half way down.
local function SpellNameFor(id)
    if not C_Spell or not C_Spell.GetSpellInfo then return nil end
    local ok, info = pcall(C_Spell.GetSpellInfo, id)
    if not ok or not info then return nil end
    return info.name
end

function Tattle.DisarmProbe(silent)
    if not Tattle._probeFrame then return end
    Tattle._probeFrame:SetScript("OnEvent", nil)
    Tattle._probeFrame = nil
    if not silent then print("Tattle probe OFF.") end
end

function Tattle.ToggleProbe()
    if Tattle._probeFrame then
        Tattle.DisarmProbe()
        return
    end

    -- Resolve the aura names from spell IDs rather than typing English strings, so
    -- the report is right whatever language the client is running.
    local probeAuras, probeAuraNames = {}, {}
    for _, id in ipairs(PROBE_AURA_SPELL_IDS) do
        local name = SpellNameFor(id)
        local plain = Tattle.PlainText(name)
        if plain and not probeAuras[plain] then
            probeAuras[plain] = true
            probeAuraNames[#probeAuraNames + 1] = plain
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

    local function Report(_, event, arg1, arg2, arg3, arg4, arg5, arg6)
        if not Tattle.IsGrouped() then return end

        -- type(), not `or`: a restricted client can hand the spell argument of a cast
        -- event over as a secret value, and testing one for truthiness is an operation
        -- on it. The same goes for the name ResolveSpellName hands back - it returns
        -- that unexamined on purpose, so a caller may not `or` it either.
        local spellArg = arg3
        if event == "UNIT_SPELLCAST_SENT" and type(arg5) ~= "nil" then spellArg = arg5 end
        local spellName = Tattle.ResolveSpellName(spellArg)
        if type(spellName) == "nil" then spellName = SpellNameFor(spellArg) end

        -- Is the caster argument a plain token this probe can name, a secret the
        -- client will answer queries for but not let be printed, or nothing?
        local okName, casterName = pcall(UnitName, arg1)
        local casterText = okName and describe(casterName) or "read refused"
        local okMe, isMe = pcall(UnitIsUnit, arg1, "player")
        local casterIsMe = (okMe and type(isMe) == "boolean") and (isMe and "YES" or "no") or "?"

        -- Hunt for a usable destination argument on UNIT_SPELLCAST_SENT. This is
        -- the question the whole victim-naming design turns on: if a build ever
        -- exposes one here, an alert can stop guessing from auras.
        --
        -- Candidates are identified by asking the client about them, not by ruling
        -- out the arguments this event is known to carry. Ruling them out means
        -- comparing the spell ID and the caster token to the candidate - exactly the
        -- comparisons a restricted client forbids - and a destination this client
        -- exposes as a secret unit is still a destination worth reporting.
        local destText, destIsMe = "none exposed", "n/a"
        if event == "UNIT_SPELLCAST_SENT" then
            for i = 4, 6 do
                local candidate = select(i, arg1, arg2, arg3, arg4, arg5, arg6)
                local okDm, dm = pcall(UnitIsUnit, candidate, "player")
                if okDm and type(dm) == "boolean" then
                    destIsMe = dm and "YES" or "no"
                    local okDn, dn = pcall(UnitName, candidate)
                    destText = (okDn and describe(dn)) or "secret (usable only via UnitIsUnit)"
                    break
                end
            end
        end

        print(string_format("|cffff6600[Tattle Probe]|r %s | spell: %s | caster: %s (isMe=%s) | dest: %s (isMe=%s)",
            event, describe(spellName), casterText, casterIsMe, destText, destIsMe))

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

        -- Fourth: does this client expose other players' targets? Two features are
        -- built on this one token: the watch list's "targeting you" section, and the
        -- Swapblaster module naming the other half of a swap (the toy marks nobody,
        -- so its victim is read from the caster's target). A build that never syncs
        -- it prints "none / not synced" no matter who is looking at you, and both
        -- features then say nothing rather than guessing -- which is the correct
        -- answer, not a broken one. Reading your own target off another player is not
        -- possible, so a blank here is not evidence that nobody is aiming at you.
        local entries = Tattle.GroupTargetEntries()
        local shown, watchers = 0, {}
        for _, entry in ipairs(entries) do
            -- Every name here went through a helper that proves the client will let
            -- it be printed before it is concatenated into a line. GetUnitShortName
            -- answers nil for a unit that does not exist, so no separate existence
            -- query is needed - and none of these reads is allowed to raise here.
            local name = Tattle.GetUnitShortName(entry.owner) or entry.owner
            local targetName = Tattle.GetUnitShortName(entry.target)
            if Tattle.IsSameUnit(entry.target, "player") then
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
    end

    -- Guarded end to end, because this is the instrument a player runs to find out
    -- what a client will not let an addon read. A refused lookup has to show up as a
    -- line in the report; it must not end the report, and it must not be the reason
    -- they give up on the one tool that answers the question.
    f:SetScript("OnEvent", function(frame, event, ...)
        local ok, err = pcall(Report, frame, event, ...)
        if not ok then
            print("|cffff6600[Tattle Probe]|r " .. event
                .. ": the probe could not read this event: " .. tostring(err))
        end
    end)

    Tattle._probeFrame = f
    print("Tattle probe ON (grouped only). Cast Swapblaster / Life Grip / Rescue -- on yourself AND on a friend -- and watch chat.")
end
