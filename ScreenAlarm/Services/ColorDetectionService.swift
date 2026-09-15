import CoreGraphics

enum ColorDetectionService {
    struct Result {
        var maximumPixels: Int = 0
        var matchingRule: ColorRule?
        var isMatch: Bool { matchingRule != nil }
    }

    static func match(in image: CGImage, rules: [ColorRule], tolerance: Double, minimum: Int) -> Result {
        guard !rules.isEmpty, let bytes = image.rgbaBytes else { return Result() }
        let toleranceSquared = tolerance * tolerance
        var counts = [Int](repeating: 0, count: rules.count)
        let stride = image.width * 4
        for y in 0..<image.height {
            let row = y * stride
            for x in 0..<image.width {
                let p = row + x * 4; let r = Double(bytes[p]); let g = Double(bytes[p + 1]); let b = Double(bytes[p + 2])
                for (index, rule) in rules.enumerated() {
                    let dr = r - Double(rule.red), dg = g - Double(rule.green), db = b - Double(rule.blue)
                    if dr * dr + dg * dg + db * db <= toleranceSquared { counts[index] += 1; break }
                }
            }
        }
        guard let winner = counts.indices.max(by: { counts[$0] < counts[$1] }) else { return Result() }
        return Result(maximumPixels: counts[winner], matchingRule: counts[winner] >= minimum ? rules[winner] : nil)
    }
}

extension CGImage {
    var rgbaBytes: [UInt8]? {
        let size = width * height * 4; var result = [UInt8](repeating: 0, count: size)
        guard let ctx = CGContext(data: &result, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none; ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height)); return result
    }
}
