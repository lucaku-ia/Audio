import SwiftUI

/// What the detail sheet (6.2) is showing.
enum InterestSheetTarget: Identifiable, Hashable {
    case category(String)
    case topic(String)

    var id: String {
        switch self {
        case .category(let id): return "c:" + id
        case .topic(let id): return "t:" + id
        }
    }
}

/// Bottom sheet for one category (Follow chips + what Lucaku researches) or
/// one topic (the exact question, edit, Stop following). Done at the bottom.
struct InterestSheet: View {
    let target: InterestSheetTarget
    @ObservedObject var viewModel: InterestsViewModel
    let token: String?
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var draft = ""

    private var topic: InterestsViewModel.Topic? {
        if case .topic(let id) = target { return viewModel.topics.first { $0.id == id } }
        return nil
    }

    private var categoryId: String? {
        switch target {
        case .category(let id): return id
        case .topic: return topic?.categoryId
        }
    }

    private var title: String {
        switch target {
        case .category(let id): return viewModel.label(forCategory: id)
        case .topic: return topic?.label ?? ""
        }
    }

    private var caption: String {
        switch target {
        case .category(let id):
            return viewModel.followsCategory(id) ? "Following everything in this category" : "Pick what to follow"
        case .topic:
            return categoryId.map { viewModel.label(forCategory: $0) } ?? "Your question"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                switch target {
                case .category(let id): categoryBody(id)
                case .topic: topicBody
                }
                InterestsPrimaryButton(title: "Done") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .background(LucakuColor.bg.ignoresSafeArea())
        .onChange(of: topic == nil) { _, gone in
            if gone, case .topic = target { dismiss() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                InterestPalette.gradient(forCategory: categoryId)
                Image(systemName: InterestPalette.symbol(forCategory: categoryId))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
                Text(caption)
                    .font(.system(size: 14))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(LucakuColor.fill))
            }
            .buttonStyle(.plain)
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityLabel("Close")
        }
    }

    // MARK: - Category

    private func categoryBody(_ id: String) -> some View {
        let all = viewModel.followsCategory(id)
        let questions = viewModel.topics.filter { $0.categoryId == id }.map(\.question)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Follow")
                InterestChipFlow(spacing: 8) {
                    FollowChip(label: "Everything in \(viewModel.label(forCategory: id))", isOn: all, minHeight: 38) {
                        guard let token else { return }
                        Task {
                            if all { await viewModel.removeCategory(id: id, token: token) }
                            else { await viewModel.addCategory(id: id, token: token) }
                        }
                    }
                    ForEach(InterestCatalog.specific[id] ?? [], id: \.self) { label in
                        FollowChip(label: label, isOn: viewModel.followsTopic(label: label), minHeight: 38) {
                            guard let token else { return }
                            Task {
                                if viewModel.followsTopic(label: label) { await viewModel.unfollowTopic(label: label, token: token) }
                                else { await viewModel.followTopic(label: label, token: token) }
                            }
                        }
                    }
                }
            }
            if all || !questions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Lucaku researches")
                    let list = questions.isEmpty
                        ? ["The most important \(viewModel.label(forCategory: id)) news of the day."]
                        : questions
                    ForEach(list, id: \.self) { questionRow($0) }
                }
            }
        }
    }

    // MARK: - Topic

    @ViewBuilder
    private var topicBody: some View {
        if let topic {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Lucaku researches")
                    if isEditing {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Question", text: $draft, axis: .vertical)
                                .font(.system(size: 15))
                                .lineLimit(1...4)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(LucakuColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            HStack(spacing: 8) {
                                smallButton("Cancel", filled: false) { isEditing = false }
                                smallButton("Save", filled: true) { save(topic) }
                                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).count < 5
                                              || viewModel.pendingIds.contains(topic.id))
                            }
                        }
                    } else {
                        questionRow(topic.question) {
                            Button {
                                draft = topic.question
                                isEditing = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(LucakuColor.icon)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit question")
                        }
                    }
                }
                Button {
                    guard let token else { return }
                    Task {
                        await viewModel.stopFollowing(topic, token: token)
                        dismiss()
                    }
                } label: {
                    Text("Stop following")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LucakuColor.destructive)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(LucakuColor.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(LucakuColor.textSecondary)
    }

    private func questionRow(_ text: String) -> some View {
        questionRow(text) { EmptyView() }
    }

    private func questionRow<Trailing: View>(_ text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LucakuColor.icon)
                .frame(height: 20)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(LucakuColor.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(LucakuColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func smallButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(filled ? LucakuColor.bg : LucakuColor.textPrimary)
                .padding(.horizontal, 18)
                .frame(minHeight: 40)
                .background(Capsule().fill(filled ? LucakuColor.textPrimary : LucakuColor.fill))
        }
        .buttonStyle(.plain)
    }

    private func save(_ topic: InterestsViewModel.Topic) {
        guard let token else { return }
        Task {
            if await viewModel.editTopic(topic, question: draft, token: token) != nil { isEditing = false }
        }
    }
}
