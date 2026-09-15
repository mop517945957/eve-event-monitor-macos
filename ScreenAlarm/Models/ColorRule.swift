import Foundation

struct ColorRule: Codable, Identifiable, Equatable {
    let id: UUID
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) { self.id = UUID(); self.red = red; self.green = green; self.blue = blue }
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

