import AppKit

final class TemplateStore {
    static let shared = TemplateStore()
    private let directory: URL
    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("ScreenAlarm/Templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func save(_ image: CGImage) -> TemplateRule? {
        let name = "template-\(UUID().uuidString).png"
        let url = directory.appendingPathComponent(name)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        do { try data.write(to: url, options: .atomic); return TemplateRule(filename: name, width: image.width, height: image.height) } catch { return nil }
    }
    func image(for rule: TemplateRule) -> CGImage? { NSImage(contentsOf: directory.appendingPathComponent(rule.filename))?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    func delete(_ rule: TemplateRule) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(rule.filename)) }
}

