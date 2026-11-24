import SwiftUI

private enum RelationLabel {
    static let web = "Web Links"
    static let quote = "Quotes"
}

enum RelationTarget: Hashable {
    case entry(String), quote(Anchor), asset(String), document(String)
}

struct RelationMenu: View {
    @ObservedObject var model: Workspace
    let entry: Entry
    let target: RelationTarget

    @ViewBuilder var body: some View {
        switch target {
        case .entry(let id):
            if let other = model.snapshot.resolve(id),
               !Set(entry.links).isDisjoint(with: [other.id] + other.aliases) ||
               !Set(other.links).isDisjoint(with: [entry.id] + entry.aliases) {
                Button("解除手动关联") { model.attempt { try model.setRelation(from: entry.id, to: id, present: false) } }
            }
        case .quote(let anchor):
            if entry.anchors.contains(anchor) {
                Button("解除这处引文关联") { model.attempt { try model.removeSourceRelation(.quote(anchor), from: entry.id) } }
            }
        case .document(let path):
            if entry.reportLinks.contains(path) || entry.anchors.contains(where: { $0.report == path }) {
                Button("解除与此文档的关联") { model.attempt { try model.removeSourceRelation(.document(path), from: entry.id) } }
            }
        case .asset(let path):
            Button("解除资料关联") { model.attempt { try model.removeSourceRelation(.asset(path), from: entry.id) } }
            if path.hasPrefix("library:") { Button("查看反链") { model.dialog = .backlinks(path) } }
        }
    }
}

private struct RelationNode: Identifiable {
    var target: RelationTarget
    var title: String
    var typeLabel: String
    var detail: String
    var icon: RelationIcon
    var id: RelationTarget { target }
}

struct EntryRelations: View {
    @ObservedObject var model: Workspace
    let entry: Entry
    let graphWidth: CGFloat
    @AppStorage("entryRelationsList") private var list = false
    @State private var hovered: RelationTarget?
    @State private var enlarged = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var nodes: [RelationNode] {
        var related = model.snapshot.related(to: entry)
        let existing = Set(related.map(\.id))
        let citing = model.snapshot.citations[entry.id] ?? []
        related += model.snapshot.entries.filter { other in
            other.id != entry.id && !existing.contains(other.id) &&
            (citing.contains(other.path) || (other.kind == .references && model.snapshot.citations[other.id]?.contains(entry.path) == true))
        }
        func node(for other: Entry) -> RelationNode {
            let web = other.kind == .references && model.snapshot.isWebReference(other)
            let typeLabel = web ? RelationLabel.web : other.kind.englishLabel
            return RelationNode(target: .entry(other.id), title: other.title, typeLabel: typeLabel,
                         detail: other.kind == .questions ? typeLabel + (other.answered ? " · 已回答" : " · 待回答") : typeLabel,
                         icon: web ? .web : RelationIcon(other.kind))
        }
        var result = related.filter { $0.kind == .questions }.map(node)
        var seen = Set<Anchor>()
        func add(_ anchor: Anchor, owner: String? = nil) {
            guard seen.insert(anchor).inserted else { return }
            let source = [documentLabel(anchor.report), anchor.section].filter { !$0.isEmpty }.joined(separator: " · ")
            let label = owner.map { $0 + "的出处" } ?? (anchor.report.hasPrefix("reports/") ? "报告原文" : "原文出处")
            result.append(RelationNode(target: .quote(anchor), title: anchor.quote, typeLabel: RelationLabel.quote, detail: [RelationLabel.quote, label, source].filter { !$0.isEmpty }.joined(separator: " · "),
                                       icon: .quote))
        }
        for anchor in entry.anchors { add(anchor) }
        if entry.kind == .questions && !entry.anchors.contains(where: { $0.report.hasPrefix("reports/") }) {
            for other in related where [.entities, .concepts, .events].contains(other.kind) {
                for anchor in other.anchors where anchor.report.hasPrefix("reports/") { add(anchor, owner: other.title) }
            }
        }
        result += related.filter { $0.kind != .questions }.map(node)
        let documents = Set(entry.reportLinks).union(entry.kind == .references ? citing : [])
        for path in documents.sorted() where model.snapshot.entry(at: path) == nil && model.valid(.doc(path)) {
            let category = PageCategory(document: path)
            result.append(RelationNode(target: .document(path), title: documentLabel(path), typeLabel: category.label,
                                       detail: category.label, icon: path == "memo.md" ? .memo : .report))
        }
        if entry.kind == .references { return result }
        for asset in Set(entry.assets).sorted() {
            if let ref = model.snapshot.reference(for: asset, from: entry.path), related.contains(where: { $0.id == ref.id }) { continue }
            let icon = RelationIcon(material: asset)
            let typeLabel = icon == .web ? RelationLabel.web : (icon == .library ? "Library Items" : "Attachments")
            result.append(RelationNode(target: .asset(asset), title: (asset as NSString).lastPathComponent,
                                       typeLabel: typeLabel, detail: typeLabel,
                                       icon: icon))
        }
        return result
    }

