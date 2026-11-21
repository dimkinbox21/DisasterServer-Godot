# Disaster 2D — Godot Server

The standalone server for the [Disaster 2D Godot client](https://github.com/dimkinbox21/Disaster2D-Godot).

![Godot](https://img.shields.io/badge/Godot-4.7.2-478cbf)
![Platform](https://img.shields.io/badge/Windows-x86__64-blue)
![Build](https://img.shields.io/badge/build-1130-green)

## Download and host

1. Download the Windows ZIP from [Releases](https://github.com/dimkinbox21/DisasterServer-Godot/releases/latest).
2. Extract it and run **DisasterServer.exe**, keeping its `.pck` file beside it.
3. Launch the matching client and connect to `127.0.0.1`, port `8606`.

Godot is not required to run a release build. Remote hosting uses UDP port `8606` by default.
Client and server must use the same build; the original GameMaker client is not compatible.

## Playing over Radmin VPN

Only the host needs the server; other players need the client. Everyone must be
online in the same Radmin VPN network. The host starts DisasterServer, and friends
enter the **host's Radmin IPv4 address** (`26.x.x.x`) in the client's IP field.
`localhost` and `127.0.0.1` connect to the player's own computer.

The server listens on every IPv4 interface using **UDP 8606** by default. Allow
`DisasterServer.exe` through the host's firewall on the network profile used by
Radmin; do not disable the firewall. VPN tunnels do not require router forwarding.
Use the current port client and server, rather than the original GameMaker builds.

If connecting fails, first check that Radmin shows both peers online, then test
`ping <host-Radmin-IP>` from the friend's machine. A ping timeout alone does not
prove the tunnel is down, because ICMP may be blocked. Check UDP/firewall rules
and the server's connection log too. Connecting to your own Radmin IP only tests
the local machine, not the friend's tunnel. `Test-NetConnection -Port` tests TCP
and cannot validate this game's UDP connection.

## Features

- Lobby, map voting, character selection, rounds and results.
- Server-controlled damage, rings, cooldowns and profile events.
- Twenty regular maps plus Fart Zone practice.
- Separate authoritative mechanics and world data for each map.
- Chat commands, operator actions, vote kick and solo testing.
- A graphical control panel for server settings and player management.

## Configuration

The server stores these files in its Godot user data directory (`user://`):

| File | Purpose |
| --- | --- |
| `Config.json` | Port, map pool, MOTD and server options |
| `Operators.json` | Operator IP addresses |
| `Bans.json` | Persisted player bans |

By default, `127.0.0.1` is an operator. The `motd` setting is shown in the client chat
when a player joins and when they use `.info`.

## Map profiles

Server hotfix **v1130.1** restores the full original presets and remains compatible
with client build **1130**, including client hotfix **v1130.1**.

| Profile | Maps |
| --- | --- |
| DEFAULT | Hide and Seek Act 2, Ravine Mist, ..., Desert Town, You Can't Run, Limp City, Not Perfect, Kind and Fair, Act 9, Nasty Paradise, Priceless Freedom, Volcano Valley, Hill, Majin Forest, Hide and Seek, Torture Cave, Dark Tower, Haunting Dream, Mystic Wood, Echidna Ruins |
| CLASSIC | ..., You Can't Run, Not Perfect, Kind and Fair, Act 9, Hill, Hide and Seek |
| EASY | Hide and Seek Act 2, ..., Dark Tower, Haunting Dream, Echidna Ruins |
| MEDIUM | Ravine Mist, Desert Town, You Can't Run, Kind and Fair, Volcano Valley, Hill, Hide and Seek |
| HARD | Limp City, Not Perfect, Nasty Paradise, Torture Cave, Mystic Wood |
| MADNESS | Act 9, Priceless Freedom, Majin Forest |
| NIGHTMARE UNIVERSE | Ravine Mist, Desert Town, Nasty Paradise, Priceless Freedom |
| SPIRITS OF HELL | Hide and Seek Act 2, Limp City, Volcano Valley, Majin Forest |

Previously truncated named profiles are upgraded and saved automatically. Manual
map pools (`map_set: -1`), including an empty pool, stay unchanged. A named profile
with a manually changed membership is relabelled CUSTOM without changing its maps.
Profile definitions are shared by the control panel and configuration migration in
`src/data/map_profiles.gd`.

## Commands

| Command | Action |
| --- | --- |
| `.help`, `.info` | Command list and server description |
| `.lobby N` | Switch lobby |
| `.vk`, `.vp` | Vote kick or vote for Fart Zone practice |
| `.yes`, `.y` | Support the current vote |
| `.test k`, `.test s` | Solo map testing as hunter or survivor |
| `.map N` | Operator: choose map 1–21; 21 is Fart Zone |
| `.kick`, `.ban`, `.op` | Operator: choose a player for an action |

`.test` requires exactly one player in the lobby. It opens normal map voting and character
selection, while disabling profile progress and preserving hunter selection chance.
Practice requires at least two players and does not award achievements or currency.

## Source layout

| Path | Purpose |
| --- | --- |
| `src/server.gd` | ENet transport and round lifecycle |
| `src/maps/<map>/rules.gd` | One map's authoritative mechanics |
| `src/maps/shared/rules.gd` | Shared geometry, damage and teleport operations |
| `assets/maps/<map>/world.json` | Entities, collision geometry, rings, exits and springs |
| `assets/maps/catalog.json` | Stable map IDs, names and durations |
| `src/data/maps.gd` | Cached map data access |
| `src/character_rules.gd`, `*_rules.gd` | Character ability validation and profile events |
| `src/chat_commands.gd` | Commands, votes and operator permissions |
| `src/ui.gd`, `src/gm.gd` | Server control panel |
| `src/net_packets.gd` | Packet IDs |

Only the selected map's module is active during a round.

## Build from source

Use **Godot 4.7.2** with matching export templates. Open `project.godot`, or run:

```powershell
New-Item -ItemType Directory -Force build
godot --headless --editor --path . --import --quit
godot --headless --path . --export-release "Windows Desktop" build/DisasterServer.exe
```

Keep the exported EXE and PCK together. The export preset includes all required JSON data.
Engine binaries, local configuration and exported packages are not committed.

## Credits and license

Original game and GameMaker source: **Team Exe Empire**.
The original MIT notice is retained in [LICENSE.md](LICENSE.md).
Godot: [Godot Engine](https://godotengine.org/), MIT license.
