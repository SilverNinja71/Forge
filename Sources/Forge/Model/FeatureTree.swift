import Foundation
import simd

/// Where a sketch lives: one of the three datum planes, or a flat face of the model.
public enum SketchPlaneRef: Codable, Equatable, Sendable {
    case xy, xz, yz
    case face(FaceTag)
    /// A datum plane moved along its normal.
    case offset(base: Int, distance: String)

    public var displayName: String {
        switch self {
        case .xy: return "XY plane"
        case .xz: return "XZ plane"
        case .yz: return "YZ plane"
        case .face: return "Face"
        case .offset(_, let d): return "Offset \(d)"
        }
    }
}

public struct SketchFeature: Codable, Equatable, Sendable {
    public var plane: SketchPlaneRef
    public var sketch: Sketch2D

    public init(plane: SketchPlaneRef, sketch: Sketch2D = Sketch2D()) {
        self.plane = plane
        self.sketch = sketch
    }
}

/// What a new solid does to the bodies already there.
public enum BodyOperation: String, Codable, CaseIterable, Sendable {
    case newBody, join, cut, intersect

    public var displayName: String {
        switch self {
        case .newBody: return "New body"
        case .join: return "Join"
        case .cut: return "Cut"
        case .intersect: return "Intersect"
        }
    }
}

public enum ExtrudeExtent: Codable, Equatable, Sendable {
    case blind(String)
    /// The same distance each way: the expression is the total.
    case symmetric(String)
    case throughAll
    /// Up to the plane of a flat face.
    case toObject(FaceTag)

    public var displayName: String {
        switch self {
        case .blind: return "Distance"
        case .symmetric: return "Symmetric"
        case .throughAll: return "Through all"
        case .toObject: return "To object"
        }
    }
}

/// Which closed areas of a sketch a feature uses.
public enum ProfileSelection: Codable, Equatable, Sendable {
    /// Every area not nested inside another once: a plate with a hole stays a plate with a hole.
    case automatic
    case regions([[Int]])
}

public struct ExtrudeFeature: Codable, Equatable, Sendable {
    public var sketchID: Int
    public var profile: ProfileSelection = .automatic
    public var extent: ExtrudeExtent
    public var flip = false
    /// Taper angle: positive narrows the shape as it grows.
    public var draft: String = "0deg"
    public var operation: BodyOperation

    public init(sketchID: Int, extent: ExtrudeExtent, operation: BodyOperation = .newBody, flip: Bool = false, draft: String = "0deg") {
        self.sketchID = sketchID
        self.extent = extent
        self.operation = operation
        self.flip = flip
        self.draft = draft
    }
}

public struct RevolveFeature: Codable, Equatable, Sendable {
    public enum Axis: Codable, Equatable, Sendable {
        case sketchLine(Int)
        case sketchX
        case sketchY
    }

    public var sketchID: Int
    public var profile: ProfileSelection = .automatic
    public var axis: Axis
    public var angle: String
    public var operation: BodyOperation

    public init(sketchID: Int, axis: Axis, angle: String = "360deg", operation: BodyOperation = .newBody) {
        self.sketchID = sketchID
        self.axis = axis
        self.angle = angle
        self.operation = operation
    }
}

public struct FilletFeature: Codable, Equatable, Sendable {
    public var edges: [EdgeRef]
    public var radius: String

    public init(edges: [EdgeRef], radius: String) {
        self.edges = edges
        self.radius = radius
    }
}

public struct ChamferFeature: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case equal(String)
        case twoDistance(String, String)
        case angleDistance(distance: String, angle: String)
    }

    public var edges: [EdgeRef]
    public var kind: Kind

    public init(edges: [EdgeRef], kind: Kind) {
        self.edges = edges
        self.kind = kind
    }
}

public struct ShellFeature: Codable, Equatable, Sendable {
    public var openFaces: [FaceTag]
    public var thickness: String

