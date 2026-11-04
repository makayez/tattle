# Changelog

All notable changes to Tattle will be documented in this file.

## [0.2.0-alpha.1] - 2026-11-03

### Added
- **MIT license** (`LICENSE`), the same terms as tarballs-dadabase. `LICENSE` is not in the `.pkgmeta` ignore list, so it ships inside the packaged addon folder too - the repository, the CurseForge project's license field and the zip a user installs all say the same thing
- **`CURSEFORGE.md`**: the project page copy, kept in the repo so it stays true to the code. Every claim in it was checked against the source - alert strings against the tests, chat channels against `CHAT_TYPE_OPTIONS`, sounds against `SOUND_OPTIONS`, the combat behaviour against each module's own `UnitAffectingCombat` check. Excluded from the packaged addon via `.pkgmeta`
- **`DESCRIPTION.md`**: the short, image-free summary of what Tattle is for, written for someone deciding whether to install it rather than for someone maintaining the repo
- **CurseForge publishing is wired up.** `Tattle.toc` now carries `## X-Curse-Project-ID: 1782380`, `release.yml` triggers on an annotated tag push instead of waiting for a hand-made GitHub Release, and one run builds the zip, publishes the GitHub release and uploads to CurseForge. The CurseForge half needs a CurseForge API token stored as the `CF_API_TOKEN` repository secret (the packager calls the variable `CF_API_TOKEN`; `CF_API_KEY` is accepted as well); without it the upload is skipped and the release asset can be dragged onto the CurseForge files page by hand. That secret is in place, and this release's file reached CurseForge project 1782380 from the workflow
- **The Tattle Turtle.** `TattleTurtle.tga` (128×128, 32-bit uncompressed, bottom-left origin) is now the addon icon via `## IconTexture` in `Tattle.toc`, with `Tools/tattle-turtle-512.png` sized for the CurseForge project icon upload, `TattleTurtle.png` for the README and `Tools/tattle-turtle-32.png` as the small-size readability check. All four are generated from one design by `Tools/make_icon.py`, which depends on nothing but the standard library, so the TGA and the PNGs cannot disagree - edit the layout constants and re-run rather than editing pixels

### Renamed
- **Snitch is now Tattle.** Everything moved with it: the folder and `.toc` (`Tattle.toc`), the global (`Tattle`), the saved variables (`SnitchDB` → `TattleDB`), the chat command (`/tattle`), the frame names (`TattleConfigPanel`, `TattleScreenAlertFrame`, `TattleWatchFrame`) and the packaging name (`package-as: Tattle`). **`/tattle` is the only command** - the old spelling is not registered at all, so a stale `/snitch` macro fails visibly instead of half-working behind an alias the docs no longer teach. **Settings do not carry over** - saved variables live per addon folder and one addon cannot read another's file - so either re-tick what you had, or copy `WTF/Account/<account>/SavedVariables/Snitch.lua` to `Tattle.lua` and rename the variable inside it

### Added
- **Neural Silencer Watch module** (`Modules/Silencer.lua`, auras `156779` / `384129`): scans the group for the aura that blocks Swapblaster and Leap of Faith, and owns the spell IDs every other module reads through `Tattle.silencerNames`. It is display-only - the module contains no `SendAlert` call at all (see *Changed* below)
- **Optional on-screen watch list** (off by default, drag-positioned from the module tab): the group's Neural Silencer wearers, plus which group members currently have you targeted. Refreshes from `UNIT_AURA` / `UNIT_TARGET` plus a 0.5 second timer, throttled to 0.25 s, with no per-frame work; it hides itself when you leave the group or disable the addon and cancels its timer when you untick it
- **Blocked attempts are explained** instead of reported as a mystery: `Pancakes attempted a Life Grip on Donut, but it failed because Donut is using a Neural Silencer`, for Life Grip, Rescue and Swapblaster. Where more than one member is protected the alert says `on a protected group member` rather than guessing a victim
- **Swapblaster backfire detection** (`182081`, "Swapblaster Explosion"): the one event that proves a blocked swap attempt exists, since a swap that lands marks nobody either way. Announced once per attempt even when the cast events also arrive
- **Cheating call-out**: a caster who fires a Swapblaster out of combat while wearing a Neural Silencer themselves is named for it - `Pancakes used Swapblaster, but Pancakes is using a Neural Silencer - that's not fair!`
- `Instance` chat channel option, and `outOfCombatOnly` / `noScope` / `extraContent` module registration flags so a module can ask the core to skip combat cast starts, drop the Monitor control it would ignore, and add its own options to its config tab
- `/tattle` is checked as the single chat command: it works, and the pre-rebrand command is asserted absent from `SlashCmdList`
- The stub harness gained mutable group/combat/target state, `C_Timer.NewTicker`, `GetStringHeight`, and checks for all of the above (45 checks to 97 - five announcement checks came out with the feature, and checks for silent joining, pet/NPC rejection, self-casts and per-event spell resolution went in)

