import SwiftUI
import SwiftData

/// Sheet/overlay presenting cross-meeting semantic search results.
struct SemanticSearchView: View {
    @ObservedObject var meetingManager: MeetingManager

    /// Called when the user clicks a result so the parent can navigate to the matching meeting + segment.
    let onSelect: (SemanticSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var query: String = ""
    @State private var results: [SemanticSearchResult] = []
    @State private var errorMessage: String?

    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
        }
        .frame(width: 640, height: 500)
        .onAppear {
            queryFocused = true
            meetingManager.semanticSearch.configure(modelContext: modelContext)
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(Color.accentColor)

            TextField("Ask across all meetings — \"What did Sarah commit to?\"", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($queryFocused)
                .onSubmit(runSearch)

            if meetingManager.semanticSearch.isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button("Search", action: runSearch)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let errorMessage = errorMessage {
            errorView(errorMessage)
        } else if results.isEmpty && !query.isEmpty && !meetingManager.semanticSearch.isSearching {
            noResultsView
        } else if results.isEmpty {
            introView
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(results) { result in
                    Button {
                        onSelect(result)
                        dismiss()
                    } label: {
                        resultRow(result)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func resultRow(_ result: SemanticSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(result.meetingTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(result.meetingDate, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", result.score * 100))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 6) {
                if let speaker = result.speaker {
                    Text(speaker)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                }
                Text(formatTime(result.startTime))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(result.text)
                    .font(.caption)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.orange)
            Text("Search failed").font(.headline)
            Text(msg).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("No matches").font(.headline)
            Text("Try phrasing your question differently.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var introView: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            Text("Ask a question").font(.headline)
            Text("Search the content of all your meetings. Results are ranked by meaning, not keywords.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func runSearch() {
        errorMessage = nil
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let key = KeychainHelper.load(key: "meetrecap_openai_key"), !key.isEmpty else {
            errorMessage = "Semantic search requires an OpenAI API key. Add one in Settings → API Keys."
            return
        }
        Task {
            do {
                results = try await meetingManager.semanticSearch.search(query: query, topK: 20, apiKey: key)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
