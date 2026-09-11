//
//  ControlLink.swift
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

import Foundation

/// An action another process can ask the app to perform through its URL scheme:
/// `open -b <bundle id> 'protonvpn://quick-connect'` (`-b` picks the app regardless of
/// which app LaunchServices has as the scheme's handler — the shipped Proton VPN app
/// registers `protonvpn://` too).
///
/// Upstream handles only `refresh`. The rest exists so that an outside supervisor — the
/// macos-setup heal daemon, which today clicks `Disconnect` / `Quick Connect` through
/// System Events — has a lever that does not need Accessibility. Every action is one
/// the user can already perform from the main window; none of them bypasses login.
public enum ControlLink: String, CaseIterable, Sendable {
    /// Upstream: re-fetch the user's data with a silent login.
    case refresh
    /// The main window's Disconnect: closes the tunnel and switches On Demand off,
    /// exactly like the click, so NE does not bring the tunnel straight back.
    case disconnect
    /// The main window's Quick Connect: the app's own server selection.
    case quickConnect = "quick-connect"
    /// Disconnect, then Quick Connect. Unlike NE's reconnect and the app's own retry,
    /// this re-runs server selection, so a dead saved server is abandoned.
    case reconnect

    public static let scheme = "protonvpn"

    /// `protonvpn://quick-connect`, `protonvpn:///quick-connect`, `protonvpn://Reconnect/`,
    /// with or without a query, all parse; anything else (another scheme, an unknown
    /// action, an action with extra path) is `nil`.
    public static func parse(_ urlString: String) -> ControlLink? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == scheme else {
            return nil
        }
        // `protonvpn://action` puts the action in `host`; `protonvpn:///action` in `path`.
        let pathPart = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let action: String
        if let host = components.host, !host.isEmpty {
            guard pathPart.isEmpty else { return nil }
            action = host
        } else {
            action = pathPart
        }
        return ControlLink(rawValue: action.lowercased())
    }
}