    private func open(_ target: RelationTarget) {
        switch target {
        case .entry(let id): model.go(.entry(id))
        case .document(let path): model.go(.doc(path))
        case .quote(let anchor):
            if model.valid(.doc(anchor.report)) { model.go(.doc(anchor.report), anchor: anchor) }
            else { model.error = "出处文件尚未同步或已移走。" }
        case .asset(let path): model.attempt {
            if let ref = model.snapshot.reference(for: path, from: entry.path) { model.go(.entry(ref.id)) }
            else if model.snapshot.unlistedMaterials.contains(path) { model.go(.entry(try model.registerMaterial(path).id)) }
            else { try model.openMaterial(path) }
        }
        }
    }

    var body: some View {
        let items = nodes
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    heading(count: items.count)
                    Spacer(minLength: 8)
                    viewPicker
                }
                VStack(alignment: .leading, spacing: 6) {
                    heading(count: items.count)
                    viewPicker
                }
            }
            if items.isEmpty {
                Text("暂无关联").font(.callout).foregroundStyle(.secondary)
            } else if list {
                ScrollView {
                    LazyVStack(spacing: 4) { ForEach(items) { node in nodeButton(node, lines: nil) } }
                }.frame(height: CGFloat(items.count) * 53)
            } else {
                network(items)
            }
        }.onChange(of: entry.id) { _, _ in hovered = nil; enlarged = false }
    }

    private func heading(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("关联").font(.headline)
            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(leaf)
            if [.concepts, .entities, .events].contains(entry.kind) {
                Button("新建问题") {
                    var question = Entry(kind: .questions, title: "")
                    question.links = [entry.id]
                    model.dialog = .editor(Editor(entry: question))
                }.buttonStyle(.link).font(.caption)
            }
        }.fixedSize()
    }

    private var viewPicker: some View {
        HStack(spacing: 2) {
            viewTab("关系图", isList: false)
            viewTab("列表", isList: true)
        }.padding(2).background(Color(white: 0.88), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain).accessibilityLabel("关联视图")
    }

    private func viewTab(_ title: String, isList: Bool) -> some View {
        let selected = list == isList
        return Button { list = isList } label: {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(Color(white: selected ? 0.18 : 0.36))
                .frame(minWidth: 45, minHeight: 22)
                .background(selected ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
        .onMoveCommand { direction in
            if direction == .left { list = false }
            if direction == .right { list = true }
        }
    }

    private func nodeButton(_ node: RelationNode, lines: Int?) -> some View {
        Button { open(node.target) } label: {
            HStack(spacing: 8) {
                RelationEmblem(icon: node.icon, size: 27)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(.system(size: 12, weight: .medium)).foregroundStyle(ink).lineLimit(lines)
                    Text(node.detail).font(.system(size: 10)).foregroundStyle(node.icon.color).lineLimit(1)
                }.multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(SidebarLinkStyle(horizontalInset: 0, verticalInset: 0))
        .background(Color.white.opacity(0.87), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.gray.opacity(0.24)).allowsHitTesting(false) }
        .help(node.title + "\n" + node.detail)
        .contextMenu { RelationMenu(model: model, entry: entry, target: node.target) }
    }

    private func network(_ items: [RelationNode]) -> some View {
        // Resolve the graph once, including links through pre-merge identifiers.
        let peers = Dictionary(uniqueKeysWithValues: model.snapshot.entries.map { ($0.id, $0) })
        var indexByID: [String: Int] = [:]
        for (i, node) in items.enumerated() {
            if case .entry(let id) = node.target, let peer = peers[id] {
                for key in [id] + peer.aliases { indexByID[key] = i }
            }
        }
        var edges = Set<PeerEdge>()
        for (i, node) in items.enumerated() {
            if case .entry(let id) = node.target, let peer = peers[id] {
                for link in peer.links {
                    if let j = indexByID[link], i != j { edges.insert(PeerEdge(i, j)) }
                }
            }
        }
        let layout = RelationLayout(count: items.count, width: graphWidth)
        let selected = items.firstIndex { $0.id == hovered }
        let overview = min(1, 680 / layout.height)
        // Only very large graphs use a fit-to-height overview; width selects an actual layout.
        let scale = enlarged ? 1 : overview
        return ZStack(alignment: .topTrailing) {
                    ZStack {
                        Canvas { context, _ in
                            for edge in edges {
                                let a = layout.points[edge.first], b = layout.points[edge.second]
                                let path = layout.peerLink(from: a, to: b)
                                let highlighted = selected == edge.first || selected == edge.second
                                context.stroke(path, with: .color(.secondary.opacity(highlighted ? 0.65 : 0.26)),
                                               style: StrokeStyle(lineWidth: highlighted ? 1.5 : 1, dash: [2, 4]))
                            }
                            for (i, point) in layout.points.enumerated() {
                                let path = layout.branch(to: point)
                                let highlighted = selected == i
                                let stroke = highlighted ? items[i].icon.color : Color(.sRGB, white: selected == nil ? 0.78 : 0.86, opacity: 1)
                                context.stroke(path, with: .color(stroke), lineWidth: highlighted ? 1.8 : 1.1)
                            }
                            // Clear the line layer under the translucent icon plates.
                            context.blendMode = .destinationOut
                            func clearNode(at point: CGPoint, size: CGFloat) {
                                let bounds = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                                context.fill(Path(roundedRect: bounds, cornerRadius: size * 0.28, style: .continuous), with: .color(.black))
                            }
                            clearNode(at: layout.center, size: RelationEmblem.hubSize)
                            for point in layout.points { clearNode(at: point, size: RelationEmblem.nodeSize) }
                        }.allowsHitTesting(false).accessibilityHidden(true)
                        hub(compact: layout.narrow).position(layout.center)
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, node in
                            let point = layout.points[i]
                            let left = !layout.narrow && point.x < layout.center.x
                            let labelWidth = layout.labelWidth(at: point)
                            orbitNode(node, left: left, labelWidth: labelWidth)
                                .position(x: point.x + (left ? -1 : 1) * (labelWidth + 8) / 2, y: point.y)
                        }
                    }
                    .frame(width: layout.width, height: layout.height)
                    .scaleEffect(scale, anchor: .top)
                    .frame(width: layout.width, height: layout.height * scale, alignment: .top)
                if overview < 1 {
                    Button { enlarged.toggle() } label: {
                        Image(systemName: enlarged ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass")
                    }.buttonStyle(.borderless).help(enlarged ? "显示全部关联" : "放大查看，可滚动浏览")
                    .accessibilityLabel(enlarged ? "显示全部关联" : "放大关系图")
                }
        }
    }

    private func hub(compact: Bool) -> some View {
        let typeLabel = "当前 · " + entry.kind.englishLabel
        return RelationEmblem(icon: RelationIcon(entry.kind), size: RelationEmblem.hubSize, isHub: true)
            .overlay(alignment: compact ? .leading : .top) {
                VStack(alignment: compact ? .leading : .center, spacing: 2) {
                    Text(typeLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(RelationIcon(entry.kind).color)
                    Text(entry.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                        .multilineTextAlignment(compact ? .leading : .center).lineLimit(2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: compact ? graphWidth - 63 : 110, alignment: compact ? .leading : .center)
                .background(paper)
                .offset(x: compact ? 51 : 0, y: compact ? 0 : 45)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(typeLabel + "，" + entry.title).help(typeLabel + "\n" + entry.title)
    }

    private func orbitNode(_ node: RelationNode, left: Bool, labelWidth: CGFloat) -> some View {
        let active = hovered == node.id
        let dot = RelationEmblem(icon: node.icon, size: RelationEmblem.nodeSize)
        let label = VStack(alignment: left ? .trailing : .leading, spacing: 2) {
            Text(node.typeLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(node.icon.color)
            Text(node.title).font(.system(size: 13, weight: active ? .semibold : .medium))
                .foregroundStyle(ink).lineLimit(2)
                .multilineTextAlignment(left ? .trailing : .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: labelWidth, alignment: left ? .trailing : .leading)
        return Button { open(node.target) } label: {
            HStack(spacing: 8) {
                if left { label }
                dot
                if !left { label }
            }.frame(height: 48).contentShape(Rectangle())
                .background(active ? leaf.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                if inside { hovered = node.id } else if active { hovered = nil }
            }
        }.help(node.title + "\n" + node.detail)
        .accessibilityLabel(node.title + "，" + node.detail)
        .contextMenu { RelationMenu(model: model, entry: entry, target: node.target) }
    }
}

private struct PeerEdge: Hashable {
    let first: Int
    let second: Int
    init(_ a: Int, _ b: Int) { first = min(a, b); second = max(a, b) }
}

private struct RelationLayout {
    let width: CGFloat
    let height: CGFloat
    let center: CGPoint
    let points: [CGPoint]
    let narrow: Bool
    private let radial: Bool

    init(count: Int, width: CGFloat) {
        self.width = width
        narrow = width < 400
        radial = width >= 560
        let rows = (count + 1) / 2
        if narrow {
            height = CGFloat(count) * 57 + 65
            center = CGPoint(x: 24, y: 27)
            points = (0..<count).map { CGPoint(x: 53, y: 80 + CGFloat($0) * 57) }
        } else if !radial {
            height = 94 + CGFloat(rows) * 73
            center = CGPoint(x: width / 2, y: 29)
            points = (0..<count).map { i in
                let side: CGFloat = i.isMultiple(of: 2) ? -1 : 1
                return CGPoint(x: width / 2 + side * 37,
                               y: 116 + CGFloat(i / 2) * 73 + (side > 0 ? 15 : 0))
            }
        } else {
            let h = CGFloat(max(3, rows) - 1) * 76 + 112
            height = h
            center = CGPoint(x: width / 2, y: h / 2)
            points = (0..<count).map { i in
                let left = i < rows
                let n = left ? rows : count - rows
                let row = left ? i : i - rows
                let y = CGFloat(2 * row - n + 1) * 38
                let t = y / (h / 2 - 12)
                let dx = max(82, width * 0.18 * sqrt(max(0.2, 1 - t * t)))
                return CGPoint(x: width / 2 + (left ? -dx : dx), y: h / 2 + y)
            }
        }
    }

    func labelWidth(at point: CGPoint) -> CGFloat {
        let space = narrow || point.x >= center.x ? width - point.x : point.x
        return max(55, space - 29)
    }

    func peerLink(from a: CGPoint, to b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        if (a.x < center.x) == (b.x < center.x) {
            // Take the dotted link inside the column, clear of intervening tiles and labels.
            let left = a.x < center.x
            let lane = narrow ? 7 : (left ? min(center.x - 8, max(a.x, b.x) + 29)
                                         : max(center.x + 8, min(a.x, b.x) - 29))
            let turn = min(20, abs(b.y - a.y) / 3) * (a.y < b.y ? 1 : -1)
            path.addQuadCurve(to: CGPoint(x: lane, y: a.y + turn), control: CGPoint(x: lane, y: a.y))
            path.addLine(to: CGPoint(x: lane, y: b.y - turn))
            path.addQuadCurve(to: b, control: CGPoint(x: lane, y: b.y))
        } else {
            path.addLine(to: b)
        }
        return path
    }

    func branch(to point: CGPoint) -> Path {
        var path = Path()
        path.move(to: center)
        if radial {
            let shoulder = center.x + (point.x < center.x ? -1 : 1) * 60
            let mid = (shoulder + point.x) / 2
            path.addLine(to: CGPoint(x: shoulder, y: center.y))
            path.addCurve(to: point, control1: CGPoint(x: mid, y: center.y), control2: CGPoint(x: mid, y: point.y))
        } else {
            let turn = min(23, abs(point.x - center.x) * 0.7)
            path.addLine(to: CGPoint(x: center.x, y: point.y - turn))
            path.addQuadCurve(to: point, control: CGPoint(x: center.x, y: point.y))
        }
        return path
    }
}
