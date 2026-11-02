# Master brief: "Forge" (parametric CAD)

The user's original brief (2026-10-26), kept for reference. Renamed since: "Steel" → **Forge** (files `.forge`).
The brief covered two apps. Part 2, about the art studio Paper, is kept in Paper's own repo, and Parts 3–5 are unchanged,
so they still mention it.

Two professional Apple-platform apps (macOS 14+ and iPadOS 17+) in Swift, SwiftUI, Metal and
Accelerate/C++, sharing a decentralised **Universal Cloud Sync Engine** for Google Drive, Dropbox,
Microsoft OneDrive and iCloud Drive.

---

## Part 1 — Forge: professional parametric CAD (Fusion 360 / Onshape / Shapr3D)

### 1.1 Philosophy
- **Functionality over flashiness**: fast wireframes, clean anti-aliased silhouette edges, zebra analysis,
  section clipping — precise technical visualisation instead of heavy PBR.
- **Parametric, non-destructive**: a re-evaluating feature history tree (timeline). Editing an early sketch
  parameter cascades through extrusions, cuts, fillets and assemblies.
- **Rigorous constraint engine**: fully constrained 2D/3D drafting with sub-micron accuracy.

### 1.2 Workflows
1. **Sketch planes**: XY / XZ / YZ datum planes or any planar face; 2D sketch mode with a snapping grid
   (0.1 mm, 1 mm, 10 mm or custom inches).
2. **Constraint solver**: coincident, collinear, concentric, midpoint, fix/unfix, parallel, perpendicular,
   horizontal/vertical, tangent, curvature (G2), symmetry, equal; dimensions for distance, angle, radius,
   diameter, offset, accepting expressions (`d1 * 2 + 5mm`). Colour feedback: under-constrained blue, fully
   constrained black, over-constrained red.
3. **Solid features**: Extrude (blind, to object, through all, symmetric, draft; new body / join / cut /
   intersect), Revolve, Loft & Sweep (guide rails, tangency), Fillet (constant/variable, rolling ball vs
   setback), Chamfer (equal, angle-distance, two-distance), Shell, Thread (ISO / UTS), Draft.
4. **Assemblies**: rigid, revolute, slider, cylindrical, pin-slot, planar and ball joints with DOF limits;
   real-time collision and contact sets.
5. **Inspection**: minimum distance, surface area, centre of mass, moment of inertia, draft analysis, live
   section planes.

### 1.3 Controls
- **macOS**: C circle · R 2-point rectangle · L line · D dimension · E extrude · Q press-pull · F fillet ·
  M move/copy · S command search · middle-drag orbit · Shift+middle-drag pan · scroll zooms to cursor.
- **iPadOS**: Apple Pencil hover previews snaps and inference lines; Pencil-drag a face to extrude/offset,
  an edge to fillet/chamfer; floating radial menu for constraints and a numeric keypad.

---

## Part 3 — Universal Cloud Folder Sync Engine (shared)

1. **Providers**: Google Drive (REST v3, OAuth2 PKCE), Dropbox (API v2), Microsoft OneDrive (Graph /
   MSAL), iCloud Drive (`url(forUbiquityContainerIdentifier:)`), local file system and external drives
   (macOS volumes, iPadOS security-scoped bookmarks).
2. **Mechanics**: map any local or cloud folder (e.g. `Google Drive/Forge Projects/`); projects are
   self-contained packages (`.forge`, `.paper`: manifest JSON, binary buffers, thumbnails) saved as
   atomic deltas; on a timestamp conflict the engine branches `[Name] (Conflicted Copy [Date])` so nothing
   is lost; silent background upload after 10 s idle or when the app is suspended.

---

## Part 4 — Source layout (as briefed)

```
Workspace/
├── Common/
│   ├── CloudSync/  UniversalSyncEngine, GoogleDriveProvider, DropboxProvider, OneDriveProvider,
│   │               ICloudDriveProvider, ConflictResolver
│   └── Math/       Matrix4x4, Vector3
├── Forge/
│   ├── Model/      CadDocument (units), FeatureTree, Sketch2D, ConstraintSolver (Newton-Raphson), BRepMesh
│   ├── Operations/ ExtrudeOp, RevolveOp, FilletOp, AssemblyJointOp
│   ├── Viewport/   CadRenderer, TechnicalShaders.metal, CadInteractionController
│   └── UI/         TimelineBarView, DimensionInputBox, CadToolbar
└── Paper/
    ├── Engine/     PaintEngine, BrushStudio, FreeBrushStore, Shaders/StrokeShader.metal, Shaders/BlendModes.metal
    ├── Compositing/ LayerStack, AdjustmentPipeline
    └── UI/         PaperCanvasView, LayerManagerSheet, BrushPickerPopover, LightroomAdjustmentsView
```

## Part 5 — Implementation instructions
1. Complete, production-ready Swift — no pseudocode or placeholders.
2. Real algorithms for the constraint solver (collinear, perpendicular, tangent, dimensions), the Metal
   compute brush pipeline with Pencil pressure/tilt interpolation, and the multi-provider sync interface with
   secure token handling.
3. Compiles with Xcode 15/16 and Swift 6, with `#if os(macOS)` / `#if os(iOS)` where needed.
