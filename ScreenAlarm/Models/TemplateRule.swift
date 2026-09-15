import Foundation

struct TemplateRule: Codable, Identifiable, Equatable {
    let id: UUID
    var filename: String
    var width: Int
    var height: Int
    init(filename: String, width: Int, height: Int) { self.id = UUID(); self.filename = filename; self.width = width; self.height = height }
}

