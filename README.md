# Tattle

A World of Warcraft addon (retail 12.x) that alerts when a group member uses a movement ability you can be griefed with: Swapblaster, Life Grip, or Rescue.

## Features

### Current Modules

- **Swapblaster Detector** (spell `161399` "Swap", from the Swapblaster item 111820):
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

- **Neural Silencer Watch** (auras `156779` / `384129`):
  - Scans the group for the aura that blocks Swapblaster and Leap of Faith
  - **Never announces that somebody is wearing one.** Joining must not produce a roll call of who is protected - a wearer surfaces only when they are involved in a cast (below), or in the list you switched on yourself
  - Optional **on-screen watch list** (off by default, drag-positioned from the config panel): the group's Neural Silencer wearers, and which group members currently have **you** targeted
  - Every other module reads the same scan, which is what lets them explain a blocked cast (below)

### Protected Players Are Called Out

A **Neural Silencer** makes its wearer immune to exactly the toys this addon watches for, so Tattle says so instead of going quiet:

- A grab or swap that resolved but marked nobody is reported as a blocked attempt: `Pancakes attempted a Life Grip on Donut, but it failed because Donut is using a Neural Silencer`. When the group has several protected members it says `on a protected group member` rather than guessing which one
- A Swapblaster that backfires (`182081`) is reported the same way - that spell is the only evidence a blocked swap exists, since a swap that lands marks nobody either
- A caster who fires a Swapblaster out of combat *while wearing one themselves* gets named for it: `Pancakes used Swapblaster, but Pancakes is using a Neural Silencer - that's not fair!`

### Planned Modules

- Hunter pet not present or set to passive
- Low durability warnings
- Additional behavior monitoring

## Alert Options

Tattle provides **per-module** alert configuration. Each module can have its own alert preferences:

