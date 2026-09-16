import Foundation
import SwiftUI
import AppKit

struct IntelMap: Decodable {
    struct System: Decodable { let id: Int; let name: String; let aliases: [String]; let neighbors: [Int] }
    let build: String
    let date: String
    let systems: [System]
}
struct IntelGraph {
    let map: IntelMap
    let byID: [Int: IntelMap.System]
    let aliases: [String: Int]
    init(_ map: IntelMap) {
        self.map = map
        byID = Dictionary(uniqueKeysWithValues: map.systems.map { ($0.id, $0) })
        var names: [String: Int] = [:]
        for system in map.systems {
            for name in system.aliases + [system.name] { names[name.lowercased()] = system.id }
        }
        aliases = names
    }
    func distances(from source: Int, limit: Int) -> [Int: Int] {
        guard byID[source] != nil else { return [:] }
        var distances = [source: 0], queue = [source], index = 0
        while index < queue.count {
            let current = queue[index]; index += 1
            let depth = distances[current]!
            guard depth < limit else { continue }
            for next in byID[current]?.neighbors ?? [] where distances[next] == nil {
                distances[next] = depth + 1; queue.append(next)
            }
        }
        return distances
    }
}
struct IntelLocation: Equatable {
    let character: String
    let characterID: String
    let system: Int
    let date: Date
}
struct IntelReport: Equatable {
    let channel: String
    let system: Int
    let date: Date
    let clear: Bool
    let text: String
}
struct IntelSnapshot {
    var locations: [String: IntelLocation] = [:] // keyed by character ID, never a shared location
    var channels: Set<String> = []
    var reports: [String: IntelReport] = [:]
    var error: String?
    var checked: Date = .distantPast
}
struct IntelParser {
    let graph: IntelGraph
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy.MM.dd HH:mm:ss"; return f
    }()
    static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
    static func timestamp(_ line: String) -> Date? {
        guard let g = groups(#"\[\s*(\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2})\s*\]"#, line) else { return nil }
        return formatter.date(from: g[1])
    }
    func destination(_ line: String) -> Int? {
        let plain = line.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        guard let g = Self.groups(#"(?:从.+?跳到|Jumping from .+? to)\s*(.+?)\s*$"#, plain) else { return nil }
        return graph.aliases[g[1].trimmingCharacters(in: CharacterSet(charactersIn: "* .\r\n")).lowercased()]
    }
    func report(_ line: String, channel: String, now: Date) -> IntelReport? {
        guard let date = Self.timestamp(line), date <= now.addingTimeInterval(60), date >= now.addingTimeInterval(-3600),
              let parts = Self.groups(#"\]\s*(.+?)\s*>\s*(.+)$"#, line),
              !["eve系统", "eve system"].contains(parts[1].lowercased()) else { return nil }
        let text = parts[2].replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        // Require a complete system name at the beginning; never mistake an anomaly code
        // or a system mentioned in the MOTD for a hostile report.
        let words = text.replacingOccurrences(of: "*", with: " ").split(whereSeparator: { $0.isWhitespace || ",，:：".contains($0) }).map(String.init)
        guard !words.isEmpty else { return nil }
        var system: Int?, count = 0
        for n in stride(from: min(4, words.count), through: 1, by: -1) {
            if let id = graph.aliases[words.prefix(n).joined(separator: " ").lowercased()] { system = id; count = n; break }
        }
        guard let system else { return nil }
        let rest = words.dropFirst(count).joined(separator: " ").lowercased()
        guard !text.contains("?"), !text.contains("？"), Self.groups(#"\b(status|motd)\b|求状态|情况如何"#, rest) == nil else { return nil }
        let negative = Self.groups(#"\b(not|no)\s+(clear|clr)\b|不安全|未清"#, rest) != nil
        let clear = !negative && Self.groups(#"^(clr|clear|cleared|safe)\b|^无红|^安全|^清空|^无人|^no hostiles\b"#, rest) != nil
        return IntelReport(channel: channel, system: system, date: date, clear: clear, text: String(text.prefix(250)))
    }
}

/// Byte-aligned UTF-16/UTF-8 tailing. Keep incomplete characters and lines until the next read.
struct IntelLogCursor {
    var offset: UInt64 = 0
    var pending = Data()
    var encodingDetected = false
    var utf16 = false
    var bigEndian = false
    var listener = ""
    var channel = ""
    var channelID = ""
    var inode: UInt64 = 0
    mutating func append(_ data: Data) -> [String] {
        offset += UInt64(data.count); pending.append(data)
        if !encodingDetected {
            guard pending.count >= 2 else { return [] }
            utf16 = pending.starts(with: [0xff, 0xfe]) || pending.starts(with: [0xfe, 0xff])
            bigEndian = pending.starts(with: [0xfe, 0xff]); encodingDetected = true
        }
        let bytes = Array(pending), step = utf16 ? 2 : 1
        var start = 0, i = 0, lines: [String] = []
        while i + step <= bytes.count {
            let newline = utf16 ? (bigEndian ? bytes[i] == 0 && bytes[i+1] == 10 : bytes[i] == 10 && bytes[i+1] == 0) : bytes[i] == 10
            if newline {
                let encoding: String.Encoding = utf16 ? (bigEndian ? .utf16BigEndian : .utf16LittleEndian) : .utf8
                if let line = String(data: Data(bytes[start..<i]), encoding: encoding) {
                    lines.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}\r")))
                }
                start = i + step
            }
            i += step
        }
        pending = Data(bytes[start...])
        if pending.count > 1_048_576 { pending.removeAll() }
        return lines
    }
}

actor IntelLogReader {
    let parser: IntelParser
    var root: String = ""
    var cursors: [String: IntelLogCursor] = [:]
    var snapshot = IntelSnapshot()
    init(graph: IntelGraph) { parser = IntelParser(graph: graph) }
    func poll(root: String, now: Date = Date()) -> IntelSnapshot {
        if self.root != root { self.root = root; cursors = [:]; snapshot = IntelSnapshot() }
        snapshot.error = nil
        do {
            for folder in ["Gamelogs", "Chatlogs"] {
                let directory = URL(fileURLWithPath: root).appendingPathComponent(folder)
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "txt" }
                for url in files {
                    do { try read(url, chat: folder == "Chatlogs", now: now) }
                    catch { snapshot.error = "日志读取失败：\(url.lastPathComponent)（\(error.localizedDescription)）" }
                }
            }
        } catch { snapshot.error = "无法读取 EVE 日志目录：\(error.localizedDescription)" }
        snapshot.reports = snapshot.reports.filter { $0.value.date >= now.addingTimeInterval(-3600) }
        snapshot.checked = now
        return snapshot
    }
    private func read(_ url: URL, chat: Bool, now: Date) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var cursor = cursors[url.path] ?? IntelLogCursor()
        if size < cursor.offset || cursor.inode != inode { cursor = IntelLogCursor(); cursor.inode = inode }
        guard size > cursor.offset else { return }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        let characterID = url.deletingPathExtension().lastPathComponent.split(separator: "_").last.map(String.init) ?? ""
        while cursor.offset < size {
            let data = try handle.read(upToCount: Int(min(262144, size - cursor.offset))) ?? Data()
            if data.isEmpty { break }
            for line in cursor.append(data) {
                if !line.contains("]"), let g = IntelParser.groups(#"^\s*(?:Listener|收听者):\s*(.+?)\s*$"#, line) { cursor.listener = g[1] }
                if chat && !line.contains("]"), let g = IntelParser.groups(#"^\s*Channel Name:\s*(.+?)\s*$"#, line) { cursor.channel = g[1] }
                if chat && !line.contains("]"), let g = IntelParser.groups(#"^\s*Channel ID:\s*(.+?)\s*$"#, line) { cursor.channelID = g[1] }
                if chat {
                    guard cursor.channelID.hasPrefix("player_"), !cursor.channel.isEmpty else { continue }
                    snapshot.channels.insert(cursor.channel)
                    if let report = parser.report(line, channel: cursor.channel, now: now) {
                        let key = "\(report.channel)|\(report.system)"
                        if snapshot.reports[key].map({ $0.date < report.date || ($0.date == report.date && $0.clear && !report.clear) }) ?? true { snapshot.reports[key] = report }
                    }
                } else if (line.contains("跳到") || line.localizedCaseInsensitiveContains("Jumping from")), !cursor.listener.isEmpty, characterID.count > 6,
                          let system = parser.destination(line), let date = IntelParser.timestamp(line), date <= now.addingTimeInterval(60) {
                    if snapshot.locations[characterID].map({ $0.date < date }) ?? true {
                        snapshot.locations[characterID] = IntelLocation(character: cursor.listener, characterID: characterID, system: system, date: date)
                    }
                }
            }
        }
        cursors[url.path] = cursor
    }
}

struct CharacterIntel {
    let location: IntelLocation?
    let nearest: IntelReport?
    let jumps: Int?
}
@MainActor
final class LocalIntel: ObservableObject {
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "intel.enabled"); changed() } }
    @Published var range: Int { didSet { defaults.set(range, forKey: "intel.range"); changed() } }
    @Published var lifetime: Int { didSet { defaults.set(lifetime, forKey: "intel.lifetime"); changed() } }
    @Published var channels: Set<String> { didSet { defaults.set(Array(channels), forKey: "intel.channels"); changed() } }
    @Published var directory: String { didSet { defaults.set(directory, forKey: "intel.directory"); snapshot = IntelSnapshot(); changed() } }
    @Published private(set) var snapshot = IntelSnapshot()
    @Published private(set) var mapError: String?
    let graph: IntelGraph?
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    var onChange: (() -> Void)?
    init(defaults: UserDefaults = .standard, start: Bool = true) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "intel.enabled") as? Bool ?? true
        range = min(30, max(0, defaults.object(forKey: "intel.range") as? Int ?? 3))
        lifetime = min(30, max(1, defaults.object(forKey: "intel.lifetime") as? Int ?? 5))
        channels = Set(defaults.stringArray(forKey: "intel.channels") ?? [])
        directory = defaults.string(forKey: "intel.directory") ?? NSHomeDirectory() + "/Documents/EVE/logs"
        if let url = Bundle.main.url(forResource: "IntelMap", withExtension: "json"),
           let data = try? Data(contentsOf: url), let map = try? JSONDecoder().decode(IntelMap.self, from: data) {
            graph = IntelGraph(map)
        } else { graph = nil; mapError = "内置星门地图读取失败，无法计算跳数。" }
        if start, let graph {
            let reader = IntelLogReader(graph: graph)
            task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let path = self?.directory else { return }
                    let result = await reader.poll(root: path)
                    guard !Task.isCancelled else { return }
                    if let owner = self, owner.directory == path {
                        owner.snapshot = result
                        if owner.defaults.object(forKey: "intel.channels") == nil && !result.channels.isEmpty {
                            owner.channels = Set(result.channels.filter { $0.lowercased().hasPrefix("wc.") })
                        }
                        owner.onChange?()
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }
    deinit { task?.cancel() }
    private func changed() { onChange?() }
    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "选择包含 Gamelogs 和 Chatlogs 的 EVE 日志目录"
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }
    static func characterName(_ title: String) -> String {
        title.lowercased().hasPrefix("eve - ") ? String(title.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
    func status(for title: String, now: Date = Date()) -> CharacterIntel {
        Self.evaluate(title: title, graph: graph, snapshot: snapshot, enabled: enabled, channels: channels, range: range, lifetime: lifetime, now: now)
    }
    static func evaluate(title: String, graph: IntelGraph?, snapshot: IntelSnapshot, enabled: Bool, channels: Set<String>, range: Int, lifetime: Int, now: Date) -> CharacterIntel {
        let name = Self.characterName(title)
        let candidates = snapshot.locations.values.filter { $0.character.caseInsensitiveCompare(name) == .orderedSame }
        guard candidates.count == 1, let location = candidates.first, let graph else { return CharacterIntel(location: nil, nearest: nil, jumps: nil) }
        guard enabled, snapshot.error == nil else { return CharacterIntel(location: location, nearest: nil, jumps: nil) }
        let distances = graph.distances(from: location.system, limit: range)
        let candidatesInRange = snapshot.reports.values.filter {
            !$0.clear && channels.contains($0.channel) && now.timeIntervalSince($0.date) <= Double(lifetime * 60) && distances[$0.system] != nil
        }.sorted {
            let a = distances[$0.system]!, b = distances[$1.system]!
            return a == b ? $0.date > $1.date : a < b
        }
        let report = candidatesInRange.first
        return CharacterIntel(location: location, nearest: report, jumps: report.flatMap { distances[$0.system] })
    }
}

struct IntelSettingsSection: View {
    @ObservedObject var intel: LocalIntel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("预警频道 · 黄色预警", isOn: $intel.enabled).font(.headline)
            HStack {
                Stepper("预警范围：\(intel.range) 跳以内", value: $intel.range, in: 0...30)
                Spacer()
                Stepper("报告有效期：\(intel.lifetime) 分钟", value: $intel.lifetime, in: 1...30)
            }
            Text("点击“开始全部监控”后生效。每个角色独立定位和计算；0 跳也为黄色，视觉发现危险才报红色。只计算普通星门最短路径。").font(.caption).foregroundStyle(.secondary)
            ForEach(intel.snapshot.channels.sorted(), id: \.self) { channel in
                Toggle(channel, isOn: Binding(get: { intel.channels.contains(channel) }, set: { selected in
                    if selected { intel.channels.insert(channel) } else { intel.channels.remove(channel) }
                })).toggleStyle(.checkbox)
            }
            if intel.snapshot.channels.isEmpty { Text("尚未发现玩家频道日志，请先在游戏中打开预警频道并启用聊天记录。").font(.caption) }
            HStack { Text(intel.directory).font(.caption).textSelection(.enabled); Spacer(); Button("选择日志目录") { intel.chooseDirectory() } }
            Text("每 2 秒读取新增记录。按消息开头的完整星系名识别，忽略状态询问；clr / clear 清除同频道报告。过期只表示报告失效，不代表安全。").font(.caption).foregroundStyle(.secondary)
            if intel.snapshot.checked != .distantPast { Text("最近读取：\(intel.snapshot.checked.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            if let graph = intel.graph { Text("离线星图：\(graph.map.systems.count) 个星系 · SDE \(graph.map.build)").font(.caption).foregroundStyle(.secondary) }
            if let error = intel.mapError ?? intel.snapshot.error { Text(error).foregroundStyle(.orange).font(.caption) }
        }.padding(14).background(Color.yellow.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct CharacterIntelView: View {
    @ObservedObject var intel: LocalIntel
    let title: String
    let monitoring: Bool
    var body: some View {
        let status = intel.status(for: title)
        VStack(alignment: .leading, spacing: 4) {
            if let location = status.location {
                Text("日志位置：\(intel.graph?.byID[location.system]?.name ?? "未知") · \(location.character)")
                Text("最后跳跃：\(location.date.formatted(date: .abbreviated, time: .standard))").foregroundStyle(.secondary)
            } else { Text("位置未知：等待该角色的跳跃日志，不使用其他角色的位置。").foregroundStyle(.orange) }
            if let report = status.nearest, let jumps = status.jumps {
                Text("\(monitoring ? "🟡 黄色预警" : "待监控")：\(intel.graph?.byID[report.system]?.name ?? "") · \(jumps) 跳 · \(report.channel)").foregroundStyle(.orange)
                Text(report.text).lineLimit(2).foregroundStyle(.secondary)
            } else { Text("\(monitoring ? "监控中" : "监控未启动") · 暂无范围内有效报告").foregroundStyle(.secondary) }
        }.font(.caption)
    }
}
