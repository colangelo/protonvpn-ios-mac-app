//
//  LivenessConfiguration.swift
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
