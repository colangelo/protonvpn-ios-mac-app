---
type: design
title: "The liveness ladder — patches B and C as one in-app supervisor (restart, then re-select excluding the dead server)"
description: "Design approved by ac on 2026-09-11 for #3 (patch B) and #4 (patch C): a TunnelLivenessSupervisor in LegacyCommon that notices the local agent stuck unreachable while NE says Connected, restarts the same connection once, then re-runs the saved request excluding the dead server's node (30-min avoid list, at most two re-selections, then gives up). Grounded in the 2026-09-10 outage (four fresh extensions, all dead on 146.70.182.18, 64 min) and in the code: serverUnreachable is inert on macOS today and 'fastest' is deterministic."
tags: [protonvpn, fork, patch-b, patch-c, liveness, server-selection, design]
timestamp: 2026-09-11
---

# The liveness ladder — patches B and C as one in-app supervisor

Issues: #3 (patch B, liveness in the reconnect path) and #4 (patch C, re-select after
failed reconnects). Approved section by section by ac on 2026-09-11; the four choices
he made are marked **(ac)**.

## Why one design for two issues

Patch C was written as "after N failed reconnects, re-select". On macOS there is no
failed reconnect for it to count:

- **The app never sees an NE failure when a server is dead.** On 2026-09-10 the heal
  daemon killed the extension four times over 54 minutes; every fresh process came back
  `Connected to: 146.70.182.18` and was dead after 32 s (macos-setup
  `docs/2026-09-07-protonvpn-dead-tunnel-after-wake.md` § 14). The only failure signal
  was the local agent (`10.2.0.1:65432`) stuck in `serverUnreachable` while NE said
  Connected.
- **That signal is inert on the macOS code path.** macOS runs the legacy connection
  stack (`FeatureFlagsRepository.isConnectionFeatureEnabled` is `false` off iOS,
  `Domain/…/VPNFeatureFlagType.swift:72`), where `VpnManager+LocalAgent.didChangeState`
  handles only certificate states and sends `serverUnreachable` to `default: break`.
- **Every automatic path lands on the same server.** `autoConnectIfEnabled` skips while
  NE is `.connected` ("Skipping auto-connect: already connected"); the certificate
  reconnect and the `AppStateManager` retries replay the stored request or configuration;
  and `VPNServerOrder.fastest` sorts by `score` with no randomness, so asking again returns
  the same server. `VPNServerFilter` has no exclusion.

So B's detector is C's trigger. **(ac) One ladder, B then C.**

## 1. The ladder — `TunnelLivenessSupervisor`

A state machine, one per app process, active only while NE reports `.connected`.

- **Dead** = NE `.connected` and the local agent **not `.connected` for 60 s in a row**,
  with at least one `serverUnreachable` or `connectionError` in that window. The window
  cannot start earlier than 30 s after a connect or a wake (settle). Upstream notes the
  agent "can briefly enter this state when its connection times out before retrying"
  (`Connection/…/LocalAgentFeature.swift:163`), hence the 60 s.
- **Never acts on:** `softJailed` / `hardJailed` (account-side; another server will not
  help); `clientCertificate*` / `serverCertificateError` (upstream already recovers those
  through `AppEvent.needsReconnect`); NE not `.connected` (upstream's connect timeout owns
  that); a user Disconnect in progress.
- **Rung 1 — patch B:** full restart of the same connection: `disconnect()`, then
  `connect(with:)` the saved request. It gets 60 s to bring the local agent to `.connected`.
- **Rung 2 — patch C:** still dead → put the server's node on the avoid list → connect
  with the saved request re-run **excluding** it (§ 2). 60 s again.
- **Cap:** one more re-selection excluding both, then **stop and log "giving up"** until
  the next connect or wake. No flapping.
- **Reset** as soon as the local agent is `.connected`.
- **Log:** one line per step, prefixed `[liveness]`, e.g.
  `[liveness] rung 2: IT#44 dead 60 s → re-select excluding IT#44`. The unified log and
  the fork's `ProtonVPN.log` are the audit.
- **(ac) Timing: moderate.** Worst case ≈ 30 + 60 + ~10 + 60 + ~10 s ≈ **3 min** to a
  different server, against 64 min on 2026-09-10.

