# Snitch Addon - Project Summary

## Overview

I've created a modular World of Warcraft addon called "Snitch" that alerts when group members perform certain actions. The initial implementation includes SwapBlaster toy detection, with an architecture designed to easily add more detection modules.

## What Was Built

### Core Files

1. **Snitch.toc** - Addon descriptor
   - Defines addon metadata
   - Lists all Lua files to load
   - Declares SavedVariables for settings persistence

2. **Core.lua** - Main addon framework
   - Module registration system
   - Event handling (combat log, addon events)
   - Alert system with multiple output methods
   - Settings management
   - Slash commands
   - Performance optimizations (localized globals, efficient filtering)

3. **Config.lua** - Configuration UI
   - Full settings panel
   - Global enable/disable
   - Alert method configuration (console, chat, audio, screen)
   - Per-module enable/disable
   - Audio testing
   - Integration with WoW settings panel

4. **Modules/SwapBlaster.lua** - First detection module
   - Detects SwapBlaster toy usage via combat log
   - Tracks cast start, success, and cancellation
   - Attempts to identify target
   - Performance optimizations (name caching, localized globals)

### Documentation

- **README.md** - User documentation
- **CHANGELOG.md** - Version history
- **TESTING.md** - Testing guide and troubleshooting
- **PROJECT_SUMMARY.md** - This file
- **.gitignore** - Standard WoW addon gitignore

## Features Implemented

### Alert System

Multiple alert methods (all configurable):
- **Console**: Print messages to chat window
- **Chat**: Send to /say, /party, or /raid
- **Audio**: Play customizable sound effects
- **Screen**: Display raid-warning style messages

### Module System

Modular architecture allows easy addition of new detection modules:
- Modules register themselves with core
- Subscribe to combat log or other events
- Provide detection logic
- Send alerts through unified system

### Configuration

Full configuration UI accessible via `/snitch`:
- Global enable/disable
- Per-module enable/disable
- Alert method preferences
- Audio selection with test button

### Commands

```
/snitch          - Open config
/snitch version  - Show version
/snitch on/off   - Enable/disable
/snitch debug    - Toggle debug mode
/snitch status   - Detailed status
```

## WoW Addon Best Practices Applied

### Performance Optimizations

1. **Localized Globals**: Frequently accessed globals are cached as local upvalues
2. **Efficient Filtering**: Early returns in event handlers to minimize processing
3. **String Operations**: Using `string.format` instead of concatenation
4. **Name Caching**: Cache parsed player names to avoid repeated string operations
5. **Single Source of Truth**: Version read from .toc file via `GetAddOnMetadata`

### Error Handling

1. **Protected Calls**: Using `pcall` for operations that might fail:
   - Audio playback
   - Chat messages
   - Screen warnings
   - Module callbacks

2. **Nil Checking**: Proper validation of data before use
3. **Module Isolation**: Module errors don't crash the entire addon

### Code Organization

1. **Modular Design**: Clean separation of core, config, and modules
2. **DRY Principle**: Shared alert system used by all modules
3. **Clear Comments**: Section headers and inline documentation
4. **Consistent Style**: Follows Lua and WoW addon conventions

### Memory Management

1. **Table Reuse**: Minimizes table creation in hot paths
2. **State Cleanup**: Proper cleanup of tracking tables
3. **Efficient Data Structures**: Lookup tables for O(1) spell ID checking

## Architecture Highlights

### Module Registration

```lua
Snitch:RegisterModule("moduleId", {
    name = "Display Name",
    description = "What it does",
    onCombatLogEvent = function(...) end,  -- Combat log handler
    onEvent = function(...) end,            -- Other event handler
    initialize = function() end              -- Setup function
})
```

### Alert Flow

1. Module detects condition in event handler
2. Calls `Snitch.SendAlert(message, moduleId)`
3. Core validates (enabled, in group, module enabled)
4. Sends to all configured alert methods
5. Error handling ensures partial failures don't break alerts

### Settings Persistence

- Saved to `SnitchDB` SavedVariable
- Automatically persists across sessions
- Per-module settings for flexibility
- Global alert preferences

## Known Considerations

### Spell IDs (verified against 12.1.5)

