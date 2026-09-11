---
type: learning
title: "Build spike 2026-09-11 — a GitHub clone builds, signs and logs in"
description: "What a GitHub clone of Proton VPN's macOS app lacks versus Proton's GitLab and how each gap was closed (public submodule mirrors, the firewalled protunFFI binary via upstream's .local switch, an Xcode 26.6 type-check split, reconstructed non-secret constants), the signing path under our team, the three first-launch surprises (Sparkle, shared keychain items, system-extension activation), the noise to ignore, and the learnings that generalise. Falsifier passed: 2FA login in the self-built app."
tags: [protonvpn, fork, build, signing, xcode, spike]
timestamp: 2026-09-11
---

# Build spike, 2026-09-11 — can a GitHub clone of Proton VPN's macOS app build, sign and log in?

**Answer: yes.** Falsifier — *a login in a self-built app* — passed at 10:05Z
on m4m (macOS 26.6, Xcode 26.6). Tracker: Gitea `AC-forks/protonvpn-ios-mac-app#1`
(closed; every measurement is in its comments). This document is the account
an agent needs to repeat it or to understand why `main` differs from `develop`.

Commits on `main` (all on top of upstream `develop` at `6973fc1f7`):

| Commit | What | Upstream-bound? |
|---|---|---|
| `4975ea5a6` | public protun xcframework via upstream's `.local` switch; Xcode 26.6 type-check split; Sparkle checks off; justfile recipes; backlog schema | type-check split → #7; the rest → #8 (docs) or fork-only |
| `b1a5e1dc5` | bundle identifiers `ch.protonvpn.*` → `io.github.colangelo.protonvpn.*` | never |
| `64b629bab` | AGENTS.md § Build prerequisites as measured | fork-only |
| `cbf12364e` | never start Sparkle; fork-prefixed keychain service and storage keys; `-allowProvisioningDeviceRegistration` | never |

## 1. The plan and its falsifier

AGENTS.md (2026-09-10) named the question — *can a clean clone build at all,
with reconstructed constants, signed by our team, and connect to Proton's
API?* — and the falsifier: a login in a self-built app. It also said the
secrets question "may be the last". It was not; the secrets were the smallest
problem. The order of blockers as they actually appeared:

1. local packages missing (wrong build entry point) — minutes
2. `protunFFI` binary target on a firewalled host — the real one
3. one expression that Swift 6.3.3 will not type-check
4. `No Accounts` — Xcode signed out (human step)
5. `Device "m4m" isn't registered` — one flag
6. Sparkle failing to start, and shared keychain items — runtime, first launch

## 2. Steps, in the order that works

From a fresh clone of `main` (Xcode 26.x installed, `go` and `jq` on PATH,
`gh` authenticated):

```
just submodules       # public mirrors for the 3 submodules the build needs
just protun-fetch     # macOS slice of ProtonVPN/protun's public xcframework (~110 MB, gitignored)
just secrets          # the four gitignored ObfuscatedConstants.swift files
just build-unsigned   # ** BUILD SUCCEEDED ** proves sources + packages; no App ID needed
just build            # signed; needs an Apple ID in Xcode (Settings → Accounts)
```

Then, for a first launch next to the shipped app:

```
defaults write io.github.colangelo.protonvpn.mac AutoConnect -bool false
open -n ~/Library/Developer/Xcode/DerivedData/ProtonVPN-*/Build/Products/Debug/ProtonVPN.app
```

