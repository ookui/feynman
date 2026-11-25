import SwiftUI

enum PageCategory {
    case stock, project, report, kind(Kind), webLinks, log, memo, images, documents

    var graphFilterKey: String {
        switch self {
        case .kind(let kind): return kind.rawValue
        case .webLinks: return Kind.references.rawValue
        default: return label
        }
    }

    static let defaultHiddenGraphFilters: Set<String> = [
        PageCategory.images.graphFilterKey, PageCategory.report.graphFilterKey,
        Kind.events.rawValue, Kind.references.rawValue
    ]

    init(document path: String) {
        switch path {
        case "log.md": self = .log
        case "memo.md": self = .memo
        default: self = path.hasPrefix("reports/") ? .report : .kind(.references)
        }
    }

    var label: String {
        switch self {
        case .images: return "Images"
        case .documents: return "Documents"
        case .stock: return "Stocks"
        case .project: return "Project"
        case .report: return "Reports"
        case .kind(let kind): return kind.englishLabel
        case .webLinks: return "Web Links"
        case .log: return "Log"
        case .memo: return "Memo"
        }
    }

    private var rgb: UInt32 {
        switch self {
        case .stock: return 0x197A67
        case .project: return 0xD72E78
        case .report: return 0x718615
        case .kind(.questions): return 0xC76509
        case .kind(.concepts): return 0xA53EC6
        case .kind(.entities): return 0x2464F5
        case .kind(.events): return 0x8054DC
        case .kind(.references), .images, .documents: return 0x2679CB
        case .webLinks: return 0x00858C
        case .log: return 0x16855D
        case .memo: return 0xBC4679
        }
    }

    var cssColor: String { String(format: "#%06X", rgb) }

    var color: Color {
        Color(.sRGB, red: Double(rgb >> 16) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

struct CategoryTag: View {
    let category: PageCategory
    var compact = false
    var accent: PageCategory?

    var body: some View {
        HStack(spacing: 3) {
            Text("#").foregroundStyle((accent ?? category).color)
            if !compact { Text(verbatim: category.label).foregroundStyle(accent == nil ? category.color : ink) }
        }
            .font(.system(size: compact ? 14 : 12, weight: .medium))
            .padding(.horizontal, compact ? 0 : 6)
            .frame(width: compact ? 18 : nil, height: compact ? 18 : 22)
            .background((accent ?? category).color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(compact)
    }
}

struct QuestionStatusButton: View {
    @ObservedObject var m: Workspace
    let question: Entry
    var body: some View {
        Button { m.toggleQuestionStatus(question.id) } label: {
            Text(question.answered ? "已回答" : "待回答")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(question.answered ? Color(red: 0.34, green: 0.24, blue: 0.02) : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(question.answered ? Color.yellow.opacity(0.7) : Color.secondary.opacity(0.12), in: Capsule())
        }.buttonStyle(.plain).fixedSize().help(question.answered ? "切回待回答" : "标为已回答")
    }
}

struct PageHeading<Content: View>: View {
    let title: String
    let category: PageCategory
    @Environment(\.activeStockModule) private var stockModule
    private var accent: PageCategory { stockModule?.category ?? category }
    var titleSize: CGFloat = 28
    var showsTag = true
    var metadata: String = ""
    var subtitle: String = ""
    var status: QuestionStatusButton? = nil
    var editableTitle: EntryPageTitle? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let editableTitle { editableTitle }
            else { Text(title).font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    tags.fixedSize()
                    Spacer(minLength: 0)
                    actions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    tags
                    actions.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                LinearGradient(colors: [.white, .white, paper], startPoint: .top, endPoint: .bottom)
                EllipticalGradient(colors: [accent.color.opacity(0.15), accent.color.opacity(0.05), .clear],
                                   center: UnitPoint(x: 0.47, y: 0.12), startRadiusFraction: 0, endRadiusFraction: 0.85)
            }
        }
    }

    private var actions: some View {
        content().tint(accent.color).foregroundStyle(stockModule == nil ? accent.color : ink)
    }

    private var tags: some View {
        HStack(spacing: 8) {
            if showsTag { CategoryTag(category: category, accent: stockModule?.category).fixedSize() }
            status
            if !metadata.isEmpty {
                Text(metadata).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct ResearchActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(minHeight: 24)
            .foregroundStyle(.white)
            .background(.tint.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 6))
    }
}

// Keep action labels at their natural size and move whole controls onto the next line.
struct PageActions: Layout {
    private let spacing: CGFloat = 8

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
