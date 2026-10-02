import Foundation

/// Draws the tray clock and encodes it as a standalone PNG (RGBA, zlib
/// stored blocks) so the shell can offer hosts a real file via
/// IconName + IconThemePath — the one icon strategy every StatusNotifier
/// implementation honors. No platform image dependencies.
enum LinuxIcon {
    static let iconSize = 24

    /// ARGB32 pixels (network byte order) for the IconPixmap property.
    static func pixmap(size: Int) -> (width: Int, height: Int, bytes: [UInt8]) {
        let (width, height, rgba) = rgbaPixels(size: size)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rgba.count / 4 * 4)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            bytes.append(rgba[index + 3])
            bytes.append(rgba[index])
            bytes.append(rgba[index + 1])
            bytes.append(rgba[index + 2])
        }
        return (width, height, bytes)
    }

    /// A complete PNG file of the same drawing.
    static func pngData(size: Int) -> Data {
        let (width, height, rgba) = rgbaPixels(size: size)
        var scanlines: [UInt8] = []
        scanlines.reserveCapacity(height * (width * 4 + 1))
        for row in 0..<height {
            scanlines.append(0)  // filter: none
            let start = row * width * 4
            scanlines.append(contentsOf: rgba[start..<(start + width * 4)])
        }
        var chunks: [UInt8] = []
        chunks.append(contentsOf: pngSignature)
        appendChunk(type: "IHDR", data: ihdr(width: width, height: height), into: &chunks)
        appendChunk(type: "IDAT", data: zlibStored(scanlines), into: &chunks)
        appendChunk(type: "IEND", data: [], into: &chunks)
        return Data(chunks)
    }

    // MARK: Drawing

    private static func rgbaPixels(size: Int) -> (Int, Int, [UInt8]) {
        let s = Double(size)
        let center = (s - 1) / 2
        let radius = s / 2 - 1
        var rgba: [UInt8] = []
        rgba.reserveCapacity(size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) - center, dy = Double(y) - center
                let distance = (dx * dx + dy * dy).squareRoot()
                var r: UInt8 = 31, g: UInt8 = 111, b: UInt8 = 235, a: UInt8 = 255
                if distance <= radius * 0.72 {
                    let hourAngle = -60.0 * Double.pi / 180, minuteAngle = -30.0 * Double.pi / 180
                    let handLength = distance / (radius * 0.62)
                    func nearHand(_ angle: Double) -> Bool {
                        let hx = sin(angle), hy = -cos(angle)
                        let dot = (dx * hx + dy * hy) / max(distance, 0.001)
                        return dot > 0.93 && handLength <= 1.0 && distance > 1.0
                    }
                    if nearHand(hourAngle) || nearHand(minuteAngle) { r = 31; g = 78; b = 184 }
                    else { r = 245; g = 248; b = 252 }
                } else if distance > radius {
                    a = 0; r = 0; g = 0; b = 0
                }
                rgba.append(r); rgba.append(g); rgba.append(b); rgba.append(a)
            }
        }
        return (size, size, rgba)
    }

    // MARK: PNG encoding (stored blocks only; small icon, maximal compatibility)

    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    private static func ihdr(width: Int, height: Int) -> [UInt8] {
        var data: [UInt8] = []
        for value in [UInt32(width), UInt32(height)] {
            data.append(UInt8((value >> 24) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }
        data.append(contentsOf: [8, 6, 0, 0, 0])  // 8-bit depth, RGBA, defaults
        return data
    }

    private static func zlibStored(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var offset = 0
        while offset < bytes.count {
            let chunk = min(65_535, bytes.count - offset)
            let last = offset + chunk >= bytes.count
            out.append(last ? 1 : 0)
            out.append(UInt8(chunk & 0xFF))
            out.append(UInt8((chunk >> 8) & 0xFF))
            out.append(UInt8(~chunk & 0xFF))
            out.append(UInt8((~chunk >> 8) & 0xFF))
            out.append(contentsOf: bytes[offset..<(offset + chunk)])
            offset += chunk
        }
        out.append(contentsOf: adler32(bytes))
        return out
    }

    private static func appendChunk(type: String, data: [UInt8], into chunks: inout [UInt8]) {
        var body: [UInt8] = Array(type.utf8)
        body.append(contentsOf: data)
        for shift in [24, 16, 8, 0] {
            chunks.append(UInt8((UInt32(data.count) >> UInt32(shift)) & 0xFF))
        }
        chunks.append(contentsOf: body)
        for byte in crc32(body) { chunks.append(byte) }
    }

    private static func adler32(_ bytes: [UInt8]) -> [UInt8] {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a &+ UInt32(byte)) % 65_521
            b = (b &+ a) % 65_521
        }
        let value = (b << 16) | a
        return [(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF].map(UInt8.init)
    }

    private static func crc32(_ bytes: [UInt8]) -> [UInt8] {
        var table: [UInt32] = []
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
            }
            table.append(c)
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        crc ^= 0xFFFF_FFFF
        return [(crc >> 24) & 0xFF, (crc >> 16) & 0xFF, (crc >> 8) & 0xFF, crc & 0xFF].map(UInt8.init)
    }
}
