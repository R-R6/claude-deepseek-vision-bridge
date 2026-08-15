# Source layout

Repository sources are grouped by responsibility. Installers copy the required
files into the existing flat user-level runtime directories, so this layout does
not change installed paths or startup entries.

| Directory | Responsibility |
| --- | --- |
| `core/` | Cross-platform Bridge runtime, vision client, health helper, and Vision CLI |
| `routing/` | Cross-platform CC Switch route and SQLite helpers |
| `macos/` | macOS install, launchd, restart, diagnosis, recovery, and wrapper scripts |
| `windows/` | Windows install, Startup, restart, diagnosis, recovery, and route scripts |
| `templates/` | Files copied or rendered into user-facing integrations |

Keep protocol and image-processing logic in `core/`. Platform scripts may
orchestrate those files, but should not duplicate their validation or request
handling. Keep shared route/database behavior in `routing/`; platform wrappers
remain in their platform directory.

Installed Bridge and Skill bundles intentionally remain flat because existing
startup entries, rollback snapshots, and upgrades depend on their stable names.
