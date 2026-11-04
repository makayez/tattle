-- ConfigSpellIDs.lua - the spell ID editor that sits at the bottom of every
-- module's tab, plus the two functions that decide what counts as an edit.
--
-- It is its own file because it is the fiddliest widget in the addon: a scroll
-- frame wrapping an EditBox whose height tracks its content, a Save button that
-- must be enabled only when the text really differs from what is stored, and a
-- Reset that has to put the field back to the shipped defaults rather than to
-- whatever the user typed last. None of it has anything to do with the rest of the
-- config panel's layout, and a change here should not need the panel open.
--
-- Matching is by spell name at runtime (see Core's ResolveSpellNames), so what a
-- user types here is a list of IDs to *look up*, not a list of strings to compare.
-- An ID the client does not know is reported in the debug log at login; it is not
-- silently dropped, and it is not refused here either, because a spell can be
-- added by a patch after this addon was written.

local _, Tattle = ...

local Config = Tattle.Config

local CreateFrame = CreateFrame
local C_Timer = C_Timer
local _G = _G
local tonumber = tonumber
local tostring = tostring
local type = type
local ipairs = ipairs
local string_format = string.format
local table_concat = table.concat
local math_max = math.max

local EDITOR_WIDTH  = 620
local EDITOR_HEIGHT = 140
local STATUS_ROW    = 20   -- the status line under the box

-- ============================================================================
-- Text <-> list of IDs
-- ============================================================================

-- Accepts anything a person is likely to paste in: comma separated, one per line,
-- or a mix. Non-numbers are ignored rather than rejected, and duplicates collapse
-- -- which is also what lets "has this been edited?" be answered by comparing the
-- normalised text instead of the raw keystrokes.
--
-- NOTE: this file returns a list to be resolved into spell names later; the IDs
-- are never compared to a cast directly.
local function ParseSpellIDList(text)
    local ids = {}
    if not text then return ids end

    local seen = {}
    for token in text:gmatch("[^,%s]+") do
        local id = tonumber(token)
        if id and id > 0 and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    return ids
end

-- One ID per line, always in the stored order: the comparison that enables Save
-- depends on the same normalisation on both sides.
local function SerializeSpellIDList(ids)
    if not ids then return "" end
    local lines = {}
    for i, id in ipairs(ids) do
        lines[i] = tostring(id)
    end
    return table_concat(lines, "\n")
end

-- ============================================================================
-- The editor
-- ============================================================================

-- Returns the y below everything it placed, so the panel can be sized to the
-- tallest tab instead of hoping a fixed height fits the tallest tab.
function Config.BuildSpellIDEditor(container, moduleSettings, defaults, labelY)

    local boxTop = labelY - 30
    local boxHeight = EDITOR_HEIGHT

    local box = CreateFrame("Frame", nil, container, "BackdropTemplate")
    box:SetSize(EDITOR_WIDTH, boxHeight)
    box:SetPoint("TOPLEFT", container, "TOPLEFT", 0, boxTop)
    box:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    box:SetBackdropColor(0, 0, 0, 0.8)

    local scrollFrame = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 8, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(_G.GameFontHighlightSmall)
    editBox:SetMaxLetters(0)
    editBox:EnableMouse(true)
    editBox:EnableKeyboard(true)
    editBox:SetJustifyH("LEFT")
    editBox:SetJustifyV("TOP")
    editBox:SetWidth(EDITOR_WIDTH - 44)
    editBox:SetHeight(boxHeight - 16)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scrollFrame:SetScrollChild(editBox)

    local function RefreshEditorHeight()
        local text = editBox:GetText() or ""
        local lines = 1
        for _ in text:gmatch("\n") do lines = lines + 1 end
        editBox:SetHeight(math_max(lines * 14 + 8, boxHeight - 16))
    end

    -- Clicking the frame or the scroll frame has to land the focus in the EditBox,
    -- otherwise a click on an unfocused editor looks like it did nothing.
    box:SetScript("OnMouseDown", function() editBox:SetFocus() end)
    scrollFrame:SetScript("OnMouseDown", function() editBox:SetFocus() end)

    local status = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -4)
    status:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -4)
    status:SetJustifyH("LEFT")

    local function storedText()
        local stored = moduleSettings.spellIDs
        if type(stored) == "table" and #stored > 0 then
            return SerializeSpellIDList(stored)
        end
        return SerializeSpellIDList(defaults.spellIDs)
    end

    local saveBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    saveBtn:SetSize(60, 22)
    saveBtn:SetPoint("TOPLEFT", container, "TOPLEFT", 330, labelY + 4)
    saveBtn:SetText("Save")
    saveBtn:Disable()

    local resetBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    resetBtn:SetSize(130, 22)
    resetBtn:SetPoint("LEFT", saveBtn, "RIGHT", 8, 0)
    resetBtn:SetText("Reset to Defaults")

    local function UpdateSaveState()
        if SerializeSpellIDList(ParseSpellIDList(editBox:GetText())) ~= storedText() then
            saveBtn:Enable()
        else
            saveBtn:Disable()
        end
    end

    local function Persist(text)
        local ids = ParseSpellIDList(text)
        moduleSettings.spellIDs = ids
        status:SetText(string_format("Saved %d spell ID(s). Type /reload to apply them.", #ids))
        C_Timer.After(3, function() status:SetText("") end)
        UpdateSaveState()
    end

    saveBtn:SetScript("OnClick", function() Persist(editBox:GetText()) end)
    resetBtn:SetScript("OnClick", function()
        editBox:SetText(SerializeSpellIDList(defaults.spellIDs))
        RefreshEditorHeight()
        Persist(editBox:GetText())
    end)

    editBox:SetScript("OnTextChanged", function()
        RefreshEditorHeight()
        UpdateSaveState()
    end)

    editBox:SetText(storedText())
    RefreshEditorHeight()
    saveBtn:Disable()
    status:SetText("Type spell IDs here to override the built-in ones. An empty list uses the module's defaults.")

    -- Below the status line, which is the last thing this places. The panel adds
    -- its own padding on top of what every tab reports.
    return boxTop - boxHeight - STATUS_ROW
end
