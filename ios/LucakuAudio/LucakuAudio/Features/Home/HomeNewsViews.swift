import SwiftUI

// MARK: - Your news (3.3 - 3.5, 3.7)

/// "Your news": header, then one collapsible card per day (newest day first).
struct NewsSectionView: View {
    @ObservedObject var store: NewsStore
    var onOpen: (NewsStory) -> Void

    var body: some View {
        if !store.feed.isEmpty {
            VStack(alignment: .leading, spacing: LucakuSpacing.sp6) {
                header
                ForEach(store.groups) { group in
                    NewsDayCard(group: group, store: store, onOpen: onOpen)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: LucakuSpacing.sp3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your news")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(LucakuColor.textPrimary)
                Text(subtitle)
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.unreadCount > 0 {
                Button {
                    withAnimation(LucakuMotion.house) { store.markAllRead() }
                } label: {
                    Text("Mark all read")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var subtitle: String {
        let lead = store.unreadCount > 0 ? "\(store.unreadCount) unread" : "All caught up"
        return "\(lead) · newest day first · swipe left to mark read or unread"
    }
}

private struct NewsDayCard: View {
    let group: NewsDayGroup
    @ObservedObject var store: NewsStore
    var onOpen: (NewsStory) -> Void

    private var isOpen: Bool { !store.collapsedDays.contains(group.dayOffset) }
    private var isExpanded: Bool { store.expandedDays.contains(group.dayOffset) }
    private var visible: [NewsStory] {
        isExpanded ? group.stories : Array(group.stories.prefix(NewsStore.storiesPerDay))
    }
    private var hiddenCount: Int { max(0, group.stories.count - NewsStore.storiesPerDay) }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            if isOpen {
                ForEach(visible) { story in
                    Divider().overlay(LucakuColor.borderSoft)
                    NewsRowView(
                        story: story,
                        isRead: store.isRead(story),
                        onOpen: { onOpen(story) },
                        onToggleRead: { withAnimation(LucakuMotion.house) { store.toggleRead(story) } }
                    )
                }
                if hiddenCount > 0 {
                    Divider().overlay(LucakuColor.borderSoft)
                    Button {
                        withAnimation(LucakuMotion.house) { store.toggleExpanded(group.dayOffset) }
                    } label: {
                        HStack(spacing: 2) {
                            Text(isExpanded ? "Show less" : "Show \(hiddenCount) more")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .padding(.horizontal, LucakuSpacing.sp4)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(LucakuColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous))
    }

    private var dayHeader: some View {
        Button {
            withAnimation(LucakuMotion.house) { store.toggleCollapsed(group.dayOffset) }
        } label: {
            HStack(spacing: LucakuSpacing.sp3) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(NewsStory.dayLabel(offset: group.dayOffset))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(LucakuColor.textPrimary)
                            .lineLimit(1)
                        if group.dayOffset == 0 {
                            Text("Today")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(LucakuColor.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(LucakuColor.fill))
                        }
                    }
                    let unread = store.unreadCount(in: group)
                    Text("\(group.stories.count) stories · \(unread > 0 ? "\(unread) unread" : "all read")")
                        .font(.system(size: 12))
                        .foregroundStyle(LucakuColor.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LucakuColor.textTertiary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .frame(width: 44, height: 44)
            }
            .padding(.leading, LucakuSpacing.sp4)
            .padding(.trailing, LucakuSpacing.sp2)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isOpen ? "Collapses this day" : "Expands this day")
    }
}

// MARK: - Story row

/// A story row: 72 pt thumbnail, category pill and time, 2-line title, 2-line
/// summary, an unread dot, and a swipe-left action that toggles read / unread.
struct NewsRowView: View {
    let story: NewsStory
    let isRead: Bool
    var onOpen: () -> Void
    var onToggleRead: () -> Void

    @State private var dx: CGFloat = 0
    @State private var tracking = false

    var body: some View {
        ZStack(alignment: .trailing) {
            swipeBackground
            Button(action: onOpen) { rowContent }
                .buttonStyle(.plain)
                .background(LucakuColor.surface)
                .offset(x: dx)
                .simultaneousGesture(swipe)
        }
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isRead ? "" : "Unread. ")\(story.category.label). \(story.title)")
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: LucakuSpacing.sp3) {
            CoverArt(seed: story.title + story.category.rawValue, cornerRadius: 8, glyph: story.category.symbol)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(story.category.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(LucakuColor.fill))
                    Text(story.timeLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(LucakuColor.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(story.title)
                    .font(.system(size: 16, weight: isRead ? .medium : .bold))
                    .foregroundStyle(isRead ? LucakuColor.textSecondary : LucakuColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(story.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.leading, 22)
        .padding(.trailing, LucakuSpacing.sp4)
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(LucakuColor.textPrimary)
                .frame(width: 9, height: 9)
                .padding(.leading, 7)
                .padding(.top, 44)
                .opacity(isRead ? 0 : 1)
        }
        .contentShape(Rectangle())
    }

    private var swipeBackground: some View {
        HStack(spacing: 6) {
            Image(systemName: isRead ? "envelope.badge" : "envelope.open")
                .font(.system(size: 17, weight: .semibold))
            Text(isRead ? "Mark unread" : "Mark read")
                .font(.system(size: 13, weight: .bold))
        }
        .foregroundStyle(Color.white)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .background(isRead ? Color(red: 0x63 / 255, green: 0x63 / 255, blue: 0x66 / 255) : Color(red: 0x48 / 255, green: 0x48 / 255, blue: 0x4A / 255))
        .opacity(min(1, Double(-dx) / 60))
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if !tracking {
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    tracking = true
                }
                dx = max(-130, min(0, value.translation.width))
            }
            .onEnded { _ in
                let commit = tracking && dx < -70
                tracking = false
                withAnimation(.easeOut(duration: 0.25)) { dx = 0 }
                if commit { onToggleRead() }
            }
    }
}

// MARK: - News story (3.6)

struct NewsDetailView: View {
    let story: NewsStory
    @ObservedObject var store: NewsStore
    @EnvironmentObject private var playerViewModel: PlayerViewModel

    @State private var showFeedback = false
    @State private var toast: String?
    @State private var showReported = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CoverArt(seed: story.title + story.category.rawValue, cornerRadius: LucakuRadius.card, glyph: story.category.symbol)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(story.category.label)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(LucakuColor.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(LucakuColor.fill))
                        Text("\(story.dayOffset == 0 ? "Today" : story.dayLabel) · \(story.timeLabel) · \(story.readMinutes) min read")
                            .font(LucakuTypography.footnote)
                            .foregroundStyle(LucakuColor.textSecondary)
                            .lineLimit(1)
                    }
                    Text(story.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                    Text(story.summary)
                        .font(.system(size: 17))
                        .foregroundStyle(LucakuColor.textSecondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("The short version")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LucakuColor.textPrimary)
                    ForEach(story.points, id: \.self) { point in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(LucakuColor.textPrimary).frame(width: 7, height: 7).padding(.top, 8)
                            Text(point)
                                .font(.system(size: 16))
                                .foregroundStyle(LucakuColor.textPrimary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LucakuSpacing.sp4)
                .background(RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous).fill(LucakuColor.surface))

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(story.body, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(.system(size: 17))
                            .lineSpacing(5)
                            .foregroundStyle(LucakuColor.textPrimary)
                    }
                }

                HStack(spacing: 12) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 18))
                        .foregroundStyle(LucakuColor.textSecondary)
                    Text("Because you follow \(story.category.label)")
                        .font(.system(size: 14))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LucakuColor.surface))

                Text("Sources: \(story.sources). Summarised and written by Lucaku.")
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(LucakuColor.textTertiary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Was this useful?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LucakuColor.textPrimary)
                    FeedbackChips(
                        rating: store.rating(for: story),
                        onUseful: { store.setRating(store.rating(for: story) == .up ? nil : .up, for: story) },
                        onNotQuite: {
                            if store.rating(for: story) == .down {
                                store.setRating(nil, for: story)
                            } else {
                                showFeedback = true
                            }
                        }
                    )
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, LucakuSpacing.sp4)
            .padding(.top, LucakuSpacing.sp4)
            .padding(.bottom, playerViewModel.hasEpisode ? 96 : LucakuSpacing.sp8)
        }
        .background(LucakuColor.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .tint(LucakuColor.textPrimary)
        .onAppear { store.markRead(story) } // 3.7: opening clears the dot
        .sheet(isPresented: $showFeedback) {
            FeedbackSheet(
                subject: story.title,
                onSend: { _, _ in
                    store.setRating(.down, for: story)
                    showToast("Thanks. Lucaku will use this to write your news.")
                },
                onReport: {
                    store.setRating(.down, for: story)
                    showReported = true
                }
            )
        }
        .alert("Problem reported", isPresented: $showReported) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("We opened a ticket for this story. Thanks for helping us get it right.")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LucakuColor.bg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(LucakuColor.textPrimary))
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(LucakuMotion.house) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(LucakuMotion.house) { toast = nil }
        }
    }
}
