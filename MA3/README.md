# Show Deck plugin for grandMA3

Show Deck controls a grandMA3 over plain OSC, which needs nothing installed.
OSC alone can't tell the app executor names, which cue is running, or which
page the desk is on. This small Lua plugin sends those to the app.

Written for **grandMA3 2.5**.

## The files

- [`ShowDeck.xml`](ShowDeck.xml): what grandMA3 imports. It names the Lua file.
- [`ShowDeck.lua`](ShowDeck.lua): the plugin's code.

Both are needed, side by side.

## Install

**1. Copy both files** straight into the plugins folder: not into a
subfolder.

| Running MA on… | Put `ShowDeck.xml` and `ShowDeck.lua` in |
|---|---|
| A console, from a USB stick | `grandMA3/gma3_library/datapools/plugins/` on the stick (a stick the console formatted has a `grandMA3` folder; otherwise use `gma3_library/datapools/plugins/` at the top of the stick) |
| grandMA3 onPC on a Mac | `~/MALightingTechnology/gma3_library/datapools/plugins/` |
| grandMA3 onPC on Windows | `C:\ProgramData\MALightingTechnology\gma3_library\datapools\plugins\` |

Create any folders that don't exist yet. For a console, plug the stick in.

**2. Import it** by typing this on the command line, using an empty plugin
slot number (here 1):

```
Import Plugin Library "ShowDeck" At Plugin 1 /nc
```

A plain `Import` makes an **empty** plugin. It has to be the `Plugin Library`
form above. The plugin is saved in your show from then on.

## Set up OSC

In **Menu › In & Out › OSC**, use the same line the app already uses (line 1
unless you change `OSC_LINE` at the top of the plugin):

- **Destination IP:** the iPad's IP address
- **Port:** the app's port (8000)
- **Prefix:** the app's prefix (`gma3`)
- **Receive** and **Receive Command:** on
- **Send:** on
- **Enable Input** and **Enable Output**: on

An OSC line uses **one port for both directions**, so MA sends to the iPad on
port 8000 too. In the app's grandMA3 device settings, **Feedback port** must be
**8000**, the same as the line's port. Devices added before this fix have 8001
there; change it to 8000.

## Run

```
Call Plugin 1
```

or tap it in the Plugins pool. The command line says "Show Deck feedback
running". Run it again to stop it ("stopped").

While it runs, the app shows on each column:

- the executor's name (yours from the app take priority);
- the current and next cue, under the name;
- which keys' playbacks are running (lit);
- faders and knobs moved on the desk.

It also makes the app follow the desk's page, if "Follow the desk's page" is
on in the app's device settings.

To start it with every show, put `Call Plugin 1` in a startup macro.

## Settings

At the top of `ShowDeck.lua`:

| Setting | Default | Meaning |
|---|---|---|
| `OSC_LINE` | 1 | Which OSC line to send with |
| `COLUMNS` | 15 | Executors x01–x15 per row |
| `ROWS` | 1, 2, 3, 4 | Rows to report |
| `INTERVAL` | 0.25 | Seconds between checks |

It only sends what changed, and resends everything every few seconds so a
newly connected iPad catches up.

## If it doesn't work

- **The plugin is empty after importing:** use `Import Plugin Library …` as
  above, and check both files are directly in `datapools/plugins`.
- **"Show Deck feedback running" appears but the app shows nothing:** check
  the app's Feedback port matches the OSC line's port (8000), the line's Send
  is on, its Destination IP is the iPad's, and Enable Output is on.
- **Names show but no cues:** tell us your exact MA version. The plugin reads
  the sequence's CueNo, CueName and CurrentCue properties, as grandMA3 2.5 has them.

## Status

Built against grandMA3 2.5.1's Lua API and object properties (as published
with the [grandma-devkit](https://github.com/badasslighting/grandma-devkit)
VS Code extension, which was checked on onPC 2.5.1.0), and the approach of
[MA3_OSC_FEEDBACK](https://github.com/ArtGateOne/MA3_OSC_FEEDBACK). Tested
against a simulated console; not yet on a real one.
