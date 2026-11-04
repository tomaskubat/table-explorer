import SwiftUI

enum ProfileSort: String, CaseIterable {
    case name = "Name", tag = "Color Tag", driver = "Driver"
    func value(_ profile: ConnectionProfile) -> String {
        switch self {
        case .name: profile.name
        case .tag: profile.tagColor ?? "Teal"
        case .driver: profile.driver.rawValue
        }
    }
}

extension ConnectionProfile {
    var production: Bool { environment.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("pro") }
    var environmentColor: Color {
        if production { return .red }
        return environment.lowercased() == "local" ? .green : .orange
    }
    var badgeColor: Color {
        if let tagColor, tagColor.hasPrefix("#"), tagColor.count == 7, let rgb = UInt32(tagColor.dropFirst(), radix: 16) {
            return Color(red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }
        return switch tagColor {
        case "Blue": .blue
        case "Purple": .purple
        case "Orange": .orange
        case "Red": .red
        case "Green": .green
        default: .teal
        }
    }
}
