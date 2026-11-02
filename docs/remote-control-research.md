# How lighting consoles and digital mixers are remote-controlled

A study for building one app that runs the lights and the sound at a small live
event. It covers the networking and protocol foundations, how each kind of
console thinks about "a fader", how the common consoles and mixers actually
accept remote control, and what all of that means for the app's design.

Every protocol detail is marked with how sure it is:

- **[doc]** comes from the manufacturer's own documentation.
- **[community]** comes from forums, open-source projects or third-party tools, and has
  been seen working by others but isn't an official spec.
- **[verify]** is from memory or a single weak source. Check it on hardware before relying on it.

Sources are listed at the end.

---

## 1. The mental model: three layers

Every remote-control link, whatever the brand, has three layers. Keeping them
separate is the most useful idea in this whole document.

| Layer | Question it answers | Examples |
|---|---|---|
| **Transport** | How do bytes get from the iPad to the console? | Ethernet/Wi-Fi, IP, UDP or TCP, a port number |
| **Encoding** (wire protocol) | How is a message laid out in those bytes? | OSC, MIDI (NRPN, SysEx), plain text lines, HTTP/JSON, proprietary binary |
| **Object model** (vocabulary) | What things exist on the console, and what can you say to them? | "Page 1, executor 201, fader at 50", "input 3 fader at −10 dB", "recall scene 12" |

Two consoles can share the bottom two layers and still be completely different
to program against. grandMA3 and the Behringer X32 both speak OSC over UDP, but
one has *executors on pages* and the other has *channel strips with dB fader
laws*. "Supports OSC" tells you how to spell a message. It doesn't tell you
what you can say.

That suggests the shape of the app straight away: shared transport and encoding
code at the bottom, a **driver per console family** that knows its object model,
and one common vocabulary on top that the UI talks to (see section 8).

### Control vs. data: a distinction that matters for lighting

- **Control plane:** telling a console what to do, such as "playback 3 to 80%" or
  "Go on cue list 1". The console then works out every fixture's output itself.
  That's what this document is mostly about.
- **Data plane:** the actual per-channel levels for the fixtures: DMX512,
  Art-Net or sACN. A console *produces* this. An app could produce it too and
  skip the console entirely.

Audio has the same split. Dante or AES67 carry the *audio*. The mixer's
control protocol carries the *settings*. A remote-control app only touches
the control side. It never needs to handle audio streams.

For small events that's a real option: many small gigs have **no lighting
console at all**, just a few LED pars on a DMX node. There the app can *be*
the lighting controller over Art-Net or
sACN, while still remote-controlling the mixer.

---

## 2. Network foundations

### IP, subnets and addressing

- Consoles and mixers almost always sit on a private subnet such as
  `192.168.1.x/24`. The iPad must be on the **same subnet** to reach them. Most
  protocols here aren't routed, and some, like broadcast discovery, *can't* be.
- Show networks mostly use **static IPs**. A DHCP router is still handy so
  phones and tablets get addresses automatically. The usual setup is a Wi-Fi
  access point bridged onto the console network, with consoles on static IPs
  outside the DHCP pool.
- A **port** picks which program on the device gets the message. Each
  protocol has its own default (OSC on 8000, X32 on 10023, dLive on 51325…).

### UDP vs TCP: the decision behind every protocol

| | UDP | TCP |
|---|---|---|
| Unit | Independent datagrams, with message boundaries kept | A byte stream with no boundaries |
| Reliability | None. Datagrams can be lost, duplicated or reordered | Delivered in order, or the connection fails |
| Connection | None. Just send | Handshake, then stays open. Both ends know it's alive |
| Framing | Free: one datagram is one message | Required: you must mark where each message ends |
| Typical users | OSC (MA3, X32, Eos UDP, MagicQ), Art-Net, sACN | A&H MIDI, Yamaha RCP, Eos OSC-TCP, MA2 telnet, HTTP/WebSocket |

What this means in practice:

- **UDP fader streams tolerate loss well.** The next fader update replaces the
  lost one. **Discrete commands don't**: a lost "Go" or "Mute on" just doesn't
  happen. Over UDP, read back the state to confirm it changed, or send
  idempotent "set" messages (set to on) rather than toggles.
- **UDP has no "connected" state.** Sending succeeds even if the console is
  off. Liveness has to come from replies, such as a subscription answer or polled values.
