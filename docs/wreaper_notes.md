# wreaper operational notes

## Build and deployment

```
swift build -c release
scripts/sign.sh
codesign --verify --strict --verbose=4 .build/release/wreaper
cp .build/release/wreaper ~/Documents/dev/utils
```

## Other useful

```
bat ~/Library/Application\ Support/windowless-reaper/state.json
cp ~/.config/windowless-reaper/config.toml ./example_config.toml
zed ~/.config/windowless-reaper/config.toml
bat ~/.config/windowless-reaper/config.toml
```

## Run commands

```
wreaper run --log-level debug
wreaper check
wreaper clear
wreaper config scaffold
```

## Accessibility permission

`wreaper` needs the macOS Accessibility grant because visibility checks and
polite termination both go through APIs guarded by TCC.

Grant it once in the GUI:

1. Open `System Settings`.
2. Go to `Privacy & Security`.
3. Open `Accessibility`.
4. Add the exact on-disk `wreaper` binary path you intend to run, for example
   `/usr/local/bin/wreaper`.

Verify from the command line:

```
wreaper permissions check
```

That command is the CLI-side confirmation point. macOS does not expose a
supported CLI or API to grant Accessibility permission directly, so grant is
GUI-managed and verification is command-line.

If you replace the binary in place and keep the same code-signing identifier,
the existing Accessibility grant should remain valid. This is why the release
flow signs with a stable identifier before install/update.

## First-time daemon install

Use this flow when setting up the persistent `launchd` daemon for the first
time.

### 1. Build and sign

```
swift build -c release
scripts/sign.sh
codesign --verify --strict --verbose=4 .build/release/wreaper
```

### 2. Copy to the stable install path

Pick one path and keep using it. The Accessibility grant is tied to the exact
binary path, so avoid moving the installed binary around between updates.

Examples:

```
cp .build/release/wreaper /usr/local/bin/
```

or

```
cp .build/release/wreaper "$(brew --prefix)/bin/"
```

### 3. Grant Accessibility to that exact path

In `System Settings -> Privacy & Security -> Accessibility`, add the installed
binary path, for example `/usr/local/bin/wreaper`.

### 4. Verify permission from the CLI

```
wreaper permissions check
```

### 5. Install and load the LaunchAgent

```
wreaper install --user
```

If you installed the binary somewhere non-default, tell the installer which
prefix to use:

```
wreaper install --user --prefix /opt/homebrew
```

### 6. Verify the daemon is live

```
launchctl print gui/$(id -u)/com.user.windowless-reaper
tail -F ~/Library/Logs/windowless-reaper.log
```

The log file is the authoritative runtime output when running under
`launchd`.

## Updating the daemon after a rebuild

Use this flow after rebuilding `wreaper` and wanting the already-installed
daemon to pick up the new binary.

### 1. Rebuild and sign the new binary

```
swift build -c release
scripts/sign.sh
codesign --verify --strict --verbose=4 .build/release/wreaper
```

### 2. Replace the installed binary in place

Replace the existing binary at the same path you originally granted in
Accessibility settings.

Examples:

```
cp .build/release/wreaper /usr/local/bin/
```

or

```
cp .build/release/wreaper "$(brew --prefix)/bin/"
```

### 3. Restart the loaded LaunchAgent

`launchd` keeps the old inode open until you bounce the job.

```
launchctl kickstart -k gui/$(id -u)/com.user.windowless-reaper
```

If you used a custom label, use the exact label printed by `wreaper install`.

### 4. Verify the updated daemon

```
launchctl print gui/$(id -u)/com.user.windowless-reaper
tail -n 50 ~/Library/Logs/windowless-reaper.log
```

If the install path and code-signing identifier remain stable, you should not
need to re-grant Accessibility after an update.

## Memory load

```
footprint wreaper
```

Or updating every minute

```
PID=$(pgrep -f "/usr/local/bin/wreaper run")
while sleep 60; do
  printf '%s  ' "$(date '+%Y-%m-%d %H:%M:%S')"
  ps -o rss=,vsz=,pagein=,time=,etime=,%cpu= -p $PID
done | tee /tmp/wreaper-watch.log
```

## CPU

