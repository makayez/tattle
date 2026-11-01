# Testing Guide for Snitch

## Installation for Testing

The addon folder must be named `Snitch` (it has to match `Snitch.toc`).

Windows, symlink the project into the AddOns folder so edits apply without re-copying:

```powershell
mklink /J "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\Snitch" "C:\Users\jon\iCloudDrive\projects\snitch"
```

Or copy it:

```powershell
xcopy /E /I "C:\Users\jon\iCloudDrive\projects\snitch" "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\Snitch"
```

macOS/Linux:

```bash
ln -s ~/projects/snitch ~/.wine/drive_c/Program\ Files/World\ of\ Warcraft/_retail_/Interface/AddOns/Snitch
```

Launch WoW and log in to a character, then verify the addon loaded:

```
/snitch version
```

## Run the probe first

Before testing anything else, see what your client actually exposes:

```
/snitch debug
/snitch probe
```

Then use each ability on **yourself** and on **a friend**. The probe prints, for every cast event it sees:

- the spell name (resolved through `C_Spell.GetSpellInfo`, so it works even when the ID is a secret value)
- whether the caster argument can be named, and whether it is you
- whether any destination argument is exposed at all
- which group auras are currently visible

That last line is the important one: "on Donut" in a Life Grip or Rescue alert only works if another player's aura is readable on your client. "none visible" means those alerts fall back to `(target unknown)`.

## Testing Checklist

### Basic Functionality

- [ ] Addon loads without errors
- [ ] `/snitch` opens configuration panel
- [ ] Configuration panel displays correctly
- [ ] All settings can be toggled on/off

### Module Testing

The shipped spell IDs are verified against the live 12.1.5 database, so no ID hunting is needed to start:

| Module | Spell ID | In-game spell name | Cast |
| --- | --- | --- | --- |
| SwapBlaster | `161399` | **Swap** (from item 111820) | 1.5 sec, channeled |
| Life Grip | `73325` | **Leap of Faith** | instant |
| Rescue | `370666` | **Rescue** | instant |

If `/snitch debug` prints `WARNING: spell ID ... not found`, or the probe shows a different name, enter the correct ID in that module tab's spell ID editor and `/reload`.

**Test Cases:**

1. **Solo Testing (should NOT trigger)**
   - [ ] Use SwapBlaster while not in a group
   - [ ] Verify no alerts appear (addon only works in groups)

2. **SwapBlaster (grouped, out of combat)**
   - [ ] Have someone start a Swapblaster cast
   - [ ] Verify the "is casting SwapBlaster" alert fires *during* the 1.5 seconds
   - [ ] Verify a second alert when it completes
   - [ ] Cancel the cast mid-channel and verify "was cut short" rather than "used SwapBlaster"
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

5. **Target Detection limits**
   - [ ] Confirm SwapBlaster reports no victim - expected, the spell marks nobody
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
- [ ] Disable SwapBlaster module, verify no SwapBlaster alerts
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
/snitch debug
```

Debug output shows:
- When events are processed
- Why alerts are blocked (if disabled, not in group, etc.)
- SwapBlaster cast tracking
- Spell ID verification on module load

## Known Limitations

1. **No victim for SwapBlaster**: the swap applies no aura to either participant, and 12.0.0 removed `COMBAT_LOG_EVENT_UNFILTERED`, which was the only API that carried a destination. SwapBlaster alerts name the caster only
2. **Aura-dependent attribution**: Life Grip and Rescue can only be attributed while group auras are readable. 12.1.0 relaxed this out of combat; inside instances it can still be refused
3. **Group Only**: alerts only work when in a party or raid group, which is also the only way these abilities can be used
4. **In-combat use is ignored** for Life Grip and Rescue, where pulling someone is a legitimate save
5. **Secret spell IDs**: inside restricted content the ID cannot be compared directly, so a spell whose *name* changes would need its ID re-entered

## Troubleshooting

### No alerts appearing

1. Check: `/snitch status`
   - Verify addon is enabled
   - Verify SwapBlaster module is enabled
   - Verify you're in a group
   - Verify at least one alert type is enabled

2. Enable debug mode: `/snitch debug`
   - Watch for messages explaining why alerts are blocked

3. Verify spell IDs:
   - `/snitch probe`, then use the ability
   - Compare the spell name the probe prints against the module's expected name
   - Enter the correct ID in that module's spell ID editor and `/reload`

### Configuration not saving

- Check for Lua errors
- Verify `SnitchDB` is listed in SavedVariables in the .toc
- Try `/reload` to ensure settings are written to disk

### Addon not loading

- Check AddOns list at character select
- Look for Lua errors on login
- Verify all files are in the correct location
- Check .toc file format (no syntax errors)

## Future Module Testing

When adding new modules:

1. Add module file to `Modules/`
2. Update `Snitch.toc` to include the new file
3. Test module independently
4. Verify it integrates with alert system
5. Test enable/disable functionality
6. Document the module's behavior

## Reporting Issues

When reporting issues, include:
- WoW version
- Addon version (`/snitch version`)
- Steps to reproduce
- Expected vs actual behavior
- Debug output if relevant (`/snitch debug`)
- Any Lua errors
