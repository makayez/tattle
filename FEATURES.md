# Tattle - Complete Feature List

## Core Features

### Modular Architecture
- Easy to add new detection modules
- Modules register themselves with the core
- Each module can be enabled/disabled independently
- Clean separation of concerns

### Swapblaster Detection
The detection module (`Modules/Swapblaster.lua`, spell `161399`):

1. **Cast Detection**
   - Alerts when a group member starts the 1.5 second cast
   - Reports successful casts
   - Not evaluated at all on a cast start while the caster is fighting - the toy says "Cannot be used in combat". A swap that began out of combat is still announced when it lands, because landing one next to a pack is a classic way to start a fight
   - Reports a channel that ended early, plus cancelled/interrupted casts
   - Tracks `UNIT_SPELLCAST_CHANNEL_START` / `_CHANNEL_STOP` as well as `_START` / `_SUCCEEDED`, because the cast is flagged channeled

2. **Two ways to find the other half of a cast, and neither is the combat log**
   - Life Grip and Rescue put a short aura on the player they moved, so their victim is named from that signature - proof rather than inference
   - The Swapblaster marks nobody, so its victim is whoever the caster had targeted when the cast started, read from `<caster>target`. The toy needs a target, and 12.0.0 removed the only API that used to report a destination
   - That is a read, so the wording is `at Pancakes` while the cast runs and `on Pancakes` once it lands. A client that is not told other players' targets gets the old sentence with nobody named - never a guess. The Monitor scope is deliberately not narrowed by this read: muting a swap because a target field pointed elsewhere would trade a rare extra alert for a missed grief

3. **Neural Silencer Detection**
   - Checks the group for the "Neural Silencer" aura (`156779` from the item, `384129` for the craftable Mk3)
   - Notes in the alert who is wearing one, since it blocks Swapblaster and Leap of Faith
   - Uses `C_UnitAuras.GetAuraDataBySpellName`, which 12.1.0 made readable out of combat again
   - Reports a backfire as what it was: `Donut attempted a Swapblaster on Pancakes, but it failed because Pancakes is using a Neural Silencer`
   - Names a protected caster who fires one: `... but Pancakes is using a Neural Silencer - that's not fair!`

### Neural Silencer Watch (spell IDs `156779` / `384129`)

The fourth module (`Modules/Silencer.lua`) owns the aura that blocks the other three:

1. **Group scan**
   - Resolves the aura names from the spell IDs (editable in-game, like every module)
   - **Announces nothing.** Having the aura is not an event: joining a raid must not read out "Donut has one on, Pancakes has one on, ...". A wearer only appears in the list below, or inside a cast alert raised by the module that saw the cast - "X tried a Swapblaster on Donut and it failed because Donut is using a Neural Silencer". This module contains no `SendAlert` call at all, which is the guarantee made checkable
2. **Optional on-screen watch list** (off by default)
   - Lists the group's Neural Silencer wearers
   - Optionally lists which group members currently have **you** targeted, from the `<member>target` tokens
   - Drag-positioned with "Reposition List" on its tab, exactly like the screen alert
   - Costs a couple of small group sweeps per second while visible (`UNIT_AURA` / `UNIT_TARGET` plus a 0.5 s timer, throttled). Nothing runs per frame, and the text is only rewritten when it actually changes
   - Hides itself when you leave the group or type `/tattle off`, and its timer stops when you untick it
   - "Targeting you" is only as good as the client's willingness to tell you other players' targets - `/tattle probe` prints what it can read

## Alert System

### Multiple Output Methods

1. **Console Output**
   - Prints to your chat window
   - Colored [Tattle] prefix for visibility
   - Toggle on/off

2. **Chat Messages**
   - Send to /say, /yell, /party, /raid, or the instance channel
   - Automatically adjusts based on group type: a `Raid` request in a Looking for Raid group is sent on the instance channel, because a plain `RAID` send there is dropped without an error. A `Raid` request while only in a party is delivered on `PARTY`
   - Toggle on/off
   - Select chat type in config (`/tattle status` shows the channel a message would really use when it differs)

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
Access via: `/tattle` → "Screen warning" → "Configure..." button

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
Access via: `/tattle` command

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
/tattle          - Open main config
/tattle version  - Show addon version
/tattle on       - Enable addon
/tattle off      - Disable addon
/tattle debug    - Toggle debug mode
/tattle status   - Show detailed status
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
1. Player in your group casts Swapblaster, Life Grip or Rescue
2. A unit cast event fires (`COMBAT_LOG_EVENT_UNFILTERED` no longer exists in 12.x)
3. Tattle filters it (is the spell watched? is the caster in your group? does the scope allow it?)
4. The module resolves the secret spell ID to a spell name and matches it
5. For Life Grip and Rescue, the module scans group auras to name the victim
6. Module formats alert message
7. Core sends alert to all enabled output methods

