import Foundation

/// The seam between the screens and the project store written by the engine. Everything the UI needs from saved
/// projects goes through here, so the gallery and the editor never talk to storage directly.
@MainActor
enum ProjectBridge {
    /// Connects the gallery to the project store.
    static func attach(to gallery: ProjectGallery) {
        // Wired to ProjectStore once the engine API is available.
    }

    /// Loads a saved project for editing. Nil when it cannot be read.
    static func open(_ id: UUID) async -> EditorSource? {
        nil
    }
}