**Open question carried into the live test:** whether rung 1's in-app restart yields a
*fresh extension process* — the thing that healed the wake case (the extension ignores
SIGTERM; only a new process recovered). Recorded as the extension PID before and after
rung 1. If the process survives, rung 1 only costs ~70 s before rung 2, and the finding
feeds #2 / #3.

## 2. Re-selection and the avoid list

- **Unit of exclusion: the node** — `Logical.domain` / `ServerModel.domain`, e.g.
  `node-it-09.protonvpn.net`. *Amended while implementing:* the section first said "the
  logical server", but several logical servers share one node and one IP — the fork's own
  log has `Server selected: IT#96 (node-it-09.protonvpn.net)` → `Connected to: 195.86.6.249`,
  and on 2026-09-10 Quick Connect picked `IT#105 (node-it-09.protonvpn.net)` on the same
  `195.86.6.249`. Excluding only the logical id could re-select a sibling on the same dead
  node; excluding the node covers the logical server too.
- **Mechanism:** `VpnServerSelector.selectServer(connectionRequest:…, excluding: Set<String> = [])`
  (node domains). Empty set → today's single `repository.getFirstServer`. Non-empty → the
  same filters and order through `repository.getServers(filteredBy:orderedBy:)`
  (`Persistence/Repository.swift:89`), first candidate whose node is not excluded. No
  change to the Persistence package.
- **(ac) Same intent, minus the dead server.** Order of attempts:
  1. the saved request unchanged — its filters, order, server type (Secure Core / P2P /
     Tor) and protocol — excluding the dead server;
  2. if the request was pinned to that one server (`.server(model)` →
     `.logicalID(model.id)`), widen to that server's **exit country**, fastest first;
  3. if nothing matches, Quick Connect, still excluding.
  - **A `.gateway` request never widens** outside its gateway; it stops and logs, because
    leaving a dedicated gateway changes the security posture.
- **Avoid list:** in memory, `node → expiry`, TTL 30 min, lost on quit. Consulted by
  the ladder's re-selections, by `VpnGateway.autoConnect()` (launch and wake — flagged for
  the duration of its connect, since an auto-connect profile carries the `.profile` trigger)
  and by any `.auto` quick connect, so a wake does not return to the dead node. **A user-initiated connect ignores it** — a
  hand-picked IT#44 connects to IT#44.