- **TCP needs framing.** OSC over TCP comes in two flavours: OSC 1.0 puts a
  4-byte length before each packet, and OSC 1.1 uses SLIP (special end bytes).
  ETC Eos makes you choose which **[doc]**. MIDI over TCP needs no framing, because
  MIDI messages describe their own length. Text protocols end each line with `\n`.
- **Turn off Nagle's algorithm** (`TCP_NODELAY`) on TCP control links, or the
  OS batches small writes and adds latency to fader moves.

### Unicast, broadcast, multicast

- **Unicast:** to one IP. Almost all control traffic.
- **Broadcast:** to everyone on the subnet. Used for discovery (and by
  Art-Net, classically).
- **Multicast:** to subscribers of a group address. sACN uses
  `239.255.<universe>` per universe.
- **On iOS, broadcast and multicast need a special entitlement that Apple must approve**
  (`com.apple.developer.networking.multicast`). Bonjour browsing doesn't need it.
  This affects Art-Net and sACN output and any "scan the network" discovery
  (section 7) **[doc]**.

### Wi-Fi: where small events actually fail

- Wi-Fi adds variable latency (often 2–50 ms, with spikes) and drops packets
  in bursts. That's fine for faders over UDP. It means reconnection logic is
  mandatory for TCP.
- Multicast over Wi-Fi is sent at the lowest data rate and is often lossy.
  Another reason to keep sACN off the Wi-Fi and on wired links.
- Venue and hotel Wi-Fi often has **client isolation** (devices can't talk to
  each other). Bring your own access point.
- An app that loses Wi-Fi mid-show must fail **safe**: never send a burst of
  stale values on reconnect, and re-read state instead (section 6).

---

## 3. The encodings in depth

### 3.1 MIDI (1983, still everywhere)

MIDI is a byte protocol built for a 31.25 kbaud serial cable. Today it's
carried inside TCP (Allen & Heath), USB or RTP-MIDI, but the bytes are the same.

- **Status bytes** have the top bit set (`0x80–0xFF`). **Data bytes** don't
  (`0x00–0x7F`), so every value is **7-bit (0–127)**.
- The low nibble of a channel status byte is the **MIDI channel** (16 channels).
  - `9n kk vv`: Note On
  - `Bn cc vv`: Control Change
  - `Cn pp`: Program Change
- **Running status:** a sender may leave out a repeated status byte. A receiver
  must remember the last status. dLive uses running status **[doc]**, so a parser
  that ignores it will misread the stream.
- **NRPN** (Non-Registered Parameter Number) works around 7-bit limits with a
  sequence of CCs: `Bn 63 <param MSB>`, `Bn 62 <param LSB>`, `Bn 06 <value MSB>`
  (optionally `Bn 26 <value LSB>` for 14-bit / 16384 steps). A&H uses NRPN
  for levels **[doc]**. NRPN is *stateful*: the parameter set by 63/62 sticks until
  changed, so the parser must track it per channel.
- **SysEx** (`F0 … F7`) carries anything else, of any length, with a
  manufacturer ID. A&H uses it for "get value" and "get name" requests **[doc]**.
- **MIDI Show Control (MSC)** is a standard SysEx format for show cues:
  `F0 7F <device> 02 <command format> <command> <data> F7`. Command format `01`
  is "Lighting – General", command `01` is GO, and cue numbers go as ASCII
  digits with `00` separating cue and list, e.g. GO cue 91.5 list 12 is
  `F0 7F 01 02 01 01 39 31 2E 35 00 31 32 00 F7` **[doc, ETC]**. Eos, MA2/MA3 and
  many others accept MSC. It's the nearest thing to a *standard* "Go" across
  lighting brands, but it only has cues, not faders.

### 3.2 OSC (Open Sound Control)

OSC is the most common modern control encoding. A message is:

```
address pattern   "/gma3/Page1/Fader201"   (null-terminated, padded to 4 bytes)
type tag string   ",f"                     (padded to 4 bytes)
arguments         float32 50.0             (big-endian)
```

- Types: `i` int32, `f` float32, `s` string, `b` blob, plus `T`/`F`/`N` with
  no data. Everything is **big-endian and 4-byte aligned**. Most hand-written
  encoders break on the alignment.
- **Bundles** (`#bundle` + timetag + sized elements) group messages. Receivers
  should accept them. X32 meter data, for instance, arrives as blobs.
