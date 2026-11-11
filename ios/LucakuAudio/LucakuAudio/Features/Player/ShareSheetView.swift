import SwiftUI
import UIKit

// MARK: - Share link (backend stub)

/// A story share link. TODO(backend): there is no share API yet (and no
/// recipient landing page — see the spec's open question 3). Until one
/// exists the slug is derived locally from the story title and the link is
/// not guaranteed to resolve. Replace `make(...)` with a call that creates the
/// share server-side and returns the real slug.
struct StoryShareLink {
    let slug: String

    var display: String { "lucaku.app/s/\(slug)" }
    var url: URL { URL(string: "https://\(display)")! }

    static func make(storyTitle: String) -> StoryShareLink {
        let parts = storyTitle.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(4)
        let slug = parts.joined(separator: "-")
        return StoryShareLink(slug: slug.isEmpty ? "story" : slug)
    }
}

// MARK: - Sheet

/// "Share a story" (4.8) and its confirmation (4.9).
///
/// Shows a preview of exactly what the friend receives: an editable message
/// plus a link card. Then neutral app circles (no brand logos). No sign-up
/// warning here; the landing page handles that.
struct ShareSheetView: View {
    let storyTitle: String
    let listenLength: String
    let firstName: String
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case compose
        case sent(String)
    }

    private enum Destination: String, CaseIterable {
        case messages = "Messages"
        case whatsApp = "WhatsApp"
        case mail = "Mail"
        case copyLink = "Copy link"
        case more = "More"

        var symbol: String {
            switch self {
            case .messages: return "message"
            case .whatsApp: return "bubble.left.and.bubble.right"
            case .mail: return "envelope"
            case .copyLink: return "link"
            case .more: return "ellipsis"
            }
        }
    }

    @State private var phase: Phase = .compose
    @State private var message = ""
    @State private var activity: ActivityPayload?

    private var link: StoryShareLink { .make(storyTitle: storyTitle) }

    private var defaultMessage: String {
        "\(firstName.isEmpty ? "A friend" : firstName) thinks you'll like this story on Lucaku:"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                switch phase {
                case .compose: compose
                case .sent(let title): sent(title)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(LucakuColor.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
        .onAppear { if message.isEmpty { message = defaultMessage } }
        .sheet(item: $activity) { payload in
            ActivitySheet(items: payload.items) { completed in
                activity = nil
                if completed { phase = .sent("Sent") }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Share this story")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(LucakuColor.textPrimary)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(LucakuColor.fill))
            }
            .accessibilityLabel("Close")
        }
    }

    // MARK: 4.8 compose

    private var compose: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("What they'll get")

            VStack(spacing: 0) {
                TextField("Message", text: $message, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(1...3)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)

                linkCard
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .background(LucakuColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            sectionLabel("Send with").padding(.top, 2)

            // TODO(backend): a contacts row ("Send to") needs Contacts access and
            // a share endpoint; for now the system apps below carry the message.
            HStack(alignment: .top, spacing: 10) {
                ForEach(Destination.allCases, id: \.self) { destination in
                    Button { send(via: destination) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: destination.symbol)
                                .font(.system(size: 21))
                                .foregroundStyle(LucakuColor.textPrimary)
                                .frame(width: 52, height: 52)
                                .background(Circle().fill(LucakuColor.surface))
                                .overlay(Circle().stroke(LucakuColor.borderSoft, lineWidth: 1))
                            Text(destination.rawValue)
                                .font(.system(size: 12))
                                .foregroundStyle(LucakuColor.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                PlayerArt(seed: storyTitle, cornerRadius: 0)
                VStack {
                    HStack {
                        Spacer()
                        Text("lucaku.")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Spacer()
                    HStack {
                        Label("\(listenLength) listen", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.black.opacity(0.5)))
                        Spacer()
                    }
                }
                .padding(10)
            }
            .frame(height: 150)

            VStack(alignment: .leading, spacing: 3) {
                Text(storyTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
                Text("Free to listen on Lucaku. Your daily news, researched for you and read in a few minutes.")
                    .font(.system(size: 13))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(2)
                Text(link.display)
                    .font(.system(size: 12))
                    .foregroundStyle(LucakuColor.textTertiary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LucakuColor.fill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: 4.9 / 4.11 sent

    private func sent(_ title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(LucakuColor.icon)
                .frame(width: 64, height: 64)
                .background(Circle().fill(LucakuColor.iconTile))
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(LucakuColor.textPrimary)
            Text("They'll get the story with a link to listen on Lucaku.")
                .font(.system(size: 14))
                .foregroundStyle(LucakuColor.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 300)
            Button { dismiss() } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LucakuColor.bg)
                    .frame(minWidth: 160, minHeight: 46)
                    .background(Capsule().fill(LucakuColor.textPrimary))
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    // MARK: Actions

    private var fullText: String { "\(message) \(link.url.absoluteString)" }

    private func send(via destination: Destination) {
        switch destination {
        case .copyLink:
            UIPasteboard.general.string = link.url.absoluteString
            phase = .sent("Link copied")
        case .more:
            activity = ActivityPayload(items: [fullText])
        case .messages, .whatsApp, .mail:
            let encoded = fullText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fullText
            let target: String
            switch destination {
            case .messages: target = "sms:&body=\(encoded)"
            case .whatsApp: target = "whatsapp://send?text=\(encoded)"
            default: target = "mailto:?subject=\(storyTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&body=\(encoded)"
            }
            guard let url = URL(string: target) else { return }
            UIApplication.shared.open(url) { opened in
                DispatchQueue.main.async {
                    if opened {
                        phase = .sent("Sent to \(destination.rawValue)")
                    } else {
                        // App not available: fall back to the system share sheet.
                        activity = ActivityPayload(items: [fullText])
                    }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.3)
            .textCase(.uppercase)
            .foregroundStyle(LucakuColor.textSecondary)
    }
}

// MARK: - System share sheet bridge

private struct ActivityPayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onFinish(completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
