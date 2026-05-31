public enum ConfigSample {
    public static let content = """
    # windowless-reaper configuration
    # Location: ~/.config/windowless-reaper/config.toml

    [settings]
    # How often the engine checks running apps.
    poll_interval     = "30s"       # minimum: 10s

    # Logging verbosity: trace | debug | info | notice | warn | error
    log_level         = "info"

    # When true, decisions are logged but terminate() is never called.
    dry_run           = false

    # Post-terminate cooldown. Prevents reaping auto-relaunched apps.
    # Accepts a multiplier of the app's timeout ("5x") or an absolute duration ("15m").
    default_cooldown  = "5x"

    # Fallback used by any rule written as `timeout = "default"`.
    # Omit to disable the alias (rules using it then become load-time errors).
    default_timeout   = "3m"

    # `wreaper clear` skips any bundle whose newest PID launched within this
    # window — protects apps the user just opened. Default 30s. Minimum 10s.
    clear_cooldown    = "30s"

    # When true, the engine adapts to runtime power pressure:
    #   • doubles `poll_interval` while on battery or in Low Power Mode
    #   • pauses evictions (still observes/logs) when thermal state reaches
    #     `serious` or `critical` — terminating apps under thermal stress
    #     doesn't help the user, and adds load to an already-stressed system
    # Default false. Flip to true once the behaviour is field-tested for
    # your workload.
    adaptive_pressure = false

    # Per-app rules. Keys are CFBundleIdentifier — never display name.
    # Only apps listed here are ever candidates for termination.
    #
    # `timeout = "none"` keeps the entry but never reaps the app. Useful when
    # scaffolding a config from currently-running apps (`wreaper config
    # scaffold`): flip "none" to a real duration to activate a rule.
    # `timeout = "default"` inherits `default_timeout` above.

    # [apps."com.apple.Safari"]
    # timeout = "default"

    # [apps."com.apple.mail"]
    # timeout  = "10m"
    # cooldown = "20m"    # override default_cooldown for this app

    # [apps."com.tinyspeck.slackmacgap"]
    # timeout = "30m"
    """
}
