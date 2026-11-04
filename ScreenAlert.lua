-- ScreenAlert.lua - the big text in the middle of the screen.
--
-- One frame, no OnUpdate: it is shown, a timer hides it, and that is the whole
-- design. The frame is built the first time an alert is actually displayed (or
-- the first time someone drags it around in the config panel), so an install that
-- never turns screen alerts on never pays for a frame at login.

local _, Tattle = ...

local ScreenAlert = {}
Tattle.ScreenAlert = ScreenAlert

local CreateFrame = CreateFrame
local C_Timer = C_Timer
local UIParent = UIParent
local type = type
local pairs = pairs

ScreenAlert.FONTS = {
    { name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
    { name = "Arial",         path = "Fonts\\ARIALN.TTF" },
    { name = "Skurri",        path = "Fonts\\skurri.ttf" },
    { name = "Morpheus",      path = "Fonts\\MORPHEUS.ttf" },
}

-- Every setting the frame understands, in one place, so a save file written by an
-- older version can be topped up field by field. See InitializeSettings.
local DEFAULTS = {
    fontSize = 32,
    font = 1,               -- index into FONTS
    duration = 3,
    showBackground = false,
}
local DEFAULT_COLOR = { r = 1, g = 0.2, b = 0.2, a = 1 }
-- The frame is always anchored to UIParent, so the saved position only needs the
-- anchor point, its counterpart on UIParent, and the offsets.
local DEFAULT_POSITION = { point = "TOP", relativePoint = "TOP", xOffset = 0, yOffset = -200 }

local alertFrame = nil
local activeTimer = nil

-- ============================================================================
-- Settings
-- ============================================================================

-- TattleDB.screenAlert is a save-file table, and a save file is old the moment it
-- is written. Creating the table only when it is entirely absent -- which is what
-- this used to do -- means the first new setting added after release hands every
-- existing install a nil where the code expects a number or a colour to read
-- apart. Filling in each missing field costs a dozen comparisons once at login and
-- is the reason ApplySettings below can assume what it reads is there.
--
-- (Modules/Silencer.lua guards its display settings the same way. Both are
-- defending the same failure; if you are adding a setting, that is the pair of
-- places to touch.)
function ScreenAlert:InitializeSettings()
    local settings = TattleDB.screenAlert
    if type(settings) ~= "table" then
        settings = {}
        TattleDB.screenAlert = settings
    end

    for key, fallback in pairs(DEFAULTS) do
        if settings[key] == nil then settings[key] = fallback end
    end

    if type(settings.color) ~= "table" then settings.color = {} end
    for key, fallback in pairs(DEFAULT_COLOR) do
        if settings.color[key] == nil then settings.color[key] = fallback end
    end

    if type(settings.position) ~= "table" then settings.position = {} end
    for key, fallback in pairs(DEFAULT_POSITION) do
        if settings.position[key] == nil then settings.position[key] = fallback end
    end
end

-- ============================================================================
-- The frame
-- ============================================================================

local function CreateAlertFrame()
    if alertFrame then return alertFrame end

    local frame = CreateFrame("Frame", "TattleScreenAlertFrame", UIParent)
    frame:SetSize(400, 100)
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(100)
    frame:SetMovable(true)
    -- Mouse off except while the config panel is deliberately repositioning it: a
    -- frame that swallows clicks in the middle of the screen is a bug report
    -- waiting to happen.
    frame:EnableMouse(false)

    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetAllPoints()
    frame.bg:SetColorTexture(0, 0, 0, 0.7)
    frame.bg:Hide()

    frame.text = frame:CreateFontString(nil, "OVERLAY")
    frame.text:SetPoint("CENTER")
    frame.text:SetJustifyH("CENTER")
    frame.text:SetJustifyV("MIDDLE")
    frame.text:SetWordWrap(true)
    frame.text:SetWidth(380)

    alertFrame = frame
    ScreenAlert:ApplySettings(frame)
    frame:Hide()
    return frame
end

function ScreenAlert:ApplySettings(frame)
    self:InitializeSettings()
    frame = frame or alertFrame
    if not frame then return end

    local settings = TattleDB.screenAlert

    local fontData = self.FONTS[settings.font] or self.FONTS[1]
    frame.text:SetFont(fontData.path, settings.fontSize, "OUTLINE")

    local c = settings.color
    frame.text:SetTextColor(c.r, c.g, c.b, c.a)

    local pos = settings.position
    frame:ClearAllPoints()
    frame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.xOffset, pos.yOffset)

    if settings.showBackground then frame.bg:Show() else frame.bg:Hide() end
end

function ScreenAlert:SavePosition()
    if not alertFrame then return end

    local point, _, relativePoint, xOffset, yOffset = alertFrame:GetPoint()
    if not point then return end
    TattleDB.screenAlert.position = {
        point = point,
        relativePoint = relativePoint,
        xOffset = xOffset,
        yOffset = yOffset,
    }
end

-- ============================================================================
-- Displaying an alert
-- ============================================================================

function ScreenAlert:Show(message)
    local frame = CreateAlertFrame()

    -- One alert on screen at a time: a fresh message replaces the current one and
    -- takes over its hide timer, rather than stacking text over the raid frames.
    if activeTimer then
        activeTimer:Cancel()
        activeTimer = nil
    end

    frame.text:SetText(message)
    frame:Show()

    local duration = TattleDB.screenAlert.duration
    activeTimer = C_Timer.NewTimer(duration, function()
        frame:Hide()
        activeTimer = nil
    end)
end

function ScreenAlert:Hide()
    if alertFrame then alertFrame:Hide() end
    if activeTimer then
        activeTimer:Cancel()
        activeTimer = nil
    end
end

-- ============================================================================
-- Repositioning (from the config panel)
-- ============================================================================

function ScreenAlert:EnableDragMode()
    local frame = CreateAlertFrame()
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ScreenAlert:SavePosition()
    end)

    -- Yellow and visible for the duration of the drag, whatever the settings say.
    frame.bg:Show()
    frame.bg:SetColorTexture(1, 1, 0, 0.3)
    frame.text:SetText("Drag to reposition\nScreen alerts will appear here")
    frame:Show()
end

function ScreenAlert:DisableDragMode()
    if not alertFrame then return end

    alertFrame:EnableMouse(false)
    alertFrame:SetScript("OnDragStart", nil)
    alertFrame:SetScript("OnDragStop", nil)

    -- Back to the saved appearance, including the background the drag turned on.
    self:ApplySettings()
    alertFrame:Hide()
end

-- Nothing to do at login. The settings are topped up on first use, and the frame
-- is built when an alert is shown or repositioned -- so a player who never
-- switches screen alerts on never carries the frame around.
function ScreenAlert:Initialize()
    self:InitializeSettings()
end
