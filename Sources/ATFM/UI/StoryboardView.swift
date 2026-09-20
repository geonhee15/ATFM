import SwiftUI

struct StoryboardView: View {
    @Bindable var store: StoryboardStore
    var inWindow = false
    @Environment(\.colorScheme) private var scheme
    @State private var renaming = false
    @State private var titleDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            boardBar
            SceneToolbar(store: store)
            canvasCard
            if let item = store.selectedItem, store.tool == .select {
                ItemInspector(store: store, item: item)
            }
            sceneNoteField
            SceneStrip(store: store)
            MusicCard(store: store)
        }
        .padding(.horizontal, inWindow ? 20 : 0)
        .padding(.vertical, inWindow ? 16 : 0)
        .frame(maxWidth: inWindow ? 1100 : .infinity)
    }

    // MARK: Board bar

    private var boardBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(store.boards) { board in
                    Button { store.selectedBoardID = board.id } label: {
                        if board.id == store.selectedBoardID { Label(board.title, systemImage: "checkmark") } else { Text(board.title) }
                    }
                }
                Divider()
                Button("새 스토리보드") { store.addBoard() }
                Button("이름 바꾸기…") { titleDraft = store.board?.title ?? ""; renaming = true }
                Button("이 스토리보드 삭제", role: .destructive) { store.deleteBoard() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "film.stack").font(.system(size: 12, weight: .medium))
                    Text(store.board?.title ?? "스토리보드").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .popover(isPresented: $renaming, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("스토리보드 이름").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("이름", text: $titleDraft).textFieldStyle(.roundedBorder).frame(width: 220)
                        .onSubmit { store.rename(titleDraft); renaming = false }
                    HStack { Spacer(); Button("완료") { store.rename(titleDraft); renaming = false }.controlSize(.small).keyboardShortcut(.defaultAction) }
                }
                .padding(12)
            }
            Spacer()
            Text("\(store.scenes.count)개 장면").font(.system(size: 11)).foregroundStyle(.tertiary)
            if !inWindow {
                Button { store.openWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("큰 창으로 열기")
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: Canvas

    private var canvasCard: some View {
        let scene = store.displayedScene ?? StoryScene()
        let ratio = scene.aspect.ratio
        return VStack(spacing: 6) {
            Color.clear
                .aspectRatio(ratio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: inWindow ? 520 : 300)
                .overlay {
                    SceneCanvas(scene: scene, store: store, interactive: !store.isPlaying)
                }
                .overlay(alignment: .topLeading) {
                    if store.isPlaying, let index = store.playbackSceneIndex {
                        Text(store.sceneTitle(index)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.55))).padding(6)
                    }
                }
                .frame(maxWidth: .infinity)
            HStack {
                if let index = store.sceneIndex, !store.isPlaying {
                    Text("\(store.sceneTitle(index)) · \(scene.aspect.rawValue)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    if let range = store.board?.segment(of: index) {
                        Text("· \(Self.mmss(range.lowerBound))–\(Self.mmss(range.upperBound))").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Text(store.tool == .pen ? "드래그해서 그리기" : store.tool == .text ? "클릭한 곳에 텍스트 추가" : "드래그로 이동 · 모서리로 크기 조절")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
        }
    }

    private var sceneNoteField: some View {
        TextField("이 장면에서 일어나는 일 · 대사 · 카메라 메모", text: Binding(
            get: { store.scene?.note ?? "" },
            set: { text in store.updateScene { $0.note = text } }))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .card()
    }

    static func mmss(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Toolbar

private struct SceneToolbar: View {
    @Bindable var store: StoryboardStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $store.tool) {
                    ForEach(StoryboardStore.Tool.allCases) { tool in Image(systemName: tool.symbol).tag(tool) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 120)
                .help("선택 / 펜 / 텍스트")
                Menu {
                    ForEach(ItemKind.allCases.filter { $0 != .text }) { kind in
                        Button { store.tool = .select; store.addItem(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                } label: {
                    Label("도형", systemImage: "plus.square.on.square").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                ColorPicker("", selection: Binding(
                    get: { store.scene?.background.color ?? .white },
                    set: { color in store.updateScene { $0.background = RGBA(color) } }), supportsOpacity: false)
                    .labelsHidden().controlSize(.small).help("배경색")
                Menu {
                    ForEach(AspectPreset.allCases) { preset in
                        Button { store.updateScene { $0.aspect = preset } } label: {
                            if store.scene?.aspect == preset { Label("\(preset.rawValue) · \(preset.subtitle)", systemImage: "checkmark") }
                            else { Text("\(preset.rawValue) · \(preset.subtitle)") }
                        }
                    }
                    Divider()
                    Button("모든 장면에 적용") {
                        guard let aspect = store.scene?.aspect else { return }
                        for scene in store.scenes { store.selectedSceneID = scene.id; store.updateScene { $0.aspect = aspect } }
                    }
                } label: {
                    Text(store.scene?.aspect.rawValue ?? "16:9").font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .menuStyle(.borderlessButton).fixedSize().help("화면 비율")
            }
            if store.tool == .pen {
                HStack(spacing: 6) {
                    ForEach(Array(RGBA.palette.enumerated()), id: \.offset) { _, swatch in
                        Circle().fill(swatch.color).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(store.penColor == swatch ? 0.8 : 0), lineWidth: 2))
                            .onTapGesture { store.penColor = swatch }
                    }
                    Circle().fill(RGBA.ink.color).frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(store.penColor == .ink ? 0.8 : 0), lineWidth: 2))
                        .onTapGesture { store.penColor = .ink }
                    ColorPicker("", selection: Binding(get: { store.penColor.color }, set: { store.penColor = RGBA($0) }), supportsOpacity: false)
                        .labelsHidden().controlSize(.mini)
                    Spacer()
                    Picker("", selection: $store.penWidth) {
                        Text("얇게").tag(0.004)
                        Text("보통").tag(0.008)
                        Text("굵게").tag(0.016)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 120)
                    Button { store.undoStroke() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.plain).foregroundStyle(.secondary).help("마지막 선 지우기")
                    Button { store.clearStrokes() } label: { Image(systemName: "eraser") }.buttonStyle(.plain).foregroundStyle(.secondary).help("선 모두 지우기")
                }
                .font(.system(size: 11))
            }
        }
    }
}

// MARK: - Inspector

private struct ItemInspector: View {
    @Bindable var store: StoryboardStore
    let item: SceneItem

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.kind.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 16)
                if item.kind == .text {
                    TextField("텍스트", text: Binding(get: { item.text }, set: { text in store.updateItem(item.id) { $0.text = text } }))
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                } else {
                    Text(item.kind.title).font(.system(size: 12, weight: .medium))
                    Toggle("채우기", isOn: Binding(get: { item.filled }, set: { on in store.updateItem(item.id) { $0.filled = on } }))
                        .toggleStyle(.checkbox).controlSize(.small)
                    Spacer()
                }
                ColorPicker("", selection: Binding(get: { item.color.color }, set: { color in store.updateItem(item.id) { $0.color = RGBA(color) } }), supportsOpacity: true)
                    .labelsHidden().controlSize(.small)
                Button { store.bringToFront(item.id) } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("맨 앞으로")
                Button { store.deleteItem(item.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.red.opacity(0.8)).help("삭제")
            }
            HStack(spacing: 10) {
                sliderRow("너비", value: Binding(get: { item.w }, set: { v in store.updateItem(item.id) { $0.w = v } }), range: 0.04...1)
                sliderRow("높이", value: Binding(get: { item.h }, set: { v in store.updateItem(item.id) { $0.h = v } }), range: 0.04...1)
                if item.kind == .text {
                    sliderRow("글자", value: Binding(get: { item.fontSize }, set: { v in store.updateItem(item.id) { $0.fontSize = v } }), range: 0.03...0.3)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .card()
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Slider(value: value, in: range).controlSize(.mini)
        }
    }
}

// MARK: - Canvas

struct SceneCanvas: View {
    let scene: StoryScene
    var store: StoryboardStore?
    var interactive: Bool

    @State private var currentStroke: [Double] = []
    @State private var dragItemID: UUID?
    @State private var dragOrigin = CGPoint.zero
    @State private var dragStart = CGPoint.zero
    @State private var dragBegan = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                scene.background.color
                ForEach(scene.items) { item in
                    SceneItemView(item: item, size: size)
                }
                StrokesLayer(strokes: scene.strokes, current: currentStroke, currentColor: store?.penColor ?? .ink,
                             currentWidth: store?.penWidth ?? 0.008, size: size)
                    .allowsHitTesting(false)
                if interactive, let store, store.tool == .select, let item = store.selectedItem {
                    SelectionOverlay(item: item, size: size, store: store)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .gesture(canvasGesture(size: size), including: interactive && store != nil ? .all : .none)
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private func normalized(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, point.x / max(size.width, 1)), 1), y: min(max(0, point.y / max(size.height, 1)), 1))
    }

    private func hitTest(_ p: CGPoint) -> SceneItem? {
        scene.items.reversed().first { item in
            abs(p.x - item.x) <= item.w / 2 + 0.01 && abs(p.y - item.y) <= item.h / 2 + 0.01
        }
    }

    private func canvasGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard let store else { return }
                let p = normalized(value.location, size)
                switch store.tool {
                case .pen:
                    if currentStroke.isEmpty {
                        currentStroke = [p.x, p.y]
                    } else {
                        let lx = currentStroke[currentStroke.count - 2], ly = currentStroke[currentStroke.count - 1]
                        if hypot(p.x - lx, p.y - ly) > 0.003 { currentStroke.append(contentsOf: [p.x, p.y]) }
                    }
                case .select:
                    if !dragBegan {
                        dragBegan = true
                        dragStart = p
                        if let hit = hitTest(p) {
                            dragItemID = hit.id
                            dragOrigin = CGPoint(x: hit.x, y: hit.y)
                            store.selectedItemID = hit.id
                        } else {
                            dragItemID = nil
                            store.selectedItemID = nil
                        }
                    }
                    if let id = dragItemID {
                        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
                        store.updateItem(id) { $0.x = min(max(0, dragOrigin.x + dx), 1); $0.y = min(max(0, dragOrigin.y + dy), 1) }
                    }
                case .text:
                    break
                }
            }
            .onEnded { value in
                guard let store else { return }
                let p = normalized(value.location, size)
                switch store.tool {
                case .pen:
                    if currentStroke.count == 2 { currentStroke.append(contentsOf: [p.x + 0.002, p.y + 0.002]) }
                    store.addStroke(Stroke(points: currentStroke, color: store.penColor, width: store.penWidth))
                    currentStroke = []
                case .select:
                    dragBegan = false
                    dragItemID = nil
                case .text:
                    store.addItem(.text, at: p)
                    store.tool = .select
                }
            }
    }
}

