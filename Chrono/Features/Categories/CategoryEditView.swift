import SwiftUI

struct CategoryEditView: View {
    enum Mode: Hashable {
        case create(parent: CategoryID?)
        case edit(TimeCategory)

        var isEdit: Bool { if case .edit = self { return true } else { return false } }
    }

    let mode: Mode

    @Environment(ChronoStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var colorHex: String = CategoryPalette.colors[0]
    @State private var parentId: CategoryID?
    @State private var archived: Bool = false

    var body: some View {
        Form {
            Section("Name") {
                TextField("e.g. Deep Work", text: $name)
                    .textInputAutocapitalization(.words)
            }

            Section("Color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 7), spacing: 12) {
                    ForEach(CategoryPalette.colors, id: \.self) { hex in
                        Button {
                            colorHex = hex
                            Haptics.select()
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Circle().strokeBorder(
                                        hex == colorHex ? Color.primary : Color.clear,
                                        lineWidth: 2.5
                                    )
                                )
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .font(.caption).bold()
                                        .foregroundStyle(.white)
                                        .opacity(hex == colorHex ? 1 : 0)
                                )
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Parent") {
                Picker("Parent category", selection: $parentId) {
                    Text("None (top level)").tag(CategoryID?.none)
                    ForEach(eligibleParents) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                .pickerStyle(.navigationLink)
            }

            if case .edit = mode {
                Section {
                    Toggle("Archived", isOn: $archived)
                }

                if case .edit(let category) = mode {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                await store.deleteCategory(category.id)
                                dismiss()
                            }
                        } label: {
                            Label("Delete Category", systemImage: "trash")
                        }
                    } footer: {
                        Text("Deleting removes this category and all entries logged to it. Archive instead to preserve history.")
                    }
                }
            }
        }
        .navigationTitle(mode.isEdit ? "Edit Category" : "New Category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .bold()
            }
        }
        .onAppear {
            switch mode {
            case .create(let parent):
                parentId = parent
            case .edit(let category):
                name = category.name
                colorHex = category.colorHex
                parentId = category.parentId
                archived = category.archived
            }
        }
    }

    /// Only top-level active categories are eligible to be parents (one level of nesting).
    private var eligibleParents: [TimeCategory] {
        store.topLevelCategories().filter { cat in
            if case .edit(let current) = mode, current.id == cat.id { return false }
            return true
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            switch mode {
            case .create:
                await store.addCategory(name: trimmed, colorHex: colorHex, parent: parentId)
            case .edit(var category):
                category.name = trimmed
                category.colorHex = colorHex
                category.parentId = parentId
                category.archived = archived
                await store.updateCategory(category)
            }
            dismiss()
        }
    }
}
