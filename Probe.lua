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
local string_lower = string.lower
local table_concat = table.concat
local table_sort = table.sort
local pcall = pcall
local _G = _G

local PREFIX = "|cffff6600[Tattle Probe]|r"

-- The three auras whose visibility decides what Tattle can say. Not guessed at:
-- Leap of Faith is what a completed grip leaves on the person who was pulled,
-- Rescue is what a completed rescue leaves on both halves of the flight, and
-- Neural Silencer is the buff every "it failed because ..." alert is built on.
-- If the first two come back "none visible", naming a victim is impossible on
-- this client; if the third does, the watch list and the blocked-cast wording
-- both go quiet. Same IDs the modules watch, listed here on purpose: a probe that
-- reads its expectations out of the modules it is checking proves nothing.
local PROBE_AURA_SPELL_IDS = { 73325, 370666, 156779 }

-- The cast whose position is sampled, and the aura whose readability decides the
-- watch list. Copies again, for the reason above: the probe is measuring whether
-- the addon's assumptions hold, so it cannot read those assumptions out of the
-- addon. 161399 is the toy's `Swap` cast - not 162217, which is the *crafting*
-- spell that happens to be named Swapblaster, and not 182081, which is the
-- explosion that fires when the swap backfires.
local PROBE_SAMPLED_SPELL_IDS = { 161399 }
local PROBE_SILENCER_SPELL_ID = 156779

-- How the probe writes about a value it may not be allowed to look at: the value
-- when the client will let it be printed, and a sentence about what stopped it when
-- it will not. The probe exists to answer "what does this client expose", so
-- "secret (not printable)" is an answer, and "none" is a different answer.
local function describe(value)
    local plain = Tattle.PlainText(value)
    if plain then return plain end
    -- Numbers need their own branch. Tattle.PlainText is string-only on purpose, so
    -- without this a plain spell ID - which is what a cast event's spell argument
    -- normally is - prints as "none", and "none" in this file means "the client sent
    -- nothing at all". Reporting 161399 as absent is precisely the confusion the rest
    -- of this file is organised around avoiding, and the payload dump below would have
    -- hidden the arg 3 / arg 4 mistake instead of exposing it.
    if type(value) == "number" then
        if Tattle.IsSecretValue(value) then return "secret (number not readable)" end
        return tostring(value)
    end
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

-- A cast or secret API, looked up when it is called rather than cached at load
-- time. "This build does not have it" is one of the answers this file exists to
-- give, and a nil cached at load cannot tell that apart from a typo in this file.
-- Passing several names tries them in order, which is how a renamed API still gets
-- measured: 12.0.0 added `UnitIsSpellTarget` and both the 12.1.5 and 12.1.7 docs
-- know only `PlayerIsSpellTarget`.
local function GlobalFunction(...)
    for i = 1, select("#", ...) do
        local candidate = _G[select(i, ...)]
        if type(candidate) == "function" then return candidate end
    end
    return nil
end

-- Ask the client a yes/no question and render the answer in the states that
-- genuinely differ: what it answered, that it had nothing to say, that it refused,
-- and that the API is not in this build at all. Folding the last three into "no" is
-- the mistake this whole file exists to prevent.
--
-- A secret boolean still reports type() == "boolean", and a secret number still
-- reports "number", so the only way to tell either apart from a value an `if` may
-- test is to attempt the test and see whether the client refused.
local function AskAnswer(fn, ...)
    if not fn then return "absent" end
    local ok, value = pcall(fn, ...)
    if not ok then return "refused" end
    if type(value) == "nil" then return "no answer" end
    if type(value) == "boolean" then
        if not pcall(function() return value == value end) then return "secret (untestable)" end
        return value and "YES" or "no"
    end
    if type(value) == "number" then
        if not pcall(function() return value == value end) then return "secret (unreadable number)" end
        return tostring(value)
    end
    return describe(value)
end

-- The same question aimed at a namespaced API, which is where most of the answers
-- about restrictions live (C_ChatInfo, C_RestrictedActions, C_CombatLog, SecretUtil).
local function AskNamespace(tableName, fnName, ...)
    local container = _G[tableName]
    if type(container) ~= "table" then return string_format("absent (%s)", tableName) end
    if type(container[fnName]) ~= "function" then return "absent" end
    return AskAnswer(container[fnName], ...)
end

