# Snitch - Complete Feature List

## Core Features

### Modular Architecture
- Easy to add new detection modules
- Modules register themselves with the core
- Each module can be enabled/disabled independently
- Clean separation of concerns

### SwapBlaster Detection
The detection module (`Modules/SwapBlaster.lua`, spell `161399`):

1. **Cast Detection**
   - Alerts when a group member starts the 1.5 second cast
   - Reports successful casts
   - Reports a channel that ended early, plus cancelled/interrupted casts
   - Tracks `UNIT_SPELLCAST_CHANNEL_START` / `_CHANNEL_STOP` as well as `_START` / `_SUCCEEDED`, because the cast is flagged channeled

2. **No victim name (a 12.x limit, not a missing feature)**
   - The swap applies no aura to either participant, and 12.0.0 removed the combat log, which was the only API that reported a destination
   - So SwapBlaster alerts name the caster only. Life Grip and Rescue *can* name their victim, because those do apply an aura

3. **Neural Silencer Detection**
   - Checks the group for the "Neural Silencer" aura (`156779` from the item, `384129` for the craftable Mk3)
   - Notes in the alert who is wearing one, since it blocks SwapBlaster and Leap of Faith
   - Uses `C_UnitAuras.GetAuraDataBySpellName`, which 12.1.0 made readable out of combat again

## Alert System

### Multiple Output Methods

1. **Console Output**
   - Prints to your chat window
   - Colored [Snitch] prefix for visibility
   - Toggle on/off

2. **Chat Messages**
   - Send to /say, /party, or /raid
   - Automatically adjusts based on group type
   - Toggle on/off
   - Select chat type in config

3. **Audio Alerts**
   - 5 sound options:
     - Raid Warning
     - Ready Check
     - Alarm Clock
     - Level Up
     - Achievement
   - Test button to preview sounds
   - Toggle on/off

4. **Screen Warnings** (Fully Customizable!)
   - **NOT** the basic raid warning frame
   - Custom frame system with full control

### Screen Alert Customization 
Access via: `/snitch` → "Screen warning" → "Configure..." button

**Font Options:**
- Friz Quadrata (WoW default)
- Arial
- Skurri
- Morpheus

**Font Size:**
- Range: 16-72
- Slider with live preview
- Default: 32

**Display Duration:**
- Range: 1-10 seconds
- Adjustable in 0.5s increments
- Default: 3 seconds

**Background:**
- Optional semi-transparent background
- Toggle on/off
- Helps text visibility

**Positioning:**
- Click "Reposition Alert" button
- Drag the preview frame to desired location
- Click "Done Repositioning" to save
- Position saved per character
- Default: Top center of screen

**Test Button:**
- Preview your settings instantly
- Shows sample alert with your configuration
- Safe to use anytime

## Configuration UI

### Main Config Panel
Access via: `/snitch` command

**Global Settings:**
- Enable/Disable entire addon
- Only active when in party or raid (by design)

**Alert Settings:**
- Toggle each alert type independently
- Configure chat type (say/party/raid)
- Select audio sound
- Test audio button
- Screen warning configuration button

**Module Settings:**
- Enable/Disable each detection module
- Module descriptions shown
- Future modules will appear here automatically

### Screen Alert Config Panel Separate dedicated panel for screen customization:
- All font and display settings
- Repositioning controls
- Live test button
- Help text for guidance

## Commands

```
/snitch          - Open main config
/snitch version  - Show addon version
/snitch on       - Enable addon
/snitch off      - Disable addon
/snitch debug    - Toggle debug mode
/snitch status   - Show detailed status
```

## Technical Highlights

### Performance Optimizations
- Localized globals for faster access
- Efficient combat log filtering
- Early returns to minimize processing
- Name caching to reduce string operations
- Aura checking uses modern API when available

### Error Handling
- Protected calls (pcall) for all risky operations
- Module errors don't crash the addon
- Graceful degradation
- Debug mode for troubleshooting

### Best Practices
- Single source of truth for version (reads from .toc)
- Settings persistence via SavedVariables
- Clean code organization
- Comprehensive inline documentation
- Consistent naming conventions