- **OSC defines spelling, not meaning.** There's no standard namespace, no
  discovery, no acknowledgements and no schema. Each vendor publishes (or
  doesn't) its own address list and value ranges. That's why "supports OSC" is
  only a starting point.
- Feedback styles differ widely: some consoles echo every change, some only
  after you *subscribe*, some never.

### 3.3 Text-line protocols

- Human-readable commands, one per line, over TCP. Examples: Yamaha RCP
  (`set MIXER:Current/InCh/Fader/Level 0 0 -1000\n`) and grandMA2 telnet.
- Easy to debug with `nc`. Watch quoting, line endings and zero-based indexes.

### 3.4 HTTP, REST and WebSocket

- **HTTP request/response** (Avolites Titan WebAPI): simple and firewall-friendly,
  but nothing gets *pushed* to you. Feedback means polling.
- **WebSocket** (Soundcraft Ui and others): one persistent connection, both
  directions. Often the same channel the mixer's own browser UI uses, so it
  is undocumented but observable.

### 3.5 Proprietary binary

Behringer Wing's native protocol, PreSonus UCNet, Harman HiQnet and DiGiCo's
own iPad protocol are faster and richer than OSC, but documented to varying
degrees or not at all. Prefer a vendor's *published* path (Wing publishes its
protocols **[doc]**), and treat reverse-engineered ones as a maintenance risk.

### 3.6 DMX, Art-Net, sACN (lighting data plane)

- **DMX512:** 512 eight-bit slots per *universe*, refreshed up to about 44 times a second
  over RS-485.
- **Art-Net:** DMX universes in UDP on port 6454.
- **sACN (ANSI E1.31):** DMX universes in UDP multicast on port 5568, with a
  **priority** field (0–200) so a backup or an app can take over or step aside.
- Not used for *remote-controlling* a console, but it's how an app drives
  fixtures directly when there's no console. Needs the iOS multicast/broadcast
  entitlement (section 2).

---

## 4. How lighting consoles think, and how to talk to them

### 4.1 The object model

Lighting consoles don't expose "fixture 12 intensity" as a remote fader, at
least not usefully. They expose **playbacks**:

- A **cue list / sequence** holds cues (looks plus timing). A **playback** (MA:
  *executor*; Eos: *fader*; Avolites/ChamSys: *playback*; Hog: *master*) is a
  physical or virtual fader-and-buttons slot that a cue list is assigned to.
- **Pages** swap which cue lists sit on the playbacks. So "fader 3" means
  nothing without a page. MA3 addresses include the page; Eos needs a fader
  *bank* to be configured first (section 4.2).
- A playback fader usually sets that playback's **master level** (how much
  of its look comes through). Its buttons do **Go, Go back, Flash, Off**, and the
  button actions can be reassigned per playback. Remote "button 1" may not
  mean Go.
- **Grand master** and **blackout** cap all intensity. Small-event users want
  these on screen permanently.
- **HTP/LTP:** intensity mixes "highest takes precedence", while other
  attributes (colour, position) go "latest takes precedence". Moving a
  playback fader can therefore change colour or position, not just brightness.
- **The command line is the universal API.** Almost every pro console can take
  a typed command remotely (MA `/cmd`, Eos `/eos/cmd`, MA2 telnet). Anything
  without a dedicated message can still be done this way, with the syntax
  depending on the console.

### 4.2 Console-by-console