-- "Is the cast this line is about the one whose positions I sample?" The numeric
-- comparison is attempted first - one attempt, and it succeeds in the ordinary case
-- - and the resolved spell name is used only if the client refused the number,
-- because a secret spell ID raises on `==`. `type()` rather than `~= nil` for the
-- same reason: comparing a secret against nil is still a comparison.
local function IsSampledSpell(spellArg, spellName)
    if type(spellArg) ~= "nil" then
        for _, wanted in ipairs(PROBE_SAMPLED_SPELL_IDS) do
            local ok, same = pcall(function() return spellArg == wanted end)
            if ok then return same end
        end
    end
    if type(spellName) == "string" then
        for _, wanted in ipairs(PROBE_SAMPLED_SPELL_IDS) do
            local plain = SpellNameFor(wanted)
            local ok, same = pcall(function() return spellName == plain end)
            if ok and same then return true end
        end
    end
    return false
end

local function TrimRealmSuffix(name) return (name:gsub("%-.*", "")) end

-- A destination name off a cast event, matched to a group token. Both sides go
-- through helpers that prove the client will let them be printed before anything is
-- compared, and realm suffixes are trimmed and case folded because the two sides
-- come from different APIs and are not spelled alike ("Pancakes" beside
-- "Pancakes-Area52"). A member whose name the client will not print cannot be
-- matched here at all, which is a fact about the client rather than a miss.
local function MemberTokenForName(name)
    local want = string_lower(TrimRealmSuffix(name))
    for _, token in ipairs(Tattle.GroupUnitTokens()) do
        local ok, unitName = pcall(UnitName, token)
        local plain = (ok and Tattle.PlainText(unitName)) or nil
        if plain then
            -- The length guard is not pedantry: an unnamed unit whose name comes back
            -- empty would otherwise match an empty destination, and "the caster sent
            -- it at nobody" would be reported as a named member. Lengths are only ever
            -- taken here on values already proved printable.
            local got = string_lower(TrimRealmSuffix(plain))
            if #got > 0 and got == want then return token end
            local short = Tattle.GetUnitShortName(token)
            if short then
                local gotShort = string_lower(TrimRealmSuffix(short))
                if #gotShort > 0 and gotShort == want then return token end
            end
        end
    end
    return nil
end

