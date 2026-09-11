//
//  VpnGateway+Liveness.swift
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

import CommonNetworking
import Domain
import Foundation
import ProtonCoreFeatureFlags
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
        livenessObservers.append(center.addObserver(
            forName: .livenessLocalAgentStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let state = notification.object as? LocalAgentState else {
                return
            }
            self?.liveness.localAgentDidChange(state)
        })
        livenessObservers.append(center.addObserver(
            forName: AppEvent.userInitiatedVPNChange.name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
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
            livenessObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.liveness.systemDidWake()
            })
        #endif
    }

    func livenessAppStateChanged(_ state: AppState, server node: String?) {
        guard !FeatureFlagsRepository.isConnectionFeatureEnabled else {
            return
        }
        if case .connected = state {
            liveness.tunnelDidConnect(to: node)
        } else {
            liveness.tunnelDidDisconnect()
        }
    }

    /// The server `connect(with:)` uses. A pending ladder re-selection first — the saved request stays the saved
    /// request, only the server differs; otherwise an automatic connect (`autoConnect()`, whatever its profile's
    /// trigger, or any `.auto` quick connect) skips avoided nodes when something else matches.
    func selectServerForConnect(_ request: ConnectionRequest) -> ServerModel? {
        if let pending = pendingLivenessReselection {
            pendingLivenessReselection = nil
            for candidate in pending.candidates {
                let resolved = candidate.serverType == .unspecified
                    ? candidate.withChanged(serverType: request.serverType)
                    : candidate
                if let server = selectServer(connectionRequest: resolved, excluding: pending.excluding) {
                    return server
                }
            }
            log.info(
                "[liveness] no server left once \(pending.excluding.sorted()) are excluded; staying disconnected",
                category: .connection
            )
            return nil
        }
        if request.trigger == .auto || livenessAutomaticConnect, !liveness.avoided.isEmpty,
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

    func reselect(excluding nodes: Set<String>) {
        let saved = lastConnectionRequest
        let candidates = LivenessReselection.candidates(
            saved: saved,
            quickConnect: quickConnectConnectionRequest(trigger: .auto)
        )
        disconnect { [weak self] in
            guard let self else {
                return
            }
            pendingLivenessReselection = (nodes, candidates)
            connect(with: saved ?? candidates[0])
            // `connect(with:)` selects synchronously — or returns earlier (deprecated protocol, authorizer refusal);
            // either way the pending re-selection must not reach a later, unrelated connect.
            pendingLivenessReselection = nil
        }
    }
}
