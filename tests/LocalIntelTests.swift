import Foundation

@main struct LocalIntelTests {
    @MainActor static func main() async throws {
        let map = try JSONDecoder().decode(IntelMap.self, from: Data(contentsOf: URL(fileURLWithPath: "ScreenAlarm/Resources/IntelMap.json")))
        let graph = IntelGraph(map), parser = IntelParser(graph: graph)
        let a = graph.aliases["yg-82v"]!, b = graph.aliases["ub-uqz"]!, c = graph.aliases["xm-4l0"]!
        precondition(graph.distances(from: a, limit: 2)[a] == 0)
        precondition(graph.distances(from: a, limit: 2)[b] == 1)
        precondition(graph.distances(from: a, limit: 2)[c] == 2)
        precondition(graph.distances(from: a, limit: 0)[b] == nil)
        let now = IntelParser.timestamp("[ 2026.09.17 00:00:00 ]")!
        let prefix = "[ 2026.09.17 00:00:00 ] Scout > "
        precondition(parser.destination("[ 2026.09.17 00:00:00 ] (None) 从<localized hint=\"UB-UQZ\">UB-UQZ*跳到<localized hint=\"YG-82V\">YG-82V*") == a)
        precondition(parser.destination("[ 2026.09.17 00:00:00 ] (None) Jumping from YG-82V to UB-UQZ") == b)
        precondition(parser.destination("跳跃费 14000") == nil)
        precondition(parser.report(prefix + "YG-82V* badguy +3", channel: "intel", now: now)?.system == a)
        precondition(parser.report(prefix + "YG-82V* clr", channel: "intel", now: now)?.clear == true)
        precondition(parser.report(prefix + "YG-82V* not clear +3", channel: "intel", now: now)?.clear == false)
        precondition(parser.report(prefix + "YG-82V status?", channel: "intel", now: now) == nil)
        precondition(parser.report(prefix + "FKW-305 relic", channel: "intel", now: now) == nil)
        precondition(parser.report("[ 2026.09.17 00:00:00 ] EVE系统 > YG-82V MOTD", channel: "intel", now: now) == nil)
        precondition(parser.report(prefix + "YG-82V +1", channel: "intel", now: now.addingTimeInterval(4000)) == nil)
        // Two independent identities at different locations see different distances.
        var snapshot = IntelSnapshot()
        snapshot.locations["10000001"] = IntelLocation(character: "Alpha", characterID: "10000001", system: a, date: now)
        snapshot.locations["10000002"] = IntelLocation(character: "Beta", characterID: "10000002", system: b, date: now)
        snapshot.reports["intel|c"] = IntelReport(channel: "intel", system: c, date: now, clear: false, text: "XM-4L0 +3")
        func status(_ title: String, range: Int = 1, date: Date = now) -> CharacterIntel {
            LocalIntel.evaluate(title: title, graph: graph, snapshot: snapshot, enabled: true, channels: ["intel"], range: range, lifetime: 5, now: date)
        }
        precondition(status("EVE - Alpha").nearest == nil)
        precondition(status("EVE - Beta").jumps == 1)
        precondition(status("EVE - Alpha", range: 2).jumps == 2)
        precondition(status("EVE - Unknown").location == nil)
        precondition(status("EVE - Beta", date: now.addingTimeInterval(301)).nearest == nil)
        snapshot.reports["intel|c"] = IntelReport(channel: "intel", system: b, date: now, clear: false, text: "UB-UQZ +3")
        precondition(status("EVE - Beta", range: 0).jumps == 0)
        snapshot.reports["intel|c"] = IntelReport(channel: "intel", system: b, date: now, clear: true, text: "UB-UQZ clr")
        precondition(status("EVE - Beta").nearest == nil)
        // UTF16 odd-byte writes, newline splits and UTF8 multi-byte splits.
        let line = "\u{feff}[ 2026.09.17 00:00:00 ] 测试 > YG-82V +1\r\n"
        for encoding in [String.Encoding.utf16LittleEndian, .utf8] {
            var cursor = IntelLogCursor()
            let bom: [UInt8] = encoding == .utf8 ? [] : [0xff, 0xfe]
            let data = Data(bom) + line.data(using: encoding)!
            var output = cursor.append(Data(data.prefix(1)))
            for byte in data.dropFirst(1) { output += cursor.append(Data([byte])) }
            precondition(output.count == 1 && output[0].contains("测试 > YG-82V"))
            precondition(cursor.pending.isEmpty)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["Gamelogs", "Chatlogs"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        let game = root.appendingPathComponent("Gamelogs/20260917_000000_10000001.txt")
        try "收听者: Alpha\n[ 2026.09.16 23:59:58 ] (None) 从UB-UQZ*跳到YG-82V*\n".write(to: game, atomically: true, encoding: .utf8)
        let betaGame = root.appendingPathComponent("Gamelogs/20260917_000000_10000002.txt")
        try "Listener: Beta\n[ 2026.09.16 23:59:58 ] (None) Jumping from YG-82V to UB-UQZ\n".write(to: betaGame, atomically: true, encoding: .utf16)
        let chat = root.appendingPathComponent("Chatlogs/intel.txt")
        try "Channel ID: player_test\nChannel Name: intel\n\(prefix)YG-82V +1\n".write(to: chat, atomically: true, encoding: .utf16)
        let local = root.appendingPathComponent("Chatlogs/Local.txt")
        try "Channel ID: solarsystemid2\nChannel Name: Local\n\(prefix)UB-UQZ +99\n".write(to: local, atomically: true, encoding: .utf16)
        let reader = IntelLogReader(graph: graph)
        var read = await reader.poll(root: root.path, now: now)
        precondition(read.error == nil && read.locations["10000001"]?.system == a && read.locations["10000002"]?.system == b && read.reports.count == 1 && read.channels == ["intel"])
        let h = try FileHandle(forWritingTo: game); try h.seekToEnd()
        try h.write(contentsOf: Data("[ 2026.09.17 00:00:00 ] (None) 从YG-82V*跳到UB-UQZ*".utf8))
        read = await reader.poll(root: root.path, now: now)
        precondition(read.locations["10000001"]?.system == a) // incomplete line
        try h.write(contentsOf: Data("\n".utf8)); try h.close()
        read = await reader.poll(root: root.path, now: now)
        precondition(read.locations["10000001"]?.system == b)
        // File rotation and older reports cannot overwrite a newer clear.
        try "Channel ID: player_test\nChannel Name: intel\n[ 2026.09.17 00:00:01 ] Scout > YG-82V clr\n".write(to: chat, atomically: true, encoding: .utf16)
        read = await reader.poll(root: root.path, now: now.addingTimeInterval(2))
        precondition(read.reports.values.first?.clear == true)
        let old = root.appendingPathComponent("Chatlogs/older.txt")
        try "Channel ID: player_test\nChannel Name: intel\n\(prefix)YG-82V +2\n".write(to: old, atomically: true, encoding: .utf16)
        read = await reader.poll(root: root.path, now: now.addingTimeInterval(2))
        precondition(read.reports.values.first?.clear == true)
        print("PASS: graph paths, independent character distances, 0 jumps, missing identity, TTL, clear/status/MOTD, split UTF16/UTF8, append/rotation, local channel exclusion, out-of-order dedup")
        if CommandLine.arguments.contains("--live") {
            let begin = Date()
            let live = await reader.poll(root: NSHomeDirectory() + "/Documents/EVE/logs")
            print("LIVE read seconds", Date().timeIntervalSince(begin), "characters",live.locations.count,"channels",live.channels.sorted(),"error",live.error ?? "none")
            for location in live.locations.values { print(location.character, graph.byID[location.system]!.name, location.date) }
            let second = Date()
            _ = await reader.poll(root: NSHomeDirectory() + "/Documents/EVE/logs")
            print("LIVE incremental poll seconds", Date().timeIntervalSince(second))
        }
    }
}
