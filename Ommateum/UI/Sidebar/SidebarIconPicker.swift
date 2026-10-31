import SwiftUI

/// Chooses an SF Symbol for a sidebar item.
struct SidebarIconPicker: View {
    static let symbols = [
        "folder", "folder.fill", "star", "heart", "flag", "tag", "bookmark", "pin",
        "house", "building.2", "briefcase", "person", "person.2", "cart", "creditcard", "calendar",
        "doc", "doc.text", "book", "graduationcap", "tray", "archivebox", "shippingbox", "trash",
        "photo", "camera", "film", "video", "music.note", "mic", "headphones", "gamecontroller",
        "paintbrush", "paintpalette", "hammer", "wrench.and.screwdriver", "terminal", "chevron.left.forwardslash.chevron.right", "globe", "cloud",
        "server.rack", "externaldrive", "lock", "clock", "lightbulb", "bolt", "flame", "leaf",
    ]

    let current: String?
    let choose: (String?) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("アイコンを選択").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 8), spacing: 6) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button { choose(symbol) } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 16))
                            .frame(width: 36, height: 32)
                            .background(symbol == current ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(symbol)
                }
            }
            HStack {
                Button("既定のアイコンに戻す") { choose(nil) }
                Spacer()
                Button("キャンセル", action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .fixedSize()
    }
}
