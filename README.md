<p align="center">
  <a href="https://github.com/zackbart/barr">
    <img src="https://shieldcn.dev/header/graph.svg?title=Barr&subtitle=a+second+home+for+your+macOS+menu+bar+apps&logo=apple&mode=light&align=center&font=geist-mono&border=false" alt="Barr">
  </a>
</p>

<p align="center">
  <a href="https://github.com/zackbart/barr/releases/latest/download/Barr.dmg">
    <img src="https://shieldcn.dev/badge/Download-Barr.dmg-blue.svg?logo=apple&size=lg" alt="Download the latest Barr.dmg">
  </a>
  <a href="https://github.com/zackbart/barr/releases/latest">
    <img src="https://shieldcn.dev/github/release/zackbart/barr.svg" alt="Latest release">
  </a>
  <a href="https://github.com/zackbart/barr/blob/main/LICENSE">
    <img src="https://shieldcn.dev/github/license/zackbart/barr.svg" alt="License">
  </a>
  <a href="https://github.com/zackbart/barr/stargazers">
    <img src="https://shieldcn.dev/github/stars/zackbart/barr.svg" alt="Stars">
  </a>
</p>

Barr clears space in your macOS menu bar by moving the apps you choose into a
compact dropdown shelf. Your apps keep running, their icons stay within reach,
and everything else remains in the native menu bar. It is especially useful on
MacBooks where the notch leaves little room for status items.

## How it works

1. Open **Choose Apps** and select the menu bar items you want Barr to hold.
2. Barr hides those items from the menu bar and mirrors them in its shelf.
3. Click Barr's three-line icon to open the shelf, then click any item to use it
   normally. You can move an item back to the menu bar at any time.

Barr needs **Screen Recording** to mirror each selected icon and
**Accessibility** to move and activate the original status item. Processing stays
on your Mac.

## Install

Install with Homebrew:

```bash
brew tap zackbart/tap
brew install --cask barr
```

Or grab the latest `Barr.dmg` from [Releases](https://github.com/zackbart/barr/releases/latest).
Barr is a menu-bar utility (`LSUIElement`) and does not appear in the Dock.

## Repo layout

```text
app/                  XcodeGen project, Swift sources, and app assets
.github/workflows/    Tag-driven release automation
CHANGELOG.md           Release history and notable changes
README.md             Project overview
```

## Develop

```bash
brew install xcodegen
cd app
xcodegen generate && open Barr.xcodeproj
```

`app/project.yml` is the source of truth; the generated Xcode project is ignored.
Requires macOS 14+ and Xcode 16+.

## Implementation note

macOS has no public API for re-parenting another app's status item. Barr mirrors
selected icons, parks their original status-item windows beyond the visible menu
bar, and temporarily restores an original when you activate it. It uses private
WindowServer functions and is intended for direct distribution rather than the
Mac App Store. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Releasing

Releases are tag-driven. Push a `v*` tag to build, sign, notarize, and publish a
stable `Barr.dmg` asset:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The release workflow expects the same Apple signing secrets used by the other
Cursor Kittens macOS apps. GitHub secrets are repository-scoped, so add these
to `zackbart/barr` before pushing the first tag:

- `BUILD_CERTIFICATE_BASE64`
- `P12_PASSWORD`
- `APPLE_TEAM_ID`
- `AC_API_KEY_BASE64`
- `AC_API_KEY_ID`
- `AC_API_ISSUER_ID`

## License

MIT — see [LICENSE](LICENSE).