private struct SelectionOverlay: View {
    let item: SceneItem
    let size: CGSize
    let store: StoryboardStore

    var body: some View {
        let w = item.w * size.width, h = item.h * size.height
        let cx = item.x * size.width, cy = item.y * size.height
        ZStack {
            Rectangle()
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: w + 6, height: h + 6)
                .position(x: cx, y: cy)
                .allowsHitTesting(false)
            Circle()
                .fill(Theme.accent)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                .frame(width: 12, height: 12)
                .position(x: cx + w / 2 + 3, y: cy + h / 2 + 3)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            let px = min(max(0, value.location.x / max(size.width, 1)), 1)
                            let py = min(max(0, value.location.y / max(size.height, 1)), 1)
                            store.updateItem(item.id) { current in
                                current.w = max(0.04, (px - current.x) * 2)
                                current.h = max(0.04, (py - current.y) * 2)
                            }
                        }
                )
        }
    }
}

private struct StrokesLayer: View {
    let strokes: [Stroke]
    let current: [Double]
    let currentColor: RGBA
    let currentWidth: Double
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            for stroke in strokes { draw(stroke.points, color: stroke.color, width: stroke.width, in: &context, size: canvasSize) }
            if current.count >= 2 { draw(current, color: currentColor, width: currentWidth, in: &context, size: canvasSize) }
        }
    }

    private func draw(_ points: [Double], color: RGBA, width: Double, in context: inout GraphicsContext, size: CGSize) {
        guard points.count >= 2 else { return }
        var path = Path()
        path.move(to: CGPoint(x: points[0] * size.width, y: points[1] * size.height))
        var index = 2
        while index + 1 < points.count {
            path.addLine(to: CGPoint(x: points[index] * size.width, y: points[index + 1] * size.height))
            index += 2
        }
        if points.count == 2 { path.addLine(to: CGPoint(x: points[0] * size.width + 0.5, y: points[1] * size.height)) }
        context.stroke(path, with: .color(color.color), style: StrokeStyle(lineWidth: max(1, width * size.height), lineCap: .round, lineJoin: .round))
    }
}

