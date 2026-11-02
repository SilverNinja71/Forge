# Forge — notes for Claude

One SwiftPM package for **Forge**, a Mac + iPad parametric CAD app (renamed from "Steel"; first working version
2026-11-02), with **CommonKit** (Universal Cloud Sync Engine) as this repo's own copy. Paper, a separate art studio, has
its own repo and its own copy, so a fix here doesn't reach it. The full brief is `docs/SPEC.md`; the README lists features.

## Build, test, verify

Forge needs full Xcode, because the Command Line Tools can't expand SwiftUI's `@Entry` macro. Xcode 26.1.1 is at
`~/Downloads/Xcode.app` but isn't the active developer directory, so prefix every command with
`DEVELOPER_DIR=$HOME/Downloads/Xcode.app/Contents/Developer`.

```bash
swift build
swift test                                    # Swift Testing; GPU tests render off-screen
swift test --filter ForgeCoreTests            # Forge only
COMMON_ONLY=1 swift test --scratch-path .build-common   # just the sync engine
swift build -c release --product ForgeSnapshots && .build/release/ForgeSnapshots <dir>
Scripts/build-forge-app.sh                  # Forge.app (don't `open` it while testing)
```

Compile for iPad (no simulator installed):
`swift build --target ForgeCore --triple arm64-apple-ios17.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" --scratch-path .build-ipad`.
`bookmarkRoundTripResolvesTheSameFolder` fails because of this Mac, not the code.

- `ForgeSnapshots <dir>` models a bracket through the real click handling, times the hot paths, checks save/reopen/delta
  save (prints ✓ / ✗ FAIL) and screenshots each screen in a window that is never shown. Look at the PNGs with Read.
- Machine: Intel iMac, AMD Radeon Pro 5300 (read-write texture tier 2), no offline `metal` compiler. Shaders are MSL
  strings compiled at runtime.
- `Package.swift`: tools 6.0. CommonKit uses Swift 6 language mode; ForgeCore and the apps use Swift 5 mode
  (Metal objects aren't Sendable). `COMMON_ONLY=1` exposes only CommonKit targets.

## Forge architecture

Everything is double precision in mm and radians; other units exist only in expressions and on screen. Bottom to top:

- `Math/Geometry` — `Vec2`/`Vec3`, `Plane3`, `Frame3`, `AABB`, `Triangulator` (ear clipping + hole bridging).
- `Model/Expression` — formulas with units; `ParameterSolver` orders formulas by dependency and reports cycles.
- `Model/Sketch2D`, `ConstraintSolver` — residuals written with `Dual` (exact derivatives); Householder QR with column
  pivoting of Jᵀ gives the minimum-norm Newton step, rank, dependent rows and free variables. Rows are normalised first.
  Angles use atan2 residuals, not sin/cos, whose slopes vanish at 0° and 90°.
- `Model/SketchProfiles` — curves → planar graph → closed regions with holes and nesting depth.
- `Model/SketchEditor` — pure tool logic (snap, inference, dimensions). Takes sketch-mm positions, so tests can draw.
- `Model/BRepMesh` — `Solid`: polygon soup in; welded vertices, T-junctions repaired, coplanar pieces merged per
  `(FaceTag, plane)`, re-triangulated; classified edges out. `isClosed` means every edge has exactly two faces.
- `Model/CSG` — BSP booleans. Every operation is a union with inputs inverted (De Morgan). The tree is built from
  distinct planes with an explicit stack (convex solids make very deep trees).
- `Operations/` — Extrude/Revolve/LoftSweep/Fillet/Shell build polygons. Fillets build a tool along the edge chain and
  cut it (convex) or add it (concave); shell offsets each face's plane and subtracts.
- `Model/FeatureTree` — `regenerate` runs features in order; one `ModelState` per feature lets edits re-run from the first
  changed one. `FaceTag` = feature + role + sketch curve; `EdgeRef` = the two tags an edge joins. This is the answer to
  the topological-naming problem: keep it stable and fillets survive upstream changes.
- `Model/CadDocument` (`@MainActor @Observable`) — tree, undo (tree snapshots), sketch mode (live `SketchEditor`, committed
  on Finish), command panel state + live preview; `ForgeFileFormat` — `.forge` package with delta saves.
- `Viewport/` — `CadCamera` (orthographic), `CadRenderer` + `TechnicalShaders` (MSL strings compiled at runtime, redraw
  only on change, stencil-counted section caps, silhouettes in the line vertex shader), `CadPicker`,
  `CadInteractionController`, `CadMetalView` (Mac events / iPad gestures).
- `UI/` — `ForgeWorkspaceView` (toolbar, browser, timeline, panels), `SketchOverlay` (Canvas over the Metal view),
  `ForgeGalleryView`. `.environment(\.forgeSnapshotMode, true)` swaps the MTKView for an off-screen render.

## Gotchas learned

- Forge: a click can line up two edges in a straight-on view; `CadPicker` must prefer the nearer. Fillet tools must reach only
  slightly past the surface, or on a small circular edge they cross the axis and turn inside out. A hole-bridge vertex
  appears twice in the loop, and connecting to the wrong copy makes overlapping triangles (wrong volume, no crash).
- Swift Testing: `#expect(x.mutatingCall())` doesn't compile. Assign to a `let` first.

- Swift structs mirrored in MSL must match byte-for-byte; avoid `uint3`/`float3` in MSL param structs
  (16-byte size/alignment) — use scalar padding.
- `Float16` doesn't exist on Intel macOS.
- Private textures on this discrete GPU: upload through a shared `MTLBuffer` + blit, never `replace`.
- `NSHostingView` snapshots: set `sizingOptions = []` and an explicit frame/background, or lazy grids
  collapse and backgrounds come out transparent.

## CommonKit (cloud sync)

`UniversalSyncManager` (actor) is the entry point; `ForgeCloudController` (ForgeCore, `@MainActor`) bridges it to SwiftUI.
`projectDidChange` after each save (10 s debounce), `appWillSuspend` when the app is suspended, `syncAll` on start.
Providers: Google Drive, Dropbox, OneDrive (REST + PKCE, keys from `~/Library/Application Support/Forge/CloudKeys.plist`),
iCloud, `LocalFolderProvider` (+ File Provider discovery). Gotcha: FileManager enumerators return `/private/var/...` while
`resolvingSymlinksInPath` gives `/var/...` — never strip root paths as string prefixes.

## Status

README "What's verified" is the source of truth. Next: hands-on test of the live Mac app with the user, Forge's unbuilt
features (assemblies, thread, draft, variable fillets; see README), iPad Xcode project, real-provider sign-in once the
user has registered keys.
