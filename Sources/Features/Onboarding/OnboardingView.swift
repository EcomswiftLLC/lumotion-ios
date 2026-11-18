import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var heroImage: UIImage?
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Scrolls when the screen is short (iPhone in landscape, large text), so the copy is never cut off
        // and "Get started" is always reachable.
        GeometryReader { geo in
            let wide = geo.size.width >= 700 && geo.size.width > geo.size.height
            ScrollView {
                Group {
                    if wide {
                        HStack(alignment: .center, spacing: LM.Space.xl) {
                            hero.frame(maxWidth: .infinity).frame(height: min(max(geo.size.height - 64, 220), 560))
                            copy.frame(maxWidth: 460)
                        }
                        .padding(.horizontal, LM.Space.xl)
                        .frame(minHeight: geo.size.height)
                    } else {
                        VStack(alignment: .leading, spacing: LM.Space.l) {
                            hero.frame(height: min(geo.size.height * 0.34, 320)).padding(.top, LM.Space.m)
                            copy
                        }
                        .padding(.horizontal, LM.Space.l)
                        .frame(minHeight: geo.size.height)
                        .readableWidth(560)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .apScreen()
        .opacity(appeared ? 1 : 0)
        .onAppear {
            if reduceMotion { appeared = true } else { withAnimation(.easeOut(duration: 0.9)) { appeared = true } }
        }
        .task {
            heroImage = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let first = Samples.refs().first else { return nil }
                return Samples.image(first, maxPixel: 1400).map { UIImage(cgImage: $0) }
            }.value
        }
    }

    private var hero: some View {
        HeroLoopView(image: heroImage, cornerRadius: 28)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome to Lumotion.")
                .apDisplay(42)
                .lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Turn a photo into a loop you can post. Nothing is uploaded.")
                .font(LM.Font.body)
                .foregroundStyle(LM.Palette.mist)
                .padding(.top, LM.Space.s)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                LMHairline()
                line("scribble.variable", "Paint the motion", "Brush a region, draw its direction, and it flows.")
                LMHairline()
                line("cloud.rain", "Add depth and weather", "Parallax, rain, snow, sparkles and more.")
                LMHairline()
                line("square.and.arrow.up", "Export and share", "Save a video or GIF, or send it straight to a friend.")
                LMHairline()
            }
            .padding(.top, LM.Space.l)
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { appState.hasOnboarded = true }
            } label: {
                Text("Get started")
            }
            .buttonStyle(.apPrimaryWide)
            .padding(.top, LM.Space.l)
            .padding(.bottom, LM.Space.l)
        }
    }

    private func line(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: LM.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(LM.Palette.glow)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(LM.Font.headline).foregroundStyle(LM.Palette.paper)
                Text(detail).font(LM.Font.callout).foregroundStyle(LM.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