| Console | Protocol / port | Fader message | Buttons / Go | Feedback | Notes |
|---|---|---|---|---|---|
| **grandMA3** (console and onPC) | OSC over UDP, port set per OSC line in Menu › In & Out › OSC | `/<prefix>/Page1/Fader201` with `,i` or `,f`, e.g. `/Page1/Fader201,i,100` **[doc]** | `/<prefix>/cmd ,s "Go+ Exec 402"` needs *Receive Command* on **[doc]**. Key messages `/Page1/Key201` **[community]** | Console can send OSC out (Enable Output). Exact feedback format **[verify]** | The prefix filters incoming messages and has no slashes **[doc]**. Names are case-sensitive **[doc]**. Fader Range per line sets the scale **[verify default]** |
| **grandMA2** | Telnet, TCP 30000 (30001 read-only) **[doc]** | Command line, e.g. `Fader 201 At 50` **[verify syntax]** | Any command | Text replies | Must `Login` as a show user first (case-sensitive) **[doc]**. Enable under Setup › Console › Global Settings |
| **ETC Eos family** | OSC over TCP 3032 (choose OSC 1.0 length-prefix or 1.1 SLIP) or UDP (e.g. 8000/8001). Third-party SLIP port 3037 **[doc]** | `/eos/fader/<bank>/config/<count>` first, then `/eos/fader/<bank>/<n>` with 0–1 **[community]** | `/eos/cmd`, `/eos/key/go_0` **[verify]** | Rich, pushed (`/eos/out/...`), very good for sync **[doc/community]** | Use a separate user number (e.g. `/eos/user/2/...`) so the app doesn't fight the main desk's command line **[community]**. Accepts MSC |
| **ChamSys MagicQ** | OSC (UDP, defaults RX 8000 / TX 9000) **[doc]**. Also ChamSys Remote Ethernet Protocol, UDP 6553 **[doc]** | `/pb/<n>` with float 0–1 or int 0–100, built-in addresses cover playbacks 1–10 only **[doc]** | `/pb/<n>/go`, etc. **[verify]** | Some | OSC not on MQ40/MQ40N, and on PC only when unlocked **[doc]**. Remote protocol is off by default |
| **Avolites Titan** | HTTP WebAPI on port 4430 (4431 shares the front-panel user) **[doc]** | `/titan/script/Playbacks/FirePlaybackAtLevel?...&level=0.5`, or `SetPlaybackLevel` **[doc]** | Same API | Poll only | Paths change between Titan versions, so pin to one **[doc]**. Faders are 0–1 but 256 steps |
| **Obsidian Onyx** | Telnet (configurable, e.g. 2323) and UDP commands. OSC also available **[doc]** | OSC playback paths like `/42xx` **[community, verify]** | Telnet commands | Telnet replies, UDP none **[doc]** | OSC mapping is in a separate PDF |
| **Hog 4** | OSC, ports set in the Network window **[doc]** | Hardware fader paths, need Hog hardware or an unlocked nomad **[doc]** | `/hog/playback/go/0` etc. **[doc]** | Some | Faders not supported on Hog 4PC **[doc]** |
| **QLC+ / free software** | OSC input, a web interface and WebSocket **[verify]** | Mappable | Mappable | Yes | Common at small events. Also a model for "app drives DMX directly" |

**Takeaways for lighting:**

- OSC over UDP is the common case, but **TCP-based Eos** and **HTTP-based Titan**
  mean the transport layer must be pluggable.
- **Fader feedback is the weak spot.** Eos is excellent, MA3 is configurable,
  and others are partial or need polling. The app must work well even without it.
- Many consoles need **setup on the console** (enable OSC, set ports, prefix,
  user). The app should show exact per-console setup steps, the way Mixing
  Station and Companion do.

---

## 5. How digital mixers think, and how to talk to them

### 5.1 The object model

- **Channel strips:** inputs, FX returns. Each has a fader, mute, gain,
  pan, EQ, dynamics and **sends**.
- **Buses:** mix/aux buses (monitors), groups, matrices, mains. Each has a
  master fader and mute.
- **Sends:** a level *from* a channel *to* a bus. "Give me more vocal in my
  wedge" is a send, not a fader. A huge share of small-event remote use is
  musicians running their own monitor sends.
- **DCAs / VCAs:** remote masters that scale a set of channel faders without
  carrying audio. **Mute groups** mute sets of channels.
- **Scenes/snapshots** recall the whole mix (with recall-safe scopes).
- **Fader law:** fader travel isn't linear in dB. A console fader spans about
  −∞ to +10 dB, with most of the travel near 0 dB. Each protocol picks its
  own number for this:
  - an abstract 0–1 float with a piecewise curve (X32),
  - real dB×100 (Yamaha),
  - 7-bit steps (A&H, with a selectable "audio taper" on SQ).

  The app must convert each one to a common dB value so a fader looks and
  feels right **[doc/community]**.

### 5.2 Mixer-by-mixer