`470116` and `470344`, the IDs this project originally guessed, are both wrong: `470116` is an internal test spell ("Chasting Strike") and `470344` is a hidden test aura ("Supercharged"). The verified IDs are `161399` (Swapblaster's cast, named "Swap"), `156779` / `384129` (Neural Silencer), `73325` (Life Grip, still named "Leap of Faith") and `370666` / `370667` (Rescue).

If a patch changes one, override it in the module tab's spell ID editor rather than editing code.

### Event Limitations

- Only works when in a party or raid group (by design: these abilities require a group)
- `COMBAT_LOG_EVENT_UNFILTERED` was removed in 12.0.0, so detection runs entirely off `UNIT_SPELLCAST_*` events
- Inside restricted content the spell ID is a secret value: it cannot be compared, printed or used as a key, so spells are matched by the name `C_Spell.GetSpellInfo` returns

### Target Detection

Target detection depends entirely on whether the spell marks its victim:
- Life Grip (4 s "Leap of Faith" aura) and Rescue (3 s "Rescue" aura) are attributed by name, because 12.1.0 made group auras readable out of combat again
- SwapBlaster marks nobody, so its alerts report the caster only
- Rescue is instant and Leap of Faith is instant, so no cast-start event precedes them; the completion event must stand alone

## Adding New Modules

To add a new detection module (e.g., hunter pet detection):

1. Create `Modules/YourModule.lua`
2. Follow the Rescue.lua pattern:
   ```lua
   local MODULE_ID   = "yourmodule"
   local MODULE_NAME = "Your Module Name"

   -- Resolve the watched IDs to names once, at Initialize(); cast events hand
   -- over secret spell IDs that can only be matched by name.
   local watchedNames = {}

   local function OnEvent(event, unitToken, castGUID, spellID)
       local info = C_Spell.GetSpellInfo(spellID)
       if not info or not watchedNames[info.name] then return end
       if not Snitch.IsGroupMemberToken(unitToken) then return end
       if Snitch.ShouldReport(MODULE_ID, unitToken) == false then return end

       Snitch.SendAlert("Message", MODULE_ID)
   end

   Snitch:RegisterModule(MODULE_ID, {
       name        = MODULE_NAME,
       description = "What it detects",
       onEvent     = OnEvent,
       initialize  = Initialize,
       spellIDs    = { 123456 },
       events      = { "UNIT_SPELLCAST_SUCCEEDED" },
   })
   ```
3. Add to `Snitch.toc`
4. `/reload` and test

## Next Steps

### Testing

1. Install addon in WoW (see TESTING.md)
2. Find correct SwapBlaster spell ID
3. Test in group environment
4. Verify all alert methods work
5. Test enable/disable functionality

### Future Modules

Planned detection modules:
- Hunter pet not present or passive
- Low durability
- Additional behaviors as needed

Each module follows the same pattern and integrates seamlessly.

### Refinements

Potential improvements:
- Cooldown system (prevent alert spam)
- Per-player muting (ignore specific players)
- Alert history/log
- More granular alert routing (different alerts for different modules)
- Custom alert messages per module

## File Structure

```
snitch/
├── Snitch.toc              # Addon descriptor
├── Core.lua                # Main addon logic
├── Config.lua              # Configuration UI
├── Modules/
│   └── SwapBlaster.lua     # SwapBlaster detection
├── README.md               # User documentation
├── CHANGELOG.md            # Version history
├── TESTING.md              # Testing guide
├── PROJECT_SUMMARY.md      # This file
└── .gitignore              # Git ignore rules
```

## Technical Stack

- **Language**: Lua 5.1 (WoW API)
- **WoW Version**: 11.x/12.x (The War Within / Midnight)
- **Framework**: Native WoW addon API
- **UI**: WoW built-in UI widgets

## Best Practice Highlights

- Localized globals for performance
- Error handling with pcall
- Efficient combat log filtering
- Modular, maintainable architecture
- Single source of truth for version
- Clean separation of concerns
- Comprehensive documentation
- Debug mode for troubleshooting
- Settings persistence
- User-friendly configuration UI

## Summary

The Snitch addon is production-ready for initial testing with a solid foundation for expansion. The modular architecture makes adding new detection modules straightforward, while the comprehensive alert system provides flexibility in how notifications are delivered. Performance optimizations and error handling ensure the addon runs efficiently without impacting gameplay.
