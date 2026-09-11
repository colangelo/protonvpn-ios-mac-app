# protonvpn-ios-mac-app — our fork of Proton VPN's Apple app (prepared 2026-09-10; build spike 2026-09-11)

This is a fork of [ProtonVPN/ios-mac-app](https://github.com/ProtonVPN/ios-mac-app)
(GPLv3). State (2026-09-11): **the fork builds, signs, logs in, and tunnels**
— a GitHub clone of `main` compiles and signs under our team (#1,
`docs/2026-09-11-build-spike.md`), and `/Applications/ProtonVPN Fork.app`
activates its own WireGuard system extension and connects next to the shipped
app on m4m without disturbing it or the heal daemon (#6,
`docs/2026-09-11-coexistence-run.md`). None of the four behaviour patches has
been started (#2–#5); nothing goes upstream before #11.
Read this file first; the detail
lives in the pointers below, and every claim there carries its measurement.

## Why this fork exists

Proton VPN's macOS app (6.5.1, WireGuard) has two behaviours that cost ac
hours of outage on both Macs in September 2026, measured and reported:

1. **After sleep/wake the tunnel is dead while the app and NetworkExtension say
   Connected**, and the app never recovers it; only a *fresh* extension process
   does. Reported upstream as
   [ProtonVPN/ios-mac-app#35](https://github.com/ProtonVPN/ios-mac-app/issues/35)
   (2026-09-08) with a follow-up comment (2026-09-10) — expect no reply there.
2. **A reconnect never re-selects a server.** When the saved server is dead,
   NE's On Demand and the app's own reconnect return to it forever; only the
   app's Quick Connect changes it (64 minutes of outage on 2026-09-10).

We work around both from outside the app: a root LaunchDaemon in
`macos-setup` (`assets/protonvpn-heal.sh`, rev 13) kills the wedged extension,
and when a fresh process stays dead it performs the app's own Disconnect and
Quick Connect by clicking them through System Events. It works, on both Macs.
It should not be necessary — which is what this fork is for.

## What we would change (the four candidate patches)

| # | Change | Where in the source (branch `develop`, 2026-06) |
|---|---|---|
| A | **Rebind on wake / link change** in the WireGuard extension: on a path change or a time jump, re-create the UDP socket and force a handshake instead of only setting `reasserting`. | the extension target; compare Tailscale's `Rebind; defIf=…` behaviour |
| B | **Liveness in the reconnect path**: when the local agent (`10.2.0.1:65432`) has failed for N minutes while NE says Connected, do a *full* provider restart instead of `Skipping auto-connect: already connected`. | `apps/macos/ProtonVPN/Scenes/Common/Services/NavigationService.swift` (`autoConnectIfEnabled`), `libraries/Core/LegacyCommon/Sources/LegacyCommon/Core/VpnManager.swift` |
| C | **Re-run server selection after N failed reconnects** to the saved endpoint, the way the app already does at launch. | `libraries/Core/LegacyCommon/Sources/LegacyCommon/Core/VpnGateway.swift` (`autoConnect`, `quickConnect`, `connect(with:)`) |
| D | **Done 2026-09-11 (#5).** `protonvpn://disconnect`, `protonvpn://quick-connect`, `protonvpn://reconnect` — call by bundle id, `open -b io.github.colangelo.protonvpn.mac 'protonvpn://reconnect'`, since the shipped app registers the same scheme. On Demand is a preference: `OnDemandEnabled` (default on; `defaults write … OnDemandEnabled -bool false`). | `LegacyCommon/Core/ControlLink.swift` (+ tests), `AppDelegate.getUrl`, `PropertiesManager.onDemandEnabled`, `VpnManager` |

D alone would let the heal daemon drop UI scripting. A alone would remove the
morning outage. C alone would have saved 2026-09-10.

## Facts already established (do not re-derive)

- **On Demand is app-managed and has no setting.** `VpnManager.swift`: every
  connect sets `isOnDemandEnabled = hasConnected` (always `true` for WireGuard
  in `develop`); `disconnect()` calls `setOnDemand(false)`; the rule is a bare
  `NEOnDemandRuleConnect`. `VpnGateway.autoConnect()` returns early while On
  Demand is on. Measured on the shipped 6.5.1: a Connect click and the launch
  auto-connect arm it; the Disconnect click clears it. `scutil` never touches it.
- **`connectAllowed` is in-memory**: after the app's own Disconnect, the running
  app vetoes any outside `scutil --nc start` within ~10 ms
  (`VPN connection not allowed, will disconnect now.`); a fresh process allows.
- **A `pkill -9` of the app may strand the session** (a forced `logOutCleanup`
  followed one by two hours; cause unproven). Quit it gracefully.
- **The extension ignores SIGTERM** (`Remaining transactions after SIGTERM`)
  and only SIGKILL replaces it; `scutil --nc status` blocks for minutes while NE
  disposes of a killed plugin.
- **UI scripting works from a root daemon** via
  `launchctl asuser <uid> sudo -u <user> osascript`; the main window exposes
  `AXButton`s named `Disconnect` / `Quick Connect` (activate the app first, and
  snapshot `entire contents` before iterating). One Accessibility approval per
  Mac, attributed to the parent binary (`gtimeout` in our case).

## Build prerequisites (measured 2026-09-11 — spike `AC-forks/protonvpn-ios-mac-app#1`)

The README's "Xcode 14.x" and "the project does not build without the private
secrets" were both wrong for the macOS app. What a GitHub clone actually lacks
versus Proton's GitLab, and what the justfile does about each:

| Gap | Finding | Recipe |
|---|---|---|
| Xcode | 26.6 works; upstream CI runs `xcode-26.2` (`.gitlab-ci.yml`). One expression no longer type-checks on Swift 6.3.3 (`Persistence/…/ServerFilter+SQLExpression.swift`, a nine-term `\|\|` chain) — split into typed sub-expressions in `4975ea5a6`, **upstream PR candidate**. | — |
| Submodules | `.gitmodules` has relative GitLab URLs. Public mirrors exist at the exact pinned commits: `ProtonMail/protoncore_ios`, `ProtonMail/apple-fusion`, `ProtonVPN/wireguard-apple`. `swift-cargo` has none and nothing in the build references it. | `just submodules` (sets `submodule.*.url` in `.git/config`; `.gitmodules` untouched) |
| `protunFFI` | A `.binaryTarget` on `nexus.protontech.ch` — DNS resolves, connection times out; SwiftPM fetches it at resolution even though it is `condition: .when(platforms: [.iOS])`. `ProtonVPN/protun` publishes the xcframework on GitHub releases (module named `protun`, not `protunFFI` — irrelevant on macOS: `#if canImport(protunFFI)`). `NEProviders/Package.swift` flipped to upstream's own `.local` switch. | `just protun-fetch` (macOS slice only, ~110 MB, gitignored `Frameworks/`) |
| Secrets | The macOS app needs five `ObfuscatedConstants` fields; the only one that matters is the API URL, and that is **committed** (`DoHVPN.liveURL = "https://vpn-api.proton.me"`). Three library packages (`LegacyCommon`, `HomeShared`, `SettingsShared`) also reference the class and need their own ignored file. | `just secrets` (four gitignored files; nothing secret in them) |
| Sparkle | `SUEnableAutomaticChecks=false` alone still showed "Unable to Check For Updates" at every launch (the updater starts anyway and its XPC helpers fail under our signature). The fork drops `SUFeedURL` and `UpdateManager` only starts the updater when a feed exists — i.e. never. | — |
| Bundle IDs | `ch.protonvpn.*` are Proton's App IDs; renamed to `io.github.colangelo.protonvpn.*` in `b1a5e1dc5` (13 files: pbxproj, entitlements, extension Info.plists, four Swift literals). **Fork-only, never upstream.** | — |
| Keychain | Login-keychain items are addressed by service/label and both apps used the same literals (`KeychainConstants.appKeychain = "ProtonVPN"`, `VpnKeychain.StorageKey` `ProtonVPN-Server-Password` / `_ike_root` / `_wg_settings`), so the fork prompted for — and after Allow read — the shipped app's items. Prefixed with the fork's identity. **Fork-only.** | — |
| Signing | Team `CW56R63WQF` ("Alfredo Colangelo", paid — proven by the issued NE-entitled profile; `Apple Development` cert valid to 2027-08). Needs **an Apple ID signed in to Xcode** (Settings → Accounts; `xcodebuild` reports `No Accounts` otherwise) and, once per Mac, `-allowProvisioningDeviceRegistration` (development profiles list Mac UDIDs: `Device "m4m" isn't registered`). Headless alternative: an App Store Connect API key via `-authenticationKeyPath`. | `just build` |

Mechanics that cost a round-trip: build the **workspace** (`ProtonVPN.xcworkspace`),
not `apps/macos/macOS.xcodeproj` — the local packages are workspace members and
the project alone reports *Missing package product* for every one of them.
Every build rewrites `ProtonVPN.xcworkspace/xcshareddata/swiftpm/Package.resolved`
(drops the pins only `swift-cargo` pulled in) — `git checkout --` it before
committing. `Internal Error: DecodingError … Corrupted JSON` lines in the log are
the compilation cache (`COMPILATION_CACHE_ENABLE_CACHING` in `Config.xcconfig`),
not a failure. The WireGuard extension is a **system extension** in every
configuration (`Debug` only drops the `-systemextension` entitlement suffix), and
`AppDelegate` submits the activation request at launch, so *running* the built
app for a tunnel needs it in `/Applications`; the login does not.

Running the Debug build shows an **environment selector** before the login
(`EnvironmentSelectorFeature`; production is preselected, "Use and continue").
Pre-seed `defaults write io.github.colangelo.protonvpn.mac AutoConnect -bool
false` before a first launch next to the shipped app, so the fork cannot start a
second tunnel. The fork's log: `~/Library/Containers/io.github.colangelo.protonvpn.mac/Data/Library/Logs/ProtonVPN.log`.

The falsifier — *a login in a self-built app* — **passed 2026-09-11 10:05Z**
(2FA login, `Session status is now established`, a fresh VPN auth certificate).

## Where the documentation lives

All measurements, logs and decisions are in `macos-setup`
(`~/_sync/dev/macos-setup`, Gitea `ac/macos-setup`):

| What | Where |
|---|---|
| The incident write-up, §1–15, with the PID tables, the SIGTERM/SIGKILL measurements, rev history | `docs/2026-09-07-protonvpn-dead-tunnel-after-wake.md` |
| The cross-cutting learnings and every rule that came out of it, incl. the On Demand and `connectAllowed` findings, the #40 spike, the Accessibility item | `docs/2026-09-10-protonvpn-heal-session-learnings.md` |
| The daemon's operating notes (mechanism, the ladder, the fallback, the reset by hand) | `docs/HOST-CONFIG.md` § *ProtonVPN dead tunnel after wake* |
| The daemon itself, its installer, the one-shot live test, 58 evals | `assets/protonvpn-heal.sh`, `assets/install-protonvpn-heal.sh`, `evals/test_protonvpn_heal.py`; `just protonvpn-heal-{install,status,escalate-test}` |
| The UI-scripting prototype (throwaway) | branch `proto/40-ui-disconnect`, file `assets/proto-protonvpn-ui-disconnect.sh` — read it with `git show`, never check the branch out on the shared `.git` |
| Tracker: the kill (#35 closed), untested branches (#37), the server change (#38 closed), the clicks (#40 closed), the Accessibility grant's durability (#41) | Gitea `ac/macos-setup` issues |
| Upstream report and follow-up | https://github.com/ProtonVPN/ios-mac-app/issues/35 (+ comment 5617354767); Proton support ticket answered 2026-09-10 (reply text in the write-up § 14) |
| The Proton `log collect` archive from a dead window | `~/Desktop/m5-protonvpn-dead-2026-09-08-1218.logarchive` on ac-mbm5 (private, never attach publicly) |

House conventions (git, secrets, relay, worktrees): `~/_sync/dev/CONTEXT/AGENTS.md`.

## Remotes and branches

| Remote | URL | Role |
|---|---|---|
| `origin` | `https://github.com/colangelo/protonvpn-ios-mac-app.git` | our public fork (default branch `develop`, as upstream) |
| `upstream` | `https://github.com/ProtonVPN/ios-mac-app.git` | Proton's repo; `just sync-upstream` |
| `internal` | `https://gitea.cat-bluegill.ts.net/AC-forks/protonvpn-ios-mac-app.git` | the house mirror (private); default branch `main` |

`develop` tracks upstream unchanged. **`main` is ours**, branched from
`develop` at the fork point; patches land on `main` (or on `feat/*` branches
off it) and rebase onto `develop` after each `just sync-upstream`. Commit by
pathspec, never `git add -A`; never `git push --all` from a synced tree (a
`*.sync-conflict-*` ref would publish as a branch on the public fork). This
folder is Syncthing-synced **including `.git`** to the other Mac: do not check
out a different branch on one Mac while a session holds the tree on the other.

**The WireGuard adapter is a second fork.** `external/wireguard-apple` (the
`WireGuardAdapter`, the Go bridge, the path monitor — everything patch A
touches) is a submodule pinned to Proton's `5742d28`; `WireGuardAdapter` keeps
its Go handle private, so adapter-side changes need our own copy. Since
2026-09-11 (`#2`):

| Remote | URL | Role |
|---|---|---|
| `origin` | `https://github.com/colangelo/wireguard-apple.git` | our public fork of `ProtonVPN/wireguard-apple` |
| `upstream` | `https://github.com/ProtonVPN/wireguard-apple.git` | Proton's; their branch is `release/ios` |
| `internal` | `https://gitea.cat-bluegill.ts.net/AC-forks/wireguard-apple.git` | house mirror; default branch `main` |

`release/ios` tracks upstream; **`main` is ours** from `5742d28`. A change
goes: commit on the submodule's `main` → push `origin` + `internal` → bump the
pointer in this repo (`git add external/wireguard-apple`) in its own commit.
`just submodules` clones from our fork and adds the other two remotes. Upstream's
`.gitmodules` is never edited. Its backlog is this repo's. Detail:
`docs/wireguard-apple-fork.md`.

## How to start

1. `just status` — remotes, branch, how far `develop` is behind upstream.
2. `just sync-upstream` — fetch upstream and fast-forward `develop`.
3. On a fresh clone: `just submodules`, `just protun-fetch`, `just secrets`,
   then `just build-unsigned` (compile proof) and `just build` (signed).
4. The spike is Gitea `AC-forks/protonvpn-ios-mac-app#1`; its comments carry
   every measurement. Backlog labels: `backlog-schema.toml` (gitea-backlog skill).
5. Work on `main`; keep upstream files untouched except where a patch needs
   them, so rebases stay cheap. Keep the fork-only commits (bundle IDs, the
   `.local` protun switch, Sparkle, keychain names) apart from upstream-bound ones.
6. **Nothing goes upstream until #11**: the patches exist (#2–#5), the fork has
   replaced the shipped app on both Macs for about a week, and it demonstrably
   fixes the wake outages in `macos-setup` — then PRs (#7, #8, and the patches)
   with that evidence. Rule set by ac on 2026-09-11; ask before any
   outward-facing action on `ProtonVPN/ios-mac-app`.

## Agent relay (spec 2.36, variant `nats` — no committed relay surface)

This repo is a relay participant since 2026-09-11 (registry row in infra
`agent-relay/AGENTS.md`; Gitea `AC-forks/protonvpn-ios-mac-app` carries the
four relay labels). Being a fork, it commits no `agent-relay/` directory: its
primary channel is NATS.

- **At session start, run `/check-relay`** — the only check that covers all
  three channels (NATS queues, Gitea `agent-relay` issues on this repo, and the
  file inbox other repos have). A hand-rolled scan is not a relay check: NATS
  `interactive` messages leave no repo trace by design.
- **To message another repo's agent — the criterion: Channel 0 addresses a
  context; the relay addresses a role.** (1) Is the ask for a specific *live*
  session holding the shared context, able to answer or coordinate now? →
  `ListAgents` + `SendMessage` (Channel 0). Needing a durable *record* never
  pushes you off Channel 0 — the record goes on the tracker either way;
  needing durable *delivery* does, and a Channel-0 send confirms enqueue, not
  delivery. (2) Else, must "not yet handled" stay visible to you? → a Gitea
  `agent-relay` issue in the recipient repo. (3) Else → the recipient's primary
  registry channel: `tools/relay-send --to <repo>` (infra) for a `nats` row, a
  file in *their* `agent-relay/inbox/` for a file-inbox row; `--class auto`
  only for work safe to run with nobody present, `interactive` when the answer
  must reach a person.
- Never put secrets in a message; reference the OpenBao path (`kv/…`).
- Counterparts: `macos-setup` (the heal daemon, host config), `infra` (relay
  registry, the TCC hook), both on `nats`. Full spec: infra
  `agent-relay/AGENTS.md`.

## Repo rules (learned 2026-09-11 — evidence in `docs/2026-09-11-session-learnings.md`)

- **Launch the fork by path** (`open "/Applications/ProtonVPN Fork.app"`), never
  `open -a`; control it by bundle id (`open -b io.github.colangelo.protonvpn.mac 'protonvpn://…'`).
- **Never two tunnels.** Disconnect the shipped app before the fork connects and
  restore it in the same script; verify with `scutil --nc status`, `ping 10.2.0.1`,
  the exit IP — not the menu icon.
- **Rename by literal.** Any identifier that is also a keychain service/label or a
  bundle resource name is renamed by grepping the *string*, then auditing `forKey:`
  and `forResource:`.
- **The extension's log is the unified log**, subsystem `PROTON-WG`, read with
  `log show … --info --debug`; keep the persistence profile on the test Mac.
- **Nothing goes upstream before #11.** Fork-only commits (bundle ids, names,
  Sparkle, keychain, `.local` protun) stay apart from upstream-bound ones.
- **Never commit `ProtonVPN.xcworkspace/xcshareddata/swiftpm/Package.resolved`**;
  `git checkout --` it before every commit.
- **Pre-seed `AutoConnect=false`** in the fork's defaults before a first launch on a
  Mac where the shipped app runs.
