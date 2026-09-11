//
//  LivenessReselectionTests.swift
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
import DomainTestSupport
@testable import LegacyCommon
import XCTest

final class LivenessReselectionTests: XCTestCase {
    private func request(_ type: ConnectionRequestType, serverType: ServerType = .standard) -> ConnectionRequest {
        ConnectionRequest(
            serverType: serverType,
            connectionType: type,
            connectionProtocol: .smartProtocol,
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
        XCTAssertEqual(
            LivenessReselection.candidates(saved: saved, quickConnect: quick).map(\.id),
            [saved.id, quick.id]
        )
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
        XCTAssertEqual(
            LivenessReselection.candidates(saved: saved, quickConnect: quick).map(\.id),
            [saved.id, quick.id]
        )
    }

    func testAGatewayNeverWidens() {
        let saved = request(.gateway(name: "X"))
        XCTAssertEqual(LivenessReselection.candidates(saved: saved, quickConnect: quick).map(\.id), [saved.id])
    }
}
