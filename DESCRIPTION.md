# Tattle

**A WoW addon that announces the mid-raid murders nobody reports.**

Some group members treat a raid as an open season on their own team. A
Swapblaster shuffles you into a boss ability, a Life Grip drags you out of a
safe spot, a Rescue yanks you off a platform you were standing on. None of
those hits show up in your combat log. Tattle puts them in chat, out loud, and
names who did it.

## What it watches

| Ability | What Tattle tells you |
| --- | --- |
| Swapblaster (the toy, spell `Swap`) | That a group member fired one, who fired it, and whether it hit you |
| Life Grip / Leap of Faith | Who gripped whom, and whether you were the one who got dragged |
| Rescue | Who rescued whom |
| Neural Silencer | Which group members are wearing the immunity that makes all of the above legal |

It only reports **group members**. Solo, nothing happens - none of these tricks
work on your own group when there is no group. Pets, minions, totems and NPCs
are rejected as casters, because none of these spells come from them.

## What an alert looks like

```text
[Tattle] Swapblaster fired by Pancakes - you are the one who got flung
[Tattle] Donut attempted a Life Grip on you.
[Tattle] Pancakes attempted a Life Grip on Donut, but it failed because Donut is using a Neural Silencer.
[Tattle] Pancakes used Swapblaster, but Pancakes is using a Neural Silencer - that's not fair!
```

Every module can send to **console**, **chat** (`Say`, `Yell`, `Party`, `Raid`,
`Instance`), an **audio alert**, and an **on-screen alert**, independently, and
each module has its own switch. `Raid` is delivered correctly in Looking-for-Raid
groups, where a plain raid chat send is silently dropped by the game.

## What it will never tell you

It does not guess. Swapblaster leaves no signature on the person who was moved,
so Tattle reports the cast with confidence and never names a victim it cannot
prove. Life Grip and Rescue mark their destination with an aura, so those it can
attribute exactly. A failure caused by a Neural Silencer is reported as
"attempted", because the proof is that nothing landed, not that something did.

## Neural Silencers

Wearing one blocks Swapblaster and Leap of Faith. Tattle does **not** announce
who is wearing one - putting a buff on is not an event, and joining a raid should
not read out a list of protected players. Wearers appear where they matter: in
the alerts above, and optionally in an opt-in on-screen watch list you position
yourself, which can also show which group members currently have you targeted.

## Performance

No `OnUpdate` anywhere. Spell names are resolved once per cast event, casts the
addon does not care about are dropped before any module is woken, group token
lists are cached, and the watch list only re-lays itself out when its text
actually changes. The config panel is built when you first open it, not at login.

## Using it

```text
/tattle            Open the config panel
/tattle status     Current state, including which chat channel alerts would use
/tattle probe      Watch raw cast events - run this before filing a bug report
/tattle on | off   Master switch
/tattle debug      Internal decisions to the console
/tattle version    Version
```

No keybinds are registered, so nothing you already bound is affected.

## Version 12.x

Tattle works in 12.x with 12.x rules, which are narrower than the addon's own
history: the Swapblaster is limited to the War Within, and War Within spells are
not castable in Midnight zones, so a swap or a grip between expansions is not
possible at all. Rescue (Priest) and Leap of Faith (Monk) are cross-expansion,
but are not War Within spells, so they cannot cross the boundary either.

## Details

- Slash command: `/tattle` (only)
- Saved variables: `TattleDB`
- Dependencies: none
- Tests: a stub WoW client harness, `Tests/wow_stub.lua`, 97 checks
- License: not yet chosen
