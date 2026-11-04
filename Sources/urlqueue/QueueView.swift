import SwiftUI

struct QueueView: View {
    @EnvironmentObject var store: QueueStore

    /// メニューバーのポップオーバー用の詰めたレイアウト
    var compact: Bool = false

    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: compact ? 360 : 420, minHeight: compact ? 0 : 240)
    }

    // MARK: - ヘッダ

    private var header: some View {
        HStack(spacing: 8) {
            Text(store.items.isEmpty ? "キューは空です" : "\(store.items.count) 件")
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            if !store.items.isEmpty {
                Button("すべて開く") { store.openAll() }
                    .help("すべてデフォルトブラウザで開いて一覧から削除します")

                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Text("すべて削除")
                }
                .help("開かずにすべて削除します")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .confirmationDialog(
            "\(store.items.count) 件すべてを削除しますか？",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("すべて削除", role: .destructive) { store.clear() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: - 一覧

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.items) { item in
                    QueueRow(item: item)
                    Divider().padding(.leading, 12)
                }
            }
        }
        .frame(maxHeight: compact ? 420 : .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: compact ? 20 : 28))
                .foregroundStyle(.tertiary)
            Text("urlqueue <URL> で追加できます")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 20 : 40)
    }
}

// MARK: - 行

private struct QueueRow: View {
    @EnvironmentObject var store: QueueStore
    let item: QueueItem

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Text(item.addedAt, format: .relative(presentation: .numeric))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .opacity(hovering ? 0 : 1)

            Button {
                store.remove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("開かずに削除")
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(hovering ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.openAndRemove(item) }
        .help("クリックでデフォルトブラウザで開いて削除")
        .contextMenu {
            Button("開いて削除") { store.openAndRemove(item) }
            Button("URL をコピー") { store.copyToClipboard(item) }
            Divider()
            Button("削除", role: .destructive) { store.remove(item) }
        }
    }
}
