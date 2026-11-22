# Lattice: Party & Raid Frames

Party and raid frames for WoW Forever: corner spell indicators, an easy settings window, click-casting, aura and dispel highlights, and profiles.

## Use
- `/lattice` opens the settings. `/lattice unlock` lets you move the frames. `/lattice preview 20` shows fake frames.
- `/lattice status` shows why frames or auras are or aren't showing.
- `/lattice tank <name>`, `/lattice notank <name>`, `/lattice autotank <name>` fix the tank guess for a player; `/lattice tanks` lists who counts as tank.
- `/lattice feedback` (or the Feedback button in the settings) shows a link for reporting bugs and ideas.
- `/lattice ai` (or the AI help button in the settings) shows a description of every setting to paste into an AI chat assistant along with what you want; paste its answer into `/lattice apply`, which shows each change before applying it. Changes made in combat apply when combat ends.
- `/lattice <setting> <value>` changes one setting from chat (`/lattice get` lists them), e.g. `/lattice layouts.raid.width 90`.
- `/lattice show <spell>`, `/lattice hide <spell>`, `/lattice unlist <spell>` edit the aura filters (name or spell ID).
- `/lattice search <words>` opens the settings with the search box filled; `/lattice version`; `/lattice help` (or `?`) lists every command, and a mistyped one suggests the nearest. `/lat` works as well as `/lattice`.
- Ctrl+Alt+Right-click a frame: tank choice for that player and a picker for their auras.

## Features
- Party, raid and large-raid layouts that switch automatically. Pet frames in their own movable block (Layout page).
- Click-casting on frames: mouse buttons 1-5 with Shift, Ctrl and Alt.
- Hover-casting: bind a key to a spell and it casts on whoever the mouse is over, optionally falling back to your friendly target, then to you (friendly spells only; on for new keys, a switch per key, and "New keys cast on me" sets where it starts).
- Your HoTs and buffs, debuffs, boss debuff and big defensives, with optional seconds-left numbers. Spell indicators in the frame corners, plus one-click presets for your class.
- Dispel highlight: a big icon of a debuff you can remove in the middle of the frame, edged in its type's colour, plus an optional coloured border or tint.
- Raid buffs in a row beside each frame, and a mark on players missing your class's buff.
- The 5-second rule: after a mana spell, a thin line over the mana bar drains for 5 seconds, then glows while mana comes back (you and your healers, or anyone you pick). `/lattice 5sr` turns it on or off.
- The 5-second rule ring: your own ring to place anywhere. It fills for the 5 seconds after you spend mana, then burns with blue fire while your mana comes back. It shows in combat (or always, if you like). `/lattice 5sr move` to place it, `/lattice 5sr widget off` to turn it off.
- Incoming heals, shields, low health warning, range fade (by your heal's range), role, leader, raid marker, ready check, resurrect and summon icons. Dead players tint red, offline players grey.
- Tank frames with each tank's target, in raids.
- Profiles per spec (on clients with specs), and one string to share your whole setup.
- Works in combat: health, heals, shields, range and auras keep updating during fights.
- Tank guessing when the group has no roles, power bars by power type and role, and aura filters (always show / never show).

## Changes

What's new in each version: [CHANGELOG.md](CHANGELOG.md).

## Install
WowUp: pick **World of Warcraft: Forever**, then Get Addons → Install from URL, and paste `https://github.com/quikmn/LatticePartyRaidFrames`.

By hand: download the latest zip from Releases and unzip it into `World of Warcraft\_forever_\Interface\AddOns`.

## License

GPL-3.0-or-later (see LICENSE). Not affiliated with Blizzard Entertainment.
