# Barr TODO

## Known issues

- [x] Remove the visible flicker when moving an item from the **Menu Bar** row to the **In Barr** row in Settings. The source row, destination row, and compact shelf should update as one stable transition without briefly hiding, duplicating, or reordering icons.
  - [x] Update lane membership optimistically while the WindowServer move is in flight, with rollback when the move fails.
  - [x] Keep SwiftUI icon identity stable across WindowServer re-parenting and retain the last valid capture when a refresh temporarily returns no image.
  - [x] Smoke-test third-party and system items in both directions; verify the two manager rows and compact shelf remain visually stable.
- [x] Refine Barr's rendering and icon sizing. Keep mirrored icons crisp, consistently scaled, vertically centered, and readable against the shelf background across Retina scale factors and mixed icon aspect ratios.
  - [x] Preserve each WindowServer capture's point dimensions instead of treating backing pixels as points.
  - [x] Normalize icons to a 24-point visual height with bounded aspect-ratio-aware widths and consistent 32-point hit targets.
  - [x] Fall back to the owning application's full-color icon when Tahoe redacts a hosted status-window capture instead of rendering an empty button.
  - [x] Visually verify monochrome, full-color, square, and wide icons on the current Retina display; sizing remains point-based per display scale.
- [x] Harden system menu-item behavior. Verify movable system items can move, activate, return, persist, and retain their logical order without causing other system icons to disappear.
  - [x] Prune and validate cached WindowServer matches so a stale window ID cannot be assigned to a different system item.
  - [x] Activate items by stable Accessibility identity before falling back to frame matching or synthetic clicks.
  - [x] Return items beside a live logical predecessor, with Barr's visible control as the safe fallback anchor.
  - [x] Insert newly appearing transient items beside their current neighbors instead of appending them to persisted order.
  - [x] Avoid retrying a move against an unobserved stale window, and report collateral system-item loss in Debug builds.
  - [x] Verify Display, Screen Mirroring, Sound, Bluetooth, Wi-Fi, and Battery in both directions, plus activation and persistence after relaunch.
- [x] Treat Control Center, Clock, and active Audio/Video privacy controls as fixed macOS surfaces, with disabled controls and explicit accessibility help instead of silent failed moves.
- [x] Confirm newly appearing transient controls retain their physical neighbor order.
- [x] Hide system items from Barr's picker by default, with an opt-in **System items** setting for users who want them.

## Debug builds

- [x] Give Debug builds a separate bundle identifier and product name so they cannot be confused with or overwrite Release permissions, defaults, or running instances.
- [x] Show a ladybug plus **DEBUG** in the menu bar.
- [x] Use a visibly badged Debug app icon and the display name **Barr Debug**.