## How It Works

### Detection Flow
1. Player in your group casts SwapBlaster, Life Grip or Rescue
2. A unit cast event fires (`COMBAT_LOG_EVENT_UNFILTERED` no longer exists in 12.x)
3. Snitch filters it (is the spell watched? is the caster in your group? does the scope allow it?)
4. The module resolves the secret spell ID to a spell name and matches it
5. For Life Grip and Rescue, the module scans group auras to name the victim
6. Module formats alert message
7. Core sends alert to all enabled output methods

### Alert Flow
1. Module calls `Snitch.SendAlert(message, moduleId)`
2. Core validates:
   - Is addon enabled?
   - Are you in a group?
   - Is this module enabled?
3. If valid, sends to all enabled alert types:
   - Console: Prints to chat
   - Chat: Delays 0.1s, sends via SendChatMessage
   - Audio: Plays selected sound
   - Screen: Shows in custom alert frame
4. Each output wrapped in pcall for safety

## Setup Requirements

### Spell IDs

Verified against the live 12.1.5 spell database:

| Ability | Spell ID | Notes |
| --- | --- | --- |
| Swapblaster's cast | `161399` | Named **"Swap"**, not "SwapBlaster"; 1.5 sec channeled item effect (item 111820). `162217` is the crafting spell and `182081` is the backfire - neither is the cast |
| Neural Silencer | `156779`, `384129` | "Immune to some annoyances", 12 hours, blocks SwapBlaster and Leap of Faith |
| Life Grip | `73325` | Still named **"Leap of Faith"**; not renamed in 12.x |
| Rescue | `370666` | Evoker. `370667` is the matching passenger-side aura (strong candidate, not a confirmed link) |

If a future patch changes an ID, override it in the module tab's spell ID editor - no code edit needed. `/snitch probe` prints what your client actually exposes.

## Future Module Ideas

The architecture supports easy addition of:
- Hunter pet detection (not present/passive)
- Low durability warnings
- Consumable tracking
- Cooldown monitoring
- Position checking
- Buff/debuff alerts
- Any combat log event

## FAQ

**Q: Why don't I see alerts when solo?**
A: Addon only works in party/raid groups by design.

**Q: Can I move the screen alert?**
A: Yes! Open screen config, click "Reposition Alert", drag it, click "Done".

**Q: Can I change the text color?**
A: Not yet, but the architecture supports it. Easy to add if requested.

**Q: Will this cause lag?**
A: No. Heavily optimized with localized globals, efficient filtering, and minimal processing.

**Q: Can I see Edit Mode integration?**
A: Basic Edit Mode registration is implemented but full integration would require more development.

**Q: How do I add a new module?**
A: See `Modules/SwapBlaster.lua` as template. Create new file, register module, add to .toc, reload.

## File Structure

```
snitch/
├── Snitch.toc           - Addon descriptor & file list
├── Core.lua             - Main framework & alert system
├── ScreenAlert.lua      - Custom screen alert system ├── Config.lua           - Main configuration UI
├── Modules/
│   └── SwapBlaster.lua  - SwapBlaster detection module
├── README.md            - User documentation
├── CHANGELOG.md         - Version history
├── TESTING.md           - Testing guide
├── FEATURES.md          - This file
├── PROJECT_SUMMARY.md   - Technical overview
└── .gitignore           - Git ignore rules
```

## Summary

Snitch is a production-ready, highly customizable addon for monitoring group member actions. The three modules show what the 12.x API still allows:

- Detection through unit cast events (the combat log is gone in 12.0.0)
- Victim naming where the spell leaves an aura (Life Grip, Rescue); SwapBlaster leaves none, so it is reported without a victim
- Neural Silencer awareness
- Multiple alert methods
- Fully customizable screen alerts
- Drag-and-drop positioning
- Performance optimized
- Error handling
- Easy to extend
- Well documented
- User-friendly configuration

The modular architecture makes adding new detection modules straightforward while maintaining code quality and performance.