### Changed
- **Wearing a Neural Silencer is never announced.** The "X put up a Neural Silencer" announcement (and its config option) is gone: wearing the thing is not an event, and joining a raid should not read out who is protected. A wearer surfaces in two places only - the opt-in watch list you switched on and positioned yourself, and the cast alerts raised by the module that saw the attempt, which is where the protection actually matters. The Silencers tab now says so in one line of grey text where the checkbox used to be
- **Only players are considered as casters.** Nothing Tattle watches can come from anything else - the Swapblaster is a toy, and Life Grip, Leap of Faith and Rescue are player spells - so the dispatcher now rejects casts by pets, minions, totems and NPCs *before* resolving the spell name, which is the cheapest place to drop them. A module that ever needs a non-player caster opts out with the new `allCasters` registration flag; because that widens the event for everybody listening to it, the per-module membership checks stay as guards
- **`Raid` chat now works in Looking for Raid groups.** An LFR group is a raid but not a `LE_GROUP_TYPE_RAID` one, and a plain `RAID` send there is dropped silently. `Tattle.ResolveChatChannel` now resolves `Raid` / `Party` requests against the group you are actually in (`Raid` in a party is delivered on `PARTY`), and `/tattle status` shows the channel a message would really use. Same class of bug fixed in tarballs-dadabase
- The Swapblaster's cast *start* events are not evaluated while its caster is in combat (the toy cannot be used in combat). Cast completions are still processed, because landing a swap can be exactly what starts the fight - gating those would drop the alert that matters most. Life Grip and Rescue are deliberately not gated: a grip or a rescue is still worth seeing in combat
- `/tattle probe` prints nothing while you are solo, now reports the channeled `CHANNEL_START` / `CHANNEL_STOP` events the Swapblaster actually uses, and reports the group's Neural Silencer wearers and what it can read from other players' target tokens
- Module tabs are assembled from shared sections (warning, enable, scope, alerts, module extras, spell IDs) so the Silencer tab reuses the same controls instead of forking the tab
- The Neural Silencer spell IDs moved from `Modules/Swapblaster.lua` to the module that owns them

### Performance

Audited the hot paths, because "does this cost anything in a raid?" deserves a real answer rather than a shrug:

- **One spell-name resolution per cast event instead of one per module.** The core now resolves the spell name itself, prefers `C_Spell.GetSpellName` (a plain string, so no `SpellInfo` table is allocated per cast), and drops any cast event whose name no module registered before waking anybody. Three modules used to each call `C_Spell.GetSpellInfo` on every cast the raid produces, watching spells nobody cared about. Modules receive the resolved name as an extra `onEvent` argument
- **The group's unit token lists are cached** (`Tattle.GroupUnitTokens` / `Tattle.GroupTargetEntries`) and dropped on `GROUP_ROSTER_UPDATE`, so repeated aura and target sweeps no longer rebuild a 25-entry table and 50 `"raid"..i` strings per sweep
- **The Silencer module's settings migration runs when a saved entry is actually incomplete**, not on every `GetSettings` call, which sits on a path that runs several times a second
- **The watch list re-measures itself only when its text changed** (`SetText` and `SetPoint` both invalidate layout; the refresh runs up to four times a second)
- **`/tattle probe`'s group context lines are all behind its one-second throttle now**, including the three aura sweeps, which used to run on every cast event while the probe was armed
- Cheaper first checks in Life Grip and Rescue (group membership before spell matching), and `EventListener.lua` now registers `GROUP_ROSTER_UPDATE` for the core's own cache rather than relying on a module to subscribe to it

