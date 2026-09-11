//
//  TunnelLivenessSupervisorTests.swift
//  ProtonVPN - fork addition, 2026-09-11
//
//  This file is part of ProtonVPN.
//
//  ProtonVPN is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonVPN is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonVPN.  If not, see <https://www.gnu.org/licenses/>.
//

import Clocks
import Dependencies
import Foundation
@testable import LegacyCommon
import XCTest

private final class RecoveryActionsSpy: TunnelRecoveryActions {
    var calls: [String] = []

    func restartSameServer() {
        calls.append("restart")
    }

    func reselect(excluding nodes: Set<String>) {
        calls.append("reselect:" + nodes.sorted().joined(separator: ","))
    }
}

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
        let supervisor = withDependencies {
            $0.continuousClock = clock
        } operation: {
            TunnelLivenessSupervisor(configuration: configuration)
        }
        supervisor.actions = spy
        return supervisor
    }

    /// Lets timer tasks register their sleeps, moves the clock, lets the woken tasks run.
    @MainActor
    private func advance(_ seconds: Int) async {
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        await clock.advance(by: .seconds(seconds))
        for _ in 0 ..< 100 {
            await Task.yield()
        }
    }

    /// Connected to `id`, agent healthy, settle over (t = 30 s), then the agent goes unreachable.
    @MainActor
    private func connectAndGoDead(_ id: String = "IT44") async {
        supervisor.tunnelDidConnect(to: id)
        supervisor.localAgentDidChange(.connected)
        await advance(30)
        supervisor.localAgentDidChange(.serverUnreachable)
    }

    /// After an action: the ladder's own disconnect, then NE connected to `id` with the agent unreachable.
    @MainActor
    private func reconnectStillDead(_ id: String) {
        supervisor.tunnelDidDisconnect()
        supervisor.tunnelDidConnect(to: id)
        supervisor.localAgentDidChange(.serverUnreachable)
    }

    @MainActor
    func testABlipShorterThanTheDeadWindowDoesNothing() async {
        await connectAndGoDead()
        await advance(45)
        supervisor.localAgentDidChange(.connected)
        await advance(120)
        XCTAssertEqual(spy.calls, [])
    }

    @MainActor
    func testSixtySecondsUnreachableRestartsTheSameServer() async {
        await connectAndGoDead()
        await advance(59)
        XCTAssertEqual(spy.calls, [])
        await advance(2)
        XCTAssertEqual(spy.calls, ["restart"])
    }

    @MainActor
    func testHealthyAfterTheRestartResetsTheLadder() async {
        await connectAndGoDead()
        await advance(61)
        supervisor.tunnelDidDisconnect()
        supervisor.tunnelDidConnect(to: "IT44")
        supervisor.localAgentDidChange(.connected)
        await advance(300)
        XCTAssertEqual(spy.calls, ["restart"])
    }

    @MainActor
    func testStillDeadAfterTheRestartReselectsExcludingTheServer() async {
        await connectAndGoDead()
        await advance(61)
        reconnectStillDead("IT44")
        await advance(61)
        XCTAssertEqual(spy.calls, ["restart", "reselect:IT44"])
        XCTAssertEqual(supervisor.avoided, ["IT44"])
    }

    @MainActor
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

    @MainActor
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

    @MainActor
    func testNeverActsWhileTheTunnelIsNotConnected() async {
        supervisor.localAgentDidChange(.serverUnreachable)
        await advance(300)
        await connectAndGoDead()
        supervisor.tunnelDidDisconnect()
        await advance(300)
        XCTAssertEqual(spy.calls, [])
    }

    @MainActor
    func testUnreachableDuringTheSettleCountsOnlyAfterIt() async {
        supervisor.tunnelDidConnect(to: "IT44")
        supervisor.localAgentDidChange(.serverUnreachable)
        await advance(30)
        await advance(59)
        XCTAssertEqual(spy.calls, [])
        await advance(2)
        XCTAssertEqual(spy.calls, ["restart"])
    }

    @MainActor
    func testARepeatedConnectedNotificationDoesNotRestartTheSettle() async {
        supervisor.tunnelDidConnect(to: "IT44")
        supervisor.localAgentDidChange(.serverUnreachable)
        await advance(20)
        supervisor.tunnelDidConnect(to: "IT44")
        await advance(10)
        await advance(61)
        XCTAssertEqual(spy.calls, ["restart"])
    }

    @MainActor
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

    @MainActor
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

    @MainActor
    func testDisabledNeverActs() async {
        var configuration = LivenessConfiguration()
        configuration.enabled = false
        supervisor = makeSupervisor(configuration)
        await connectAndGoDead()
        await advance(300)
        XCTAssertEqual(spy.calls, [])
    }

    @MainActor
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
