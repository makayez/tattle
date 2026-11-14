# Changelog

All notable changes to Tattle will be documented in this file.

## [0.2.0-beta.1] - 2026-11-13

The two bugs that came back from alpha.3 with a traceback attached, plus the review of
the fix for them. Both reports were the same underlying thing seen from two sides: a 12.x
client hands over Mythic+ and rated-PvP values in a form an addon is not allowed to look
at, and this addon looked. One new rule about when the addon is allowed to speak at all,
and three checks in the harness that were passing while reading no code at all.

### Added
- **Tattle says nothing while you are fighting.** While *you* are in combat no module runs, no alert is sent, and nothing is asked of the client; `/tattle status` prints `In combat: YES - Tattle is silent while you fight`, so a quiet raid is explainable instead of mysterious. Everything this addon watches is an out-of-combat act - the Swapblaster says "Cannot be used in combat" on its own tooltip - and this is a separate question from the existing rule about the *caster*, which stays: you can be standing still while a group member is fighting, and a group member who is fighting is not griefing anybody. The one part of the addon the rule lets through is `/tattle probe`, on purpose: the question that instrument exists to answer is what a client sends and withholds during a fight. It is disarmed by `/tattle off` with everything else. One consequence worth knowing before you call it a regression: a swap that *began* out of combat and lands after you are fighting is no longer announced - the Swapblaster's `outOfCombat = "start"` policy still applies to the caster, and your own combat state now outranks it
- **`/tattle status` lists "Problems this session"** with a count for each kind. A module that threw on a cast event, a module that threw while initializing, a cast the client would not let Tattle classify, a spell name that came back unreadable, a group member the client would not identify: all of them used to be debug-printed and therefore invisible, which is what made "no Swapblaster alerts in my M+ key" indistinguishable from "the gate decided not to fire". The first of each kind is printed when it happens; the count is how you notice it afterwards
- Five helpers modules are now required to use instead of the client's own APIs: `Tattle.NameMatches`, `Tattle.PlainText`, `Tattle.GroupSlotOf`, `Tattle.CasterLabel`, `Tattle.GetUnitShortName`. The harness audits the modules and `Commands.lua` for going around them
- **The harness can model restricted content.** Spell IDs, cast GUIDs, caster tokens and unit names are handed to the real dispatch path as proxy values whose every operation - index, compare, concatenate, lengthen, convert, test for truthiness - refuses, the way a client refuses. `type()` still answers `"string"` for them, which is exactly the property that made the original bug invisible to a plausible-looking guard

### Fixed
- **`attempt to compare local 'name' (a secret string value, while execution tainted by 'Tattle')`.** The crash a Mythic+ run produced within moments of a Swapblaster going off. A `pcall` wrapped the call to `C_Spell.GetSpellName` and the very next line compared what came back with an empty string - outside the protection - and a secret string reports as a string and then refuses to be compared. That line was the visible one; the same unreadable value was also being used as a table key in three places, which fails the same way. Nothing that came from the client is inspected any more: spell identity is matched by the core, names are printed only after the core has proved they are printable, and a cast the client would not classify is reported as a refusal instead of quietly answered "not one of ours". Restricted content is not an edge case for this addon; it is where all the griefing happens, so the fix had to be in the identification path rather than in a guard at one call site
- **`Malloc is casting Swapblaster` and `Malloc's Swapblaster was interupted`, each of them twice.** Three separate causes of the same symptom, all of them now checked: state keyed on whichever unit token an event happened to carry, so a raid client that reports your own casts once as your `raidN` index and once as `player` got one record per token; late-arriving halves of a cast that the settled record of the first half no longer suppressed; and the plain and channeled halves of one Swapblaster cast arriving with *different* cast GUIDs, which no identity-based dedupe can see through. Cast state is now keyed on a group slot this addon resolved itself, and deduped by the record a cast left rather than by the identity an event carried
- **A second Swapblaster could go unreported entirely**, which is what the fix above cost at first and is worth reading as the actual trade. Suppressing every cast start while a fresh record existed meant somebody who was refused, retargeted and fired again two seconds later was reported not at all, for up to eight seconds. Seconds cannot separate a late half of one cast from a second attempt at another - both are two seconds apart - but the *event family* can, because one cast sends at most one plain start and one channeled start. Two swaps two seconds apart are now announced as the two swaps they were. What still cannot be told apart, and is not pretended otherwise: a second attempt whose first event happens to arrive as the other family reads as the late half of the first, and stays unannounced
- **`the client would not say whether a cast was one Tattle watches` counted against ordinary casting.** The comparison helper ended in `answered and false or nil`, an idiom that cannot produce `false` (`true and false` is `false`, `false or nil` is `nil`), so "the client compared it and said no" was filed as "the client refused to answer" - which turns every spell the raid is casting in a key into a reported refusal and makes the one line that distinguishes a real restriction from ordinary casting unreadable. `false` and `nil` mean different things again, and a secret cast of a spell Tattle does not watch now neither announces nor reports anything
- **The in-combat start gate gated nothing in alpha.3.** `OUT_OF_COMBAT_EVENTS.start` was built from a table of cast-start events that had not been defined yet, so the Swapblaster's `outOfCombat = "start"` policy matched no event, and the only notice was a harness line about an unknown policy that nothing was asserting. Both cast-start families are named explicitly now, and the harness proves the gate *drops* as well as allows - the half of a gate that no positive alert can detect
- **A module that throws while initializing took the addon down with it.** Its `initialize` was called unguarded inside `ADDON_LOADED`, after the module registry was filled but before the listener lists, the module settings and the config tabs existed: an addon that had registered its modules and then silently did nothing, noticed as one taint line. Failures are caught and reported per module now, and the module registered behind a broken one still initializes
- **A raw client token could reach a module's state as a table key.** Where the client hands over a group member it will not identify, the core now reports it and drops the cast rather than passing the client's own value through: a module keys per-cast state on that token, and keying a table with a secret is an error rather than a miss