The addon has no `OnUpdate` anywhere, so there was and is no per-frame or GPU cost; the config panel is still built on first open, not at login.

### Fixed
- **Membership now includes you.** The `partyN` / `raidN` tokens exclude yourself and membership was decided by `UnitInRaid` / `UnitInParty` alone, so your own Swapblaster or Life Grip could be filtered out before any module ever saw it. `IsGroupMemberToken` also asks `UnitIsUnit(token, "player")` now - secret-safe, unlike comparing the token directly - and there is a check that a self-cast alerts
- The stub harness called a frame's `OnEvent` once per `RegisterEvent` call for the same event, so any event registered from two places (the core list plus a module's declared `events`) produced duplicate alerts in the checks. Real WoW registers an event once per frame; the stub now does too - this was harness noise, not an addon bug
- The spell ID editor could be given a zero or negative height on a tall tab; it now floors at a usable size

### Notes
- Whether your client is told other players' targets at all is a patch and context question. "Targeting you" reports what it can read and `/tattle probe` shows the raw reads, so an empty list is never silently mistaken for "nobody is looking"
- A Neural Silencer is documented to block Swapblaster and Leap of Faith. The Rescue call-out is inference from a flight that marked nobody, and says "attempted" for that reason
- **Why `0.2.0-alpha.1`.** The last tag was `v0.1.0-alpha.1`, dated after `0.1.0`, which inverts the series: a pre-release of a version that already shipped. This release reopens it in order - `0.2.0` is the next feature line, and `-alpha.1` says it is still being tested in a raid, which an alpha is supposed to mean. Two things are deliberately *not* in it: naming a Swapblaster's victim (the swap marks nobody, so there is nothing to prove), and a scrollable event history window
- **The tag was re-cut from `v0.2.0-alpha.1` once.** The first cut had 0 asset downloads and no CurseForge file, and it pointed at a commit whose `release.yml` read the token from a secret named `CF_API_KEY` while the repository secret is `CF_API_TOKEN`, so the packager saw an empty token and skipped CurseForge. The tag now points at a commit whose workflow accepts either name, and the re-cut build also carries `LICENSE`

## [0.1.0-alpha.1] - 2026-10-31

First packaged release: the first version built by the CI pipeline and the first tag in this repository.

### Added
- **Rescue Detector** module (Evoker `Rescue`, spell `370666`), the third griefing movement ability
- **Target naming from auras**: Life Grip and Rescue mark the player they grab, so alerts can now say `Pancakes used Life Grip on Donut!` or `... on you!` - the combat log is gone, so the victim's aura is the only remaining destination information
- **Channeled cast handling**: `UNIT_SPELLCAST_CHANNEL_START` / `_CHANNEL_STOP` are tracked, and one cast is never announced twice even if both event families arrive
- **Tabbed configuration panel**: one window (`/tattle`) with **About**, **General**, **Screen Alerts**, and one tab per module. The separate per-module and screen-appearance windows are gone
- **Chat channel options**: `Private (console only)`, `Say`, `Yell`, `Party`, `Raid` - configurable per module
- **Monitoring scope per module**: `Whole group` or `Only me`
- **Spell ID editor per module**: enter spell IDs in-game (comma or newline separated) with Save / Reset to Defaults, so IDs can be verified without editing code
- `/tattle probe`: dumps what the cast events actually expose in the current build, including which group auras are visible (that visibility is what target naming depends on)
- Color swatches for screen alert text
- GitHub Actions: release workflow (`BigWigsMods/packager` on release publish) and a test workflow running a stub-client harness under `lua5.1`

