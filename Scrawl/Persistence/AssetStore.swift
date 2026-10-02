import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// Binary assets (images) embedded in a document. Assets are content-addressed: the ID is a
/// hash of the bytes, so importing the same image twice stores it once and IDs are stable.
final class AssetStore {
    struct Asset: Equatable {
        let id: String
        let data: Data
        let fileExtension: String
    }

    private(set) var assets: [String: Asset] = [:]
    private var images: [String: NSImage] = [:]

    init() {}

    var ids: [String] { assets.keys.sorted() }

    func asset(_ id: String) -> Asset? { assets[id] }

    /// Adds image bytes and returns the asset ID. Returns nil if the bytes aren't a readable image.
    @discardableResult
    func add(data: Data, fileExtension ext: String? = nil) -> String? {
        let resolvedExt = ext.map { $0.lowercased() } ?? AssetStore.sniffExtension(data) ?? "png"
        let id = AssetStore.hash(data)
        if assets[id] == nil {
            guard NSImage(data: data) != nil else { return nil }
            assets[id] = Asset(id: id, data: data, fileExtension: resolvedExt)
        }
        return id
    }

    /// Inserts an asset as-is (used when loading or pasting with a known ID).
    func insert(_ asset: Asset) {
        assets[asset.id] = asset
        images[asset.id] = nil
    }

    func merge(_ other: AssetStore) {
        for a in other.assets.values where assets[a.id] == nil { assets[a.id] = a }
    }

    func image(_ id: String) -> NSImage? {
        if let i = images[id] { return i }
        guard let a = assets[id], let img = NSImage(data: a.data) else { return nil }
        images[id] = img
        return img
    }

    /// Intrinsic size in points (pixels for bitmaps, so imports land at 1:1 on non-Retina zoom).
    func naturalSize(_ id: String) -> CGSize? {
        guard let img = image(id) else { return nil }
        if let rep = img.representations.first as? NSBitmapImageRep, rep.pixelsWide > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return img.size
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func sniffExtension(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.count > 11, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        if b.starts(with: [0x49, 0x49, 0x2A]) || b.starts(with: [0x4D, 0x4D, 0x00]) { return "tiff" }
        if b.count > 11, String(bytes: b[4..<12], encoding: .ascii)?.hasPrefix("ftyphei") == true { return "heic" }
        if let s = String(data: data.prefix(512), encoding: .utf8), s.contains("<svg") { return "svg" }
        return nil
    }

    static var importableTypes: [UTType] {
        [.png, .jpeg, .gif, .tiff, .heic, .webP, .bmp, .svg, .image]
    }
}
