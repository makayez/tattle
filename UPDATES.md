# Recent Updates

### The review pass: one event frame, and the addon was reading you twice
**Before**: `EventListener.lua` and `Core.lua` each created an event frame and
both registered the same six cast events; Life Grip, Rescue and Swapblaster each
carried their own combat check and their own spell-ID-to-name boilerplate;
`Core.lua` was 1.2k lines and included the probe and the slash command

**Now**: the core owns the one event frame and the cast filter, and spells the
combat rule once (`outOfCombat = "all"` for the grab spells, `"start"` for the
Swapblaster, whose landing still arrives because a swap begun while walking can be
what pulls you into the fight). `EventListener.lua` is deleted, Life Grip and
Rescue are one table-driven file (`Modules/CastSpells.lua`), and the probe, the
slash command and the spell ID editor are their own files. The only globals left
are `TattleDB` and the slash command

**The bug**: in a raid you hold one of the `raidN` indexes *and* you are `player`,
and the core's group token list appended both - so you were scanned twice. The
watch list said `you and you`; a blocked cast said `it failed because you and you
are using a Neural Silencer`; a Life Grip on you read `on you and you`; and an
Evoker who Rescued somebody was reported as their own passenger

**Why it took this long**: the stub harness modelled a raid of two as `raid1` and
`raid2` being other players, which is not a shape the game can produce. Fixing the
model turned the bug into five failing checks, and deleting the core's
double-counting turned them green again - the fix is pinned by checks, not by a
comment. Checks went 97 to 106, and the harness now also fails if a widget setter
is handed `nil` where the client wants a number, which is how `SetSize(700, nil)`
slipped past it once


### 0.2.0-alpha.1 is out
**Before**: the work since the last tag sat in the tree - the rename, the Neural Silencer
module, the performance pass, the LFR chat fix, the icon - and there was no CurseForge
project to put it on

**Now**: tag `v0.2.0-alpha.1` is pushed, and pushing an annotated tag is the whole release
procedure: `BigWigsMods/packager` builds `Tattle-v0.2.0-alpha.1.zip`, creates the GitHub
pre-release and - once a CurseForge token exists as a repository secret - uploads to
CurseForge project 1782380 through `## X-Curse-Project-ID` in `Tattle.toc`. The zip is
verified to contain the 12.x addon and nothing else: four modules, core, config, screen
alert, event listener, the TOC, the TGA and nothing from `Tests` or `Tools`

**Now also true**: the repository secret exists, so the same run uploaded the file to
CurseForge project 1782380 (`Uploading Tattle-v0.2.0-alpha.1.zip (12.0.1,12.0.0 alpha)
to https://wow.curseforge.com/projects/1782380 - Success!`). The first cut of the tag did
not: its workflow read the token from a secret named `CF_API_KEY`, the secret is
`CF_API_TOKEN`, and the packager logged an empty token and skipped CurseForge. Moving the
token-agnostic workflow into the tagged commit and re-cutting the tag fixed it

### Renamed: Snitch -> Tattle
**Before**: the addon, its folder, its chat command (`/snitch`), its global and its
saved variables (`SnitchDB`) were all called Snitch

**Now**: Tattle - `Tattle.toc`, `/tattle`, `Tattle`, `TattleDB`, `TattleConfigPanel`.
`/tattle` is the only command; the old spelling is not registered, so a stale
keybind fails visibly rather than working behind an alias the docs do not teach

**Gotcha**: saved variables are stored per addon folder and one addon cannot read
another's file, so configuration starts fresh. To keep yours, copy
`WTF/Account/<account>/SavedVariables/Snitch.lua` over `Tattle.lua` and rename the
top-level variable inside it

### Supported interface moved to 12.1.x
**Before**: `## Interface: 120001, 120000` - the 12.0 line

**Now**: `## Interface: 120107, 120105` - 12.1.7 and 12.1.5, the same pair the other
addon in this family declares. No Lua changed: a scan of every global the addon calls
came back as cast/aura/target events, `C_Spell` lookups, `C_UnitAuras`, the group
queries, `C_Timer`, `PlaySound`, `SendChatMessage` and the widget/Settings API - none of
which moved between 12.0 and 12.1, and there is no `GetBuildInfo` branch to update

**Why it needs a release, not just a commit**: CurseForge stamps a file's supported game
versions from `## Interface` when the file is uploaded. The alpha.1 file is filed under
12.0.1/12.0.0 for good, so the label only moves by publishing a new file

## Major Changes

### Per-Module Alert Configuration 
**Before**: All modules shared the same alert settings (global console, chat, audio, screen settings)

**Now**: Each module has its own independent alert configuration!

**Benefits**:
- Swapblaster can use screen + audio alerts
- Life Grip can use console output only
- Each module fully customizable

**How It Works**:
1. Global master switch (`/tattle` → "Enable Tattle") - turns entire addon on/off
2. Per-module enable/disable (module checkbox)
3. Per-module alert settings (click "Configure..." button)

### New Life Grip Module 
Detects when a priest uses Life Grip (Leap of Faith) **while out of combat**.

**Features**:
- Alerts on cast start with target identification
- Reports successful grips
- Reports cancelled/interrupted casts
- **Only triggers out of combat** (legitimate in-combat usage is ignored)

**Spell ID**: 73325 (verify in-game, may need adjustment)

## Configuration UI Changes

