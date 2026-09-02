# Octopus Usage for Omarchy

An [Omarchy shell](https://omarchy.org/) bar widget that tracks AI usage from a
self-hosted [Octopus](https://github.com/bestruirui/octopus) LLM gateway.

The bar shows today's token usage (e.g. `2.4M`); clicking opens a panel with
today / all-time stats and a 14-day cost chart.

## Setup

```bash
omarchy plugin add <this-repo-url> --enable
octopus-usage-config https://your-octopus.example.com <username>
# or pass the password as a third argument
```

`octopus-usage-config` writes `~/.local/state/omarchy/settings/octopus-usage.json`
(mode 600). The password is stored because Octopus auth tokens expire every 30
days — the plugin re-logs-in transparently when a cached token goes stale.

## Behavior

- All HTTP runs through `curl` child processes; the shell process itself
  never makes network connections.
- Refreshes every 5 minutes (configurable via `refreshMinutes` in the state
  file), with exponential backoff (30s → 10m cap) while the gateway is
  unreachable.
- **Left click** opens the dashboard panel · **middle click** forces a
  refresh · **right click** opens the Octopus web UI.
- Credentials and cached tokens live only in the state file; nothing is
  logged.

## Development

```bash
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml
```

Files under `~/.config/omarchy/plugins/io.github.zhruoshui.octopus-usage/`
hot-reload on save.

## License

MIT
