<!--
Source of the CurseForge project page. Paste the Markdown below into CurseForge's
description editor (Markdown mode).

Project: CurseForge project 1782380, slug "tattle", game: WoW Retail.
Fill before publishing:

  * Summary field -> the one-liner below the H1, trimmed to 255 chars
  * Project icon  -> upload Tools/tattle-turtle-512.png
  * Category      -> Utility / User Interface, Damage Reduction (minor field)
  * License field -> pick one in the project settings until a LICENSE file exists

The project is not public until the first file is approved by moderation, so the
public link below is written for the page once it is live.
-->

# Tattle

**Tattle announces in chat when someone in your group Swapblasts, Life Grips or Rescues you while you're walking through your raid — and flags who's wearing a Neural Silencer to get away with it.**

<!-- Optionally drop a screenshot/gif of the config panel and an on-screen alert here. -->

Nobody is supposed to know who knocked you into the trash. Movement toys and out-of-combat grabs leave nothing in the chat window, and since `COMBAT_LOG_EVENT_UNFILTERED` was removed from retail there is no longer even a log to sift through. Tattle puts the name back in: **who** moved you, **with what**, and whether they were already immune to the thing they tried.

It watches four things, alerts on three of them, and stays quiet on the fourth on purpose.

---

## Table of contents

