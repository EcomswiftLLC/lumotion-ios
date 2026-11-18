import Foundation
import UIKit

/// The seam between the screens and the project store written by the engine. Everything the gallery needs from saved
/// projects goes through here, so the Home screen never talks to storage directly.
@MainActor
enum ProjectBridge {
    /// Connects the gallery to the project store.
    static func attach(to gallery: ProjectGallery) {
        let store = ProjectStore.shared
        gallery.reloadHandler = {
            await Task.detached(priority: .userInitiated) { () -> [ProjectSummary] in
                store.listProjects().map { listing in
                    ProjectSummary(
                        id: listing.id,
                        title: listing.title,
                        modified: listing.modifiedAt,
                        duration: listing.duration,
                        thumbnail: listing.thumbnailURL.flatMap { UIImage(contentsOfFile: $0.path) }
                    )
                }
            }.value
        }
        gallery.renameHandler = { id, title in
            await Task.detached(priority: .userInitiated) { _ = try? store.rename(id: id, title: title) }.value
        }
        gallery.duplicateHandler = { id in
            await Task.detached(priority: .userInitiated) { _ = try? store.duplicate(id: id) }.value
        }
        gallery.deleteHandler = { id in
            await Task.detached(priority: .userInitiated) { _ = try? store.delete(id: id) }.value
        }
    }

    /// Opens a saved project for editing.
    static func open(_ id: UUID) async -> EditorSource? {
        .existing(id)
    }
}
