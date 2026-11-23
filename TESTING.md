# Testing Guide for Tattle

## Installation for Testing

The addon folder must be named `Tattle` (it has to match `Tattle.toc`).

Windows, symlink the project into the AddOns folder so edits apply without re-copying:

```powershell
mklink /J "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\Tattle" "C:\Users\jon\iCloudDrive\projects\tattle"
```

Or copy it:

```powershell
xcopy /E /I "C:\Users\jon\iCloudDrive\projects\tattle" "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\Tattle"
```

macOS/Linux:

```bash
ln -s ~/projects/tattle ~/.wine/drive_c/Program\ Files/World\ of\ Warcraft/_retail_/Interface/AddOns/Tattle
```

Launch WoW and log in to a character, then verify the addon loaded:

```
/tattle version
```

## Run the probe first

Before testing anything else, see what your client actually exposes:

```
/tattle debug
/tattle probe
```

Then use each ability on **yourself** and on **a friend**. The probe prints, for every cast event it sees (at most once a second for the group context lines, and **nothing at all while you are solo** - none of this can happen without a group):

- the spell name (resolved through `C_Spell.GetSpellInfo`, so it works even when the ID is a secret value)
- the whole event payload, argument by argument, so a claim about what your client exposes can be checked against what it actually sent
- whether the caster argument can be named, and whether it is you
- whether the destination is exposed - and `UNIT_SPELLCAST_SENT` is read by its own layout, where the destination is **argument 2** and the spell ID is **argument 4**. An earlier revision of the probe looked for the spell in argument 3 and hunted the destination in arguments 4-6, and printed `none exposed` about payloads that carried both, so anything it told you about target visibility was a statement about its own indexing
- which group auras are currently visible
- the group's Neural Silencer wearers
- what each group member's target token resolves to, and who is targeting you
- what the sanctioned cast-target APIs answer for a watched cast (`PlayerIsSpellTarget` / `UnitShouldDisplaySpellTargetName` / `UnitSpellTargetName`), reported as *absent*, *refused*, *no answer*, *secret*, *yes* or *no* rather than as a boolean, because an alert has to behave differently in each of those
- `UnitPosition` samples taken at the start, middle and end of a watched channeled cast: how far the group drifted before the swap resolved, whether exactly one member ended up where the caster began, and whether the caster's own target read **agrees** with the member who actually changed places. A disagreement is printed in full and nobody is picked between
- on arming, a capability report for the build you are on: which target APIs exist, which secret predicates answer, whether `restrictRelativeTargetUnits` is even a setting, which add-on restrictions are active, whether chat messaging is locked down, and the per-spell secrecy answers for Neural Silencer (`156779`) and the swap (`161399`)

The aura line is the important one: "on Donut" in a Life Grip or Rescue alert only works if another player's aura is readable on your client. "none visible" means those alerts fall back to `(target unknown)`.

The target lines decide whether the watch list's "Targeting you" section can work at all. If nobody in the group shows a target even when you can see their target frame in the world, your client is not being told - that section will stay empty and nothing is broken.

## Testing Checklist

### Basic Functionality

- [ ] Addon loads without errors
- [ ] `/tattle` opens configuration panel
- [ ] Configuration panel displays correctly
- [ ] All settings can be toggled on/off

### What 0.2.0-beta.2 is asking your client to confirm

These are the things the harness cannot settle, because they are questions about what a
12.1.5 / 12.1.7 client will tell an addon. `/tattle probe` output from a raid or a key is the
most useful single thing you can send back.