| Mixer | Protocol / port | Fader message & scale | Feedback | Notes |
|---|---|---|---|---|
| **Behringer X32 / Midas M32** | OSC over UDP 10023 **[community]** | `/ch/01/mix/fader ,f 0.0–1.0`, where 0.75 is 0 dB. dB = 40f−30 (f≥0.5), 80f−50 (≥0.25), 160f−70 (≥0.0625), 480f−90 below, with 0 as −∞. About 1024 steps **[community]** | Send `/xremote` about every 9 s to receive changes for 10 s **[community]**. Values readable by sending the address with no argument | Two-digit, one-based channel numbers in addresses. Very well documented by Patrick-Gilles Maillot (unofficial) |
| **Behringer X Air / Midas MR** | OSC over UDP 10024 **[community]** | Similar namespace, different from X32 in places | Subscription, different command from X32 **[community]** | Very common at small events |
| **Behringer Wing** | OSC on UDP 2223. Native binary over TCP for full apps **[community]**. Official "WING Remote Protocols" doc **[doc]** | Per the protocols doc | OSC changes only while subscribed (renew under 10 s) **[community]** | Prefer the native protocol for a full-featured driver |
| **Allen & Heath dLive / Avantis** | MIDI over TCP. MixRack **51325** (TLS 51327), Surface **51328** (TLS 51329) **[doc]** | NRPN `Bn 63 CH, Bn 62 17, Bn 06 LV`, with dB = LV × 64/127 − 54 and LV 0 = −∞, so 0x6B ≈ 0 dB and 0x7F = +10 dB **[doc, via Companion module]**. Strip types live on base channel N through N+4 | Pushed changes. SysEx get for level, mute and name | Running status **[doc]**. The server limits flow rate (sliding window), so pace bursts **[community]**. TLS needs a user and password **[doc]** |
| **Allen & Heath SQ / SQ+** | MIDI over TCP 51325 **[doc]** | NRPN with MSB/LSB. 14-bit resolution available. Linear or audio-taper law selectable **[doc]** | Pushed | Separate DAW-control MIDI strips (CC 0–31 on channel 2) **[doc]** |
| **Allen & Heath Qu / CQ** | MIDI over TCP **[verify ports]** | NRPN | Pushed | Similar to the SQ family, but not identical |
| **Yamaha TF / CL / QL / DM3 / DM7 / Rivage** | RCP: text over TCP 49280 **[doc for related Yamaha devices; community for mixers]** | `set MIXER:Current/InCh/Fader/Level <ch0> 0 <dB×100>`, range −13800…1000, with −32768 as −∞. Channels zero-based **[community]** | `NOTIFY` lines pushed when something changes **[community]** | Yamaha publishes Python templates for CL/QL/TF **[doc]**. Mute is the channel's `Fader/On` parameter: 1 = on, 0 = muted (from the consoles' own parameter dumps). Scene recall: `ssrecall_ex scene_a <n>` on TF/DM3, `ssrecall_ex MIXER:Lib/Scene <n>` on CL/QL **[community]** |
| **Soundcraft Ui12/16/24R** | WebSocket, the same one the browser UI uses **[community]** | Text messages (reverse-engineered, e.g. the `soundcraft-ui` project) | Pushed | Up to 10 devices at once **[doc]**. Undocumented, so pin to firmware |
| **Soundcraft Si / Vi** | HiQnet **[verify]** | Proprietary | | Lower priority |
| **PreSonus StudioLive III** | UCNet, proprietary **[doc that it exists; no public spec]** | — | — | Avoid, or use MIDI/DAW modes only |
| **DiGiCo SD / Quantum** | OSC via External Control, configured on the console **[doc]**. One OSC device on some versions **[community]** | Console-defined | Two-way | Generic OSC is more "console sends to you" than full remote |

**Takeaways for audio:**

- No two mixer brands share an object model. Even their *indexing* differs
  (one-based two-digit OSC vs zero-based RCP vs a MIDI channel offset plus a
  number).
- Most mixers **push changes** to subscribed clients. That's better than lighting,
  and essential, because the engineer at the desk and the app both move things.
- **Fader laws must be per-driver code**, tested against the console's own display.

---

## 6. Cross-cutting engineering problems

These are what separate a demo from something you'd trust at a show.

1. **Initial state sync.** On connect, read everything the UI shows (levels,
   mutes, names) before you let the user touch it. Never push the app's stored
   values to the console on connect: the desk is the source of truth.
2. **Two writers, one fader.** The engineer and the app can move the same
   fader. Common rules:
   - Ignore incoming feedback for a control while the user's finger is on it
     (*touch lock*).
   - Suppress the console's echo of your own message.
   - On release, accept the console's value.
