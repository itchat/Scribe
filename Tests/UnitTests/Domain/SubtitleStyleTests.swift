import Testing
import Foundation
@testable import Domain

@Suite("SubtitleStyle")
struct SubtitleStyleTests {

    // MARK: - Defaults

    @Test("Default style is New York 14pt, bottom-centred, black box, white text")
    func defaults() {
        let s = SubtitleStyle()
        #expect(s.fontName == "New York")
        #expect(s.fontSize == 14)
        #expect(s.primaryColorARGB == 0xFFFFFFFF)
        #expect(s.outlineColorARGB == 0xFF000000)
        #expect(s.borderStyle == .opaqueBox)
        #expect(s.alignment == .bottomCenter)
        #expect(s.marginVertical == 16)
        #expect(s.marginHorizontal == 40)
    }

    @Test("defaultFontName constant is New York")
    func defaultFontConstant() {
        #expect(SubtitleStyle.defaultFontName == "New York")
    }

    // MARK: - Codable

    @Test("Round-trips through JSON")
    func codableRoundTrip() throws {
        let original = SubtitleStyle(
            fontName: "Helvetica Neue",
            fontSize: 24,
            primaryColorARGB: 0xFFFFFFFF,
            outlineColorARGB: 0xFFFFFFFF,
            borderStyle: .outline,
            alignment: .topCenter,
            marginVertical: 30,
            marginHorizontal: 60
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SubtitleStyle.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoder fills in defaults for missing fields (graceful upgrade from older configs)")
    func decoderUsesDefaults() throws {
        // Empty JSON object → default style.
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SubtitleStyle.self, from: json)
        #expect(decoded == SubtitleStyle())
    }

    @Test("Legacy preset-shaped JSON falls back to defaults instead of crashing")
    func legacyPresetJSONDoesntCrash() throws {
        // Older builds stored {"preset": "recommended"} — the new flat
        // struct can't read it but must degrade to default values
        // rather than throwing the whole AppConfig decode.
        let legacy = #"{"preset": "recommended"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SubtitleStyle.self, from: legacy)
        #expect(decoded == SubtitleStyle())
    }

    // MARK: - ASS force_style emission

    @Test("assForceStyle includes every libass key the burn step needs")
    func assForceStyleAllKeys() {
        let s = SubtitleStyle(
            fontName: "New York",
            fontSize: 14,
            primaryColorARGB: 0xFFFFFFFF,
            outlineColorARGB: 0xFF000000,
            borderStyle: .opaqueBox,
            alignment: .bottomCenter,
            marginVertical: 16,
            marginHorizontal: 40
        )
        let payload = s.assForceStyle()
        #expect(payload.contains("FontName=New York"))
        #expect(payload.contains("FontSize=14"))
        #expect(payload.contains("PrimaryColour=&HFFFFFF"))
        #expect(payload.contains("OutlineColour=&H000000"))
        #expect(payload.contains("BorderStyle=4"))
        #expect(payload.contains("Alignment=2"))
        #expect(payload.contains("MarginV=16"))
        #expect(payload.contains("MarginL=40"))
        #expect(payload.contains("MarginR=40"))
    }

    @Test("BorderStyle outline emits libass code 1")
    func borderStyleOutlineCode() {
        var s = SubtitleStyle()
        s.borderStyle = .outline
        #expect(s.assForceStyle().contains("BorderStyle=1"))
    }

    @Test("Alignment topCenter emits libass numpad code 8")
    func alignmentTopCenterCode() {
        var s = SubtitleStyle()
        s.alignment = .topCenter
        #expect(s.assForceStyle().contains("Alignment=8"))
    }

    @Test("White-box configuration emits white outline + black text")
    func whiteBoxColors() {
        let s = SubtitleStyle(
            fontName: "New York",
            fontSize: 14,
            primaryColorARGB: 0xFF000000,   // black text
            outlineColorARGB: 0xFFFFFFFF,   // white box
            borderStyle: .opaqueBox,
            alignment: .bottomCenter,
            marginVertical: 16,
            marginHorizontal: 40
        )
        let payload = s.assForceStyle()
        #expect(payload.contains("PrimaryColour=&H000000"))
        #expect(payload.contains("OutlineColour=&HFFFFFF"))
        #expect(payload.contains("BorderStyle=4"))
    }
}
