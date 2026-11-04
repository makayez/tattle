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
- whether the caster argument can be named, and whether it is you
- whether any destination argument is exposed at all
- which group auras are currently visible
- the group's Neural Silencer wearers
- what each group member's target token resolves to, and who is targeting you

The aura line is the important one: "on Donut" in a Life Grip or Rescue alert only works if another player's aura is readable on your client. "none visible" means those alerts fall back to `(target unknown)`.

The target lines decide whether the watch list's "Targeting you" section can work at all. If nobody in the group shows a target even when you can see their target frame in the world, your client is not being told - that section will stay empty and nothing is broken.

## Testing Checklist

### Basic Functionality

- [ ] Addon loads without errors
- [ ] `/tattle` opens configuration panel
- [ ] Configuration panel displays correctly
- [ ] All settings can be toggled on/off

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
   - [ ] Have a group member wear a Neural Silencer, then have someone else Leap of Faith them
   - [ ] Verify `... attempted a Life Grip on Donut, but it failed because Donut is using a Neural Silencer` rather than `(target unknown)`
   - [ ] Repeat with Rescue
   - [ ] Repeat against yourself and verify the wording becomes `on you, ... you are using a Neural Silencer`
   - [ ] Put a second person behind a silencer and verify the alert says `on a protected group member` instead of naming one of them
   - [ ] Swapblaster a protected player and verify the backfire is reported as a blocked attempt, once
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
   - [ ] Confirm Swapblaster reports no victim - expected, the spell marks nobody
   - [ ] If Life Grip or Rescue reports `(target unknown)`, check the probe's aura line for your client

### Alert Testing

Configure different alert methods and verify each works:

1. **Console Output**
   - [ ] Enable console output only
   - [ ] Trigger an event
   - [ ] Verify message appears in chat window

2. **Chat Message**
   - [ ] Enable chat message alert
   - [ ] Set to /party
   - [ ] Trigger an event
   - [ ] Verify message sent to party chat

3. **Audio Alert**
   - [ ] Enable audio alert
   - [ ] Select a sound (e.g., "Raid Warning")
   - [ ] Click "Test" button to verify sound works
   - [ ] Trigger an event
   - [ ] Verify sound plays

4. **Screen Warning**
   - [ ] Enable screen warning
   - [ ] Trigger an event
   - [ ] Verify raid-warning style message appears on screen

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

`lua5.1 Tests/wow_stub.lua` (exit 0 = pass) loads the addon in TOC order against a stub client and asserts the behaviour that has broken before: alert routing, instant casts, channeled casts, scope gating, chat channel resolution (including LFR), the combat gate, the Neural Silencer call-outs, the watch list, the config tabs and the spell ID editor. The checks are numbered in a comment block near the top of the file. Widget keys the stub does not model are printed at the end as a "proxied" audit - a new key there is usually a typo, not a missing stub.

## Known Limitations

1. **No victim for Swapblaster**: the swap applies no aura to either participant, and 12.0.0 removed `COMBAT_LOG_EVENT_UNFILTERED`, which was the only API that carried a destination. Swapblaster alerts name the caster only
2. **Aura-dependent attribution**: Life Grip and Rescue can only be attributed while group auras are readable. 12.1.0 relaxed this out of combat; inside instances it can still be refused
3. **Group Only**: alerts only work when in a party or raid group, which is also the only way these abilities can be used
4. **In-combat use is ignored** for Life Grip and Rescue, where pulling someone is a legitimate save
5. **Secret spell IDs**: inside restricted content the ID cannot be compared directly, so a spell whose *name* changes would need its ID re-entered
6. **Other players' targets are not guaranteed**: "Targeting you" reads `<member>target` tokens, which a client may not be told about. An empty list means "none we can read", never "nobody is looking at you"
7. **A blocked grab has to be inferred**: when a swap, grip or rescue is refused there is no victim aura to read, so the named victim is the group's only protected member. With more than one, the alert refuses to guess

## Troubleshooting

### No alerts appearing

1. Check: `/tattle status`
   - Verify addon is enabled
   - Verify Swapblaster module is enabled
   - Verify you're in a group
   - Verify at least one alert type is enabled

2. Enable debug mode: `/tattle debug`
   - Watch for messages explaining why alerts are blocked

3. Verify spell IDs:
   - `/tattle probe`, then use the ability
   - Compare the spell name the probe prints against the module's expected name
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
