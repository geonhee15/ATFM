import AppKit
import Observation

struct DaySection: Identifiable {
    let day: Date
    let items: [ClipItem]
    var id: Date { day }
}

struct KnownApp: Identifiable, Hashable {
    let key: String
    let app: SourceApp
    var id: String { key }
}

@MainActor
@Observable
final class ClipboardViewModel {
    private(set) var items: [ClipItem] = []

    var searchText = ""
    var appFilterKey: String?
    var kindFilter: ClipKind?
    var isSelecting = false
    var selectedIDs: Set<Int64> = []
    var showClearAllConfirm = false
    var recentlyCopiedID: Int64?
    /// Incremented every time the bubble is shown; views can react (e.g. scroll to top).
    var presentationCount = 0

    let store: ClipboardStore
    @ObservationIgnored weak var monitor: ClipboardMonitor?
    @ObservationIgnored var onRequestKeyboardReturn: (() -> Void)?
    @ObservationIgnored private let thumbCache = NSCache<NSNumber, NSImage>()

    init(store: ClipboardStore) {
        self.store = store
        items = store.fetchAll()
        thumbCache.countLimit = 400
    }

    // MARK: - Derived data

    var isFiltering: Bool { !searchText.isEmpty || appFilterKey != nil || kindFilter != nil }

    var filteredItems: [ClipItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            if let key = appFilterKey, item.app.cacheKey != key { return false }
            if let kind = kindFilter, item.kind != kind { return false }
            if query.isEmpty { return true }
            if item.text.localizedCaseInsensitiveContains(query) { return true }
            if let name = item.app.name, name.localizedCaseInsensitiveContains(query) { return true }
            if item.kind == .image, item.kind.label.contains(query) { return true }
            return false
        }
    }

    var sections: [DaySection] {
        let calendar = Calendar.current
        var result: [DaySection] = []
        var currentDay: Date?
        var bucket: [ClipItem] = []
        for item in filteredItems {
            let day = calendar.startOfDay(for: item.createdAt)
            if day != currentDay {
                if let d = currentDay { result.append(DaySection(day: d, items: bucket)) }
                currentDay = day
                bucket = []
            }
            bucket.append(item)
        }
        if let d = currentDay { result.append(DaySection(day: d, items: bucket)) }
        return result
    }

    var knownApps: [KnownApp] {
        var seen: [String: SourceApp] = [:]
        for item in items where seen[item.app.cacheKey] == nil {
            seen[item.app.cacheKey] = item.app
        }
        return seen.map { KnownApp(key: $0.key, app: $0.value) }
            .sorted { $0.app.displayName.localizedCaseInsensitiveCompare($1.app.displayName) == .orderedAscending }
    }

    var appFilter: SourceApp? {
        guard let key = appFilterKey else { return nil }
        return knownApps.first { $0.key == key }?.app
    }

    func thumbnail(for item: ClipItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        let key = NSNumber(value: item.id)
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let data = store.thumbData(id: item.id) ?? store.imageData(id: item.id),
              let image = NSImage(data: data) else { return nil }
        thumbCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Ingest

    func ingest(_ clip: CapturedClip) {
        let hash = clip.hash
        if AppSettings.moveDuplicatesToTop, let index = items.firstIndex(where: { $0.hash == hash }) {
            var existing = items.remove(at: index)
            existing.createdAt = clip.date
            existing.app = clip.source
            store.bump(id: existing.id, date: clip.date, source: clip.source)
            items.insert(existing, at: 0)
            return
        }
        guard let item = store.insert(clip) else { return }
        items.insert(item, at: 0)
        trimToLimit()
    }

    func trimToLimit() {
        let limit = max(50, AppSettings.maxItems)
        guard items.count > limit else { return }
        let overflow = Array(items[limit...])
        store.delete(ids: overflow.map(\.id))
        items.removeLast(overflow.count)
        overflow.forEach { thumbCache.removeObject(forKey: NSNumber(value: $0.id)) }
    }

    // MARK: - Actions

    func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text, forType: .string)
        case .files:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) as NSURL }
            pb.writeObjects(urls)
        case .image:
            let pbItem = NSPasteboardItem()
            if let data = store.imageData(id: item.id) {
                pbItem.setData(data, forType: .png)
                if let tiff = NSImage(data: data)?.tiffRepresentation {
                    pbItem.setData(tiff, forType: .tiff)
                }
            }
            if !item.text.isEmpty { pbItem.setString(item.text, forType: .string) }
            pb.writeObjects([pbItem])
        }
        monitor?.markOwnChange()
        onRequestKeyboardReturn?()

        recentlyCopiedID = item.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.recentlyCopiedID == item.id { self?.recentlyCopiedID = nil }
        }
    }

    func delete(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        store.delete(ids: Array(ids))
        items.removeAll { ids.contains($0.id) }
        ids.forEach { thumbCache.removeObject(forKey: NSNumber(value: $0)) }
        selectedIDs.subtract(ids)
        if items.isEmpty { isSelecting = false }
        if let key = appFilterKey, !knownApps.contains(where: { $0.key == key }) { appFilterKey = nil }
    }

    func delete(_ item: ClipItem) { delete(ids: [item.id]) }

    func deleteSelected() {
        delete(ids: selectedIDs)
        selectedIDs = []
        isSelecting = false
    }

    func deleteAll() {
        store.deleteAll()
        items = []
        selectedIDs = []
        isSelecting = false
        showClearAllConfirm = false
        appFilterKey = nil
        thumbCache.removeAllObjects()
    }

    func toggleSelection(_ item: ClipItem) {
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
    }

    func selectAllVisible() {
        selectedIDs = Set(filteredItems.map(\.id))
    }

    func beginSelecting() {
        isSelecting = true
        selectedIDs = []
    }

    func endSelecting() {
        isSelecting = false
        selectedIDs = []
    }

    func resetFilters() {
        searchText = ""
        appFilterKey = nil
        kindFilter = nil
    }
}