### Harness
Three checks were passing while reading no code, all three found by reading the harness as hard as the addon:

- the audit that keeps modules off the client's raw value-APIS selected its files with `file:find("^Modules/", 1, true)` - with plain find the second argument is a start index, not a pattern, so it searched source lines for the nine literal characters `^Modules/`, matched nothing, and reported clean over the three modules it exists to police. Proper patterns now, with frontier anchors so the `Tattle.` wrappers it wants modules to *call* are not flagged, and every source audit asserts how many files it actually opened
- the audit for Lua constructs newer than the game's Lua read a hand-written file list that had silently dropped `Config.lua`, `ScreenAlert.lua` and `ConfigSpellIDs.lua`; it is driven from the TOC now, and reads-every-shipped-file is asserted
- the stub fed the addon a hand-typed `"0.2.0"` while `Tattle.toc` said `0.2.0-alpha.3`. It reads the TOC now, and a check asserts the two agree - the tag, the TOC and the line `/tattle version` prints are how a bug report says which build somebody is holding

The stub also states, per interpreter, how faithfully its fake secret values model a client: `__len` on a table does not exist before Lua 5.2, so on CI's `lua5.1` a fake secret answers `#` instead of refusing. 172 checks pass; every one of the fixes above was verified by putting the old code back and watching the specific check fail.

## [0.2.0-alpha.3] - 2026-11-04

A review pass over the whole addon - what the code claims, what it costs, and what
was still in it that nothing calls - plus the one feature it kept describing as a
limitation and never tried to work around. And one user-visible bug that the
harness could not see until the harness was made to model a raid correctly.

### Added
- **Swapblaster now names the other half of the swap.** The toy leaves no aura on either player, and `COMBAT_LOG_EVENT_UNFILTERED` - the only API that ever reported where a spell was aimed - was removed in 12.0.0. So the victim is read from the caster's own target at the moment the cast starts, which is the instant the toy requires a target ("Swaps your location with another party member"): `Donut is casting Swapblaster at Pancakes`, then `Donut used Swapblaster on Pancakes` - or `at you` / `on you`, which is the sentence this addon exists to produce. Where your client is not told other players' targets the alert says what it always said and names nobody: `Tattle.GroupMemberTargetOf` answers "your client was not told" with nothing, and the module will not guess. A backfire whose target is readable names the protected player who set it off instead of hedging about "a protected group member"
- That read is deliberately **not** fed to the `Only me` scope. It is strong evidence of intent and good enough to put a name in a sentence, but suppressing an alert on it would mean a swap you never saw coming went unreported because a target field was momentarily pointing elsewhere

