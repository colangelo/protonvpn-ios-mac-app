//
//  TunnelLivenessSupervisor.swift
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
    var avoided: Set<String> {
        Set(avoidExpiries.keys)
    }

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

    private var recovering: Bool {
        rung > 0
    }

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
            log.info(
                "[liveness] rung 1: \(name) dead for \(configuration.deadAfter) while NE says Connected → restart the same connection",
                category: .connection
            )
            actions?.restartSameServer()
            return
        }
        let reselections = rung - 1
        guard reselections < configuration.maxReselections else {
            gaveUp = true
            log.info(
                "[liveness] giving up on \(name) after \(reselections) re-selections; waiting for the next connect or wake",
                category: .connection
            )
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
