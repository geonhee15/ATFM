import SwiftUI

struct DictionaryView: View {
    @Bindable var hub: DictionaryHub
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch hub.section {
            case .english, .korean:
                WordLookupView(hub: hub)
            case .periodic:
                PeriodicTableView(hub: hub)
            }
        }
        .padding(.horizontal, 20)
        .onAppear { hub.pasteIfWord() }
    }

    private var header: some View {
        HStack {
            Text("사전")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $hub.section) {
                ForEach(DictionaryHub.Section.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 210)
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Word lookup (영어 · 국어)

private struct WordLookupView: View {
    @Bindable var hub: DictionaryHub
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchBar
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !hub.currentInstalled { notInstalledCard }
                    if hub.searched.isEmpty {
                        recentCard
                    } else if hub.entries.isEmpty {
                        notFoundCard
                    } else {
                        ForEach(hub.entries) { entry in
                            EntryCard(headword: entry.headword, text: entry.text, source: hub.currentKind.title)
                        }
                        if hub.section == .english {
                            ForEach(hub.englishEnglish) { entry in
                                EntryCard(headword: entry.headword, text: entry.text, source: hub.englishEnglishKind?.title ?? "영영")
                            }
                            if hub.onlineLoading {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("영영 사전(온라인) 불러오는 중…").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 4)
                            } else if let online = hub.online {
                                OnlineEntryCard(entry: online)
                            }
                        }
                        Button {
                            hub.openInDictionaryApp()
                        } label: {
                            Label("사전 앱에서 보기", systemImage: "book")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(hub.section == .korean ? "국어 단어" : "영어 단어 또는 한국어 (영한 · 한영)", text: $hub.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { hub.lookup() }
            if !hub.query.isEmpty {
                Button {
                    hub.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button("찾기") { hub.lookup() }
                .controlSize(.small)
                .disabled(hub.query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .card()
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hub.recentForSection.isEmpty {
                Text(hub.section == .korean
                     ? "뜻이 궁금한 우리말을 적고 Enter. 동음이의어는 전부 보여줘요."
                     : "영어 단어를 적으면 뜻·발음·예문을, 한국어를 적으면 영어 표현을 보여줘요.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("최근")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                FlowChips(items: hub.recentForSection) { word in hub.lookup(word) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var notFoundCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("'\(hub.searched)' 항목이 없어요")
                .font(.system(size: 13, weight: .semibold))
            if !hub.suggestions.isEmpty {
                Text("혹시 이 단어인가요?")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                FlowChips(items: hub.suggestions) { word in hub.lookup(word) }
            }
            Button {
                hub.openInDictionaryApp()
            } label: {
                Label("사전 앱에서 찾기", systemImage: "book")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var notInstalledCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(hub.currentKind.title)이 아직 없어요")
                    .font(.system(size: 13, weight: .semibold))
                Text("macOS 사전 앱 › 설정에서 해당 사전을 켜면 내려받아져요. 그 다음부터는 오프라인으로 바로 찾을 수 있어요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("사전 앱 열기") { hub.openDictionaryApp() }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }
}

private struct EntryCard: View {
    let headword: String
    let text: String
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(headword)
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text(source)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text(SystemDictionary.prettify(text))
                .font(.system(size: 12))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct OnlineEntryCard: View {
    let entry: OnlineEnglishEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.word)
                    .font(.system(size: 15, weight: .bold))
                if let phonetic = entry.phonetic {
                    Text(phonetic)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("영영 · 온라인")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            ForEach(entry.senses) { sense in
                VStack(alignment: .leading, spacing: 3) {
                    Text(sense.partOfSpeech)
                        .font(.system(size: 11, weight: .semibold))
                        .italic()
                        .foregroundStyle(Theme.accent)
                    ForEach(Array(sense.definitions.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(index + 1). \(item.definition)")
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                            if let example = item.example {
                                Text("“\(example)”")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .card()
    }
}

/// Simple wrapping chip row.
struct FlowChips: View {
    let items: [String]
    let action: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { action(item) } label: {
                    Text(item)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.chipFill(scheme)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Periodic table

private struct PeriodicTableView: View {
    @Bindable var hub: DictionaryHub
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("원소 이름 · 기호 · 번호 (철, Fe, 26)", text: $hub.elementQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { if let first = hub.elementMatches.first { hub.selectElement(first) } }
                if !hub.elementQuery.isEmpty {
                    Button { hub.elementQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .card()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let element = hub.selectedElement {
                        ElementDetailCard(element: element) { hub.selectElement(nil) }
                    } else if !hub.elementQuery.isEmpty {
                        matchesCard
                    }
                    gridCard
                    legend
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var matchesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            let matches = hub.elementMatches
            if matches.isEmpty {
                Text("맞는 원소가 없어요").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
            }
            ForEach(matches.prefix(8)) { element in
                Button { hub.selectElement(element) } label: {
                    HStack(spacing: 10) {
                        Text(element.sym)
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(element.cat.color.opacity(0.35)))
                        Text("\(element.ko) · \(element.en)").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(element.n)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    /// 18 columns × 9.35 rows of cells (7 periods, a gap, lanthanides, actinides) with 2 pt gaps and 8 pt padding.
    private static let gridAspect: CGFloat = 302.0 / 162.9   // (18·14 + 17·2 + 16) / (9.35·14 + 8·2 + 16)

    private static func cellSize(for size: CGSize) -> CGFloat {
        let byWidth = (size.width - 16 - 2 * 17) / 18
        let byHeight = (size.height - 16 - 2 * 8) / 9.35
        return floor(min(byWidth, byHeight))
    }

    private static let gridRows: [Int] = [1, 2, 3, 4, 5, 6, 7, 9, 10]

    private var gridCard: some View {
        GeometryReader { geo in
            let cell = Self.cellSize(for: geo.size)
            VStack(spacing: 2) {
                ForEach(Self.gridRows, id: \.self) { row in
                    PeriodicRow(row: row, cell: cell, hub: hub)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .aspectRatio(Self.gridAspect, contentMode: .fit)
        .card()
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 5) {
            ForEach(ChemicalElement.Category.legend, id: \.self) { category in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(category.color).frame(width: 10, height: 10)
                    Text(category.title).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct PeriodicRow: View {
    let row: Int
    let cell: CGFloat
    let hub: DictionaryHub

    private var elements: [ChemicalElement?] {
        (1...18).map { PeriodicTable.element(atX: $0, y: row) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if row == 9 { Color.clear.frame(height: cell * 0.35) }
            HStack(spacing: 2) {
                ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
                    if let element {
                        cellView(element)
                    } else {
                        Color.clear.frame(width: cell, height: cell)
                    }
                }
            }
        }
    }

    private func cellView(_ element: ChemicalElement) -> some View {
        let query = hub.elementQuery
        let dimmed = !query.isEmpty && !element.matches(query)
        let selected = hub.selectedElement?.n == element.n
        return ElementCell(element: element, size: cell, dimmed: dimmed, selected: selected) {
            hub.selectElement(selected ? nil : element)
        }
    }
}

private struct ElementCell: View {
    let element: ChemicalElement
    let size: CGFloat
    let dimmed: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                if size >= 24 {
                    Text("\(element.n)").font(.system(size: max(5, size * 0.22))).foregroundStyle(.secondary)
                }
                Text(element.sym)
                    .font(.system(size: max(6, size * 0.42), weight: .semibold))
                    .minimumScaleFactor(0.6)
            }
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: max(2, size * 0.15)).fill(element.cat.color.opacity(dimmed ? 0.12 : 0.55)))
            .overlay(RoundedRectangle(cornerRadius: max(2, size * 0.15)).strokeBorder(selected ? Color.primary : Color.clear, lineWidth: 1.5))
            .opacity(dimmed ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .help("\(element.n) \(element.ko) (\(element.en))")
    }
}

private struct ElementDetailCard: View {
    let element: ChemicalElement
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    Text("\(element.n)").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(element.sym).font(.system(size: 22, weight: .bold))
                }
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(element.cat.color.opacity(0.5)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(element.ko).font(.system(size: 16, weight: .bold))
                    Text(element.en).font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(element.cat.title)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(element.cat.color.opacity(0.35)))
                        if !element.alias.isEmpty {
                            Text("옛 이름 " + element.alias.joined(separator: ", "))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 4) {
                row("원자량", element.mass.map { String(format: "%.4g u", $0) } ?? "–")
                row("주기 · 족 · 블록", "\(element.period)주기 · \(element.group.map { "\($0)족" } ?? "–") · \(element.block ?? "-")블록")
                row("실온 상태", element.phaseKorean)
                row("전자 배치", element.config ?? "–")
                row("전기음성도", element.eneg.map { String(format: "%.2f", $0) } ?? "–")
                row("밀도", element.density.map { String(format: "%.4g %@", $0, element.phase == "Gas" ? "g/L" : "g/cm³") } ?? "–")
                row("녹는점 · 끓는점", "\(element.melt.map(PeriodicTable.kelvinToCelsius) ?? "–") · \(element.boil.map(PeriodicTable.kelvinToCelsius) ?? "–")")
                row("발견", element.found ?? "–")
            }
            HStack {
                Spacer()
                Button {
                    if let url = URL(string: "https://ko.wikipedia.org/wiki/\(element.ko.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? element.ko)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("위키백과", systemImage: "safari").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(.system(size: 12)).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
