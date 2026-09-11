---
type: runbook
title: "The wireguard-apple fork — submodule wiring and workflow"
description: "Why the WireGuard adapter is a second fork (WireGuardAdapter keeps its Go handle private), its three remotes (colangelo/wireguard-apple, ProtonVPN/wireguard-apple, AC-forks/wireguard-apple) and branch model (release/ios tracks upstream, main is ours from the pinned 5742d28), how a change flows from the submodule's main to a pointer bump in the app repo, how to sync with upstream, and what a fresh clone needs."
tags: [protonvpn, fork, wireguard-apple, submodule, runbook]
timestamp: 2026-09-11
---

# The `wireguard-apple` fork — how the submodule is wired and worked on

Created 2026-09-11 for patch A (Gitea `AC-forks/protonvpn-ios-mac-app#2`).
Proton's macOS app embeds WireGuard through `external/wireguard-apple`
(`WireGuardKit` — the `WireGuardAdapter`, its `NWPath` monitor, the
`WireGuardKitGo` bridge to wireguard-go). The adapter keeps the Go tunnel
handle private, so anything that must rebind, re-handshake or log from the
adapter's side cannot be done from the app repo. Hence a fork of the
submodule, mirrored like the app.

## Remotes and branches

| Remote | URL | Role |
|---|---|---|
| `origin` | `https://github.com/colangelo/wireguard-apple.git` | our public fork of `ProtonVPN/wireguard-apple` (GitHub's default branch `master` is upstream's — irrelevant) |
| `upstream` | `https://github.com/ProtonVPN/wireguard-apple.git` | Proton's fork of `WireGuard/wireguard-apple`; their working branch is `release/ios` |
| `internal` | `https://gitea.cat-bluegill.ts.net/AC-forks/wireguard-apple.git` | house mirror, created by push-to-create; default branch `main` |

- `release/ios` — upstream's branch, unchanged. The app repo pins
  `5742d28664f58ca7317cd50525b2b08922260dbc` (*"Merge branch
  'jkb/fix/reassert-on-path-change' into 'release/ios'"*, 2026-03-12).
- `main` — **ours**, branched from that commit. Fork changes land here.
- Both branches are on both remotes. `just published`-style proof:
  `git -C external/wireguard-apple ls-remote origin refs/heads/main`.

No backlog on the fork repo itself: issues live in
`AC-forks/protonvpn-ios-mac-app` (the patch that motivates a change).

## Making a change

```
cd external/wireguard-apple
git checkout main                      # not detached HEAD
# edit Sources/WireGuardKit/…  (or Sources/WireGuardKitGo/… for the Go side)
git commit -m "…"
git push origin main && git push internal main
cd ../..
git add external/wireguard-apple       # bumps the pointer to the new commit
git commit -m "build: wireguard-apple → <sha> (<what>)"
```

Then the usual `just build`. Xcode rebuilds `WireGuardKit`/`WireGuardKitGo`
(the Go bridge target `WireGuardGoBridgemacOS` runs `make` in
`Sources/WireGuardKitGo`) on the next build.

Keep upstream-bound hunks separate from fork-only ones here too: an
adapter change worth sending to Proton goes upstream only after `#11`
(the week of verified use), with the app-side evidence.

## Syncing with upstream

```
cd external/wireguard-apple
git fetch upstream
git branch -f release/ios upstream/release/ios && git push origin release/ios && git push internal release/ios
git rebase release/ios main            # or merge; the fork is small
git push origin main && git push internal main
```

The app repo's `just sync-upstream` does not touch the submodule; after an
upstream sync of the app, check whether upstream moved the submodule pointer
(`git diff develop -- external/wireguard-apple`) and rebase `main` onto that
commit if so.

## On a fresh clone

`just submodules` clones from our fork (`origin`), checks out the pinned
commit, and adds `upstream` and `internal`. The Syncthing-synced copy on the
other Mac already carries the `.git/modules/external/wireguard-apple`
metadata; a plain `git submodule update --init` there works as well.
