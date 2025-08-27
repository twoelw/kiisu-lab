Mirror service (server-side)

What it does
- Polls GitHub for latest releases for selected repos
- Downloads .tgz/.dfu assets and stores them under /mirror (served by nginx)
- Produces /mirror/channels.json for the frontend to consume
- Special-case support for Momentum Firmware feed at https://up.momentum-fw.dev/firmware/directory.json (selectable channel)

Tokenless mode
- Works without GITHUB_TOKEN using ETag caching (If-None-Match)
- Default interval is 1h without token; with token, 15min
- Set MIRROR_INTERVAL_SECONDS to override

Environment variables
- MIRROR_REPOS: space-separated repos (owner/name)
- MIRROR_INTERVAL_SECONDS: seconds between syncs
- GITHUB_TOKEN: optional; increases rate limits and speed
- USER_AGENT: UA string for GitHub API
- MIRROR_MOMENTUM_CHANNEL: which Momentum channel to mirror (default: release). Examples: release, development, wip-kiisu-mntm
