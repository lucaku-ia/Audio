import SwiftUI

/// Library / Search tab — GET /api/search/history, GET /api/search/query,
/// and a manual "Generate now" button against POST /api/generation/run so
/// the Episode Generator's on-demand path is reachable from the app too.
struct LibraryView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel = LibraryViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    generateButton
                }

                switch viewModel.historyState {
                case .idle, .loading:
                    ProgressView("Loading history…")
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Couldn't load history").font(.headline)
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                        Button("Retry") { Task { await refresh() } }
                    }
                case .loaded(let history):
                    if let results = viewModel.searchResults {
                        Section("Search results") {
                            if results.episodes.isEmpty && results.unmatchedRequests.isEmpty {
                                Text("No matches for \"\(results.query)\"").foregroundStyle(.secondary)
                            }
                            ForEach(results.episodes) { episode in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(episode.headline ?? "Untitled").font(.body)
                                    if let snippet = episode.headlineSnippet {
                                        Text(snippet).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } else {
                        Section("History") {
                            if history.items.isEmpty {
                                Text("No episodes yet.").foregroundStyle(.secondary)
                            }
                            ForEach(history.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.headline)
                                    HStack {
                                        Text(item.fecha)
                                        Text("· \(item.state)")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $viewModel.searchText, prompt: "Search your episodes")
            .onSubmit(of: .search) {
                guard let token = session.accessToken else { return }
                Task { await viewModel.runSearch(token: token) }
            }
            .onChange(of: viewModel.searchText) { _, newValue in
                if newValue.isEmpty {
                    Task { await viewModel.runSearch(token: session.accessToken ?? "") }
                }
            }
            .navigationTitle("Library")
            .task { await refresh() }
            .refreshable { await refresh() }
        }
    }

    @ViewBuilder
    private var generateButton: some View {
        switch viewModel.generationState {
        case .idle, .failed:
            Button("Generate today's episode now") {
                guard let token = session.accessToken else { return }
                Task { await viewModel.runGeneration(token: token) }
            }
            if case .failed(let message) = viewModel.generationState {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        case .running:
            HStack {
                ProgressView()
                Text("Generating… this calls the real research → write → voice pipeline and can take a while.")
                    .font(.caption)
            }
        case .finished(let job):
            LabeledContent("Last job status", value: job.status)
        }
    }

    private func refresh() async {
        guard let token = session.accessToken else { return }
        await viewModel.loadHistory(token: token)
    }
}

#Preview {
    LibraryView()
        .environmentObject(SessionStore())
}
