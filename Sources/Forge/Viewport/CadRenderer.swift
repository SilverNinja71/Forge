import Foundation
import Metal
import MetalKit
import CoreGraphics
import simd

/// One anti-aliased line for the GPU. Must match `LineInstance` in the shaders byte for byte (80 bytes).
struct LineInstance {
    var ax: Float, ay: Float, az: Float, kind: Float
    var bx: Float, by: Float, bz: Float, width: Float
    var n0x: Float = 0, n0y: Float = 0, n0z: Float = 0, pad0: Float = 0
    var n1x: Float = 0, n1y: Float = 0, n1z: Float = 0, pad1: Float = 0
    var r: Float, g: Float, b: Float, a: Float

    init(_ p: Vec3, _ q: Vec3, color: SIMD4<Float>, width: Float, silhouette: (Vec3, Vec3)? = nil) {
        ax = Float(p.x)
        ay = Float(p.y)
        az = Float(p.z)
        bx = Float(q.x)
        by = Float(q.y)
        bz = Float(q.z)
        kind = silhouette == nil ? 0 : 1
        self.width = width
        if let s = silhouette {
            n0x = Float(s.0.x)
            n0y = Float(s.0.y)
            n0z = Float(s.0.z)
            n1x = Float(s.1.x)
            n1y = Float(s.1.y)
            n1z = Float(s.1.z)
        }
        r = color.x
        g = color.y
        b = color.z
        a = color.w
    }
}

/// Must match `Uniforms` in the shaders.
struct CadUniforms {
    var viewProj: simd_float4x4
    var toViewer: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var section: SIMD4<Float>
    var pull: SIMD4<Float>
    var viewport: SIMD2<Float>
    var lineBias: Float
    var mode: Int32
    var sectionOn: Int32
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var pad2: Int32 = 0
}

/// Everything the renderer needs for one picture. Plain data, so a snapshot and the live view draw the same thing.
public struct CadSceneDescription {
    public var bodies: [Body]
    public var sketches: [(frame: Frame3, sketch: Sketch2D, id: Int)]
    public var selection: ModelSelection
    public var hoverEdge: EdgeRef?
    public var hoverFace: FaceTag?
    public var settings: ViewportSettings
    public var camera: CadCamera
    /// Datum planes are drawn while there's nothing else to look at.
    public var showDatumPlanes: Bool
    public var modelRevision: Int

    public init(bodies: [Body], sketches: [(frame: Frame3, sketch: Sketch2D, id: Int)] = [], selection: ModelSelection = ModelSelection(),
                hoverEdge: EdgeRef? = nil, hoverFace: FaceTag? = nil, settings: ViewportSettings = ViewportSettings(), camera: CadCamera,
                showDatumPlanes: Bool = false, modelRevision: Int = 0) {
        self.bodies = bodies
        self.sketches = sketches
        self.selection = selection
        self.hoverEdge = hoverEdge
        self.hoverFace = hoverFace
        self.settings = settings
        self.camera = camera
        self.showDatumPlanes = showDatumPlanes
        self.modelRevision = modelRevision
    }
}

/// The technical renderer: shaded, hidden-line, wireframe, zebra and draft views with crisp edges and live section cuts.
public final class CadRenderer {
    public let device: MTLDevice
    public static let sampleCount = 4
    public static let colorFormat = MTLPixelFormat.bgra8Unorm
    public static let depthFormat = MTLPixelFormat.depth32Float_stencil8

    let queue: MTLCommandQueue
    private let facePipeline: MTLRenderPipelineState
    private let stencilPipeline: MTLRenderPipelineState
    private let tintPipeline: MTLRenderPipelineState
    private let capPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthTest: MTLDepthStencilState
    private let noDepth: MTLDepthStencilState
    private let stencilCount: MTLDepthStencilState
    private let capDepth: MTLDepthStencilState

