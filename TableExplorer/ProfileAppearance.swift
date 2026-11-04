import SwiftUI

enum ProfileSort: String, CaseIterable {
    case name = "Name", tag = "Tag", color = "Status Color", driver = "Driver"
    func value(_ profile: ConnectionProfile) -> String {
        switch self {
        case .name: profile.name
        case .tag: profile.connectionTag
        case .color: profile.tagColor ?? StatusSwatch.neutral.rawValue
        case .driver: profile.driver.rawValue
        }
    }
}

enum ConnectionTag: String, CaseIterable {
    case local, testing, development, staging, production

    static func displayValue(_ stored: String) -> String {
        let value = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "dev": return development.rawValue
        case "test": return testing.rawValue
        case "stage": return staging.rawValue
        case "prod": return production.rawValue
        default: return Self(rawValue: value)?.rawValue ?? stored
        }
    }
}

enum StatusSwatch: String, CaseIterable {
    case neutral = "#F8F8F8", blue = "#BDCCF4", yellow = "#F8F7BD", green = "#DAEBC2", red = "#FFD7D4"
    var name: String { String(describing: self).capitalized }
}

extension Color {
    init?(statusHex: String) {
        guard statusHex.count == 7, statusHex.first == "#", let rgb = UInt32(statusHex.dropFirst(), radix: 16) else { return nil }
        self.init(.sRGB, red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    var statusHex: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}

extension ConnectionProfile {
    // Keep reading the original archive keys; existing profiles and URL imports
    // already store the TablePlus tag as "environment" and the status color as "tagColor".
    var connectionTag: String {
        get { ConnectionTag.displayValue(environment) }
        set { environment = newValue }
    }
    var production: Bool { environment.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("pro") }
    var environmentColor: Color {
        if production { return .red }
        return connectionTag == "local" ? .green : .orange
    }
    var badgeColor: Color {
        if let tagColor, let color = Color(statusHex: tagColor) { return color }
        switch tagColor {
        case "Blue": return .blue
        case "Purple": return .purple
        case "Orange": return .orange
        case "Red": return .red
        case "Green": return .green
        case "Teal": return .teal
        default: return Color(statusHex: StatusSwatch.neutral.rawValue)!
        }
    }
}
