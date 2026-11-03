# Show Deck plugin for grandMA3

Show Deck controls a grandMA3 over plain OSC, which needs nothing installed.
OSC alone can't tell the app executor names, which cue is running, or which
page the desk is on. This small Lua plugin sends those to the app.

## Install

The `ShowDeck` folder here holds the plugin: `ShowDeck.xml` (what MA imports)
and `ShowDeckFeedback.lua` (the code). Copy the whole folder, not just the
files, into the console's plugin library:

| Where | Put the `ShowDeck` folder in |
|---|---|
| USB stick (console or onPC) | `grandMA3/gma3_library/datapools/plugins/` |
| grandMA3 onPC on a Mac | `~/MALightingTechnology/gma3_library/datapools/plugins/` |
| grandMA3 onPC on Windows | `C:\ProgramData\MALightingTechnology\gma3_library\datapools\plugins\` |

Create any folders that don't exist yet. Then, on the console:

1. Open a **Plugins** pool window (add a window › Pools › Plugins).
2. Edit an empty plugin slot and choose **Import**. Or use the Import/Export
   menu and go to Plugins.
3. Pick the drive (the USB stick, or Internal for onPC), choose **Show Deck**,
   and import.

The plugin is saved in your show file from then on.

## Set up OSC

In **Menu › In & Out › OSC**, use the same line the app already uses (line 1
unless you change `OSC_LINE` at the top of the plugin):

- **Destination IP:** the iPad's IP address
- **Port:** the app's port (8000)
- **Prefix:** the app's prefix (`gma3`)
- **Receive** and **Receive Command:** on
- **Send:** on, with the app's **Feedback port** (8001)
- **Enable Input** and **Enable Output**: on

## Run

Tap the plugin in the pool, or type `Plugin "Show Deck"`, to start it. Do the
same again to stop it. The command line says "Show Deck feedback running" or
"stopped".

While it runs, the app shows on each column:

- the executor's name (yours from the app take priority);
- the current and next cue, under the name;
- which keys' playbacks are running (lit);
- faders and knobs moved on the desk.

It also makes the app follow the desk's page, if "Follow desk page" is on in
the app's device settings.

To start it with every show, add `Plugin "Show Deck"` to a startup macro.

## Settings

At the top of the plugin:

| Setting | Default | Meaning |
|---|---|---|
| `OSC_LINE` | 1 | Which OSC line to send with |
| `COLUMNS` | 15 | Executors x01–x15 per row |
| `ROWS` | 1, 2, 3, 4 | Rows to report |
| `INTERVAL` | 0.25 | Seconds between checks |

It only sends what changed, and resends everything every few seconds so a
newly connected iPad catches up.

## Status

The plugin follows the approach of
[MA3_OSC_FEEDBACK](https://github.com/ArtGateOne/MA3_OSC_FEEDBACK) (the
`GetExecutor`, `GetFader` and `HasActivePlayback` calls and the `SendOSC`
format). The cue lookups (`CurrentChild`, `Children`, `ToAddr`) and
`CurrentExecPage` haven't been tried on a console yet. Each is guarded, so
if one isn't available on your software version, that item is just left out.