- [What it watches](#what-it-watches)
- [What the alerts look like](#what-the-alerts-look-like)
- [Neural Silencers, the fun module](#neural-silencers-the-fun-module)
- [What Tattle will never tell you](#what-tattle-will-never-tell-you)
- [Configuration](#configuration)
- [Commands](#commands)
- [Chat channels, including LFR](#chat-channels-including-lfr)
- ["Does this cost frames?"](#does-this-cost-frames)
- [How it works under the 12.x restrictions](#how-it-works-under-the-12x-restrictions)
- [Compatibility](#compatibility)
- [FAQ](#faq)

---

## What it watches

| Module | Spell | Out of combat | Who gets named |
|---|---|---|---|
| **Swapblaster** | `161399` — the game names the cast *"Swap"*, from the item *Swapblaster* (111820) | yes | the caster only |
| **Life Grip** | `73325` — the game names it *Leap of Faith* (Priest) | yes | caster **and** the player pulled |
| **Rescue** | `370666` (Evoker) | yes | caster **and** the passenger |
| **Neural Silencer** | auras `156779` / `384129` (*"Immune to some annoyances"*, 12 hours) | n/a | whoever is wearing one, if you switch the list on |

**Swapblaster** reports the 1.5 second cast when it starts (so you can turn around), when it lands, and when it was **cut short, failed or interrupted**. A swap marks nobody with an aura, so Tattle will not pretend to know who was swapped — it names the caster, which is the half you can act on.

**Life Grip** and **Rescue** name their victim by reading the short aura the grab leaves on the player who was moved. That aura is the only destination information the 12.x API still exposes, and it is why these two can say *"on Donut"* while Swapblaster cannot.

**All three ignore casts made in combat.** A Life Grip or a Rescue during a fight is somebody's emergency cooldown and is not news. A Swapblaster cast that *begins* out of combat is still announced even if the pull starts before it lands — that swap is exactly as mean as it looks.

---

## What the alerts look like

Console output is tagged; chat messages are sent plain so they don't shout:

```
[Tattle] Donut is casting Swapblaster
[Tattle] Donut used Swapblaster
[Tattle] Pancakes's Swapblaster was cut short
[Tattle] Pancakes used Life Grip on you!
[Tattle] Pancakes used Rescue on Donut!
[Tattle] Pancakes attempted a Life Grip on Donut, but it failed because Donut is using a Neural Silencer
[Tattle] Pancakes used Swapblaster, but Pancakes is using a Neural Silencer - that's not fair!
```

Every module decides independently where its alerts go: console, chat channel, sound, on-screen warning. Swapblaster on screen + Raid Warning sound while Life Grip goes quietly to the chat window is a normal setup.

---

## Neural Silencers, the fun module

A Neural Silencer makes its wearer immune to precisely the toys this addon watches. Tattle refuses to let that be quietly useful:

- **A blocked grab is reported as a blocked grab.** A Life Grip or Rescue that resolved but marked nobody is a refusal, and the message says so and names the immune player.
- **A backfired Swapblaster is reported too** (`182081`, *Swapblaster Explosion*). That spell is the only evidence a blocked swap attempt ever existed, because a swap that *lands* marks nobody either.
- **A protected caster gets called out.** Firing a Swapblaster while wearing a Silencer yourself cannot work, and gets: *`… is using a Neural Silencer - that's not fair!`*
- **An optional on-screen watch list** (off by default, drag it where you want) shows the group's Silencer wearers and which group members currently have *you* targeted.

It will **never** announce that someone simply put one on. Wearing a buff is not an event, and joining a raid should not read out *"Donut has one on, Pancakes has one on…"*. A wearer surfaces only in the list you switched on, or in an alert about a cast they were involved in.

---

## What Tattle will never tell you

Listed so nobody files it as a bug:

- **Not who was swapped.** The Swapblaster's cast leaves no aura on either party. Caster only, every time.
- **Nothing while you are solo.** Every ability it watches needs a group, so out of one there is nothing to detect and the addon does no work at all.
- **Nothing about pets, minions, totems or NPCs.** None of them can cast any of these spells, so non-player casters are rejected before the spell is even named.
- **Nothing while the addon is disabled** or while a module's own toggle is off.
- **No claim about who is *aiming* at you, if your client can't see it.** The "who has you targeted" list only prints what your client actually exposes; when a target token isn't synced it says so rather than guessing.

---

## Configuration

`/tattle` opens the panel. Each module gets its own tab (**Swapblaster**, **Life Grip**, **Rescue**, **Silencers**) with:

- **Monitor** — `Whole group` (any member's cast) or `Only me` (drop a cast only when it can be *proven* it missed you)
- **Console output** — print to your chat window, tagged `[Tattle]`
- **Chat message** — and which channel (see below)
- **Sound** — Raid Warning, Ready Check, Alarm Clock, Level Up, Achievement
- **On-screen alert** — on/off per module
- **Spell ID editor** — override the built-in IDs in-game, per module, for when Blizzard renames something

Screen alert **appearance is global** (text colour, font, font size, how long it shows, optional background, drag to reposition); which modules *use* it is per module. The Silencers tab additionally holds the optional watch list.

The panel — about 200 widgets — is not created until the first time you open it, not at login.

## Commands

| Command | Does |
|---|---|
| `/tattle` | Open the configuration panel |
| `/tattle status` | Current state, effective settings and which chat channel alerts actually resolve to |
| `/tattle on` / `/tattle off` | Enable / disable |
| `/tattle version` | Print the version |
| `/tattle debug` | Verbose decision logging, including why a cast was dropped |
| `/tattle probe` | Event probe: prints every cast event it can see, whether the caster and destination are readable, the group's Silencer wearers, and what it can read from other players' target tokens |

`/tattle probe` is the "is my build different?" tool. If an alert never fires, turn on `debug` + `probe`, have a friend use the ability on you and on someone else, and you'll see whether the event arrived, what spell name your client reported, and whether the aura that names the victim was visible. If a spell ID moved, type the right one into that module's spell ID editor and `/reload`.

## Chat channels, including LFR

Pick per module: **Private (console only)**, **Say**, **Yell**, **Party**, **Raid** or **Instance**.

`Raid` and `Party` are resolved against the group you are *actually* in before they are sent. In a **Looking for Raid** group a literal `RAID` send goes nowhere without an error, and a literal `PARTY` send in a raid is silently dropped — so asking for *Raid* in LFR routes to instance chat, and asking for *Raid* in a party of four routes to party chat instead of into the void. `/tattle status` shows which channel a message really used.

## "Does this cost frames?"

There is **no `OnUpdate` anywhere in the addon**. Nothing runs per frame, nothing polls, and there is no GPU cost beyond text frames that exist only while an alert is visible. Everything is event-driven, and it tries to answer the cheapest question first:

- **Four gates before any module code runs**: addon enabled → you're grouped → the spell name was registered by somebody → the caster is one of your group's *players* (membership includes you, which the `partyN`/`raidN` tokens do not cover).
- **One spell-name lookup per cast event, not one per module.** In a fight the client reports every cast by every raid member; a spell name is resolved once with `C_Spell.GetSpellName` (a plain string, no table allocated) and the event is discarded unless a module asked for that name. The addon's own test harness asserts exactly one lookup per watched cast event — and zero for a pet or NPC cast.
- **Group roster scans are cached** and dropped on `GROUP_ROSTER_UPDATE`, so an aura or target sweep allocates no token lists.
- **The watch list is throttled** (never faster than one sweep per 0.25 s), only ticks while you have it switched on, and only re-measures its frame when the text actually changed. Turn it off and its timer is cancelled, not just hidden.
- Out of a group, the addon does literally nothing.

## How it works under the 12.x restrictions

Two changes in Midnight made this kind of addon harder, and Tattle exists because of them:

- **`COMBAT_LOG_EVENT_UNFILTERED` was removed** (registering it now raises `ADDON_ACTION_FORBIDDEN`). It was the only source of a spell's *destination*. Tattle substitutes **auras as destinations**: Life Grip and Rescue mark the player they moved, so the victim is recovered by scanning the group's auras — which 12.1 made readable out of combat again.
- **Spell IDs are secret values inside restricted content** — they can't be compared with `==`, printed, or used as a table key. Tattle therefore resolves its known IDs to spell names once at startup and compares the *name* the core hands each event, never the raw ID, with `pcall` around anything that might receive a secret.

That is also why this addon can name a grip's victim when older, combat-log-based tools can no longer do it at all.

## Compatibility

- **World of Warcraft retail 12.x** (Midnight). `## Interface: 120001, 120000`; built and spell-checked against **12.1.5**.
- No libraries, no data feeds, no addons required, no `/who`-style scanning, no comms. Nothing leaves your client and nothing is collected.
- Saved variables: `TattleDB`.
- **Tattle used to be called Snitch.** The rename carried the folder, chat command, frames and saved-variable name with it, and saved variables are stored per addon folder — so settings from an old *Snitch* install do not migrate on their own. Either re-tick what you had, or copy `WTF/Account/<account>/SavedVariables/Snitch.lua` over `Tattle.lua` and rename the variable inside. **`/tattle` is the only command**: the old spelling is not registered at all, so a stale `/snitch` macro fails visibly instead of half-working behind an alias nobody documents.

## FAQ

**Why did nothing happen when someone put a Neural Silencer on?**
That's intentional. Having the buff isn't an event; the wearer shows up in your watch list, or in an alert the next time their immunity actually matters.

**Why no alert for a Life Grip during the fight?**
Mid-combat grips and rescues are legitimate emergency tools. Tattle watches the out-of-combat ones — the ones nobody can explain.

**It says "attempted … but it failed". How does it know?**
A grab that resolves and marks nobody left with an aura is a refusal, and the group has a Silencer wearer. That's the inference, and the wording says *attempted* because the addon is reporting what it could see, not reading the server's mind.

**Can I make one module silent and another loud?**
Yes, that's the point of per-module tabs.

**The victim line says "on a protected group member" instead of a name. Why?**
Several people in the group were immune, so naming one of them would be a guess.

---

Source, issues and changelog: [latest release](https://github.com/makayez/tattle/releases/latest) · [issues](https://github.com/makayez/tattle/issues) · [changelog](https://github.com/makayez/tattle/blob/main/CHANGELOG.md)

*Icon: the Tattle Turtle, generated from `Tools/make_icon.py` — the turtle has opinions about your movement toys.*