3. **Rate limiting and coalescing.** A drag gives 60–120 events a second. Send
   at most about 30–50 Hz per control, always send the *final* value, and drop
   intermediates if the link is busy. dLive throttles bursts itself.
4. **Idempotent commands.** Prefer "mute = on" over "toggle mute". If a toggle
   is lost or doubled over UDP, the app's state is wrong and nobody notices.
5. **Liveness and reconnects.**
   - **TCP:** detect the drop, back off, reconnect, and resync.
   - **UDP:** use subscription replies or a periodic query as a heartbeat.
   - **Both:** show connection state prominently. A grey "offline" badge saves shows.
6. **Normalisation.** Store a control's value in its *native* unit (dB, %,
   step), and convert at the edge to fader position. Round-trips must not
   drift: going fader to dB to native and back must give the same value.
7. **Indexing and naming.** Be explicit everywhere about zero- vs one-based
   numbering. Pull channel and playback names from the console where the
   protocol allows (dLive, X32 and Yamaha all do), so users see "Lead Vox", not "Ip 7".
8. **Safety.**
   - Most of these protocols have **no authentication**: anyone on the network
     can mute the mains. Keep the show network private.
   - Require confirmation for dangerous actions (scene recall, blackout, mains mute).
   - Never fire stored actions on app launch.
9. **Version drift.** Undocumented protocols (Soundcraft Ui) and
   version-specific APIs (Avolites) break on firmware updates. Record the
   firmware version each driver was tested against.

---

## 7. iOS/iPadOS platform constraints

- **Local Network permission:** iOS asks the user the first time the app touches
  the LAN. If they deny it, nothing works and sends fail silently. Detect this
  and explain it. Needs `NSLocalNetworkUsageDescription`.
- **Multicast/broadcast entitlement:** must be requested from Apple and
  approved. It's needed for sACN, Art-Net broadcast and any broadcast discovery
  (for example scanning for X32s). Plain unicast UDP and TCP don't need it **[doc]**.
- **Backgrounding:** iOS suspends apps quickly and closes their sockets. On
  returning to the foreground, reconnect *and resync*. Never assume the old state.
- **Network.framework** (`NWConnection`/`NWListener`) handles UDP, TCP, TLS
  and WebSocket, and reports path changes such as Wi-Fi drops. One framework
  covers every transport above.
- **Sleep and auto-lock:** disable the idle timer while connected during a show.

---

## 8. What this means for a universal app

### 8.1 Architecture

```
┌───────────────────────── UI (surfaces, scenes, macros) ─────────────────────────┐
│ Binds widgets to Controls; knows nothing about brands                           │
├─────────────────────────── Common control model ────────────────────────────────┤
│ Device → Controls:                                                              │
│   Level  (fader: native value + dB/% + 0–1 position)                            │
│   Switch (mute/on)                                                              │
│   Trigger (go/flash/recall)                                                     │
│   Selector (page/scene)                                                         │
│ Each with name, state, writable?, feedback-capable?                             │
├──────────────────────────── Drivers (one per family) ───────────────────────────┤
│ grandMA3 · Eos · MagicQ · Titan · Onyx │ X32 · XAir · Wing · A&H dLive/SQ/Qu ·   │
│ Yamaha RCP · Soundcraft Ui │ Direct DMX (Art-Net/sACN)                          │
│ connect · discover objects · subscribe · set · fader law · setup instructions  │
├──────────────────────────── Encodings ──────────────────────────────────────────┤
│ OSC codec · MIDI stream parser (running status, NRPN, SysEx) · line codec · HTTP│
├──────────────────────────── Transports ─────────────────────────────────────────┤
│ UDP · TCP (framing: none/length/SLIP/newline) · WebSocket · HTTP · TLS          │
└─────────────────────────────────────────────────────────────────────────────────┘
```

- Each **driver declares what it can do**: whether it has feedback, names,
  scenes, sends. The UI adapts, for example greying out "live" indicators when
  a console can't report back.
- **Cross-domain actions** are the app's real value for small events. One
  "Walk-in" button could recall lighting cue list 1 *and* unmute the playback
  channels; "Speech" could bring up the podium special *and* the lectern mic;
  a "Blackout" could fade the lights out *and* mute the band. These are just
  macros over the common model.
