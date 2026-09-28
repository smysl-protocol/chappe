import SwiftUI
import Combine

// ============================================================================
// «Что помнит Софи» (шаг 3.3) — человекочитаемое зеркало памяти:
// пользователь ВИДИТ каждый факт и эпизод и может удалить любой
// навсегда (замок deleteFactPersists). Всё локально, шифровано ключом,
// «Начать заново» стирает целиком (криптостирание).
// ============================================================================

@MainActor
final class SophieMemoryModel: ObservableObject {

    @Published var facts: [SophieFact] = []
    @Published var episodes: [SophieEpisode] = []

    /// В бою — общий стор с ключом из Keychain; тесты подменяют.
    var memory: SophieMemoryStore? = SophieMemoryStore.open()

    func load() async {
        guard let memory else { return }
        facts = await memory.facts().reversed()      // свежее сверху
        episodes = await memory.episodes().reversed()
    }

    func deleteFact(_ id: UUID) async {
        await memory?.deleteFact(id: id)
        await load()
    }

    func deleteEpisode(_ id: UUID) async {
        await memory?.deleteEpisode(id: id)
        await load()
    }
}

struct SophieMemoryView: View {

    @StateObject private var model = SophieMemoryModel()

    var body: some View {
        List {
            Section {
                Text("Всё, что \(AppIdentity.assistantName) помнит между "
                     + "разговорами, — на этом экране. Хранится только на "
                     + "телефоне, зашифровано; «Начать заново» стирает всё. "
                     + "Смахните запись, чтобы удалить её навсегда.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if model.facts.isEmpty && model.episodes.isEmpty {
                Section {
                    Text("\(AppIdentity.assistantName) пока ничего не запомнила.")
                        .foregroundStyle(.secondary)
                }
            }
            if !model.facts.isEmpty {
                Section("Факты") {
                    ForEach(model.facts) { fact in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.content)
                            Text(fact.subject)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { model.facts[$0].id }
                        Task { for id in doomed { await model.deleteFact(id) } }
                    }
                }
            }
            if !model.episodes.isEmpty {
                Section("Эпизоды") {
                    ForEach(model.episodes) { episode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.summary)
                            Text(episode.happenedAt.formatted(
                                date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { model.episodes[$0].id }
                        Task { for id in doomed { await model.deleteEpisode(id) } }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SophieDesign.background)
        .navigationTitle("Память \(AppIdentity.assistantName)")
        .preferredColorScheme(.dark)
        .task { await model.load() }
    }
}
