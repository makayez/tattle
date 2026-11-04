-- EventListener.lua
-- Must be FIRST in the TOC. No logic. Just RegisterEvent.

Tattle = Tattle or {}

Tattle.eventFrame = CreateFrame("Frame")
Tattle.eventFrame:RegisterEvent("ADDON_LOADED")
-- The core caches the group's unit token lists, so it needs the event that says
-- they went stale regardless of what the modules subscribe to.
Tattle.eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
Tattle.eventFrame:RegisterEvent("UNIT_SPELLCAST_START")
Tattle.eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
Tattle.eventFrame:RegisterEvent("UNIT_SPELLCAST_FAILED")
Tattle.eventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