### Changed
- **Spell IDs verified against the live 12.1.5 spell database**: Swapblaster's cast is spell `161399` (named "Swap", a 1.5 second channeled item effect from item 111820), Life Grip is `73325` (still named "Leap of Faith", not renamed in 12.x), Rescue is `370666` with the passenger-side aura `370667`
- The anti-Swapblaster buff is **Neural Silencer** (`156779`, `384129`), not "Neurosilencer"
- `Monitor: Only me` now means "it involved me": a cast by someone else that can be *proven* to have missed you is dropped, an unresolvable target is still reported. A cast by another player used to be suppressed outright, which discarded the exact warning the addon exists to give
- Works in parties as well as raids (previously raid-only), which is where Swapblaster/Life Grip griefing actually happens
- `chatType` is now honored; previously the chat channel was hardcoded to raid
- Spell IDs are matched by resolved spell name so secret spell values never have to be compared directly
- A Swapblaster whose channel ends early is reported as "cut short" instead of a completed swap

### Fixed
- The addon crashed on load: `EventListener.lua` was missing from the TOC, so the event frame did not exist yet
- Swapblaster watched spell `470116`, which is an unrelated internal test spell ("Chasting Strike"); the watched aura `470344` likewise resolved to a hidden test aura ("Supercharged")
- Swapblaster watched only `UNIT_SPELLCAST_START`, but its real cast is channeled, so the warning could have been missed entirely
- Aura scanning only looked at `raidN` tokens, silently skipping parties
- Life Grip alerts never fired: the success alert required a preceding cast-start event, which an instant cast never sends
- `/tattle status` listed modules in `pairs()` order, so the order changed between runs

### Notes
- CurseForge publishing is commented out in the release workflow until Tattle has a CurseForge project
- Swapblaster applies no aura to either side, so no 12.x API can name its victim; its alerts stop at the caster
- 12.1.0 relaxed the out-of-combat private-aura restriction, which is what makes the Life Grip and Rescue target naming possible. `/tattle probe` prints whether auras are actually visible on your client

## [0.1.0] - 2026-02-15

Development milestone only - this version was never tagged or packaged, and several
claims below were later corrected against the live 12.1.5 spell database.

### Added
- Initial release
- Core addon framework with modular architecture

- **Per-Module Alert Configuration**:
  - Each module has independent alert settings
  - Global master switch to enable/disable entire addon
  - Configure console, chat, audio, and screen alerts separately for each module
  - Example: Swapblaster can use audio + screen, Life Grip can use console only

- **Swapblaster Detection Module**:
  - Alerts when someone starts casting Swapblaster
  - Alerts on successful cast
  - Alerts on cancelled or interrupted cast
  - Identifies cast target
  - **Detects Neurosilencer buff on target** (warns if swap will be blocked)
  - Reports block status on successful cast completion

- **Life Grip Detection Module**:
  - Alerts when a priest uses Life Grip (Leap of Faith) while out of combat
  - Identifies who is being gripped
  - Only triggers for out-of-combat usage
  - Reports cast start, success, and cancellation

- **Alert System**:
  - Console output
  - Chat messages (/say, /party, /raid) - configurable per module
  - Audio alerts with 5 customizable sounds - configurable per module
  - **Fully customizable screen warnings**:
    - Adjustable font (4 font options)
    - Adjustable font size (16-72)
    - Custom positioning via drag-and-drop
    - Configurable display duration (1-10 seconds)
    - Optional background
    - Screen appearance is global, per-module on/off control
    - Settings saved per character
- Configuration UI
  - Enable/disable addon globally
  - Enable/disable individual modules
  - Configure alert preferences
  - Test audio alerts
- Slash commands:
  - `/tattle` - Open configuration
  - `/tattle version` - Show version
  - `/tattle on/off` - Enable/disable
  - `/tattle debug` - Toggle debug mode
  - `/tattle status` - Show detailed status
- Performance optimizations:
  - Localized globals
  - Efficient combat log filtering
  - Protected calls for error handling
  - Name caching to reduce string operations
- Only active when in a party or raid group
- Debug mode for troubleshooting

### Technical
- Modular architecture for easy addition of new detection modules
- Single source of truth for version (reads from .toc)
- Best practices for WoW addon development
- Clean separation of core logic, config UI, and modules
