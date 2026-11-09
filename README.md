# Show Deck (iPhone and iPad)

One app to run the lights and the sound at a small event. It talks directly
to your mixer and your lighting console over the network, or drives DMX
itself when there's no lighting console. It's built on the design in
[docs/remote-control-research.md](docs/remote-control-research.md).

## What it controls

### Sound

| Mixer | Protocol | Faders and mutes | Processing (tap a strip's name) | Gain on strip | Meters |
|---|---|---|---|---|---|
| Behringer X32 / Midas M32 | OSC, UDP 10023 | Inputs, aux ins, FX returns, buses, matrices, DCAs, mains, mute groups | Inputs: trim, phase, high-pass, gate (mode, threshold, range, times), compressor (mode, ratio, knee, times, make-up, mix, detector, envelope, auto), 4-band parametric EQ with band types, pan and all 16 bus sends. Buses, matrices, mains: compressor and 6-band EQ | Preamp (local input n) | Inputs |
| Behringer X Air / Midas MR | OSC, UDP 10024 | Inputs, aux in, FX returns and sends, buses, DCAs, main, mute groups | The same as the X32 (no trim), with 6 bus sends; buses and main: compressor and 6-band EQ | Preamp | Inputs, buses, main |
| Behringer Wing (Full, Compact, Rack) | OSC, UDP 2223 | Channels, aux ins, buses, matrices, DCAs, mains, mute groups | Channels: trim, phase, phantom, low/high-cut with slope, gate (GATE model), compressor (COMP model), STD EQ (shelf/peak low and high bands plus 4 parametric), pan and 16 sends. Buses, matrices, mains: compressor and 8-band EQ | Input gain | – |
| Allen & Heath SQ | MIDI over TCP 51325 | Inputs, FX returns and groups (to LR), mixes, FX sends, matrices, DCAs, LR, mute groups | Not in SQ's MIDI protocol | – | – |
| Allen & Heath dLive / Avantis | MIDI over TCP: MixRack 51325, Surface 51328 | Every strip type | High-pass, 4-band parametric EQ with types and widths (inputs). No gate or compressor over MIDI | Preamp (MixRack socket n) | – |
| Yamaha TF / DM3 / CL / QL / DM7 | RCP text over TCP 49280 | Inputs, stereo inputs, FX returns, mixes, matrices, DCAs, stereo | Whatever the console reports: EQ bands, gate, compressor, high-pass | Head amp, where reported | Inputs (pre-fader) and outputs |

**Parametric EQ:** every EQ is drawn as a curve. Drag a band's point left and
right for frequency, up and down for gain, and pinch for Q or width. Each
band's exact values and type are listed below the curve.

Every mixer also does scene recall, reads channel names (not SQ), and follows
changes made at the desk.

Yamaha consoles name and scale their processing differently from family to
family, so after connecting the app asks the console for its parameter list
and builds the controls from what it says.

### Lights

| Console | Protocol | Strips | Buttons and tools | Reads back |
|---|---|---|---|---|
| grandMA3 | OSC, UDP (8000) | Executor columns on a page: the 1xx key under the fader, the 2xx fader and key, and the 3xx/4xx knobs and keys (you choose which rows) | Keys do what they do on the desk, or a fixed Go+, Go−, Toggle, On, Off, Top or Select. Cue tools: Go+, Go−, go to cue, set cue fade, update cue. Page, command line | With the [Show Deck plugin](MA3/README.md): names, running keys, current and next cue, faders, the desk's page |
| ChamSys MagicQ | OSC, UDP (8000 in, 9000 out) | Playbacks 1–10 | Go, Stop, Flash | Playback levels, when TX is set |
| Lighting (the desktop console in nickskull03/lighting) | Its WebSocket API, ws://host:8080/ws | The ten faders of the page it's on, every sequence in the show, and the grand master | Go, Off, Flash, Blackout. Cue tools: Back, Pause, go to cue, set cue fade, store cue. Page, command line | Sequence names, levels, running and next cue, page, grand master, blackout, and its error messages |
| ETC Eos family | OSC over TCP 3032 | An OSC fader bank | Fire, Stop, Go, Stop/Back, fader pages. Go to cue, set cue time, update cue, command line | Levels, names, active and pending cue |
| Lights direct | Art-Net to a node's IP | One fader per DMX channel, plus a master | Blackout | (the app is the source) |

### Key panels

Every lighting console except Lights direct has a key panel: switch a
pane from **Faders** to **Keys** at the top. To see faders and keys together,
choose two panes in the layout menu, pick the same console in both, and
switch one of them to Keys.

| Console | How the keys work |
|---|---|
| grandMA3 | MA takes whole command lines over OSC, not key presses. So the keys (objects, functions, At/Thru/Full, the number pad) build the line in the app, where you can see it, and **Please** sends it to `/cmd`. Go+, Go−, Pause, Highlight, Blind, Freeze, Oops and Clear All act straight away. **Clear** empties the app's line; tap it again on an empty line to send MA's own Clear. |
| Lighting | The same way as grandMA3, with its own keywords. Enter sends the line. Go, Back, Pause, Highlight, Oops and Clear All act straight away. |
| ETC Eos | Each key is pressed and released on Eos itself (`/eos/key/<name>`), on the app's OSC user's command line. Eos reports the command line back and the app shows it above the keys. |
| ChamSys MagicQ | One row per playback (1–10): Go, Stop, fast back, fast forward, activate, release, through MagicQ's remote protocol on `/rpc`. Jump to a cue from Commands (`2 5` is cue 5 on playback 2). |

### Customising strips

Tap a strip's name to open its detail. There you can:
- give the strip your own name and colour;
- on grandMA3, choose what each key does;
- set its processing or use its cue tools.

Names and colours are saved with the device.

### Lights only, sound only

In **Devices**, the menu at the top right switches between **Lights & Sound**,
**Lights only** and **Sound only**. The other half disappears from the Desk,
the device list, adding devices and the cue editor, and its devices
disconnect.

**Desk tab:** one or two panes. The layout button at the top right chooses:
- **Automatic:** two panes when there's room, one on phone-sized screens;
- **One pane**;
- **Two side by side**;
- **Two, one above the other**.

Each pane's menu chooses what it shows: any device, or the **custom layer**.
Panes keep their choice when you fold, unfold or rotate.

**Custom layer:** a page of your own, with strips from any devices: mixer
channels next to lighting sequences and executors. Each strip is labelled
LIGHTS or SOUND, with its device's name. To add a strip, tap its name on any
device and turn on **On the custom layer**. **Edit** reorders or removes
strips. The layer can show all of them, or just lights or sound.

**Cues tab:** big buttons that each do several things across devices, like
"Speech" (podium light up, lectern mic on) or "Walk-in". You can ask to
confirm before a cue runs.

**Devices tab:** add a console, and each one shows the steps to set it up on
the desk.

## How it behaves

These follow section 6 of the research notes:

- **The desk is the source of truth.** On connect the app reads every level,
  mute and name, and keeps the controls locked ("Reading desk…") until it has.
  It never pushes stored values to a console.
- **Touch wins.** While your finger is on a fader, the console's reports for
  that fader are ignored. Echoes arriving just after you let go are ignored
  too, so the fader doesn't snap back.
- **Throttled moves.** Fader drags go out at most about 30 times a second, and
  the final position always gets sent.
- **No toggles on the wire.** Mutes are always sent as "mute on" or "mute off".
- **Confirmation** for scene recalls, mains mutes and blackouts.
- **Reconnects.** A dropped connection is retried with backoff (1 s up to
  10 s). Coming back from the background reconnects and re-reads the desk.
- **Honest status.** The badge shows Online, Sending (for protocols that
  can't confirm anything), Reading desk… or the error. If a console can't
  report desk changes, the app says so under its faders.
- **Screen stays on** while anything is connected.
- **Interruptions don't leave a fader stuck.** If a touch is cancelled
  (a call comes in, you fold the phone, the layout changes under your
  finger), the fader lets go, its last position is sent, and it follows the
  desk again.

## Build and run

Needs iOS/iPadOS 17 or later. Use the newest Xcode from the App Store: Xcode
can only install on iOS versions it knows, and the iPhone Duo ships with iOS 27.

1. Open `ShowDeck.swiftpm` in Xcode. It pulls in `ShowKit` from
   the folder next to it.
2. Pick your iPhone or iPad as the run destination, set your team under
   *Signing & Capabilities*, and press Run.
3. Allow Local Network access when iOS asks, or nothing gets through.

Run the engine's tests on a Mac:

```sh
cd ShowKit
swift test
```

The tests use a fake transport that records what each driver sends and plays
back what the console would answer. No hardware or network needed.

## Layout

```
ShowKit/                      the engine: no UI, unit-tested
  Model/       Controls (control IDs, values, strips), AudioTaper (the fader law),
               DeviceKind (the consoles and their setup steps), DeviceConfig,
               Device (sync gating, touch lock, throttling, reconnects), Show (devices, cues, saving)
  Codecs/      OSC (and OSC-over-TCP framing), MIDI stream parser and NRPN, text lines, Art-Net
  Transport/   Transport protocol; UDP and TCP on Apple's Network framework
  Drivers/     one per console family, behind ConsoleDriver
ShowDeck.swiftpm/             the SwiftUI app
MA3/                          the grandMA3 plugin that sends names and cues to the app
```

Adding a console means writing a `ConsoleDriver`: it declares its strips,
controls and processing sections, translates `ControlValue`s to and from the
wire, and reports values, meters and state.
The UI, cues, sync and timing work for it without changes.

## Where the protocol details come from

Mixer messages were checked against the manufacturers' documents where
reachable, and against the Bitfocus Companion modules for these consoles
(X32, X Air, SQ, dLive, Yamaha RCP), which are used at shows every day.
Yamaha's paths and counts come from the consoles' own parameter dumps.

Still to confirm on real hardware:
- Wing: the low-cut frequency range, and replies to every query arriving as
  ",sff" (the app also reads a single number or text);
- X32 meters (the layout of `/meters/1` on the X32, as opposed to X Air);
- Yamaha meter scaling (0–127 is drawn as-is) and which consoles answer `prminfo`;
- grandMA3: OSC control of the 3xx/4xx knobs (sent as `Fader3nn`), and the
  plugin's cue lookups;
- MagicQ button addresses (`/pb/<n>/go`, `/stop`, `/flash`);
- Eos key and fire addresses (`/key/go_0`, `/fader/1/<n>/fire`), and the
  key panel's key names (`chan`, `at`, `copy_to`, `rem_dim`, `clear_cmd`,
  `stop_back`, …), and the command line arriving as `/eos/out/cmd`;
- MagicQ's `/rpc` remote commands (`1G`, `1S`, `1B`, `1F`, `1A`, `1R`, `1,5J`);
- grandMA3 keywords sent bare from the panel (`Go+`, `Highlight`, `Blind`,
  `Freeze`) acting on the selected executor or toggling;
- grandMA3's own (non-plugin) feedback format;
- channel counts on smaller Yamaha models (strips a model lacks just don't answer);
- DM7 scene recall (not offered yet).

## Connecting to the Lighting console

The Lighting desktop app only listens on its own computer. To control it from
an iPad, run the console with `npm start -- --host 0.0.0.0` in the lighting
repository, and enter that computer's IP and port 8080 in Show Deck. There's
no login, so only do this on a network you trust.
