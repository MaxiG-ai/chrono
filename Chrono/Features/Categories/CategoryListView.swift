import SwiftUI

/// Manage categories: add, rename, recolor, archive, reorder, delete.
struct CategoryListView: View {
    @Environment(ChronoStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showingAdd = false
    @State private var showingArchived = false

    var body: some View {
        List {
            Section("Active") {
                ForEach(store.topLevelCategories()) { cat in
                    NavigationLink {
                        CategoryEditView(mode: .edit(cat))
                    } label: {
                        CategoryRowLabel(category: cat,
                                         subcount: store.subcategories(of: cat.id).count)
                    }
                }
                .onMove { indices, destination in
                    var current = store.topLevelCategories()
                    current.move(fromOffsets: indices, toOffset: destination)
                    Task { await store.reorderTopLevel(current.map(\.id)) }
                }
                .onDelete { offsets in
                    let current = store.topLevelCategories()
                    Task {
                        for i in offsets {
                            await store.deleteCategory(current[i].id)
                        }
                    }
                }
            }

            if showingArchived {
                Section("Archived") {
                    ForEach(archivedCategories) { cat in
                        HStack {
                            CategoryRowLabel(category: cat, subcount: 0)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Unarchive") {
                                Task { await store.archiveCategory(cat.id, archived: false) }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button {
                        showingArchived.toggle()
                    } label: {
                        Image(systemName: showingArchived ? "archivebox.fill" : "archivebox")
                    }
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    EditButton()
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                CategoryEditView(mode: .create(parent: nil))
            }
        }
    }

    private var archivedCategories: [TimeCategory] {
        store.categories.filter { $0.archived && $0.parentId == nil }
            .sorted { $0.name < $1.name }
    }
}

private struct CategoryRowLabel: View {
    let category: TimeCategory
    let subcount: Int

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(category.color)
                .frame(width: 14, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                if subcount > 0 {
                    Text("\(subcount) subcategor\(subcount == 1 ? "y" : "ies")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
