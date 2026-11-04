-- Config.lua - Configuration panel (one tabbed window)
local _, Tattle = ...

Tattle.Config = {}

local Config = Tattle.Config

-- ============================================================================
-- Localize Globals (Performance)
-- ============================================================================

local _G = _G
local ipairs = ipairs
local type = type
local tonumber = tonumber
local tostring = tostring
local string_format = string.format
local table_concat = table.concat
local math_abs = math.abs
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local CreateFrame = CreateFrame
local PlaySound = PlaySound
local C_Timer = C_Timer
local GameTooltip = GameTooltip
local UIDropDownMenu_Initialize = UIDropDownMenu_Initialize
local UIDropDownMenu_CreateInfo = UIDropDownMenu_CreateInfo
local UIDropDownMenu_AddButton = UIDropDownMenu_AddButton
local UIDropDownMenu_SetWidth = UIDropDownMenu_SetWidth
local UIDropDownMenu_SetText = UIDropDownMenu_SetText

-- ============================================================================
-- Constants
-- ============================================================================

local CONFIG_PANEL_WIDTH = 700
-- The panel is sized to whatever its tallest tab actually occupies -- see
-- CreateConfigPanel, where every tab builder hands back the depth it used. These
-- two are the floor and the padding, not the height: a hardcoded 700 was a
-- standing invitation for the next option added to any tab to spill over the
-- bottom edge, and a panel is not a scroll frame.
local PANEL_MIN_HEIGHT = 480
local PANEL_BOTTOM_PAD = 16

local TAB_BUTTON_LEFT = 20
local TAB_BUTTON_Y    = -35
local TAB_BUTTON_GAP  = 5

local TAB_LEFT   = 20
local TAB_TOP    = -70
local TAB_RIGHT  = -20
local TAB_BOTTOM = 20

local CONTENT_WIDTH  = CONFIG_PANEL_WIDTH - TAB_LEFT + TAB_RIGHT            -- 660
-- The content area's height is whatever the panel ends up being: containers are
-- anchored to the panel on all four sides (see CreateTabContainer), so sizing the
-- panel sizes every tab with it.

local LABEL_X       = 20
local DROPDOWN_X    = 90
local CHECKBOX_ROW  = 32
local DROPDOWN_ROW  = 40
local SLIDER_ROW    = 62

local EDITOR_WIDTH  = 620
local EDITOR_HEIGHT = 140

-- Sound effect options
local SOUND_OPTIONS = {
    {text = "Raid Warning", value = SOUNDKIT.RAID_WARNING or 8959},
    {text = "Ready Check", value = SOUNDKIT.READY_CHECK or 8960},
    {text = "Alarm Clock", value = SOUNDKIT.ALARM_CLOCK_WARNING_3 or 12867},
    {text = "Level Up", value = SOUNDKIT.LEVEL_UP or 888},
    {text = "Achievement", value = SOUNDKIT.ACHIEVEMENT_MENU_OPEN or 3337},
}

local SCOPE_OPTIONS = {
    {text = "Whole group", value = "group"},
    {text = "Only me",     value = "self"},
}

-- "PRIVATE" = chat window only (no SendChatMessage).
-- Raid and Party are resolved against the group you are actually in before they
-- are sent (see Tattle.ResolveChatChannel), which is what makes "Raid" work in a
-- Looking for Raid group instead of vanishing. "Instance" asks for that resolved
-- channel directly.
local CHAT_TYPE_OPTIONS = {
    {text = "Private (console only)", value = "PRIVATE"},
    {text = "Say",       value = "SAY"},
    {text = "Yell",      value = "YELL"},
    {text = "Party",     value = "PARTY"},
    {text = "Raid",      value = "RAID"},
    {text = "Instance",  value = "INSTANCE_CHAT"},
}

