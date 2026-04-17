import Foundation
import os
import Domain
import Protocols

/// Decorator that tries a primary translator, falling back to a secondary on failure.
///
/// OCP fix: Only catches `ScribeError` (not bare `Error`) to avoid swallowing
/// unexpected failures. The Python version caught bare `Exception`.
public final class FallbackTranslator: SubtitleTranslating, @unchecked Sendable {

    private let primary: any SubtitleTranslating
    private let fallback: any SubtitleTranslating
    private let logger = Logger(subsystem: "com.scribe", category: "translation.fallback")

    public var name: String {
        "\(primary.name) (with \(fallback.name) fallback)"
    }

    public var isAvailable: Bool {
        primary.isAvailable || fallback.isAvailable
    }

    public init(primary: any SubtitleTranslating, fallback: any SubtitleTranslating) {
        self.primary = primary
        self.fallback = fallback
    }

    public func translate(entries: [SubtitleEntry]) async throws -> [SubtitleEntry] {
        do {
            return try await primary.translate(entries: entries)
        } catch let primaryError as ScribeError {
            logger.warning("Primary translator failed: \(primaryError.localizedDescription, privacy: .public)")

            guard fallback.isAvailable else { throw primaryError }

            do {
                return try await fallback.translate(entries: entries)
            } catch {
                logger.error("Fallback translator also failed: \(error.localizedDescription, privacy: .public)")
                // Return original entries unchanged
                return entries
            }
        }
    }
}
