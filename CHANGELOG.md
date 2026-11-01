# Changelog

All notable changes to Snitch will be documented in this file.

## [0.1.0-alpha.1] - 2026-10-31

First packaged release: the first version built by the CI pipeline and the first tag in this repository.

### Added
- **Rescue Detector** module (Evoker `Rescue`, spell `370666`), the third griefing movement ability
- **Target naming from auras**: Life Grip and Rescue mark the player they grab, so alerts can now say `Pancakes used Life Grip on Donut!` or `... on you!` - the combat log is gone, so the victim's aura is the only remaining destination information
- **Channeled cast handling**: `UNIT_SPELLCAST_CHANNEL_START` / `_CHANNEL_STOP` are tracked, and one cast is never announced twice even if both event families arrive
- **Tabbed configuration panel**: one window (`/snitch`) with **About**, **General**, **Screen Alerts**, and one tab per module. The separate per-module and screen-appearance windows are gone
- **Chat channel options**: `Private (console only)`, `Say`, `Yell`, `Party`, `Raid` - configurable per module
- **Monitoring scope per module**: `Whole group` or `Only me`
- **Spell ID editor per module**: enter spell IDs in-game (comma or newline separated) with Save / Reset to Defaults, so IDs can be verified without editing code
- `/snitch probe`: dumps what the cast events actually expose in the current build, including which group auras are visible (that visibility is what target naming depends on)
- Color swatches for screen alert text
- GitHub Actions: release workflow (`BigWigsMods/packager` on release publish) and a test workflow running a stub-client harness under `lua5.1`

### Changed
- **Spell IDs verified against the live 12.1.5 spell database**: SwapBlaster's cast is spell `161399` (named "Swap", a 1.5 second channeled item effect from item 111820), Life Grip is `73325` (still named "Leap of Faith", not renamed in 12.x), Rescue is `370666` with the passenger-side aura `370667`
- The anti-Swapblaster buff is **Neural Silencer** (`156779`, `384129`), not "Neurosilencer"
- `Monitor: Only me` now means "it involved me": a cast by someone else that can be *proven* to have missed you is dropped, an unresolvable target is still reported. A cast by another player used to be suppressed outright, which discarded the exact warning the addon exists to give
- Works in parties as well as raids (previously raid-only), which is where SwapBlaster/Life Grip griefing actually happens
- `chatType` is now honored; previously the chat channel was hardcoded to raid
- Spell IDs are matched by resolved spell name so secret spell values never have to be compared directly
- A Swapblaster whose channel ends early is reported as "cut short" instead of a completed swap

### Fixed
- The addon crashed on load: `EventListener.lua` was missing from the TOC, so the event frame did not exist yet
- SwapBlaster watched spell `470116`, which is an unrelated internal test spell ("Chasting Strike"); the watched aura `470344` likewise resolved to a hidden test aura ("Supercharged")
- SwapBlaster watched only `UNIT_SPELLCAST_START`, but its real cast is channeled, so the warning could have been missed entirely
- Aura scanning only looked at `raidN` tokens, silently skipping parties
- Life Grip alerts never fired: the success alert required a preceding cast-start event, which an instant cast never sends
- `/snitch status` listed modules in `pairs()` order, so the order changed between runs

### Notes
- CurseForge publishing is commented out in the release workflow until Snitch has a CurseForge project
- SwapBlaster applies no aura to either side, so no 12.x API can name its victim; its alerts stop at the caster
- 12.1.0 relaxed the out-of-combat private-aura restriction, which is what makes the Life Grip and Rescue target naming possible. `/snitch probe` prints whether auras are actually visible on your client

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
  - Example: SwapBlaster can use audio + screen, Life Grip can use console only

- **SwapBlaster Detection Module**:
  - Alerts when someone starts casting SwapBlaster
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
  - `/snitch` - Open configuration
  - `/snitch version` - Show version
  - `/snitch on/off` - Enable/disable
  - `/snitch debug` - Toggle debug mode
  - `/snitch status` - Show detailed status
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