- [ ] **A completed Swapblaster is no longer described as "cut short".** The client returns cast and channel start/end times in milliseconds; beta.1 subtracted them as if they were seconds, so *every* finished swap took the "cut short" wording. If you saw that, it should be gone - and if it is still there, `/tattle probe` now prints the raw pair plus both readings, which settles it in one line
- [ ] **A swap's victim.** With both people in the group, fire a swap at one while your target frame shows the other (a `@mouseover` macro is the honest way to arrange this). The completion should name the member the spell actually moved; if it says `- aiming at <whoever your frame showed>`, the target APIs stayed secret on your client and that is the correct fallback - say so, because it tells us whether `UnitSpellTargetName` answers for other players' casts at all
- [ ] **A Neural Silencer list inside a key.** Take the group's protected member into a Mythic+ key and look at the watch list. It should say `Unknown (+N hidden by the client)`, not `nobody`. "nobody" over a refused read is the failure this item exists to catch
- [ ] **Chat in restricted content.** With Chat Messages on for a module, in a raid or key where addon chat is locked down: nothing should be spammed at the channel, no error bag, and the **screen warning should still fire**
- [ ] **Chat never carries a hidden name.** If an alert's target name arrived as a secret value, the alert may appear on your screen and console; it must not appear in `/say`, `/party` or `/raid`

### Module Testing

The shipped spell IDs are verified against the live 12.1.5 database, so no ID hunting is needed to start:

| Module | Spell ID | In-game spell name | Cast |
| --- | --- | --- | --- |
| Swapblaster | `161399` | **Swap** (from item 111820) | 1.5 sec, channeled |
| Life Grip | `73325` | **Leap of Faith** | instant |
| Rescue | `370666` | **Rescue** | instant |

If `/tattle debug` prints `WARNING: spell ID ... not found`, or the probe shows a different name, enter the correct ID in that module tab's spell ID editor and `/reload`.

**Test Cases:**

1. **Solo Testing (should NOT trigger)**
   - [ ] Use Swapblaster while not in a group
   - [ ] Verify no alerts appear (addon only works in groups)

2. **Swapblaster (grouped, out of combat)**
   - [ ] Have someone start a Swapblaster cast
   - [ ] Verify the "is casting Swapblaster" alert fires *during* the 1.5 seconds
   - [ ] Verify a second alert when it completes
   - [ ] Cancel the cast mid-channel and verify "was cut short" rather than "used Swapblaster"
   - [ ] Verify only one alert per phase even if the client sends both `START` and `CHANNEL_START`

3. **Life Grip (grouped, out of combat)**
   - [ ] Have a Priest Leap of Faith you
   - [ ] Verify `... used Life Grip on you!`
   - [ ] Have them grip someone else and verify that person is named
   - [ ] Verify nothing fires for an in-combat grip (that is a legitimate heal)

4. **Rescue (grouped, out of combat)**
   - [ ] Have an Evoker Rescue you
   - [ ] Verify `... used Rescue on you!`
   - [ ] Have them carry someone else and verify the passenger is named, not the Evoker

5. **Combat behaviour**
   - [ ] In combat, have someone start a Swapblaster cast: verify nothing is evaluated (with `/tattle debug` you should see `Skipping swapblaster - caster is in combat`)
   - [ ] Out of combat, start a swap that lands somewhere that pulls combat: verify the completion alert still fires
   - [ ] Verify an in-combat Life Grip is still ignored *by that module's own rule*, and that an out-of-combat one from the same caster alerts

6. **Neural Silencer (protected players)**
   - [ ] Have a group member wear a Neural Silencer, have someone else **target them**, then Leap of Faith them
   - [ ] Verify `... attempted a Life Grip on Donut, but it failed because Donut is using a Neural Silencer` rather than `(target unknown)`
   - [ ] Repeat with Rescue
   - [ ] Repeat against yourself and verify the wording becomes `on you, ... you are using a Neural Silencer`
   - [ ] Now do the same with the caster targeting **nobody** (or somebody unprotected): expect `... used Life Grip (target unknown)!` with no mention of a Neural Silencer at all. Naming the raid's protected member from "the aura never appeared" is the behaviour removed in this pass
   - [ ] Fire a Swapblaster at a *protected* player and verify `(Pancakes is using a Neural Silencer)` appears on that swap's alerts; fire one at somebody else with the same protected player standing in the group and verify the alerts say nothing about protection
   - [ ] Swapblaster a protected player and verify the backfire is reported as a blocked attempt, once - this is the one alert that may name a lone protected member without a target read, and with two of them it should say `on a protected group member` instead of picking
   - [ ] Have the *protected* player fire a Swapblaster at someone else, out of combat, and verify `... but Pancakes is using a Neural Silencer - that's not fair!`
   - [ ] Verify an unprotected caster gets the plain completion line with no accusation

