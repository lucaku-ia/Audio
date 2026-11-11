import SwiftUI

// MARK: - State

/// The top-card states of Home (screens spec 3.1, 3.2, 3.10 - 3.16).
enum HomeTopState: String, CaseIterable, Identifiable {
    case ready, playing, firstDay, notStarted, generating, onItsWay, late, caughtUp, noTopics

    var id: String { rawValue }

    /// Label for the DEBUG state switcher.
    var debugTitle: String {
        switch self {
        case .ready: return "3.1 Ready"
        case .playing: return "3.2 Playing"
        case .firstDay: return "3.10 First day"
        case .notStarted: return "3.11 Not started"
        case .generating: return "3.12 Generating"
        case .onItsWay: return "3.13 On its way"
        case .late: return "3.14 Running late"
        case .caughtUp: return "3.15 Caught up"
        case .noTopics: return "3.16 No topics"
        }
    }

    /// Whether the "Your Lucaku" card shows under the top card.
    var showsYourLucaku: Bool {
        switch self {
        case .ready, .playing, .firstDay, .notStarted, .generating, .onItsWay, .late: return true
        case .caughtUp, .noTopics: return false
        }
    }

    var isMaking: Bool {
        switch self {
        case .firstDay, .notStarted, .generating, .onItsWay, .late: return true
        default: return false
        }
    }
}

struct HomeTopActions {
    var onPlay: () -> Void = {}
    var onOpenPlayer: () -> Void = {}
    var onGenerate: () -> Void = {}
    var onCheckNow: () -> Void = {}
    var onSubmitRequest: () -> Void = {}
    var onAddTopic: () -> Void = {}
}

// MARK: - Buttons shared by the cards

/// Primary action inside a card: solid text colour on bg, 46 pt, radius 14.
private struct CardPrimaryButton: View {
    let title: String
    let icon: String?
    var fullWidth = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 15, weight: .bold)) }
                Text(title).font(.system(size: 16, weight: .bold)).lineLimit(1)
            }
            .foregroundStyle(LucakuColor.bg)
            .padding(.horizontal, 20)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LucakuColor.textPrimary))
        }
        .buttonStyle(.plain)
    }
}

private struct CardOutlineButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.system(size: 15))
            }
            .foregroundStyle(LucakuColor.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .overlay(Capsule().strokeBorder(LucakuColor.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func homeCard(padding: CGFloat = LucakuSpacing.sp4) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous).fill(LucakuColor.surface))
    }
}

// MARK: - Top card

struct HomeTopCard: View {
    let state: HomeTopState
    var headline: String = "Your daily briefing"
    var storyCount: Int = 0
    var durationS: Int?
    var topicsCount: Int = 0
    /// Profile delivery time as a clock string, e.g. "7:00 AM" (3.15 copy).
    var deliveryClock: String = "7:00 AM"
    /// Scheduled ready time, when the backend knows it.
    var eta: Date?
    /// Set while a generation started from this device is running.
    var generatingSince: Date?
    var playbackFraction: Double = 0
    var playbackStatus: String = ""
    var isPlayingNow = false
    var errorMessage: String?
    @Binding var requestText: String
    var isSubmitting = false
    var submitError: String?
    var actions = HomeTopActions()

    private var topicsPhrase: String { "\(topicsCount) topic\(topicsCount == 1 ? "" : "s")" }

    var body: some View {
        switch state {
        case .ready, .playing: episodeCard
        case .caughtUp: caughtUpCard
        case .noTopics: noTopicsCard
        default: makingCard
        }
    }

    // MARK: 3.1 / 3.2

