# Forge

A Mac + iPad parametric CAD app in the spirit of Fusion 360, Onshape and Shapr3D. First working version on Mac.

Cloud sync (Google Drive, Dropbox, OneDrive, iCloud Drive) comes from **CommonKit**, this repo's own copy of the sync
engine.

The full brief is in [`docs/SPEC.md`](docs/SPEC.md).

## Build & run (Mac)

Needs macOS 14+ and the Swift 6 toolchain (Xcode or just the Command Line Tools).

```bash
Scripts/build-forge-app.sh       # builds Forge.app in this folder — double-click to run
swift test                          # unit + GPU tests (headless)
swift build -c release --product ForgeSnapshots && .build/release/ForgeSnapshots /tmp/forge-check
```

`ForgeSnapshots` models a bracket through the real click handling, times the hot paths, saves and reopens a file and
screenshots every screen — without opening a window.

## Features

**Sketching.** Draw on the XY, XZ or YZ planes, offset planes or any flat face, with lines, rectangles, circles and
arcs, snapping to points, midpoints, curves and a grid (0.1, 1 or 10 mm, ⅛ in or any size you type). A line that's
nearly level or upright snaps straight and gets a horizontal or vertical constraint by itself.

**Constraint solver.** Coincident, point on curve, collinear, concentric, midpoint, fix/unfix, parallel, perpendicular,
horizontal, vertical, tangent, curvature (G2, for arcs and circles), symmetric and equal; dimensions for distance,
angle, radius, diameter and offset. Geometry is blue while it can move, black when fully constrained and red when
constraints conflict, and the panel says how many degrees of freedom remain. It's Newton-Raphson with exact derivatives
(automatic differentiation) and takes the smallest step each time, so geometry moves as little as possible. A
rank-revealing QR factorisation (a way of finding which equations are independent) also reports which constraints are
redundant. It converges to within 0.000000001 mm, far below the micron (0.001 mm) the brief asks for.

**Formulas.** Every dimension accepts a formula with units: `d1 * 2 + 5mm`, `width / 2`, `2in + sin(30deg) * 4mm`.
Named parameters are edited in the side panel and cycles are reported.

**Feature timeline.** A history of sketches and solid features, recomputed top to bottom. Change an early dimension and
every later cut and fillet follows, because faces have permanent names (which feature made them, and from which sketch
curve) and edges are referred to by the two faces they join. Features can be edited, suppressed, deleted or rolled back,
and a broken one is flagged while the rest keep working. Undo covers all of it.

**Solid features.** Extrude (distance, symmetric, through all, up to a face, with draft; new body, join, cut,
intersect), Revolve (around a sketch axis or a line), Fillet (one radius, straight or curved edges, convex or concave),
Chamfer (equal, two distances, distance + angle), Shell, Loft (ruled) and Sweep (no twist, no guide rails). Q pulls a
flat face outward. Commands show a live preview.

**Technical renderer (Metal).** Shaded, shaded with edges, hidden line, wireframe, zebra and draft analysis views, with
crisp anti-aliased edges and silhouettes found on the GPU. Live section planes paint a hatched cap on the cut.
The view only redraws when something changes.

**Inspection.** Volume, surface area, centre of mass, moments of inertia, bounding size, a watertightness check and the
minimum distance between two bodies.

**Controls (Mac).** C circle · R rectangle · L line · A arc · D dimension · E extrude · Q press-pull · F fillet · S search
all commands · middle-drag orbit · Shift+middle-drag pan · scroll zooms at the cursor. Without a middle button,
Option-drag orbits and Option+Shift-drag pans.

**Files.** Parts are `.forge` packages (`manifest.json`, `model.json`, `mesh/bodies.bin`, `thumbnail.png`) that save
themselves, rewrite only the files that changed, and sync through CommonKit. STL export is included.

