import AppKit
import WebKit

@MainActor private final class TestReaderBridge: NSObject, WKScriptMessageHandler {
    var received: [String:Any]?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        received = message.body as? [String:Any]
    }
}

@main struct MacSmoke {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let bridge = TestReaderBridge()
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name:"reader")
        let web = WKWebView(frame: CGRect(x:0,y:0,width:800,height:600), configuration:config)
        web.loadFileURL(resources.appendingPathComponent("reader.html"), allowingReadAccessTo:resources)
        var ready = false
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds:150_000_000)
            if (try? await web.evaluateJavaScript("typeof render === 'function' && typeof marked === 'object'") as? Bool) == true { ready=true; break }
        }
        guard ready else { throw Failure("WebKit 阅读器未加载") }
        let readerResult = try await web.evaluateJavaScript("""
          (() => {
            if ([...bar.querySelectorAll('button')].map(b=>b.textContent).join(',') !== '概念,实体,事件,问题') return '划选类型不正确';
            const a = {report:'reports/base-v1.md',section:'研究',quote:'合约',prefix:'先例，',suffix:'确认。'};
            const view = {file:a.report,body:'# 研究\\n\\n早期合约。\\n\\n先例，**合约**确认。\\n\\n| 公司 | 事件 |\\n|---|---|\\n| 甲 | 签约 |',marks:[{id:'1',kind:'concepts',title:'概念',anchor:a}],focus:a,extract:true,scroll:0};
            render(view);
            const mark=article.querySelector('mark.focus'),table=article.querySelector('table');
            if(!mark || mark.textContent!=='合约' || !table) return '高亮、表格或原文定位失败';
            mark.click();
            const paragraphs=article.querySelectorAll('p');
            const range=document.createRange();range.setStart(paragraphs[0].firstChild,2);range.setEnd(paragraphs[1].firstChild,3);
            const d=makeDraft(positionForRange(range),'selection');
            if(!d || !d.quote.includes('。\\n先例，') || locate(index,d)===null) return '跨段标注失败';
            render({...view, focus:null, marks:[], deletedIDs:['gone'], deletedPaths:['entities/old.md'],
              body:'[正文](feynman:gone) [带章节](feynman:gone#section) [旧文](../entities/old.md#section) [保留](feynman:live#section)'});
            if(article.querySelector('mark') || article.querySelectorAll('a').length!==1 ||
              article.querySelector('a').getAttribute('href')!=='feynman:live#section' ||
              !article.textContent.includes('正文 带章节 旧文 保留')) return '删除后的正文链接不正确';
            return 'WebKit 已验证报告渲染、重复原文定位、跨段选取与表格';
          })()
        """)
        guard let result=readerResult as? String, result.hasPrefix("WebKit") else { throw Failure(String(describing:readerResult)) }
        guard bridge.received?["action"] as? String == "show",
              bridge.received?["ids"] as? [String] == ["1"],
              let anchors = bridge.received?["anchors"] as? [[String:String]], anchors.first?["prefix"] == "先例，" else {
            throw Failure("点击高亮未带回对应的出处")
        }
        print(result)
        let historyResult = try await web.evaluateJavaScript("""
          (() => {
            const data = {file:'questions/history.md',body:'整合后的总结。',marks:[],extract:false,scroll:0,deletedIDs:[],deletedPaths:[],
              questionHistory:[{id:'one',date:'2026-11-18T00:00:00Z',question:'谁负责？',answer:'由**医院**负责。'},
                {id:'two',date:'2026-11-18T01:00:00Z',question:'依据？<script>bad()</script>',answer:'见[合同](feynman:contract)。<img src=x onerror=bad()>'}]};
            render(data);
            let history=article.querySelector('.question-history');
            if(!history || history.open || history.previousElementSibling.textContent!=='整合后的总结。') return '历史默认收起或位置错误';
            if(history.querySelectorAll('.history-turn').length!==2 || !history.querySelector('strong') || history.querySelector('script,[onerror]')) return '历史顺序或 Markdown 安全渲染错误';
            history.querySelector('summary').click();
            if(!history.open || !history.textContent.includes('谁负责？') || !history.textContent.includes('依据？')) return '历史无法展开';
            const rounds=history.querySelectorAll('.history-turn');
            if([...rounds].some(turn=>turn.classList.contains('expanded'))) return '每轮记录未默认收起';
            rounds[1].querySelector('button').click();
            if(!rounds[1].classList.contains('expanded') || rounds[0].classList.contains('expanded')) return '单轮展开影响其他记录';
            if(!rounds[1].querySelector('.history-answer').getBoundingClientRect().height) return '回答无法显示';
            render({...data,body:'自动刷新后的总结。'});
            if(!article.querySelector('.question-history').open || !article.querySelector('[data-turn-id="two"]').classList.contains('expanded') || article.querySelector('[data-turn-id="one"]').classList.contains('expanded')) return '刷新丢失展开状态';
            article.querySelector('.question-history a').click();
            render({...data,file:'questions/other.md'});
            if(article.querySelector('.question-history').open || article.querySelector('.history-turn.expanded')) return '新问题未默认收起';
            render({...data,questionHistory:[]});
            if(!article.querySelector('.history-empty')) return '旧问题空记录错误';
            return '追问记录已验证';
          })()
        """)
        guard historyResult as? String == "追问记录已验证", bridge.received?["action"] as? String == "link",
              bridge.received?["href"] as? String == "feynman:contract" else { throw Failure(String(describing:historyResult)) }
        print("追问记录通过：默认折叠、展开、时间顺序、Markdown、来源链接、刷新与切换问题")
        if CommandLine.arguments.contains("--terminal") {
            let root=fm.temporaryDirectory.appendingPathComponent("Feynman-Smoke-" + UUID().uuidString)
            try fm.createDirectory(at:root,withIntermediateDirectories:true)
            defer { try? fm.removeItem(at:root) }
            let p=try Files.create(root,title:"终端往返 ' 样例",intent:"临时验证")
            let fake=root.appendingPathComponent("fixture-cli")
            let fixture = #"""
            #!/usr/bin/python3
            import json, os, sys
            from pathlib import Path
            assert sys.argv[1] == '-C' and os.path.samefile(sys.argv[2], os.getcwd())
            assert os.tcgetpgrp(1) == os.getpgrp()
            if 'exec' in sys.argv:
                assert sys.argv[-1] == '-' and sys.argv[sys.argv.index('--sandbox') + 1] == 'read-only'
                prompt = sys.stdin.buffer.read()
                Path('submitted.bin').write_bytes(prompt)
                print('This is a progress log, not the answer.')
                assert Path(sys.argv[sys.argv.index('--output-schema') + 1]).is_file()
                output = Path(sys.argv[sys.argv.index('--output-last-message') + 1])
                if '全新空白问题' in prompt.decode():
                    assert Path(sys.argv[sys.argv.index('--output-schema') + 1]).name == 'question-response-schema.json'
                    output.write_text(json.dumps({'answer':'首轮完整回答。','edits':[]}))
                    sys.exit(0)
                if '原合同何时到期？' in prompt.decode():
                    assert '完整原文' in prompt.decode() and '融入相应论点' in prompt.decode()
                    output.write_text(json.dumps({'edits':[{'original':'合同于六月到期。','revised':'原合同于六月到期，双方已将其续至十二月。'}]}))
                    sys.exit(0)
                if '本轮追问' in prompt.decode():
                    print('Processing follow-up', flush=True)
                    if '中途退出' in prompt.decode():
                        import time
                        time.sleep(60)
                    output.write_text(json.dumps({'answer':'证据来自[采购合同](feynman:contract)，由医院签署。','edits':[{'original':'由医院负责续约。','revised':'由医院负责续约，依据是[采购合同](feynman:contract)。'}]}))
                    sys.exit(0)
                output.write_text(json.dumps({'answer':'由医院负责续约，合同期限为三年。','edits':[{'original':'续约责任待核实。','revised':'由医院负责续约。'}]}))
            else:
                assert sys.argv[3] == '--'
                Path('submitted.bin').write_bytes(sys.argv[4].encode())
            """#
            try Data(fixture.utf8).write(to:fake)
            try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:fake.path)
            var item = Entry(kind:.questions, title:"谁负责续约？", body:"合同为期三年。[来源](feynman:term)\n\n续约责任待核实。")
            item.anchors = [Anchor(report:"reports/base-v1.md", section:"测试", quote:"续约")]
            try Files.write(item, in:p.url)
            item = try Files.scan(p.url).resolve(item.id)!
            let reference = try Terminal.prompt(.question, project:p, root:root, context:item.path, entry:item)
            guard reference.hasPrefix(item.title), reference.contains(item.body), !reference.contains("preflight.done"), !reference.contains("sling-thematic-study") else { throw Failure("追问使用了错误的模板") }
            let window = NSWindow(contentRect:CGRect(x:0,y:0,width:800,height:320),styleMask:[.titled],backing:.buffered,defer:false)
            let sent = p.url.appendingPathComponent("submitted.bin")
            var concept = Entry(kind:.concepts, title:"续约机制", body:"审批权限归采购部门。\n\n合同于六月到期。")
            try Files.write(concept, in:p.url)
            concept = try Files.scan(p.url).resolve(concept.id)!
            let revision = try Terminal.prompt(.revise, project:p, root:root, context:concept.path, entry:concept)
            for action in [Action.preflight, .revise, .question] {
                let draft = action == .question ? reference : action == .revise ? revision : "请核验数据。\n第二段 $() ' 🧪"
                let selected = action == .question ? item : action == .revise ? concept : nil
                let session = ResearchSession(project:p, root:root, action:action, context:selected?.path, cli:fake, draft:draft, target:selected.map(ResearchTarget.entry), resources:resources)
                defer { session.closeSession() }
                let console = session.view()
                window.contentView = console; window.orderFront(nil)
                var loaded = false
                for _ in 0..<100 {
                    if (try? await console.evaluateJavaScript("document.querySelector('#draft').value") as? String) == draft { loaded = true; break }
                    try await Task.sleep(nanoseconds:100_000_000)
                }
                guard loaded, !fm.fileExists(atPath:sent.path) else { throw Failure("没有显示完整可编辑草稿，或草稿已提前发送") }
                let submitted = draft + (action == .revise ? "\n原合同何时到期？" : "手工修改")
                _ = try await console.evaluateJavaScript("editor.value = " + (try json(submitted)) + "; send.click()")
                for _ in 0..<100 {
                    if session.exited || session.phase == .followUp { break }
                    try await Task.sleep(nanoseconds:100_000_000)
                }
                guard (action == .question ? session.phase == .followUp : session.exited), try String(contentsOf:sent, encoding:.utf8).hasPrefix(submitted) else { throw Failure("CLI 未收到修改后的提示词") }
                try fm.removeItem(at:sent)
                if action == .revise {
                    guard try Files.scan(p.url).resolve(concept.id)?.body == "审批权限归采购部门。\n\n原合同于六月到期，双方已将其续至十二月。" else { throw Failure("条目修订未整合补充问题") }
                }
                if action == .question {
                    let written = try Files.scan(p.url).resolve(item.id)!
                    let answer = "合同为期三年。[来源](feynman:term)\n\n由医院负责续约。"
                    guard !written.answered, written.body == answer, written.anchors == item.anchors, written.questionHistory.count == 1, written.questionHistory[0].question == submitted, written.questionHistory[0].answer == "由医院负责续约，合同期限为三年。" else { throw Failure("最终回复未原样保存到原问题：" + session.status) }
                    let conflicting = try? ResearchTarget.entry(item).save("另一轮回答", in:p)
                    guard conflicting == nil, try Files.scan(p.url).resolve(item.id)?.body == answer else { throw Failure("写入覆盖了更新的答案") }
                    let followUp = "证据来自哪里？"
                    let composerReady = try await console.evaluateJavaScript("!document.querySelector('#composer').hidden && editor.value === '' && document.querySelector('#hint').textContent.includes('Esc')") as? Bool
                    guard composerReady == true else { throw Failure("保存后未显示空白追问框和 Esc 提示") }
                    _ = try await console.evaluateJavaScript("editor.value='证据来自哪里？'; submit()")
                    for _ in 0..<100 {
                        if fm.fileExists(atPath:sent.path), session.phase == .followUp { break }
                        try await Task.sleep(nanoseconds:100_000_000)
                    }
                    let next = try Files.scan(p.url).resolve(item.id)!
                    let followPrompt = try String(contentsOf: sent, encoding: .utf8)
                    guard next.body == "合同为期三年。[来源](feynman:term)\n\n由医院负责续约，依据是[采购合同](feynman:contract)。",
                          followPrompt.contains(followUp), followPrompt.contains(item.path), next.anchors == item.anchors,
                          next.questionHistory.count == 2, next.questionHistory[0] == written.questionHistory[0],
                          next.questionHistory[1].question == followUp, next.questionHistory[1].answer == "证据来自[采购合同](feynman:contract)，由医院签署。"
                    else { throw Failure("第二轮回答没有融入已有正文") }
                    let workspace = Workspace()
                    workspace.selectedConsole = session.id
                    _ = try await console.evaluateJavaScript("editor.value='中途退出'; submit()")
                    for _ in 0..<50 where session.phase != .running { try await Task.sleep(nanoseconds:100_000_000) }
                    workspace.escapeConsole(session)
                    for _ in 0..<50 where !session.exited { try await Task.sleep(nanoseconds:100_000_000) }
                    guard session.exited, workspace.selectedConsole == session.id,
                          (try await console.evaluateJavaScript("document.querySelector('#exit').textContent.includes('按 Esc 收起终端')") as? Bool) == true,
                          try Files.scan(p.url).resolve(item.id)?.body == next.body,
                          try Files.scan(p.url).resolve(item.id)?.questionHistory == next.questionHistory else { throw Failure("退出未保留已完成的问答和收起提示") }
                    workspace.escapeConsole(session)
                    guard workspace.selectedConsole == nil else { throw Failure("第二次 Esc 未收起终端") }
                }
            }
            var blank = Entry(kind:.questions, title:"全新空白问题")
            try Files.write(blank, in:p.url)
            blank = try Files.scan(p.url).resolve(blank.id)!
            let blankDraft = try Terminal.prompt(.question, project:p, root:root, context:blank.path, entry:blank)
            let fresh = ResearchSession(project:p, root:root, action:.question, context:blank.path, cli:fake, draft:blankDraft, target:.entry(blank), resources:resources)
            defer { fresh.closeSession() }
            let freshWeb = fresh.view()
            window.contentView = freshWeb
            for _ in 0..<100 {
                if (try? await freshWeb.evaluateJavaScript("editor.value") as? String) == blankDraft { break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            _ = try await freshWeb.evaluateJavaScript("send.click()")
            for _ in 0..<100 {
                if fresh.phase == .followUp || fresh.exited { break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            let blankSaved = try Files.scan(p.url).resolve(blank.id)!
            guard fresh.phase == .followUp, blankSaved.body == "首轮完整回答。",
                  blankSaved.questionHistory.count == 1, blankSaved.questionHistory[0].question == blank.title,
                  blankSaved.questionHistory[0].answer == blankSaved.body else { throw Failure("空白问题首答及原始问题记录失败") }
            let source = "project:references/files/经典报告.pdf"
            let original = try Files.child(p.url, "references/files/经典报告.pdf")
            try Data("original file bytes".utf8).write(to: original)
            var ref = Entry(kind: .references, title: "经典报告", body: "[新闻](<https://example.org/news/2026>)")
            ref.assets = [source]
            ref.links = [item.id]
            ref.reportLinks = ["reports/base-v1.md"]
            try Files.write(ref, in: p.url)
            let report = try Files.child(p.url, "reports/base-v1.md")
            try "[新闻](https://example.org/news/2026)".write(to: report, atomically: true, encoding: .utf8)
            var owner = try Files.scan(p.url).resolve(item.id)!
            owner.assets = [source]
            try Files.write(owner, in: p.url)
            let target = ResearchTarget.archive(id: ref.id, source: source, localFile: original, lakehouse: root, prefix: "library:")
            let receipt = #"{"libraryPath":"Library/reports/经典报告.pdf"}"#
            guard (try? target.save(receipt, in: p)) == nil else { throw Failure("不应更新尚未落盘的资料") }
            let archiveFixture = #"""
            #!/usr/bin/python3
            import json, sys
            from pathlib import Path
            args = sys.argv
            assert args[args.index('--sandbox') + 1] == 'workspace-write'
            root = Path(args[args.index('-C') + 1])
            destination = root / 'Library/reports/经典报告.pdf'
            destination.parent.mkdir(parents=True)
            destination.write_bytes(Path(sys.stdin.read()).read_bytes())
            Path(args[args.index('--output-last-message') + 1]).write_text(json.dumps({'libraryPath': 'Library/reports/经典报告.pdf'}))
            """#
            try Data(archiveFixture.utf8).write(to: fake)
            let archive = ResearchSession(project:p, root:root, action:.archive, context:ref.path, cli:fake, draft:original.path, target:target, resources:resources)
            defer { archive.closeSession() }
            window.contentView = archive.view()
            for _ in 0..<150 where !archive.exited { try await Task.sleep(nanoseconds: 100_000_000) }
            let snapshot = try Files.scan(p.url)
            let canonical = "library:Library/reports/经典报告.pdf"
            guard archive.exited, snapshot.resolve(ref.id)?.assets == [canonical], snapshot.resolve(owner.id)?.assets == [canonical],
                  snapshot.reference(for: source, from: owner.path)?.id == ref.id,
                  snapshot.citations[ref.id]?.contains("reports/base-v1.md") == true,
                  snapshot.reference(for: "https://example.org/news/2026", from: "reports/base-v1.md")?.id == ref.id,
                  snapshot.looseAssets.isEmpty, snapshot.unlistedMaterials.isEmpty,
                  snapshot.related(to: ref).contains(where: { $0.id == owner.id }) else {
                throw Failure("自动入库、核验、引用替换或反链失败：" + archive.status)
            }
            print("通过：单击自动启动归档、校验 Library 文件、共享附件更新、报告与问题反链、旧链接定位")
            window.orderOut(nil)
            print("内嵌终端通过：可编辑草稿、手动发送、首答回填、追问整合、运行中退出、二次 Esc 收起、出处保留、冲突保护")
        }
    }
}
