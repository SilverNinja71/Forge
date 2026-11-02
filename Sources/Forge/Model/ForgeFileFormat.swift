import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// `manifest.json` inside a `.forge` package.
///
/// Package layout (a folder that Finder and Files show as one document):
/// ```
/// Part.forge/
///   manifest.json       ← written last: the commit point of a save, as the sync engine expects
///   model.json          ← the feature history: the real source of the model
///   mesh/bodies.bin     ← triangles of the current bodies, for previews and tools that can't regenerate
///   thumbnail.png       ← preview for the gallery
/// ```
/// Saves are deltas: a file is rewritten only when its bytes changed, so sync uploads only what's different.
public struct ForgeManifest: Codable, Sendable {
    public var format = "forge"
    public var version = 1
    public var name: String
    public var unitScale: Double
    public var bodyCount: Int
    public var featureCount: Int
    public var fingerprints: [String: String]
    public var created: Date
    public var modified: Date
    public var saveCount: Int
    public var generator = "Forge 0.1"
}

public enum ForgeFileError: Error, LocalizedError {
    case notAForgeFile
    case newerVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .notAForgeFile: return "This isn't a Forge project."
        case .newerVersion(let v): return "This project was made by a newer Forge (format \(v)). Please update."
        }
    }
}

/// Reads and writes the mesh cache: "FMSH", body count, then for each body a triangle count and
/// 18 little-endian floats per triangle (position and normal for each corner).
public enum ForgeMeshCache {
    public static func encode(_ bodies: [Body]) -> Data {
        var data = Data("FMSH".utf8)
        func append(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(bodies.count))
        for body in bodies {
            let s = body.solid
            append(UInt32(s.triangleCount))
            var floats: [Float32] = []
            floats.reserveCapacity(s.triangleCount * 18)
            for f in s.faces {
                for t in f.triangles {
                    let i = Int(t)
                    let p = s.positions[Int(f.verts[i])], n = f.normals[i]
                    floats += [Float32(p.x), Float32(p.y), Float32(p.z), Float32(n.x), Float32(n.y), Float32(n.z)]
                }
            }
            floats.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Triangle count per body, or nil if the data isn't a mesh cache.
    public static func triangleCounts(_ data: Data) -> [Int]? {
        guard data.count >= 8, data.prefix(4) == Data("FMSH".utf8) else { return nil }
        func read(_ at: Int) -> UInt32? {
            guard at + 4 <= data.count else { return nil }
            let base = data.startIndex + at
            return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
        }
        guard let count = read(4) else { return nil }
        var at = 8
        var out: [Int] = []
        for _ in 0..<count {
            guard let t = read(at) else { return nil }
            out.append(Int(t))
            at += 4 + Int(t) * 18 * 4
            guard at <= data.count else { return nil }
        }
        return out
    }
}

/// A binary STL file of all bodies, the format 3-D printers and slicers take.
public enum STLExporter {
    public static func data(for bodies: [Body]) -> Data {
        let triangles = bodies.reduce(0) { $0 + $1.solid.triangleCount }
        var data = Data(count: 80)
        var count = UInt32(triangles).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.reserveCapacity(84 + triangles * 50)
        func put(_ v: Vec3) {
            for k in 0..<3 {
                var f = Float32(v[k]).bitPattern.littleEndian
                withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
            }
        }
        for body in bodies {
            let s = body.solid
            for f in s.faces {
                var i = 0
                while i + 2 < f.triangles.count {
                    put(f.plane.normal)
                    for k in 0..<3 { put(s.positions[Int(f.verts[Int(f.triangles[i + k])])]) }
                    data.append(contentsOf: [0, 0])
                    i += 3
                }
            }
        }
        return data
    }
}

extension CadDocument {
    public static let fileExtension = "forge"

    /// Saves to `url`, writing only what changed. Returns the changed files, manifest last.
    @discardableResult
    public func save(to url: URL, thumbnail: CGImage? = nil) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601

        var files: [(String, Data)] = [("model.json", try encoder.encode(tree)), ("mesh/bodies.bin", ForgeMeshCache.encode(bodies))]
        if let thumbnail, let png = Self.pngData(thumbnail) { files.append(("thumbnail.png", png)) }

        let oldFingerprints = Self.readManifest(url)?.fingerprints ?? [:]
        var fingerprints = oldFingerprints
        var changed: [String] = []
        for (path, data) in files {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let target = url.appendingPathComponent(path)
            if oldFingerprints[path] == hash, fm.fileExists(atPath: target.path) { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            fingerprints[path] = hash
            changed.append(path)
        }

        saveCount += 1
        let manifest = ForgeManifest(name: name, unitScale: tree.unitScale, bodyCount: bodies.count, featureCount: tree.features.count,
                                     fingerprints: fingerprints, created: created, modified: Date(), saveCount: saveCount)
        // The manifest goes last: a reader that finds it knows everything it lists is in place.
        try encoder.encode(manifest).write(to: url.appendingPathComponent("manifest.json"), options: .atomic)
        changed.append("manifest.json")
        fileURL = url
        hasUnsavedChanges = false
        return changed
    }

    public static func open(_ url: URL) throws -> CadDocument {
        guard let manifest = readManifest(url), manifest.format == "forge" else { throw ForgeFileError.notAForgeFile }
        guard manifest.version <= 1 else { throw ForgeFileError.newerVersion(manifest.version) }
        let data = try Data(contentsOf: url.appendingPathComponent("model.json"))
        let tree = try JSONDecoder().decode(FeatureTree.self, from: data)
        let doc = CadDocument(name: url.deletingPathExtension().lastPathComponent, tree: tree)
        doc.fileURL = url
        doc.created = manifest.created
        doc.saveCount = manifest.saveCount
        return doc
    }

    static func readManifest(_ url: URL) -> ForgeManifest? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ForgeManifest.self, from: data)
    }

    /// Quick look at a project for the gallery, without computing its model.
    public static func peek(_ url: URL) -> (manifest: ForgeManifest, thumbnail: CGImage?)? {
        guard let m = readManifest(url) else { return nil }
        var image: CGImage?
        if let src = CGImageSourceCreateWithURL(url.appendingPathComponent("thumbnail.png") as CFURL, nil) {
            image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        return (m, image)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