7. **Watch list** (`/tattle` -> Silencers tab) - note that this module is display-only: no chat output of its own, ever
   - [ ] Tick "Show the watch list on screen" and verify the list appears without a `/reload`, naming the protected members
   - [ ] Tick "List group members targeting you" and verify whoever targets you appears (if the probe's target lines are empty for your client, this cannot work - check there first)
   - [ ] Click "Reposition List", drag it, click "Done Repositioning", `/reload` and verify it stayed where you put it
   - [ ] Have someone put up a Neural Silencer and verify **nothing is announced** - the list updates, chat stays quiet
   - [ ] Disband and reform the group (or join a fresh raid) and verify the room full of protected people is *not* announced name by name
   - [ ] Leave the group and verify the list disappears; return and verify it comes back
   - [ ] Untick the option and verify the list is gone and its timer stopped
   - [ ] `/tattle status` and verify the `Watch list:` line reflects what you set

8. **Chat channels**
   - [ ] Set a module's chat type to `Raid`, join a normal raid, trigger an alert and verify it appears in raid chat
   - [ ] Join a **Looking for Raid** group (or a premade/flex raid), trigger the same alert and verify it still appears - this is the bug fixed in this release
   - [ ] Set chat type to `Raid` while in a 5-man party and verify `/tattle status` reports it will be sent on `PARTY`

9. **Target Detection limits**
   - [ ] Have a friend **target you** and fire a Swapblaster: expect `Donut is casting Swapblaster at you`, then `Donut used Swapblaster on you`
   - [ ] Repeat with that friend targeting somebody else, then with nothing targeted: the alert should name the other player, then name nobody
   - [ ] If nobody is ever named, read the probe's target lines - some clients are not told other players' targets, and the alert is then correct to stay quiet about the victim
   - [ ] If Life Grip or Rescue reports `(target unknown)`, check the probe's aura line for your client

### Alert Testing

Configure different alert methods and verify each works:

1. **Console Output** (this is the debugging line - it is on whenever `/tattle debug` is on)
   - [ ] With `/tattle debug` **off** and no module's Console output ticked, trigger an event and verify **nothing** is printed to your chat window
   - [ ] `/tattle debug` on, trigger an event and verify every module's alert prints (plus the `[Tattle Debug]` lines)
   - [ ] Debug off, tick one module's Console output and verify that module prints and the others do not

2. **Chat Message**
   - [ ] Enable chat message alert (the chat type defaults to `/say`, so it should appear without touching the dropdown)
   - [ ] Set to /party
   - [ ] Trigger an event
   - [ ] Verify message sent to party chat
   - [ ] Set the chat type to `None (no chat message)` and verify nothing is sent anywhere (this option used to be labelled "console only" and looked like it was doing something)

3. **Audio Alert**
   - [ ] Enable audio alert
   - [ ] Select a sound (e.g., "Raid Warning")
   - [ ] Click "Test" button to verify sound works
   - [ ] Trigger an event
   - [ ] Verify sound plays
   - [ ] Trigger one Swapblaster that starts and then lands (or fails): verify **one** sound, not one per line of chat. Trigger a Life Grip, which has no start: verify its landing still makes the noise

4. **Screen Warning** (on by default, and the alert a new install actually sees)
   - [ ] Trigger an event and verify a raid-warning style message appears on screen, then disappears after *Display duration*
   - [ ] If it never appears, look at that module's own tab: the Screen Alerts tab only controls **appearance** and has no master on/off. The tick named "Screen warning" lives on the Swapblaster / Life Grip / Rescue tab
   - [ ] Reposition it from the Screen Alerts tab and trigger another event: the drag preview always shows the frame, so use a real alert - not the preview - to decide whether screen alerts are switched on

### Configuration Testing

- [ ] Disable addon globally, verify no alerts trigger
- [ ] Disable Swapblaster module, verify no Swapblaster alerts
- [ ] Test each combination of alert types
- [ ] Close and reopen config panel, verify settings persist
- [ ] `/reload`, verify settings persist across reloads

### Error Handling

- [ ] Test with invalid spell ID (should not crash)
- [ ] Test with nil values (addon should handle gracefully)
- [ ] Check for any Lua errors in the default UI error window
- [ ] `/tattle status` after a run: anything the addon swallowed is listed there, with a count ("Problems this session")

## Debug Mode

Enable debug mode to see detailed information:

```
/tattle debug
```

Debug output shows:
- When events are processed
- Why alerts are blocked (if disabled, not in group, etc.)
- Swapblaster cast tracking
- Spell ID verification on module load

## Automated Harness

`lua5.1 Tests/wow_stub.lua` (exit 0 = pass) loads the addon in TOC order against a stub client and asserts the behaviour that has broken before: alert routing, instant casts, channeled casts, scope gating, chat channel resolution (including LFR), the combat gates, the Neural Silencer call-outs, the watch list, the config tabs and the spell ID editor. The checks are numbered in a comment block near the top of the file.

Since 0.2.0-beta.1 it also asserts the two things that went wrong in the alphas:

- **One cast, one alert.** The two event halves of a swap - including the plain half and the channeled half arriving with *different* cast GUIDs - and the same cast reported once as your `raidN` index and once as `player`, must each produce one alert. And neither a record that never terminated nor a settled tombstone may mute that caster's next cast.
- **Restricted content.** With the spell ID, the cast GUID and the caster token all modelled as secret values, a swap is still announced, is never given a name the client refused to give, and touches nothing the client forbids (the stub counts every refusal it was asked to make). On a stub build with no `C_SecretComparisons`, the refusal to classify a cast is announced once and counted, rather than answered as "not a cast we watch" - and a secret cast of a spell Tattle does *not* watch is neither announced nor reported, because "the client answered no" and "the client would not answer" are different answers.
- **Idle while you fight.** While this player is fighting nothing is announced, by any module, and no spell name is resolved to decide it; the same cast alerts once `PLAYER_REGEN_ENABLED` has fired. `/tattle status` says which of the two states the addon believes it is in, the `/tattle probe` is the one deliberate exception (it is the instrument for asking about combat), and `/tattle off` disarms the probe with everything else.
- **A module that throws while initializing does not take the addon down.** The harness registers a module that refuses to initialize before `ADDON_LOADED`, and asserts that the failure is reported, that the module registered behind it still initializes, and that the load banner still prints.

Five audits run alongside the checks. Two are about the stub (widget keys it does not model are printed at the end - a new one is usually a typo - and a widget setter handed `nil` where the client demands a number is a failure). Three are about the source: nothing that came from the client may be compared with an empty string (the line that crashed alpha.3, which a Lua 5.1 harness cannot make to raise, so it is caught in the text instead), no module or command calls a raw client value-API where the core has an accessor for it, and every module asks for an `outOfCombat` policy the core actually implements. Two more check the code against the Lua the game ships rather than the Lua your shell has, and one states how faithfully this file's fake secret values model a real client on the interpreter running it (`__len` on a table does not exist before Lua 5.2, so on CI's `lua5.1` a fake secret answers `#` instead of refusing).

