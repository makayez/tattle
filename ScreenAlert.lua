-- ScreenAlert.lua - Custom screen notification system

Tattle = Tattle or {}
Tattle.ScreenAlert = {}

local ScreenAlert = Tattle.ScreenAlert

-- ============================================================================
-- Localize Globals
-- ============================================================================

local CreateFrame = CreateFrame
local C_Timer = C_Timer
local UIParent = UIParent

-- ============================================================================
-- Font Options
-- ============================================================================

ScreenAlert.FONTS = {
    {name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF"},
    {name = "Arial", path = "Fonts\\ARIALN.TTF"},
    {name = "Skurri", path = "Fonts\\skurri.ttf"},
    {name = "Morpheus", path = "Fonts\\MORPHEUS.ttf"},
}

-- ============================================================================
-- Alert Frame
-- ============================================================================

local alertFrame = nil
local activeTimer = nil

local function CreateAlertFrame()
    if alertFrame then return alertFrame end

    -- Main container frame
    local frame = CreateFrame("Frame", "TattleScreenAlertFrame", UIParent)
    frame:SetSize(400, 100)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -200)
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(100)
    frame:Hide()

    -- Make it movable
    frame:SetMovable(true)
    frame:EnableMouse(false)  -- Only enable during config

    -- Background (optional, can be disabled in settings)
    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetAllPoints()
    frame.bg:SetColorTexture(0, 0, 0, 0.7)
    frame.bg:Hide()  -- Hidden by default

    -- Text
    frame.text = frame:CreateFontString(nil, "OVERLAY")
    frame.text:SetPoint("CENTER")
    frame.text:SetJustifyH("CENTER")
    frame.text:SetJustifyV("MIDDLE")
    frame.text:SetWordWrap(true)
    frame.text:SetWidth(380)

    -- Apply initial settings
    ScreenAlert:ApplySettings(frame)

    alertFrame = frame
    return frame
end

-- ============================================================================
-- Settings Management
-- ============================================================================

function ScreenAlert:InitializeSettings()
    if not TattleDB.screenAlert then
        TattleDB.screenAlert = {
            fontSize = 32,
            font = 1,  -- Index into FONTS table
            color = {r = 1, g = 0.2, b = 0.2, a = 1},
            duration = 3,
            showBackground = false,
            position = {
                point = "TOP",
                relativeTo = "UIParent",
                relativePoint = "TOP",
                xOffset = 0,
                yOffset = -200
            }
        }
    end
end

function ScreenAlert:ApplySettings(frame)
    frame = frame or alertFrame
    if not frame then return end

    local settings = TattleDB.screenAlert

    -- Apply font
    local fontData = self.FONTS[settings.font] or self.FONTS[1]
    local fontPath = fontData.path
    frame.text:SetFont(fontPath, settings.fontSize, "OUTLINE")

    -- Apply color
    local c = settings.color
    frame.text:SetTextColor(c.r, c.g, c.b, c.a)

    -- Apply position
    local pos = settings.position
    frame:ClearAllPoints()
    frame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.xOffset, pos.yOffset)

    -- Background visibility
    if settings.showBackground then
        frame.bg:Show()
    else
        frame.bg:Hide()
    end
end

function ScreenAlert:SavePosition()
    if not alertFrame then return end

    local point, relativeTo, relativePoint, xOffset, yOffset = alertFrame:GetPoint()
    TattleDB.screenAlert.position = {
        point = point,
        relativeTo = "UIParent",  -- Always relative to UIParent
        relativePoint = relativePoint,
        xOffset = xOffset,
        yOffset = yOffset
    }
end

-- ============================================================================
-- Alert Display
-- ============================================================================

function ScreenAlert:Show(message)
    local frame = CreateAlertFrame()

    -- Cancel any existing timer
    if activeTimer then
        activeTimer:Cancel()
        activeTimer = nil
    end

    -- Set message
    frame.text:SetText(message)

    -- Show frame
    frame:Show()

    -- Auto-hide after duration
    local duration = TattleDB.screenAlert.duration
    activeTimer = C_Timer.NewTimer(duration, function()
        frame:Hide()
        activeTimer = nil
    end)
end

function ScreenAlert:Hide()
    if alertFrame then
        alertFrame:Hide()
    end
    if activeTimer then
        activeTimer:Cancel()
        activeTimer = nil
    end
end

-- ============================================================================
-- Edit Mode Support (Optional)
-- ============================================================================

function ScreenAlert:EnableDragMode()
    local frame = CreateAlertFrame()
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ScreenAlert:SavePosition()
    end)

    -- Show background during drag for visibility
    frame.bg:Show()
    frame.bg:SetColorTexture(1, 1, 0, 0.3)  -- Yellow tint

    -- Show preview text
    frame.text:SetText("Drag to reposition\nScreen alerts will appear here")
    frame:Show()
end

function ScreenAlert:DisableDragMode()
    if not alertFrame then return end

    alertFrame:EnableMouse(false)
    alertFrame:SetScript("OnDragStart", nil)
    alertFrame:SetScript("OnDragStop", nil)

    -- Restore background to settings
    self:ApplySettings()
    alertFrame:Hide()
end

-- ============================================================================
-- Edit Mode Registration (WoW 10.0+)
-- ============================================================================

function ScreenAlert:RegisterEditMode()
    -- Check if Edit Mode API is available
    if not EditModeManagerFrame then
        return false
    end

    -- Register with Edit Mode
    -- Note: This is a simplified version. Full Edit Mode integration
    -- requires more complex setup with system registration
    local frame = CreateAlertFrame()
    frame.isEditModeManaged = true

    return true
end

-- ============================================================================
-- Initialization
-- ============================================================================

function ScreenAlert:Initialize()
    self:InitializeSettings()
    CreateAlertFrame()

    -- Try to register with Edit Mode if available
    self:RegisterEditMode()
end
