import Foundation

enum LinuxIcon {
    /// ARGB32 pixmap for the tray item: a blue disc with a light clock face
    /// and hands, drawn per pixel so no host icon theme is required.
    static func pixmap(size: Int) -> (width: Int, height: Int, bytes: [UInt8]) {
        let s = Double(size)
        let center = (s - 1) / 2
        let radius = s / 2 - 1
        var bytes: [UInt8] = []
        bytes.reserveCapacity(size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) - center, dy = Double(y) - center
                let distance = (dx * dx + dy * dy).squareRoot()
                var r: UInt8 = 31, g: UInt8 = 111, b: UInt8 = 235, a: UInt8 = 255
                if distance <= radius * 0.72 {
                    // Face: white with dark hands from center toward 10 and 2 o'clock.
                    let hourAngle = -60.0 * .pi / 180, minuteAngle = -30.0 * .pi / 180
                    let handLength = distance / (radius * 0.62)
                    func nearHand(_ angle: Double) -> Bool {
                        let hx = sin(angle), hy = -cos(angle)
                        let dot = (dx * hx + dy * hy) / max(distance, 0.001)
                        return dot > 0.93 && handLength <= 1.0 && distance > 1.0
                    }
                    if nearHand(hourAngle) || nearHand(minuteAngle) { r = 31; g = 78; b = 184 }
                    else { r = 245; g = 248; b = 252 }
                } else if distance <= radius {
                    r = 31; g = 111; b = 235
                } else {
                    a = 0; r = 0; g = 0; b = 0
                }
                bytes.append(a); bytes.append(r); bytes.append(g); bytes.append(b)
            }
        }
        return (size, size, bytes)
    }
}