### Fixed
- **Swapblaster's other half, part two: a caster's second swap could be silenced by their first.** One cast's record is kept after it settles so the two halves of the same cast (START with CHANNEL_START, SUCCEEDED with CHANNEL_STOP) cannot announce it twice - but the record was permanent, so a *later* cast by the same unit that reached the module only as a completion (out of range, a `/reload` mid-channel, a client that reports the toy only once it resolves) matched the old settled record and was discarded as a duplicate. Settled records now expire after 8 seconds: far longer than one cast's own events take to arrive, far shorter than any gap between two casts a player can make
- **The addon read you twice in a raid.** In a raid you hold one of the `raidN` indexes and `GetNumGroupMembers()` counts you; a party calls you `player` and numbers only the other four. `GroupUnitTokens` enumerated `raidN` up to the member count *and* appended `player`, so inside a raid you were scanned twice, and every group-wide sentence gained a second copy of you: the watch list said `you and you`, a blocked cast said `because you and you are using a Neural Silencer`, a Life Grip that landed on you read `used Life Grip on you and you`, and an Evoker who Rescued Pancakes was reported as also having been rescued by themselves. Unit tokens that might name you are now compared with `UnitIsUnit` (`Tattle.IsYou`, `Tattle.IsSameUnit`) rather than with `==`, which is also the safe way to compare a token that could be a secret value
- **A module registered after `ADDON_LOADED` was left half wired**: no settings, and its declared events were never installed as listeners, because the core registers events once at start-up and had no second chance. `RegisterModule` now initialises its settings and rebuilds the listener table, so a late module works or is loudly broken rather than quietly doing nothing
- **The config panel's height was a constant** (`700`) picked when the addon had fewer options in it, and tabs are not clipped - the next option added to the tallest tab would have spilled its spell ID editor over the bottom of the window. Each tab builder now reports the depth it used and the window is built around the deepest one
- **The two sliders on the Screen Alerts tab indexed a widget that was never there.** `OptionsSliderTemplate` supplies its low/high labels as `$parentLow` / `$parentHigh`, which only exist as reachable widgets when the slider is created *named* - Tattle's sliders are anonymous, so `slider.Low:SetText(...)` reads a nil field and indexing it aborts the panel build. The end labels are now created by `AddSlider` itself, which also means they are positioned by the same code that positions the value readout. A stub that answers every unknown key with a no-op cannot catch this class of mistake, which is why it survived until the widget audit was tightened

- `PlaySound` behind the Screen Alerts tab's *Test Sound* button is now guarded like the real alert path, so a `SOUNDKIT` constant that a patch renames prints a line instead of raising an error dialog

### Changed
- **One event owner.** `EventListener.lua` is gone. `Core.lua` creates the single event frame, registers `ADDON_LOADED`, `GROUP_ROSTER_UPDATE` and the cast events its modules ask for, and does the cast filtering there. Two frames used to register the same six cast events, and a module's own event list was registered by a third file's loop over a table it did not own
- **Combat policy belongs to the core and is spelled once.** Registration takes `outOfCombat = "all"` (drop every event of a cast whose caster is fighting - what an instant spell wants) or `"start"` (drop only the cast/channel starts, so a swap begun out of combat is still announced when it lands). The old boolean `outOfCombatOnly` meant the second and could only mean the second, which is why Life Grip and Rescue each carried a private copy of the first. The core asks the caster's combat state at most once per event, and only when a listening module asked for the rule at all
- **Life Grip and Rescue are one file**: `Modules/CastSpells.lua` registers both from one table-driven factory. They differ in their spell IDs and in the word that goes in the sentence, and the two files differed in nothing else for 300 lines
- **`Core.lua` shed three files' worth of work**: `/tattle probe` is now `Probe.lua`, the chat command is `Commands.lua`, and the spell ID editor is `ConfigSpellIDs.lua`. What is left in the core is what more than one module needs
- **`Tattle.ShouldReport` became `Tattle.ScopeDrops`.** It answered a three-valued question with a boolean whose polarity each caller had to remember; now the name says what `true` means, and "we cannot prove who it hit" is written as `nil` and documented as never being a reason to stay quiet
- **The per-module spell boilerplate moved into the core**: `Tattle.MakeSpellIDs` (what the player typed, or what ships), `Tattle.ResolveSpellNames` (IDs to names, registered with the dispatcher), `Tattle.MakeSpellMatcher` (the name-or-ID test every handler started with). Three copies of each came out
- Module and listener order comes from `Tattle.moduleOrder` everywhere, so `pairs()` cannot reshuffle initialisation or alert order between sessions
- `Config:GetSlider` - a method that used no state - is the plain function `AddSlider`; the row rhythm the shared controls assume is published as `Config.CHECKBOX_ROW` / `Config.DROPDOWN_ROW` so a module laying out its own tab extras steps by the same amount; `Modules/Silencer.lua` measures its wrapped notes with `GetStringHeight` instead of guessing row counts
- **Alerts stopped paying twice for the same words.** The grab spells built a `TargetPhrase` for the alert and then built it again one line later for a debug line that usually prints nothing. Every Swapblaster alert for one cast now uses the silencer list recorded when that cast started - the "cut short" alert was sweeping the group again in the same breath. And `(Neural Silencer worn by %s)` was written out in two files; the core exports the list-taking form (`Tattle.SilencerNoteList`) and the token-taking form is a call to it, so the two halves of the addon cannot word the same fact differently