Each of the source audits also asserts that it *opened the files it polices*, and the file list for the Lua audit comes from the TOC rather than from a hand-written list. Both of those exist because of a real false green found in review: the client-API audit selected its files with `file:find("^Modules/", 1, true)`, and with plain-find enabled the second argument is a start index, not a pattern - so it searched source lines for the nine literal characters `^Modules/`, found none, and reported clean for the three modules it exists to police. An audit that read no file is now a failure rather than a pass.

## Known Limitations

1. **Swapblaster's other half is a target read, not a signature**: the swap applies no aura to either participant, and 12.0.0 removed `COMBAT_LOG_EVENT_UNFILTERED`, which was the only API that carried a destination. The module reads `<caster>target` at the moment the cast starts, so the victim is named on a client that syncs group targets and left unmentioned - never guessed - on one that does not
2. **Aura-dependent attribution**: Life Grip and Rescue can only be attributed while group auras are readable. 12.1.0 relaxed this out of combat; inside instances it can still be refused
3. **Group Only**: alerts only work when in a party or raid group, which is also the only way these abilities can be used
4. **Tattle is silent while you are fighting**: no module runs, no alert is sent, nothing is asked of the client. `/tattle status` says `In combat: YES - Tattle is silent while you fight` so the silence is explainable. Everything this addon watches is an out-of-combat act (the toy says "Cannot be used in combat" on its own tooltip), and a separate rule asks about the *caster*: a group member who is fighting is not griefing anybody, which is why Life Grip and Rescue are ignored in combat even when you are not
5. **Restricted content**: inside M+ and rated PvP the spell ID, the cast GUID and the caster token all arrive as secret values that cannot be printed, concatenated, indexed or compared against a literal. Tattle identifies a cast by its name, through the client's own comparison API where the build has one. Where it does not, Tattle says that it was not allowed to classify the cast rather than reporting nothing
6. **Other players' targets are not guaranteed**: "Targeting you" reads `<member>target` tokens, which a client may not be told about. An empty list means "none we can read", never "nobody is looking at you"
7. **A blocked grab has to be inferred**: when a swap, grip or rescue is refused there is no victim aura to read, so the named victim is the group's only protected member. With more than one, the alert refuses to guess
8. **One cast is recognised by the record it left, not by the identity the client attached to the event**: the plain half and the channeled half of one swap carry different GUIDs, and a restricted client will not compare them. A second attempt at the same spell is told apart by which event family its start arrived as (one cast sends at most one plain start and one channeled start), so a refused swap followed by a real one two seconds later is announced as the two casts they were. What cannot be told apart is a second attempt whose first event happens to arrive as the *other* family - the late half of the first cast and the start of the next one look identical in the event stream - and there Tattle stays quiet rather than announce one swap twice. A record stops claiming to describe anything after eight seconds, so nothing can mute a caster permanently
9. **A caster the client will not name is called "someone"**: an alert never prints a name this client would not have printed itself

