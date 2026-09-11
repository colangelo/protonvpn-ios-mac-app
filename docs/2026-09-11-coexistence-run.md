# Coexistence run, 2026-09-11 — the fork's tunnel next to the shipped app on m4m

Gitea `AC-forks/protonvpn-ios-mac-app#6`. Follows `2026-09-11-build-spike.md`
(compile + sign + login). This run answers: can the fork activate its own
WireGuard system extension, connect, and hand the VPN back to the shipped app,
on the Mac whose heal daemon watches the shipped app — without the two
interfering. **Yes**, after three fork-only fixes. Commits: `b25e14d32`
(names), `b84f0fb36` (schemes), `3302e8fb7` (keychain).

## 1. Why names came first

`macos-setup/assets/protonvpn-heal.sh` addresses the shipped app by **name**:
`pgrep -x ProtonVPN`, `pkill -9 -x ProtonVPN`, `tell process "ProtonVPN"`,
`open -a ProtonVPN`, `scutil --nc status ProtonVPN`; only the extension is
matched by bundle id. A fork whose process and VPN configuration were also
called "ProtonVPN" would have been killed, clicked and polled by the daemon.
So, before any tunnel: `PRODUCT_NAME = "ProtonVPN Fork"` (with
`PRODUCT_MODULE_NAME = ProtonVPN` pinned, because
`setUpNSCoding(withModuleName: "ProtonVPN")` maps archived class names by
module), and `WireguardConfigurator.configurationTitle` → `"ProtonVPN Fork"`
(Release) / `"<server> - <protocol> (fork)"` (Debug). The daemon's Disconnected
branch is `not-ours` unless it killed the extension in the last few minutes, so
a deliberate Disconnect of the shipped app during the test is safe.

## 2. Steps that work

```
ditto ~/Library/Developer/Xcode/DerivedData/ProtonVPN-*/Build/Products/Debug/"ProtonVPN Fork.app" "/Applications/ProtonVPN Fork.app"
open "/Applications/ProtonVPN Fork.app"          # by PATH — `open -a` may pick the DerivedData copy
# macOS: "ProtonVPN Fork would like to use a new network extension" → Open System Settings → enable → Done
systemextensionsctl list | grep colangelo        # [activated enabled]
```

Then, with the user present: shipped app Disconnect → fork Quick Connect →
verify → fork Disconnect → shipped Quick Connect → verify. The whole swap is
~70 s. Verification that means something:

| Check | Fork connected (12:46:00) | Shipped restored (12:46:40) |
|---|---|---|
| `scutil --nc list` | `(Connected) … "ProtonVPN Fork"` | `(Connected) … "ProtonVPN"` |
| `ping 10.2.0.1` (Proton local agent) | 0 % loss | 0 % loss (after ~10 s) |
| exit IP (`api.ipify.org`) | 159.26.101.111 (US-MA#195) | 205.147.30.27 |
| DNS | 185.70.42.45 | — |
| daemon log | unchanged | unchanged |

Both NE configurations then exist side by side; the fork's stays Disconnected
with On Demand FALSE.

## 3. What broke, and why

1. **Crash on the first Quick Connect** — `EXC_BREAKPOINT` in
   `VpnKeychain.storeServerCertificate()`, reached from
   `AppStateManager.prepareToConnect()`. `StorageKey.serverCertificate` is used
   as the keychain **label** *and* as the bundled resource name
   (`ProtonVPN_ike_root.der`, `Bundle.main.path(forResource:)!`). The keychain
   rename in `cbf12364e` therefore turned a resource lookup into `nil`. Fix:
   `serverCertificateResource` keeps the file name; the label stays ours.
2. **A second keychain implementation.** `ConnectionShared/TunnelKeychainImplementation`
   (the new-connection path, `WireguardConfigurator`) has its own
   `"ProtonVPN_wg_settings"`; items are addressed by the bare key (service =
   account = generic, no access group). Left alone, the fork's connect would
   have *updated the shipped app's item in place* — same persistent reference,
   the fork's WireGuard config — a hijack, not a collision. Aligned with
   `VpnKeychain`'s fork value.
3. **The environment selector / onboarding** are Debug-build UI (SwiftUI, no
   accessibility names): "Use and continue" had to be clicked by coordinates;
   onboarding's telemetry toggles are not reachable at all, so they were set
   off through the fork's defaults (`Telemetry*` keys → `false`).

## 4. Facts established

- The **Debug** configuration's `packet-tunnel-provider` entitlement (no
  `-systemextension` suffix) activates a system extension fine; upstream's
  suffix in Release is not what gates activation. The app must be in
  `/Applications` (`OSSystemExtensionErrorDomain Code=3` otherwise).
- After a rebuild + `ditto`, re-launch reports `.success(.upgraded)` with no
  new approval (same version 6.5.99/1234, same team).
- The fork's Smart Protocol scan lost every UDP probe on its first 5 s pass
  (`read udp 192.168.4.200:… i/o timeout`), retried, and connected 16 s after
  the click — worth remembering when judging "slow connect" later.
- Both apps log in as client id `macos-vpn` (`Client.plist`); the shipped app
  showed no 401/logout across both runs. Watch during `#11`.
- **Unexplained:** in run 0 the shipped app got `applicationShouldTerminate`
  at 10:28:44Z, 20 s after the Disconnect click and 6 s after the fork's crash.
  Not the daemon, not this session. Open on #6 until ac says whether it was a
  manual quit.

## 5. Learnings that generalise

- Renaming an identifier that is also a *file name* needs `grep` for the
  literal, not for the symbol — the crash was a `path(forResource:)` on the
  symbol's value.
- The same keychain key can live in two implementations (legacy and new
  path); rename by literal across the tree, then audit `forKey:`.
- A daemon that matches by name defines the fork's naming; read it before
  the first launch, not after the first kill.
- AppleScript UI errors are not proof the click missed: the shipped app's
  Disconnect landed while `System Events` reported *Can't get window 1*.
- Restore the baseline inside the same script that breaks it — the shipped
  app was back before any analysis started.
