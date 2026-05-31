# wreaper operator guide

This document is the operational reference for running `wreaper` as either:

- a one-shot CLI tool
- a persistent per-user `launchd` daemon

The README gives the short version. This guide is the step-by-step version.

## Operating modes

`wreaper` supports two distinct workflows:

- One-shot CLI commands: run once, report a result, then exit.
- Persistent daemon mode: run continuously under `launchd` with `KeepAlive`
  and config reload on save.

Use one-shot commands when you want manual verification or explicit
fire-and-exit execution. Use the daemon when you want continuous background
reaping.

## Accessibility permission

`wreaper` needs the macOS Accessibility grant. The grant is required for the
window visibility checks and polite termination path used by the engine.

### Granting permission

macOS does not expose a supported CLI for granting Accessibility access, so the
grant must be done in the GUI:

1. Open `System Settings`.
2. Open `Privacy & Security`.
3. Open `Accessibility`.
4. Add the exact on-disk `wreaper` binary path you intend to run, for example
   `/usr/local/bin/wreaper`.

### Verifying permission

Verify the grant from the command line:

```bash
wreaper permissions check
```

### Path and signing rules

- The Accessibility grant is tied to the installed binary path.
- Keep the installed path stable across updates.
- Keep the code-signing identifier stable across updates.

If both stay stable, replacing the binary in place should not require
re-granting Accessibility.

## One-shot CLI usage

These commands are the primary one-shot entry points:

```bash
wreaper check
wreaper clear
```

Useful supporting commands:

```bash
wreaper run --log-level debug
wreaper permissions check
wreaper config scaffold
wreaper config validate
wreaper config show
```

For first-time config setup, `wreaper config scaffold` is usually the quickest
starting point because it emits starter rules from the currently running apps.

### What each command is for

- `wreaper check`: perform one dry-run evaluation tick and exit.
- `wreaper clear`: terminate allowlisted apps that are currently windowless,
  subject to `clear_cooldown`.
- `wreaper run --log-level debug`: run in the foreground for manual validation.
- `wreaper permissions check`: verify Accessibility state for the installed
  binary path.
- `wreaper config scaffold`: generate a starter config from the current app
  set, then trim it down to the bundle IDs you actually want to manage.

### Recommended config setup flow

```bash
wreaper config init
wreaper config scaffold
wreaper config validate
```

After scaffolding, edit `~/.config/windowless-reaper/config.toml` and remove
any bundle IDs you do not want allowlisted. The scaffold is a starting point,
not a final policy.

## First-time daemon install

Use this procedure when setting up the persistent `launchd` agent for the
first time.

### 1. Build and sign

```bash
swift build -c release
scripts/sign.sh
codesign --verify --strict --verbose=4 .build/release/wreaper
```

### 2. Copy the binary to its stable install path

Pick one install path and keep using it. Do not move between paths across
updates unless you are also prepared to re-check Accessibility.

Example using `/usr/local/bin`:

```bash
cp .build/release/wreaper /usr/local/bin/
```

Example using Homebrew's prefix:

```bash
cp .build/release/wreaper "$(brew --prefix)/bin/"
```

### 3. Grant Accessibility to that exact installed path

Grant permission in `System Settings -> Privacy & Security -> Accessibility`
for the path you installed in step 2.

### 4. Verify Accessibility from the CLI

```bash
wreaper permissions check
```

### 5. Install and load the LaunchAgent

Default install path resolution order:

1. `--prefix <path>` if passed
2. `$HOMEBREW_PREFIX/bin/wreaper` if that environment variable is set in the
   shell running the install command
3. `/usr/local/bin/wreaper`

Install the daemon:

```bash
wreaper install --user
```

If the binary lives under a non-default prefix, pass it explicitly:

```bash
wreaper install --user --prefix /opt/homebrew
```

Useful variants:

```bash
wreaper install --user --print-only
wreaper install --user --force
```

### 6. Verify the agent is running

```bash
launchctl print gui/$(id -u)/com.user.windowless-reaper
tail -F ~/Library/Logs/windowless-reaper.log
```

When running under `launchd`, the file log is the authoritative runtime output.
Do not expect useful `launchd` stdout/stderr files.

## Updating the daemon after a rebuild

Use this procedure after rebuilding `wreaper` and wanting the installed daemon
to pick up the new binary.

