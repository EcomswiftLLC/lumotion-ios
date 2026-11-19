import SwiftUI
import UIKit

/// What the gallery needs to show about one saved project.
struct ProjectSummary: Identifiable {
    let id: UUID
    var title: String
    var modified: Date
    /// Loop length in seconds.
    var duration: Double
    var thumbnail: UIImage?
}

/// The list of saved projects on Home. The store behind it is attached in `ProjectGallery.attach` (see ProjectBridge).
@MainActor
final class ProjectGallery: ObservableObject {
    @Published private(set) var items: [ProjectSummary] = []
    @Published private(set) var loaded = false

    /// Called by the bridge to the project store.
    var reloadHandler: (() async -> [ProjectSummary])?
    var renameHandler: ((UUID, String) async -> Void)?
    var duplicateHandler: ((UUID) async -> Void)?
    var deleteHandler: ((UUID) async -> Void)?

    func reload() async {
        if let reloadHandler {
            items = await reloadHandler()
        }
        loaded = true
    }

    func rename(_ id: UUID, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await renameHandler?(id, trimmed)
        await reload()
    }

    func duplicate(_ id: UUID) async {
        await duplicateHandler?(id)
        await reload()
    }

    func delete(_ id: UUID) async {
        await deleteHandler?(id)
        await reload()
    }

    /// Used by debug screens to show a gallery with content.
    func setItems(_ summaries: [ProjectSummary]) {
        items = summaries
        loaded = true
    }
}

struct ProjectCard: View {
    let project: ProjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .overlay {
                    if let image = project.thumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ApertureMark(lineWidth: 1, color: LM.Palette.mist.opacity(0.6))
                            .frame(width: 36, height: 36)
                    }
                }
                .background(LM.Palette.graphite)
                .clipped()
            .clipShape(RoundedRectangle(cornerRadius: LM.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LM.Radius.control, style: .continuous).strokeBorder(LM.Palette.line, lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                Text(LMFormat.seconds(project.duration))
                    .font(LM.Font.caption.monospacedDigit())
                    .foregroundStyle(LM.Palette.paper)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(LM.Font.label)
                    .foregroundStyle(LM.Palette.paper)
                    .lineLimit(1)
                Text("Edited \(project.modified.formatted(.relative(presentation: .named)))")
                    .font(LM.Font.caption)
                    .foregroundStyle(LM.Palette.mist)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
