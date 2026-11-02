#!/usr/bin/env python3
"""Claude Code status line: which account you are on, and how much of it is left.

Reads the status-line JSON on stdin. The payload carries the five-hour and
weekly windows live, but NOT the per-model weekly window, so the model-scoped
figure (the one worth watching when a plan caps one model separately) is read from the account's
own cachedUsageUtilization on disk, which the CLI keeps current for free.

The session id is shown too (``resume <id>``) so the conversation can be
brought back by hand with ``claude --resume <id>`` after an unexpected exit.

Never raises: a status line that throws leaves the user staring at nothing.
"""
import json, os, re, sys

HOME = os.path.expanduser("~")
ACCOUNTS = os.path.join(HOME, ".claude-accounts")
WARN, CRIT = 70.0, 90.0
G, Y, R, D, B, X = "\033[32m", "\033[33m", "\033[31m", "\033[90m", "\033[1m", "\033[0m"
TRACK = "Fable"          # the model-scoped weekly window to track; set to the scarce bucket on your plan
FLOOR = 10.0             # accounts with less unused than this are never suggested
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def visible_len(s):
    return len(ANSI.sub("", s))


def tone(pct):
    if pct is None:
        return D
    return R if pct >= CRIT else (Y if pct >= WARN else G)


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def account_from(payload):
    """Derive the account from transcript_path, which is always present and
    authoritative. Falls back to the env var, then to the default account."""
    tp = payload.get("transcript_path") or ""
    marker = ACCOUNTS + os.sep
    if tp.startswith(marker):
        return tp[len(marker):].split(os.sep)[0]
    cfg = os.environ.get("CLAUDE_CONFIG_DIR", "")
    if cfg.startswith(marker):
        return cfg[len(marker):].split(os.sep)[0]
    return "default"


def config_path(account):
    if account == "default":
        for p in (os.path.join(HOME, ".claude", ".claude.json"), os.path.join(HOME, ".claude.json")):
            d = read_json(p)
            if d and isinstance(d.get("cachedUsageUtilization"), dict):
                return p
        return os.path.join(HOME, ".claude.json")
    return os.path.join(ACCOUNTS, account, ".claude.json")


def scoped(account, model_name):
    """(percent still unused, reset epoch) for the model-scoped weekly window."""
    d = read_json(config_path(account)) or {}
    cu = d.get("cachedUsageUtilization")
    if not isinstance(cu, dict):
        return (None, None)
    u = cu.get("utilization")
    lims = (u or {}).get("limits") if isinstance(u, dict) else None
    if not isinstance(lims, list):
        return (None, None)
    for lim in lims:
        if not isinstance(lim, dict) or lim.get("kind") != "weekly_scoped":
            continue
        scope = lim.get("scope") if isinstance(lim.get("scope"), dict) else {}
        model = scope.get("model") if isinstance(scope.get("model"), dict) else {}
        name = model.get("display_name") or ""
        if name.lower() == model_name.lower():
            try:
                left = max(0.0, 100.0 - float(lim.get("percent")))
            except (TypeError, ValueError):
                return (None, None)
            reset = None
            try:
                import datetime
                reset = datetime.datetime.fromisoformat(lim.get("resets_at")).timestamp()
            except Exception:
                reset = None
            return (left, reset)
    return (None, None)


def scoped_left(account, model_name):
    return scoped(account, model_name)[0]


def next_account(current):
    """Soonest reset first, then most unused: unused quota is wiped at the reset.
    Cached figures only, never probes."""
    cands = []
    if not os.path.isdir(ACCOUNTS):
        return None
    for name in sorted(os.listdir(ACCOUNTS)):
        d = os.path.join(ACCOUNTS, name)
        if name == current or not os.path.isdir(d):
            continue
        if not os.path.exists(os.path.join(d, ".credentials.json")):
            continue
        left, reset = scoped(name, TRACK)
        if left is not None and left >= FLOOR:
            cands.append((reset if reset is not None else float("inf"), -left, name))
    cands.sort()
    return cands[0][2] if cands else None


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    acct = account_from(payload)
    model = (payload.get("model") or {}).get("display_name") or "?"

    rl = payload.get("rate_limits") or {}
    def used(key):
        blk = rl.get(key) or {}
        v = blk.get("used_percentage")
        try:
            return float(v)
        except (TypeError, ValueError):
            return None
    five, week = used("five_hour"), used("seven_day")

    left = scoped_left(acct, TRACK)
    tracked_used = None if left is None else 100.0 - left

    cw = payload.get("context_window") or {}
    try:
        ctx = float(cw.get("used_percentage"))
    except (TypeError, ValueError):
        ctx = None

    def cell(label, pct):
        return f"{D}{label}{X} {tone(pct)}{'--' if pct is None else format(pct, '.0f') + '%'}{X}"

    known = [p for p in (five, week, tracked_used) if p is not None]
    worst = max(known) if known else None
    bits = [f"{tone(worst)}\u25cf{X} {B}{acct}{X}",
            f"{D}{model}{X}",
            cell("5h", five), cell("wk", week), cell(TRACK.lower(), tracked_used)]
    if ctx is not None:
        bits.append(cell("ctx", ctx))

    if worst is not None and worst >= WARN:
        nxt = next_account(acct)
        if nxt:
            bits.append(f"{Y}→ cn → {nxt}{X}")
    line = "  ".join(bits)

    # The session id, so the conversation can be resumed by hand:
    #   claude --resume <id>      (any account sharing the session store can resume it)
    # Same row when it fits, its own row underneath when it does not: the row
    # is clipped at the terminal edge and the id is useless when cut short.
    sid = payload.get("session_id") or ""
    if sid:
        tag = f"{D}resume{X} {sid}"
        try:
            cols = int(os.environ.get("COLUMNS") or 0)
        except ValueError:
            cols = 0
        if cols and visible_len(line) + 2 + visible_len(tag) > cols:
            line += "\n" + tag
        else:
            line += "  " + tag
    sys.stdout.write(line)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
