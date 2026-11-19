import SwiftUI

enum RelationIcon: String, CaseIterable {
    case question, concept, entity, event, reference, quote, web, library, attachment

    case overview, report, log, memo, projects, folder

    init(_ kind: Kind) {
        switch kind {
        case .questions: self = .question
        case .concepts: self = .concept
        case .entities: self = .entity
        case .events: self = .event
        case .references: self = .reference
        }
    }

    init(material: String) {
        if MaterialLinks.isWeb(material) { self = .web }
        else if material.hasPrefix("library:") || material.hasPrefix("lakehouse:Library/") { self = .library }
        else { self = .attachment }
    }

    static let images: [RelationIcon: NSImage] = Dictionary(uniqueKeysWithValues: allCases.compactMap { icon in
        guard let url = Bundle.main.url(forResource: icon.rawValue, withExtension: "svg", subdirectory: "RelationIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        return (icon, image)
    })

    var color: Color {
        switch self {
        case .question: return PageCategory.kind(.questions).color
        case .concept: return PageCategory.kind(.concepts).color
        case .entity: return PageCategory.kind(.entities).color
        case .event: return PageCategory.kind(.events).color
        case .reference, .attachment, .library, .folder: return PageCategory.kind(.references).color
        case .web: return PageCategory.webLinks.color
        case .quote, .report: return PageCategory.report.color
        case .overview, .projects: return PageCategory.project.color
        case .log: return PageCategory.log.color
        case .memo: return PageCategory.memo.color
        }
    }
}

struct RelationEmblem: View {
    static let nodeSize: CGFloat = 30
    static let hubSize: CGFloat = 40

    let icon: RelationIcon
    let size: CGFloat
    var isHub = false

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            tile.fill(icon.color.opacity(isHub ? 0.16 : 0.09))
            if let artwork = RelationIcon.images[icon] {
                Image(nsImage: artwork)
                    .resizable().renderingMode(.original).scaledToFit()
                    .padding(size * 0.045)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
