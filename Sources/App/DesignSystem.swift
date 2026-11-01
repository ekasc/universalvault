import AppKit
import SwiftUI

/// The product's visual language. Near-monochrome planes, hairlines instead of
/// boxes, tracked micro-labels, monospaced values, and serif for record titles.
/// System accent still drives selection so the app follows the Mac's highlight
/// colour.
enum Theme {
  static let canvas = color(light: 0xFFFFFF, dark: 0x0B0B0C)
  static let plane = color(light: 0xFAFAFA, dark: 0x0E0E10)
  static let well = color(light: 0xF2F2F3, dark: 0x16161A)
  static let primary = color(light: 0x0A0A0A, dark: 0xEDEDEF)
  static let secondary = color(light: 0x5F5F66, dark: 0xA0A0A8)
  static let tertiary = color(light: 0x70707A, dark: 0x8A8A94)

  static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.isDark
      ? NSColor.white.withAlphaComponent(0.10)
      : NSColor.black.withAlphaComponent(0.09)
  })

  static let hover = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.isDark
      ? NSColor.white.withAlphaComponent(0.055)
      : NSColor.black.withAlphaComponent(0.035)
  })

  /// Row selection: the Mac's highlight colour held back to a tint. The row text
  /// keeps full ink contrast, and the palette does not spend its loudest value
  /// on which row a keystroke would insert.
  static let selection = Color(nsColor: NSColor(name: nil) { appearance in
    NSColor.controlAccentColor.withAlphaComponent(appearance.isDark ? 0.30 : 0.16)
  })

  private static func color(light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      appearance.isDark ? nsColor(dark) : nsColor(light)
    })
  }

  private static func nsColor(_ hex: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1)
  }
}

private extension NSAppearance {
  var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

enum Typography {
  /// Serif is reserved for record titles and empty-state headings. Everything
  /// else stays in the system sans so controls still feel native.
  static let recordTitle = Font.system(size: 25, weight: .semibold, design: .serif)
  static let emptyTitle = Font.system(size: 18, weight: .medium, design: .serif)
  static let body = Font.system(size: 13)
  static let rowTitle = Font.system(size: 13, weight: .medium)
  static let value = Font.system(size: 12.5, design: .monospaced)
  static let meta = Font.system(size: 11, weight: .medium)
  static let micro = Font.system(size: 10.5, weight: .semibold)
  static let monoMicro = Font.system(size: 10.5, design: .monospaced)
  static let keycap = Font.system(size: 10, weight: .medium, design: .monospaced)
}

enum Metrics {
  static let contentPadding: CGFloat = 26
  static let labelColumn: CGFloat = 158
  static let rowVerticalPadding: CGFloat = 9
  static let radius: CGFloat = 7
  static let sectionGap: CGFloat = 22
}

/// Shared with the Quick Fill panel controller and the native verification
/// harness so its window is sized from the same numbers the rows are laid out
/// with. Every value here is load-bearing: the panel is a command surface that
/// must show whole rows and nothing else.
/// The palette is the one surface a person cannot zoom, so it follows the system
/// text size instead of pinning points. AppKit exposes that through the preferred
/// body font; `systemFontSize` is the standard body size the layout was drawn at.
enum PaletteScale {
  static var factor: CGFloat {
    let standard = NSFont.systemFontSize
    guard standard > 0 else { return 1 }
    let preferred = NSFont.preferredFont(forTextStyle: .body).pointSize
    return min(max(preferred / standard, 1), 1.6)
  }

  static func size(_ base: CGFloat) -> CGFloat { base * factor }
  static func length(_ base: CGFloat) -> CGFloat { (base * factor).rounded() }
}

enum PaletteMetrics {
  static let width: CGFloat = 600
  static let minWidth: CGFloat = 520
  static let radius: CGFloat = 16
  /// Leading and trailing inset for the search row and footer; rows add
  /// `rowInset` so their selection pill sits inboard of the surface edge.
  static let sidePadding: CGFloat = 18
  static let searchHeight: CGFloat = 54
  static let rowHeight: CGFloat = 44
  static let rowSpacing: CGFloat = 2
  static let rowInset: CGFloat = 6
  static let listPadding: CGFloat = 6
  static let footerHeight: CGFloat = 56
  static let emptyHeight: CGFloat = 148
  static let maxRows: Int = 7

  /// Height of the whole surface. The rule count is two hairlines: under the
  /// search row and above the footer.
  static func height(fieldCount: Int, empty: Bool) -> CGFloat {
    let rules: CGFloat = 2
    guard !empty else {
      return PaletteScale.length(searchHeight + emptyHeight + footerHeight) + rules
    }
    let rows = CGFloat(min(max(fieldCount, 1), maxRows))
    let list = rows * rowHeight + max(rows - 1, 0) * rowSpacing + listPadding * 2
    return PaletteScale.length(searchHeight + list + footerHeight) + rules
  }
}

/// A 1px rule. `Divider` inherits system separators, which are heavier and tint
/// with the accent in some states; the identity needs a neutral hairline.
struct Hairline: View {
  var body: some View {
    Rectangle()
      .fill(Theme.hairline)
      .frame(height: 1)
      .accessibilityHidden(true)
  }
}

/// Small uppercase section label with open tracking.
struct MicroLabel: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text.uppercased())
      .font(Typography.micro)
      .tracking(0.7)
      .foregroundStyle(Theme.secondary)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
  }
}

/// A keypress hint, drawn as a small key rather than an icon.
struct Keycap: View {
  let text: String

  var body: some View {
    Text(text)
      .font(Typography.keycap)
      .foregroundStyle(Theme.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(Theme.well, in: RoundedRectangle(cornerRadius: 4))
      .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
  }
}

/// The item icon's plate: a bordered square so the glyph reads as a record
/// marker rather than a stray symbol.
struct IconPlate: View {
  let symbol: String
  var size: CGFloat = 28

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.5, weight: .regular))
      .foregroundStyle(Theme.secondary)
      .frame(width: size, height: size)
      .background(Theme.well, in: RoundedRectangle(cornerRadius: Metrics.radius))
      .overlay(
        RoundedRectangle(cornerRadius: Metrics.radius).strokeBorder(Theme.hairline))
      .accessibilityHidden(true)
  }
}

/// Flat text input: hairline border over a subtle well instead of a system
/// bezel. Used where the value itself is the content, not a form field.
struct WellFieldStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .font(Typography.value)
      .foregroundStyle(Theme.primary)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(Theme.well, in: RoundedRectangle(cornerRadius: 5))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline))
  }
}

extension View {
  func wellField() -> some View { modifier(WellFieldStyle()) }
}

/// Primary action. Uses the ink/plane pair rather than the system accent, so a
/// monochrome window keeps one loud element: the action itself.
struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12.5, weight: .medium))
      .foregroundStyle(Theme.canvas)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .background(
        Theme.primary.opacity(configuration.isPressed ? 0.82 : 1),
        in: RoundedRectangle(cornerRadius: Metrics.radius))
      .contentShape(Rectangle())
  }
}

