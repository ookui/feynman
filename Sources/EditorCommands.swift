import SwiftUI
import WebKit

struct OverviewShortcut {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+").map { String($0).clean }
        guard let last = parts.last, last.count == 1, let character = last.first,
              character.isLetter || character.isNumber else { return nil }
        var flags: EventModifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.command)
            case "shift", "⇧": flags.insert(.shift)
            case "opt", "alt", "option", "⌥": flags.insert(.option)
            case "ctrl", "control", "⌃": flags.insert(.control)
            default: return nil
            }
        }
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        key = KeyEquivalent(character)
        modifiers = flags
    }
}

struct OverviewShortcutSetting: View {
    @AppStorage("overviewShortcut") private var saved = "Cmd+G"
    @State private var draft = ""
    var body: some View {
        HStack {
            Text("Project Overview 快捷键")
            TextField("Cmd+G", text: $draft).frame(width: 130)
            Button("应用") { saved = draft }.disabled(OverviewShortcut(draft) == nil || draft == saved)
            Button("恢复默认") { saved = "Cmd+G"; draft = saved }
        }.onAppear { draft = saved }
    }
}

struct MarkdownCommands: Commands {
    @ObservedObject var model: Workspace
    @AppStorage("overviewShortcut") var overviewKey = "Cmd+G"
    private var editable: Bool { model.currentNotePath.map(model.canEditNote) == true && model.dialog == nil }
    private func item(_ title: LocalizedStringKey, _ id: String, _ key: Character? = nil, _ modifiers: EventModifiers = .command) -> some View {
        Button(title) { model.editorCommand(id) }
            .keyboardShortcut(key.map { KeyboardShortcut(KeyEquivalent($0), modifiers: modifiers) })
            .disabled(!editable)
    }
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.editHistory(redo: false) }.keyboardShortcut("z")
            Button("Redo") { model.editHistory(redo: true) }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            item("Edit Markdown", "open")
            item("Insert Link…", "edit.link", "k")
            Button("Find in Document…") { model.searchDocument = model.currentNotePath; NotificationCenter.default.post(name: .focusProjectSearch, object: model) }.keyboardShortcut("f")
                .disabled(model.currentNotePath == nil || model.dialog != nil)
            Button("Search Project") { model.searchDocument = nil; NotificationCenter.default.post(name: .focusProjectSearch, object: model) }
                .keyboardShortcut("f", modifiers: [.command,.shift]).disabled(model.project == nil || model.dialog != nil)
        }
        CommandMenu("Paragraph") {
            ForEach(1...6, id: \.self) { level in
                item("Heading \(level)", "paragraph.h" + String(level), Character(String(level)))
            }
            item("Body Text","paragraph.paragraph","0")
            item("Block Quote","paragraph.quote")
            item("Bulleted List","paragraph.bullet")
            item("Numbered List","paragraph.ordered")
            item("Task List","paragraph.task")
            item("Code Block","paragraph.code","c",[.command,.option])
            item("Display Math","paragraph.math")
            item("Mermaid Diagram","paragraph.mermaid")
            item("Table of Contents","paragraph.toc")
        }
        CommandGroup(replacing: .textFormatting) {
            item("Inline Math","format.math")
            item("Bold","format.bold","b")
            item("Italic","format.italic","i")
            item("Strikethrough","format.strike")
            item("Highlight","format.highlight")
            item("Inline Code","format.code","e")
        }
        CommandMenu("Table") {
            item("Insert Table…","table.insert","t",[.command,.option])
            item("Insert Row Above","table.rowAbove")
            item("Insert Row Below","table.rowBelow")
            item("Insert Column Left","table.columnLeft")
            item("Insert Column Right","table.columnRight")
            item("Delete Row","table.deleteRow")
            item("Delete Column","table.deleteColumn")
            item("Move Row Up","table.moveRowUp")
            item("Move Row Down","table.moveRowDown")
            item("Move Column Left","table.moveColumnLeft")
            item("Move Column Right","table.moveColumnRight")
            item("Align Column Left","table.alignLeft")
            item("Center Column","table.alignCenter")
            item("Align Column Right","table.alignRight")
        }
        CommandGroup(after: .sidebar) {
            Button { model.go(.overview) } label: { Text(model.project?.info.stock == nil ? "Project Overview" : "Company Home") }
                .keyboardShortcut(OverviewShortcut(overviewKey).map { KeyboardShortcut($0.key, modifiers: $0.modifiers) })
                .disabled(model.project == nil || model.dialog != nil)
        }
    }
}

extension Notification.Name {
    static let focusProjectSearch = Notification.Name("Feynman.focusProjectSearch")
}

extension Workspace {
    var currentNotePath: String? {
        switch place {
        case .judgmentEditor: return stockBook.draft?.path
        case .doc(let path): return path
        case .entry(let id): return snapshot.resolve(id)?.path
        default: return nil
        }
    }

    func editHistory(redo: Bool) {
        if inlineNote?.mode == .rich, dialog == nil, let web = readerWeb,
           let responder = NSApp.keyWindow?.firstResponder as? NSView,
           responder === web || responder.isDescendant(of: web) {
            editorCommand(redo ? "edit.redo" : "edit.undo")
        } else {
            NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: nil)
        }
    }

    func editorCommand(_ command: String) {
        guard let web = readerWeb, dialog == nil else { return }
        web.callAsyncJavaScript("return performEditorCommand(command)", arguments: ["command": command], in: nil, in: .page, completionHandler: nil)
    }
}