- **Testing without hardware:** each driver gets a protocol-level fake (a
  local UDP/TCP server that speaks the console's language) so encodings,
  feedback and reconnection can be tested in CI. Several consoles also have
  free offline editors (MA3 onPC, Eos Nomad, MagicQ PC, X32-Edit, Yamaha
  editors, A&H Director) that can stand in for the real thing on a laptop.

### 8.2 What to support first (small live events)

Weighted by how often each appears at small events and how open its protocol is:

1. **Audio:** Behringer X32/M32 and X Air/MR (very common, OSC, well documented);
   Allen & Heath SQ, Qu, CQ (documented MIDI-TCP); Yamaha TF and DM3 (RCP);
   Soundcraft Ui (very common at small venues, undocumented WebSocket).
2. **Lighting:**
   - **Direct DMX over Art-Net/sACN.** The most common small-event case has no
     console, and Show Deck can drive DMX itself over Art-Net.
   - Then ChamSys MagicQ (free PC version widely used), grandMA3 onPC, Onyx,
     ETC Eos and QLC+.
3. **Later:** dLive/Avantis, Wing native, Avolites Titan, Hog, DiGiCo.

### 8.3 Prior art worth studying

- **Mixing Station:** one app covering most mixer families. Proof the audio
  half is feasible, and a benchmark for UX and per-mixer setup guides.
- **Bitfocus Companion:** the best model for a driver/plug-in architecture
  (connections, actions, feedbacks, variables) across hundreds of devices,
  lighting and audio alike. Open source.
- **TouchOSC / Open Stage Control / OSC/PILOT:** generic surfaces. Show what
  users build when there's no dedicated app, and where generic OSC falls short
  (no fader laws, no names, no subscriptions).

---

## 9. Lessons from the first prototype

The earlier prototype was written before this research. It got
OSC and the dLive message formats broadly right, but:

- it had the **dLive ports swapped**: the MixRack is 51325 and the Surface 51328
  **[doc]**;
- it hard-coded each console straight into the UI, with no common control
  model, so adding a third console meant new screens;
- it had no rate limiting, no "set" vs "toggle" discipline and no initial-sync
  gating, all of which section 6 calls for.

It has been replaced by Show Deck (this repository), which follows section 8.
While building it, the open-source Bitfocus Companion modules for X32, X Air,
SQ, dLive and Yamaha RCP settled several of the questions below. They also
showed that the X32 doesn't echo a client's own changes back to it over
`/xremote`; only changes from elsewhere come back.

## 10. Open questions to settle on hardware

- grandMA3: the exact OSC feedback format, the Fader Range default, and Key semantics.
- Eos: whether fader bank config must be re-sent per page; master fader address.
- X32 and X Air: how `/xremote` behaves with several clients at once.
- MagicQ: the playback button addresses (`/pb/<n>/go`, `/stop`, `/flash`).
- Yamaha RCP: DM7 scene recall (text scene numbers); exact strip counts per model.
- Soundcraft Ui message set per firmware.

## Sources

- grandMA3 OSC remote inputs: https://help.malighting.com/grandMA3/2.3/HTML/remote_inputs_osc.html
- grandMA3 OSC with Open Stage Control: https://help.malighting.com/grandMA3/2.3/HTML/osc_open_stage_control.html
- grandMA3 SendOSC keyword: https://help.malighting.com/grandMA3/2.3/HTML/keyword_sendosc.html
- grandMA2 telnet: https://help.malighting.com/grandMA2/en/help/key_remote_control_telnet.html
- ETC Eos OSC over TCP port: https://support.etcconnect.com/ETC/Consoles/Eos_Family/Software_and_Programming/TCP_port_for_OSC_communication_with_Eos_Software
- ETC Eos OSC setup: https://www.etcconnect.com/WebDocs/Controls/EosFamilyOnlineHelp/en/Content/23_Show_Control/08_OSC/Using_OSC_with_Eos/Eos_OSC_Setup.htm
- Eos fader bank discussion: https://community.etcconnect.com/control_consoles/eos-family-consoles/f/eos-family-show-control-support-midi-smpte-osc-rtc-etc/34682/linking-faders-oscalculator/173165
- Eos MSC formatting: https://www.etcconnect.com/WebDocs/Controls/EosFamilyOnlineHelp/en/Content/23_Show_Control/05_MIDI_Show_Control/Hexadecimal_MIDI.htm
- ChamSys MagicQ OSC: https://docs.chamsys.co.uk/magicq/manual/OSC.html
- ChamSys MagicQ UDP remote: https://secure.chamsys.co.uk/help/documentation/magicq/udp.html
- Avolites WebAPI: https://api.avolites.com/19.2 and https://avosupport.de/wiki/webapi/requests/playbacks_setplaybacklevel
- Obsidian Onyx telnet and UDP: https://support.obsidiancontrol.com/Content/Onyx_Manual/Networking/Telnet_and_UDP_Commands.htm
- Hog 4 OSC mappings: https://www.etcconnect.com/webdocs/Controls/HOG/HTML/en/sect-osc_mappings.htm
- Hog 4 PC OSC limits: https://support.etcconnect.com/HES/Consoles/Hog_4/Software_and_Programming/OSC_control_of_buttons,_faders,_and_encoders_in_Hog_4_PC_are_not_working
- dLive MIDI over TCP V2.0: https://www.allen-heath.com/content/uploads/2024/06/dLive-MIDI-Over-TCP-Protocol-V2.0.pdf
- dLive V1.9: https://www.allen-heath.com/content/uploads/2023/05/dLive-MIDI-Over-TCP-Protocol-V1.9.pdf
- dLive rate limiting thread: https://community.allen-heath.com/?p=106374
- Bitfocus dLive module: https://bitfocus.io/connections/allenheath-dlive
- SQ MIDI protocol: https://www.allen-heath.com/content/uploads/2023/11/SQ-MIDI-Protocol-Issue5.pdf and https://support.allen-heath.com/hc/en-gb/articles/47793537575953-SQ-MIDI-Protocol-Firmware-V2-0-3
- Allen & Heath for IT managers: https://support.allen-heath.com/hc/en-gb/articles/37287399691409-Allen-Heath-for-IT-managers
- Yamaha RCP (unofficial docs): https://github.com/BrenekH/yamaha-rcp-docs
- Yamaha RCP Chataigne module: https://github.com/vk0eppel/Yamaha-RCP-Chataigne-Module
- Yamaha MTX/MRX RCP spec: https://usa.yamaha.com/files/download/other_assets/3/331593/MTX3_MTX5-D_RemoteCtrlProtocolSpecs_v101_en.pdf
- Yamaha RCP on QLab list: https://groups.google.com/g/qlab/c/58GRL5iGeDc
- Yamaha Python templates: https://dk.yamaha.com/da/news_events/all/?p=80
- X32 fader law (pmaillot): https://behringer.world/viewtopic.php?p=11070 and https://openstagecontrol.discourse.group/t/mapping-float-value-to-frequency-hz-or-db/1249
- X32 /xremote: https://behringer.world/viewtopic.php?p=10236 and https://www.behringer.world/viewtopic.php?p=8815
- Patrick-Gilles Maillot X32 docs: https://sites.google.com/site/patrickmaillot/x32
- Wing remote protocols: https://cdn.mediavalet.com/aunsw/musictribe/M7u1XZvRGkWxJAVwCKE5BA/7qQ-l43rn0SEnqyb5ZcETg/Original/WING%20Remote%20Protocols_V3.0.6-30.pdf
- Wing OSC subscription: https://behringer.world/viewtopic.php?p=1735
- libwing: https://docs.rs/crate/libwing/0.2.0
- Soundcraft Ui websocket thread: https://proforums.harman.com/soundcraft/discussion/comment/198833
- DiGiCo generic OSC: https://digico.biz/digico-opens-up-the-sd-range-with-generic-osc-control/
- FADER_X (DiGiCo OSC notes): https://github.com/stagehacks/FADER_X
- Mixing Station: https://apps.apple.com/us/app/mixing-station/id1438352631
- Bitfocus Companion module development: https://companion.free/for-developers/module-development/
- Apple multicast entitlement: https://developer.apple.com/forums/thread/663271
- Bitfocus Companion modules (protocol tables used to check the drivers):
  https://github.com/bitfocus/companion-module-behringer-x32,
  https://github.com/bitfocus/companion-module-behringer-xair,
  https://github.com/bitfocus/companion-module-allenheath-sq,
  https://github.com/bitfocus/companion-module-allenheath-dlive,
  https://github.com/bitfocus/companion-module-yamaha-rcp
