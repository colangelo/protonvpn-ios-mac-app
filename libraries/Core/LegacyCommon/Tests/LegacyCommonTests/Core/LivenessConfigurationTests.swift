//
//  LivenessConfigurationTests.swift
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