- **Dead code removed**: `Config:RegisterModuleTab` and the per-module `buildContent` hook (no module ever supplied one, so tabs were built by one function through an indirection), `ScreenAlert:RegisterEditMode` (never called - and `FEATURES.md` was telling people it existed), the `Tattle.WatchedSpellNames` mutable export, `Tattle.IsInRaidGroup` / `Tattle.IsRaidMemberToken` aliases, `Silencer.GetWatchedSpellIDs`, `module.buildContent` in the registration shape
- Every addon file now opens with `local _, Tattle = ...` and receives the namespace table the core created, so the only globals the addon leaves in the client are `TattleDB` and the slash command entry

### Notes
- **The stub now models a raid the way the client numbers one**: you hold a raid index, `GetNumGroupMembers()` counts you, and an aura on you is readable through either of your tokens. That is what made the double-count fix testable - with the self-exclusion removed from `GroupUnitTokens`, five checks fail, one of which reads `it failed because you and you are using a Neural Silencer`
- **The stub's `UnitIsUnit` now resolves `<unit>target` tokens** to whoever they point at, and treats your raid index and `player` as the same person on either side of the question. Comparing them as strings, which it did, let it agree that `raid1target` was "not raid3" and "was player" in the same breath - the same mistake the addon was making
- **Checks went from 97 to 117.** New coverage: the unit-token list and the watcher sweep's own entry, protected-person naming, Rescue's self-mark, late module registration, the `allCasters` opt-out (which had none), Swapblaster victim naming in both directions (a readable target names the player, an unreadable or non-player target names nobody), `at you` / `on you`, a backfire that names the immune player behind it, that a target lookup spends one `UnitExists` before it is allowed to spend any `UnitIsUnit`, that a target who is you resolves to `player` rather than to your raid index, and that a second swap from one caster is not muted by the first one's record while the two halves of a single cast are still announced once
- **The harness now fails when a widget setter is handed `nil`** where the client demands a number. It previously shrugged at `panel:SetSize(700, nil)` - an error on a real client - because its setters type-checked and dropped what they did not understand
- `README.md` gained the file layout and what each file is for; `PROJECT_SUMMARY.md`, `FEATURES.md` and the config panel's own About text no longer describe the pre-review addon

## [0.2.0-alpha.2] - 2026-11-04

### Changed
- **Supported interface is now 12.1.x: `## Interface: 120107, 120105`** (12.1.7 and 12.1.5). The 12.0 line is dropped, matching the other addon in this family; a client still on 12.0.x will list Tattle as out of date rather than load an unsupported build
- **No Lua changed.** Everything the addon touches is stable across the 12.0 to 12.1 point releases: `UNIT_SPELLCAST_*` / `UNIT_AURA` / `UNIT_TARGET` events, `C_Spell.GetSpellName` and `C_Spell.GetSpellInfo`, `C_UnitAuras.GetAuraDataBySpellName`, `UnitCastingInfo` / `UnitChannelInfo`, the group and membership queries, `C_Timer`, `PlaySound`, `SendChatMessage`, the widget API, `C_AddOns.GetAddOnMetadata` and the two `Settings.Register*Category` calls. Nothing version-gated, and no `GetBuildInfo` branch anywhere in the addon - so this is a compatibility declaration, not a port

### Notes
- **Why a version bump for one TOC line.** CurseForge takes a file's supported game versions from `## Interface` at upload time; the alpha.1 file is filed under 12.0.1 and 12.0.0 and cannot be relabelled. A new file is the only way a 12.1 player sees a supported version, and the packager reads the version from the tag, so the tag is how the metadata moves
- Also in this build, from commits after the alpha.1 tag: the `## License` section and corrected requirement in `README.md`, the license line in `DESCRIPTION.md` and `CURSEFORGE.md`, and the devlog's account of how the CurseForge upload came to work

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
