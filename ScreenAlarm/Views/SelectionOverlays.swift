import AppKit
import SwiftUI

enum RegionSelectionPresenter {
    private static var controller: SelectionController?
    static func selectRegion(completion: @escaping (MonitorRegion) -> Void) { controller = SelectionController(mode: .region, completion: completion, colorCompletion: nil, templateCompletion: nil); controller?.show() }
    static func selectColor(completion: @escaping (ColorRule) -> Void) { controller = SelectionController(mode: .color, completion: nil, colorCompletion: completion, templateCompletion: nil); controller?.show() }
    static func selectTemplate(completion: @escaping (CGImage) -> Void) { controller = SelectionController(mode: .template, completion: nil, colorCompletion: nil, templateCompletion: completion); controller?.show() }
    static func dismissController() { controller = nil }
}

private enum SelectionMode { case region, color, template }

private final class SelectionController {
    private var panels: [NSPanel] = []
    private var hiddenWindows: [NSWindow] = []
    private let mode: SelectionMode
    private let regionCompletion: ((MonitorRegion) -> Void)?
    private let colorCompletion: ((ColorRule) -> Void)?
    private let templateCompletion: ((CGImage) -> Void)?
    init(mode: SelectionMode, completion: ((MonitorRegion) -> Void)?, colorCompletion: ((ColorRule) -> Void)?, templateCompletion: ((CGImage) -> Void)?) { self.mode = mode; regionCompletion = completion; self.colorCompletion = colorCompletion; self.templateCompletion = templateCompletion }
    func show() {
        // Do not call NSApp.hide here: it also hides the newly-created panels and leaves
        // the app inactive until the user clicks its Dock icon. Hide only normal windows.
        NSApp.activate(ignoringOtherApps: true)
        hiddenWindows = NSApp.windows.filter { !($0 is NSPanel) && $0.isVisible }
        hiddenWindows.forEach { $0.orderOut(nil) }
        for screen in NSScreen.screens {
            let panel = OverlayPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            panel.level = .screenSaver; panel.isOpaque = false; panel.backgroundColor = .clear; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]; panel.ignoresMouseEvents = false
            let view = SelectionCanvas(frame: CGRect(origin: .zero, size: screen.frame.size), screen: screen, mode: mode) { [weak self] result in self?.finish(result: result) }
            panel.contentView = view; panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless(); panels.append(panel)
        }
        panels.first?.makeKey()
    }
    private func finish(result: SelectionResult) {
        panels.forEach { $0.orderOut(nil) }; panels.removeAll()
        hiddenWindows.forEach { $0.makeKeyAndOrderFront(nil) }; hiddenWindows.removeAll()
        switch result {
        case .region(let region): regionCompletion?(region)
        case .color(let rule): colorCompletion?(rule)
        case .template(let region):
            // Capture only after the selection overlay has left the composited screen;
            // otherwise a saved template can accidentally contain the dark overlay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, let image = self.captureTemplate(region) else { return }
                self.hiddenWindows.forEach { $0.makeKeyAndOrderFront(nil) }
                self.hiddenWindows.removeAll()
                self.templateCompletion?(image)
                RegionSelectionPresenter.dismissController()
            }
            return
        case .cancelled: break
        }
        RegionSelectionPresenter.dismissController()
    }
    private func captureTemplate(_ region: MonitorRegion) -> CGImage? {
        guard let full = CGDisplayCreateImage(CGDirectDisplayID(region.displayID)) else { return nil }
        let sx = CGFloat(full.width) / region.displayPointWidth, sy = CGFloat(full.height) / region.displayPointHeight
        let rect = CGRect(x: region.x * sx, y: (region.displayPointHeight - region.y - region.height) * sy, width: region.width * sx, height: region.height * sy).integral
        return full.cropping(to: rect)
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private enum SelectionResult { case region(MonitorRegion), color(ColorRule), template(MonitorRegion), cancelled }

private final class SelectionCanvas: NSView {
    private let targetScreen: NSScreen, mode: SelectionMode, done: (SelectionResult) -> Void
    private var start: CGPoint?
    private var current: CGPoint = .zero
    private var sampledColor: ColorRule?
    init(frame: CGRect, screen: NSScreen, mode: SelectionMode, done: @escaping (SelectionResult) -> Void) { targetScreen = screen; self.mode = mode; self.done = done; super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil)) }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); current = start!; if mode == .color { finishColor(at: current) }; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { current = convert(event.locationInWindow, from: nil); if mode == .color { sampledColor = color(at: current) }; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { guard mode == .color else { return }; current = convert(event.locationInWindow, from: nil); sampledColor = color(at: current); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard mode != .color, let start else { return }; current = convert(event.locationInWindow, from: nil); let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y)).integral
        guard rect.width >= 3, rect.height >= 3 else { return }
        if mode == .region { done(.region(makeRegion(rect))) } else { done(.template(makeRegion(rect))) }
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { done(.cancelled) } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.38).setFill(); bounds.fill()
        if let start { let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y)); NSColor.clear.setFill(); rect.fill(using: .copy); NSColor.systemYellow.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke() }
        if mode == .color, let color = sampledColor { let box = CGRect(x: min(max(current.x + 18, 8), bounds.width - 154), y: min(max(current.y + 18, 8), bounds.height - 78), width: 146, height: 66); NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill(); NSColor(red: CGFloat(color.red)/255, green: CGFloat(color.green)/255, blue: CGFloat(color.blue)/255, alpha: 1).setFill(); CGRect(x: box.minX + 8, y: box.minY + 8, width: 48, height: 50).fill(); let text = "\(color.hex)\nRGB(\(color.red), \(color.green), \(color.blue))" as NSString; text.draw(at: CGPoint(x: box.minX + 64, y: box.minY + 19), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]) }
    }
    private func makeRegion(_ rect: CGRect) -> MonitorRegion {
        let id = (targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let pxW = CGDisplayPixelsWide(CGDirectDisplayID(id)), pxH = CGDisplayPixelsHigh(CGDirectDisplayID(id))
        return MonitorRegion(displayID: id, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, displayPointWidth: bounds.width, displayPointHeight: bounds.height, displayPixelWidth: pxW, displayPixelHeight: pxH)
    }
    private func image(rect: CGRect) -> CGImage? {
        let id = (targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? 0
        guard let full = CGDisplayCreateImage(id) else { return nil }
        let sx = CGFloat(full.width) / bounds.width, sy = CGFloat(full.height) / bounds.height
        let crop = CGRect(x: rect.minX * sx, y: (bounds.height - rect.maxY) * sy, width: rect.width * sx, height: rect.height * sy).integral
        return full.cropping(to: crop)
    }
    private func color(at point: CGPoint) -> ColorRule? {
        guard let image = image(rect: CGRect(x: point.x, y: point.y, width: 1, height: 1)), let bytes = image.rgbaBytes, bytes.count >= 3 else { return nil }
        return ColorRule(red: bytes[0], green: bytes[1], blue: bytes[2])
    }
    private func finishColor(at point: CGPoint) { if let rule = color(at: point) { done(.color(rule)) } }
}

/// Coordinates are measured on the captured window image, never on the desktop.
enum WindowCropGeometry {
    static func imageRect(imageSize: NSSize, bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    static func crop(start: NSPoint, end: NSPoint, imageRect: NSRect) -> WindowCrop? {
        guard imageRect.width > 0, imageRect.height > 0, imageRect.contains(start) else { return nil }
        let selection = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(imageRect)
        guard selection.width >= 3, selection.height >= 3 else { return nil }
        return WindowCrop(x: (selection.minX - imageRect.minX) / imageRect.width,
                          y: (selection.minY - imageRect.minY) / imageRect.height,
                          width: selection.width / imageRect.width, height: selection.height / imageRect.height)
    }
}

@MainActor
final class WindowCropEditor: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var completion: ((WindowCrop?) -> Void)?
    init(image: CGImage, title: String, completion: @escaping (WindowCrop?) -> Void) {
        self.completion = completion
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1100, height: 800)
        panel = CropEditorPanel(contentRect: NSRect(x: 0, y: 0, width: min(1100, available.width - 80), height: min(740, available.height - 100)), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = "\(title) · 在窗口快照内拖拽选区，松开确认，Esc 取消"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 300)
        panel.level = .screenSaver
        panel.delegate = self
        let canvas = WindowCropCanvas(image: image) { [weak self] crop in self?.finish(crop) }
        panel.contentView = canvas
        panel.center()
    }
    func show() { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel.contentView) }
    func cancel() { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }
    private func finish(_ crop: WindowCrop?) {
        guard let completion else { return }
        self.completion = nil
        panel.orderOut(nil)
        completion(crop)
    }
}

private final class CropEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class WindowCropCanvas: NSView {
    private let image: NSImage
    private let done: (WindowCrop?) -> Void
    private var start: NSPoint?
    private var current = NSPoint.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(image: CGImage, done: @escaping (WindowCrop?) -> Void) {
        self.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        self.done = done
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError() }
    private var imageRect: NSRect { WindowCropGeometry.imageRect(imageSize: image.size, bounds: bounds) }
    override func resetCursorRects() { addCursorRect(imageRect, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        image.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        if let start {
            let rect = NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y)).intersection(imageRect)
            NSColor.systemYellow.withAlphaComponent(0.2).setFill(); rect.fill()
            NSColor.systemYellow.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        start = point; current = point; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { current = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        self.start = nil; needsDisplay = true
        if let crop = WindowCropGeometry.crop(start: start, end: end, imageRect: imageRect) { done(crop) }
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { done(nil) } else { super.keyDown(with: event) } }
}
