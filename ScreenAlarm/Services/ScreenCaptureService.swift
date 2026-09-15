import ScreenCaptureKit
import CoreMedia
import CoreImage

final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    var onImage: ((CGImage) -> Void)?
    var onCaptureStopped: ((Error) -> Void)?
    private var stream: SCStream?
    private var source: Source?
    private let queue = DispatchQueue(label: "ScreenAlarm.capture", qos: .userInitiated)

    private enum Source {
        case region(MonitorRegion)
        case window(WindowCrop?)
    }

    func start(region: MonitorRegion) async throws {
        stop(); source = .region(region)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGDirectDisplayID(region.displayID) }) else { throw CaptureError.displayUnavailable }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = region.displayPixelWidth; config.height = region.displayPixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    /// Captures an individual composited window, independent from its position in
    /// the desktop. This lets detection continue while another window is frontmost.
    func start(window target: WindowTarget, crop: WindowCrop?) async throws {
        stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = resolveWindow(target, from: content.windows) else {
            throw CaptureError.windowUnavailable(target.displayName)
        }

        source = .window(crop)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // SCWindow coordinates are in points. A 2× stream preserves detail on
        // Retina displays and still keeps the detector limited to this window.
        config.width = max(1, Int(window.frame.width * 2))
        config.height = max(1, Int(window.frame.height * 2))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func availableWindows() async throws -> [WindowTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        return content.windows.compactMap { window in
            guard let app = window.owningApplication,
                  app.bundleIdentifier != ownBundleIdentifier,
                  window.frame.width >= 80, window.frame.height >= 60 else { return nil }
            return WindowTarget(
                windowID: window.windowID,
                applicationPID: app.processID,
                bundleIdentifier: app.bundleIdentifier,
                applicationName: app.applicationName,
                title: window.title ?? "",
                frameX: window.frame.origin.x,
                frameY: window.frame.origin.y,
                frameWidth: window.frame.width,
                frameHeight: window.frame.height
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func refreshedTarget(for target: WindowTarget) async throws -> WindowTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = resolveWindow(target, from: content.windows), let app = window.owningApplication else {
            throw CaptureError.windowUnavailable(target.displayName)
        }
        return WindowTarget(
            windowID: window.windowID,
            applicationPID: app.processID,
            bundleIdentifier: app.bundleIdentifier,
            applicationName: app.applicationName,
            title: window.title ?? "",
            frameX: window.frame.origin.x,
            frameY: window.frame.origin.y,
            frameWidth: window.frame.width,
            frameHeight: window.frame.height
        )
    }

    func stop() { let current = stream; stream = nil; source = nil; if let current { Task { try? await current.stopCapture() } } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer), let buffer = sampleBuffer.imageBuffer, let source else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        guard let full = ciContext.createCGImage(ci, from: ci.extent) else { return }
        if case let .window(crop) = source {
            guard let crop else { onImage?(full); return }
            let rect = CGRect(
                x: CGFloat(crop.x) * CGFloat(full.width),
                y: CGFloat(crop.y) * CGFloat(full.height),
                width: CGFloat(crop.width) * CGFloat(full.width),
                height: CGFloat(crop.height) * CGFloat(full.height)
            ).integral.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
            guard rect.width > 0, rect.height > 0, let image = full.cropping(to: rect) else { return }
            onImage?(image)
            return
        }
        guard case let .region(region) = source else { return }
        let sx = CGFloat(full.width) / region.displayPointWidth, sy = CGFloat(full.height) / region.displayPointHeight
        let crop = CGRect(x: region.x * sx, y: (region.displayPointHeight - region.y - region.height) * sy, width: region.width * sx, height: region.height * sy).integral.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard crop.width > 0, crop.height > 0, let image = full.cropping(to: crop) else { return }
        onImage?(image)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard self.stream === stream else { return }
        self.stream = nil
        source = nil
        onCaptureStopped?(error)
    }

    private func resolveWindow(_ target: WindowTarget, from windows: [SCWindow]) -> SCWindow? {
        if let exact = windows.first(where: { $0.windowID == target.windowID }) { return exact }
        return windows.first {
            guard let app = $0.owningApplication else { return false }
            let sameApp: Bool
            if let bundleIdentifier = target.bundleIdentifier {
                sameApp = app.bundleIdentifier == bundleIdentifier
            } else {
                sameApp = app.processID == target.applicationPID
            }
            return sameApp && $0.title == target.title && $0.frame.width >= 80 && $0.frame.height >= 60
        }
    }

    enum CaptureError: LocalizedError {
        case displayUnavailable
        case windowUnavailable(String)
        var errorDescription: String? {
            switch self {
            case .displayUnavailable: return "所选显示器当前不可用。"
            case .windowUnavailable(let name): return "监控窗口“\(name)”当前不可用。请重新选择窗口；窗口关闭、最小化或重启后可能需要重新绑定。"
            }
        }
    }
}