### 1. Rebuild and sign the new binary

```bash
swift build -c release
scripts/sign.sh
codesign --verify --strict --verbose=4 .build/release/wreaper
```

### 2. Replace the installed binary in place

Replace the binary at the same installed path you originally granted in
Accessibility settings.

Example using `/usr/local/bin`:

```bash
cp .build/release/wreaper /usr/local/bin/
```

Example using Homebrew's prefix:

```bash
cp .build/release/wreaper "$(brew --prefix)/bin/"
```

### 3. Restart the loaded agent

`launchd` keeps the old inode open until you bounce the job. After replacing
the binary, restart the job:

```bash
launchctl kickstart -k gui/$(id -u)/com.user.windowless-reaper
```

If you are not using the default label, use the exact label printed by
`wreaper install`.

### 4. Verify the updated daemon

```bash
launchctl print gui/$(id -u)/com.user.windowless-reaper
tail -n 50 ~/Library/Logs/windowless-reaper.log
```

If the installed path and code-signing identifier remain stable, you should not
need to re-grant Accessibility after the update.

## Monitoring and inspection

### Log file

Daemon mode writes to:

```text
~/Library/Logs/windowless-reaper.log
```

Useful commands:

```bash
tail -F ~/Library/Logs/windowless-reaper.log
bat ~/Library/Logs/windowless-reaper.log
```

Log behavior:

- Rotating and bounded by the daemon's file logger.
- Rotation threshold is 5 MiB with one backup generation.
- Worst-case on-disk footprint is roughly 10 MiB for `.log` plus `.log.1`.
- `launchd` stdout/stderr are discarded to `/dev/null`.

### Runtime status

Check whether the agent is loaded and inspect its state:

```bash
launchctl print gui/$(id -u)/com.user.windowless-reaper
```

Check whether the process is currently running:

```bash
pgrep -x wreaper
```

### Memory monitoring

Quick snapshot:

```bash
footprint wreaper
```

Rolling sample every minute:

```bash
PID=$(pgrep -f "/usr/local/bin/wreaper run")
while sleep 60; do
  printf '%s  ' "$(date '+%Y-%m-%d %H:%M:%S')"
  ps -o rss=,vsz=,pagein=,time=,etime=,%cpu= -p "$PID"
done | tee /tmp/wreaper-watch.log
```

If your installed path is not `/usr/local/bin/wreaper`, adjust the `pgrep -f`
pattern accordingly.

### CPU monitoring

```bash
top -pid $(pgrep -f "/usr/local/bin/wreaper run") -stats pid,command,cpu,time,mem,state
ps -o pid,%cpu,time,etime -p $(pgrep -f "/usr/local/bin/wreaper run")
```

If your installed path is not `/usr/local/bin/wreaper`, adjust the `pgrep -f`
pattern accordingly.

### State and config files

Checkpoint state:

```text
~/Library/Application Support/windowless-reaper/state.json
```

Config:

```text
~/.config/windowless-reaper/config.toml
```

Useful commands:

```bash
bat ~/Library/Application\ Support/windowless-reaper/state.json
bat ~/.config/windowless-reaper/config.toml
cp ~/.config/windowless-reaper/config.toml ./example_config.toml
```

## Disabling or uninstalling the daemon

### Disable autostart and stop the current run

`bootout` alone only stops the current process. The plist in
`~/Library/LaunchAgents` will still auto-load at next login unless the job is
also disabled.

Disable first:

```bash
launchctl disable gui/$(id -u)/com.user.windowless-reaper
```

Then stop the running instance:

```bash
launchctl bootout gui/$(id -u)/com.user.windowless-reaper
```

Verify:

```bash
launchctl print-disabled gui/$(id -u) | grep windowless-reaper
pgrep -x wreaper && echo "still running" || echo "stopped"
```

The order matters. Disabling first prevents `KeepAlive=true` from immediately
respawning the job after `bootout`.

### Re-enable later

```bash
launchctl enable gui/$(id -u)/com.user.windowless-reaper
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.windowless-reaper.plist
```

### Uninstall completely

```bash
wreaper uninstall --user
```

That removes `~/Library/LaunchAgents/com.user.windowless-reaper.plist` and
unloads the job. The installed binary and Accessibility grant are left in place
so the daemon can be installed again later without repeating the full setup if
the path and signing identity remain unchanged.
