---
name: smoke
description: Run midimend's end-to-end verification battery — unit tests, live foreground run with device checks, --list-devices, and brew-service state. Use before releases, after MIDIIO/Engine changes, or when asked to verify that midimend works.
---

# Midimend smoke test

Run the full check battery and report a pass/fail summary. Continue
through failures so the report is complete; lead with any failure.

1. **Unit tests:** `swift test` — expect all green (count is in the
   output; it should not shrink). This includes the end-to-end battery
   (`EndToEndTests`: spawns the built binary, simulates hot-plug with a
   virtual source) and `EngineReloadTests` — if any of these were
   *skipped* rather than run, that's a failure of this check: skips are
   only for MIDI-less CI, never for this machine.
2. **Build current:** `swift build` (debug is fine for the checks
   below).
3. **Service coexistence:** if `brew services info midimend` says
   Running, stop it first (`brew services stop midimend`) so the
   foreground run doesn't create duplicate virtual ports — and restart
   it at the end regardless of outcome.
4. **Live foreground run:** start
   `.build/debug/midimend examples/config.example.json` in the
   background, wait ~1.5 s, SIGINT it, and check the captured output
   for:
   - `Created virtual input: Midimend In` / `Created virtual output: Midimend`
   - `Created feedback port for: Midimend`, and a `Feedback outputs: …`
     line listing the present (non-ignored) destinations — the example
     config sets `"feedback": "all"`
   - `Connected input: Minilab37 MIDI` when the MiniLab is attached —
     if it isn't, expect instead the warning that lists present inputs
     (that's a pass for the warning path, note it as such)
   - live hot-plug (only when Michael offers to replug the MiniLab;
     the automated `EndToEndTests` already cover the mechanism):
     `MIDI input appeared: …` followed by `Connected input: …`, and
     `MIDI input disappeared: …` on unplug
   - `Script evaluated successfully!`
   - no `[JS Exception]`, no `error:`
5. **Device listing:** `.build/debug/midimend --list-devices
   examples/config.example.json` — the config's hardware entry must be
   annotated `matched by`, or flagged `(nothing matches …)` if the
   device is absent.
6. **Config skeleton:** `.build/debug/midimend --init
   examples/minilab-mainknob.js 2>/dev/null` must emit JSON that
   `python3 -m json.tool` accepts.
7. **Installed service (if brew-installed):** `midimend --version`
   matches the formula version; after restarting the service in step 3's
   cleanup, `/opt/homebrew/var/log/midimend.log` contains the fresh
   startup lines (ports created, script evaluated) — an empty log is a
   regression of the v0.1.0 buffering bug.

Report as a short table: check, result, note. Any failure: quote the
actual output under the table.