- **Monitor scope**: `Whole group` (any group member's cast) or `Only me` (drop a cast only when it can be proven it missed you)
- **Console Output**: Print messages to your chat window
- **Chat Messages**: Send alerts to /say, /yell, /party, /raid or instance chat, or keep them private (configurable per module). `Raid` and `Party` are resolved against the group you are actually in, so announcements land in a **Looking for Raid** raid as well - a plain `RAID` send there goes nowhere
- **Combat awareness**: all three detectors ignore a cast made *in combat* - a mid-fight Life Grip or Rescue is somebody's emergency cooldown, and the Swapblaster toy cannot be used in combat at all. The mechanisms differ: Swapblaster is flagged `outOfCombatOnly`, so the core skips its cast **starts** while the caster is fighting (a swap that begins out of combat is still announced when landing it is what pulled), while Life Grip and Rescue each check `UnitAffectingCombat` on both the start and the success
- **Audio Alerts**: Play customizable sound effects when events occur (5 sounds to choose from)
- **Screen Warnings**: Fully customizable on-screen alerts with:
  - Adjustable font and font size
  - Custom positioning (drag to move)
  - Configurable display duration
  - Optional background
  - Screen appearance is global, but each module controls whether to show screen alerts
- **Spell ID editor**: override the built-in spell IDs in-game, per module

**Example**: You can configure Swapblaster to use screen + audio alerts, while Life Grip only uses console output.

## Usage

### Installation

**From CurseForge** (recommended): install Tattle from the addon manager, and it lands in `Interface/AddOns/Tattle` already spelled the way the game expects.

**From this repository**:

1. Download the zip from the latest GitHub Release - it contains a `Tattle` folder
2. Put that folder in `World of Warcraft/_retail_/Interface/AddOns/`, so the addon is at `Interface/AddOns/Tattle/Tattle.toc`
3. Restart WoW or reload your UI with `/reload`

Cloning the repository gives you the repo layout, not the package: the addon files sit at the top level, so either copy them into a folder named `Tattle`, or let `.pkgmeta` / the release workflow build the zip.

### Configuration

Open the configuration panel with:
```
/tattle
```

### Commands

```
/tattle          - Open configuration panel
/tattle version  - Show addon version
/tattle on       - Enable the addon
/tattle off      - Disable the addon
/tattle debug    - Toggle debug mode
/tattle probe    - Toggle event probe (verify spell IDs + target visibility)
/tattle status   - Show current status and settings
```

## Module Architecture

Tattle uses a modular architecture to make adding new detection modules easy. Each module:

- Registers itself with the core addon
- Subscribes to the events it cares about (`UNIT_SPELLCAST_START`, `_SUCCEEDED`, `_FAILED`, `_INTERRUPTED`, `_CHANNEL_START` / `_CHANNEL_STOP`, and for non-cast modules `UNIT_AURA` / `UNIT_TARGET` / `GROUP_ROSTER_UPDATE`)
- Tells the core which spell names it watches (`Tattle.WatchSpellNames`, from `Initialize`), which is how the core knows to drop every other cast event before waking anyone; a cast handler then receives that name as its fifth argument (`onEvent(event, unitToken, castGUID, spellID, spellName)`)
- Provides detection logic for specific behaviors
- Sends alerts through the unified alert system
- Gets its own tab in the config panel automatically

Registration also accepts three flags the core honours: `outOfCombatOnly` (skip cast *starts* while the caster is fighting), `noScope` (this module filters no casts, so its tab omits the Monitor control), and `extraContent` (a function that adds the module's own options to its tab).

### Creating a New Module

To add a new detection module:

1. Create a new file in `Modules/YourModule.lua`
2. Register the module with `Tattle:RegisterModule()` (declared `events` are registered for you)
3. Implement detection logic in the event handler
4. Add the file to `Tattle.toc`

See `Modules/Rescue.lua` for the smallest complete example.

## Technical Details

### Working around the 12.0 addon restrictions

Midnight 12.0.0 removed `COMBAT_LOG_EVENT_UNFILTERED` (registering it now raises `ADDON_ACTION_FORBIDDEN`), and that was the only API that carried a spell's **destination**. Two techniques replace it:

- **Secret spell IDs**: inside restricted content the `spellID` from cast events is a secret value - it cannot be compared with `==`, printed, or used as a table key. Tattle resolves its own known IDs to spell names once at startup and compares against the name the core resolves for each event (`C_Spell.GetSpellName`, falling back to `C_Spell.GetSpellInfo`).
- **Auras as destinations**: Life Grip and Rescue mark the player they grabbed with a short aura, so the victim is named by scanning group auras (`C_UnitAuras.GetAuraDataBySpellName`), which 12.1.0 made readable out of combat again. Swapblaster marks nobody, so its alerts stop at the caster's name.

### Performance

There is no `OnUpdate` anywhere in the addon, so nothing runs per frame and there is no GPU work beyond the two text frames (`TattleScreenAlertFrame` while an alert is up, and the optional watch list). Everything the addon does is event-driven. What that costs:

- **Cast events are the only noisy input.** In a fight the client reports every raid member's every cast, plus their pets, minions and totems. The core asks the cheapest question first - is this caster one of our players? - and only then resolves the spell name **once per event** with `C_Spell.GetSpellName` (a plain string - no table allocated), dropping the event unless a module registered that name. Three modules used to each call `C_Spell.GetSpellInfo` on every cast, which is three API calls and three thrown-away tables per cast; the harness asserts exactly one resolution per cast event, and that a pet or NPC cast costs none at all.
- **Four gates run before any module code**: addon enabled, grouped, spell name watched by somebody, caster is a group member. Out of a group the addon does nothing at all.
- **Aura and target scans are cached and throttled.** The group's unit token lists (`Tattle.GroupUnitTokens` / `GroupTargetEntries`) are built once and dropped on `GROUP_ROSTER_UPDATE`, so a watch-list sweep allocates nothing. Scans are driven by `UNIT_AURA` / `UNIT_TARGET` plus a 0.5 s ticker, throttled to no faster than every 0.25 s - about four sweeps of ~25 aura lookups a second at the ceiling, and only while the watch list is switched on. The frame is re-measured only when its text actually changed.
- **Nothing is created until it is needed.** The config panel (~200 widgets) is built the first time you open `/tattle`, not at login; the watch list frame and its timer are created when you tick them and the timer is cancelled when you untick them.
- **Localised globals, early returns, and `pcall` around anything that may receive a secret value**, so a restricted context cannot error a module.

If you want the addon to cost nothing: untick the watch list on the Silencers tab, and the only work left is one name lookup per cast event and an immediate return.

### When alerts fire

The addon only processes cast events when:
- The addon is enabled
- You are in a party or a raid (these abilities require a group, so out of one there is nothing to watch - `/tattle probe` follows the same rule)
- The caster is one of your group's **players**. Nothing Tattle watches can come from anything else - the Swapblaster is a toy and Life Grip, Leap of Faith and Rescue are player spells - so a hunter's pet, a warlock's minion, a totem and every NPC are rejected before their spell is even named. Membership includes you, which the `partyN` / `raidN` tokens do not
- The cast is a spell some module registered (`Tattle.WatchSpellNames`)
- The module's `Monitor` scope allows the cast
- For the Swapblaster only: the caster is not in combat. A swap that began out of combat is still announced even if landing it is what started the fight

### Verifying spell IDs

The shipped IDs were checked against the live 12.1.5 spell database, but the API behaviour that *delivers* them is best confirmed on your own client:

1. `/tattle debug` then `/tattle probe`, then use each ability on yourself and on a friend
2. The probe prints every cast event it sees (including the channeled `CHANNEL_START` / `CHANNEL_STOP` the Swapblaster uses), whether the caster argument can be named, whether any destination argument is exposed, and which group auras are visible - which is what the "on Donut" half of an alert depends on
3. It also prints the group's Neural Silencer wearers and what it can read from other players' target tokens, which is all the optional watch list has to work with
4. If an ID is wrong for your build, enter the right one in the module tab's spell ID editor and `/reload`

## The Tattle Turtle (icon and artwork)

![Tattle Turtle](TattleTurtle.png)

| File | What it is for |
|---|---|
| `TattleTurtle.tga` | The in-game icon: 128×128, 32-bit uncompressed, bottom-left origin. Referenced by `## IconTexture` in `Tattle.toc`, so it shows in the addon list |
| `TattleTurtle.png` | The same 128×128 picture, for the README (excluded from the packaged addon) |
| `Tools/tattle-turtle-512.png` | 512×512 upload for the CurseForge project icon |
| `Tools/tattle-turtle-32.png` | What it looks like at addon-list size - the readability check |

It is not a hand-drawn asset, it is **generated**: `Tools/make_icon.py` renders the
scene (plaque, turtle, speech bubble) with no third-party dependencies and writes
every size from one design, so the TGA and the PNGs can never drift apart.

```bash
python3 Tools/make_icon.py     # rewrites the .tga and all three .png files
```

The layout lives in the constants at the top of that file (`SHELL`, `HEAD`, `BUB`,
`SCUTE_SIZE` and the palette), in 128-unit design coordinates - move the turtle by
editing numbers and re-running, not by pushing pixels.

## Requirements

- World of Warcraft retail 12.x. `Tattle.toc` accepts the interface values `120001` and `120000`
- No dependencies, no saved-game addons, no extra libraries

## Releases & CI

Two GitHub Actions workflows:

- **Test** (`.github/workflows/test.yml`) runs on every push to `main` and on pull requests. It installs `lua5.1` and runs `Tests/wow_stub.lua`, a stub WoW client that loads the addon in TOC order and asserts alert routing, instant-cast handling, scope gating, silent joining, non-player cast rejection, the config panel tabs and the spell-ID editor. Locally: `lua Tests/wow_stub.lua` (exit 0 = pass).
- **Release** (`.github/workflows/release.yml`) runs on an **annotated tag push** (`v*`). `BigWigsMods/packager` builds the addon zip from `.pkgmeta`, names it `Tattle-<version>` using the `## Version` in `Tattle.toc`, creates the GitHub release for the tag, attaches the zip, and uploads to CurseForge using `## X-Curse-Project-ID: 1782380`.

To ship a version:

1. Bump `## Version` in `Tattle.toc`, and turn the `## [Unreleased]` heading in `CHANGELOG.md` into `## [<version>] - <date>`
2. Run the harness: `lua Tests/wow_stub.lua`
3. Tag and push: `git tag -a v0.2.0-alpha.1 -m "Tattle 0.2.0-alpha.1"` then `git push origin main v0.2.0-alpha.1`

The tag must be **annotated** (`git tag -a`), because the packager reads the version from the tag and builds the changelog from the commits between tags.

CurseForge publishing needs a CurseForge API token (created at authors.curseforge.com, account settings -> API tokens) stored as the repository secret `CF_API_KEY`. Without that secret the CurseForge upload is skipped and everything else still runs - in which case download `Tattle-<version>.zip` from the GitHub release and upload it on the project's files page by hand.

## Development

Built following WoW addon best practices:
- Modular architecture for maintainability
- Localized globals for performance
- Error handling with pcall
- Efficient event filtering
- Clean separation of concerns

## Version

Current version is defined in `Tattle.toc`
