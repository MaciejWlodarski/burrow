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
                    Text("Rename").font(FinderUI.titleFont)
                    Text(item.name)
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.name)
                }
            }
            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text("New name")
                    .font(FinderUI.detailFont)
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("New name")
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
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
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
            errorMessage = String(localized: "The name can't be empty.")
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
            errorMessage = FileOperationsManager.shared.lastStatusMessage ?? String(localized: "Couldn't rename the item.")
            isNameFocused = true
        }
    }
}