local ALERT_COLORS = {
    {name = "Red",    r = 1.0, g = 0.2, b = 0.2},
    {name = "Orange", r = 1.0, g = 0.6, b = 0.1},
    {name = "Yellow", r = 1.0, g = 1.0, b = 0.2},
    {name = "Green",  r = 0.2, g = 1.0, b = 0.2},
    {name = "Cyan",   r = 0.2, g = 1.0, b = 1.0},
    {name = "Blue",   r = 0.3, g = 0.5, b = 1.0},
    {name = "Purple", r = 0.7, g = 0.3, b = 1.0},
    {name = "White",  r = 1.0, g = 1.0, b = 1.0},
}

-- ============================================================================
-- Spell ID Helpers
-- ============================================================================


-- ============================================================================
-- Control Helpers
-- ============================================================================

local function AddCheckbox(container, y, label, getValue, setValue)
    local checkbox = CreateFrame("CheckButton", nil, container, "UICheckButtonTemplate")
    checkbox:SetPoint("TOPLEFT", 0, y)
    checkbox.text = checkbox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    checkbox.text:SetPoint("LEFT", checkbox, "RIGHT", 5, 0)
    checkbox.text:SetText(label)
    checkbox:SetChecked(getValue() and true or false)
    checkbox:SetScript("OnClick", function(self)
        setValue(self:GetChecked() and true or false)
    end)

    container.refreshers[#container.refreshers + 1] = function()
        checkbox:SetChecked(getValue() and true or false)
    end
    return checkbox
end

local function AddDropdown(container, y, labelText, width, options, getValue, setValue)
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", LABEL_X, y)
    label:SetText(labelText)

    local dropdown = CreateFrame("Frame", nil, container, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", DROPDOWN_X, y + 5)
    UIDropDownMenu_SetWidth(dropdown, width)

    local function textFor(value)
        for _, option in ipairs(options) do
            if option.value == value then return option.text end
        end
        return options[1].text
    end

    UIDropDownMenu_Initialize(dropdown, function(self, level)
        for _, option in ipairs(options) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = option.text
            info.value = option.value
            info.func = function()
                setValue(option.value)
                UIDropDownMenu_SetText(dropdown, option.text)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    UIDropDownMenu_SetText(dropdown, textFor(getValue()))

    container.refreshers[#container.refreshers + 1] = function()
        UIDropDownMenu_SetText(dropdown, textFor(getValue()))
    end
    return dropdown
end

-- Exposed so a module can add its own controls to its tab (see
-- Modules/Silencer.lua's extraContent) without reinventing the widgets.
Config.AddCheckbox = AddCheckbox
Config.AddDropdown = AddDropdown
-- The row pitch the controls above assume. A module that lays out its own tab
-- extras (Modules/Silencer.lua) has to step by the same amount or its rows land
-- half on top of the next one, and a duplicate constant in a second file is how
-- those two drift apart.
Config.CHECKBOX_ROW = CHECKBOX_ROW
Config.DROPDOWN_ROW = DROPDOWN_ROW

-- Labelled OptionsSliderTemplate with a value readout under the handle.
-- A plain function like the other control helpers. It used to be declared
-- `Config:GetSlider(...)`, which quietly makes `self` the Config table and buys
-- nothing: nothing in the body uses it, and the colon at the call site was the only
-- thing suggesting this widget had state of its own.
local function AddSlider(container, y, labelText, width, minValue, maxValue, stepValue, initialValue, lowText, highText, formatFunc, onValueChanged)
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 0, y)
    label:SetText(labelText)

    local slider = CreateFrame("Slider", nil, container, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 0, y - 22)
    slider:SetWidth(width)
    slider:SetMinMaxValues(minValue, maxValue)
    slider:SetValueStep(stepValue)
    slider:SetObeyStepOnDrag(true)

    -- The end labels are ours rather than the template's. `OptionsSliderTemplate`
    -- adds its own as `$parentLow` / `$parentHigh`, which only become reachable
    -- once the slider is created *named* - this one is anonymous, so there is no
    -- $parent to prefix and `slider.Low` is nil. Asking the template for a widget
    -- it has no way to hand over is exactly the kind of bug a stub that answers
    -- every unknown key with a no-op will hide, so the two strings are made here.
    local lowLabel = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lowLabel:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -2)
    lowLabel:SetText(lowText)

    local highLabel = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    highLabel:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -2)
    highLabel:SetText(highText)

    -- centred under the handle, between the two end labels
    slider.valueText = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    slider.valueText:SetPoint("TOP", slider, "BOTTOM", 0, -2)
    slider.valueText:SetText(formatFunc(initialValue))

    slider:SetScript("OnValueChanged", function(self, value)
        value = math_floor(value / stepValue + 0.5) * stepValue
        value = math_floor(value * 100 + 0.5) / 100
        self.valueText:SetText(formatFunc(value))
        onValueChanged(value)
    end)
    slider:SetValue(initialValue)

    return slider
end

-- ============================================================================
-- Tabs
-- ============================================================================

local ShowTab

ShowTab = function(index)
    local panel = Config.frame
    if not panel or not panel.tabs[index] then return end

    panel.currentTab = index

    for i, content in ipairs(panel.tabs) do
        if i == index then content:Show() else content:Hide() end
    end
    for i, button in ipairs(panel.tabButtons) do
        button:SetAlpha(i == index and 1.0 or 0.6)
    end

    local tab = panel.tabs[index]
    if tab.warning then
        if TattleDB.enabled then tab.warning:Hide() else tab.warning:Show() end
    end
    for _, refresh in ipairs(tab.refreshers) do
        refresh()
    end
end

local function CreateTabButton(panel, text, tabButtons, isSmall)
    -- Measured with the button template's own font size so the label can never
    -- be clipped; tabs only ever get narrower padding, never a too-narrow button.
    panel.tabMeasure:SetText(text)

    local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    button:SetHeight(isSmall and 22 or 26)
    button:SetText(text)
    button:SetWidth(panel.tabMeasure:GetStringWidth() + (isSmall and 20 or 24))

    local x = TAB_BUTTON_LEFT
    for _, existing in ipairs(tabButtons) do
        x = x + existing:GetWidth() + TAB_BUTTON_GAP
    end
    button:SetPoint("TOPLEFT", panel, "TOPLEFT", x, TAB_BUTTON_Y)

    tabButtons[#tabButtons + 1] = button
    local index = #tabButtons
    button:SetScript("OnClick", function() ShowTab(index) end)
    return button
end

local function CreateTabContainer(panel)
    local content = CreateFrame("Frame", nil, panel)
    content:SetPoint("TOPLEFT", panel, "TOPLEFT", TAB_LEFT, TAB_TOP)
    content:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", TAB_RIGHT, TAB_BOTTOM)
    content.refreshers = {}
    content:Hide()
    panel.tabs[#panel.tabs + 1] = content
    return content
end

-- ============================================================================
-- About Tab
-- ============================================================================

local function BuildAboutTab(container)
    local y = 0

    local nameLabel = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    nameLabel:SetPoint("TOPLEFT", 0, y)
    nameLabel:SetText("Tattle v" .. (Tattle.VERSION or "Unknown"))
    y = y - 34

    local desc = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", 0, y)
    desc:SetPoint("TOPRIGHT", 0, y)
    desc:SetJustifyH("LEFT")
    desc:SetSpacing(3)
    desc:SetText("Watches your party and raid for the ways a group member can move you around: the Swapblaster toy, out-of-combat Life Grip from a Priest, and out-of-combat Rescue from an Evoker. A fourth module tracks who in the group is wearing a Neural Silencer (the aura that blocks all three) and can keep a small list of them, plus whoever is targeting you, on screen. Every module has its own alert settings on its own tab.")
    y = y - 70

    local commandHeader = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    commandHeader:SetPoint("TOPLEFT", 0, y)
    commandHeader:SetText("Slash commands")
    y = y - 24

    local commands = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    commands:SetPoint("TOPLEFT", 12, y)
    commands:SetPoint("TOPRIGHT", 0, y)
    commands:SetJustifyH("LEFT")
    commands:SetSpacing(3)
    commands:SetText(
        "/tattle          open or close this window\n" ..
        "/tattle on       enable all alerts\n" ..
        "/tattle off      disable all alerts\n" ..
        "/tattle debug    toggle debug printing\n" ..
        "/tattle probe    toggle the event probe\n" ..
        "/tattle status   print the current settings\n" ..
        "/tattle version  print the version"
    )
    y = y - 110

    local noteHeader = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    noteHeader:SetPoint("TOPLEFT", 0, y)
    noteHeader:SetText("Notes")
    y = y - 24

    local notes = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    notes:SetPoint("TOPLEFT", 12, y)
    notes:SetPoint("TOPRIGHT", 0, y)
    notes:SetJustifyH("LEFT")
    notes:SetSpacing(3)
    notes:SetText(
        "Alerts only fire while you are in a party or a raid. Out of a group, Tattle stays silent: nobody can swap, grip or rescue you without one, so there is nothing to look at. Nothing is announced while the caster is fighting either: Life Grip and Rescue are instant, so one that lands mid-fight is a raid tool doing a job, and the Swapblaster cannot be fired in combat at all - for that one only the decision to fire is judged, so a swap you started while walking still tells you where it ended up.\n\n" ..
        "A chat alert set to Raid is resolved against the group you are actually in, so it also lands in a Looking for Raid raid.\n\n" ..
        "Blizzard's 12.x rules shape what can be detected. COMBAT_LOG_EVENT_UNFILTERED was removed in 12.0.0, " ..
        "so no cast event says who another player's spell was aimed at, and inside instances the spell ID is a " ..
        "secret value (Tattle matches spell names instead). Life Grip and Rescue put an aura on the victim, so " ..
        "those can be attributed by name. Swapblaster marks nobody, so it is reported without a victim. Run " ..
        "/tattle probe to confirm what your client actually exposes before you trust a spell ID or an \"Only me\" filter."
    )
    -- Measured rather than guessed: a paragraph's height depends on the client's
    -- font and the player's window width, which is exactly what a hardcoded row
    -- count gets wrong.
    return y - notes:GetStringHeight() - 4
end

-- ============================================================================
-- General Tab
-- ============================================================================

local function BuildGeneralTab(container)
    local y = 0

    AddCheckbox(container, y, "Enable Tattle",
        function() return TattleDB.enabled end,
        function(value) TattleDB.enabled = value end)
    y = y - 36

    AddCheckbox(container, y, "Debug mode",
        function() return TattleDB.debug end,
        function(value) TattleDB.debug = value end)
    y = y - 42

    local probeBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    probeBtn:SetSize(170, 24)
    probeBtn:SetPoint("TOPLEFT", 0, y)
    probeBtn:SetText("Toggle Event Probe")
    probeBtn:SetScript("OnClick", function()
        Tattle.ToggleProbe()
    end)
    y = y - 34

    local probeHelp = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    probeHelp:SetPoint("TOPLEFT", 0, y)
    probeHelp:SetPoint("TOPRIGHT", 0, y)
    probeHelp:SetJustifyH("LEFT")
    probeHelp:SetSpacing(3)
    probeHelp:SetText(
        "/tattle probe prints every UNIT_SPELLCAST_* event to chat with the spell name, who cast it, " ..
        "whether the caster is you, and whether any destination unit is exposed. Use it in a group to " ..
        "confirm spell IDs on the module tabs and to see whether \"Only me\" monitoring is actually " ..
        "possible in the current build."
    )
    y = y - 84

    local divider = container:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.5, 0.5, 0.5, 0.5)
    divider:SetSize(CONTENT_WIDTH, 1)
    divider:SetPoint("TOPLEFT", 0, y)
    y = y - 20

    local footer = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    footer:SetPoint("TOPLEFT", 0, y)
    footer:SetPoint("TOPRIGHT", 0, y)
    footer:SetJustifyH("LEFT")
    footer:SetText("Settings save automatically. Use /reload to apply changes that affect spell IDs.")
    return y - footer:GetStringHeight() - 4
end

-- ============================================================================
-- Screen Alerts Tab
-- ============================================================================

local function BuildScreenAlertTab(container)
    local settings = TattleDB.screenAlert
    if not settings then return end

    local swatches = {}
    local function RefreshSwatches()
        for _, swatch in ipairs(swatches) do
            local color = settings.color
            local selected = color
                and math_abs((color.r or 0) - swatch.color.r) < 0.01
                and math_abs((color.g or 0) - swatch.color.g) < 0.01
                and math_abs((color.b or 0) - swatch.color.b) < 0.01
            if selected then swatch.dim:Hide() else swatch.dim:Show() end
        end
    end

    local fontOptions = {}
    local fonts = Tattle.ScreenAlert and Tattle.ScreenAlert.FONTS or {}
    for i, font in ipairs(fonts) do
        fontOptions[i] = {text = font.name, value = i}
    end

    local y = 0

    if #fontOptions > 0 then
        AddDropdown(container, y, "Font:", 200, fontOptions,
            function() return settings.font or 1 end,
            function(value)
                settings.font = value
                if Tattle.ScreenAlert then Tattle.ScreenAlert:ApplySettings() end
            end)
    end
    y = y - DROPDOWN_ROW

    AddSlider(container, y, "Font Size:", 420, 16, 72, 2, settings.fontSize or 32,
        "16", "72",
        function(value) return tostring(value) end,
        function(value)
            settings.fontSize = value
            if Tattle.ScreenAlert then Tattle.ScreenAlert:ApplySettings() end
        end)
    y = y - SLIDER_ROW

    AddSlider(container, y, "Display Duration:", 420, 1, 10, 0.5, settings.duration or 3,
        "1s", "10s",
        function(value) return string_format("%.1fs", value) end,
        function(value) settings.duration = value end)
    y = y - SLIDER_ROW

    local colorLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colorLabel:SetPoint("TOPLEFT", 0, y)
    colorLabel:SetText("Text color:")
    y = y - 24

    local x = 0
    for _, color in ipairs(ALERT_COLORS) do
        local swatch = CreateFrame("Button", nil, container)
        swatch:SetSize(26, 26)
        swatch:SetPoint("TOPLEFT", x, y)
        swatch.color = color

        local fill = swatch:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints(swatch)
        fill:SetColorTexture(color.r, color.g, color.b, 1)
        swatch:SetNormalTexture(fill)

        swatch.dim = swatch:CreateTexture(nil, "OVERLAY")
        swatch.dim:SetAllPoints(swatch)
        swatch.dim:SetColorTexture(0, 0, 0, 0.65)

        swatch:SetScript("OnClick", function()
            settings.color = {
                r = color.r,
                g = color.g,
                b = color.b,
                a = (settings.color and settings.color.a) or 1,
            }
            if Tattle.ScreenAlert then Tattle.ScreenAlert:ApplySettings() end
            RefreshSwatches()
        end)
        swatch:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(color.name, color.r, color.g, color.b)
            GameTooltip:Show()
        end)
        swatch:SetScript("OnLeave", function() GameTooltip:Hide() end)

        swatches[#swatches + 1] = swatch
        x = x + 32
    end
    container.refreshers[#container.refreshers + 1] = RefreshSwatches
    RefreshSwatches()
    y = y - 38

    AddCheckbox(container, y, "Show background",
        function() return settings.showBackground end,
        function(value)
            settings.showBackground = value
            if Tattle.ScreenAlert then Tattle.ScreenAlert:ApplySettings() end
        end)
    y = y - 38

    local isDragMode = false
    local positionBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    positionBtn:SetSize(170, 26)
    positionBtn:SetPoint("TOPLEFT", 0, y)
    positionBtn:SetText("Reposition Alert")
    positionBtn:SetScript("OnClick", function(self)
        if not Tattle.ScreenAlert then return end

        isDragMode = not isDragMode
        if isDragMode then
            Tattle.ScreenAlert:EnableDragMode()
            self:SetText("Done Repositioning")
        else
            Tattle.ScreenAlert:DisableDragMode()
            self:SetText("Reposition Alert")
        end
    end)

    local testBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    testBtn:SetSize(150, 26)
    testBtn:SetPoint("LEFT", positionBtn, "RIGHT", 10, 0)
    testBtn:SetText("Test Alert")
    testBtn:SetScript("OnClick", function()
        if Tattle.ScreenAlert then
            Tattle.ScreenAlert:Show("This is a test alert!\nResize and reposition as needed.")
        end
    end)
    y = y - 38

    local helpText = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    helpText:SetPoint("TOPLEFT", 0, y)
    helpText:SetPoint("TOPRIGHT", 0, y)
    helpText:SetJustifyH("LEFT")
    helpText:SetSpacing(2)
    helpText:SetText(
        "Use 'Reposition Alert' to drag the alert to your preferred location. Click 'Test Alert' to " ..
        "preview your changes. Font, size, duration, colour and background apply immediately. " ..
        "Whether a module shows a screen warning is set on that module's tab."
    )
    return y - helpText:GetStringHeight() - 4
end

-- ============================================================================
-- Module Tab Content
-- ============================================================================


-- A module tab is assembled from sections so a module that needs extra options
-- (the Silencer watch list) reuses the same controls instead of forking the
-- whole tab. Each section takes the current `y` and returns the next one.

local function AddDisabledWarning(container, y)
    local warning = CreateFrame("Frame", nil, container, "BackdropTemplate")
    warning:SetHeight(34)
    warning:SetPoint("TOPLEFT", container, "TOPLEFT", 0, y - 4)
    warning:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, y - 4)
    warning:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    warning:SetBackdropColor(0.8, 0.2, 0.2, 0.3)
    warning:SetBackdropBorderColor(0.8, 0.2, 0.2, 1)
    warning.text = warning:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    warning.text:SetPoint("CENTER", warning, "CENTER", 0, 0)
    warning.text:SetWidth(CONTENT_WIDTH - 16)
    warning.text:SetJustifyH("CENTER")
    warning.text:SetTextColor(1, 0.25, 0.25)
    warning.text:SetText("WARNING: Tattle is globally disabled (type /tattle on to enable) - this module will not alert")
    warning:Hide()
    container.warning = warning
    return y - 46
end

local function AddEnableControl(container, moduleSettings, y)
    AddCheckbox(container, y, "Enable module",
        function() return moduleSettings.enabled end,
        function(value) moduleSettings.enabled = value end)
    return y - CHECKBOX_ROW
end

-- Only cast-watching modules get a scope. A module that never filters a cast
-- (it watches auras instead) would be showing a control it does not honour.
local function AddScopeControl(container, moduleSettings, y)
    AddDropdown(container, y, "Monitor:", 150, SCOPE_OPTIONS,
        function() return moduleSettings.scope or "group" end,
        function(value) moduleSettings.scope = value end)
    y = y - DROPDOWN_ROW

    local scopeNote = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    scopeNote:SetPoint("TOPLEFT", LABEL_X, y)
    scopeNote:SetPoint("TOPRIGHT", 0, y)
    scopeNote:SetJustifyH("LEFT")
    scopeNote:SetText("\"Only me\" drops a cast only when it can prove it missed you. Life Grip and Rescue mark their victim with an aura, so they can be attributed; Swapblaster marks nobody, so it is always reported.")
    return y - 30
end

local function AddAlertControls(container, alerts, y)
    AddCheckbox(container, y, "Console output",
        function() return alerts.console end,
        function(value) alerts.console = value end)
    y = y - CHECKBOX_ROW

    AddCheckbox(container, y, "Chat message",
        function() return alerts.chat end,
        function(value) alerts.chat = value end)
    y = y - CHECKBOX_ROW

    AddDropdown(container, y, "Chat type:", 170, CHAT_TYPE_OPTIONS,
        function() return alerts.chatType or "PRIVATE" end,
        function(value) alerts.chatType = value end)
    y = y - DROPDOWN_ROW

    AddCheckbox(container, y, "Audio alert",
        function() return alerts.audio end,
        function(value) alerts.audio = value end)
    y = y - CHECKBOX_ROW

    local audioDropdown = AddDropdown(container, y, "Sound:", 150, SOUND_OPTIONS,
        function() return alerts.audioFile end,
        function(value) alerts.audioFile = value end)

    local testSoundBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    testSoundBtn:SetSize(90, 24)
    testSoundBtn:SetPoint("LEFT", audioDropdown, "RIGHT", -15, -2)
    testSoundBtn:SetText("Test Sound")
    testSoundBtn:SetScript("OnClick", function()
        -- Guarded for the same reason the real alert plays it guarded: the value
        -- comes from a dropdown of SOUNDKIT constants, and a patch that renames or
        -- retires one turns "Test Sound" into a Lua error dialog.
        local ok, err = pcall(PlaySound, alerts.audioFile)
        if not ok then
            print("Tattle: that sound is not available in this client -- " .. tostring(err))
        end
    end)
    y = y - DROPDOWN_ROW

    AddCheckbox(container, y, "Screen warning (appearance is set on the Screen Alerts tab)",
        function() return alerts.screen end,
        function(value) alerts.screen = value end)
    return y - CHECKBOX_ROW
end

-- The section wrapper is one label and a divider; everything interesting about the
-- editor itself lives in ConfigSpellIDs.lua.
local function AddSpellIDSection(container, moduleSettings, moduleId, y)
    local spellLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    spellLabel:SetPoint("TOPLEFT", 0, y)
    spellLabel:SetText("Spell IDs (one per line or comma separated)")

    local divider = container:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.5, 0.5, 0.5, 0.5)
    divider:SetSize(EDITOR_WIDTH, 1)
    divider:SetPoint("TOPLEFT", 0, y - 26)

    local defaults = (Tattle.GetModuleDefaults and Tattle.GetModuleDefaults(moduleId)) or {spellIDs = {}}
    return Config.BuildSpellIDEditor(container, moduleSettings, defaults, y)
end

local function BuildModuleTabContent(container, moduleId)
    local moduleSettings = TattleDB.modules and TattleDB.modules[moduleId]
    if not moduleSettings or not moduleSettings.alerts then return end
    local module = Tattle.modules and Tattle.modules[moduleId]

    local y = AddDisabledWarning(container, 0)
    y = AddEnableControl(container, moduleSettings, y)
    if not (module and module.noScope) then
        y = AddScopeControl(container, moduleSettings, y)
    end
    y = AddAlertControls(container, moduleSettings.alerts, y)

    -- Anything the module itself wants on its tab, between the shared alert
    -- controls and the spell ID editor.
    if module and module.extraContent then
        y = module.extraContent(container, moduleId, moduleSettings, y) or y
    end

    return AddSpellIDSection(container, moduleSettings, moduleId, y)
end

-- ============================================================================
-- Module Tab Registration
-- ============================================================================

-- One tab per registered module, in registration order, all of them built by the
-- same BuildModuleTabContent: a module contributes options (extraContent) rather
-- than its own tab layout, which is why there is no per-module builder hook here
-- and no `buildContent` field on the module record.
function Config:BuildModuleTabs()
    local tabs = {}
    for _, moduleId in ipairs(Tattle.moduleOrder or {}) do
        local module = Tattle.modules[moduleId]
        if module then
            tabs[#tabs + 1] = { moduleId = moduleId, name = module.tabName or module.name }
        end
    end
    self.moduleTabs = tabs
    return tabs
end

-- ============================================================================
-- Panel Creation
-- ============================================================================

local function CreateConfigPanel()
    local panel = CreateFrame("Frame", "TattleConfigPanel", UIParent, "BasicFrameTemplateWithInset")
    -- Set after the tabs are built, from what they actually occupied (below).
    panel:SetPoint("CENTER")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetFrameStrata("DIALOG")
    panel:Hide()

    panel.tabButtons = {}
    panel.tabs = {}

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    panel.title:SetPoint("TOP", 0, -5)
    panel.title:SetText("Tattle")

    -- Hidden measuring string: GetStringWidth on the template's own font is what
    -- lets tab buttons be packed left to right without hardcoding widths.
    panel.tabMeasure = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")

    -- Every builder returns the y it finished at -- a negative offset below the
    -- top of its tab -- so the window is built around the tallest tab instead of
    -- around a number picked when the addon had fewer options in it. Tabs are not
    -- clipped, so the failure mode of the old fixed 700 was an editor spilling off
    -- the bottom of the window whenever anyone added a row.
    local deepest = 0
    local function addTab(name, isSmall, builder, arg)
        local container = CreateTabContainer(panel)
        local bottom = builder(container, arg)
        if type(bottom) == "number" and bottom < deepest then
            deepest = bottom
        end
        CreateTabButton(panel, name, panel.tabButtons, isSmall)
    end

    addTab("About", false, BuildAboutTab)
    addTab("General", false, BuildGeneralTab)
    addTab("Screen Alerts", false, BuildScreenAlertTab)
    for _, moduleTab in ipairs(Config:BuildModuleTabs()) do
        addTab(moduleTab.name, true, BuildModuleTabContent, moduleTab.moduleId)
    end

    -- -deepest is how far the tallest tab reached below the top of the content
    -- area; the area itself starts -TAB_TOP below the top of the window and ends
    -- TAB_BOTTOM above its bottom.
    local needed = -deepest + PANEL_BOTTOM_PAD - TAB_TOP + TAB_BOTTOM
    panel:SetSize(CONFIG_PANEL_WIDTH, math_max(PANEL_MIN_HEIGHT, needed))

    panel.currentTab = 1
    panel.tabMeasure:SetText("")
    return panel
end

-- ============================================================================
-- Panel Management
-- ============================================================================

Config.frame = nil

function Config:Show()
    if not self.frame then
        self.frame = CreateConfigPanel()
    end
    self.frame:Show()
    ShowTab(self.frame.currentTab or 1)
end

function Config:Hide()
    if self.frame then
        self.frame:Hide()
    end
end

function Config:Toggle()
    if not self.frame then
        self:Show()
        return
    end

    if self.frame:IsVisible() then
        self:Hide()
    else
        self:Show()
    end
end

-- ============================================================================
-- Interface Options Registration
-- ============================================================================

function Config:RegisterInterfaceOptions()
    local settingsPanel = CreateFrame("Frame", "TattleSettingsPanel")
    settingsPanel.name = "Tattle"

    local title = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Tattle")

    local desc = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetPoint("TOPRIGHT", settingsPanel, "TOPRIGHT", -16, -32)
    desc:SetJustifyH("LEFT")
    desc:SetText("Alerts when a group member casts something that can be used to grief the group: Swapblaster, Life Grip, or Rescue. Also tracks the group's Neural Silencer wearers.")

    local openBtn = CreateFrame("Button", nil, settingsPanel, "UIPanelButtonTemplate")
    openBtn:SetSize(180, 30)
    openBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
    openBtn:SetText("Open Configuration")
    openBtn:SetScript("OnClick", function()
        Config:Show()
        Settings.Close()
    end)

    local slashInfo = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    slashInfo:SetPoint("TOPLEFT", openBtn, "BOTTOMLEFT", 0, -16)
    slashInfo:SetText("You can also use the slash command: /tattle")

    local category = Settings.RegisterCanvasLayoutCategory(settingsPanel, "Tattle")
    Settings.RegisterAddOnCategory(category)
    self.category = category
end
