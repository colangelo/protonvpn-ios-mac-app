# protonvpn-ios-mac-app — house recipes for the fork (upstream builds with Xcode)

set shell := ["bash", "-euo", "pipefail", "-c"]

# List recipes
default:
    @just --list

# Remotes, current branch, and how far `develop` is behind upstream
status:
    git remote -v | sed 's/\t/ /'
    echo "branch: $(git branch --show-current)"
    git fetch -q upstream
    echo "develop behind upstream/develop by: $(git rev-list --count develop..upstream/develop) commit(s)"
    echo "main ahead of develop by: $(git rev-list --count develop..main) commit(s)"

# Fetch upstream and fast-forward our `develop` to it (no merge commits)
sync-upstream:
    git fetch upstream --tags
    git checkout -q develop
    git merge --ff-only upstream/develop
    git push -q origin develop
    git push -q internal develop
    git checkout -q main
    echo "develop = upstream/develop $(git rev-parse --short develop); rebase main when ready: git rebase develop"

# Prove both remotes hold what HEAD holds (never trust a push that printed nothing)
published:
    sha="$(git rev-parse HEAD)"; for r in origin internal; do echo "$r: $(git ls-remote "$r" "refs/heads/$(git branch --show-current)" | cut -c1-7) (HEAD ${sha:0:7})"; done

# ---- Build prerequisites (what upstream's private GitLab provides and GitHub does not) ----
# Order for a clean clone: submodules → protun-fetch → secrets → build-unsigned → build.

# Upstream's .gitmodules uses relative GitLab URLs; swift-cargo has no public mirror and nothing in the build uses it.
# wireguard-apple comes from OUR fork (colangelo/wireguard-apple, `main` = ours, `release/ios` = upstream) — see docs/wireguard-apple-fork.md.
# Check out the 3 submodules the build needs (2 public mirrors + our wireguard-apple fork)
submodules:
    git config submodule.external/protoncore.url https://github.com/ProtonMail/protoncore_ios.git
    git config submodule.external/apple-fusion.url https://github.com/ProtonMail/apple-fusion.git
    git config submodule.external/wireguard-apple.url https://github.com/colangelo/wireguard-apple.git
    git submodule update --init external/protoncore external/apple-fusion external/wireguard-apple
    git -C external/wireguard-apple remote get-url upstream >/dev/null 2>&1 || git -C external/wireguard-apple remote add upstream https://github.com/ProtonVPN/wireguard-apple.git
    git -C external/wireguard-apple remote get-url internal >/dev/null 2>&1 || git -C external/wireguard-apple remote add internal https://gitea.cat-bluegill.ts.net/AC-forks/wireguard-apple.git
    git submodule status

# Public ProTUN release to install as the local protunFFI xcframework (see NEProviders/Package.swift)
protun_release := "v2.2.1"

# Upstream resolves protunFFI from a firewalled Nexus; without a local copy SwiftPM cannot resolve at all.
# Install the macOS slice of ProtonVPN/protun's public xcframework as NEProviders/Frameworks/protunFFI.xcframework (gitignored, ~110 MB)
protun-fetch:
    #!/usr/bin/env bash
    set -euo pipefail
    dst=libraries/Core/NEProviders/Frameworks/protunFFI.xcframework
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    command gh release download {{ protun_release }} -R ProtonVPN/protun -p 'protun-release.xcframework.zip' -D "$tmp"
    unzip -q "$tmp/protun-release.xcframework.zip" -d "$tmp"
    rm -rf "$dst"; mkdir -p "$dst"
    cp -R "$tmp/protun-release.xcframework/macos-arm64_x86_64" "$dst/"
    plutil -convert json -o - "$tmp/protun-release.xcframework/Info.plist" \
      | jq '.AvailableLibraries |= map(select(.LibraryIdentifier == "macos-arm64_x86_64"))' \
      | plutil -convert xml1 -o "$dst/Info.plist" -
    plutil -lint "$dst/Info.plist" && du -sh "$dst"

# Nothing in them is secret: the live API URL is committed in DoH.swift; the rest are empty or unused on macOS.
# Write the four gitignored ObfuscatedConstants.swift files (idempotent)
secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    hdr='// ObfuscatedConstants.swift — LOCAL, gitignored; written by `just secrets` (see AGENTS.md § Build prerequisites).
    // Upstream keeps the real file in a private repo. Nothing here is secret: the live API URL is committed in DoH.swift.

    import Foundation
    '
    printf '%s\nclass ObfuscatedConstants {\n    static let sentryDsnmacOS: String = ""\n    static let sentryDsniOS: String = ""\n\n    // DoH lookup host for alternative routing (ProtonCore DoH.apiHost); login uses DoHVPN.liveURL regardless.\n    static let apiHost: String = "vpn-api.proton.me"\n    static let humanVerificationV3Host = "https://verify.proton.me"\n\n    static let vpnIAPIdentifiers: Set<String> = []\n}\n' "$hdr" > apps/macos/ProtonVPN/ObfuscatedConstants.swift
    for d in libraries/Core/LegacyCommon/Sources/LegacyCommon libraries/Features/Home/Sources/HomeShared; do
      printf '%s\nenum ObfuscatedConstants {\n    static let fidoPortal: String = "https://account.proton.me/vpn/account-password"\n}\n' "$hdr" > "$d/ObfuscatedConstants.swift"
    done
    printf '%s\nenum ObfuscatedConstants {\n    // Internal Proton test environments; unused in our builds.\n    static let btiAPIHost: String = ""\n    static let blackAPIHost: String = ""\n}\n' "$hdr" > libraries/Features/Settings/Sources/SettingsShared/ObfuscatedConstants.swift
    git status --short --ignored | grep ObfuscatedConstants

# Our Apple team (paid Developer Program membership is required for the NetworkExtension entitlements)
team := "CW56R63WQF"
xcb := "xcodebuild -workspace ProtonVPN.xcworkspace -scheme ProtonVPN-macOS -configuration Debug -destination 'platform=macOS,arch=arm64' -skipMacroValidation -skipPackagePluginValidation"

# Compile everything without signing — proves the sources/secrets/submodules half of the build
build-unsigned:
    {{ xcb }} CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build 2>&1 | grep -E 'error:|warning: .*(entitlement|profile)|\*\* BUILD' | grep -v DTDKRemoteDeviceConnection

# Development profiles list Mac UDIDs, so a new Mac needs -allowProvisioningDeviceRegistration once.
# Signed Debug build with automatic provisioning under our team (needs the Apple ID signed in to Xcode)
build:
    {{ xcb }} -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM={{ team }} CODE_SIGN_STYLE=Automatic PROVISIONING_PROFILE_SPECIFIER="" build 2>&1 | grep -E 'error:|\*\* BUILD|\.app$' | grep -v DTDKRemoteDeviceConnection

# Where the findings are (the AGENTS.md table, as paths)
docs:
    @echo "~/_sync/dev/macos-setup/docs/2026-09-07-protonvpn-dead-tunnel-after-wake.md"
    @echo "~/_sync/dev/macos-setup/docs/2026-09-10-protonvpn-heal-session-learnings.md"
    @echo "~/_sync/dev/macos-setup/docs/HOST-CONFIG.md  (§ ProtonVPN dead tunnel after wake)"
    @echo "~/_sync/dev/macos-setup/assets/protonvpn-heal.sh"
    @echo "https://github.com/ProtonVPN/ios-mac-app/issues/35"
