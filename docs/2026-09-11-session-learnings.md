---
type: learning
title: "2026-09-11 — from parked fork to a tunnelling app with a control surface, and what became rules"
description: "The cross-cutting layer over the day's three per-task docs (build spike, coexistence run, wireguard-apple fork): what shipped and how each was verified, the rules that now bind (launch by path, never two tunnels, rename by literal, the evidence gate before anything upstream, the extension log is in the unified log under PROTON-WG), and what is open at handover — the unexecuted ControlLink tests (#12), patch A waiting on a persisted wake log (#2), patches B and C (#3, #4), the week of verified use (#11)."
tags: [protonvpn, fork, learnings, handover]
timestamp: 2026-09-11
---

# 2026-09-11 — from parked fork to a tunnelling app with a control surface, and what became rules

Per-task detail lives in `2026-09-11-build-spike.md`, `2026-09-11-coexistence-run.md`
and `wireguard-apple-fork.md`; this is the layer across them plus the handover state.

## What shipped

| Thing | Verified how |
|---|---|
| A GitHub clone compiles (`just setup`, `just build-unsigned`) | `** BUILD SUCCEEDED **`, 3,824 units; #1 |
| Signed under team CW56R63WQF, NE entitlements issued | `codesign -d --entitlements`, "Mac Team Provisioning Profile" to 2027-09-11; #1 |
| Login in the self-built app (the spike's falsifier) | fork log: 2FA login → `Session status is now established` → new VPN cert; #1 closed |
| Fork runs its own WireGuard system extension next to the shipped app (`/Applications/ProtonVPN Fork.app`) | `systemextensionsctl list` `[activated enabled]`; NE config "ProtonVPN Fork" Connected; `10.2.0.1` answers; exit IP a Proton server; shipped app restored and healthy; daemon silent; #6 closed |
| Patch D: `protonvpn://disconnect \| quick-connect \| reconnect` + `OnDemandEnabled` preference | live: quick-connect → Connected 15 s; reconnect → Disconnected → Connected 6 s with a fresh `Server selected`; disconnect → OnDemand FALSE; #5 |
| Second fork `colangelo/wireguard-apple` (+ `AC-forks/wireguard-apple`), submodule wired | `ls-remote` both remotes = `5742d28` on `main` and `release/ios` |
| Onboarded (fork profile): house verbs, OKF docs, issue templates, relay labels + pointer, catalog record handed to infra | `just lint` exit 0 (`lint-paths: ok`, `4 docs, 0 errors`); `doctor` clean; infra-relay-5 holds the registry row + record |
| infra `tcc-path-guard` per-repo opt-out (with the #173 fixes and 26 tests) | ac/infra#173 closed; `.claude/tcc-guard-allow` here |

## Learnings → rules

1. **Launch the fork by path, never `open -a`.** LaunchServices resolves the name to whichever copy it registered last — the DerivedData build — and system-extension activation then fails with *"App containing System Extension to be activated must be in /Applications"*. *Evidence:* fork log 10:25:11Z; `docs/2026-09-11-coexistence-run.md` § 2.
2. **Never two tunnels: the shipped app is Disconnected before the fork connects, and restored inside the same script.** The heal daemon treats a deliberate Disconnect as `not-ours`; a fork tunnel next to a live shipped one would confuse every probe. *Evidence:* daemon log unchanged across three swaps; `assets/protonvpn-heal.sh` Disconnected branch.
3. **Rename by literal, then audit `forKey:` and `forResource:` — a symbol rename is not the same thing.** `StorageKey.serverCertificate` was also the bundled `.der` name (crash on first Quick Connect); `ProtonVPN_wg_settings` existed in two implementations, one of which would have updated the shipped app's item in place. *Evidence:* `ProtonVPN Fork-2026-09-11-122838.ips`; commit `3302e8fb7`.
4. **Two apps with the same keychain literals share credentials, whatever their bundle ids, teams or sandboxes.** Isolation is the service/label name. *Evidence:* the two macOS prompts on run 0; commit `cbf12364e`.
5. **A fork must never *start* the updater, not merely disable its schedule.** `SUEnableAutomaticChecks=false` still produced "Unable to Check For Updates" at every launch. *Evidence:* `UpdateManager.swift` `startingUpdater: feedURLString != nil`.
6. **The extension's log has been in the unified log all along — subsystem `PROTON-WG`, public strings.** `log show` hides `.info`/`.debug` unless given `--info --debug`, and those levels live ~15 min unless persisted: `sudo log config --mode 'level:debug,persist:debug' --subsystem PROTON-WG` (on m4m since 13:29 local). Upstream *already* rebinds on path changes (`wgBumpSockets`), so patch A is designed from what that log shows at the next real wake, not from the plan's wording. *Evidence:* `WireGuardAdapter.didReceivePathUpdate`; `#2`.
7. **Nothing goes upstream before #11** — patches implemented, a week of real use on both Macs, evidence against the wake outages. Even one-hunk fixes wait. *Evidence:* ac, 2026-09-11; `#7`, `#8` parked `horizon/later`.
8. **Two Proton apps on one Mac must differ in process name, NE-configuration title and keychain names before the first tunnel** — the daemon addresses the shipped app by every one of those. *Evidence:* `protonvpn-heal.sh` `pgrep -x`, `tell process`, `scutil --nc status ProtonVPN`; commit `b25e14d32`.
9. **AppleScript's error is not proof the click missed** — the shipped app's Disconnect landed while `System Events` reported *Can't get window 1*; the app's own log is the reading. And a `terminate:` preceded by `trackMouse … mouseUp` is a human click, not a peer process. *Evidence:* shipped log 10:28:24Z; unified log 12:28:44.747.
10. **`Package.resolved` is rewritten by every build (and by Xcode while open) — never commit it.** The dropped pins belong to the absent `swift-cargo`. *Evidence:* every `git status` today.

## Open at handover

- **#12** — `just test` is not a proven invocation: the auto-generated `LegacyCommon` scheme has no test action, so `ControlLinkTests` (4 tests) is committed but **unexecuted**. First job: find the invocation (`-scheme LegacyCommon-Package`? `swift test --package-path libraries/Core/LegacyCommon --filter ControlLinkTests`?), fix the recipe, run it. Also upstream's `ProtonVPNmacOSTests` does not build on Xcode 26.6 (TrustKit/SDWebImage/GRDBSQLite unresolved).
- **#2** patch A — blocked on evidence: read `log show --start '<wake time>' --info --debug --predicate 'subsystem == "PROTON-WG"'` after m4m's next real morning wake (correlate with `pmset -g log | grep -E ' (Sleep|Wake) '` and the heal daemon log); then design the adapter change on the wireguard-apple fork (`docs/wireguard-apple-fork.md`).
- **#4** patch C and **#3** patch B — ready; both want `OnDemandEnabled=false` on the fork to be testable (`defaults write io.github.colangelo.protonvpn.mac OnDemandEnabled -bool false`).
- **#11** — the week of use on both Macs; the fork is installed on m4m only (`/Applications/ProtonVPN Fork.app`), quit, logged in, `AutoConnect` off.
- Catalog record + registry row: with infra-relay-5 (CONTEXT tree was held); verify `~/_sync/dev/CONTEXT/PROJECTS/protonvpn-ios-mac-app.md` shows `onboarded = "2026-09-11"` and infra's registry has the row.
- The fork's first connect logged `Error reading from keychain: -25300` once (probably the atlas-secret read); benign, unexplained.
