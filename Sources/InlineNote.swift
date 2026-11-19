import SwiftUI
import AppKit

@MainActor final class InlineNoteDraft: ObservableObject, Identifiable {
    let id = UUID()
    let path: String
    let url: URL
    let project: ProjectAt
    var entry: Entry?
    var original: String?
    var text: String
    @Published var title: String
    var caret: Int
    enum Mode { case paragraph, title, document }
    let mode: Mode
    var autosave: Task<Void, Never>?
    var cloudCopies: [CloudCopy]
    @Published var diskVersion: String?
    @Published var status = ""

    init(path: String, url: URL, project: ProjectAt, entry: Entry?, original: String?, append: String,
         offset: Int, mode: Mode, cloudCopies: [CloudCopy]) {
        self.path = path
        self.url = url
        self.project = project
        self.entry = entry
        self.original = original
        self.cloudCopies = cloudCopies
        title = entry?.title ?? ""
        let body = Document(original ?? "").body
        text = append.isEmpty ? body : body + (body.isEmpty ? "" : "\n\n") + append + "\n"
        caret = append.isEmpty ? min(max(0, offset), (body as NSString).length) : (text as NSString).length
        self.mode = mode
    }
    var needsReview: Bool { diskVersion != nil || !cloudCopies.isEmpty }
}

extension Workspace {
    func beginInlineNote(_ path: String, offset: Int = 0, mode: InlineNoteDraft.Mode = .document, append: String = "") {
        guard canEditNote(path) else { return }
        if let current = inlineNote, current.path == path, current.mode == mode { return }
        guard finishInlineNote(), let project else { return }
        attempt {
            let url = try documentURL(path)
            let original = try Files.contents(url)
            guard original != nil || ["memo.md", "log.md"].contains(path) else { throw Failure("文件尚未同步或已移走。") }
            let entry = snapshot.entry(at: path).flatMap { item in
                item.path == path ? original.map { Entry(kind: item.kind, path: path, raw: $0) } : nil
            }
            let copies = try (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map {
                CloudCopy(version: $0, content: try String(contentsOf: $0.url, encoding: .utf8))
            }
            inlineNote = InlineNoteDraft(path: path, url: url, project: project, entry: entry, original: original,
                                        append: append, offset: offset, mode: mode, cloudCopies: copies)
        }
    }

    func scheduleNoteSave(_ note: InlineNoteDraft) {
        note.autosave?.cancel()
        guard !note.needsReview else { return }
        note.autosave = Task { [weak self, weak note] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, let note, self.inlineNote === note else { return }
            _ = self.saveInlineNote(note)
        }
    }

    private func saveInlineNote(_ note: InlineNoteDraft, reviewed: Bool = false) -> Bool {
        do {
            guard canEditNote(note.path) else { throw Failure("引用资料为只读。") }
            if note.needsReview && !reviewed { return false }
            let expected = reviewed ? note.diskVersion ?? note.original : note.original
            if note.text == Document(expected ?? "").body, note.entry.map({ $0.title == note.title.clean }) ?? true,
               !note.needsReview { return true }
            if let prior = note.entry {
                guard !note.title.clean.isEmpty else { throw Failure("请填写标题。") }
                var item = expected.map { Entry(kind: prior.kind, path: prior.path, raw: $0) } ?? prior
                guard item.id == prior.id, !item.deleted else { throw Failure("条目已变更，请先复制需要保留的草稿。") }
                item.title = note.title.clean
                item.body = note.text
                note.original = try Files.write(item, in: note.project.url)
                note.entry = item
            } else {
                let contents = Document(expected ?? "").header + note.text
                try Files.save(note.url, contents, expected: expected)
                note.original = contents
            }
            if reviewed {
                for copy in note.cloudCopies { copy.version.isResolved = true }
                note.cloudCopies = []
                note.diskVersion = nil
            }
            note.status = ""
            refresh()
            return true
        } catch {
            note.status = error.localizedDescription
            if let disk = try? Files.contents(note.url), disk != note.original { note.diskVersion = disk }
            return false
        }
    }

    @discardableResult func finishInlineNote(reviewed: Bool = false) -> Bool {
        guard let note = inlineNote else { return true }
        note.autosave?.cancel()
        guard saveInlineNote(note, reviewed: reviewed) else { return false }
        readingPosition = (note.path, note.caret)
        inlineNote = nil
        return true
    }
}

struct NoteBody: View {
    @ObservedObject var m: Workspace
    var path: String
    var text: String
    var extract = false
    var history: [ResearchTurn]? = nil
    var body: some View {
        let note = m.inlineNote.flatMap { $0.path == path ? $0 : nil }
        VStack(spacing: 0) {
            Reader(model: m, path: path, bodyText: note?.text ?? text, extract: extract, questionHistory: history)
            if let note { NoteEditingControls(m: m, draft: note) }
        }
    }
}

struct EntryPageTitle: View {
    @ObservedObject var model: Workspace
    let entry: Entry