    private var faceBuffer: MTLBuffer?
    private var faceVertexCount = 0
    private var geometryRevision = -1
    private var modelLines: [LineInstance] = []
    private var modelBounds = AABB.empty

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: TechnicalShaders.source, options: nil) else { return nil }
        self.device = device
        self.queue = queue

        func pipeline(_ vertex: String, _ fragment: String?, blend: Bool = false, colorWrites: Bool = true) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = fragment.flatMap { library.makeFunction(name: $0) }
            d.rasterSampleCount = Self.sampleCount
            d.colorAttachments[0].pixelFormat = Self.colorFormat
            d.colorAttachments[0].writeMask = colorWrites ? .all : []
            d.depthAttachmentPixelFormat = Self.depthFormat
            d.stencilAttachmentPixelFormat = Self.depthFormat
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let face = pipeline("faceVertex", "faceFragment"),
              let stencil = pipeline("faceVertex", "stencilFragment", colorWrites: false),
              let tint = pipeline("faceVertex", "tintFragment", blend: true),
              let cap = pipeline("faceVertex", "capFragment"),
              let line = pipeline("lineVertex", "lineFragment", blend: true),
              let bg = pipeline("backgroundVertex", "backgroundFragment") else { return nil }
        facePipeline = face
        stencilPipeline = stencil
        tintPipeline = tint
        capPipeline = cap
        linePipeline = line
        backgroundPipeline = bg

        func depthState(_ compare: MTLCompareFunction, write: Bool, _ configure: ((MTLDepthStencilDescriptor) -> Void)? = nil) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            configure?(d)
            return device.makeDepthStencilState(descriptor: d)
        }
        guard let dw = depthState(.lessEqual, write: true),
              let dt = depthState(.lessEqual, write: false),
              let nd = depthState(.always, write: false),
              let sc = depthState(.always, write: false, { d in
                  let front = MTLStencilDescriptor(), back = MTLStencilDescriptor()
                  front.depthStencilPassOperation = .decrementWrap
                  back.depthStencilPassOperation = .incrementWrap
                  d.frontFaceStencil = front
                  d.backFaceStencil = back
              }),
              let cd = depthState(.lessEqual, write: true, { d in
                  let s = MTLStencilDescriptor()
                  s.stencilCompareFunction = .notEqual
                  d.frontFaceStencil = s
                  d.backFaceStencil = s
              }) else { return nil }
        depthWrite = dw
        depthTest = dt
        noDepth = nd
        stencilCount = sc
        capDepth = cd
    }

    // MARK: Building buffers

    private static let edgeColor = SIMD4<Float>(0.07, 0.08, 0.1, 1)
    private static let tangentColor = SIMD4<Float>(0.07, 0.08, 0.1, 0.25)
    private static let selectColor = SIMD4<Float>(0.09, 0.45, 0.95, 1)
    private static let hoverColor = SIMD4<Float>(0.98, 0.55, 0.1, 1)

    private func rebuildGeometry(_ scene: CadSceneDescription) {
        guard scene.modelRevision != geometryRevision || faceBuffer == nil else { return }
        geometryRevision = scene.modelRevision
        var floats: [Float] = []
        var lines: [LineInstance] = []
        var bounds = AABB.empty
        let triangles = scene.bodies.reduce(0) { $0 + $1.solid.triangleCount }
        floats.reserveCapacity(triangles * 18)
        for body in scene.bodies {
            let solid = body.solid
            bounds = bounds.union(solid.bounds)
            for f in solid.faces {
                for t in f.triangles {
                    let i = Int(t)
                    let p = solid.positions[Int(f.verts[i])], n = f.normals[i]
                    floats += [Float(p.x), Float(p.y), Float(p.z), Float(n.x), Float(n.y), Float(n.z)]
                }
            }
            for e in solid.edges {
                let a = solid.positions[Int(e.a)], b = solid.positions[Int(e.b)]
                switch e.kind {
                case .sharp, .open:
                    lines.append(LineInstance(a, b, color: Self.edgeColor, width: 1.5))
                case .tangent:
                    lines.append(LineInstance(a, b, color: Self.tangentColor, width: 1))
                case .smooth:
                    lines.append(LineInstance(a, b, color: Self.edgeColor, width: 1.5,
                                              silhouette: (solid.faces[Int(e.f0)].plane.normal, solid.faces[Int(e.f1)].plane.normal)))
                case .seamless:
                    break
                }
            }
        }
        modelLines = lines
        modelBounds = bounds
        faceVertexCount = floats.count / 6
        faceBuffer = floats.isEmpty ? nil : device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    private func overlayLines(_ scene: CadSceneDescription) -> [LineInstance] {
        var lines: [LineInstance] = []
        // Selected and hovered edges.
        for body in scene.bodies {
            let s = body.solid
            for e in s.edges where e.f1 >= 0 {
                let tagA = s.faces[Int(e.f0)].tag, tagB = s.faces[Int(e.f1)].tag
                if scene.selection.edges.contains(where: { $0.joins(tagA, tagB) }) {
                    lines.append(LineInstance(s.positions[Int(e.a)], s.positions[Int(e.b)], color: Self.selectColor, width: 3))
                } else if let h = scene.hoverEdge, h.joins(tagA, tagB) {
                    lines.append(LineInstance(s.positions[Int(e.a)], s.positions[Int(e.b)], color: Self.hoverColor, width: 3))
                }
            }
        }
        // Finished sketches, in their colours.
        if scene.settings.showSketches {
            for (frame, sketch, _) in scene.sketches {
                for edge in sketch.tessellatedEdges(includeConstruction: true) {
                    let construction = sketch.curve(edge.curve)?.isConstruction == true
                    let color = construction ? SIMD4<Float>(0.45, 0.45, 0.45, 0.6) : SIMD4<Float>(0.1, 0.3, 0.75, 0.85)
                    lines.append(LineInstance(frame.world(edge.a), frame.world(edge.b), color: color, width: 1.2))
                }
            }
        }
        if scene.settings.showGrid {
            lines += gridLines(scene)
        }
        if scene.showDatumPlanes {
            let size = 40.0
            let colors: [(Frame3, SIMD4<Float>)] = [(.xy, SIMD4(0.1, 0.35, 0.85, 0.8)), (.xz, SIMD4(0.1, 0.6, 0.25, 0.8)), (.yz, SIMD4(0.8, 0.2, 0.2, 0.8))]
            for (frame, color) in colors {
                let corners = [Vec2(-size, -size), Vec2(size, -size), Vec2(size, size), Vec2(-size, size)].map { frame.world($0) }
                for i in 0..<4 { lines.append(LineInstance(corners[i], corners[(i + 1) % 4], color: color, width: 1.2)) }
            }
        }
        return lines
    }

    /// A ground grid at a spacing that suits the zoom level.
    private func gridLines(_ scene: CadSceneDescription) -> [LineInstance] {
        let view = scene.camera.viewHeight
        let spacing = pow(10, (log10(max(view, 1e-3) / 8)).rounded(.up))
        let extent = view * 2.5
        let c = scene.camera.target
        let cx = (c.x / spacing).rounded() * spacing, cy = (c.y / spacing).rounded() * spacing
        let n = Int(extent / spacing)
        guard n > 0, n < 400 else { return [] }
        let major = SIMD4<Float>(0.3, 0.33, 0.38, 0.28), minor = SIMD4<Float>(0.3, 0.33, 0.38, 0.13)
        var lines: [LineInstance] = []
        lines.reserveCapacity(4 * n + 2)
        for i in -n...n {
            let x = cx + Double(i) * spacing, y = cy + Double(i) * spacing
            let isMajorX = (x / (spacing * 10)).rounded() * spacing * 10 == x
            let isMajorY = (y / (spacing * 10)).rounded() * spacing * 10 == y
            lines.append(LineInstance(Vec3(x, cy - extent, 0), Vec3(x, cy + extent, 0), color: isMajorX ? major : minor, width: 1))
            lines.append(LineInstance(Vec3(cx - extent, y, 0), Vec3(cx + extent, y, 0), color: isMajorY ? major : minor, width: 1))
        }
        // World axes.
        lines.append(LineInstance(Vec3(-extent * 2, 0, 0), Vec3(extent * 2, 0, 0), color: SIMD4(0.8, 0.2, 0.2, 0.55), width: 1.2))
        lines.append(LineInstance(Vec3(0, -extent * 2, 0), Vec3(0, extent * 2, 0), color: SIMD4(0.1, 0.6, 0.25, 0.55), width: 1.2))
        return lines
    }

    private func highlightVertices(_ scene: CadSceneDescription) -> (selected: [Float], hover: [Float]) {
        var selected: [Float] = [], hover: [Float] = []
        guard !scene.selection.faces.isEmpty || scene.hoverFace != nil else { return ([], []) }
        for body in scene.bodies {
            let s = body.solid
            for f in s.faces {
                let isSelected = scene.selection.faces.contains(f.tag)
                let isHover = !isSelected && scene.hoverFace == f.tag
                guard isSelected || isHover else { continue }
                for t in f.triangles {
                    let i = Int(t)
                    let p = s.positions[Int(f.verts[i])], n = f.normals[i]
                    let v = [Float(p.x), Float(p.y), Float(p.z), Float(n.x), Float(n.y), Float(n.z)]
                    if isSelected { selected += v } else { hover += v }
                }
            }
        }
        return (selected, hover)
    }

    // MARK: Drawing

    private func uniforms(_ scene: CadSceneDescription, width: Int, height: Int) -> CadUniforms {
        let cam = scene.camera
        let aspect = Double(width) / Double(max(height, 1))
        let depthRange = max(modelBounds.isEmpty ? 0 : modelBounds.diagonal + simd_length(modelBounds.center - cam.target), cam.viewHeight * 4) * 2
        func v4(_ v: Vec3) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), 0) }
        let sec = scene.settings.section
        let settings = scene.settings
        let plane = sec.plane
        let mode: Int32
        switch settings.mode {
        case .shaded, .shadedEdges: mode = 0
        case .hiddenLine, .wireframe: mode = 1
        case .zebra: mode = 2
        case .draftAnalysis: mode = 3
        }
        let mmPerPixel = cam.viewHeight / Double(max(height, 1))
        return CadUniforms(viewProj: cam.viewProjection(aspect: aspect, depthRange: depthRange),
                           toViewer: v4(cam.back), right: v4(cam.right), up: v4(cam.up),
                           section: SIMD4(Float(plane.normal.x), Float(plane.normal.y), Float(plane.normal.z), Float(plane.d)),
                           pull: SIMD4(Float(settings.pullDirection.x), Float(settings.pullDirection.y), Float(settings.pullDirection.z), Float(sin(settings.requiredDraft))),
                           viewport: SIMD2(Float(width), Float(height)),
                           lineBias: Float(mmPerPixel * 1.5 / (2 * depthRange)),
                           mode: mode, sectionOn: sec.isEnabled ? 1 : 0)
    }

    /// Encodes one frame into a render pass whose attachments are multisampled colour and depth/stencil.
    public func encode(_ scene: CadSceneDescription, into encoder: MTLRenderCommandEncoder, width: Int, height: Int) {
        rebuildGeometry(scene)
        var u = uniforms(scene, width: width, height: height)
        let settings = scene.settings

        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)

        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setDepthStencilState(noDepth)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        let wireframe = settings.mode == .wireframe
        if let faceBuffer, faceVertexCount > 0, !wireframe {
            encoder.setRenderPipelineState(facePipeline)
            encoder.setDepthStencilState(depthWrite)
            encoder.setVertexBuffer(faceBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<CadUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<CadUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: faceVertexCount)

            // Section cap: count front/back crossings in the stencil, then paint the plane wherever we're inside.
            if settings.section.isEnabled {
                encoder.setRenderPipelineState(stencilPipeline)
                encoder.setDepthStencilState(stencilCount)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: faceVertexCount)
                var cap = capVertices(settings.section)
                encoder.setRenderPipelineState(capPipeline)
                encoder.setDepthStencilState(capDepth)
                encoder.setStencilReferenceValue(0)
                encoder.setVertexBytes(&cap, length: cap.count * MemoryLayout<Float>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.setVertexBuffer(faceBuffer, offset: 0, index: 0)
            }

            // Selected and hovered faces, tinted over the shading.
            let highlights = highlightVertices(scene)
            func tint(_ floats: [Float], _ color: SIMD4<Float>) {
                guard !floats.isEmpty, let buf = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared) else { return }
                var c = color
                encoder.setRenderPipelineState(tintPipeline)
                encoder.setDepthStencilState(depthTest)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: floats.count / 6)
            }
            tint(highlights.selected, SIMD4(Self.selectColor.x, Self.selectColor.y, Self.selectColor.z, 0.42))
            tint(highlights.hover, SIMD4(Self.hoverColor.x, Self.hoverColor.y, Self.hoverColor.z, 0.3))
        }

        // Edges. Plain shaded and analysis views leave them out except for the selection.
        var lines = overlayLines(scene)
        if settings.mode == .shadedEdges || settings.mode == .hiddenLine || wireframe { lines = modelLines + lines }
        guard !lines.isEmpty, let lineBuffer = device.makeBuffer(bytes: lines, length: lines.count * MemoryLayout<LineInstance>.stride, options: .storageModeShared) else { return }
        encoder.setRenderPipelineState(linePipeline)
        encoder.setDepthStencilState(wireframe ? noDepth : depthTest)
        encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<CadUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<CadUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: lines.count)
    }

    private func capVertices(_ section: SectionPlane) -> [Float] {
        let plane = section.plane
        let frame = Frame3.on(plane: plane, near: modelBounds.isEmpty ? .zero : modelBounds.center)
        let size = max(modelBounds.diagonal, 1) * 2
        let corners = [Vec2(-size, -size), Vec2(size, -size), Vec2(size, size), Vec2(-size, size)].map { frame.world($0) }
        var out: [Float] = []
        for i in [0, 1, 2, 0, 2, 3] {
            let p = corners[i], n = plane.normal
            out += [Float(p.x), Float(p.y), Float(p.z), Float(n.x), Float(n.y), Float(n.z)]
        }
        return out
    }

    /// Renders off-screen and reads the picture back, never touching a window.
    public func renderImage(_ scene: CadSceneDescription, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let msaa = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false)
        msaa.textureType = .type2DMultisample
        msaa.sampleCount = Self.sampleCount
        msaa.usage = .renderTarget
        msaa.storageMode = .private
        let resolve = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false)
        resolve.usage = [.renderTarget]
        resolve.storageMode = .private
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.depthFormat, width: width, height: height, mipmapped: false)
        depth.textureType = .type2DMultisample
        depth.sampleCount = Self.sampleCount
        depth.usage = .renderTarget
        depth.storageMode = .private
        guard let msaaTex = device.makeTexture(descriptor: msaa), let resolveTex = device.makeTexture(descriptor: resolve),
              let depthTex = device.makeTexture(descriptor: depth),
              let readback = device.makeBuffer(length: width * height * 4, options: .storageModeShared),
              let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaaTex
        pass.colorAttachments[0].resolveTexture = resolveTex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depthTex
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = depthTex
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.clearStencil = 0
        pass.stencilAttachment.storeAction = .dontCare
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(scene, into: encoder, width: width, height: height)
        encoder.endEncoding()
        if let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: resolveTex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: readback, destinationOffset: 0, destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }
        let data = Data(bytes: readback.contents(), count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// What's under the cursor in the 3-D view.
public struct CadPick: Equatable {
    public var edge: EdgeRef?
    public var face: FaceTag?
    public var point: Vec3?
}

public enum CadPicker {
    /// Edges within a few screen points win over the faces behind them, so edges are easy to click.
    public static func pick(_ screen: CGPoint, camera: CadCamera, viewSize: CGSize, bodies: [Body], edgeTolerance: Double = 6) -> CadPick {
        let ray = camera.ray(at: screen, viewSize: viewSize)
        var bestT = Double.infinity
        var bestFace: FaceTag?
        var bestPoint: Vec3?
        // Start the ray far behind the target plane so nothing is missed.
        let far = 1e6
        let origin = ray.origin - ray.direction * far
        for body in bodies {
            let s = body.solid
            for f in s.faces {
                var i = 0
                while i + 2 < f.triangles.count {
                    let a = s.positions[Int(f.verts[Int(f.triangles[i])])]
                    let b = s.positions[Int(f.verts[Int(f.triangles[i + 1])])]
                    let c = s.positions[Int(f.verts[Int(f.triangles[i + 2])])]
                    i += 3
                    if let t = rayTriangle(origin: origin, dir: ray.direction, a, b, c), t > 0, t < bestT {
                        bestT = t
                        bestFace = f.tag
                        bestPoint = origin + ray.direction * t
                    }
                }
            }
        }
        // Depth of a world point along the view direction: nearer to the viewer means smaller.
        func depth(_ p: Vec3) -> Double { simd_dot(p - origin, ray.direction) }
        let frontDepth = bestPoint.map(depth) ?? .infinity
        let slack = camera.viewHeight * 0.01

        var bestEdge: EdgeRef?
        var bestDistance = edgeTolerance
        var bestDepth = Double.infinity
        for body in bodies {
            let s = body.solid
            for (index, e) in s.edges.enumerated() where e.kind == .sharp || e.kind == .tangent {
                let a = s.positions[Int(e.a)], b = s.positions[Int(e.b)]
                let pa = camera.project(a, viewSize: viewSize), pb = camera.project(b, viewSize: viewSize)
                let d = Vec2(pb.x - pa.x, pb.y - pa.y)
                let len2 = simd_length_squared(d)
                let t = len2 > 0 ? min(1, max(0, simd_dot(Vec2(screen.x - pa.x, screen.y - pa.y), d) / len2)) : 0
                let distance = simd_length(Vec2(pa.x + d.x * t - screen.x, pa.y + d.y * t - screen.y))
                guard distance < edgeTolerance else { continue }
                // Hidden edges behind the front surface don't count.
                let world = a + (b - a) * t
                let edgeDepth = depth(world)
                guard edgeDepth <= frontDepth + slack else { continue }
                // Looking straight along a face, two edges can line up exactly: the one nearer the viewer wins.
                let clearlyCloser = distance < bestDistance - 0.5
                let sameSpotButNearer = abs(distance - bestDistance) <= 0.5 && edgeDepth < bestDepth - slack
                guard clearlyCloser || sameSpotButNearer || bestEdge == nil else { continue }
                bestDistance = distance
                bestDepth = edgeDepth
                bestEdge = s.reference(toEdge: index)
            }
        }
        return CadPick(edge: bestEdge, face: bestFace, point: bestPoint)
    }
}
