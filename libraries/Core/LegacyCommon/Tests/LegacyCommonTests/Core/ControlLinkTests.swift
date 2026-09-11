//
//  ControlLinkTests.swift
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

final class ControlLinkTests: XCTestCase {
    func testEveryActionParsesInHostForm() {
        for action in ControlLink.allCases {
            XCTAssertEqual(ControlLink.parse("protonvpn://\(action.rawValue)"), action, action.rawValue)
        }
    }

    func testPathFormAndDecorationsParse() {
        XCTAssertEqual(ControlLink.parse("protonvpn:///quick-connect"), .quickConnect)
        XCTAssertEqual(ControlLink.parse("protonvpn://quick-connect/"), .quickConnect)
        XCTAssertEqual(ControlLink.parse("protonvpn://reconnect?source=heal"), .reconnect)
        XCTAssertEqual(ControlLink.parse("PROTONVPN://Disconnect"), .disconnect)
        XCTAssertEqual(ControlLink.parse("  protonvpn://refresh\n"), .refresh)
    }

    func testUpstreamRefreshLinkStillParses() {
        // The only link upstream handled; the fork must not break it.
        XCTAssertEqual(ControlLink.parse("protonvpn://refresh"), .refresh)
    }

    func testRejectsOtherSchemesUnknownActionsAndExtraPath() {
        XCTAssertNil(ControlLink.parse("https://protonvpn.com/disconnect"))
        XCTAssertNil(ControlLink.parse("protonvpn://settings/connection"))
        XCTAssertNil(ControlLink.parse("protonvpn://disconnect/now"))
        XCTAssertNil(ControlLink.parse("protonvpn://quickconnect"))
        XCTAssertNil(ControlLink.parse("protonvpn://"))
        XCTAssertNil(ControlLink.parse(""))
        XCTAssertNil(ControlLink.parse("disconnect"))
    }
}
