import SwiftUI

// Экран пробника: две кнопки и живой журнал. Всё остальное — ProbeCore.
@main
struct ProbeApp: App {
    @StateObject private var core = ProbeCore()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("Проба BLE-фона")
                    .font(.headline)
                HStack {
                    Label(core.isAdvertising ? "маяк вкл" : "маяк выкл",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(core.isAdvertising ? .green : .secondary)
                    Label(core.isScanning ? "скан вкл" : "скан выкл",
                          systemImage: "magnifyingglass")
                        .foregroundStyle(core.isScanning ? .green : .secondary)
                }
                .font(.caption)
                HStack {
                    Button("Старт") { core.startBoth() }
                        .buttonStyle(.borderedProminent)
                    Button("Стоп") { core.stopAll() }
                        .buttonStyle(.bordered)
                    Button("Метка") { core.log("mark", detail: "ручная метка") }
                        .buttonStyle(.bordered)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(core.lines.enumerated()),
                                    id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .id(i)
                            }
                        }
                    }
                    .onChange(of: core.lines.count) { _, n in
                        proxy.scrollTo(n - 1, anchor: .bottom)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding()
            // автостарт: замеры снимаются и без касаний экрана
            .onAppear { core.startBoth() }
        }
    }
}
