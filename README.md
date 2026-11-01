# Snitch

A World of Warcraft addon (retail 12.x) that alerts when a group member uses a movement ability you can be griefed with: SwapBlaster, Life Grip, or Rescue.

## Features

### Current Modules

- **SwapBlaster Detector** (spell `161399` "Swap", from the Swapblaster item 111820):
  - Alerts when a group member begins the 1.5 second cast, and when it completes
  - Reports a cast that was cut short, failed, or interrupted
  - Names the caster. The swap itself puts no aura on anyone, so **the victim cannot be named**
  - Notes who in the group is wearing a **Neural Silencer** (12-hour "Immune to some annoyances" aura, spells `156779` / `384129`), which blocks the swap

- **Life Grip Detector** (spell `73325` - the game names it "Leap of Faith"):
  - Alerts when a Priest yanks someone while out of combat
  - Names the victim from the 4-second "Leap of Faith" aura the pull leaves on them: `Pancakes used Life Grip on Donut!`, or `Pancakes used Life Grip on you!`
  - Ignores in-combat usage, which is a legitimate emergency heal

- **Rescue Detector** (spell `370666`, Evoker):
  - Alerts when an Evoker scoops someone up out of combat
  - Names the passenger from the 3-second "Rescue" aura, excluding the Evoker who cast it
  - Ignores in-combat usage

### Planned Modules

- Hunter pet not present or set to passive
- Low durability warnings
- Additional behavior monitoring

## Alert Options

Snitch provides **per-module** alert configuration. Each module can have its own alert preferences:

- **Monitor scope**: `Whole group` (any group member's cast) or `Only me` (drop a cast only when it can be proven it missed you)
- **Console Output**: Print messages to your chat window
- **Chat Messages**: Send alerts to /say, /yell, /party or /raid chat, or keep them private (configurable per module)
- **Audio Alerts**: Play customizable sound effects when events occur (5 sounds to choose from)
- **Screen Warnings**: Fully customizable on-screen alerts with:
  - Adjustable font and font size
  - Custom positioning (drag to move)
  - Configurable display duration
  - Optional background
  - Screen appearance is global, but each module controls whether to show screen alerts
- **Spell ID editor**: override the built-in spell IDs in-game, per module

**Example**: You can configure SwapBlaster to use screen + audio alerts, while Life Grip only uses console output.

## Usage

### Installation

1. Download or clone this repository
2. Place the `snitch` folder in your `World of Warcraft/_retail_/Interface/AddOns/` directory
3. Restart WoW or reload your UI with `/reload`

### Configuration

Open the configuration panel with:
```
/snitch
```

### Commands

```
/snitch          - Open configuration panel
/snitch version  - Show addon version
/snitch on       - Enable the addon
/snitch off      - Disable the addon
/snitch debug    - Toggle debug mode
/snitch probe    - Toggle event probe (verify spell IDs + target visibility)
/snitch status   - Show current status and settings
```

## Module Architecture

Snitch uses a modular architecture to make adding new detection modules easy. Each module:

- Registers itself with the core addon
- Subscribes to the unit cast events it cares about (`UNIT_SPELLCAST_START`, `_SUCCEEDED`, `_FAILED`, `_INTERRUPTED`, and for channeled casts `_CHANNEL_START` / `_CHANNEL_STOP`)
- Provides detection logic for specific behaviors
- Sends alerts through the unified alert system
- Gets its own tab in the config panel automatically

### Creating a New Module

To add a new detection module:

1. Create a new file in `Modules/YourModule.lua`
2. Register the module with `Snitch:RegisterModule()` (declared `events` are registered for you)
3. Implement detection logic in the event handler
4. Add the file to `Snitch.toc`

See `Modules/Rescue.lua` for the smallest complete example.

## Technical Details

### Working around the 12.0 addon restrictions

Midnight 12.0.0 removed `COMBAT_LOG_EVENT_UNFILTERED` (registering it now raises `ADDON_ACTION_FORBIDDEN`), and that was the only API that carried a spell's **destination**. Two techniques replace it:

- **Secret spell IDs**: inside restricted content the `spellID` from cast events is a secret value - it cannot be compared with `==`, printed, or used as a table key. Snitch resolves its own known IDs to spell names once at startup and compares the name that `C_Spell.GetSpellInfo(secretID)` returns.
- **Auras as destinations**: Life Grip and Rescue mark the player they grabbed with a short aura, so the victim is named by scanning group auras (`C_UnitAuras.GetAuraDataBySpellName`), which 12.1.0 made readable out of combat again. SwapBlaster marks nobody, so its alerts stop at the caster's name.

### Performance

- Localizes frequently accessed globals for improved performance
- Early returns to minimize unnecessary processing
- Protected calls (pcall) around anything that may receive a secret value, so a restricted context cannot error a module

### When alerts fire

The addon only processes cast events when:
- The addon is enabled
- You are in a party or a raid (these abilities require a group)
- The caster is a member of your group
- The module's `Monitor` scope allows the cast

### Verifying spell IDs

The shipped IDs were checked against the live 12.1.5 spell database, but the API behaviour that *delivers* them is best confirmed on your own client:

1. `/snitch debug` then `/snitch probe`, then use each ability on yourself and on a friend
2. The probe prints every cast event it sees, whether the caster argument can be named, whether any destination argument is exposed, and which group auras are visible - which is what the "on Donut" half of an alert depends on
3. If an ID is wrong for your build, enter the right one in the module tab's spell ID editor and `/reload`

## Requirements

- World of Warcraft retail 12.x (Midnight). Built and verified against 12.1.5

## Releases & CI

Two GitHub Actions workflows:

- **Test** (`.github/workflows/test.yml`) runs on every push to `main` and on pull requests. It installs `lua5.1` and runs `Tests/wow_stub.lua`, a stub WoW client that loads the addon in TOC order and asserts alert routing, instant-cast handling, scope gating, the config panel tabs and the spell-ID editor. Locally: `lua5.1 Tests/wow_stub.lua` (exit 0 = pass).
- **Release** (`.github/workflows/release.yml`) runs when a **GitHub Release is published**. `BigWigsMods/packager` builds the addon zip from `.pkgmeta`, names it `Snitch-<version>` using the `## Version` in `Snitch.toc`, and attaches it to the release.

To ship a version:

1. Bump `## Version` in `Snitch.toc` and add a `CHANGELOG.md` entry
2. Tag and push: `git tag -a v0.1.0-alpha.1 -m "Snitch 0.1.0-alpha.1"` then `git push origin main v0.1.0-alpha.1`
3. Create a GitHub Release from that tag and **publish** it - the workflow attaches the packaged zip

CurseForge publishing is commented out in `release.yml` because Snitch has no CurseForge project yet. When one exists, add the `CF_API_KEY` repository secret and uncomment that line.

## Development

Built following WoW addon best practices:
- Modular architecture for maintainability
- Localized globals for performance
- Error handling with pcall
- Efficient event filtering
- Clean separation of concerns

## Version

Current version is defined in `Snitch.toc`
