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

# Where the findings are (the AGENTS.md table, as paths)
docs:
    @echo "~/_sync/dev/macos-setup/docs/2026-09-07-protonvpn-dead-tunnel-after-wake.md"
    @echo "~/_sync/dev/macos-setup/docs/2026-09-10-protonvpn-heal-session-learnings.md"
    @echo "~/_sync/dev/macos-setup/docs/HOST-CONFIG.md  (§ ProtonVPN dead tunnel after wake)"
    @echo "~/_sync/dev/macos-setup/assets/protonvpn-heal.sh"
    @echo "https://github.com/ProtonVPN/ios-mac-app/issues/35"