struct SceneItemView: View {
    let item: SceneItem
    let size: CGSize

    var body: some View {
        let w = max(2, item.w * size.width), h = max(2, item.h * size.height)
        Group {
            switch item.kind {
            case .text:
                Text(item.text.isEmpty ? " " : item.text)
                    .font(.system(size: max(4, item.fontSize * size.height), weight: .bold))
                    .foregroundStyle(item.color.color)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.3)
                    .frame(width: w, height: h)
            case .rect: shape(Rectangle())
            case .roundedRect: shape(RoundedRectangle(cornerRadius: min(w, h) * 0.2, style: .continuous))
            case .ellipse: shape(Ellipse())
            case .triangle: shape(TriangleShape())
            case .arrow: shape(ArrowShape())
            case .star: shape(StarShape())
            }
        }
        .frame(width: w, height: h)
        .position(x: item.x * size.width, y: item.y * size.height)
    }

    @ViewBuilder
    private func shape<S: Shape>(_ s: S) -> some View {
        if item.filled {
            s.fill(item.color.color)
        } else {
            s.stroke(item.color.color, lineWidth: max(1.5, size.height * 0.008))
        }
    }
}

struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let shaft = rect.height * 0.4
        let headStart = rect.maxX - rect.width * 0.4
        path.move(to: CGPoint(x: rect.minX, y: rect.midY - shaft / 2))
        path.addLine(to: CGPoint(x: headStart, y: rect.midY - shaft / 2))
        path.addLine(to: CGPoint(x: headStart, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: headStart, y: rect.maxY))
        path.addLine(to: CGPoint(x: headStart, y: rect.midY + shaft / 2))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY + shaft / 2))
        path.closeSubpath()
        return path
    }
}

struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2, inner = outer * 0.45
        for i in 0..<10 {
            let radius = i % 2 == 0 ? outer : inner
            let angle = (Double(i) * 36 - 90) * .pi / 180
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Scene strip

private struct SceneStrip: View {
    @Bindable var store: StoryboardStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(store.scenes.enumerated()), id: \.element.id) { index, scene in
                    thumbnail(index: index, scene: scene)
                }
                Button { store.addScene() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                        Text("장면 추가").font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 96, height: 54)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill(scheme)))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
    }

    private func thumbnail(index: Int, scene: StoryScene) -> some View {
        let selected = scene.id == store.scene?.id
        let playing = store.isPlaying && store.playbackSceneIndex == index
        return VStack(spacing: 3) {
            SceneCanvas(scene: scene, store: nil, interactive: false)
                .frame(width: 96, height: max(30, min(96, 96 / scene.aspect.ratio)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(playing ? Color.orange : (selected ? Theme.accent : Color.clear), lineWidth: 2))
            HStack(spacing: 3) {
                Text(store.sceneTitle(index)).font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                if let range = store.board?.segment(of: index) {
                    Text(StoryboardView.mmss(range.upperBound - range.lowerBound)).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selectedSceneID = scene.id; if store.music != nil { store.seek(toScene: index) } }
        .contextMenu {
            Button("복제") { store.duplicateScene(scene.id) }
            Button("왼쪽으로") { store.moveScene(scene.id, by: -1) }.disabled(index == 0)
            Button("오른쪽으로") { store.moveScene(scene.id, by: 1) }.disabled(index == store.scenes.count - 1)
            Divider()
            Button("내용 비우기") { store.selectedSceneID = scene.id; store.clearScene() }
            Button("삭제", role: .destructive) { store.deleteScene(scene.id) }.disabled(store.scenes.count <= 1)
        }
    }
}

// MARK: - Music & timeline

private struct MusicCard: View {
    @Bindable var store: StoryboardStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let music = store.music {
                HStack(spacing: 8) {
                    Button { store.togglePlay() } label: {
                        Image(systemName: store.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 22))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(music.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(StoryboardView.mmss(store.currentTime)) / \(StoryboardView.mmss(music.duration))" + currentSceneText)
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("다른 음악 고르기…") { store.chooseMusic() }
                        Button("장면 시간 균등 배분") { store.distributeEvenly() }
                        Divider()
                        Button("음악 제거", role: .destructive) { store.removeMusic() }
                    } label: { Image(systemName: "ellipsis.circle").font(.system(size: 14)) }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                }
                Timeline(store: store, music: music)
                    .frame(height: 58)
                Text("구분선을 끌어서 장면이 바뀌는 시점을 정하고, 장면을 누르면 그 구간으로 이동해요.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "music.note").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("배경음악 추가").font(.system(size: 12, weight: .medium))
                        Text("음악을 넣으면 타임라인에서 장면별 구간을 나눠 흐름을 볼 수 있어요").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("파일 고르기") { store.chooseMusic() }.controlSize(.small)
                }
            }
            if let error = store.musicError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card()
    }

    private var currentSceneText: String {
        guard let index = store.playbackSceneIndex, store.music != nil else { return "" }
        return " · \(store.sceneTitle(index))"
    }
}

private struct Timeline: View {
    @Bindable var store: StoryboardStore
    let music: MusicTrack

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width, height = geo.size.height
            let duration = max(music.duration, 0.001)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05))
                waveform(width: width, height: height)
                ForEach(store.scenes.indices, id: \.self) { index in
                    if let range = store.board?.segment(of: index) {
                        let x = range.lowerBound / duration * width
                        let w = max(1, (range.upperBound - range.lowerBound) / duration * width)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(RGBA.palette[index % RGBA.palette.count].color.opacity(store.playbackSceneIndex == index && store.isPlaying ? 0.5 : 0.28))
                            .frame(width: w, height: height)
                            .overlay(alignment: .topLeading) {
                                Text(w > 60 ? "S\(index + 1) \(StoryboardView.mmss(range.lowerBound))" : "S\(index + 1)")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.primary.opacity(0.8))
                                    .padding(.horizontal, 4).padding(.top, 3)
                            }
                            .offset(x: x)
                            .onTapGesture { store.selectedSceneID = store.scenes[index].id; store.seek(to: range.lowerBound) }
                    }
                }
                ForEach(music.cuts.indices, id: \.self) { cutIndex in
                    let x = music.cuts[cutIndex] / duration * width
                    Capsule().fill(Color.primary.opacity(0.75))
                        .frame(width: 4, height: height - 6)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                        .padding(.horizontal, 5)
                        .contentShape(Rectangle())
                        .offset(x: x - 7, y: 3)
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline")).onChanged { value in
                            store.setCut(cutIndex, time: value.location.x / width * duration)
                        })
                }
                Rectangle().fill(Color.red).frame(width: 2, height: height)
                    .offset(x: store.currentTime / duration * width - 1)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "timeline")
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("timeline")).onChanged { value in
                store.seek(to: value.location.x / width * duration)
            })
        }
    }

    private func waveform(width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            let bars = store.waveform
            guard !bars.isEmpty else { return }
            let step = size.width / CGFloat(bars.count)
            for (index, value) in bars.enumerated() {
                let h = max(1, CGFloat(value) * (size.height - 16))
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - h) / 2 + 4, width: max(1, step - 1), height: h)
                context.fill(Path(rect), with: .color(Color.primary.opacity(0.22)))
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}