```
top -pid $(pgrep -f "/usr/local/bin/wreaper run") -stats pid,command,cpu,time,mem,state
ps -o pid,%cpu,time,etime -p $(pgrep -f "/usr/local/bin/wreaper run")
```

## LOG

```
tail -F ~/Library/Logs/windowless-reaper.log
bat ~/Library/Logs/windowless-reaper.log
```

## Installing as background task

The first-time install and update procedures above are the authoritative
workflow. This section keeps the low-level reference details in one place.

Install as a per-user LaunchAgent, starts automatically on login:

```
sudo install -m 0755 ~/Documents/dev/utils/wreaper /usr/local/bin/wreaper
wreaper install --user --prefix /usr/local
wreaper uninstall --user
```

inspect status: `launchctl print gui/501/com.user.windowless-reaper`

Installation path resolution order (InstallPathResolver.swift:12):

1. `--prefix <path>` if passed
2. `$HOMEBREW_PREFIX/bin/wreaper` if that env var is set in the shell running install
3. `/usr/local/bin/wreaper` fallback

Inspect runtime status anytime with `launchctl print gui/$(id -u)/<label>` (the exact label is printed by the install command).

After replacing the binary you need to bounce the agent so launchd re-execs the new copy (the running process keeps the old inode):

```
launchctl kickstart -k gui/$(id -u)/<label>
```

The exact label is what wreaper install printed (LaunchAgentPlist.label).

Updating the daemon is the same binary replacement flow followed by a
`launchctl kickstart -k ...` bounce. If you keep the same install path and a
stable signing identifier, you should not need to re-grant Accessibility.

## Logs (when installed as a task)

```
~/Library/Logs/windowless-reaper.log
```

Bounded/rotating — owned by the daemon's RotatingFileLogHandler, not launchd. Launchd's own stdout/stderr are deliberately discarded to /dev/null, so don't bother looking for .out/.err files.

Tail it with:

```
tail -F ~/Library/Logs/windowless-reaper.log
```

### File: App log
Path: ~/Library/Logs/windowless-reaper.log (+ .log.1 backup)
Size-limited: Yes — rotated at 5 MiB (LogLevelBootstrap.defaultLogRotateBytes), one backup generation, so worst-case ~10 MiB on disk (RotatingFileLogHandler.swift:13)

### File: Launchd stdout/stderr
Path: /dev/null
Size N/A — discarded; daemon owns its own log (LaunchAgentPlist.swift:14)

### File: Checkpoint state
Path: ~/Library/Application Support/windowless-reaper/state.json
No explicit cap — single atomic JSON, bounded only by the tracker's entry count (one per allowlisted bundle), so effectively a few KB

### File: Config
Path: ~/.config/windowless-reaper/config.toml
User-owned, not written by daemon

### File: LaunchAgent plist
Path: ~/Library/LaunchAgents/com.user.windowless-reaper.plist
Static, written once by wreaper install

So the only growth-prone file (the log) is bounded; everything else is either discarded, tiny-and-bounded by domain, or user-owned.

## Disabling daemon and autostart

Two-step. bootout alone only stops the current run — at next login the plist in ~/Library/LaunchAgents/ auto-loads again. You need disable to persist the "don't run" decision.

### 1. Mark it disabled (persists across reboots, survives plist reload)
```
launchctl disable gui/$(id -u)/com.user.windowless-reaper
```

### 2. Stop the running instance
```
launchctl bootout gui/$(id -u)/com.user.windowless-reaper
```

### 3. Verify
```
launchctl print-disabled gui/$(id -u) | grep windowless-reaper
```
expect:  "com.user.windowless-reaper" => disabled

```
pgrep -x wreaper && echo "still running" || echo "stopped"
```

Order matters: disable first sets the flag, so when bootout exits the process, KeepAlive=true can't trigger a respawn — the disabled flag wins.

To restart later:

```
launchctl enable gui/$(id -u)/com.user.windowless-reaper
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.windowless-reaper.plist
```

If you want it completely gone (plist removed, not just disabled), use wreaper uninstall --user instead — that deletes ~/Library/LaunchAgents/com.user.windowless-reaper.plist and unloads the job in one shot. The binary at /usr/local/bin/wreaper and the Accessibility grant are left in place, so you can reinstall later without re-doing the GUI dance.