- **On Demand:** the rungs use `VpnGateway`'s own `disconnect()` then `connect(with:)`,
  as `protonvpn://reconnect` does — which already disarms and re-arms On Demand correctly
  and clears the in-memory `connectAllowed` veto (patch D, measured 6 s, #5).

## 3. Wiring, files, tunables

| File | Change |
|---|---|
| **new** `libraries/Core/LegacyCommon/Sources/LegacyCommon/Core/Liveness/` (`TunnelLivenessSupervisor`, `LivenessConfiguration`, `LivenessReselection`) + `Core/VpnGateway+Liveness.swift` (the glue) | the state machine; a `TunnelRecoveryActions` protocol (`restartSameServer()`, `reselect(excluding:)`); the TTL avoid list. Clock via `@Dependency(\.continuousClock)`, as `AppStateManager` does |
| `…/Core/VpnManager+LocalAgent.swift` `didChangeState` | **+1 line**: post `Notification.Name.livenessLocalAgentStateChanged` (declared in LegacyCommon — `AppEvent` lives in `Domain`, which cannot see `LocalAgentState`) carrying the real `LocalAgentState`. The single `localAgentStateChanged: (Bool?) -> Void` closure (already taken by `AppStateManager`, `AppStateManager.swift:426`) is left alone |
| `…/Core/VpnGateway.swift` | owns the supervisor; feeds it NE state (it already observes `AppEvent.appStateManagerStateChange`) and connect events; implements the two actions; passes `excluding` into selection; active only when `!shouldUseNewConnectionFeature` |
| `…/Core/VpnServerSelector.swift` | the `excluding:` parameter |
| `apps/macos/…/NavigationService.swift` `handleWake` | tells the supervisor a wake happened (settle window) |
| `…/PropertiesManager` | the tunables below, same pattern as `onDemandEnabled` |

**Tunables and kill switch** (fork's defaults domain `io.github.colangelo.protonvpn.mac`):
`LivenessEnabled` (default `true`), `LivenessDeadSeconds` 60, `LivenessRungSeconds` 60,
`LivenessSettleSeconds` 30, `LivenessAvoidMinutes` 30.
`defaults write io.github.colangelo.protonvpn.mac LivenessEnabled -bool false` switches
the ladder off without a rebuild.

**Commit hygiene.** The supervisor, the selector exclusion and the notification are
upstream-bound *candidates* (after #11 only), so they are separate commits from anything
fork-only; new files carry the "fork addition" header like `ControlLinkTests.swift`.

**The heal daemon does not interfere.** It addresses the shipped app by process name and
NE title (`protonvpn-heal.sh`: `pgrep -x`, `scutil --nc status ProtonVPN`), which the fork
does not share (session learnings rule 8); with the shipped app Disconnected while the
fork runs, the daemon reads `not-ours`. Whether it retires or becomes a backstop once the
fork replaces the shipped app is decided under #11, in macos-setup.

**Out of scope:** patch A (#2, adapter-side rebind); iOS and the new `Connection`
package; NE's own On Demand respawn.

## 4. Testing and the live falsifier

**Unit (in `LegacyCommonTests`, run by `just test`, written first):**

- `TunnelLivenessSupervisorTests` (`TestClock`, fake actions): a 45 s blip → nothing;
  60 s unreachable → rung 1; healthy after rung 1 → reset, no rung 2; still dead → rung 2
  excluding the server; after two re-selections → gives up; jailed / certificate states →
  never; NE not connected → never; settle after connect / wake respected;
  `LivenessEnabled=false` → never; avoid-list entry expires after 30 min.
- `VpnServerSelectorTests` additions: fastest with exclusion → next-best score; an
  excluded pinned server → widened to its country; all excluded → `nil`.
- The fallback order (request → country → Quick Connect; gateway never widens) as a pure
  function with its own tests.

**Live falsifier on m4m — declared before any code:**

1. Shipped app Disconnected; the fork launched by path and connected (repo rules: never
   two tunnels; launch by path).
2. Block the fork's server IP in a private pf anchor (`com.apple/liveness-falsifier`, behind a
   reference-counted `pfctl -E` token; states to it killed) — reproduces
   2026-09-10: NE stays Connected, the local agent goes `serverUnreachable`.
3. **PASS:** within ~3 min the fork's log shows `[liveness] rung 1` then `rung 2`, a
   `Server selected:` naming a server on a *different* node, `10.2.0.1` answers, the exit IP
   changes. **FAIL:** still on the blackholed server after 5 min, or any rung within the
   first 60 s.
4. Record the extension PID before and after rung 1 (the fresh-process question, § 1).
5. Clean-up: flush the anchor and release the token (the script does it on every exit); quit the fork; the shipped app's Quick
   Connect. Steps 2 and 5 need ac's sudo.

**No false positives:** the fork on a normal connection for ~30 min with zero
`[liveness] rung` lines; the overnight soak belongs to #11.

## Done when

- `just test` green with the new tests; the live falsifier PASSes on m4m with its log
  lines pasted on #3 and #4.
- #3 and #4 closed with that evidence; the extension-PID finding recorded on #2 / #3.

## Amendments while implementing (2026-09-11)

- **Exclusion unit → the node** (§ 2), evidence above.
- **pf, not a blackhole route, for the falsifier** (§ 4). NE installs no host route to the
  endpoint (`netstat -rn` has no `149.22.91.161` while the shipped app is connected to it),
  and the WireGuard extension sends from an interface-bound socket, whose scoped route lookup
  would most likely bypass an unscoped blackhole route — the test would prove nothing. pf
  drops per packet regardless. Scripted: `just liveness-falsifier` (`tools/liveness-falsifier.sh`).
- **Review fixes** (independent review of `57fd2c0fb..054e3a4c6`): the pending re-selection
  is cleared right after the ladder's own `connect(with:)` returns, so an early return
  (deprecated protocol, authorizer refusal) cannot hand it to a later, unrelated connect; and
  `autoConnect()` is flagged so an auto-connect *profile* (trigger `.profile`) still skips
  avoided nodes.
