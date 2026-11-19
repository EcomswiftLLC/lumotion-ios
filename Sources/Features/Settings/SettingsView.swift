import SwiftUI
import StoreKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @ObservedObject private var ads = AdsManager.shared

    private let privacyURL = URL(string: "https://ecomswiftllc.github.io/lumotion/privacy/")!
    private let supportURL = URL(string: "https://ecomswiftllc.github.io/lumotion/support/")!
    private let mailURL = URL(string: "mailto:support@ecomswiftllc.com")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LM.Space.l) {
                    LMHeader(title: "Settings", subtitle: "Lumotion is free. Your photos and videos never leave your device.")

                    section("Privacy") {
                        if ads.privacyOptionsRequired {
                            row("Ad privacy choices", symbol: "hand.raised") { ads.presentPrivacyOptions() }
                            LMHairline()
                        }
                        link("Privacy policy", symbol: "lock", url: privacyURL)
                    }

                    section("Help") {
                        link("Support", symbol: "questionmark.circle", url: supportURL)
                        LMHairline()
                        link("Email us", symbol: "envelope", url: mailURL)
                        LMHairline()
                        row("Rate Lumotion", symbol: "star") { requestReview() }
                    }

                    if !credits.isEmpty {
                        section("Sample credits") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("The sample photos and clips in Lumotion come from these creators.")
                                    .font(LM.Font.caption)
                                    .foregroundStyle(LM.Palette.mist)
                                ForEach(credits, id: \.self) { line in
                                    Text(line)
                                        .font(LM.Font.caption)
                                        .foregroundStyle(LM.Palette.paper)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, LM.Space.s)
                            .accessibilityElement(children: .combine)
                        }
                    }

                    section("About") {
                        LMRow(title: "Version", symbol: "info.circle", value: version, showsChevron: false)
                            .accessibilityElement(children: .combine)
                        LMHairline()
                        Text("Photos, videos and projects are processed and stored on this device. Ads are shown on the Home screen and before you save or share an export.")
                            .font(LM.Font.caption)
                            .foregroundStyle(LM.Palette.mist)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, LM.Space.s)
                    }
                }
                .padding(.horizontal, LM.Space.m)
                .padding(.bottom, LM.Space.xl)
                .readableWidth()
            }
            .apScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(LM.Palette.glow)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var credits: [String] { SampleCatalog.credits() }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LM.Space.s) {
            LMSectionTitle(text: title)
            VStack(spacing: 0) {
                LMHairline()
                content()
                LMHairline()
            }
        }
    }

    private func row(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { LMRow(title: title, symbol: symbol) }
            .buttonStyle(.plain)
    }

    private func link(_ title: String, symbol: String, url: URL) -> some View {
        Link(destination: url) { LMRow(title: title, symbol: symbol) }
    }
}
