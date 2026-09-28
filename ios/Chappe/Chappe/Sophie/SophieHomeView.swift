//
//  SophieHomeView.swift
//  R+M — папка Софи (sophie_presence §2, мокап sophie_folder): закреплённые
//  пресеты сверху как есть + свои чаты (создать/переименовать/удалить).
//  У каждого чата своя история и свой суммарий.
//

import SwiftUI
import Combine

@MainActor
final class SophieFolderModel: ObservableObject {

    @Published var chats: [SophieChatInfo] = []

    func reload() {
        chats = SophieChatStore.loadChatList()
    }

    /// Новый чат сразу открывается; имя по счёту, переименовать можно потом.
    @discardableResult
    func createChat() -> SophieChatInfo {
        let info = SophieChatInfo(title: "Новый чат \(chats.count + 1)")
        chats.append(info)
        SophieChatStore.saveChatList(chats)
        return info
    }

    func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].title = trimmed
        SophieChatStore.saveChatList(chats)
    }

    /// Закрепить/открепить свой чат в верхней папке (задание 30.07:
    /// «пользователь может закрепить свой»).
    func setPinned(_ id: String, _ value: Bool) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].pinned = value ? true : nil
        SophieChatStore.saveChatList(chats)
    }

    var pinnedChats: [SophieChatInfo] { chats.filter(\.isPinned) }
    var recentChats: [SophieChatInfo] { chats.filter { !$0.isPinned } }

    /// Удаление вычищает всё: запись, историю, суммарий.
    func delete(_ id: String) {
        chats.removeAll { $0.id == id }
        SophieChatStore.saveChatList(chats)
        SophieChatStore.deleteChat(key: id)
    }
}

struct SophieHomeView: View {
    @StateObject private var model = SophieFolderModel()
    @State private var renameTarget: SophieChatInfo?
    @State private var renameText = ""
    @State private var openedChat: SophieChatInfo?

    /// true — экран показан сам по себе (превью) и несёт свой
    /// NavigationStack; false — пушится из списка чатов (таббар v1),
    /// вложенный стек недопустим.
    var standalone = false

    var body: some View {
        if standalone {
            NavigationStack { content }
        } else {
            content
        }
    }

    private var content: some View {
            List {
                // Ф5.2 + правка 31.07: SOS — плашка ТОЙ ЖЕ формы, что
                // обычная строка («Новый чат»): большой непрерывный
                // радиус, без вертикальных отступов (они и рвали рамку
                // по углам). Внутри — только «SOS» красным, подписи нет.
                Section {
                    NavigationLink {
                        SophieChatView(preset: .sos)
                    } label: {
                        Label {
                            Text(SophiePreset.sos.title)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(RMDesign.danger)
                        } icon: {
                            Image(systemName: SophiePreset.sos.icon)
                                .foregroundStyle(RMDesign.danger)
                        }
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(SophieDesign.surface1)
                            .overlay(RoundedRectangle(cornerRadius: 26,
                                                      style: .continuous)
                                .strokeBorder(RMDesign.danger.opacity(0.6),
                                              lineWidth: 1)))
                }

                Section {
                    ForEach(SophiePreset.allCases.filter { $0 != .sos }) { preset in
                        NavigationLink {
                            SophieChatView(preset: preset)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title)
                                        .foregroundStyle(SophieDesign.textPrimary)
                                    Text(preset.subtitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(SophieDesign.textTertiary)
                                }
                            } icon: {
                                Image(systemName: preset.icon)
                                    .foregroundStyle(SophieDesign.sophieLight)
                            }
                        }
                        .listRowBackground(SophieDesign.surface1)
                    }

                    // Закреплённые пользователем чаты — в той же папке,
                    // после пресетов
                    ForEach(model.pinnedChats) { chat in
                        NavigationLink {
                            SophieChatView(chat: chat)
                        } label: {
                            Label {
                                Text(chat.title)
                                    .foregroundStyle(SophieDesign.textPrimary)
                            } icon: {
                                Image(systemName: "pin")
                                    .foregroundStyle(SophieDesign.sophieLight)
                            }
                        }
                        .listRowBackground(SophieDesign.surface1)
                        .contextMenu {
                            Button("Открепить", systemImage: "pin.slash") {
                                model.setPinned(chat.id, false)
                            }
                            Button("Переименовать", systemImage: "pencil") {
                                renameText = chat.title
                                renameTarget = chat
                            }
                            Button("Удалить", systemImage: "trash",
                                   role: .destructive) {
                                model.delete(chat.id)
                            }
                        }
                    }
                } header: {
                    Text("Всегда под рукой")
                        .foregroundStyle(SophieDesign.textSecondary)
                } footer: {
                    Text("Эти чаты отвечают по проверенным базам на устройстве. "
                       + "Чего нет в базе — \(AppIdentity.assistantName) честно скажет.")
                        .foregroundStyle(SophieDesign.textTertiary)
                }

                Section {
                    ForEach(model.recentChats) { chat in
                        NavigationLink {
                            SophieChatView(chat: chat)
                        } label: {
                            Label {
                                Text(chat.title)
                                    .foregroundStyle(SophieDesign.textPrimary)
                            } icon: {
                                Image(systemName: "sparkle")
                                    .foregroundStyle(SophieDesign.sophieLight)
                            }
                        }
                        .listRowBackground(SophieDesign.surface1)
                        .contextMenu {
                            Button("Закрепить", systemImage: "pin") {
                                model.setPinned(chat.id, true)
                            }
                            Button("Переименовать", systemImage: "pencil") {
                                renameText = chat.title
                                renameTarget = chat
                            }
                            Button("Удалить", systemImage: "trash",
                                   role: .destructive) {
                                model.delete(chat.id)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for offset in offsets {
                            model.delete(model.recentChats[offset].id)
                        }
                    }

                    if model.recentChats.isEmpty {
                        Text("Своих чатов пока нет — создайте кнопкой «+».")
                            .font(.system(size: 12.5))
                            .foregroundStyle(SophieDesign.textTertiary)
                            .listRowBackground(SophieDesign.surface1)
                    }
                } header: {
                    Text("Недавние")
                        .foregroundStyle(SophieDesign.textSecondary)
                } footer: {
                    Text("У каждого чата своя история и свой суммарий — "
                       + "всё на устройстве.")
                        .foregroundStyle(SophieDesign.textTertiary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SophieDesign.background)
            .navigationTitle("\(AppIdentity.assistantName)")
            .toolbar {
                // Зеркало памяти (шаг 3.3): пользователь видит, что Софи
                // помнит между разговорами, и может удалить любую запись
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SophieMemoryView()
                    } label: {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(SophieDesign.sophieLight)
                    }
                    .accessibilityLabel("Память \(AppIdentity.assistantName)")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openedChat = model.createChat()
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(SophieDesign.sophieLight)
                    }
                    .accessibilityLabel("Новый чат")
                }
            }
            .navigationDestination(item: $openedChat) { chat in
                SophieChatView(chat: chat)
            }
            .alert("Название чата", isPresented: .init(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })) {
                TextField("Название", text: $renameText)
                Button("Сохранить") {
                    if let target = renameTarget {
                        model.rename(target.id, to: renameText)
                    }
                    renameTarget = nil
                }
                Button("Отмена", role: .cancel) { renameTarget = nil }
            }
            .onAppear { model.reload() }
            .preferredColorScheme(.dark)
    }
}

#Preview {
    SophieHomeView(standalone: true)
}