**Not built yet.** Assemblies and joints; Thread; a stand-alone Draft feature; variable-radius and setback fillets; guide
rails on lofts and sweeps; Move/Copy (M only says so); splines; picking a single sketch area to extrude (the engine
supports it, the screen doesn't offer it yet); on iPad, Pencil press-pull, the radial menu and the numeric keypad.

**Known limits of this version.**
- Solids are polyhedral: curved surfaces are made of flat facets within 0.02 mm of the true curve. Sketches solve far below
  a micron and flat-faced solids measure exactly, but volumes of curved parts are only as good as the facets,
  typically within 0.5 %. They aren't the exact curved surfaces (NURBS) a professional CAD kernel uses, so "sub-micron"
  describes the sketch solver, not curved solids.
- Where three fillets meet at a corner, their surfaces intersect in sharp creases rather than a smooth ball corner.
- A concave fillet stops flat at the ends of its edge, which leaves a mismatch if the end faces aren't square to it.

## Cloud sync (CommonKit)

Parts are always saved locally first; sync runs in the background (10 s after you stop editing, or as soon as the app is
suspended). Only changed files upload, `manifest.json` goes last as the commit point, and when two devices edit the same
part both versions are kept (`Name (Conflicted Copy 2026-10-26 14.30.05).forge`). Open **Cloud Sync…** in the gallery.

Each service requires a free "app registration" from you. Create
`~/Library/Application Support/Forge/CloudKeys.plist` and fill in:

| Service | Where to register | Put in CloudKeys.plist | Redirect URI to register |
|---|---|---|---|
| Google Drive | console.cloud.google.com → enable Drive API → OAuth client of type **iOS** with bundle ID `com.silverninja71.forge` | `googleDrive > clientID` | (automatic) `com.googleusercontent.apps.<id>:/oauth2redirect` |
| Dropbox | dropbox.com/developers/apps → Scoped access, `files.metadata.read/write` + `files.content.read/write` | `dropbox > clientID` (the app key) | `db-<APP_KEY>://2/token` |
| OneDrive | entra.microsoft.com → App registrations → any directory + personal accounts, *Mobile and desktop*, permission `Files.ReadWrite` | `oneDrive > clientID` | `msauth.com.silverninja71.forge://auth` |
| iCloud Drive | nothing (a signed app with the iCloud capability uses its own container; otherwise your iCloud Drive folder) | — | — |

Tokens are kept in the Keychain, sign-in uses PKCE (no secrets in the app), and requests retry with backoff.

## What's verified (2026-11-02)

- 106 Forge tests pass: expressions, every constraint kind, status colours, profiles, booleans, every solid feature
  checked against textbook volumes, parametric cascade, sketch editor, files, picking, and real AppKit mouse and key
  events sent into the Mac view. The whole package's run of 239 tests, which includes the 133 sync tests, passes with the Command Line
  Tools. With Xcode, one test failed on this Mac: `bookmarkRoundTripResolvesTheSameFolder`.
- `ForgeSnapshots` passes all its checks: drawing, dimensioning, red/black/blue status, extrude, sketch on a face, cut,
  fillet and chamfer picked by simulated clicks, changing a parameter (regenerates in about 60 ms), undo, rollback, all
  display modes, section caps, save/reopen/delta save, and Forge → local "cloud" folder → reopen. A 36-hole plate
  regenerates in about 150 ms and draws in about 8 ms on the AMD Radeon Pro 5300.
- `ForgeCore` compiles for iPad, and `Forge.app` builds and is signed for this Mac.
- **Not yet verified:** hands-on use of the live app window (the Metal view is created in a window that's never shown and
  asked to draw without crashing, but its pixels weren't checked, and input was only tested with synthetic events; menus,
  dialogs and SwiftUI's keyboard focus haven't been exercised); real cloud sign-in; running on an iPad or simulator at all
  (`ForgeCore` compiles and `iPad/ForgeiPadApp.swift` type-checks, nothing more, so the iPad gesture code has never run).

## iPad

To build for iPad: in Xcode, create an iOS App project (iPadOS 17+), add this folder as a local package, link
`ForgeCore`, and use [`iPad/ForgeiPadApp.swift`](iPad/ForgeiPadApp.swift) as the app file. The iPad-specific code
(`#if os(iOS)` in `Viewport/CadMetalView.swift`) handles touch, hover and gestures.

## Licence

Mozilla Public License 2.0 — see [`LICENSE`](LICENSE).