## Troubleshooting

### No alerts appearing

1. Check: `/tattle status`
   - Verify addon is enabled
   - Verify Swapblaster module is enabled
   - Verify you're in a group
   - Verify `In combat:` says `NO` - the addon announces nothing while you are fighting, by design
   - Verify at least one alert type is enabled

2. Enable debug mode: `/tattle debug`
   - Watch for messages explaining why alerts are blocked

3. Look at what the addon was told to keep quiet about:
   - `/tattle status` prints "Problems this session" with a count for each kind
   - A module that threw on a cast event, and a cast the client would not let Tattle
     classify, both land there. The first of each kind is printed in chat when it
     happens; the count is how you notice it afterwards
   - In M+ and rated PvP the client hands cast events as secret values. If this build
     has no `C_SecretComparisons`, Tattle cannot tell you whether a cast was one it
     watches, and it says so rather than going quiet

4. Verify spell IDs:
   - `/tattle probe`, then use the ability
   - Compare the spell name the probe prints against the module's expected name
   - In restricted content the probe prints `table (fields not readable)` instead of a
     name, because the client would not print one either
   - Enter the correct ID in that module's spell ID editor and `/reload`

### Configuration not saving

- Check for Lua errors
- Verify `TattleDB` is listed in SavedVariables in the .toc
- Try `/reload` to ensure settings are written to disk

### Addon not loading

- Check AddOns list at character select
- Look for Lua errors on login
- Verify all files are in the correct location
- Check .toc file format (no syntax errors)

## Future Module Testing

When adding new modules:

1. Add module file to `Modules/`
2. Update `Tattle.toc` to include the new file
3. Test module independently
4. Verify it integrates with alert system
5. Test enable/disable functionality
6. Document the module's behavior

## Reporting Issues

When reporting issues, include:
- WoW version
- Addon version (`/tattle version`)
- Steps to reproduce
- Expected vs actual behavior
- Debug output if relevant (`/tattle debug`)
- Any Lua errors
