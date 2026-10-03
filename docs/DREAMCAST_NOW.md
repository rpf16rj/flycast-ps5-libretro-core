# Dreamcast Now / DreamPi support in the Flycast libretro core

This documents the `dcnow` feature added by `patches/flycast-ps5.patch`:
in-emulator replication of what a Raspberry Pi running
[DreamPi](https://github.com/Kazade/dreampi) does for a real Dreamcast —
dial-up DNS through a community server, presence reporting to
[dreamcast.online](https://dreamcast.online), and discoverability of the
console on the LAN exactly like a Pi.

All of it runs inside the core: no external device, no TLS, no extra
process.

## Why it exists

Online Dreamcast play in 2025 works because the community rebuilt the dead
Sega/GameSpy infrastructure:

- A **DreamPi** bridges the console's modem to the internet. Its PPP
  negotiation hands the Dreamcast a DNS server; a local `dnsmasq` forwards
  queries to community DNS (`46.101.91.123`, `209.50.50.129`), which answer
  the long-dead host names (`master.gamespy.com`, per-game lobby servers)
  with the addresses of today's community-run replacements (Shuouma,
  Dreamcast Live).
- DreamPi's **`dcnow.py`** watches the console's DNS queries and POSTs the
  SHA-256 of the last resolved host name to `dcnow-2016.appspot.com` every
  15 s. That is what powers the "who is playing what" list on
  dreamcast.online.
- DreamPi's **`config_server.py`** listens on TCP **1998** and answers
  `{"mac_address": "<sha256 identity>", "is_enabled": true}` with open
  CORS, so the dreamcast.online page can find the device on the LAN and
  let the user claim it.

Emulated dial-up in Flycast already terminates PPP in-process (picoTCP),
so the Dreamcast's DNS packets are visible to the emulator — everything
the Pi does beside the console can be done *inside* the core.

## What the patch adds

### Core options (Quick Menu → Options)

| Option | Values | Effect |
| --- | --- | --- |
| `reicast_dns_server` — **Dial-up DNS Server** | `dns.flyca.st` (Flycast Community), `46.101.91.123` (Shuouma / DreamPi), `209.50.50.129` (DreamPi alternate), `8.8.8.8` | The resolver handed to the emulated Dreamcast during PPP/DHCP when **Use DCNet is off**. Picking a community server gives the console the same redirected answers a DreamPi would produce. |
| `reicast_dcnow` — **Dreamcast Now Presence** | `enabled` (default) / `disabled` | Turns the whole feature on/off: DNS snooping, the 15 s presence POSTs, and the port-1998 config server. |
| `reicast_dcnow_mac` — **Dreamcast Now MAC** | `auto` | Identity source. `auto` reads/generates `flycast_dcnow.id` in the save directory. A literal `AA:BB:CC:DD:EE:FF` (set in the options file, or through the config page below) claims a specific identity — e.g. the MAC of a real DreamPi, unifying history. |

The patch also removes upstream's rewrite of `config::DNS == "46.101.91.123"`
to `dns.flyca.st`, which would silently ignore an explicit Shuouma choice.

### Presence reporting (`core/network/dcnow.cpp`)

Mirrors `dcnow.py` faithfully:

- `UdpSink::picoCallback` (picoppp.cpp) snoops Dreamcast UDP egress on port
  53 and extracts the question host name from the DNS packet.
- A worker thread POSTs
  `POST /api/update/<sha256(mac)>/ dns_query=<sha256(hostname)>` to
  `dcnow-2016.appspot.com` every 15 s while the link is up — **plain HTTP
  on port 80**, which the service accepts, so no TLS stack is needed.
- The shared domains DreamPi posts once per session
  (`gameloft`, `onsen0.overworks.isao.net`) get the same treatment.
- All socket work is on the worker with 10 s connect/read timeouts and
  cancellation on stop — the emulation thread never blocks.
- The player id is logged (`Dreamcast Now player id <hash>`); register it
  on dreamcast.online to claim the console.

### Identity

DreamPi's identity is `sha256` of its NIC MAC formatted `%012X` and
colon-separated. The core does the same:

1. `reicast_dcnow_mac` literal MAC → normalized to uppercase, hashed.
2. else `flycast_dcnow.id` in the save directory (a 17-char MAC string) →
   normalized to uppercase, hashed.
3. else a generated `5A:xx:xx:xx:xx:xx` persisted to the same file, so the
   identity is stable across sessions.

### DreamPi-compatible config server (port 1998)

While the core is loaded and DCNow is enabled, a thread listens on TCP
1998 and answers like `config_server.py`:

- **GET** from the site's XHR → `{"mac_address":"<id>","is_enabled":...}`
  with `Access-Control-Allow-Origin: *` — dreamcast.online/now detects the
  emulator as a DreamPi.
- **GET** from a browser (`Accept: text/html`) → a small config page:
  shows the player id, lets you **type the MAC** (`mac=AA:BB:CC:DD:EE:FF`
  POST, URL-decoded, validated, uppercased, persisted), and Enable/Disable
  presence. This is also the way to set the MAC without FTP access, since
  libretro core options cannot take free text.
- **POST** `disable`/`enable` → honored like the Pi (also what the site
  sends when toggling a device).

## How to use it

1. Quick Menu → Options: **Use DCNet = disabled** (Shuouma needs real PPP;
   DCNet tunnels DNS differently), **Dial-up DNS Server = Shuouma /
   DreamPi**, **Dreamcast Now Presence = enabled**.
2. Load a game and open its online mode.
3. From a PC/phone on the same LAN, open `http://<ps5-ip>:1998` — the page
   shows the player id and a MAC field; or just run dreamcast.online/now's
   DreamPi detection.
4. Register the player id on dreamcast.online to claim the console.

Requirements/limits:

- The browser and the PS5 must be on the same routed LAN (no AP isolation,
  no NAT between them) for port 1998 to be reachable.
- The config server only lives while the core is loaded — keep Flycast
  open during registration.
- DNS-over-TCP queries are not snooped (games use UDP for DNS).

## Inbound connections / port forwarding

Some games need unsolicited inbound packets (peer connects to you), the
same games the Dreamcast Live guide flags with the port-forward icon.
On real hardware the DreamPi owns a `.98` LAN address and the router
forwards to *the Dreamcast behind it* — never to the Pi. With Flycast the
emulated console has a virtual PPP address only, so **the PS5's LAN IP
takes the Dreamcast's place on your network**: forward to it.

The core already does the DreamPi-side NAT in-process, upstream:

- When the emulated Dreamcast listens on a port, `TcpAcceptor`/the UDP
  sink open a **real socket on the same port on the host** (bind
  `0.0.0.0:port`) — packets arriving at the PS5's IP are injected into
  the picoTCP stack toward the Dreamcast.
- A table of the community games' ports is listened on as soon as the
  link comes up; DirectPlay4 games (TCP 47624, UDP/TCP 2300-2400) are
  detected automatically from the game's own packets.
- `reicast_upnp` (default enabled): when the link comes up, miniupnpc
  asks the router to map those ports via UPnP IGD — with UPnP enabled on
  the router **no manual forwarding is needed**. On the PS5 this path is
  unverified; if the log shows `UPNP Init failed`, forward manually.

Router setup:

1. Reserve the PS5's IP in the router's DHCP (the equivalent of the
   DreamPi's fixed `.98`).
2. If UPnP works, nothing else is needed. Otherwise forward the ports the
   game needs to the **PS5's IP**, per the Dreamcast Live list:

   | Game | Ports |
   | --- | --- |
   | Alien Front Online | UDP 7980 |
   | ChuChu Rocket! | UDP 9789 |
   | Dee Dee Planet | UDP 9879 |
   | Ooga Booga | UDP 6001 |
   | NBA/NFL/NCAA 2K | UDP 5502, 5503, 5656; TCP 5011, 6666 |
   | Starlancer / PBA Tour Bowling 2001 | TCP+UDP 2300-2400, UDP 6500, TCP+UDP 47624 |
   | Internet Game Pack | UDP 5656, TCP 5011, TCP 10500-10503 |
   | The Next Tetris | TCP+UDP 3512 |
   | Floigan Bros. | TCP 37001 |
   | Driving Strikers | UDP 30099 |
   | ClassiCube | UDP 25565 |

   Or put the PS5's IP in the router's **DMZ** — the equivalent of DMZ'ing
   the Dreamcast's `.98`. (The guide's "never DMZ the Pi" warning doesn't
   apply: the PS5 *is* the endpoint, not an intermediary.)

Inbound forwarding only exists on the **real PPP path** — same
requirement as the rest of this feature: *Use DCNet = disabled*. DCNet
tunnels traffic through its cloud service instead, where the inbound
model is different.

## Files

- `core/network/dcnow.h`, `core/network/dcnow.cpp` — service, SHA-256,
  worker, config server.
- `core/network/picoppp.cpp` — DNS snoop hook, lifecycle, literal-DNS fix.
- `core/cfg/option.{h,cpp}`, `shell/libretro/option.cpp`,
  `shell/libretro/libretro_core_options.h` — the three options.
- `shell/libretro/libretro.cpp` — `setStateDir` + `init`/`deinit` wiring.
- `core/network/CMakeLists.txt` — build.
