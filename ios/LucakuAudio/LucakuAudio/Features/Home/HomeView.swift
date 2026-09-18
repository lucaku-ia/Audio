import SwiftUI

/// Home screen — calls the real GET /api/home endpoint and renders the real
/// response. Deliberately plain/unstyled per the scaffold's goal (real data
/// flowing end to end); a separate design pass owns the visual polish.
struct HomeView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Home")
                .task { await refresh() }
                .refreshable { await refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("Loading Home…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Text("Couldn't load Home")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await refresh() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let home):
            List {
                Section("Banner") {
                    bannerRows(home.banner)
                    if home.banner.state == "empty_day" {
                        requestTodayForm
                    }
                }

                if !home.recent.isEmpty {
                    Section("Recent") {
                        ForEach(home.recent) { episode in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(episode.headline ?? "No news")
                                    .font(.body)
                                HStack {
                                    Text(episode.date)
                                    if let style = episode.style { Text("· \(style)") }
                                    if let duration = episode.durationS {
                                        Text("· \(duration / 60)m \(duration % 60)s")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !home.sharedInventory.isEmpty {
                    Section("Because you follow…") {
                        ForEach(home.sharedInventory) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.headline ?? "Untitled")
                                Text(item.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bannerRows(_ banner: BannerOut) -> some View {
        LabeledContent("State", value: banner.state)
        if let headline = banner.headline {
            LabeledContent("Headline", value: headline)
        }
        if let count = banner.requestsCount {
            LabeledContent("Requests", value: "\(count)")
        }
        if let duration = banner.durationS {
            LabeledContent("Duration", value: "\(duration / 60)m \(duration % 60)s")
        }
        if let eta = banner.eta {
            LabeledContent("ETA", value: eta.formatted(date: .omitted, time: .shortened))
        }
    }

    @ViewBuilder
    private var requestTodayForm: some View {
        TextField("What do you want to know about today?", text: $viewModel.requestTodayText)
        Button {
            guard let token = session.accessToken else { return }
            Task { await viewModel.submitRequestToday(token: token) }
        } label: {
            if viewModel.isSubmittingRequest {
                ProgressView()
            } else {
                Text("Request for today")
            }
        }
        .disabled(viewModel.isSubmittingRequest)
        if let error = viewModel.requestTodayError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private func refresh() async {
        guard let token = session.accessToken else { return }
        await viewModel.load(token: token)
    }
}

#Preview {
    HomeView()
        .environmentObject(SessionStore())
}