Debug shows an environment selector first (production preselected — "Use and
continue"), then the login window. The fork logs to
`~/Library/Containers/io.github.colangelo.protonvpn.mac/Data/Library/Logs/ProtonVPN.log`.
Quit it with `osascript -e 'tell application id "io.github.colangelo.protonvpn.mac" to quit'`
(never `pkill -9`; AGENTS.md § Facts).

## 3. What a GitHub clone lacks, and the evidence

### 3.1 Build the workspace, not the project

`xcodebuild -project apps/macos/macOS.xcodeproj` fails with *Missing package
product 'X'* for all 25 local packages: they are members of the root
`ProtonVPN.xcworkspace`, not of the project. `-workspace ProtonVPN.xcworkspace
-scheme ProtonVPN-macOS` is the entry point (`bootstrap.sh` checks for the
workspace, which is the hint).

### 3.2 Submodules

`.gitmodules` has relative URLs (`../../shared/protoncore`,
`../../../tpe/apple-fusion`, `../wireguard-apple`, `../swift-cargo`) that only
resolve on Proton's GitLab. Checked with `gh api repos/<mirror>/commits/<sha>`:

| Submodule | Pinned | Public mirror at that commit |
|---|---|---|
| `external/protoncore` | `40e92cbe` (36.0.3) | `ProtonMail/protoncore_ios` ✓ |
| `external/apple-fusion` | `5f680d98` (2.1.2) | `ProtonMail/apple-fusion` ✓ |
| `external/wireguard-apple` | `5742d286` | `ProtonVPN/wireguard-apple` ✓ (also `WireGuard/wireguard-apple`) |
| `external/swift-cargo` | `a5c3cf9c` | none — and no `Package.swift`/pbxproj references it (a Mintfile CI tool) |

`just submodules` sets `submodule.<name>.url` in `.git/config`; `.gitmodules`
is left as upstream has it, so rebases stay clean. No Git LFS anywhere
(`.gitattributes` has no `filter=lfs` in the repo or the three submodules).

### 3.3 `protunFFI` — the binary target on a firewalled host

`libraries/Core/NEProviders/Package.swift` declares
`.binaryTarget(name: "protunFFI", url: "https://nexus.protontech.ch/…/protunFFI.xcframework.zip", checksum: …)`.
DNS resolves (`185.70.42.66`) and the TCP connection times out from outside
Proton, so resolution dies with *A TLS error caused the secure connection to
fail*. SwiftPM downloads binary targets at resolution time **even though the
target is `condition: .when(platforms: [.iOS])`**, so the macOS build never
starts. Upstream's manifest already has a `.local` case
(`Frameworks/protunFFI.xcframework`, gitignored; commit `677cc4393`).

`ProtonVPN/protun` publishes `protun-release.xcframework.zip` on GitHub
releases (v2.2.1, 97 MB; slices for ios, ios-simulator, tvos, tvos-simulator,
macos-arm64_x86_64). Its framework and module are named `protun`, not
`protunFFI` (SwiftPM checksum `13dc3241…` vs upstream's `c770dc20…`), which
does not matter on macOS: `ProTUNExtension/FFI/protun.swift` is behind
`#if canImport(protunFFI)`. It would matter for iOS (#9). `just protun-fetch`
unpacks only the macOS slice and rewrites the xcframework's `Info.plist` to
list just that slice, so the synced tree carries 110 MB rather than 326.

### 3.4 Secrets are not secrets (for macOS)

`apps/macos/ProtonVPN/ObfuscatedConstants.example.swift` lists five fields:
two Sentry DSNs (empty is fine), `apiHost`, `humanVerificationV3Host`,
`vpnIAPIdentifiers` (iOS in-app purchases). The live API URL is committed:
`DoHVPN.liveURL = "https://vpn-api.proton.me"`
(`libraries/Shared/CommonNetworking/…/DoH.swift:32`); `apiHost` is only the DoH
alternative-routing lookup host and `humanVerificationV3Host` is the public
`https://verify.proton.me`. Three library packages also reference the class
and need their own ignored file, because a package cannot see an app target's
type: `LegacyCommon` and `HomeShared` (`fidoPortal`), `SettingsShared`
(`btiAPIHost`, `blackAPIHost`, internal test environments). `.gitignore` has
`**/ObfuscatedConstants.swift`, so `just secrets` can put them anywhere in the
target's sources. Also public: `apps/macos/ProtonVPN/Client.plist` carries
the app's API client id (`macos-vpn`) and secret.

### 3.5 Xcode 26.6 and one expression

Upstream CI image: `team-vpn-macos-15.6-xcode-26.2` (`.gitlab-ci.yml:27`).
On Xcode 26.6 / Swift 6.3.3, 3,824 compilation units built and one failed:
`Persistence/QueryInterface/ServerFilter+SQLExpression.swift:95`, the
`.matches(query)` case — nine GRDB `SQLExpression`s joined with `||` — *the
compiler is unable to type-check this expression in reasonable time*. Split
into four typed sub-expressions (`matchesCountryCode`, `matchesPlace`,
`matchesCountryName`, `matchesName`); OR is associative so the SQL is the
same. Upstream will hit this on its next Xcode bump → #7.

### 3.6 Signing

- Keychain: one `Apple Development: a.colangelo@pm.me (T49JDQ5DC7)` identity,
  `OU=CW56R63WQF, O=Alfredo Colangelo` — the OU is the team. The
  parenthesised id in the CN is **not** the team id.
- `xcodebuild -allowProvisioningUpdates` needs an Apple ID signed in to
  Xcode; without one every target fails with `No Accounts: Add a new account
  in Accounts settings` before compiling. `defaults read com.apple.dt.Xcode
  DVTDeveloperAccountManagerAppleIDLists` shows whether one exists.
- Mac development profiles list device UDIDs: the first signed build failed
  with `Device "m4m" isn't registered in your developer account`.
  `-allowProvisioningDeviceRegistration` registers it (now in `just build`).
- Result: `ProtonVPN.app` signed by team `CW56R63WQF` with
  `packet-tunnel-provider`, `app-proxy-provider`, `allow-vpn`,
  `system-extension.install`, app group
  `CW56R63WQF.group.io.github.colangelo.protonvpn.mac`, keychain group
  `CW56R63WQF.io.github.colangelo.protonvpn.macos`, profile "Mac Team
  Provisioning Profile: io.github.colangelo.protonvpn.mac" (to 2027-09-11).
  The issued NetworkExtension entitlement is the proof that the membership is
  paid.
- Bundle IDs had to change (App IDs are unique across teams; upstream's
  README says so). `b1a5e1dc5` rewrites 13 files; queue labels and
  `os_log` subsystems that merely start with `ch.protonvpn` were left alone.
  The extension products are named after their bundle ids
  (`…WireGuard-Extension.systemextension`), so the pbxproj product references
  changed too, and `xcodebuild` then rewrote the Plutonium scheme's
  `BuildableName` on its own.

### 3.7 First launch: three surprises

1. **Sparkle** — "Unable to Check For Updates. The update checker failed to
   start correctly." `SUEnableAutomaticChecks=false` is not enough:
   `UpdateManager.init` constructs `SPUStandardUpdaterController`, which
   starts the updater, whose bundled XPC helpers
   (`org.sparkle-project.*.xpc`, Proton-signed) fail under our signature. The
   fork drops `SUFeedURL` and passes `startingUpdater: feedURLString != nil`.
2. **Keychain sharing** — macOS: *"Proton VPN wants to use your confidential
   information stored in "ProtonVPN" in your keychain"* at launch, and
   *"…"ProtonVPN-Server-Password"…"* after login. Login-keychain items are
   addressed by service/label; `KeychainConstants.appKeychain = "ProtonVPN"`
   and `VpnKeychain.StorageKey` literals were identical in both apps. After an
   Allow, the fork's defaults gained a key containing the Proton username —
   it had read the shipped app's auth item. The danger is a token refresh from
   the fork logging the shipped app out (single-use refresh tokens). Fork
   prefix on all four names; the shipped app was verified healthy afterwards
   (`10.2.0.1` answers; `scutil --nc list` Connected; no auth errors).
3. **System extension** — `OSSystemExtensionActivationRequest` for both
   extensions fails immediately from DerivedData (expected: the app must be
   in `/Applications`), and the app carries on (`No active protocols
   detected. Defaulting to .ike`). Note that *every* configuration builds the
   WireGuard extension as a `.systemextension`; `Debug` only drops the
   `-systemextension` suffix from the `packet-tunnel-provider` entitlement
   (`NE_ENTITLEMENT_SUFFIX`). Whether that matters for activation is #6's
   first question.

### 3.8 Noise to ignore

- `DTDKRemoteDeviceConnection: … The device is passcode protected` — a locked
  iPhone plugged into the Mac.
- `Internal Error: DecodingError.dataCorrupted … Corrupted JSON` — the
  compilation cache (`COMPILATION_CACHE_ENABLE_CACHING = YES` in
  `apps/macos/Config.xcconfig`); the build succeeds regardless.
- Every build rewrites `ProtonVPN.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  (drops `swift-subprocess`/`swift-system`, pulled in only by the absent
  `swift-cargo`). `git checkout --` it before committing.
- `Failed to unregister login item: SMAppServiceErrorDomain Code=1` — the
  login-item helper is not installed for a DerivedData build.

## 4. Learnings that generalise

- **Read the manifest before the README.** The README's "Xcode 14.x" and "does
  not build without the secrets" were both stale; the manifest's `.local`
  switch and the committed `liveURL` were the answers.
- **A platform-conditioned binary target is still downloaded.** SwiftPM
  resolves the whole graph before it looks at conditions.
- **Separate the two halves of a build falsifier.** `CODE_SIGNING_ALLOWED=NO`
  proved sources/packages before any App ID existed, so every later failure
  was a signing failure by construction.
- **Two apps with the same keychain literals share credentials**, regardless
  of bundle id, team or sandbox. Renaming bundle ids is not isolation.
- **A fork must never start the updater**, not merely disable its schedule.
- **Screenshots of a wide display are 3200 pt across**: a 340-pt window is a
  thumbnail after downscaling; crop by window position (`sips -c … --cropOffset`)
  after bringing the process frontmost.
- **`by` is a reserved word in AppleScript** (`set by to …` is a syntax error
  that reads like a logic error).

## 5. Where things are

| What | Where |
|---|---|
| Tracker | Gitea `AC-forks/protonvpn-ios-mac-app`: #1 (this spike, closed), #2–#5 patches A–D (blocked by #6), #6 real run, #7–#8 upstream PRs, #9 protun/iOS, #10 relay |
| Recipes | `justfile` (`submodules`, `protun-fetch`, `secrets`, `build-unsigned`, `build`, `status`, `sync-upstream`, `published`) |
| Fork-only vs upstream-bound | this file § top table; AGENTS.md § How to start |
| The outage measurements the fork exists for | `macos-setup` docs (AGENTS.md § Where the documentation lives) |
| Build logs of the day | scratchpad only (`build-unsigned-ws*.log`, `build-signed*.log`); nothing worth keeping beyond what is quoted here |