### Alert Flow
1. Module calls `Tattle.SendAlert(message, moduleId)`
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
| Swapblaster's cast | `161399` | Named **"Swap"**, not "Swapblaster"; 1.5 sec channeled item effect (item 111820). `162217` is the crafting spell and `182081` is the backfire - neither is the cast |
| Neural Silencer | `156779`, `384129` | "Immune to some annoyances", 12 hours, blocks Swapblaster and Leap of Faith. Owned by the Silencers module and read by all of them |
| Swapblaster backfire | `182081` | "Swapblaster Explosion", what the caster eats when the target was protected. Read as a blocked attempt; deliberately not in the editable watched-spell list |
| Life Grip | `73325` | Still named **"Leap of Faith"**; not renamed in 12.x |
| Rescue | `370666` | Evoker. `370667` is the matching passenger-side aura (strong candidate, not a confirmed link) |

If a future patch changes an ID, override it in the module tab's spell ID editor - no code edit needed. `/tattle probe` prints what your client actually exposes.

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
A: No. Heavily optimized with localized globals, efficient filtering, and minimal processing. The optional watch list is the only recurring work: a couple of small group aura/target sweeps a second while it is visible, throttled, with no per-frame code and no rewrite when the text has not changed.

**Q: Can I see who is targeting me?**
A: Turn on "List group members targeting you" on the Silencers tab. It reads each group member's target token, which your client may or may not be told about - `/tattle probe` prints what it can actually read, so you can tell "nobody is targeting me" from "my client cannot see it".

**Q: Why does the probe print nothing when I am solo?**
A: By design. Nothing it measures - a swap, a grip, a rescue - can happen without a group, and the aura and target sweeps it would run are pure waste when you are alone.

**Q: Can I move the alerts in Edit Mode?**
A: No - Tattle does not register with Edit Mode, because the two frames that can appear on screen are invisible most of the time, and Edit Mode is for frames you can see in order to position them. Each has a **Reposition** button instead (Screen Alerts tab, Silencers tab), which makes the frame movable so you can drag it, and the position is saved per option.

**Q: How do I add a new module?**
A: See `Modules/CastSpells.lua` (cast detectors - Life Grip and Rescue are one factory registered twice) or `Modules/Swapblaster.lua` (a channeled spell with a backfire to interpret). Create the file, register it with `Tattle:RegisterModule`, add it to `Tattle.toc` after Core.lua, `/reload`.

## File Structure

```
tattle/
├── Tattle.toc           - Addon descriptor & file list
├── Core.lua             - Settings, the event frame, cast filtering, alert system,
│                          silencer / group / chat helpers (loads first)
├── Probe.lua            - /tattle probe
├── Commands.lua         - the /tattle slash command
├── ScreenAlert.lua      - Custom screen alert system
├── Config.lua           - Main configuration UI (tabbed, shared module-tab sections)
├── ConfigSpellIDs.lua   - Per-module spell ID editor
├── Modules/
│   ├── Swapblaster.lua  - Swapblaster detection module
│   ├── CastSpells.lua   - Life Grip and Rescue detection modules
│   └── Silencer.lua     - Neural Silencer lookup, blocked-cast wording, watch list
├── Tests/
│   └── wow_stub.lua     - Stub WoW client harness (CI + local)
├── README.md            - User documentation
├── CHANGELOG.md         - Version history
├── TESTING.md           - Testing guide
├── FEATURES.md          - This file
├── PROJECT_SUMMARY.md   - Technical overview
└── .gitignore           - Git ignore rules
```

## Summary

Tattle is a production-ready, highly customizable addon for monitoring group member actions. The three modules show what the 12.x API still allows:

- Detection through unit cast events (the combat log is gone in 12.0.0)
- Victim naming from an aura where the spell leaves one (Life Grip, Rescue), and from the caster's target where it does not (Swapblaster)
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
