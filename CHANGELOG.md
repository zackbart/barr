# Changelog

All notable changes to Barr are documented here.

## [0.0.4] - 2026-07-23

### Fixed

- Kept Barr's own menu bar control at a visible priority across quit and relaunch,
  including on MacBooks with a notch.
- Re-applied every persisted Barr membership after the first launch scan so
  selected apps return to the shelf reliably after reopening Barr, regaining
  Accessibility permission, or launching later in the session.
- Prevented the shelf from opening beneath an unreachable status item and made
  it dismiss when clicking elsewhere or pressing Escape.

## [0.0.3] - 2026-07-23

### Fixed

- Allowed adding the first visible item when Barr still remembers hidden items
  whose apps are not currently running.
- Prevented Debug and Release instances from offering each other's controls and
  invisible storage anchors as movable menu bar items.
- Sized and clamped the shelf to the display containing Barr's menu bar control.

## [0.0.2] - 2026-07-23

### Added

- A **System items** setting. macOS system items are hidden from Barr by
  default and can be enabled explicitly.
- A distinct `Barr Debug` app identity, badged app icon, and `DEBUG` menu bar
  label so development builds cannot be confused with release builds.
- Debug diagnostics for status-item movement and activation.

### Changed

- Increased shelf and configuration icons from 18 to 24 points, with larger
  32-point hit targets and roomier layouts.
- Made configuration-row transitions optimistic and stable while items move
  between the menu bar and Barr.
- Preserved logical item identity, ordering, and the last valid icon while
  macOS reparents or temporarily hides a status-item window.
- Improved system-item activation by matching stable Accessibility identity
  before falling back to geometry or synthetic clicks.
- Restored items beside a live logical neighbor, with Barr's visible control
  as a safe fallback.
- Used readable owning-app icons when macOS Tahoe redacts hosted menu-bar
  captures.

### Fixed

- Prevented stale or reused WindowServer IDs from affecting neighboring menu
  bar items.
- Prevented failed move retries from dragging an unobserved stale window.
- Kept transient system controls in their physical neighbor order.
- Repositioned the open shelf when its hidden-item storage boundary changes.
- Marked fixed macOS surfaces such as Clock, Control Center, and active privacy
  controls unavailable instead of allowing silent failed moves.

## [0.0.1] - 2026-07-23

- Initial signed and notarized release.

[0.0.4]: https://github.com/zackbart/barr/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/zackbart/barr/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/zackbart/barr/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/zackbart/barr/releases/tag/v0.0.1
