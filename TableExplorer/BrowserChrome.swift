import SwiftUI

/// The neutral surfaces and small controls shared by the chooser and workspace.
enum BrowserChrome {
    static let panel = adaptive(0.938, 0.15)
    static let bar = adaptive(0.918, 0.18)
    static let line = adaptive(0.85, 0.26)
    static let paper = Color(nsColor: .textBackgroundColor)

    private static func adaptive(_ light: CGFloat, _ dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }
}

struct DriverBadge: View {
    let driver: DatabaseDriver
    var diameter: CGFloat = 27
    var body: some View {
        Text(driver == .mariaDB ? "Mr" : "Sl")
            .font(.system(size: diameter * 0.47, weight: .medium, design: .rounded)).italic()
            .foregroundStyle(.white).frame(width: diameter, height: diameter)
            .background(driver == .mariaDB ? Color(red: 0.19, green: 0.58, blue: 0.61) : Color(red: 0.51, green: 0.22, blue: 0.92), in: Circle())
            .accessibilityLabel(driver.rawValue)
    }
}

struct EnvironmentBadge: View {
    let profile: ConnectionProfile
    var body: some View {
        if !profile.connectionTag.isEmpty {
            Text(String(profile.connectionTag.prefix(3)).lowercased())
                .font(.system(size: 10)).padding(.horizontal, 4)
                .overlay { RoundedRectangle(cornerRadius: 1).strokeBorder(lineWidth: 0.75) }
                .foregroundStyle(profile.environmentColor)
                .accessibilityLabel(profile.connectionTag)
        }
    }
}

struct ChromeSearchField: View {
    let title: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(title, text: $text).textFieldStyle(.plain).font(.system(size: 12)).accessibilityLabel(title)
        }
        .padding(.horizontal, 7).frame(height: 22)
        .background(BrowserChrome.paper, in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(BrowserChrome.line, lineWidth: 0.6).allowsHitTesting(false) }
    }
}

/// A folded-paper database stack, drawn at the window's native backing scale.
struct LibraryMark: View {
    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 100, sy = size.height / 80
            func face(_ hex: UInt32, _ vertices: [(Int, Int)]) {
                let points = vertices.map { CGPoint(x: CGFloat($0.0) * sx, y: CGFloat($0.1) * sy) }
                var path = Path(); path.addLines(points); path.closeSubpath()
                ctx.fill(path, with: .color(Color(red: Double(hex >> 16) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)))
            }
            for y in [46, 28, 10] {
                face(0xE77327, [(4,y+6),(46,y+16),(46,y+30),(5,y+18)])
                face(0xF99523, [(4,y+6),(46,y+16),(16,y+21)])
                face(0xFFBC25, [(46,y+16),(95,y+2),(92,y+16),(46,y+30)])
                face(0xFFDC46, [(46,y+16),(95,y+2),(68,y+24)])
                face(0xFFB62B, [(4,y+6),(54,y-8),(95,y+2),(46,y+16)])
                face(0xFFD247, [(4,y+6),(54,y-8),(46,y+16)])
            }
        }.accessibilityHidden(true)
    }
}

struct LibraryTransferIcon: View {
    let importing: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Canvas { ctx, size in
                let body = CGRect(x: 2, y: 7, width: 33, height: 23)
                ctx.fill(Path(roundedRect: body, cornerRadius: 3), with: .color(Color(red: 0.41, green: 0.67, blue: 0.97)))
                for y in [23, 17, 11] {
                    ctx.fill(Path(ellipseIn: CGRect(x: 2, y: y, width: 33, height: 10)),
                             with: .color(Color(red: 0.41, green: 0.67 + Double(23 - y) / 180, blue: 0.97)))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: 2, y: 3, width: 33, height: 11)),
                         with: .color(Color(red: 0.64, green: 0.83, blue: 1)))
            }
            Image(systemName: importing ? "arrow.down" : "arrow.up").font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white).frame(width: 16, height: 16)
                .background(Color(red: 0.55, green: 0.77, blue: 0.99), in: Circle())
        }.frame(width: 43, height: 37).accessibilityHidden(true)
    }
}
