import AppKit

/// Independent enlarged preview of the selected monitor region. It contains no
/// detection logic and receives only the already-cropped in-memory preview image.
@MainActor
final class RegionPreviewWindowController: NSObject, NSWindowDelegate {
    private let imageView = NSImageView()
    private let panel: NSPanel
    private var hasBeenShown = false
    private var wasClosedByUser = false

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 160, y: 180, width: 620, height: 440),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Screen Alarm · 监视区域预览"
        panel.isReleasedWhenClosed = false
        // Higher than normal/floating app windows while still leaving macOS system UI usable.
        panel.level = .screenSaver
        // Keep the region preview visible when the user switches Spaces or the
        // monitored display enters a full-screen application Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 300, height: 220)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        panel.contentView = imageView
        panel.delegate = self
    }

    func update(image: NSImage) {
        imageView.image = image
        if !hasBeenShown && !wasClosedByUser {
            sizeWindow(for: image)
            panel.makeKeyAndOrderFront(nil)
            hasBeenShown = true
        } else if panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func setInteractionLocked(_ locked: Bool) { panel.ignoresMouseEvents = locked }

    func show() {
        guard imageView.image != nil else { return }
        wasClosedByUser = false
        panel.makeKeyAndOrderFront(nil)
        hasBeenShown = true
    }

    /// Selecting a new source region is an intentional request to show its preview.
    func prepareForNewRegion() {
        wasClosedByUser = false
        hasBeenShown = false
        panel.orderOut(nil)
    }

    private func sizeWindow(for image: NSImage) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let maximum = NSSize(width: 780, height: 620)
        let scale = min(maximum.width / imageSize.width, maximum.height / imageSize.height)
        let fitted = NSSize(width: max(300, imageSize.width * scale), height: max(220, imageSize.height * scale))
        panel.setContentSize(fitted)
    }

    func windowWillClose(_ notification: Notification) { wasClosedByUser = true }
}
