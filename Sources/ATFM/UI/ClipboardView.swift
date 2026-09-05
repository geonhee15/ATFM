import SwiftUI

struct ClipboardView: View {
    @Bindable var vm: ClipboardViewModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let sections = vm.sections
        VStack(spacing: 10) {
            header
            searchBar
            if vm.appFilterKey != nil || vm.kindFilter != nil {
                filterChips
            }
            if vm.showClearAllConfirm {
                clearAllBar
            }
            if sections.isEmpty {
                emptyState
            } else {
                list(sections)
            }
            if vm.isSelecting {
                selectionBar
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("클립보드")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(vm.items.count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.chipFill(scheme)))
            Spacer()
            Menu {
                if vm.isSelecting {
                    Button { vm.endSelecting() } label: { Label("선택 종료", systemImage: "xmark.circle") }
                } else {
                    Button { vm.beginSelecting() } label: { Label("항목 선택", systemImage: "checkmark.circle") }
                }
                Divider()
                Button(role: .destructive) { vm.showClearAllConfirm = true } label: {
                    Label("전체 삭제…", systemImage: "trash")
                }
                .disabled(vm.items.isEmpty)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 2)
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("내용이나 앱 이름으로 검색", text: $vm.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !vm.searchText.isEmpty {
                Button { vm.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            filterMenu
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .frame(height: 36)
        .card(radius: 10)
    }

    private var filterMenu: some View {
        Menu {
            Picker("앱", selection: $vm.appFilterKey) {
                Text("모든 앱").tag(String?.none)
                ForEach(vm.knownApps) { known in
                    Label {
                        Text(known.app.displayName)
                    } icon: {
                        Image(nsImage: AppIconCache.icon(for: known.app, size: 16))
                    }
                    .tag(String?.some(known.key))
                }
            }
            .pickerStyle(.inline)
            Picker("종류", selection: $vm.kindFilter) {
                Text("모든 종류").tag(ClipKind?.none)
                Label("텍스트", systemImage: "text.alignleft").tag(ClipKind?.some(.text))
                Label("이미지", systemImage: "photo").tag(ClipKind?.some(.image))
                Label("파일", systemImage: "doc").tag(ClipKind?.some(.files))
            }
            .pickerStyle(.inline)
        } label: {
            Group {
                if let app = vm.appFilter {
                    Image(nsImage: AppIconCache.icon(for: app, size: 18))
                        .resizable()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: vm.kindFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(vm.kindFilter == nil ? Color.secondary : Theme.accent)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("앱 · 종류로 필터")
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            if let app = vm.appFilter {
                FilterChip(text: app.displayName, icon: AppIconCache.icon(for: app, size: 14)) { vm.appFilterKey = nil }
            }
            if let kind = vm.kindFilter {
                FilterChip(text: kind.label, systemImage: kind.symbol) { vm.kindFilter = nil }
            }
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    // MARK: Bars

    private var clearAllBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("기록 \(vm.items.count)개를 모두 삭제할까요?")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("취소") { vm.showClearAllConfirm = false }
            Button(role: .destructive) { vm.deleteAll() } label: { Text("삭제") }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .card()
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Text("\(vm.selectedIDs.count)개 선택")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            Spacer()
            Button("모두 선택") { vm.selectAllVisible() }
            Button("취소") { vm.endSelecting() }
            Button(role: .destructive) { vm.deleteSelected() } label: {
                Label("삭제", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(vm.selectedIDs.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .card()
    }

    // MARK: List

    private func list(_ sections: [DaySection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 0).id("top")
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(dayTitle(section.day))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(section.items.count)개")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 4)

                            VStack(spacing: 0) {
                                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                    ClipRow(
                                        item: item,
                                        thumbnail: vm.thumbnail(for: item),
                                        isSelecting: vm.isSelecting,
                                        isSelected: vm.selectedIDs.contains(item.id),
                                        justCopied: vm.recentlyCopiedID == item.id,
                                        onTap: {
                                            if vm.isSelecting { vm.toggleSelection(item) } else { vm.copyToPasteboard(item) }
                                        },
                                        onDelete: { withAnimation(.snappy(duration: 0.2)) { vm.delete(item) } },
                                        onSelectMode: {
                                            vm.beginSelecting()
                                            vm.toggleSelection(item)
                                        }
                                    )
                                    if index < section.items.count - 1 {
                                        Divider().padding(.leading, vm.isSelecting ? 70 : 44)
                                    }
                                }
                            }
                            .card()
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.automatic)
            .onChange(of: vm.presentationCount) { _, _ in
                proxy.scrollTo("top", anchor: .top)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: vm.isFiltering ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(vm.isFiltering ? "검색 결과가 없어요" : "아직 복사한 내용이 없어요")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if vm.isFiltering {
                Button("필터 초기화") { vm.resetFilters() }
                    .controlSize(.small)
            } else {
                Text("⌘C 로 복사하면 여기에 쌓입니다")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Helpers

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        let formatted: String
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            formatted = day.formatted(.dateTime.month().day().weekday(.abbreviated))
        } else {
            formatted = day.formatted(.dateTime.year().month().day().weekday(.abbreviated))
        }
        if calendar.isDateInToday(day) { return "오늘 · " + formatted }
        if calendar.isDateInYesterday(day) { return "어제 · " + formatted }
        return formatted
    }
}

struct FilterChip: View {
    var text: String
    var icon: NSImage?
    var systemImage: String?
    var onRemove: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            }
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.chipFill(scheme)))
    }
}
