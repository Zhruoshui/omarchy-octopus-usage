# Octopus Usage for Omarchy

An [Omarchy shell](https://omarchy.org/) bar widget for
[Octopus](https://github.com/bestruirui/octopus) — the self-hosted LLM API
gateway. If you run Octopus to pool and proxy your AI provider keys, this
plugin puts your usage on your bar.

- **Bar pill**: today's total tokens, e.g. `2.4M` (`!` on errors, `…` while loading)
  — the metric is configurable (tokens / cost / requests)
- **Panel**: today / all-time cost, requests, success rate, input & output
  tokens, cumulative wait time, and a 14-day bar chart measuring cost or
  tokens (configurable). An always-visible **DISPLAY** box at the panel bottom
  switches both; the choices persist in the state file.
## How it works

The widget talks to your Octopus instance's stats API
(`/api/v1/stats/hourly`, `/stats/total`, `/stats/daily` — 0.13.x replaced
`/stats/today` with per-hour rows, summed client-side). Nothing is inferred
or guessed — every number on screen comes straight from Octopus.

All HTTP runs through `curl` child processes; the Quickshell process itself
never makes network connections. Credentials live only in a mode-600 state
file, and nothing is ever logged.

Octopus auth tokens expire after 30 days, so the config file keeps your
password on disk and the plugin re-logs-in transparently when a cached token
goes stale.

## Setup

```bash
omarchy plugin add https://github.com/Zhruoshui/omarchy-octopus-usage.git --enable

# Configure access to your Octopus instance (script lives inside the plugin
# dir; omarchy plugin add does not put it on PATH):
~/.config/omarchy/plugins/io.github.zhruoshui.octopus-usage/octopus-usage-config \
  https://your-octopus.example.com <username>
# or pass the password as a third argument:
~/.config/omarchy/plugins/io.github.zhruoshui.octopus-usage/octopus-usage-config \
  https://your-octopus.example.com <username> <password>

# Optional: make the command available by name:
ln -s ~/.config/omarchy/plugins/io.github.zhruoshui.octopus-usage/octopus-usage-config ~/.local/bin/
```

`octopus-usage-config` writes
`~/.local/state/omarchy/settings/octopus-usage.json` (mode 600). You need a
working Octopus deployment first — see the
[Octopus docs](https://github.com/bestruirui/octopus) to set one up.

## Behavior

- Refreshes every 5 minutes (configurable via `refreshMinutes` in the state
  file), with exponential backoff (30s → 10m cap) while the gateway is
  unreachable.
- **Left click** opens the dashboard panel · **middle click** forces a
  refresh · **right click** opens the Octopus web UI.
- `wait_time` is reported by Octopus in cumulative milliseconds per request;
  the panel shows the human-readable total.

## Development

```bash
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml
```

Saving a file under `~/.config/omarchy/plugins/io.github.zhruoshui.octopus-usage/`
did not hot-reload the running shell in testing: it kept executing the
previous code while the widget's IPC target still answered, so a quick
"it loaded" check is misleading. Apply plugin changes with
`omarchy restart shell`.

## Credits & License

- Usage data and stats API: [Octopus](https://github.com/bestruirui/octopus)
  by [bestruirui](https://github.com/bestruirui) — this plugin is an
  independent client and is not affiliated with that project.
- Widget code: MIT, see [LICENSE](LICENSE).
