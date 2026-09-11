//
//  KeychainConstants.swift
//  Core
//
//  Created by Jaroslav on 2021-06-22.
//  Copyright © 2021 Proton Technologies AG. All rights reserved.
//

import Foundation

public class KeychainConstants {
    // Fork: upstream uses "ProtonVPN". A login-keychain item is addressed by service name, so a
    // fork with the same name asks for — and can overwrite — the shipped app's `vpnKeys` and
    // session items (macOS prompts "Proton VPN wants to use your confidential information…").
    // Keep the two apps' credentials apart.
    public static let appKeychain = "io.github.colangelo.protonvpn"
}
