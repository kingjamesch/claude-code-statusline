# statusline

A status line for Claude Code that shows which account the session is on and how much of it is left:

```
● home  Fable 5.1  5h 11%  wk 74%  fable 93%  ctx 17%  → cn → spare  resume 00000000-0000-0000-0000-000000000000
```

- `●`, coloured by the worst of the three usage windows: green under 70% used, amber from 70%, red from 90%. The account name follows it in bold.
- The display name of the model the session runs on.
- `5h` and `wk`: the five-hour and seven-day windows, live from the status-line payload. They read `--` while the payload carries no rate limits, which is the case until the session's first API call.
- `fable`: the model-scoped weekly window for the model named in `TRACK` (the label is that name in lower case). The payload does not carry it, so it is read from the account's own `.claude.json`, where the CLI caches usage; `/usage` refreshes the cache. It reads `--` when no such window is cached.
- `ctx`: context window used.
- `→ cn → <account>`: appears once any of the three usage windows reaches 70%, and names the sibling account to hop to next: the one whose tracked window resets soonest, ties broken by most unused, skipping accounts with under 10% left. Unused quota is wiped at the reset, so the soonest-expiring account goes first. Only accounts with cached figures are considered; the script never probes.
- `resume <id>`: the session id, so the conversation can be brought back with `claude --resume <id>` after an unexpected exit. It stays on the same row while it fits `COLUMNS` and drops to its own row otherwise, because a clipped id is useless. With `COLUMNS` unset it stays on the same row.

It never raises: on a bad payload it prints nothing rather than a traceback, because a status line that throws leaves you staring at nothing.

## Install

Copy `statusline.sh` somewhere, keep it executable, and register it in `~/.claude/settings.json` (or in the `settings.json` of each `CLAUDE_CONFIG_DIR` you use):

```json
"statusLine": {
  "type": "command",
  "command": "/path/to/statusline.sh",
  "padding": 0
}
```

Needs Python 3.7 or newer, standard library only. Despite the extension it is a Python script; the shebang does the work.

## Accounts

The script was written for a multi-account layout, hard-coded as `ACCOUNTS`: one directory per account under `~/.claude-accounts/<name>/`, each holding its own `.claude.json` and `.credentials.json`, selected per shell with `CLAUDE_CONFIG_DIR`. The account name is taken from the payload's `transcript_path` when it lies under that directory, then from `CLAUDE_CONFIG_DIR`, then `default`, which reads `~/.claude/.claude.json` or `~/.claude.json`.

With a single account everything still works: the name shows as `default` and the hop hint never appears.

`cn` in the hint is the account-switching command of the setup this was written for. Change the string in `main()` to whatever yours is called.

## Tuning

- `TRACK`: display name of the model whose weekly window is tracked (`Fable`). Set it to the scarce bucket on your plan.
- `WARN`, `CRIT`: the 70 / 90 thresholds.
- `FLOOR`: accounts with less unused than this are never suggested.
- `ACCOUNTS`: where the per-account directories live.

## Check it

```
echo '{"model":{"display_name":"Fable 5.1"},"session_id":"00000000-0000-0000-0000-000000000000","rate_limits":{"five_hour":{"used_percentage":11},"seven_day":{"used_percentage":64}},"context_window":{"used_percentage":17}}' | ./statusline.sh; echo
```

On a machine with no accounts directory it prints:

```
● default  Fable 5.1  5h 11%  wk 64%  fable --  ctx 17%  resume 00000000-0000-0000-0000-000000000000
```

Renders in about 30 ms. Nothing leaves the machine: it reads the payload on stdin, the current account's `.claude.json`, and, only once a usage window is at 70% or more, the sibling accounts' cached `.claude.json` files.