    private var episodeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LucakuColor.episodeArt)
                    .frame(width: 112, height: 112)
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.34))
                    )
                VStack(alignment: .leading, spacing: 5) {
                    Text("Today's episode")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LucakuColor.textPrimary)
                    Text(headline)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(metaLine)
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            }
            if state == .playing {
                Button(action: actions.onOpenPlayer) {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(LucakuColor.borderSoft)
                                Capsule().fill(LucakuColor.textPrimary)
                                    .frame(width: proxy.size.width * min(1, max(0, playbackFraction)))
                            }
                        }
                        .frame(height: 3)
                        Text(playbackStatus)
                            .font(LucakuTypography.footnote)
                            .foregroundStyle(LucakuColor.textSecondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            CardPrimaryButton(
                title: state == .playing ? (isPlayingNow ? "Pause" : "Resume") : "Play",
                icon: state == .playing && isPlayingNow ? "pause.fill" : "play.fill",
                action: actions.onPlay
            )
        }
        .homeCard(padding: 12)
    }

    private var metaLine: String {
        var parts: [String] = []
        if storyCount > 0 { parts.append("\(storyCount) stor\(storyCount == 1 ? "y" : "ies")") }
        if let minutes = HomeFormat.minutes(durationS) { parts.append(minutes) }
        return parts.isEmpty ? HomeFormat.todayHeadline : parts.joined(separator: " · ")
    }

    // MARK: 3.10 - 3.14

    private var makingTitle: String {
        switch state {
        case .generating: return "Recording your episode…"
        case .late: return "Running a little long"
        case .notStarted: return "Ready when you are"
        default: return "Your episode is on its way"
        }
    }

    private var makingSubtitle: String {
        switch state {
        case .generating:
            return "Researching and voicing \(topicsPhrase), about a minute or two. Read your news below while you wait."
        case .late:
            return "It's taking a little longer than usual. Your news below is already up to date."
        case .notStarted:
            return "Lucaku researches \(topicsPhrase) and records them for you. Hear it now instead of waiting for tomorrow morning."
        default:
            if let eta { return "Ready around \(HomeFormat.shortTime(eta)). Your news below is already up to date." }
            return "Ready in a few minutes. Your news below is already up to date."
        }
    }

    private var showsSteps: Bool { state == .firstDay || state == .onItsWay }

    private var makingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(LucakuColor.iconTile).frame(width: 52, height: 52)
                    if state == .notStarted {
                        Image(systemName: "waveform")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(LucakuColor.icon)
                    } else {
                        ProgressView().tint(LucakuColor.icon)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(makingTitle)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .lineLimit(2)
                    Text(makingSubtitle)
                        .font(LucakuTypography.subhead)
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(2)
                }
            }

            if showsSteps { stepsView }
            if state == .generating { countdownView }
            if (state == .onItsWay || state == .notStarted), let eta { flowLine(eta: eta) }

            if state == .notStarted {
                CardPrimaryButton(title: "Generate my episode now", icon: "waveform", action: actions.onGenerate)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(LucakuTypography.caption1)
                    .foregroundStyle(LucakuColor.destructive)
            }
        }
        .homeCard()
    }

    /// Researching N topics -> Writing your script -> Recording your voice.
    private var stepsView: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let current = stepIndex(at: context.date)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(["Researching \(topicsPhrase)", "Writing your script", "Recording your voice"].enumerated()), id: \.offset) { index, text in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(index < current ? LucakuColor.textPrimary : Color.clear)
                                .overlay(Circle().strokeBorder(index < current ? Color.clear : (index == current ? LucakuColor.textPrimary : LucakuColor.border), lineWidth: index == current ? 2 : 1.5))
                            if index < current {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(LucakuColor.bg)
                            }
                        }
                        .frame(width: 22, height: 22)
                        Text(text)
                            .font(.system(size: 15, weight: index == current ? .bold : .medium))
                            .foregroundStyle(LucakuColor.textPrimary)
                    }
                    .opacity(index <= current ? 1 : 0.5)
                }
            }
            .padding(.leading, 4)
        }
    }

    private func stepIndex(at date: Date) -> Int {
        guard let eta else { return 0 }
        let left = max(0, eta.timeIntervalSince(date))
        let p = min(0.99, max(0, 1 - left / 120))
        return p < 0.45 ? 0 : (p < 0.8 ? 1 : 2)
    }

    /// Countdown once generation has started (about two minutes).
    private var countdownView: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = generatingSince.map { context.date.timeIntervalSince($0) } ?? 0
            let left = max(0, 120 - Int(elapsed))
            Text(left > 0 ? "About \(HomeFormat.clock(left)) left" : "Almost there…")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(LucakuColor.textPrimary)
        }
    }

    /// "Research starts at 13:30 and will be ready at 14:30" + Start now.
    private func flowLine(eta: Date) -> some View {
        let start = eta.addingTimeInterval(-3600)
        let started = Date() >= start
        return HStack(alignment: .center, spacing: 8) {
            Text(started
                 ? "Research started at \(HomeFormat.shortTime(start)) and will be ready at \(HomeFormat.shortTime(eta))."
                 : "Research starts at \(HomeFormat.shortTime(start)) and will be ready at \(HomeFormat.shortTime(eta)).")
                .font(LucakuTypography.footnote)
                .foregroundStyle(LucakuColor.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if state == .onItsWay {
                Button(action: actions.onGenerate) {
                    Text("Start now")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 3.15

    private var caughtUpCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're caught up.")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(LucakuColor.textPrimary)
            Text("Nothing new for your episode today. Your next one arrives tomorrow at \(deliveryClock). Your news below is still fresh.")
                .font(LucakuTypography.subhead)
                .foregroundStyle(LucakuColor.textSecondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                CardOutlineButton(title: "Check now", icon: "arrow.triangle.2.circlepath", action: actions.onCheckNow)
                if generatingSince == nil {
                    CardOutlineButton(title: "Generate one now", icon: "waveform", action: actions.onGenerate)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Recording, about a minute or two.")
                            .font(LucakuTypography.footnote)
                            .foregroundStyle(LucakuColor.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            Divider().overlay(LucakuColor.borderSoft).padding(.vertical, 4)
            Text("Request something for today")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LucakuColor.textPrimary)
            requestField(placeholder: "What do you want to know about today?")
            CardPrimaryButton(title: isSubmitting ? "Sending…" : "Request for today", icon: nil, action: actions.onSubmitRequest)
                .opacity(canSubmit ? 1 : 0.4)
                .disabled(!canSubmit)
            if let submitError { Text(submitError).font(LucakuTypography.caption1).foregroundStyle(LucakuColor.destructive) }
            if let errorMessage { Text(errorMessage).font(LucakuTypography.caption1).foregroundStyle(LucakuColor.destructive) }
        }
        .homeCard()
    }

    // MARK: 3.16

    private var noTopicsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nothing lined up yet")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(LucakuColor.textPrimary)
            Text("Add a topic or question and Lucaku will research it for your next episode, and start your news feed.")
                .font(LucakuTypography.subhead)
                .foregroundStyle(LucakuColor.textSecondary)
                .lineLimit(3)
            requestField(placeholder: "What should Lucaku follow?")
            CardPrimaryButton(title: isSubmitting ? "Adding…" : "Add request", icon: "plus", action: actions.onAddTopic)
                .opacity(canSubmit ? 1 : 0.4)
                .disabled(!canSubmit)
            if let submitError { Text(submitError).font(LucakuTypography.caption1).foregroundStyle(LucakuColor.destructive) }
        }
        .homeCard()
    }

    private var canSubmit: Bool {
        !isSubmitting && !requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func requestField(placeholder: String) -> some View {
        TextField(placeholder, text: $requestText, axis: .vertical)
            .lineLimit(2...2)
            .font(.system(size: 17))
            .foregroundStyle(LucakuColor.textPrimary)
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(LucakuColor.border, lineWidth: 1))
            .accessibilityLabel(placeholder)
    }
}

// MARK: - Your Lucaku card

/// "Your Lucaku": the next episode line plus the topics you follow, with Edit
/// (goes to the Interests tab) and +.
struct YourLucakuCard: View {
    let nextLabel: String
    let nextWhen: String
    let topics: [String]
    var onEdit: () -> Void
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LucakuColor.icon)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LucakuColor.iconTile))
                VStack(alignment: .leading, spacing: 1) {
                    Text(nextLabel)
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                    Text(nextWhen)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Divider().overlay(LucakuColor.borderSoft)
            HStack {
                Text("Following \(topics.count) topic\(topics.count == 1 ? "" : "s")")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LucakuColor.textPrimary)
                Spacer(minLength: 0)
                Button(action: onEdit) {
                    Text("Edit")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .frame(minWidth: 44, minHeight: 36)
                }
                .buttonStyle(.plain)
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(LucakuColor.fill))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a topic")
            }
            FlowLayout(spacing: 6) {
                ForEach(topics, id: \.self) { topic in
                    HStack(spacing: 5) {
                        Image(systemName: NewsCategory.infer(from: topic)?.symbol ?? "bookmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LucakuColor.icon)
                        Text(topic)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LucakuColor.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(LucakuColor.fill))
                }
            }
        }
        .homeCard()
    }
}
