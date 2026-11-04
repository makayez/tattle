# Tattle Addon - Project Summary

## Overview

I've created a modular World of Warcraft addon called "Tattle" that alerts when group members perform certain actions. The initial implementation includes Swapblaster toy detection, with an architecture designed to easily add more detection modules.

## What Was Built

### Core Files

1. **Tattle.toc** - Addon descriptor
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

4. **Modules/Swapblaster.lua** - First detection module
   - Detects Swapblaster toy usage via combat log
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

Full configuration UI accessible via `/tattle`:
- Global enable/disable
- Per-module enable/disable
- Alert method preferences
- Audio selection with test button

### Commands

```
/tattle          - Open config
/tattle version  - Show version
/tattle on/off   - Enable/disable
/tattle debug    - Toggle debug mode
/tattle status   - Detailed status
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
Tattle:RegisterModule("moduleId", {
    name        = "Display Name",
    description = "What it does",
    onEvent     = function(event, unitToken, castGUID, spellID) end,
    initialize  = function() end,          -- resolve spell IDs to names here
    events      = { "UNIT_SPELLCAST_SUCCEEDED" },  -- registered for you
    spellIDs    = { 123456 },              -- feeds the tab's spell ID editor

    -- Optional flags the core honours:
    outOfCombat = "all",     -- "all" drops every event of a cast whose caster is
                             -- fighting; "start" drops only the cast/channel
                             -- starts, so a slow spell's landing still arrives
    noScope     = true,      -- this module filters no casts; tab omits Monitor
    allCasters  = true,      -- opt out of the core's group-member filter (rarely right)
    extraContent = function(container, moduleId, moduleSettings, y) return y end,
})
```

There is no `onCombatLogEvent` any more: `COMBAT_LOG_EVENT_UNFILTERED` was removed in 12.0.0.

### Alert Flow

1. Module detects condition in event handler
2. Calls `Tattle.SendAlert(message, moduleId)`
3. Core validates (enabled, in group, module enabled)
4. Sends to all configured alert methods
5. Error handling ensures partial failures don't break alerts

### Settings Persistence

- Saved to `TattleDB` SavedVariable
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
- Inside restricted content the spell ID is a secret value: it cannot be compared, printed or used as a key, so spells are matched by name. The core resolves that name once per cast event (`C_Spell.GetSpellName`, falling back to `C_Spell.GetSpellInfo`) and hands it to the modules that registered it

### Neural Silencer (fourth module)

`Modules/Silencer.lua` owns the aura that blocks the other three. It resolves the aura names from the (user-editable) spell IDs into `Tattle.silencerNames`, which every module reads, and answers two questions for them: is this player protected, and who in the group is? It announces nothing on its own - wearing the thing is not an event, and joining must not produce a roll call of who is protected - so a wearer only surfaces in the display, or inside a cast alert raised by the module that saw the attempt. It can display a small drag-positioned on-screen list of the group's protected members plus whoever currently has you targeted. Its tab uses the shared alert controls plus `extraContent` for the display options, and `noScope` because it filters no casts.

### Chat channels

`Tattle.ResolveChatChannel` maps a configured `Raid` / `Party` request onto the channel that group actually has. An LFR raid is a raid but not a `LE_GROUP_TYPE_RAID` one, and a plain `RAID` send there disappears without an error, so it becomes `INSTANCE_CHAT`; a `Raid` request while only in a party becomes `PARTY`.

### Target Detection

Target detection depends entirely on whether the spell marks its victim:
- Life Grip (4 s "Leap of Faith" aura) and Rescue (3 s "Rescue" aura) are attributed by name, because 12.1.0 made group auras readable out of combat again
- Swapblaster marks nobody, so its alerts report the caster only
- Rescue is instant and Leap of Faith is instant, so no cast-start event precedes them; the completion event must stand alone

## Adding New Modules

To add a new detection module (e.g., hunter pet detection):

1. Create `Modules/YourModule.lua`
2. Follow the `Modules/CastSpells.lua` pattern (or `Modules/Silencer.lua` for a module that watches auras rather than casts):
   ```lua
   local MODULE_ID   = "yourmodule"
   local MODULE_NAME = "Your Module Name"

   local names     = {}   -- spell names, filled in Initialize
   local isOurCast        -- the matcher, built in Initialize below

   -- Cast events hand over spell IDs that are secret values inside instances, so a
   -- module matches by spell name. Initialize is where the IDs you ship (or the
   -- ones the player typed over them) become names, and where those names are
   -- handed to the core -- which then resolves each event's spell name once and
   -- wakes only the modules that registered it.
   local function Initialize()
       Tattle.ResolveSpellNames(names, Tattle.MakeSpellIDs(MODULE_ID, { 123456 }))
       isOurCast = Tattle.MakeSpellMatcher(names)
   end

   -- The core already dropped casts by anyone outside your group and every spell
   -- nobody registered, so the handler is a decision, not a filter. The membership
   -- line stays as a guard: that filter is per-event, and another module's
   -- allCasters flag widens the same event for everybody.
   local function OnEvent(event, unitToken, castGUID, spellID, spellName)
       if not Tattle.IsGroupMemberToken(unitToken) then return end
       if not isOurCast(spellName, spellID) then return end

       -- ScopeDrops answers "is this outside the Monitor scope?" The third
       -- argument is the victims you positively identified; nil means "unknown",
       -- and an unknown is never proof that a cast missed you.
       if Tattle.ScopeDrops(MODULE_ID, unitToken, nil) then return end

       Tattle.SendAlert("Message", MODULE_ID)
   end

   Tattle:RegisterModule(MODULE_ID, {
       name        = MODULE_NAME,
       description = "What it detects",
       onEvent     = OnEvent,
       initialize  = Initialize,
       spellIDs    = { 123456 },   -- what the tab's spell ID editor starts from
       events      = { "UNIT_SPELLCAST_SUCCEEDED" },
   })
   ```
3. Add to `Tattle.toc`
4. `/reload` and test

## Next Steps

### Testing

1. Install addon in WoW (see TESTING.md)
2. Find correct Swapblaster spell ID
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
tattle/
├── Tattle.toc              # Addon descriptor, load order, CurseForge project ID
├── Core.lua                # Settings, the event frame, cast filtering, alerts,
│                           #   group/aura/silencer helpers (loads first)
├── Probe.lua               # /tattle probe
├── Commands.lua            # the /tattle slash command
├── ScreenAlert.lua         # Custom screen alerts
├── Config.lua              # Configuration UI (shared controls, one tab per module)
├── ConfigSpellIDs.lua      # Per-module spell ID editor
├── Modules/
│   ├── Swapblaster.lua     # Swapblaster detection
│   ├── CastSpells.lua      # Life Grip and Rescue, from one factory
│   └── Silencer.lua        # Neural Silencer lookup and watch list
├── Tests/
│   └── wow_stub.lua        # Stub client harness (CI and local)
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

The Tattle addon is production-ready for initial testing with a solid foundation for expansion. The modular architecture makes adding new detection modules straightforward, while the comprehensive alert system provides flexibility in how notifications are delivered. Performance optimizations and error handling ensure the addon runs efficiently without impacting gameplay.
