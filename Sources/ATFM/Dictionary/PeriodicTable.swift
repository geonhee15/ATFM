import SwiftUI

struct ChemicalElement: Codable, Identifiable, Equatable {
    enum Category: String, Codable {
        case alkali, alkalineEarth, transition, postTransition, metalloid, nonmetal, halogen, noble, lanthanide, actinide, unknown

        var title: String {
            switch self {
            case .alkali: return "알칼리 금속"
            case .alkalineEarth: return "알칼리 토금속"
            case .transition: return "전이 금속"
            case .postTransition: return "전이후 금속"
            case .metalloid: return "준금속"
            case .nonmetal: return "비금속"
            case .halogen: return "할로젠"
            case .noble: return "비활성 기체"
            case .lanthanide: return "란타넘족"
            case .actinide: return "악티늄족"
            case .unknown: return "미확인"
            }
        }

        var color: Color {
            switch self {
            case .alkali: return Color(red: 0.95, green: 0.42, blue: 0.40)
            case .alkalineEarth: return Color(red: 0.98, green: 0.62, blue: 0.30)
            case .transition: return Color(red: 0.96, green: 0.80, blue: 0.30)
            case .postTransition: return Color(red: 0.55, green: 0.75, blue: 0.45)
            case .metalloid: return Color(red: 0.35, green: 0.75, blue: 0.70)
            case .nonmetal: return Color(red: 0.35, green: 0.65, blue: 0.95)
            case .halogen: return Color(red: 0.50, green: 0.55, blue: 0.95)
            case .noble: return Color(red: 0.72, green: 0.50, blue: 0.95)
            case .lanthanide: return Color(red: 0.95, green: 0.55, blue: 0.75)
            case .actinide: return Color(red: 0.85, green: 0.45, blue: 0.60)
            case .unknown: return Color.gray
            }
        }

        static let legend: [Category] = [.alkali, .alkalineEarth, .transition, .postTransition, .metalloid, .nonmetal, .halogen, .noble, .lanthanide, .actinide]
    }

    let n: Int
    let sym: String
    let en: String
    let ko: String
    let alias: [String]
    let mass: Double?
    let cat: Category
    let period: Int
    let group: Int?
    let block: String?
    let phase: String?
    let config: String?
    let eneg: Double?
    let density: Double?
    let melt: Double?
    let boil: Double?
    let found: String?
    let x: Int
    let y: Int

    var id: Int { n }

    var phaseKorean: String {
        switch phase {
        case "Solid": return "고체"
        case "Liquid": return "액체"
        case "Gas": return "기체"
        default: return "미확인"
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return false }
        if let number = Int(q) { return number == n }
        return sym.lowercased() == q || en.lowercased().hasPrefix(q) || ko.hasPrefix(q) || alias.contains { $0.hasPrefix(q) }
            || cat.title.contains(q)
    }
}

enum PeriodicTable {
    static let elements: [ChemicalElement] = {
        guard let url = Bundle.main.url(forResource: "elements", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ChemicalElement].self, from: data) else { return [] }
        return list.sorted { $0.n < $1.n }
    }()

    static func element(atX x: Int, y: Int) -> ChemicalElement? {
        elements.first { $0.x == x && $0.y == y }
    }

    static func search(_ query: String) -> [ChemicalElement] {
        elements.filter { $0.matches(query) }
    }

    static func kelvinToCelsius(_ k: Double) -> String {
        String(format: "%.0f °C", k - 273.15)
    }
}