### Main Config Panel
```
/tattle
├── Global Enable/Disable (master switch)
└── Modules:
    ├── [x] Swapblaster Detector [Configure...]
    └── [x] Life Grip Detector [Configure...]
```

### Per-Module Config Panel
Click "Configure..." next to any module:
```
Module Name - Alert Configuration
├── [ ] Console output
├── [ ] Chat message
│   └── Chat type: [Party ▼]
├── [ ] Audio alert
│   ├── Sound: [Raid Warning ▼]
│   └── [Test] button
└── [ ] Screen warning
    └── [Appearance...] button (global screen settings)
```

### Screen Alert Appearance Panel
Accessed from any module's config:
- Font selection (4 fonts)
- Font size (16-72)
- Display duration (1-10 seconds)
- Background on/off
- [Reposition Alert] button
- [Test Alert] button

**Note**: Screen appearance (font, size, position) is **global** - affects all modules. Each module controls whether to **show** screen alerts.

## Data Structure Changes

### SavedVariables Format

**Before**:
```lua
TattleDB = {
  enabled = true,
  alerts = {  -- Global alerts
    console = true,
    chat = false,
    ...
  },
  modules = {
    swapblaster = {
      enabled = true
    }
  }
}
```

**After**:
```lua
TattleDB = {
  enabled = true,  -- Global master switch
  modules = {
    swapblaster = {
      enabled = true,
      alerts = {  -- Per-module alerts!
        console = true,
        chat = false,
        chatType = "PARTY",
        audio = false,
        audioFile = 8959,
        screen = false
      }
    },
    lifegrip = {
      enabled = true,
      alerts = {
        console = true,
        chat = false,
        ...
      }
    }
  },
  screenAlert = {  -- Global screen appearance
    fontSize = 32,
    font = 1,
    ...
  }
}
```

## Command Changes

### `/tattle status` Output

**Before**:
```
Tattle Status:
  Enabled: ON
  Version: 0.1.0
  ...
Modules:
  [Swapblaster Detector] ON
Alerts:
  Console: ON
  Chat: OFF
  ...
```

**After**:
```
Tattle Status:
  Global Enabled: ON
  Version: 0.1.0
  ...
Modules:
  [Swapblaster Detector] ON
    Alerts: Console=ON, Chat=OFF (PARTY), Audio=OFF, Screen=ON
  [Life Grip Detector] ON
    Alerts: Console=ON, Chat=OFF (PARTY), Audio=OFF, Screen=OFF
```

## Migration / Compatibility

**Good News**: If you have existing settings, the addon will:
1. Initialize per-module alert settings with defaults
2. Keep your existing module enable/disable states
3. Not break or lose any existing configuration

**First Time Opening Config**:
- Each module will have default alerts (console=ON, others=OFF)
- You can customize each module independently
- Settings save automatically

## Testing Checklist

1. **Existing Settings**:
   - [ ] Load addon with existing TattleDB
   - [ ] Verify modules still enabled/disabled correctly
   - [ ] Open config, verify per-module settings initialized

2. **Swapblaster Module**:
   - [ ] Open Swapblaster config
   - [ ] Enable screen + audio
   - [ ] Trigger Swapblaster alert
   - [ ] Verify both screen and audio work

3. **Life Grip Module**:
   - [ ] Open Life Grip config
   - [ ] Enable console only
   - [ ] Have a priest use Life Grip out of combat
   - [ ] Verify console alert appears
   - [ ] Verify no screen/audio (if disabled)

4. **Global Master Switch**:
   - [ ] Disable addon globally
   - [ ] Try to trigger any module
   - [ ] Verify no alerts appear
   - [ ] Re-enable, verify alerts work again

5. **Screen Appearance**:
   - [ ] Open screen config (from any module)
   - [ ] Change font size
   - [ ] Reposition alert
   - [ ] Test alert
   - [ ] Verify changes apply to all modules

## File Changes

### Modified:
- `Core.lua` - Updated to support per-module alerts
- `Config.lua` - Complete UI redesign for per-module config
- `Tattle.toc` - Added Life Grip module

### Added:
- `Modules/LifeGrip.lua` - New Life Grip detection module
- `UPDATES.md` - This file

### Unchanged:
- `ScreenAlert.lua` - No changes needed
- `Modules/Swapblaster.lua` - No changes needed (works with new system)

## Spell IDs

Verified against the live 12.1.5 spell database, so the checking this file used to ask for is already done:

| Ability | Verified ID | What the guess got wrong |
| --- | --- | --- |
| Life Grip | `73325` | Correct. Still named "Leap of Faith" in 12.x, instant, 40 yd |
| Swapblaster | `161399` | `470116` was wrong: it is an internal test spell ("Chasting Strike"). The cast is a spell named **"Swap"**, 1.5 sec channeled |
| Neural Silencer | `156779`, `384129` | `470344` was wrong (a hidden test aura, "Supercharged"), and the buff is **Neural** Silencer |
| Rescue | `370666`, `370667` | New module; `370667` is the passenger-side aura and is a strong candidate rather than a confirmed link |

`/tattle probe` confirms what your own client exposes. Overrides go in the module tab's spell ID editor, not in code.

## Summary

- Per-module alert configuration implemented
- Life Grip detection module added
- Configuration UI redesigned
- Data structure updated
- `/tattle status` enhanced
- Backward compatible
- Documentation updated

**Ready for testing!**