local function CountEntries(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

-- Where everybody in the group is standing. `UnitPosition` is documented the same
-- way in 12.1.5 and 12.1.7:
--     UnitPosition(unit) -> positionX, positionY, positionZ, mapID
-- carrying `SecretArguments = "AllowedWhenUntainted"` and no secrecy flag on any
-- return - while UnitName, UnitGUID, UnitClass and UnitInRaid each carry an
-- identity guard. That asymmetry is the reason the physical channel is worth
-- measuring at all: it may be the only thing left that answers about another
-- player. Whether it answers for a raid member standing forty yards away, across an
-- instance boundary, is precisely what a beta has to find out.
local function GroupPositions()
    local unitPosition = GlobalFunction("UnitPosition")
    if not unitPosition then return nil, "UnitPosition is not in this build" end

    local snapshot, readable, refused = {}, 0, 0
    for _, token in ipairs(Tattle.GroupUnitTokens()) do
        local ok, x, y, z, mapID = pcall(unitPosition, token)
        -- type() on its own is not enough: a secret number still reports "number"
        -- and raises on the first subtraction. The components are proved usable by
        -- attempting the arithmetic and the comparison that callers are about to do
        -- with them, which is the only question a restricted client answers honestly.
        if ok and type(x) == "number" and type(y) == "number"
                  and type(z) == "number" and type(mapID) == "number" then
            local movable = pcall(function() return x + y + z end)
            local identifiable = pcall(function() return mapID == mapID end)
            if movable and identifiable then
                snapshot[token] = { x = x, y = y, z = z, mapID = mapID }
                readable = readable + 1
            else
                refused = refused + 1
            end
        else
            refused = refused + 1
        end
    end
    if readable == 0 then
        return nil, string_format("no member has a readable position (%d refused or absent)", refused)
    end
    if refused > 0 then
        return snapshot, string_format("%d member(s) refused or had no position", refused)
    end
    return snapshot, nil
end

local function Distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return (dx * dx + dy * dy + dz * dz) ^ 0.5
end

-- Which member changed places with `mover`, or nil and the reason these two samples
-- say nothing. Two legs, deliberately not symmetric.
--
-- The leg that has to be tight is "the partner ENDS where the MOVER was sampled at
-- the start": the mover is the caster, and the caster is the half of a swap whose
-- position does not change during the channel - they move only at the instant the
-- swap resolves, and the two samples bracket that instant.
--
-- The other leg, "the mover ENDS where the PARTNER was sampled at the start", has
-- to absorb whatever the partner did with their legs for the length of the channel,
-- which outdoors on a fast mount is tens of yards and not the ~15 a walking estimate
-- suggests. It is a sanity bound rather than evidence: the discriminating work is
-- done by the tight leg, by requiring the mover to have moved at all, and by
-- refusing to choose when more than one member matches.
--
-- The asymmetry rests on how the toy behaves, not on anything the client asserts -
-- neither 12.1.5 nor 12.1.7 has any movement flag on UnitCastingInfo,
-- UnitChannelInfo or the cast events. If a future cast does move the caster part way
-- through, the tight leg rejects the match and this reports "no exchange", which is
-- a lost alert rather than a false accusation. That direction of failure is the
-- point.
local PROBE_MIN_MOVE       = 5   -- yards the mover must cover before a trade is measurable
local PROBE_TIGHT_LEG      = 12  -- yards: sample jitter plus a little caster drift
local PROBE_SANITY_BOUND   = 60  -- yards: keeps wrong-map and wrong-continent noise out

-- How far the group moved between two samples of the same cast. This is precisely
-- the quantity the loose leg below has to absorb, which is why it is measured rather
-- than looked up in a table of movement speeds: a constant has to be set for the
-- fastest member who might be moving, and a channel that lasts a couple of seconds
-- out of combat is exactly the window in which people are mounted between pulls. A
-- third sample mid channel turns that guess into an observation about the group that
-- actually cast.
local function MaxDriftBetween(before, later)
    local maxDrift, moved, compared = 0, 0, 0
    for token, a in pairs(before) do
        local b = later[token]
        if b and a.mapID == b.mapID then
            compared = compared + 1
            local drift = Distance(a, b)
            if drift > 0.5 then moved = moved + 1 end
            if drift > maxDrift then maxDrift = drift end
        end
    end
    return maxDrift, moved, compared
end

local function SwapPartner(before, after, mover)
    local moverStart, moverEnd = before[mover], after[mover]
    if not moverStart or not moverEnd then return nil, "the mover's own position is unreadable" end
    if moverStart.mapID ~= moverEnd.mapID then return nil, "the mover changed map between the samples" end

    local moved = Distance(moverStart, moverEnd)
    if moved < PROBE_MIN_MOVE then
        return nil, string_format("mover moved only %.1f yd - nothing measurable traded places", moved)
    end

    local partner, matches, tightDist = nil, 0, nil
    for token, start in pairs(before) do
        if token ~= mover then
            local finish = after[token]
            if finish and start.mapID == finish.mapID
               and finish.mapID == moverStart.mapID
               and start.mapID == moverEnd.mapID then
                local tight  = Distance(finish, moverStart)
                local sanity = Distance(start, moverEnd)
                if tight <= PROBE_TIGHT_LEG and sanity <= PROBE_SANITY_BOUND then
                    matches = matches + 1
                    partner = token
                    tightDist = tight
                end
            end
        end
    end

    if matches == 0 then return nil, "nobody ended up where the mover began" end
    if matches > 1 then
        return nil, string_format("%d members ended up where the mover began - ambiguous, not choosing", matches)
    end
    return partner, string_format("partner ended %.1f yd from the mover's start; mover moved %.1f yd", tightDist, moved)
end

-- What this build has, and what it will say out loud right now. Printed once, when
-- a player arms the probe, because every answer here changes the meaning of the cast
-- lines that follow: "dest: none exposed" says something quite different about a
-- client that has no UnitSpellTargetName than about one that has it and answered with
-- a secret.
local function ReportCapabilities()
    print(string_format("%s APIs in this build: spell-target=%s display-gate=%s target-name=%s target-class=%s position=%s", PREFIX,
        GlobalFunction("PlayerIsSpellTarget", "UnitIsSpellTarget") and "yes" or "NO",
        GlobalFunction("UnitShouldDisplaySpellTargetName") and "yes" or "NO",
        GlobalFunction("UnitSpellTargetName") and "yes" or "NO",
        GlobalFunction("UnitSpellTargetClass") and "yes" or "NO",
        GlobalFunction("UnitPosition") and "yes" or "NO"))

    print(string_format("%s secret surface: issecretvalue=%s canaccessvalue=%s CanCompareUnitTokens=%s C_SecretComparisons=%s secret-restrictions-active=%s",
        PREFIX,
        GlobalFunction("issecretvalue") and "yes" or "NO",
        GlobalFunction("canaccessvalue") and "yes" or "NO",
        -- The documented way to find out whether comparing two unit tokens is
        -- permitted, asked rather than guessed. UnitIsUnit is guarded by
        -- RequiresComparableUnitTokens, so a "no" here is why a target read fails.
        AskNamespace("SecretUtil", "CanCompareUnitTokens", "player", "player"),
        (_G.C_SecretComparisons and _G.C_SecretComparisons.Equal) and "yes" or "NO",
        AskNamespace("SecretUtil", "HasSecretRestrictions")))

    -- Whether another player's target is available at all has historically been a
    -- client setting as much as a patch fact. That setting's name is NOT verified
    -- against the 12.x docs - it appears in none of the 12.0.0 / 12.1.0 / 12.1.5 CVar
    -- added-and-removed lists, which shows only that it was neither added nor removed
    -- there, not that it exists - so this asks the client instead of letting any of
    -- the pipeline branch on an assumption. "no such setting" is a useful answer.
    local cvarName = "restrictRelativeTargetUnits"
    local cvarText = "not queryable"
    local getCVarInfo = GlobalFunction("GetCVarInfo")
    if getCVarInfo then
        local ok, name, current = pcall(getCVarInfo, cvarName)
        if not ok then
            cvarText = "refused"
        else
            -- A setting this client does not know comes back with an empty name, and
            -- the length is taken inside the pcall because a value that arrived from
            -- the client is never assumed to be measurable or printable: a secret value
            -- raises on the length, which is its own answer.
            local measured, known = pcall(function() return type(name) == "string" and #name > 0 end)
            if not measured then
                cvarText = "present, but not printable"
            elseif not known then
                cvarText = "no such setting in this client"
            else
                local formatted, text = pcall(string_format, "%s = %s", name, current)
                cvarText = formatted and text or "present, value not printable"
            end
        end
    end
    print(string_format("%s %s: %s", PREFIX, cvarName, cvarText))

    -- Which restrictions this client says are on. The enum is enumerated rather than
    -- written out, because the set of restriction types is exactly the kind of list a
    -- patch is entitled to grow.
    local restrictionTypes = _G.Enum and _G.Enum.AddOnRestrictionType
    if type(restrictionTypes) == "table" then
        local parts = {}
        for name, value in pairs(restrictionTypes) do
            parts[#parts + 1] = string_format("%s=%s", tostring(name),
                AskNamespace("C_RestrictedActions", "IsAddOnRestrictionActive", value))
        end
        if parts[1] then
            table_sort(parts)
            print(string_format("%s add-on restrictions active: %s", PREFIX, table_concat(parts, " ")))
        end
    end

    -- Chat, asked as two separate questions. InChatMessagingLockdown is the gate an
    -- alert needs before naming anybody in a channel. AreOutgoingAddonChatMessages-
    -- Restricted is NOT a substitute for it - it is realm-wide, about comms prefixes,
    -- and its own return carries SecretInChatMessagingLockdown, so the answer you
    -- need in order to decide whether chat is safe can itself arrive secret.
    print(string_format("%s chat: messaging-lockdown=%s | outgoing-addon-comms=%s | combat-log-restricted=%s",
        PREFIX,
        AskNamespace("C_ChatInfo", "InChatMessagingLockdown"),
        AskNamespace("C_ChatInfo", "AreOutgoingAddonChatMessagesRestricted"),
        AskNamespace("C_CombatLog", "IsCombatLogRestricted")))

    -- The one question the watch list depends on, put to the API built to answer it.
    -- Auras may be flagged never- or always-secret per spell, and that flag outranks
    -- the content restrictions, so "is Neural Silencer's aura readable on somebody
    -- else right now?" is answerable instead of guessable. Without it, an empty watch
    -- list in a key cannot tell "nobody wears one" from "we are not allowed to look".
    print(string_format("%s secrecy of %d (neural silencer) aura=%s | secrecy of %d (swap) cast=%s",
        PREFIX,
        PROBE_SILENCER_SPELL_ID,
        AskNamespace("SecretUtil", "GetSpellAuraSecrecy", PROBE_SILENCER_SPELL_ID),
        PROBE_SAMPLED_SPELL_IDS[1],
        AskNamespace("SecretUtil", "GetSpellCastSecrecy", PROBE_SAMPLED_SPELL_IDS[1])))
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
    -- The third position sample. The generated docs list this event with the same
    -- payload as CHANNEL_START (unit, castGUID, spellID, castBarID) and no secret
    -- flags, and it arrives on the channel's own updates rather than once a frame,
    -- so it costs nothing this probe is not already paying. It exists here to answer
    -- how much the people standing around the cast were moving while it ran, which is
    -- the number any position-based corroboration has to allow for - see the drift
    -- lines below.
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")

    -- Group context (who is protected, who is targeting you) does not change
    -- between one cast event and the next, so it is reported at most once a
    -- second. A raid-wide pull produces dozens of casts per second, and sweeping
    -- every member's auras for each of them would make the debug tool the most
    -- expensive thing in the addon.
    -- Position samples taken at a watched cast's CHANNEL_START, compared at its
    -- CHANNEL_STOP, keyed by the caster's plain group token. An event's own caster
    -- argument may be a secret value and a secret cannot be a table key, which is
    -- what GroupSlotOf is for. Every path that reads an entry also drops it, so an
    -- interrupted or unwatched cast cannot leave a record behind.
    local positionSamples = {}
    local positionMid = {}

    local function ReportPositionEvidence(event, caster, casterSlot)
        if not casterSlot then
            print(string_format("%s   position: not sampled (the caster is not a readable group token)", PREFIX))
            return
        end

        if event == "UNIT_SPELLCAST_CHANNEL_START" then
            local snapshot, why = GroupPositions()
            if not snapshot then
                print(string_format("%s   position: no start sample - %s", PREFIX, why))
                positionSamples[casterSlot] = nil
                return
            end
            positionSamples[casterSlot] = snapshot
            print(string_format("%s   position: start sample taken for %d member(s)%s", PREFIX,
                CountEntries(snapshot), why and (" - " .. why) or ""))

            -- The channel's own window, logged raw. The generated docs name these
            -- returns startTimeMs and endTimeMs, and Blizzard's own cast bar divides
            -- them by 1000 before comparing against GetTime - so an addon that treats
            -- the difference as seconds is out by a factor of a thousand. That is not
            -- hypothetical here: Modules/Swapblaster.lua does exactly that, which is
            -- why a swap that finishes is announced as one that was cut short. This
            -- line is how a beta confirms the units from its own client instead of
            -- from a reading of the docs.
            local unitChannelInfo = GlobalFunction("UnitChannelInfo")
            if unitChannelInfo then
                -- Four placeholders, not three: pcall's own status result shifts the
                -- API's returns by one, which is the same reason the module's own
                -- window helper counts them the same way.
                local ok, _, _, _, startTime, endTime = pcall(unitChannelInfo, casterSlot)
                if not ok then
                    print(string_format("%s   channel window: UnitChannelInfo refused this cast", PREFIX))
                elseif type(startTime) ~= "number" or type(endTime) ~= "number"
                    or Tattle.IsSecretValue(startTime) or Tattle.IsSecretValue(endTime) then
                    print(string_format("%s   channel window: no readable timing pair for this caster", PREFIX))
                else
                    print(string_format("%s   channel window: pair %.2f / %.2f, difference %.2f - seconds means %.2fs, milliseconds means %.2fs",
                        PREFIX, startTime, endTime, endTime - startTime, endTime - startTime,
                        (endTime - startTime) / 1000))
                end
            else
                print(string_format("%s   channel window: UnitChannelInfo is not in this build", PREFIX))
            end
            return
        end

        if event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
            local snapshot, why = GroupPositions()
            local before = positionSamples[casterSlot]
            if not before then
                print(string_format("%s   position: mid-channel sample not compared - no start sample for this caster", PREFIX))
                return
            end
            if not snapshot then
                print(string_format("%s   position: mid-channel sample unavailable - %s", PREFIX, why))
                return
            end
            positionMid[casterSlot] = snapshot
            local drift, moved, compared = MaxDriftBetween(before, snapshot)
            print(string_format("%s   position: mid-channel - group drifted up to %.1f yd since the start (%d of %d readable members moving)%s",
                PREFIX, drift, moved, compared, why and (" - " .. why) or ""))
            return
        end

        if event ~= "UNIT_SPELLCAST_CHANNEL_STOP" then return end

        local before = positionSamples[casterSlot]
        local mid = positionMid[casterSlot]
        positionSamples[casterSlot] = nil
        positionMid[casterSlot] = nil
        if not before then
            print(string_format("%s   position: no start sample for this caster (the channel began before the probe was armed)", PREFIX))
            return
        end

        local after, why = GroupPositions()
        if not after then
            print(string_format("%s   position: no stop sample - %s", PREFIX, why))
            return
        end
        if why then
            print(string_format("%s   position: stop sample incomplete - %s", PREFIX, why))
        end

        -- What the group was actually doing between the start and the end of this
        -- channel, printed before the verdict so a beta reader can see how much room
        -- the verdict needed. Whatever the answer turns out to be, it is a measurement
        -- of this group in this content rather than an assumption about who was
        -- mounted, and it is the only honest way to decide how tight the leg above
        -- could safely be made.
        if mid then
            local drift, moved, compared = MaxDriftBetween(before, mid)
            print(string_format("%s   position: drift observed before the swap resolved: up to %.1f yd (%d of %d readable members moving)",
                PREFIX, drift, moved, compared))
        else
            print(string_format("%s   position: no mid-channel sample (this build sent no CHANNEL_UPDATE for the cast)", PREFIX))
        end

        local partner, detail = SwapPartner(before, after, casterSlot)
        if not partner then
            print(string_format("%s   position: no exchange reported - %s", PREFIX, detail))
            return
        end
        local partnerName = Tattle.GetUnitShortName(partner) or partner
        print(string_format("%s   position: %s [%s] traded places with the caster (%s)", PREFIX,
            partnerName, partner, detail))

        -- The comparison the alert design turns on: the caster's own target read
        -- against what physically happened. Agreement is the ordinary case and says
        -- the target read can be trusted in this content; disagreement is what a
        -- @mouseover cast looks like, and the target read is the half that is wrong.
        -- Two people crossing paths is also what it looks like, which is why the
        -- ambiguity rule above has to refuse rather than pick.
        local targetRead = Tattle.GroupMemberTargetOf(caster)
        if not targetRead then
            print(string_format("%s   target read: none - an alert would have named nobody for a swap that happened", PREFIX))
        elseif targetRead == partner then
            print(string_format("%s   target read: agrees with the exchange", PREFIX))
        else
            print(string_format("%s   target read: DISAGREES - read %s [%s], exchange says %s [%s]; naming the target read would accuse the wrong member",
                PREFIX, Tattle.GetUnitShortName(targetRead) or "?", targetRead, partnerName, partner))
        end
    end

    local lastContext = 0

    -- The payloads, as this client's own generated docs define them for the events
    -- registered above (Blizzard_APIDocumentationGenerated/UnitDocumentation.lua,
    -- read from both 12.1.5 and 12.1.7 - they agree):
    --
    --   UNIT_SPELLCAST_SENT          unit, target:cstring, castGUID, spellID
    --   every other cast event here  unit, castGUID, spellID, castBarID
    --   CHANNEL_STOP / INTERRUPTED   interruptedBy follows spellID
    --
    -- SENT is the odd one out, and this file used to read every event the same way:
    -- arg 3 as the spell, which for SENT is the cast GUID, and a destination hunted
    -- for from arg 4 upwards, where SENT carries nothing at all while its destination
    -- sits at arg 2 as a name string. Each mistake reported "none exposed" about a
    -- client that had answered, which is why both had to be fixed before any
    -- destination line below could be believed - and before the live data people sent
    -- back from the beta could be believed.
    local function Report(_, event, ...)
        if not Tattle.IsGrouped() then return end

        local argc = select("#", ...)
        local caster = select(1, ...)

        -- type(), not `or`: a restricted client can hand the spell argument of a cast
        -- event over as a secret value, and testing one for truthiness is an operation
        -- on it. The same goes for the name ResolveSpellName hands back - it returns
        -- that unexamined on purpose, so a caller may not `or` it either. An if/else
        -- rather than `a and b or c` for the same reason: the nil that means "this
        -- event carries no fourth argument" must not fall through to the third.
        local spellArg
        if event == "UNIT_SPELLCAST_SENT" then
            spellArg = select(4, ...)
        else
            spellArg = select(3, ...)
        end
        local spellName = Tattle.ResolveSpellName(spellArg)
        if type(spellName) == "nil" then spellName = SpellNameFor(spellArg) end

        -- Is the caster argument a plain token this probe can name, a secret the
        -- client will answer queries for but not let be printed, or nothing?
        local okName, casterName = pcall(UnitName, caster)
        local casterText = okName and describe(casterName) or "read refused"
        local okMe, isMe = pcall(UnitIsUnit, caster, "player")
        local casterIsMe = (okMe and type(isMe) == "boolean") and (isMe and "YES" or "no") or "?"
        local casterSlot = Tattle.GroupSlotOf(caster)

        -- The destination, read at the argument that actually carries one. The
        -- documented type is a name string rather than a unit token, so the value is
        -- described rather than offered to UnitIsUnit, and only a name plain enough to
        -- be printed is matched against the group. The hunt above could not have found
        -- this: a name is not a unit token, so UnitIsUnit answers nothing about it,
        -- and the event that has never stopped exposing a destination printed "none
        -- exposed" every time.
        --
        -- What this line says decides whether an alert can name a victim at cast time
        -- at all, so a secret destination is spelled out as one rather than shortened
        -- to "secret": there is a destination, and the client will not let it be read.
        local destText, destIsMe = "none exposed", "n/a"
        if event == "UNIT_SPELLCAST_SENT" then
            local dest = select(2, ...)
            if type(dest) ~= "nil" then
                local plain = Tattle.PlainText(dest)
                if plain then
                    local token = MemberTokenForName(plain)
                    if token then
                        destText = string_format("%s [%s]", plain, token)
                        destIsMe = (token == "player") and "YES" or "no"
                    else
                        destText = string_format("%s (a name; not one of your group's readable members)", plain)
                    end
                elseif Tattle.IsSecretValue(dest) then
                    destText = "secret - a destination is present, and cannot be printed or compared"
                else
                    destText = describe(dest)
                end
            end
        end

        print(string_format("%s %s | spell: %s | caster: %s (isMe=%s) | dest: %s (isMe=%s)",
            PREFIX, event, describe(spellName), casterText, casterIsMe, destText, destIsMe))

        -- Everything the event carried, in argument order. Printed because a payload
        -- is the one part of this report a patch can change without telling anybody,
        -- and both mistakes above were "we kept looking where the payload used to be".
        local parts = {}
        for i = 1, argc do
            parts[#parts + 1] = string_format("arg%d=%s", i, describe(select(i, ...)))
        end
        print(string_format("%s   payload: %s", PREFIX, table_concat(parts, " ")))

        -- The sanctioned cast-target APIs, asked about the caster at the moment of the
        -- event. Whether they answer for *another* player's cast is documented
        -- nowhere: the flags say a name may come back secret, not how often it will,
        -- and the pipeline being built on them needs that measurement rather another
        -- opinion. A plain group token is passed rather than the event's own caster
        -- argument because these APIs accept secret arguments only when execution is
        -- untainted, and an addon's is not.
        if event ~= "UNIT_SPELLCAST_SENT" then
            if casterSlot then
                print(string_format("%s   target APIs: IsSpellTarget=%s ShouldDisplayName=%s TargetName=%s TargetClass=%s",
                    PREFIX,
                    AskAnswer(GlobalFunction("PlayerIsSpellTarget", "UnitIsSpellTarget"), casterSlot),
                    AskAnswer(GlobalFunction("UnitShouldDisplaySpellTargetName"), casterSlot),
                    AskAnswer(GlobalFunction("UnitSpellTargetName"), casterSlot),
                    AskAnswer(GlobalFunction("UnitSpellTargetClass"), casterSlot)))
            else
                print(string_format("%s   target APIs: not asked - the caster is not a readable token of your group", PREFIX))
            end
        end

        -- Position evidence, sampled on the swap's own two events. Reported whether or
        -- not the addon could ever act on it: this is how a beta finds out what a pair
        -- of samples would have concluded, and whether the caster's own target read
        -- agrees with it, which is the question a @mouseover cast answers and a hard
        -- target cannot.
        if IsSampledSpell(spellArg, spellName) then
            ReportPositionEvidence(event, caster, casterSlot)
        end

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
    ReportCapabilities()
end
