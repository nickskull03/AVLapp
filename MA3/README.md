# Show Deck plugin for grandMA3

Show Deck controls a grandMA3 over plain OSC, which needs nothing installed.
OSC alone can't tell the app executor names, which cue is running, or which
page the desk is on. This small Lua plugin sends those to the app.

## Install

1. On the console (or grandMA3 onPC), open the **Plugins** pool and edit an
   empty plugin.
2. Add a Lua component, and paste in the contents of
   [`ShowDeckFeedback.lua`](ShowDeckFeedback.lua).
3. Name the plugin **Show Deck**.

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

Tap the plugin, or type `Plugin "Show Deck"`, to start it; do it again to stop.
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