    var body: some View {
        if let draft = model.inlineNote, draft.path == entry.path, draft.mode != .paragraph {
            InlineNoteTitle(draft: draft, model: model).id(draft.id)
        } else {
            Button { model.beginInlineNote(entry.path, mode: .title) } label: {
                Text(entry.title).font(.system(size: 28, weight: .bold)).foregroundStyle(ink)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(.plain).help("点击修改标题")
        }
    }
}

private struct InlineNoteTitle: View {
    @ObservedObject var draft: InlineNoteDraft
    let model: Workspace
    @FocusState private var focused: Bool

    private func finishTitle() {
        if draft.mode == .title, model.inlineNote === draft { model.finishInlineNote() }
    }

    var body: some View {
        TextField("标题", text: $draft.title, axis: .vertical)
            .font(.system(size: 28, weight: .bold)).textFieldStyle(.plain)
            .focused($focused).focusedValue(\.editingNavigationKeys, true)
            .task(id: draft.id) { if draft.mode == .title { focused = true } }
            .onSubmit { finishTitle() }
            .onChange(of: focused) { _, active in if !active { finishTitle() } }
            .onExitCommand {
                if draft.mode == .title, model.inlineNote === draft { model.inlineNote = nil }
            }
    }
}

private struct NoteEditingControls: View {
    @ObservedObject var m: Workspace
    @ObservedObject var draft: InlineNoteDraft
    var body: some View {
        VStack(spacing: 0) {
            if draft.needsReview {
                DisclosureGroup("查看其他版本，核对后合并") {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(draft.cloudCopies) { Text(Document($0.content).body) }
                            if let disk = draft.diskVersion { Text(disk) }
                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }.padding(.horizontal)
            }
            if draft.mode == .document || draft.needsReview || !draft.status.isEmpty {
                HStack {
                    Text(draft.status.isEmpty ? (draft.needsReview ? "请核对同步版本" : "Markdown · 自动保存") : draft.status)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !draft.status.isEmpty || draft.needsReview {
                        Button("放弃未保存修改") { m.inlineNote = nil; m.refresh() }
                    }
                    Button(draft.needsReview ? "合并并完成" : "完成") { m.finishInlineNote(reviewed: draft.needsReview) }
                        .keyboardShortcut("s")
                }.padding(.horizontal, 18).padding(.vertical, 6)
            }
        }.onChange(of: draft.title) { _, _ in
            if draft.mode == .document { m.scheduleNoteSave(draft) }
        }
    }
}

struct MarkdownSourceView: NSViewRepresentable {
    let url: URL
    let initialText: String
    let changed: (String, Bool) -> Void
    let pasteError: (Error) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NoteTextView()
        text.noteURL = url
        text.onPasteError = pasteError
        text.delegate = context.coordinator
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 15)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        text.defaultParagraphStyle = style
        text.textContainerInset = NSSize(width: 31, height: 20)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.string = initialText
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {}
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let source: MarkdownSourceView
        init(_ source: MarkdownSourceView) { self.source = source }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            source.changed(text.string, text.hasMarkedText())
        }
    }
}
