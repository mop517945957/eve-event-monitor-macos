import CoreGraphics

enum TemplateMatchingService {
    /// Fixed-size RGB template matcher. A sparse precheck avoids expensive full comparisons.
    static func bestSimilarity(template: CGImage, in source: CGImage, threshold: Double) -> Double {
        guard template.width <= source.width, template.height <= source.height,
              let t = template.rgbaBytes, let s = source.rgbaBytes else { return 0 }
        let tw = template.width, th = template.height, sw = source.width
        let sampleStep = max(1, min(tw, th) / 14)
        let requiredPrecheck = threshold * 0.82
        var best = 0.0
        // Candidate stride reduces work for the usual fixed UI-icon case.
        for y in stride(from: 0, through: source.height - th, by: 2) {
            for x in stride(from: 0, through: source.width - tw, by: 2) {
                var quickDiff = 0.0; var quickCount = 0
                for ty in stride(from: 0, to: th, by: max(sampleStep * 3, 1)) {
                    for tx in stride(from: 0, to: tw, by: max(sampleStep * 3, 1)) {
                        let a = (ty * tw + tx) * 4, b = ((y + ty) * sw + x + tx) * 4
                        quickDiff += abs(Double(t[a]) - Double(s[b])) + abs(Double(t[a + 1]) - Double(s[b + 1])) + abs(Double(t[a + 2]) - Double(s[b + 2])); quickCount += 3
                    }
                }
                guard quickCount > 0, 1 - quickDiff / Double(quickCount * 255) >= requiredPrecheck else { continue }
                var diff = 0.0; var count = 0
                for ty in stride(from: 0, to: th, by: sampleStep) {
                    for tx in stride(from: 0, to: tw, by: sampleStep) {
                        let a = (ty * tw + tx) * 4, b = ((y + ty) * sw + x + tx) * 4
                        diff += abs(Double(t[a]) - Double(s[b])) + abs(Double(t[a + 1]) - Double(s[b + 1])) + abs(Double(t[a + 2]) - Double(s[b + 2])); count += 3
                    }
                }
                let similarity = 1 - diff / Double(count * 255); best = max(best, similarity)
                if best >= threshold { return best }
            }
        }
        return best
    }
}

