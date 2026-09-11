---
type: plan
title: "The liveness ladder — implementation plan (patches B and C, #3 #4)"
description: "Task-by-task TDD plan for docs/2026-09-11-liveness-ladder-design.md: selector exclusion, the tunables, the re-selection candidates, the TunnelLivenessSupervisor state machine, the VpnGateway glue, then the live falsifier on m4m. Every task names its files, the exact interfaces it produces, the tests first and the command that proves them."
tags: [protonvpn, fork, patch-b, patch-c, liveness, plan]
timestamp: 2026-09-11
---

# The liveness ladder — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When NE says Connected but the local agent stays unreachable, the fork restarts the same connection once, then re-selects excluding the dead logical server — at most twice — instead of sitting on a dead server for an hour.

**Architecture:** A pure state machine (`TunnelLivenessSupervisor`, timers on the TCA `continuousClock`) fed by the local agent's real state, NE state, wake and user actions; it calls two actions that `VpnGateway` implements through its own `disconnect` / `connect(with:)`. `VpnServerSelector` gains an `excluding:` set; the fallback order (same intent → the pinned server's country → Quick Connect; gateways never widen) is a pure function.

**Tech Stack:** Swift 5.10 packages in `ProtonVPN.xcworkspace`; XCTest; swift-dependencies (`withDependencies`, `@Dependency(\.continuousClock)`); swift-clocks `TestClock`; `just test` (runs `libraries/Core/LegacyCommon`'s tests from the package root).

**Spec:** `docs/2026-09-11-liveness-ladder-design.md` (approved by ac 2026-09-11).

## Global Constraints

- macOS legacy connection stack only: everything is inert when `FeatureFlagsRepository.isConnectionFeatureEnabled` is `true` (iOS).
- Thresholds: dead after **60 s** of the local agent not `.connected` (with a `serverUnreachable`/`connectionError` seen), **30 s** settle after a connect or wake, **60 s** per rung, **30 min** avoid list, **2** re-selections max, then give up until the next connect or wake.
- Defaults keys (fork's domain `io.github.colangelo.protonvpn.mac`, macOS `UserDefaults.standard`): `LivenessEnabled` (default true), `LivenessDeadSeconds`, `LivenessRungSeconds`, `LivenessSettleSeconds`, `LivenessAvoidMinutes`; read once at launch.
- Never act on `softJailed`, `hardJailed`, `clientCertificateExpired`, `clientCertificateUnknownCA`, `serverCertificateError`; never while NE is not `.connected`.
- Exclusion unit = logical server id (`ServerModel.id`, `Logical.id`).
- A user-initiated connect never consults the avoid list; the ladder never rewrites `lastConnectionRequest`.
- Log lines start with `[liveness]`, category `.connection`.
- New files carry the fork-addition GPL header (copy it from `Tests/LegacyCommonTests/Core/ControlLinkTests.swift`, changing the file name).
- Upstream files get the smallest possible edits; commit by pathspec; `git checkout -- ProtonVPN.xcworkspace/xcshareddata/swiftpm/Package.resolved` before each commit; nothing upstream before #11.

**Deviation from the spec's file table, decided while planning:** the tunables are read by `LivenessConfiguration.load(from:)` in the new code rather than added to `PropertiesManager` (five protocol members + mock for values read once) — the keys, domain and behaviour are the spec's; the upstream diff is smaller. The wake hook lives in the gateway glue (`NSWorkspace.didWakeNotification`) instead of `NavigationService`, for the same reason.

Paths below are relative to `libraries/Core/LegacyCommon/` unless they start with the repo root.

---

### Task 1: `VpnServerSelector` can exclude logical servers

**Files:**
- Modify: `Sources/LegacyCommon/Core/VpnServerSelector.swift` (`selectServer`, plus one private helper)
- Test: `Tests/LegacyCommonTests/Core/VpnServerSelectorTests.swift` (append)

**Interfaces:**
- Produces: `VpnServerSelector.selectServer(connectionRequest: ConnectionRequest, fallbackToStandard: Bool = false, excluding: Set<String> = []) -> ServerModel?` — with a non-empty set and no candidate left it returns `nil` **without** calling `notifyResolutionUnavailable`.

- [ ] **Step 1: Write the failing tests** — append inside `VpnServerSelectorTests`, before `makeMockServer`:

```swift
    // MARK: - Fork: liveness ladder exclusion (#4)

    private func select(
        _ connectionType: ConnectionRequestType,
        excluding: Set<String>,
        notified: ((ResolutionUnavailableReason) -> Void)? = nil
    ) -> ServerModel? {
        withDependencies {
            $0.serverRepository = repository
        } operation: {
            let selector = VpnServerSelector(
                serverType: .standard,
                userTier: 3,
                connectionProtocol: connectionProtocol,
                smartProtocolConfig: smartProtocolConfig,
                appStateGetter: appStateGetter
            )
            selector.notifyResolutionUnavailable = { _, _, reason in notified?(reason) }
            let request = ConnectionRequest(
                serverType: .standard,
                connectionType: connectionType,
                connectionProtocol: connectionProtocol,
                netShieldType: .off,
                natType: .default,
                safeMode: true,
                portForwarding: true,
                profileId: nil,
                profileName: nil,
                trigger: nil
            )
            return selector.selectServer(connectionRequest: request, excluding: excluding)
        }
    }

    func testExclusionSkipsTheFastestAndPicksTheNextBestScore() {
        XCTAssertEqual(select(.country("US", .fastest), excluding: [])?.id, "US1") // score 6 beats US0's 7
        XCTAssertEqual(select(.country("US", .fastest), excluding: ["US1"])?.id, "US0")
    }

    func testExcludingEveryCandidateReturnsNilWithoutAnUnavailabilityAlert() {
        var reasons: [ResolutionUnavailableReason] = []
        XCTAssertNil(select(.country("US", .fastest), excluding: ["US0", "US1"], notified: { reasons.append($0) }))
        XCTAssertTrue(reasons.isEmpty, "a liveness re-selection must not push an alert: \(reasons)")
    }

    func testAnExcludedPinnedServerIsNotReturned() {
        let pinned = ServerModel(server: servers["US1"]!)
        XCTAssertEqual(select(.country("US", .server(pinned)), excluding: [])?.id, "US1")
        XCTAssertNil(select(.country("US", .server(pinned)), excluding: ["US1"]))
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run (repo root): `just test -only-testing:LegacyCommonTests/VpnServerSelectorTests`
Expected: build error `extra argument 'excluding' in call`.

- [ ] **Step 3: Implement** — in `VpnServerSelector.selectServer`, change the signature and the two repository calls, and return early on an exhausted exclusion:

```swift
    public func selectServer(
        connectionRequest: ConnectionRequest,
        fallbackToStandard: Bool = false,
        excluding: Set<String> = []
    ) -> ServerModel? {
```

```swift
        var result: VPNServer? = firstServer(filteredBy: filters, orderedBy: order, excluding: excluding)
        // this should be the only case when we want to enforce p2p for PF but there are no p2p servers
        if result == nil, fallbackToStandard, type == .p2p {
            // just do filtering again without p2p limitation
            result = firstServer(
                filteredBy: connectionRequest.locationFilters + [VPNServerFilter.features(.standard)],
                orderedBy: order,
                excluding: excluding
            )
        }

        guard let server = result else {
            if !excluding.isEmpty {
                // Fork (liveness ladder): nothing left once the dead servers are excluded — the caller widens; no alert.
                log.info("No servers left once \(excluding.sorted()) are excluded", category: .persistence)
                return nil
            }
            log.error("No servers satisfy requested criteria", category: .persistence)
```

and add below `selectServer`:

```swift
    /// Fork (liveness ladder, #4): `getFirstServer`, skipping the given logical servers. `fastest` is a
    /// deterministic score order, so asking again without this returns the same dead server.
    private func firstServer(
        filteredBy filters: [VPNServerFilter],
        orderedBy order: VPNServerOrder,
        excluding: Set<String>
    ) -> VPNServer? {
        guard !excluding.isEmpty else {
            return repository.getFirstServer(filteredBy: filters, orderedBy: order)
        }
        guard let candidate = repository.getServers(filteredBy: filters, orderedBy: order)
            .first(where: { !excluding.contains($0.logical.id) }) else {
            return nil
        }
        return repository.getFirstServer(filteredBy: [.logicalID(candidate.logical.id)], orderedBy: order)
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `just test -only-testing:LegacyCommonTests/VpnServerSelectorTests`
Expected: every `VpnServerSelectorTests` case passed, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git checkout -- ProtonVPN.xcworkspace/xcshareddata/swiftpm/Package.resolved
git add -- libraries/Core/LegacyCommon/Sources/LegacyCommon/Core/VpnServerSelector.swift libraries/Core/LegacyCommon/Tests/LegacyCommonTests/Core/VpnServerSelectorTests.swift
git commit -m "feat(selection): VpnServerSelector can exclude logical servers (liveness ladder, #4)"
```

---

### Task 2: the tunables — `LivenessConfiguration`

**Files:**
- Create: `Sources/LegacyCommon/Core/Liveness/LivenessConfiguration.swift`
- Test: `Tests/LegacyCommonTests/Core/LivenessConfigurationTests.swift`

**Interfaces:**
- Produces: `struct LivenessConfiguration: Equatable { var enabled: Bool; var deadAfter, rungWindow, settle, avoidFor: Duration; var maxReselections: Int; static func load(from: UserDefaults) -> LivenessConfiguration }`; defaults `true, 60 s, 60 s, 30 s, 1800 s, 2`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
@testable import LegacyCommon
import XCTest

final class LivenessConfigurationTests: XCTestCase {
    private let suite = "LivenessConfigurationTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testTheDesignDefaults() {
        let configuration = LivenessConfiguration()
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.deadAfter, .seconds(60))
        XCTAssertEqual(configuration.rungWindow, .seconds(60))
        XCTAssertEqual(configuration.settle, .seconds(30))
        XCTAssertEqual(configuration.avoidFor, .seconds(30 * 60))
        XCTAssertEqual(configuration.maxReselections, 2)
        XCTAssertEqual(LivenessConfiguration.load(from: defaults), configuration)
    }

    func testOverridesAreRead() {
        defaults.set(false, forKey: "LivenessEnabled")
        defaults.set(90, forKey: "LivenessDeadSeconds")
        defaults.set(45, forKey: "LivenessRungSeconds")
        defaults.set(10, forKey: "LivenessSettleSeconds")
        defaults.set(5, forKey: "LivenessAvoidMinutes")
        let configuration = LivenessConfiguration.load(from: defaults)
        XCTAssertFalse(configuration.enabled)
        XCTAssertEqual(configuration.deadAfter, .seconds(90))
        XCTAssertEqual(configuration.rungWindow, .seconds(45))
        XCTAssertEqual(configuration.settle, .seconds(10))
        XCTAssertEqual(configuration.avoidFor, .seconds(300))
    }

    func testNonPositiveValuesKeepTheDefaults() {
        defaults.set(0, forKey: "LivenessDeadSeconds")
        defaults.set(-5, forKey: "LivenessAvoidMinutes")
        XCTAssertEqual(LivenessConfiguration.load(from: defaults), LivenessConfiguration())
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `just test -only-testing:LegacyCommonTests/LivenessConfigurationTests` → `cannot find 'LivenessConfiguration' in scope`.

- [ ] **Step 3: Implement** (after the fork header):

```swift
import Foundation

/// Tunables for the liveness ladder (docs/2026-09-11-liveness-ladder-design.md), read once at launch from the
/// app's defaults — `defaults write io.github.colangelo.protonvpn.mac LivenessEnabled -bool false` switches it off.
struct LivenessConfiguration: Equatable {
    var enabled = true
    var deadAfter: Duration = .seconds(60)
    var rungWindow: Duration = .seconds(60)
    var settle: Duration = .seconds(30)
    var avoidFor: Duration = .seconds(30 * 60)
    var maxReselections = 2

    enum Key {
        static let enabled = "LivenessEnabled"
        static let deadSeconds = "LivenessDeadSeconds"
        static let rungSeconds = "LivenessRungSeconds"
        static let settleSeconds = "LivenessSettleSeconds"
        static let avoidMinutes = "LivenessAvoidMinutes"
    }

    /// Missing or non-positive values keep the defaults above.
    static func load(from defaults: UserDefaults) -> LivenessConfiguration {
        var configuration = LivenessConfiguration()
        if defaults.object(forKey: Key.enabled) != nil {
            configuration.enabled = defaults.bool(forKey: Key.enabled)
        }
        if let seconds = positive(defaults.double(forKey: Key.deadSeconds)) {
            configuration.deadAfter = .seconds(seconds)
        }
        if let seconds = positive(defaults.double(forKey: Key.rungSeconds)) {
            configuration.rungWindow = .seconds(seconds)
        }
        if let seconds = positive(defaults.double(forKey: Key.settleSeconds)) {
            configuration.settle = .seconds(seconds)
        }
        if let minutes = positive(defaults.double(forKey: Key.avoidMinutes)) {
            configuration.avoidFor = .seconds(minutes * 60)
        }
        return configuration
    }

    private static func positive(_ value: Double) -> Double? {
        value > 0 ? value : nil
    }
}
```

- [ ] **Step 4: Run to verify they pass** — same command → 3 passed.

- [ ] **Step 5: Commit** — `git add` the two new files; `git commit -m "feat(liveness): LivenessConfiguration — the ladder's tunables and kill switch from defaults (#3 #4)"`.

---

### Task 3: the fallback order — `LivenessReselection`

**Files:**
- Create: `Sources/LegacyCommon/Core/Liveness/LivenessReselection.swift`
- Test: `Tests/LegacyCommonTests/Core/LivenessReselectionTests.swift`

**Interfaces:**
- Produces: `enum LivenessReselection { static func candidates(saved: ConnectionRequest?, quickConnect: ConnectionRequest) -> [ConnectionRequest] }` and `extension ConnectionRequest { func withConnectionType(_: ConnectionRequestType) -> ConnectionRequest }`.

- [ ] **Step 1: Write the failing tests**

```swift
import CommonNetworking
import Domain
import DomainTestSupport
@testable import LegacyCommon
import XCTest

final class LivenessReselectionTests: XCTestCase {
    private func request(_ type: ConnectionRequestType, serverType: ServerType = .standard) -> ConnectionRequest {
        ConnectionRequest(
            serverType: serverType,
            connectionType: type,
            connectionProtocol: .vpnProtocol(.wireGuard(.udp)),
            netShieldType: .level1,
            natType: .default,
            safeMode: true,
            portForwarding: false,
            profileId: "p",
            profileName: "profile",
            trigger: .quick
        )
    }

    private lazy var quick = request(.fastest)

    func testNoSavedRequestFallsBackToQuickConnect() {
        XCTAssertEqual(LivenessReselection.candidates(saved: nil, quickConnect: quick).map(\.id), [quick.id])
    }

    func testSameIntentFirstThenQuickConnect() {
        let saved = request(.country("IT", .fastest))
        XCTAssertEqual(LivenessReselection.candidates(saved: saved, quickConnect: quick).map(\.id), [saved.id, quick.id])
    }

    func testAPinnedServerWidensToItsExitCountry() {
        let pinned = ServerModel(server: .mock)
        let saved = request(.country(pinned.countryCode, .server(pinned)))
        let candidates = LivenessReselection.candidates(saved: saved, quickConnect: quick)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates.first?.id, saved.id)
        XCTAssertEqual(candidates.last?.id, quick.id)
        guard case let .country(code, .fastest) = candidates[1].connectionType else {
            return XCTFail("expected the fastest in the pinned server's exit country, got \(candidates[1].connectionType)")
        }
        XCTAssertEqual(code, pinned.exitCountryCode)
        XCTAssertEqual(candidates[1].netShieldType, saved.netShieldType)
        XCTAssertEqual(candidates[1].profileId, saved.profileId)
        XCTAssertEqual(candidates[1].serverType, saved.serverType)
    }

    func testSecureCorePinnedIsAlreadyCountryWideAndDoesNotWiden() {
        let pinned = ServerModel(server: .mock)
        let saved = request(.country(pinned.countryCode, .server(pinned)), serverType: .secureCore)
        XCTAssertEqual(LivenessReselection.candidates(saved: saved, quickConnect: quick).map(\.id), [saved.id, quick.id])
    }

    func testAGatewayNeverWidens() {
        let saved = request(.gateway(name: "X"))
        XCTAssertEqual(LivenessReselection.candidates(saved: saved, quickConnect: quick).map(\.id), [saved.id])
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `just test -only-testing:LegacyCommonTests/LivenessReselectionTests` → `cannot find 'LivenessReselection' in scope`. (If `.wireGuard(.udp)` or `.level1` do not compile, use the spellings found in `VpnServerSelectorTests` / `ConnectionRequest.swift` — they are fixture values only.)

- [ ] **Step 3: Implement**

```swift
import CommonNetworking
import Domain

/// The requests the liveness ladder tries, in order, when it abandons a dead server; the caller excludes the dead
/// logical servers from each (docs/2026-09-11-liveness-ladder-design.md § 2). Same intent first; a request pinned
/// to one server widens to that server's exit country; then Quick Connect. A gateway never widens — leaving a
/// dedicated gateway changes the security posture. A Secure Core "server" request already selects by country.
enum LivenessReselection {
    static func candidates(saved: ConnectionRequest?, quickConnect: ConnectionRequest) -> [ConnectionRequest] {
        guard let saved else {
            return [quickConnect]
        }
        switch saved.connectionType {
        case .gateway:
            return [saved]
        case let .country(_, .server(model)) where saved.serverType != .secureCore:
            return [saved, saved.withConnectionType(.country(model.exitCountryCode, .fastest)), quickConnect]
        default:
            return [saved, quickConnect]
        }
    }
}

extension ConnectionRequest {
    /// A copy with another connection type (upstream has `withChanged` for every other field).
    func withConnectionType(_ connectionType: ConnectionRequestType) -> ConnectionRequest {
        ConnectionRequest(
            serverType: serverType,
            connectionType: connectionType,
            connectionProtocol: connectionProtocol,
            netShieldType: netShieldType,
            natType: natType,
            safeMode: safeMode,
            portForwarding: portForwarding,
            profileId: profileId,
            profileName: profileName,
            trigger: trigger
        )
    }
}
```

- [ ] **Step 4: Run to verify they pass** — same command → 5 passed.

- [ ] **Step 5: Commit** — `git commit -m "feat(liveness): LivenessReselection — same intent, pinned widens to its country, then Quick Connect (#4)"`.

---

### Task 4: the ladder — `TunnelLivenessSupervisor`

**Files:**
- Create: `Sources/LegacyCommon/Core/Liveness/TunnelLivenessSupervisor.swift`
- Test: `Tests/LegacyCommonTests/Core/TunnelLivenessSupervisorTests.swift`

**Interfaces:**
- Consumes: `LivenessConfiguration` (Task 2); `LocalAgentState` (`Sources/LegacyCommon/Models/LocalAgent/LocalAgentState.swift`, cases `connecting, connected, softJailed, hardJailed, connectionError, serverUnreachable, serverCertificateError, clientCertificateExpired, clientCertificateUnknownCA, disconnected`).
- Produces:
  - `extension Notification.Name { static let livenessLocalAgentStateChanged }` (object = `LocalAgentState`)
  - `protocol TunnelRecoveryActions: AnyObject { func restartSameServer(); func reselect(excluding logicalIDs: Set<String>) }`
  - `final class TunnelLivenessSupervisor { init(configuration:); weak var actions; var avoided: Set<String>; func tunnelDidConnect(to logicalID: String?); func tunnelDidDisconnect(); func localAgentDidChange(_ state: LocalAgentState); func systemDidWake(); func userDidTakeOver() }` — all inputs on the main thread.

- [ ] **Step 1: Write the failing tests**

```swift
import Clocks
import Dependencies
import Foundation
@testable import LegacyCommon
import XCTest

private final class RecoveryActionsSpy: TunnelRecoveryActions {
    var calls: [String] = []
    func restartSameServer() { calls.append("restart") }
    func reselect(excluding logicalIDs: Set<String>) { calls.append("reselect:" + logicalIDs.sorted().joined(separator: ",")) }
}

@MainActor
final class TunnelLivenessSupervisorTests: XCTestCase {
    private var clock: TestClock<Duration>!
    private var spy: RecoveryActionsSpy!
    private var supervisor: TunnelLivenessSupervisor!

    override func setUp() {
        super.setUp()
        clock = TestClock()
        spy = RecoveryActionsSpy()
        supervisor = makeSupervisor(LivenessConfiguration())
    }

    private func makeSupervisor(_ configuration: LivenessConfiguration) -> TunnelLivenessSupervisor {
        let supervisor = withDependencies { $0.continuousClock = clock } operation: {
            TunnelLivenessSupervisor(configuration: configuration)
        }
        supervisor.actions = spy
        return supervisor
    }

    /// Lets timer tasks register their sleeps, moves the clock, lets the woken tasks run.
    private func advance(_ seconds: Int) async {
        for _ in 0 ..< 100 { await Task.yield() }
        await clock.advance(by: .seconds(seconds))
        for _ in 0 ..< 100 { await Task.yield() }
    }

    /// Connected to `id`, agent healthy, settle over (t = 30 s), then the agent goes unreachable.
    private func connectAndGoDead(_ id: String = "IT44") async {
        supervisor.tunnelDidConnect(to: id)
        supervisor.localAgentDidChange(.connected)
        await advance(30)
        supervisor.localAgentDidChange(.serverUnreachable)
    }

    /// After an action: the ladder's own disconnect, then NE connected to `id` with the agent unreachable.
    private func reconnectStillDead(_ id: String) {
        supervisor.tunnelDidDisconnect()
        supervisor.tunnelDidConnect(to: id)
        supervisor.localAgentDidChange(.serverUnreachable)
    }

    func testABlipShorterThanTheDeadWindowDoesNothing() async {
        await connectAndGoDead()
        await advance(45)
        supervisor.localAgentDidChange(.connected)
        await advance(120)
        XCTAssertEqual(spy.calls, [])
    }

    func testSixtySecondsUnreachableRestartsTheSameServer() async {
        await connectAndGoDead()
        await advance(59)
        XCTAssertEqual(spy.calls, [])
        await advance(2)
        XCTAssertEqual(spy.calls, ["restart"])
    }

    func testHealthyAfterTheRestartResetsTheLadder() async {
        await connectAndGoDead()
        await advance(61)
        supervisor.tunnelDidDisconnect()
        supervisor.tunnelDidConnect(to: "IT44")
        supervisor.localAgentDidChange(.connected)
        await advance(300)
        XCTAssertEqual(spy.calls, ["restart"])
    }

    func testStillDeadAfterTheRestartReselectsExcludingTheServer() async {
        await connectAndGoDead()
        await advance(61)
        reconnectStillDead("IT44")
        await advance(61)
        XCTAssertEqual(spy.calls, ["restart", "reselect:IT44"])
        XCTAssertEqual(supervisor.avoided, ["IT44"])
    }

    func testGivesUpAfterTwoReselectionsAndStartsOverOnWake() async {
        await connectAndGoDead()
        await advance(61)
        reconnectStillDead("IT44")
        await advance(61)
        reconnectStillDead("IT45")
        await advance(61)
        reconnectStillDead("IT46")
        await advance(61)
        await advance(300)
        XCTAssertEqual(spy.calls, ["restart", "reselect:IT44", "reselect:IT44,IT45"])

        supervisor.systemDidWake()
        supervisor.localAgentDidChange(.serverUnreachable)
        await advance(30)
        await advance(61)
        XCTAssertEqual(spy.calls.last, "restart")
    }

    func testNeverActsOnJailedOrCertificateStates() async {
        let states: [LocalAgentState] = [
            .softJailed, .hardJailed, .clientCertificateExpired, .clientCertificateUnknownCA, .serverCertificateError,
        ]
        for state in states {
            supervisor = makeSupervisor(LivenessConfiguration())
            supervisor.tunnelDidConnect(to: "IT44")
            supervisor.localAgentDidChange(.connected)
            await advance(30)
            supervisor.localAgentDidChange(state)
            supervisor.localAgentDidChange(.serverUnreachable)
            await advance(300)
        }
        XCTAssertEqual(spy.calls, [])
    }

    func testNeverActsWhileTheTunnelIsNotConnected() async {
        supervisor.localAgentDidChange(.serverUnreachable)
        await advance(300)
        await connectAndGoDead()
        supervisor.tunnelDidDisconnect()
        await advance(300)
        XCTAssertEqual(spy.calls, [])
    }

    func testUnreachableDuringTheSettleCountsOnlyAfterIt() async {
        supervisor.tunnelDidConnect(to: "IT44")
        supervisor.localAgentDidChange(.serverUnreachable)
        await advance(30)
        await advance(59)
        XCTAssertEqual(spy.calls, [])
        await advance(2)
        XCTAssertEqual(spy.calls, ["restart"])
    }

    func testARepeatedConnectedNotificationDoesNotRestartTheSettle() async {
        supervisor.tunnelDidConnect(to: "IT44")
        supervisor.localAgentDidChange(.serverUnreachable)
        await advance(20)
        supervisor.tunnelDidConnect(to: "IT44")
        await advance(10)
        await advance(61)
        XCTAssertEqual(spy.calls, ["restart"])
    }

    func testAWakeRestartsTheSettleWindow() async {
        await connectAndGoDead()
        await advance(20)
        supervisor.systemDidWake()
        await advance(30)
        await advance(59)
        XCTAssertEqual(spy.calls, [])
        await advance(2)
        XCTAssertEqual(spy.calls, ["restart"])
    }

    func testAUserActionResetsTheLadder() async {
        await connectAndGoDead()
        await advance(61)
        supervisor.userDidTakeOver()
        supervisor.tunnelDidDisconnect()
        supervisor.tunnelDidConnect(to: "IT44")
        supervisor.localAgentDidChange(.serverUnreachable)
        await advance(30)
        await advance(61)
        XCTAssertEqual(spy.calls, ["restart", "restart"])
    }

    func testDisabledNeverActs() async {
        var configuration = LivenessConfiguration()
        configuration.enabled = false
        supervisor = makeSupervisor(configuration)
        await connectAndGoDead()
        await advance(300)
        XCTAssertEqual(spy.calls, [])
    }

    func testTheAvoidListExpiresAfterThirtyMinutes() async {
        await connectAndGoDead()
        await advance(61)
        reconnectStillDead("IT44")
        await advance(61)
        XCTAssertEqual(supervisor.avoided, ["IT44"])
        await advance(30 * 60)
        XCTAssertEqual(supervisor.avoided, [])
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `just test -only-testing:LegacyCommonTests/TunnelLivenessSupervisorTests` → `cannot find 'TunnelLivenessSupervisor' in scope`.

- [ ] **Step 3: Implement**

```swift
import Dependencies
import Foundation

extension Notification.Name {
    /// Fork (liveness ladder): posted by `VpnManager.didChangeState`, the `LocalAgentState` as `object`.
    static let livenessLocalAgentStateChanged = Notification.Name("LivenessLocalAgentStateChanged")
}

/// What the ladder asks of the gateway; both go through the gateway's own disconnect, as the main window does.
protocol TunnelRecoveryActions: AnyObject {
    /// Rung 1 (patch B): disconnect, then connect the saved request again.
    func restartSameServer()
    /// Rung 2+ (patch C): disconnect, then connect the saved request with these logical servers excluded.
    func reselect(excluding logicalIDs: Set<String>)
}

/// Patches B and C as one ladder (docs/2026-09-11-liveness-ladder-design.md). NE says Connected but the local
/// agent has not been connected for `deadAfter` → restart the same connection → still dead after `rungWindow` →
/// re-select excluding the dead logical server (avoided for `avoidFor`), at most `maxReselections` times, then
/// give up until the next connect or wake. Every input is called on the main thread; timers hop back to it.
final class TunnelLivenessSupervisor {
    @Dependency(\.continuousClock) private var clock

    let configuration: LivenessConfiguration
    weak var actions: TunnelRecoveryActions?

    /// Logical servers the ladder abandoned within the last `avoidFor`.
    var avoided: Set<String> { Set(avoidExpiries.keys) }

    private var tunnelConnected = false
    private var server: String?
    private var agentConnected = false
    private var sawAgentFailure = false
    private var blocked = false // jailed or certificate trouble: not a dead server

    private var rung = 0 // 0 = nothing done yet; 1 = restarted; n > 1 = re-selected n - 1 times
    private var excluded: Set<String> = []
    private var gaveUp = false

    private var settleTask: Task<Void, Never>?
    private var deadTask: Task<Void, Never>?
    private var avoidExpiries: [String: Task<Void, Never>] = [:]

    private var recovering: Bool { rung > 0 }

    init(configuration: LivenessConfiguration) {
        self.configuration = configuration
        if !configuration.enabled {
            log.info("[liveness] disabled (LivenessEnabled = false)", category: .connection)
        }
    }

    // MARK: - Inputs

    /// NE reports `.connected`; `logicalID` is the active server's.
    func tunnelDidConnect(to logicalID: String?) {
        guard !(tunnelConnected && server == logicalID) else {
            return // the same state posted again
        }
        if gaveUp {
            resetOutage() // a connect the ladder did not make: start over
        }
        tunnelConnected = true
        server = logicalID
        agentConnected = false
        sawAgentFailure = false
        blocked = false
        cancel(&deadTask)
        if recovering {
            evaluate() // the rung's window starts now
        } else {
            startSettle()
        }
    }

    /// NE reports anything but `.connected`.
    func tunnelDidDisconnect() {
        guard tunnelConnected else {
            return
        }
        tunnelConnected = false
        agentConnected = false
        cancel(&settleTask)
        cancel(&deadTask)
        if !recovering {
            resetOutage()
        }
    }

    func localAgentDidChange(_ state: LocalAgentState) {
        switch state {
        case .connected:
            if recovering {
                log.info("[liveness] \(server ?? "?") healthy again after rung \(rung)", category: .connection)
            }
            agentConnected = true
            cancel(&deadTask)
            resetOutage()
        case .serverUnreachable, .connectionError:
            agentConnected = false
            sawAgentFailure = true
            evaluate()
        case .connecting, .disconnected:
            agentConnected = false
            evaluate()
        case .softJailed, .hardJailed, .clientCertificateExpired, .clientCertificateUnknownCA, .serverCertificateError:
            if !blocked {
                log.info("[liveness] standing down: local agent is \(state), not a dead server", category: .connection)
            }
            agentConnected = false
            blocked = true
            cancel(&deadTask)
        }
    }

    func systemDidWake() {
        if gaveUp {
            resetOutage()
        }
        guard tunnelConnected else {
            return
        }
        cancel(&deadTask)
        startSettle()
    }

    /// The user connected, disconnected, changed a setting or logged out: the ladder steps aside.
    func userDidTakeOver() {
        cancel(&deadTask)
        resetOutage()
    }

    // MARK: - Ladder

    private func evaluate() {
        guard configuration.enabled, tunnelConnected, !agentConnected, !blocked, !gaveUp,
              settleTask == nil, deadTask == nil else {
            return
        }
        let window = recovering ? configuration.rungWindow : configuration.deadAfter
        deadTask = after(window) { [weak self] in
            self?.deadlineReached()
        }
    }

    private func deadlineReached() {
        deadTask = nil
        guard tunnelConnected, !agentConnected, !blocked, !gaveUp, recovering || sawAgentFailure else {
            return
        }
        escalate()
    }

    private func escalate() {
        let name = server ?? "unknown server"
        guard recovering else {
            rung = 1
            log.info("[liveness] rung 1: \(name) dead for \(configuration.deadAfter) while NE says Connected → restart the same connection", category: .connection)
            actions?.restartSameServer()
            return
        }
        let reselections = rung - 1
        guard reselections < configuration.maxReselections else {
            gaveUp = true
            log.info("[liveness] giving up on \(name) after \(reselections) re-selections; waiting for the next connect or wake", category: .connection)
            return
        }
        if let server {
            excluded.insert(server)
            avoid(server)
        }
        rung += 1
        let exclusion = excluded.union(avoided)
        log.info("[liveness] rung \(rung): \(name) still dead → re-select excluding \(exclusion.sorted())", category: .connection)
        actions?.reselect(excluding: exclusion)
    }

    private func resetOutage() {
        rung = 0
        excluded = []
        gaveUp = false
        sawAgentFailure = false
    }

    // MARK: - Avoid list

    private func avoid(_ logicalID: String) {
        avoidExpiries[logicalID]?.cancel()
        avoidExpiries[logicalID] = after(configuration.avoidFor) { [weak self] in
            self?.avoidExpiries[logicalID] = nil
        }
    }

    // MARK: - Timers

    private func startSettle() {
        cancel(&settleTask)
        settleTask = after(configuration.settle) { [weak self] in
            self?.settleTask = nil
            self?.evaluate()
        }
    }

    private func after(_ duration: Duration, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor [clock] in
            do {
                try await clock.sleep(for: duration)
            } catch {
                return // cancelled
            }
            body()
        }
    }

    private func cancel(_ task: inout Task<Void, Never>?) {
        task?.cancel()
        task = nil
    }
}
```

- [ ] **Step 4: Run to verify they pass** — same command → 13 passed. If a timing test is flaky, raise the yield count in `advance` rather than loosening an assertion.

- [ ] **Step 5: Commit** — `git commit -m "feat(liveness): TunnelLivenessSupervisor — restart, then re-select excluding, then give up (patches B+C, #3 #4)"`.

---

### Task 5: wire it — `VpnGateway` and the local agent

**Files:**
- Create: `Sources/LegacyCommon/Core/VpnGateway+Liveness.swift`
- Modify: `Sources/LegacyCommon/Core/VpnGateway.swift` (three stored properties; one line at the end of `init`; one line in `appStateChanged`; the `server:` argument in `connect(with:)`; `selectServer` becomes internal with `excluding:`)
- Modify: `Sources/LegacyCommon/Core/VpnManager+LocalAgent.swift` (`didChangeState`: one line)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: `VpnGateway: TunnelRecoveryActions`; `VpnGateway.selectServerForConnect(_:) -> ServerModel?`.

No unit test: `VpnGateway` has none upstream and needs the whole app graph; this glue is proven by the build, the unchanged suite and the live falsifier (Task 6).

- [ ] **Step 1: `VpnGateway.swift`** — after `private var connectionPreparer: VpnConnectionPreparer?` add:

```swift
    // Fork (liveness ladder, #3 #4): see TunnelLivenessSupervisor and VpnGateway+Liveness.swift.
    lazy var liveness = TunnelLivenessSupervisor(configuration: .load(from: .standard))
    var pendingLivenessReselection: (excluding: Set<String>, candidates: [ConnectionRequest])?
    var livenessObservers: [NSObjectProtocol] = []
```

at the end of `init(appStateManager:…)`, after the four `AppEvent….subscribe` lines:

```swift
        startLiveness()
```

in `appStateChanged(_:)`, after `connection = ConnectionStatus.forAppState(state)`:

```swift
        livenessAppStateChanged(state, server: appStateManager.activeConnection()?.server.id)
```

in `connect(with:)`, replace `server: selectServer(connectionRequest: requestWithUpdatedServerType),` with:

```swift
            server: selectServerForConnect(requestWithUpdatedServerType),
```

and change `private func selectServer(connectionRequest: ConnectionRequest) -> ServerModel? {` to

```swift
    func selectServer(connectionRequest: ConnectionRequest, excluding: Set<String> = []) -> ServerModel? {
```

passing it on: `let selected = selector.selectServer(connectionRequest: connectionRequest, fallbackToStandard: connectionRequest.serverType == .p2p, excluding: excluding)`.

- [ ] **Step 2: `VpnManager+LocalAgent.swift`** — in `didChangeState(state:)`, right after the `log.debug("Local agent state changed to …")` line:

```swift
        NotificationCenter.default.post(name: .livenessLocalAgentStateChanged, object: state) // fork: liveness ladder
```

- [ ] **Step 3: create `VpnGateway+Liveness.swift`** (fork header first):

```swift
import CommonNetworking
import Domain
import Foundation
#if os(macOS)
    import AppKit
#endif

/// Fork (liveness ladder, #3 #4): the ladder's inputs and the two actions it asks for. Legacy connection
/// stack only — iOS runs the Connection package (`FeatureFlagsRepository.isConnectionFeatureEnabled`).
extension VpnGateway: TunnelRecoveryActions {
    func startLiveness() {
        guard !FeatureFlagsRepository.isConnectionFeatureEnabled else {
            return
        }
        liveness.actions = self
        let center = NotificationCenter.default
        livenessObservers.append(center.addObserver(forName: .livenessLocalAgentStateChanged, object: nil, queue: .main) { [weak self] notification in
            guard let state = notification.object as? LocalAgentState else {
                return
            }
            self?.liveness.localAgentDidChange(state)
        })
        livenessObservers.append(center.addObserver(forName: AppEvent.userInitiatedVPNChange.name, object: nil, queue: .main) { [weak self] notification in
            guard let change = notification.object as? UserInitiatedVPNChange else {
                return
            }
            switch change {
            case .connect, .disconnect, .settingsChange, .logout:
                self?.liveness.userDidTakeOver()
            case .abort:
                break // also posted by the ladder's own reconnect (AppStateManager.cancelConnectionAttempt)
            }
        })
        #if os(macOS)
            livenessObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.liveness.systemDidWake()
            })
        #endif
    }

    func livenessAppStateChanged(_ state: AppState, server logicalID: String?) {
        guard !FeatureFlagsRepository.isConnectionFeatureEnabled else {
            return
        }
        if case .connected = state {
            liveness.tunnelDidConnect(to: logicalID)
        } else {
            liveness.tunnelDidDisconnect()
        }
    }

    /// The server `connect(with:)` uses. A pending ladder re-selection first — the saved request stays the saved
    /// request, only the server differs; otherwise an automatic connect skips avoided servers when it can.
    func selectServerForConnect(_ request: ConnectionRequest) -> ServerModel? {
        if let pending = pendingLivenessReselection {
            pendingLivenessReselection = nil
            for candidate in pending.candidates {
                let resolved = candidate.serverType == .unspecified ? candidate.withChanged(serverType: request.serverType) : candidate
                if let server = selectServer(connectionRequest: resolved, excluding: pending.excluding) {
                    return server
                }
            }
            log.info("[liveness] no server left once \(pending.excluding.sorted()) are excluded; staying disconnected", category: .connection)
            return nil
        }
        if request.trigger == .auto, !liveness.avoided.isEmpty,
           let server = selectServer(connectionRequest: request, excluding: liveness.avoided) {
            return server
        }
        return selectServer(connectionRequest: request)
    }

    // MARK: - TunnelRecoveryActions

    func restartSameServer() {
        let saved = lastConnectionRequest
        disconnect { [weak self] in
            self?.connect(with: saved)
        }
    }

    func reselect(excluding logicalIDs: Set<String>) {
        let saved = lastConnectionRequest
        let candidates = LivenessReselection.candidates(saved: saved, quickConnect: quickConnectConnectionRequest(trigger: .auto))
        disconnect { [weak self] in
            guard let self else {
                return
            }
            pendingLivenessReselection = (logicalIDs, candidates)
            connect(with: saved ?? candidates[0])
        }
    }
}
```

- [ ] **Step 4: Build the app and run the whole suite**

Run (repo root): `just build` → `** BUILD SUCCEEDED **` and the `.app` path; then `just test` → `Executed 118 tests` (94 + 3 selector + 3 configuration + 5 reselection + 13 supervisor), `0 failures`, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit** — `git add` the three files; `git commit -m "feat(liveness): wire the ladder — local-agent feed, NE state, wake, user takeover, gateway actions (#3 #4)"`; push `internal` + `origin`; `just published`.

---

### Task 6: install and prove it on m4m (needs ac's sudo twice)

**Files:** none changed; results go on #3 / #4 and into `AGENTS.md` (patch table rows B and C).

- [ ] **Step 1: install** — `ditto ~/Library/Developer/Xcode/DerivedData/ProtonVPN-*/Build/Products/Debug/"ProtonVPN Fork.app" "/Applications/ProtonVPN Fork.app"`.
- [ ] **Step 2: never two tunnels** — Disconnect the shipped app (its own Disconnect); verify `scutil --nc status ProtonVPN` = Disconnected; `open "/Applications/ProtonVPN Fork.app"`; `open -b io.github.colangelo.protonvpn.mac 'protonvpn://quick-connect'`; verify `scutil --nc status "ProtonVPN Fork"` = Connected, `ping -c1 10.2.0.1`, `curl -s api.ipify.org`; note the server IP from the fork's `ProtonVPN.log` (`Connected to: <ip>`) and the extension PID (`pgrep -fl WireGuard`).
- [ ] **Step 3 (ac, sudo):** `sudo route -n add -host <ip> 127.0.0.1 -blackhole`.
- [ ] **Step 4: watch** — `grep -E '\[liveness\]|Server selected|Connected to' ~/Library/Containers/io.github.colangelo.protonvpn.mac/Data/Library/Logs/ProtonVPN.log | tail -20` every 30 s for 5 min. **PASS:** `rung 1` then `rung 2`, a `Server selected:` naming a different logical server, `ping 10.2.0.1` answers, exit IP changed, all within ~3 min; extension PID before/after rung 1 recorded. **FAIL:** still on the blackholed server after 5 min, or a rung within the first 60 s.
- [ ] **Step 5 (ac, sudo):** `sudo route -n delete -host <ip>`; quit the fork gracefully; the shipped app's Quick Connect; verify it Connected.
- [ ] **Step 6: no false positives** — the fork connected normally for ~30 min: `grep -c '\[liveness\] rung' …ProtonVPN.log` unchanged.
- [ ] **Step 7: record** — paste the log lines on #3 and #4; close both with that evidence; the PID finding on #2; `AGENTS.md` patch table rows B and C → "Done 2026-09-xx"; commit by pathspec; push; `just published`.
