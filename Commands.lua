-- Commands.lua - the slash command. Configuration lives in the config panel;
-- this exists to open it and to answer the two questions a bug report needs:
-- which version is running, and what does the addon currently think it is doing.

local _, Tattle = ...

local print = print
local string_format = string.format
local table_concat = table.concat

local function HandleSlashCommand(msg)
    msg = (msg or ""):lower():trim()

    if msg == "" then
        if Tattle.Config then Tattle.Config:Toggle() end

    elseif msg == "version" then
        print("Tattle version " .. Tattle.VERSION)

    elseif msg == "on" then
        TattleDB.enabled = true
        print("Tattle enabled.")

    elseif msg == "off" then
        TattleDB.enabled = false
        print("Tattle disabled.")

    elseif msg == "debug" then
        TattleDB.debug = not TattleDB.debug
        print("Tattle debug " .. (TattleDB.debug and "ON" or "OFF"))

    elseif msg == "probe" then
        Tattle.ToggleProbe()

    elseif msg == "status" then
        print("Tattle v" .. Tattle.VERSION)
        print("  Enabled:", TattleDB.enabled and "ON" or "OFF")
        -- The core's own group rule, not the bare IsGrouped() global: that
        -- function is not in the retail API, and a nil here would error out of
        -- /tattle status at exactly the line meant for diagnosing problems.
        print("  Grouped:", Tattle.IsGrouped() and "YES" or "NO")
        print("  Debug:",   TattleDB.debug and "ON" or "OFF")
        print("Modules:")
        -- moduleOrder, not pairs(): a string-keyed table has no defined order, so
        -- pairs() would reshuffle this list (and the config tabs) between runs.
        for _, moduleId in ipairs(Tattle.moduleOrder) do
            local module = Tattle.modules[moduleId]
            local s = module and TattleDB.modules[moduleId]
            if s then
                local channel = (s.alerts and s.alerts.chatType) or "PRIVATE"
                -- Show what a chat alert would actually be sent on when that is
                -- not the channel named in the settings (an LFR raid, for one).
                local sent = (s.alerts and s.alerts.chat) and Tattle.ResolveChatChannel(channel) or nil
                local note = (sent and sent ~= channel)
                    and string_format(" (sent on %s in this group)", sent) or ""
                print("  [" .. module.name .. "]",
                    s.enabled and "ON" or "OFF",
                    "| scope:", module.noScope and "n/a" or (s.scope or "group"),
                    "| chat:", channel .. note)
            end
        end

        -- The watch list is the one piece of output that is not an alert, so it
        -- needs its own line to be debuggable.
        local display = TattleDB.modules.silencer and TattleDB.modules.silencer.display
        if display then
            local sections = {}
            if display.showWearers then sections[#sections + 1] = "Neural Silencers" end
            if display.showWatchers then sections[#sections + 1] = "targeting me" end
            print("  Watch list:", display.showList
                and ("ON (" .. (sections[1] and table_concat(sections, ", ") or "no sections") .. ")")
                or "OFF")
        end

    else
        print("Tattle: /tattle [version|on|off|debug|probe|status]")
    end
end

-- One command, and it is the name the addon has. Accepting the old name as a
-- hidden alias would mean shipping two spellings of the same thing forever -- a
-- `/snitch` in someone's macro that quietly works is worse than one that fails
-- and sends them looking for the new command.
SLASH_TATTLE1 = "/tattle"
SlashCmdList["TATTLE"] = HandleSlashCommand
