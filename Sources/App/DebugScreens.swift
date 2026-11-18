#if DEBUG
import SwiftUI
import UIKit

/// Debug builds can open a given screen directly, with generated sample content, so CI can take screenshots of every
/// screen without tapping through the app: `xcrun simctl launch <device> com.ecomswift.lumotion -lmScreen home-filled`.
/// None of this exists in Release builds.
enum DebugScreens {
    static var requested: String? {
        guard let value = UserDefaults.standard.string(forKey: "lmScreen"), !value.isEmpty else { return nil }
        return value
    }

    @ViewBuilder
    static func view(for screen: String) -> some View {
        switch screen {
        case "onboarding":
            OnboardingView().environmentObject(AppState())
        case "home":
            HomeView()
        case "home-filled":
            HomeView(debugFilled: true)
        case "settings":
            SettingsView()
        case "editor":
            EditorView(source: .photo(DebugFixtures.photo(seed: 0)))
        case "export":
            DebugExportScreen()
        default:
            HomeView(debugFilled: true)
        }
    }
}

private struct DebugExportScreen: View {
    @StateObject private var coordinator: ExportCoordinator = {
        let coordinator = ExportCoordinator()
        coordinator.estimate = { choice in
            switch choice.format {
            case .gif: return "About 6.8 MB at \(choice.gifWidth) px wide."
            case .still: return "About 0.9 MB."
            default: return "About 4.2 MB."
            }
        }
        return coordinator
    }()

    var body: some View {
        ExportScreen(
            coordinator: coordinator,
            previewImage: DebugFixtures.gradient(seed: 0, size: CGSize(width: 900, height: 1100)),
            hasAudio: false
        )
    }
}

/// Generated pictures and projects for development screenshots only.
enum DebugFixtures {
    private static let skies: [[UInt32]] = [
        [0x1F2A44, 0xC76B5A, 0xF3C58A],
        [0x0F2B3D, 0x2F8F9D, 0xBDE7D8],
        [0x2B1B3D, 0xD9567A, 0xFFC38B],
        [0x1E3A2B, 0x6FA66B, 0xF4E9A8],
        [0x1A1F3A, 0x5663B8, 0xE6C9F2],
        [0x2A1E1E, 0xA85B3F, 0xF0D9A8],
    ]

    static func gradient(seed: Int, size: CGSize) -> UIImage {
        let colors = skies[abs(seed) % skies.count]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let skyColors = colors.map { UIColor(hex: $0).cgColor } as CFArray
            let sky = CGGradient(colorsSpace: space, colors: skyColors, locations: [0, 0.62, 1])!
            cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height * 0.75), options: [])
            let sunColors = [UIColor(hex: 0xFFF1CF).cgColor, UIColor(hex: 0xFFD18A, alpha: 0).cgColor] as CFArray
            let sun = CGGradient(colorsSpace: space, colors: sunColors, locations: [0, 1])!
            let centre = CGPoint(x: size.width * 0.62, y: size.height * 0.55)
            cg.drawRadialGradient(sun, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: size.width * 0.4, options: [])
            let ridges: [(UInt32, CGFloat, CGFloat)] = [(0x5B4A6B, 0.62, 0.07), (0x3A3552, 0.72, 0.09), (0x1D2233, 0.84, 0.10), (0x0F131C, 0.94, 0.05)]
            for (hex, base, amp) in ridges {
                cg.setFillColor(UIColor(hex: hex).cgColor)
                cg.beginPath()
                cg.move(to: CGPoint(x: 0, y: size.height))
                var x: CGFloat = 0
                while x <= size.width {
                    let wave = 0.5 + 0.5 * sin(x / (size.width * 0.13) + base * 9)
                    let y = size.height * base - size.height * amp * wave
                    cg.addLine(to: CGPoint(x: x, y: y))
                    x += 6
                }
                cg.addLine(to: CGPoint(x: size.width, y: size.height))
                cg.closePath()
                cg.fillPath()
            }
        }
    }

    static func photo(seed: Int) -> PhotoSource {
        let image = gradient(seed: seed, size: CGSize(width: 1600, height: 2000))
        return PhotoSource(image: image.cgImage!, data: image.jpegData(compressionQuality: 0.9) ?? Data(), name: "Debug photo")
    }

    static var samples: [SampleLibrary.Sample] {
        let titles = ["Golden hour", "Harbour", "Dusk", "Meadow", "Aurora", "Embers"]
        return titles.enumerated().map { index, title in
            SampleLibrary.Sample(id: "debug\(index)", title: title, url: URL(string: "debug://\(index)")!)
        }
    }

    @MainActor
    static func fill(_ gallery: ProjectGallery) {
        let titles = ["Harbour at dusk", "Mountain stream", "Rain on glass", "Lanterns", "Golden field", "Night market"]
        let days: [Double] = [0, 1, 2, 5, 9, 20]
        let durations: [Double] = [4, 6, 3, 8, 4, 5]
        var items: [ProjectSummary] = []
        for (index, title) in titles.enumerated() {
            items.append(ProjectSummary(
                id: UUID(),
                title: title,
                modified: Date().addingTimeInterval(-days[index] * 86_400),
                duration: durations[index],
                thumbnail: gradient(seed: index, size: CGSize(width: 320, height: 400))
            ))
        }
        gallery.setItems(items)
    }
}
#endif
