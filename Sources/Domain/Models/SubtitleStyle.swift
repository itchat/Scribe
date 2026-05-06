import Foundation

/// Where the subtitle text sits on screen and how its border is drawn.
/// Numbers map to libass conventions (`force_style=Alignment=N`,
/// `BorderStyle=N`) so callers can emit ASS strings without re-translating.
public enum SubtitleAlignment: String, Codable, Sendable, CaseIterable {
    case bottomCenter
    case middleCenter
    case topCenter

    /// libass numpad alignment code (1-9).
    public var assCode: Int {
        switch self {
        case .bottomCenter: return 2
        case .middleCenter: return 5
        case .topCenter:    return 8
        }
    }
}

public enum SubtitleBorderStyle: String, Codable, Sendable, CaseIterable {
    /// Just an outline + drop shadow around glyphs (BorderStyle=1).
    case outline
    /// Opaque box behind the text (BorderStyle=4) — most readable on
    /// busy backgrounds.
    case opaqueBox

    public var assCode: Int {
        switch self {
        case .outline:   return 1
        case .opaqueBox: return 4
        }
    }
}

/// How burned subtitles look on the output video.
///
/// SRP: this is just a value type — every field is stored; nothing is
/// auto-computed against the input video. The earlier preset / resolver
/// layer was removed because the user-tuned numbers (14pt etc.) work
/// well across resolutions once libass is told the real canvas size via
/// ffmpeg's `original_size=WxH`.
///
/// Colours are stored as ARGB; the alpha byte is currently treated as
/// fully opaque on emission (libass uses the bottom 24 bits for `&Hxxxxxx`).
public struct SubtitleStyle: Codable, Sendable, Equatable {

    /// macOS-bundled serif used as default. New York is Apple's house
    /// serif (ships with macOS 11+ at /System/Library/Fonts/NewYork.ttf),
    /// pairs well with SF Pro, and reads cleanly at small burn-in sizes.
    public static let defaultFontName = "New York"

    public var fontName: String
    public var fontSize: Int
    public var primaryColorARGB: UInt32
    public var outlineColorARGB: UInt32
    public var borderStyle: SubtitleBorderStyle
    public var alignment: SubtitleAlignment
    /// Distance from the top/bottom edge in pixels (libass MarginV).
    public var marginVertical: Int
    /// Distance from the left and right edges in pixels (libass MarginL /
    /// MarginR). Drives where libass starts wrapping long lines — set
    /// generously (~5% of width) so portrait phone clips and tight 720p
    /// content don't overflow.
    public var marginHorizontal: Int

    public init(
        fontName: String = SubtitleStyle.defaultFontName,
        fontSize: Int = 14,
        primaryColorARGB: UInt32 = 0xFFFFFFFF,
        outlineColorARGB: UInt32 = 0xFF000000,
        borderStyle: SubtitleBorderStyle = .opaqueBox,
        alignment: SubtitleAlignment = .bottomCenter,
        marginVertical: Int = 16,
        marginHorizontal: Int = 40
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.primaryColorARGB = primaryColorARGB
        self.outlineColorARGB = outlineColorARGB
        self.borderStyle = borderStyle
        self.alignment = alignment
        self.marginVertical = marginVertical
        self.marginHorizontal = marginHorizontal
    }

    /// Forgiving decoder: any missing field falls back to its default.
    /// This is what lets older configs — which stored an enum-shaped
    /// `{"preset": "recommended"}` payload — load without throwing.
    /// They simply land on a default `SubtitleStyle` after the upgrade.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SubtitleStyle()
        self.fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? fallback.fontName
        self.fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? fallback.fontSize
        self.primaryColorARGB = try c.decodeIfPresent(UInt32.self, forKey: .primaryColorARGB) ?? fallback.primaryColorARGB
        self.outlineColorARGB = try c.decodeIfPresent(UInt32.self, forKey: .outlineColorARGB) ?? fallback.outlineColorARGB
        self.borderStyle = try c.decodeIfPresent(SubtitleBorderStyle.self, forKey: .borderStyle) ?? fallback.borderStyle
        self.alignment = try c.decodeIfPresent(SubtitleAlignment.self, forKey: .alignment) ?? fallback.alignment
        self.marginVertical = try c.decodeIfPresent(Int.self, forKey: .marginVertical) ?? fallback.marginVertical
        self.marginHorizontal = try c.decodeIfPresent(Int.self, forKey: .marginHorizontal) ?? fallback.marginHorizontal
    }

    enum CodingKeys: String, CodingKey {
        case fontName, fontSize
        case primaryColorARGB, outlineColorARGB
        case borderStyle, alignment
        case marginVertical, marginHorizontal
    }

    /// Emit the comma-separated `force_style=...` payload that ffmpeg's
    /// `subtitles` filter accepts. Caller wraps it with the surrounding
    /// `subtitles='path':force_style='...'` shell-safe quoting.
    public func assForceStyle() -> String {
        let primaryHex = String(format: "&H%06X", primaryColorARGB & 0x00FFFFFF)
        let outlineHex = String(format: "&H%06X", outlineColorARGB & 0x00FFFFFF)
        return [
            "FontName=\(fontName)",
            "FontSize=\(fontSize)",
            "PrimaryColour=\(primaryHex)",
            "OutlineColour=\(outlineHex)",
            "BorderStyle=\(borderStyle.assCode)",
            "Alignment=\(alignment.assCode)",
            "MarginV=\(marginVertical)",
            "MarginL=\(marginHorizontal)",
            "MarginR=\(marginHorizontal)",
        ].joined(separator: ",")
    }
}
