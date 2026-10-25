import SwiftUI

struct RenameItemSheet: View {
    let item: FileItem
    @ObservedObject var pane: PaneTabState
    @ObservedObject private var iconCache = FileIconCache.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @ViewState private var draft: String
    @ViewState private var errorMessage: String?

    init(item: FileItem, pane: PaneTabState) {
        self.item = item
        self.pane = pane
        self._draft = ViewState(wrappedValue: item.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FinderUI.sectionSpacing) {
            HStack(spacing: 12) {
                Image(nsImage: FileIconCache.shared.icon(for: item))
                    .resizable().frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                    Text("Zmień nazwę").font(FinderUI.titleFont)
                    Text(item.name)
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.name)
                }
            }
            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text("Nowa nazwa")
                    .font(FinderUI.detailFont)
                TextField("Nazwa", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Nowa nazwa")
                    .focused($isNameFocused)
                    .onSubmit(rename)
                    .onChange(of: draft) { _, _ in errorMessage = nil }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(FinderUI.detailFont)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Zmień nazwę", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == item.name)
            }
        }
        .font(FinderUI.bodyFont)
        .controlSize(.regular)
        .padding(FinderUI.sheetPadding)
        .frame(width: 420)
        .onAppear { isNameFocused = true }
    }

    private func rename() {
        // Return bypasses the disabled button, so validate the same trimmed value here.
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Nazwa nie może być pusta."
            isNameFocused = true
            return
        }
        guard name != item.name else { dismiss(); return }
        if let url = FileOperationsManager.shared.renameItem(item, to: name) {
            pane.renamingItemPath = nil
            pane.refresh()
            pane.selectedPaths = [url.path]
            pane.selectionCursorPath = url.path
            dismiss()
        } else {
            errorMessage = FileOperationsManager.shared.lastStatusMessage ?? "Nie udało się zmienić nazwy."
            isNameFocused = true
        }
    }
}
