//
//  LivenessReselection.swift
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