    public init(openFaces: [FaceTag], thickness: String) {
        self.openFaces = openFaces
        self.thickness = thickness
    }
}

public struct LoftFeature: Codable, Equatable, Sendable {
    public var sketchIDs: [Int]
    public var operation: BodyOperation

    public init(sketchIDs: [Int], operation: BodyOperation = .newBody) {
        self.sketchIDs = sketchIDs
        self.operation = operation
    }
}

public struct SweepFeature: Codable, Equatable, Sendable {
    public var profileSketchID: Int
    public var pathSketchID: Int
    public var operation: BodyOperation

    public init(profileSketchID: Int, pathSketchID: Int, operation: BodyOperation = .newBody) {
        self.profileSketchID = profileSketchID
        self.pathSketchID = pathSketchID
        self.operation = operation
    }
}

/// One step of the model's history. The bodies you see are always what these steps produce, in order.
public struct Feature: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case sketch(SketchFeature)
        case extrude(ExtrudeFeature)
        case revolve(RevolveFeature)
        case fillet(FilletFeature)
        case chamfer(ChamferFeature)
        case shell(ShellFeature)
        case loft(LoftFeature)
        case sweep(SweepFeature)
    }

    public var id: Int
    public var name: String
    public var isSuppressed = false
    public var kind: Kind

    public var symbol: String {
        switch kind {
        case .sketch: return "pencil.and.ruler"
        case .extrude: return "square.stack.3d.up"
        case .revolve: return "arrow.triangle.2.circlepath"
        case .fillet: return "circle.bottomhalf.filled"
        case .chamfer: return "triangle"
        case .shell: return "cube.transparent"
        case .loft: return "cone"
        case .sweep: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

public struct Body: Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var solid: Solid
}

/// The model after one feature has run: everything downstream starts from this.
public struct ModelState: Sendable {
    public var bodies: [Body] = []
    public var nextBodyID = 1
    /// Values of every named dimension and parameter known so far.
    public var values: [String: Quantity] = [:]
    public var sketchFrames: [Int: Frame3] = [:]
    public var sketchSolutions: [Int: ConstraintSolver.Result] = [:]
    public var solvedSketches: [Int: Sketch2D] = [:]
}

/// The feature history plus the user's parameters. `regenerate` runs it top to bottom: this is what
/// makes the model parametric. Change anything early and every later feature is simply recomputed.
public struct FeatureTree: Codable, Equatable, Sendable {
    public var features: [Feature] = []
    public var parameters: [Parameter] = []
    /// mm per document unit.
    public var unitScale = 1.0
    public var nextFeatureID = 1
    public var nextDimensionNumber = 1
    /// Features after this index are rolled back: temporarily ignored, as if not yet made.
    public var rollback: Int?

    public init() {}

    public var activeFeatures: ArraySlice<Feature> {
        features[..<min(rollback ?? features.count, features.count)]
    }

    public mutating func append(_ kind: Feature.Kind, name: String? = nil) -> Int {
        let id = nextFeatureID
        nextFeatureID += 1
        let number = features.filter { sameCategory($0.kind, kind) }.count + 1
        let feature = Feature(id: id, name: name ?? "\(Self.categoryName(kind)) \(number)", kind: kind)
        // A new feature goes at the rollback marker, which then moves past it.
        if let r = rollback, r < features.count {
            features.insert(feature, at: r)
            rollback = r + 1
        } else {
            features.append(feature)
        }
        return id
    }

    private func sameCategory(_ a: Feature.Kind, _ b: Feature.Kind) -> Bool { Self.categoryName(a) == Self.categoryName(b) }

    static func categoryName(_ k: Feature.Kind) -> String {
        switch k {
        case .sketch: return "Sketch"
        case .extrude: return "Extrude"
        case .revolve: return "Revolve"
        case .fillet: return "Fillet"
        case .chamfer: return "Chamfer"
        case .shell: return "Shell"
        case .loft: return "Loft"
        case .sweep: return "Sweep"
        }
    }

    public func feature(_ id: Int) -> Feature? { features.first { $0.id == id } }

    public mutating func takeDimensionName() -> String {
        var name: String
        repeat {
            name = "d\(nextDimensionNumber)"
            nextDimensionNumber += 1
        } while parameters.contains(where: { $0.name == name }) || allDimensionNames.contains(name)
        return name
    }

    public var allDimensionNames: Set<String> {
        var names = Set<String>()
        for f in features {
            if case .sketch(let s) = f.kind { names.formUnion(s.sketch.dimensionNames) }
        }
        return names
    }

    // MARK: Regeneration

    public struct Regeneration: Sendable {
        /// The state after each active feature, in order.
        public var states: [ModelState] = []
        public var errors: [Int: String] = [:]
        public var parameterErrors: [String: String] = [:]
        public var final: ModelState { states.last ?? ModelState() }

        public init() {}
    }

    /// Runs the whole history. `reusing` supplies states from a previous run for features before `firstChanged`,
    /// which is what makes editing a late feature fast.
    public func regenerate(reusing previous: Regeneration? = nil, firstChanged: Int = 0) -> Regeneration {
        var result = Regeneration()
        var state = ModelState()
        let (values, errors) = ParameterSolver.evaluate(parameters.map { ($0.name, $0.expression) }, defaultLength: unitScale)
        state.values = values
        result.parameterErrors = errors

        let active = activeFeatures
        var startIndex = 0
        if let previous, firstChanged > 0, firstChanged <= previous.states.count, firstChanged <= active.count {
            startIndex = firstChanged
            result.states = Array(previous.states[..<firstChanged])
            state = result.states.last ?? state
            for f in active[..<firstChanged] {
                if let e = previous.errors[f.id] { result.errors[f.id] = e }
            }
        }
        for f in active[startIndex...] {
            if !f.isSuppressed {
                do {
                    try run(f, state: &state)
                } catch {
                    // A broken feature is skipped and flagged; the rest of the tree still tries to run.
                    result.errors[f.id] = error.localizedDescription
                }
            }
            result.states.append(state)
        }
        return result
    }

    private func evaluator(_ state: ModelState) -> ExpressionEvaluator {
        let values = state.values
        return ExpressionEvaluator(defaultLength: unitScale) { values[$0] }
    }

    private func run(_ f: Feature, state: inout ModelState) throws {
        switch f.kind {
        case .sketch(let feature):
            try runSketch(f.id, feature, state: &state)
        case .extrude(let e):
            let (sketch, frame) = try sketchContext(e.sketchID, state)
            let regions = pick(e.profile, from: sketch.regions())
            guard !regions.isEmpty else { throw FeatureError("This sketch has no closed profile to extrude") }
            let ev = evaluator(state)
            let draft = try ev.angle(e.draft)
            let dir = e.flip ? -1.0 : 1.0
            var rings: [ExtrudeOp.Ring]
            let slope = tan(draft)
            switch e.extent {
            case .blind(let text):
                let d = try ev.length(text)
                guard abs(d) > 1e-9 else { throw FeatureError("The extrude distance is zero") }
                let end = d * dir
                rings = end > 0
                    ? [.init(height: 0), .init(height: end, offset: abs(d) * slope)]
                    : [.init(height: end, offset: abs(d) * slope), .init(height: 0)]
            case .symmetric(let text):
                let d = try ev.length(text)
                guard d > 1e-9 else { throw FeatureError("The extrude distance must be above zero") }
                rings = draft == 0
                    ? [.init(height: -d / 2), .init(height: d / 2)]
                    : [.init(height: -d / 2, offset: d / 2 * slope), .init(height: 0), .init(height: d / 2, offset: d / 2 * slope)]
            case .throughAll:
                let all = state.bodies.reduce(AABB.empty) { $0.union($1.solid.bounds) }
                guard !all.isEmpty else { throw FeatureError("“Through all” needs a body to go through") }
                // Far enough to clear the whole model from any sketch plane.
                let far = all.diagonal + simd_length(all.center - frame.origin) + 1
                rings = dir > 0 ? [.init(height: 0), .init(height: far)] : [.init(height: -far), .init(height: 0)]
            case .toObject(let tag):
                let target = state.bodies.lazy.compactMap { $0.solid.faces(tagged: tag).first }.first
                guard let face = target else { throw FeatureError("The face this extrude goes up to no longer exists") }
                guard abs(simd_dot(face.plane.normal, frame.z)) > 1e-6 else { throw FeatureError("That face is parallel to the extrude direction") }
                // Height at which the sketch origin's normal line meets the face's plane.
                let height = face.plane.distance(frame.origin) / -simd_dot(face.plane.normal, frame.z)
                guard abs(height) > 1e-9 else { throw FeatureError("That face is already on the sketch plane") }
                rings = height > 0
                    ? [.init(height: 0), .init(height: height, offset: height * slope)]
                    : [.init(height: height, offset: -height * slope), .init(height: 0)]
            }
            let solid = try ExtrudeOp.solid(regions: regions, frame: frame, rings: rings, feature: f.id)
            try apply(solid, e.operation, state: &state, feature: f)
        case .revolve(let r):
            let (sketch, frame) = try sketchContext(r.sketchID, state)
            let regions = pick(r.profile, from: sketch.regions())
            guard !regions.isEmpty else { throw FeatureError("This sketch has no closed profile to revolve") }
            let a: Vec2, b: Vec2
            switch r.axis {
            case .sketchLine(let id):
                guard let ends = sketch.endpoints(of: id) else { throw FeatureError("The revolve axis line no longer exists") }
                a = sketch.position(ends.a)
                b = sketch.position(ends.b)
            case .sketchX:
                a = .zero
                b = Vec2(1, 0)
            case .sketchY:
                a = .zero
                b = Vec2(0, 1)
            }
            let angle = try evaluator(state).angle(r.angle)
            let solid = try RevolveOp.solid(regions: regions, frame: frame, axisA: a, axisB: b, angle: angle, feature: f.id)
            try apply(solid, r.operation, state: &state, feature: f)
        case .fillet(let feature):
            let radius = try evaluator(state).length(feature.radius)
            try applyEdgeShape(feature.edges, .fillet(radius: radius), state: &state, feature: f)
        case .chamfer(let feature):
            let ev = evaluator(state)
            let shape: FilletOp.Shape
            switch feature.kind {
            case .equal(let d):
                let v = try ev.length(d)
                shape = .chamfer(d1: v, d2: v)
            case .twoDistance(let d1, let d2):
                shape = .chamfer(d1: try ev.length(d1), d2: try ev.length(d2))
            case .angleDistance(let d, let a):
                shape = .chamferAngle(distance: try ev.length(d), angle: try ev.angle(a))
            }
            try applyEdgeShape(feature.edges, shape, state: &state, feature: f)
        case .shell(let s):
            let t = try evaluator(state).length(s.thickness)
            let open = Set(s.openFaces)
            // Shell the body holding the open faces, or every body when none was picked.
            var changed = false
            for i in state.bodies.indices where open.isEmpty || !state.bodies[i].solid.tags.isDisjoint(with: open) {
                let result = try ShellOp.apply(to: state.bodies[i].solid, removing: open, thickness: t, feature: f.id)
                state.bodies[i].solid = result
                changed = true
            }
            guard changed else { throw FeatureError("The face this shell opens no longer exists") }
        case .loft(let l):
            var loops: [[Vec3]] = []
            for id in l.sketchIDs {
                let (sketch, frame) = try sketchContext(id, state)
                guard let region = pick(.automatic, from: sketch.regions()).first else { throw FeatureError("Each lofted sketch needs a closed profile") }
                loops.append(region.outer.points.map { frame.world($0) })
            }
            let solid = try LoftSweepOp.loft(loops: loops, feature: f.id)
            try apply(solid, l.operation, state: &state, feature: f)
        case .sweep(let sw):
            let (profile, frame) = try sketchContext(sw.profileSketchID, state)
            guard let region = pick(.automatic, from: profile.regions()).first else { throw FeatureError("The sweep profile needs a closed area") }
            let (pathSketch, pathFrame) = try sketchContext(sw.pathSketchID, state)
            let path = try orderedPath(pathSketch).map { pathFrame.world($0) }
            let solid = try LoftSweepOp.sweep(outline: region.outer.points, frame: frame, path: path, feature: f.id)
            try apply(solid, sw.operation, state: &state, feature: f)
        }
    }

    /// Chains the drawn curves of a sketch end to end, for a sweep's path.
    private func orderedPath(_ sketch: Sketch2D) throws -> [Vec2] {
        var edges = sketch.tessellatedEdges()
        guard let first = edges.first else { throw FeatureError("The sweep path sketch is empty") }
        edges.removeFirst()
        var path = [first.a, first.b]
        while !edges.isEmpty {
            let end = path.last!, start = path.first!
            if let i = edges.firstIndex(where: { simd_length($0.a - end) < 1e-6 }) {
                path.append(edges.remove(at: i).b)
            } else if let i = edges.firstIndex(where: { simd_length($0.b - end) < 1e-6 }) {
                path.append(edges.remove(at: i).a)
            } else if let i = edges.firstIndex(where: { simd_length($0.b - start) < 1e-6 }) {
                path.insert(edges.remove(at: i).a, at: 0)
            } else if let i = edges.firstIndex(where: { simd_length($0.a - start) < 1e-6 }) {
                path.insert(edges.remove(at: i).b, at: 0)
            } else {
                throw FeatureError("The sweep path must be one connected chain of curves")
            }
        }
        return path
    }

    private func runSketch(_ id: Int, _ feature: SketchFeature, state: inout ModelState) throws {
        // Position the sketch.
        let frame: Frame3
        switch feature.plane {
        case .xy: frame = .xy
        case .xz: frame = .xz
        case .yz: frame = .yz
        case .offset(let base, let distance):
            let d = try evaluator(state).length(distance)
            let baseFrame = base == 1 ? Frame3.xz : (base == 2 ? Frame3.yz : Frame3.xy)
            frame = Frame3(origin: baseFrame.origin + baseFrame.z * d, x: baseFrame.x, y: baseFrame.y)
        case .face(let tag):
            guard let face = state.bodies.lazy.compactMap({ $0.solid.faces(tagged: tag).first }).first else {
                throw FeatureError("The face this sketch was on no longer exists")
            }
            frame = Frame3.on(plane: face.plane, near: .zero)
        }
        state.sketchFrames[id] = frame

        // Evaluate driving dimensions (they may refer to each other and to anything earlier), then solve.
        var sketch = feature.sketch
        let dims = sketch.constraints.compactMap { c -> (name: String, expression: String)? in
            c.dimension.map { ($0.name, $0.expression) }
        }
        let (values, errors) = ParameterSolver.evaluate(dims, known: state.values, defaultLength: unitScale)
        var firstError: String?
        for i in sketch.constraints.indices {
            guard let dim = sketch.constraints[i].dimension else { continue }
            if let message = errors[dim.name] {
                firstError = firstError ?? "\(dim.name): \(message)"
                continue
            }
            guard let q = values[dim.name] else { continue }
            let isAngle = sketch.constraints[i].kind.isAngular
            let value: Double
            if isAngle {
                value = q.value
                state.values[dim.name] = q
            } else {
                guard q.lengthPower <= 1 else {
                    firstError = firstError ?? "\(dim.name) isn't a length"
                    continue
                }
                value = q.lengthPower == 1 ? q.value : q.value * unitScale
                state.values[dim.name] = .length(value)
            }
            sketch.constraints[i].dimension?.value = value
        }
        if let firstError { throw FeatureError(firstError) }
        let solution = ConstraintSolver.solve(&sketch)
        state.sketchSolutions[id] = solution
        state.solvedSketches[id] = sketch
    }

    private func sketchContext(_ id: Int, _ state: ModelState) throws -> (Sketch2D, Frame3) {
        guard let sketch = state.solvedSketches[id], let frame = state.sketchFrames[id] else {
            throw FeatureError("The sketch this feature uses is missing or comes later in the history")
        }
        if let s = state.sketchSolutions[id], !s.converged {
            throw FeatureError("The sketch has conflicting constraints; fix those first")
        }
        return (sketch, frame)
    }

    private func pick(_ selection: ProfileSelection, from regions: [ProfileRegion]) -> [ProfileRegion] {
        switch selection {
        case .automatic:
            return regions.filter { $0.depth % 2 == 0 }
        case .regions(let keys):
            return regions.filter { keys.contains($0.key) }
        }
    }

    private func applyEdgeShape(_ refs: [EdgeRef], _ shape: FilletOp.Shape, state: inout ModelState, feature f: Feature) throws {
        guard !refs.isEmpty else { throw FeatureError("Pick at least one edge") }
        var handled = false
        for i in state.bodies.indices {
            let own = refs.filter { !state.bodies[i].solid.edgeIndices(for: $0).isEmpty }
            guard !own.isEmpty else { continue }
            let result = try FilletOp.apply(to: state.bodies[i].solid, refs: own, shape: shape, feature: f.id)
            state.bodies[i].solid = result
            handled = true
        }
        guard handled else { throw FeatureError("The edges this feature used no longer exist") }
    }

    /// Combines a freshly made solid with the existing bodies.
    private func apply(_ solid: Solid, _ op: BodyOperation, state: inout ModelState, feature f: Feature) throws {
        guard !solid.isEmpty else { throw FeatureError("This feature produced no geometry") }
        func addBodies(_ pieces: [Solid]) {
            for piece in pieces {
                state.bodies.append(Body(id: state.nextBodyID, name: "Body \(state.nextBodyID)", solid: piece))
                state.nextBodyID += 1
            }
        }
        switch op {
        case .newBody:
            addBodies(solid.separated())
        case .join:
            var merged = solid
            var keep: [Body] = []
            var firstHit: Body?
            for b in state.bodies {
                let touches = b.solid.bounds.overlaps(merged.bounds, tolerance: 1e-6)
                if touches {
                    merged = CSG.combine(b.solid, merged, .union)
                    if firstHit == nil { firstHit = b }
                } else {
                    keep.append(b)
                }
            }
            state.bodies = keep
            if let firstHit {
                let pieces = merged.separated()
                for (i, piece) in pieces.enumerated() {
                    if i == 0 {
                        state.bodies.append(Body(id: firstHit.id, name: firstHit.name, solid: piece))
                    } else {
                        addBodies([piece])
                    }
                }
            } else {
                addBodies(merged.separated())
            }
        case .cut, .intersect:
            guard !state.bodies.isEmpty else { throw FeatureError("There's no body to \(op == .cut ? "cut" : "intersect") yet") }
            var next: [Body] = []
            for b in state.bodies {
                if op == .cut, !b.solid.bounds.overlaps(solid.bounds, tolerance: 1e-6) {
                    next.append(b)
                    continue
                }
                let result = CSG.combine(b.solid, solid, op == .cut ? .subtract : .intersect)
                let pieces = result.separated()
                for (i, piece) in pieces.enumerated() {
                    if i == 0 {
                        next.append(Body(id: b.id, name: b.name, solid: piece))
                    } else {
                        next.append(Body(id: state.nextBodyID, name: "Body \(state.nextBodyID)", solid: piece))
                        state.nextBodyID += 1
                    }
                }
            }
            state.bodies = next
        }
    }
}
