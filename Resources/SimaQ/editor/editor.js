/* Markdown stays authoritative. The reading surface and the native text field share UTF-16 offsets. */
(function () {
  'use strict';
  const clamp = (n, a, b) => Math.max(a, Math.min(b, n));
  const normalize = value => value.replace(/\r\n?/g, '\n');
  const element = (name, cls) => Object.assign(document.createElement(name), {className:cls});
  const escape = value => value.replace(/[&<>"]/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;'}[c]));
  function rawOffset(raw, index) {
    if (!raw.includes('\r')) return index;
    let at = 0;
    for (let i = 0; i < index && at < raw.length; i++, at++) {
      if (raw[at] === '\r' && raw[at + 1] === '\n') at++;
    }
    return at;
  }
  function difference(before, after) {
    let from = 0, oldEnd = before.length, newEnd = after.length;
    while (from < oldEnd && from < newEnd && before[from] === after[from]) from++;
    while (oldEnd > from && newEnd > from && before[oldEnd-1] === after[newEnd-1]) {oldEnd--; newEnd--;}
    return {from, oldEnd, inserted:after.slice(from, newEnd)};
  }
  // Token ranges distinguish real list items from lookalike lines in code blocks.
  function listOutdentEdits(text, blocks, from, to) {
    const edits = new Map();
    function paragraphBreak(at) {
      if (!at || at >= text.length) return;
      const newline = text.slice(at - 2, at) === '\r\n' ? '\r\n' : text[at - 1];
      const end = at - newline.length;
      let p = end;
      while (p && /[ \t]/.test(text[p - 1])) p--;
      let next = at;
      while (next < text.length && /[ \t]/.test(text[next])) next++;
      if (!p || next === text.length || /[\r\n]/.test(text[p - 1]) || /[\r\n]/.test(text[next])) return;
      const edit = edits.get(at) || {at, remove:0, insert:''};
      edit.separator = newline;
      edits.set(at, edit);
    }
    for (const block of blocks) {
      if (!block.listItems || block.end < from || (from === to ? block.start > to : block.start >= to)) continue;
      const parents = [];
      let at = block.start, index = 0, previousPlain = false;
      for (const [i, line] of block.source.split(/\r\n|\r|\n/).entries()) {
        while (parents.length && parents.at(-1).until <= i) parents.pop();
        let parent = parents.at(-1);
        const selected = from <= at + line.length && (from === to ? at <= to : at < to);
        if (block.listItems[index]?.line === i) {
          const token = block.listItems[index++];
          // Two markers can share a physical line. Lift its outer item once.
          while (block.listItems[index]?.line === i) index++;
          const marker = /^([ \t]*)(?:[-*+]|\d+[.)])(?:[ \t]+|$)(?:\[[ xX]\](?:[ \t]+|$))?/.exec(line);
          const direct = token.level === (parent ? parent.level + 2 : 1);
          const item = {...token, indent:marker?.[1] || '', shift:0, plain:false};
          if (selected && marker && direct) {
            item.plain = !parent;
            const remove = item.plain ? marker[0].length : item.indent.length;
            let insert = parent?.indent || '';
            if (parent?.promotedIndent !== undefined && item.indent.startsWith(parent.indent)) {
              insert = parent.promotedIndent + item.indent.slice(parent.indent.length);
            }
            edits.set(at, {at, remove, insert});
            if (parent) item.promotedIndent = insert;
            item.shift = remove - insert.length;
            if (item.plain) paragraphBreak(at);
          }
          if (previousPlain) paragraphBreak(at);
          parents.push(item);
          parent = item;
        } else if (selected && parent?.shift > 0) {
          const remove = Math.min(parent.shift, /^[ \t]*/.exec(line)[0].length);
          if (remove) edits.set(at, {at, remove, insert:''});
        }
        previousPlain = !!parent?.plain;
        at += line.length;
        at += text.startsWith('\r\n', at) ? 2 : 1;
      }
      if (previousPlain) paragraphBreak(at);
    }
    return [...edits.values()].sort((a,b) => a.at - b.at);
  }
  function create(host, options = {}) {
    let text = String(options.text ?? ''), source = !!options.literal, yamlCollapsed = options.settings?.autoHideYaml !== false;
    const folderName = (options.path?.split('/').at(-2) || options.workspaceName || '').toLowerCase();
    let focusMode = false, typewriter = false, selection = {anchor:0, head:0};
    let blocks = [], active = null, activeTable = null, field = null, mirror = null;
    let chooser = null, outlineJump = null;
    let composing = false, destroyed = false, pendingActions = [], pendingScroll = null;
    let tableWidths = [];
    let hits = [], currentHit = null, beforeSelection = null;
    const undo = [], redo = [], pendingAssets = new Set();
    const viewport = element('div','sima-editor cm-editor'), doc = element('article','sima-document');
    viewport.tabIndex = 0;
    viewport.setAttribute('aria-label',options.literal ? options.path : 'Markdown 编辑器');
    doc.setAttribute('aria-label','文稿正文');
    viewport.append(doc);
    host.replaceChildren(viewport);
    const renderOptions = {path:options.path || ''};
    const events = new AbortController();
    function on(target, name, fn, extra = {}) {target.addEventListener(name, fn, {...extra,signal:events.signal});}
    let filePreview, imageCaption, closeImagePreview;
    function clearImageSelection() {
      const input = imageCaption;
      if (!input) return;
      imageCaption = null;
      input.parentElement?.remove();
      input.finishImageEdit();
    }
    const detachScrollbar = window.SimaScrollbar.attach(viewport);
    const range = () => [Math.min(selection.anchor,selection.head),Math.max(selection.anchor,selection.head)];
    function pick(a,b=a) {selection={anchor:clamp(a,0,text.length),head:clamp(b,0,text.length)};}
    function eol(raw = text) {return raw.match(/\r\n|\n|\r/)?.[0] || '\n';}
    function write(from, to, inserted, after, record=true) {
      if (text.slice(from,to) === inserted) {if(after)pick(after.anchor,after.head);return;}
      if (record) {
        undo.push({from,old:text.slice(from,to),inserted,before:{...(beforeSelection||selection)},after:{...after}});
        if (undo.length>500) undo.shift();
        redo.length=0;
      }
      beforeSelection=null;
      const shift=inserted.length-(to-from);
      for (const p of pendingAssets) {
        const adjust = n => n < from ? n : n >= to ? n + shift : from + inserted.length;
        p.a=adjust(p.a);p.b=adjust(p.b);
      }
      text=text.slice(0,from)+inserted+text.slice(to);
      pick(after.anchor,after.head);
      hits=[];currentHit=null;
      filePreview?.refresh();
      mathView?.schedule(120);
      options.onChange?.();
    }
    function readField() {
      if (!field || !active) return;
      const raw=text.slice(active.start,active.end);
      const a=active.start+rawOffset(raw,field.selectionStart), b=active.start+rawOffset(raw,field.selectionEnd);
      if(field.selectionDirection==='backward') pick(b,a); else pick(a,b);
    }
    function readSelection() {
      if (field && document.activeElement===field && !composing) readField();
      else {
        const dom=window.getSelection();
        if(dom && !dom.isCollapsed && doc.contains(dom.anchorNode) && doc.contains(dom.focusNode)) {
          const a=sourcePoint(dom.anchorNode,dom.anchorOffset), b=sourcePoint(dom.focusNode,dom.focusOffset);
          if(a!=null && b!=null)pick(a,b);
        }
      }
    }
    function placeField(focus) {
      if (!field) return;
      const raw=text.slice(active.start,active.end);
      const [a,b]=range().map(n=>normalize(raw.slice(0,clamp(n-active.start,0,raw.length))).length);
      field.setSelectionRange(a,b,selection.head<selection.anchor?'backward':'forward');
      if (focus) field.focus({preventScroll:true});
    }
    function blockAt(n) {
      return blocks.find(b=>n>=b.start && n<=b.end) || blocks.find(b=>b.start>n) || blocks.at(-1);
    }
    let outlineText, outlineItems=[], parsedBlocks=[];
    const mathView=options.literal ? null : window.SimaMath?.preview(doc,parseBlocks);
    function parseBlocks() {
      if (outlineText===text) return parsedBlocks;
      const parsed=window.SimaRender.parse(text);
      parsedBlocks=parsed;
      outlineText=text;
      outlineItems=parsed.filter(b=>b.level).map(b=>({start:b.start,level:b.level,title:b.title}));
      return parsed;
    }
    function unpack() {
      const parsed=parseBlocks();
      let next=0;
      const list=[];
      function blanks(to) {
        while(next<to) {
          const match=/[^\r\n]*/y;match.lastIndex=next;
          const end=next+match.exec(text)[0].length;
          list.push({start:next,end,type:'blank',source:text.slice(next,end)});
          const linebreak=text.slice(end,end+2).match(/^(?:\r\n|\r|\n)/);
          next=end+(linebreak?.[0].length||0);
          if(!linebreak)break;
        }
      }
      for(const b of parsed) {
        if(b.start<next || b.end<b.start) continue;
        blanks(b.start);
        list.push({...b});
        next=b.end+(text.slice(b.end,b.end+2).match(/^(?:\r\n|\r|\n)/)?.[0].length||0);
      }
      blanks(text.length);
      if (!list.length || (/(?:\r|\n)$/.test(text) && list.at(-1).end<text.length)) {
        list.push({start:text.length,end:text.length,type:'blank',source:''});
      }
      return list;
    }
    function stamp(b) {b.node.dataset.start=b.start;b.node.dataset.end=b.end;}
    function paintInput() {
      if (!field || !mirror) return;
      const raw=text.slice(active.start,active.end);
      const intervals=[];
      if (!source) {
        const syntax=/^(?:#{1,6}(?=\s)|[ \t]*[-+*>](?=\s)|[ \t]*\d+[.)](?=\s))|\*\*[^*\n]+\*\*|__[^_\n]+__|~~[^~\n]+~~|==[^=\n]+==|`[^`\n]+`|\*[^*\n]+\*|\[[^\]\n]+\]\([^\n)]*\)/gm;
        for(const m of raw.matchAll(syntax)) {
          const token=m[0];
          const cls=token.startsWith('**')||token.startsWith('__')?'strong':token.startsWith('~~')?'strike':token.startsWith('==')?'mark':token.startsWith('`')?'code':token.startsWith('[')?'link':token.startsWith('*')&&token.length>1?'em':'punct';
          intervals.push([m.index,m.index+token.length,'sima-token-'+cls]);
        }
      }
      if (options.literal && /\.json$/i.test(options.path)) {
        const tokens=/"(?:\\[\s\S]|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null/g;
        for (const token of raw.matchAll(tokens)) {
          const string=token[0].startsWith('"');
          const key=string && /^\s*:/.test(raw.slice(token.index+token[0].length));
          const type=key?'key':string?'string':/^[tnf]/.test(token[0])?'literal':'number';
          intervals.push([token.index,token.index+token[0].length,'sima-token-json-'+type]);
        }
      }
      for(const hit of hits) if(hit.start<active.end && hit.start+hit.length>active.start) {
        intervals.push([Math.max(0,hit.start-active.start),Math.min(raw.length,hit.start+hit.length-active.start),sameHit(hit,currentHit)?'md-search-select':'md-search-hit']);
      }
      const cuts=[...new Set([0,raw.length,...intervals.flatMap(([a,b])=>[a,b])])].sort((a,b)=>a-b);
      const starts=new Map(),ends=new Map(),visible=new Set();
      for(const interval of intervals){
        const [a,b]=interval;
        if(a>=b)continue;
        if(!starts.has(a))starts.set(a,[]);
        if(!ends.has(b))ends.set(b,[]);
        starts.get(a).push(interval);ends.get(b).push(interval);
      }
      let html='';
      for(let i=1;i<cuts.length;i++){
        const a=cuts[i-1],b=cuts[i];
        for(const interval of ends.get(a)||[])visible.delete(interval);
        for(const interval of starts.get(a)||[])visible.add(interval);
        const cls=[...visible].map(v=>v[2]).join(' ');
        const content=escape(normalize(raw.slice(a,b)));
        html+=cls?'<span class="'+cls+'">'+content+'</span>':content;
      }
      mirror.innerHTML=html+'<i class="sima-line-end" aria-hidden="true">\u200b</i>';
      if (!source) {
        const line=/^([ \t]*)([-+*]|\d+[.)]|>)([ \t]+)(?:\[([ xX])\]([ \t]+))?/.exec(raw);
        const paragraphStyle=line?(line[2]==='>'?'quote':line[4]!==undefined?'task':/^\d/.test(line[2])?'ordered':'bullet'):'';
        active.node.dataset.paragraphStyle=paragraphStyle;
        const heading=/^(#{1,6})(?:\s|$)/.exec(raw);
        active.node.dataset.heading=heading?heading[1].length:'';
      }
    }
    function sameHit(a,b) {return !!a && !!b && a.start===b.start && a.length===b.length;}
    function fieldBlock(b, focus) {
      active=b;activeTable=null;
      b.node.classList.add('sima-active-block');
      const pair=element('div','sima-text-pair');
      field=element('textarea',source?'sima-source-input cm-content':'sima-block-input cm-content');
      field.rows=1;field.spellcheck=false;field.setAttribute('aria-label',options.literal?options.path:source?'Markdown 源码':'编辑当前段落');
      // A pre would pick up the theme's code font while the native caret uses the field font.
      mirror=element('div','sima-text-mirror');mirror.setAttribute('aria-hidden','true');
      field.value=normalize(text.slice(b.start,b.end));
      pair.append(mirror,field);b.node.append(pair);paintInput();placeField(focus);
    }
    function onTableChange(b,next,meta={},ordinal) {
      const prior=text.slice(b.start,b.end), d=difference(prior,next);
      const position=b.start+d.from+d.inserted.length;
      write(b.start+d.from,b.start+d.oldEnd,d.inserted,{anchor:position,head:position});
      if(meta.widthsBefore && meta.widthsAfter && undo.length){
        undo.at(-1).widths={ordinal,before:[...meta.widthsBefore],after:[...meta.widthsAfter]};
      }
      shiftBlock(b,next.length-prior.length);
    }
    function shiftBlock(b, delta) {
      if(!delta) return;
      b.end+=delta;stamp(b);
      if(source)return;
      for(const other of blocks.slice(blocks.indexOf(b)+1)) {
        other.start+=delta;other.end+=delta;stamp(other);
      }
    }
    function makeBlock(b) {
      const node=element('div','sima-block');b.node=node;
      node.dataset.kind=b.type;
      if (b.documentTitle) node.dataset.documentTitle = '';
      stamp(b);
      return node;
    }
    function yamlButton(b, preview) {
      const button=element('button','sima-yaml-toggle');button.type='button';
      button.setAttribute('aria-label','YAML');
      if (preview) {
        const show = visible => {
          if (!yamlCollapsed) return;
          preview.hidden = !visible;
          button.setAttribute('aria-expanded', String(visible));
        };
        b.node.onmouseenter = () => show(true);
        b.node.onmouseleave = () => show(false);
      } else {
        b.node.onmouseenter = b.node.onmouseleave = null;
      }
      button.setAttribute('aria-expanded',String(!preview || !yamlCollapsed));
      button.addEventListener('click',e=>{e.stopPropagation();action('view.yaml');});
      b.node.append(button);
    }
    // Extend the scroll range only when a heading near the document end needs it.
    function positionHeading(rect, viewportY) {
      const desired = viewport.scrollTop + rect.top - viewportY;
      const missing = Math.ceil(desired + viewport.clientHeight - viewport.scrollHeight);
      if (missing > 0) viewport.style.setProperty('--outline-tail',missing+'px');
      viewport.scrollTop = Math.max(0,desired);
    }
    function drawBlock(b) {
      const raw=text.slice(b.start,b.end);
      if (b.type==='yaml') {
        const preview=element('pre','md-meta-block');
        const lines=normalize(raw).split('\n');
        preview.textContent=lines.slice(1,-1).join('\n');
        preview.hidden=yamlCollapsed;
        yamlButton(b,preview);
        b.node.append(preview);
        return;
      }
      if (b.type==='blank')return;
      if(b.type==='table' && window.SimaTables?.parse(raw)) {
        const ordinal=blocks.filter(item=>item.type==='table' && item.start<b.start).length;
        b.table=window.SimaTables.mount(b.node,raw,{
          writeClipboard:options.writeTableClipboard,
          onError:error=>options.onError?.(error.message ?? String(error)),
          remove:()=>replace(b.start,b.end,''),

          widths:tableWidths[ordinal],onWidthsChange:widths=>{tableWidths[ordinal]=widths;},
          change:(next,meta)=>onTableChange(b,next,meta,ordinal),
          renderInline:window.SimaRender.inline ? s=>window.SimaRender.inline(s,{...b.context,...renderOptions,editableImages:true}):undefined,
          selection:(a,z)=>{activeTable=b;pick(b.start+a,b.start+z);},
          activate:()=>{activeTable=b;if(active && !source && active!==b)finishBlock();},
          openLink:(s,o)=>options.onLink?.(s,o),
          exit:direction=>{
            const other=blocks[blocks.indexOf(b)+direction];
            if (other) choose(direction<0 ? other.end : other.start);
            else if (direction>0) replace(text.length,text.length,eol()+eol());
          },
        });
      } else b.node.insertAdjacentHTML('beforeend',window.SimaRender.renderBlock({...b,source:raw}, {...renderOptions,editableImages:true}));
    }
    // Keep the Markdown blocks themselves intact for caret mapping and live table controls.
    function layoutPageHeader(parent) {
      const title = parseBlocks().find(b => b.documentTitle);
      const titleIndex = title ? blocks.findIndex(b => b.start === title.start && b.type === 'heading') : -1;
      const oldHeader = parent.querySelector('.sima-page-header');
      if (oldHeader) {
        const previousBlocks = oldHeader.querySelectorAll(':scope > .sima-block');
        if (titleIndex >= 0 && previousBlocks[previousBlocks.length - 1] === blocks[titleIndex].node) return;
        oldHeader.replaceWith(...previousBlocks);
      }
      if (titleIndex < 0) return;
      const header = element('header','sima-page-header');
      blocks[0].node.before(header);
      for (const b of blocks.slice(0, titleIndex + 1)) header.append(b.node);
      if (folderName) {
        const tag = element('span','sima-folder-tag');
        tag.textContent = '# ' + folderName;
        header.append(tag);
      }
    }
    function finishBlock() {
      // Only replace the text field leaving focus. Other live controls retain their DOM.
      const prev=active;if(!prev)return;
      active=null;field=null;mirror=null;
      const freshly=unpack().filter(b=>b.start>=prev.start && b.end<=prev.end);
      if(!freshly.length)return;
      const index=blocks.indexOf(prev);
      const fragment=document.createDocumentFragment();
      for(const b of freshly){fragment.append(makeBlock(b));drawBlock(b);}
      prev.node.replaceWith(fragment);blocks.splice(index,1,...freshly);
      if (prev.source !== text.slice(prev.start,prev.end)) layoutPageHeader(doc);
      mathView?.schedule();options.onOutlineChange?.();
    }
    function draw(edit, focus=false, preferTable=true) {
      closeImagePreview?.(); clearImageSelection();
      outlineJump=null;
      options.onOutlineChange?.();
      for(const b of blocks)b.table?.destroy();
      mathView?.schedule();
      active=null;activeTable=null;field=null;mirror=null;
      viewport.classList.toggle('sima-source',source);
      viewport.classList.toggle('sima-focus-mode',focusMode);
      viewport.classList.toggle('sima-typewriter',typewriter);
      if (source) {
        const b={type:'source',start:0,end:text.length};
        blocks=[b];doc.replaceChildren(makeBlock(b));fieldBlock(b,focus);return;
      }
      blocks=unpack();
      const desired={...selection};
      const [lo,hi]=range(), start=edit?blockAt(lo):null, end=edit?blockAt(hi):null;
      if(start && end && start!==end) {
        const first=blocks.indexOf(start),last=blocks.indexOf(end);
        blocks.splice(first,last-first+1,{start:start.start,end:end.end,type:'selection'});
      }
      const target=edit?blockAt(lo):null;
      const fragment=document.createDocumentFragment();
      for(const b of blocks) {
        fragment.append(makeBlock(b));
        if(b===target && (b.type!=='table'||!preferTable)) {
          if(b.type==='yaml')yamlButton(b);
          fieldBlock(b,false);
        } else drawBlock(b);
      }
      layoutPageHeader(fragment);
      const endEntry=element('div','sima-end-entry');
      endEntry.setAttribute('aria-label','在文末添加段落');
      fragment.append(endEntry);
      doc.replaceChildren(fragment);
      if(target?.table && focus) {
        const inside=target.table.focusAt(desired.anchor-target.start,desired.head-target.start);
        if(!inside) {pick(desired.anchor,desired.head);draw(true,focus,false);return;}
      } else if(field)placeField(focus);
      highlightRendered();
    }
    function choose(a,b=a,focus=true,preferTable=true) {
      pick(a,b);
      if(field && active && Math.min(a,b)>=active.start && Math.max(a,b)<=active.end && !activeTable) {
        placeField(focus);return;
      }
      draw(true,focus,preferTable);
    }
    function inputChange() {
      if(!field || !active || composing)return;
      const raw=text.slice(active.start,active.end), before=normalize(raw);
      const d=difference(before,field.value);
      if(d.from===d.oldEnd && !d.inserted){readField();return;}
      const l=rawOffset(raw,d.from),r=rawOffset(raw,d.oldEnd),ins=d.inserted.replace(/\n/g,eol(raw.includes('\n')?raw:text));
      const next=raw.slice(0,l)+ins+raw.slice(r);
      let a=active.start+rawOffset(next,field.selectionStart),b=active.start+rawOffset(next,field.selectionEnd);
      if(field.selectionDirection==='backward')[a,b]=[b,a];
      write(active.start+l,active.start+r,ins,{anchor:a,head:b});
      shiftBlock(active,next.length-raw.length);paintInput();
      if(!source && (d.inserted.includes('\n') || before.slice(d.from,d.oldEnd).includes('\n'))) {
        const parsed=unpack(), focusBlock=parsed.find(v=>selection.head>=v.start&&selection.head<=v.end);
        if(focusBlock && (focusBlock.start!==active.start || focusBlock.end!==active.end || focusBlock.type==='table')) draw(true,true);
      }
      if(typewriter)reveal('center');
    }
    function sourcePoint(node, offset) {
      const el=node?.nodeType===1?node:node?.parentElement;
      const wrapper=el?.closest('.sima-block');
      if(!wrapper || !doc.contains(wrapper))return null;
      const b=blocks.find(x=>x.node===wrapper);
      if(!b)return null;
      if(el.closest('textarea'))return b.start;
      const mapped=mapNodes(b);
      const found=mapped.find(x=>x.node===node);
      if(found)return b.start+found.positions[clamp(offset,0,found.positions.length-1)];
      if(node.nodeType===1){
        const children=node.childNodes;
        for(let i=offset;i<children.length;i++){
          const next=mapped.find(x=>children[i].contains(x.node));
          if(next)return b.start+next.positions[0];
        }
        for(let i=offset-1;i>=0;i--){
          const previous=mapped.findLast(x=>children[i].contains(x.node));
          if(previous)return b.start+previous.positions.at(-1);
        }
      }
      return offset?b.end:b.start;
    }
    // Build source positions only on demand. Markdown punctuation and link targets have no visible glyph.
    function mapNodes(b) {
      const raw=text.slice(b.start,b.end), result=[];
      let cursor=b.type==='yaml' ? (raw.match(/^[^\r\n]*(?:\r\n|\r|\n)/)?.[0].length || 0) : 0;
      const walker=document.createTreeWalker(b.node,NodeFilter.SHOW_TEXT);
      while(walker.nextNode()) {
        const node=walker.currentNode, parent=node.parentElement;
        if(parent.closest('button,textarea,.sima-image-caption,.sima-text-mirror,.sima-table-toolbar,svg,math'))continue;
        const str=node.data;
        // Markdown-it inserts formatting newlines between block elements.
        // Mapping those to source offsets skips the first row or list item.
        if (!str.trim() && parent.matches('.sima-block,ul,ol,li,blockquote,table,thead,tbody,tr') && str.includes('\n')) continue;
        if(!str || str==='\u200b')continue;
        let begin=raw.indexOf(str,cursor), positions=[];
        if(begin>=0) {
          for(let i=0;i<=str.length;i++)positions.push(begin+i);
        } else {
          let at=cursor;
          for(let i=0;i<str.length;i++){const k=raw.indexOf(str[i],at);if(k<0){positions=[];break;}positions.push(k);at=k+1;}
          if(positions.length)positions.push(at);
        }
        if(positions.length){result.push({node,positions});cursor=positions.at(-1);}
        if(parent.tagName==='A' && !node.nextSibling && raw.startsWith('](',cursor)){
          const end=raw.indexOf(')',cursor+2);if(end>=0)cursor=end+1;
        }
      }
      return result;
    }
    function highlightRendered() {
      for(const mark of doc.querySelectorAll('mark[data-editor-hit]'))mark.replaceWith(...mark.childNodes);
      if(!hits.length || source)return;
      for(const b of blocks) {
        if(b===active)continue;
        const local=hits.filter(h=>h.start<b.end && h.start+h.length>b.start);
        if(!local.length)continue;
        for(const {node,positions} of mapNodes(b)){
          const matches=[];
          for(const h of local){
            const a=positions.findIndex(x=>x+b.start>=h.start),z=positions.findIndex(x=>x+b.start>=h.start+h.length);
            const l=Math.max(0,a),r=z===-1?node.length:z;
            if(a!==-1 && l<r) matches.push({l,r,h});
          }
          if(!matches.length)continue;
          const fragment=document.createDocumentFragment();let end=0;
          for(const {l,r,h} of matches.sort((a,b)=>a.l-b.l)){
            if(l<end)continue;
            fragment.append(node.data.slice(end,l));const mark=element('mark',sameHit(h,currentHit)?'md-search-select':'md-search-hit');
            mark.dataset.editorHit='';mark.textContent=node.data.slice(l,r);fragment.append(mark);end=r;
          }
          fragment.append(node.data.slice(end));node.replaceWith(fragment);
        }
      }
    }
    function caretRect(position) {
      if(!field || !mirror || position<active.start || position>active.end)return null;
      const target=normalize(text.slice(active.start,position)).length;
      const walker=document.createTreeWalker(mirror,NodeFilter.SHOW_TEXT);
      let remain=target, rect;
      while(walker.nextNode()) {
        const node=walker.currentNode;
        if(remain<=node.length){
          const r=document.createRange();r.setStart(node,remain);r.collapse(true);rect=r.getBoundingClientRect();break;
        }
        remain-=node.length;
      }
      return rect;
    }
    function viewportAnchor() {
      const top=viewport.getBoundingClientRect().top;
      const block=blocks.find(b=>b.node.getBoundingClientRect().bottom>top) || blocks.at(-1);
      if(!block)return null;
      if(block!==active || !mirror)return {at:block.start,dy:block.node.getBoundingClientRect().top-top};
      let lo=block.start,hi=block.end;
      while(lo<hi){
        const m=Math.floor((lo+hi)/2),r=caretRect(m);
        if(r && r.bottom<=top)lo=m+1;else hi=m;
      }
      const r=caretRect(lo);
      return {at:lo,dy:(r?.top??block.node.getBoundingClientRect().top)-top};
    }
    function restoreAnchor(anchor) {
      if(!anchor)return;
      const rect=caretRect(anchor.at)||blockAt(anchor.at)?.node.getBoundingClientRect();
      if(rect)viewport.scrollTop+=rect.top-viewport.getBoundingClientRect().top-anchor.dy;
    }
    function reveal(align='nearest') {
      const rect=caretRect(selection.head);
      if(!rect?.height){blockAt(selection.head)?.node.scrollIntoView({block:align});return;}
      const view=viewport.getBoundingClientRect();
      if(align==='center')viewport.scrollTop+=rect.top-view.top-(view.height-rect.height)/2;
      else if(rect.top<view.top+12)viewport.scrollTop+=rect.top-view.top-12;
      else if(rect.bottom>view.bottom-12)viewport.scrollTop+=rect.bottom-view.bottom+12;
    }
    function replace(from,to,value,cursor=value.length,end=cursor) {
      const next=value.replace(/\r\n|\r|\n/g,eol());
      const convert=n=>value.slice(0,n).replace(/\r\n|\r|\n/g,eol()).length;
      write(from,to,next,{anchor:from+convert(cursor),head:from+convert(end)});
      draw(true,true);reveal(typewriter?'center':'nearest');
    }
    function changeList(command) {
      const [lo, hi] = range(), parsed = parseBlocks();
      const ix = parsed.findIndex(b => b.listItems && b.start <= lo && lo <= b.end);
      if (ix < 0) return false;
      // Adjacent marker styles may be parsed as separate Markdown lists.
      let first = ix, last = ix;
      const adjacent = (left, right) => left?.listItems && right?.listItems &&
        /^(?:\r\n|\r|\n)$/.test(text.slice(left.end, right.start));
      while (adjacent(parsed[first - 1], parsed[first])) first--;
      while (adjacent(parsed[last], parsed[last + 1])) last++;
      const start = parsed[first].start, end = parsed[last].end;
      if (hi > end) return false;
      const raw = text.slice(start, end), outline = clipboardList(raw);
      if (!outline) return false;
      const a = outline.position(normalize(text.slice(start, lo)).length);
      const z = outline.position(normalize(text.slice(start, hi)).length);
      if (!a || !z) return false;
      let from = a, to = z;
      if (command === 'indent') {
        const heads = outline.rows.filter(r => r.node && r.from <= z.row.to && r.to >= a.row.from);
        if (!heads.length && a.row.owner) heads.push(a.row.owner);
        const selected = new Set(heads);
        if (!heads.length || !outline.move(heads.filter(r => !selected.has(r.parent)), false)) return true;
      } else if (command === 'enter') {
        if (a.row !== z.row || lo - start < rawOffset(raw, a.row.textAt)) return false;
        from = to = outline.split(a, z);
        if (!from) return false;
      }
      let next = outline.write();
      const shift = !outline.rows[0].mark && start > 0 && !/\n[ \t]*\n$/.test(normalize(text.slice(0,start))) ? 1 : 0;
      if (shift) next = '\n' + next;
      const offset = pos => shift + pos.row.offset + pos.offset;
      const backwards = selection.anchor > selection.head;
      replace(start,end,next,offset(backwards ? to : from),offset(backwards ? from : to));
      return true;
    }
    function outdentList() {
      const edits = listOutdentEdits(text, parseBlocks(), ...range());
      if (!edits.length) return false;
      const start = edits[0].at;
      let end = start, inserted = '';
      function mapped(offset) {
        let delta = 0;
        for (const {at, remove, insert, separator = ''} of edits) {
          if (offset < at) break;
          if (offset <= at + remove) return at + delta + separator.length + Math.min(offset - at, insert.length);
          delta += separator.length + insert.length - remove;
        }
        return offset + delta;
      }
      for (const {at, remove, insert, separator = ''} of edits) {
        inserted += text.slice(end, at) + separator + insert;
        end = at + remove;
      }
      beforeSelection = null;
      write(start, end, inserted, {anchor:mapped(selection.anchor), head:mapped(selection.head)});
      draw(true, true, false);
      return true;
    }
    function history(reverse) {
      beforeSelection=null;
      const src=reverse?redo:undo,dest=reverse?undo:redo,entry=src.pop();
      if(!entry)return false;
      if (imageCaption?.restoreImageEdit(entry, reverse)) {
        dest.push(entry);
        return true;
      }
      const gone=reverse?entry.old:entry.inserted, ins=reverse?entry.inserted:entry.old;
      write(entry.from,entry.from+gone.length,ins,reverse?entry.after:entry.before,false);
      if(entry.widths)tableWidths[entry.widths.ordinal]=entry.widths[reverse?'after':'before'];
      dest.push(entry);draw(!entry.imageLayout,!entry.imageLayout);reveal();return true;
    }
    function focus() {
      if(composing || host.contains(document.activeElement) && document.activeElement.tagName==='TEXTAREA')return;
      readSelection();
      if(activeTable?.table && selection.anchor===selection.head)activeTable.table.focusAt?.(selection.head-activeTable.start);
      else {
        const first=blockAt(selection.head);
        if(first?.type==='yaml' && yamlCollapsed && selection.anchor===selection.head){
          const body=blocks.find(b=>b.start>first.end && b.type!=='blank');
          if(body){choose(body.start);return;}
        }
        choose(selection.anchor,selection.head);
      }
    }
    function locate(start,length=0,viewportY=null) {
      const a=clamp(Math.trunc(start)||0,0,text.length),b=clamp(a+(Math.trunc(length)||0),0,text.length);
      if(b>a) {currentHit={start:a,length:b-a};if(!hits.some(h=>sameHit(h,currentHit)))hits=[currentHit];}
      choose(a,b,true,true);
      paintInput();highlightRendered();
      if (Number.isFinite(viewportY)) {
        const rect=caretRect(a) || doc.querySelector('td.editing,th.editing')?.getBoundingClientRect() || blockAt(a)?.node.getBoundingClientRect();
        if(rect) viewport.scrollTop+=rect.top-viewportY;
      } else reveal('center');
    }
    function goToBeginning(ranges = []) {
      if (composing) { pendingActions.push(() => goToBeginning(ranges)); return; }
      pick(0,0);
      if (source || active || activeTable) draw(source,false);
      currentHit=null;
      setHighlights(ranges,null);
      pendingScroll=0;
      syncVisible();
    }
    function showSearchResult(ranges,hit) {
      if (composing) { pendingActions.push(()=>showSearchResult(ranges,hit)); return; }
      if (source) {
        if (hit) locate(hit.start,hit.length);
        setHighlights(ranges,hit);
        return;
      }
      if (hit) pick(hit.start,hit.start+hit.length);
      // A search jump is a reading action. Finish any active edit before
      // resolving the hit against rendered text, including long list items.
      if (active || activeTable || doc.querySelector('.editing')) draw(false);
      const target=hit && blockAt(selection.anchor);
      if (target?.type==='yaml' && yamlCollapsed) {
        target.node.querySelector('.md-meta-block').hidden=false;
        target.node.querySelector('.sima-yaml-toggle').setAttribute('aria-expanded','true');
      }
      setHighlights(ranges,hit);
      if (target) {
        const mark=target.node.querySelector('mark.md-search-select');
        (mark || target.node).scrollIntoView({block:'center'});
      }
    }
    function outline() {
      if (outlineText!==text) parseBlocks();
      return outlineItems;
    }
    function centeredHeading(items) {
      if (outlineJump && Math.abs(outlineJump.scrollTop-viewport.scrollTop)<1 &&
          items.some(item=>item.start===outlineJump.start)) return outlineJump.start;
      outlineJump=null;
      const center=viewport.getBoundingClientRect().top+viewport.clientHeight/2;
      let lo=0,hi=items.length;
      while(lo<hi) {
        const mid=(lo+hi)>>>1;
        const item=items[mid];
        const rect=item.node ? item.node.getBoundingClientRect() : caretRect(item.start);
        if(rect && rect.top<=center) lo=mid+1; else hi=mid;
      }
      return items[Math.max(0,lo-1)]?.start;
    }
    function outlineLocations() {
      const items=outline();
      if(source) return items;
      const nodes=new Map(blocks.map(b=>[b.start,b.node]));
      return items.flatMap(h=>{
        const block=nodes.get(h.start);
        if (active?.type==='selection' && h.start>=active.start && h.start<=active.end) return [h];
        if (!block) return [];
        const heading=block.querySelector('h1,h2,h3,h4,h5,h6');
        return [{...h,title:heading?.textContent || h.title,node:heading || block}];
      });
    }
    function goToHeading(start) {
      if(composing) { pendingActions.push(()=>goToHeading(start)); return; }
      pick(start);
      let rect;
      viewport.style.removeProperty('--outline-tail');
      if(source) {
        placeField(true);
        rect=caretRect(start);
      } else {
        if(active || activeTable || doc.querySelector('.editing')) draw(false);
        const target=blockAt(start);
        if (!target) return;
        const heading=target.node.querySelector('h1,h2,h3,h4,h5,h6');
        rect=(heading || target.node).getBoundingClientRect();
      }
      if (rect) {
        const lineHeight=parseFloat(getComputedStyle(doc).lineHeight) || 26;
        const inset=Math.min(lineHeight*2.5,viewport.clientHeight*0.22);
        positionHeading(rect,viewport.getBoundingClientRect().top+inset);
        outlineJump={start,scrollTop:viewport.scrollTop};
      }
      options.onOutlineChange?.();
    }
    function setHighlights(ranges,current) {
      hits=(Array.isArray(ranges)?ranges:[]).filter(h=>Number.isFinite(h.start)&&h.length>0);
      currentHit=typeof current==='number'?hits[current]:current || hits.find(h=>sameHit(h,currentHit));
      paintInput();highlightRendered();
    }
    function chooseTableSize() {
      if(chooser){chooser.querySelector('input').focus();return;}
      chooser=element('dialog','sima-table-size');
      chooser.setAttribute('aria-label','插入表格');
      const form=element('form','sima-size-form');
      const title=element('h3','');title.textContent='插入表格';form.append(title);
      const inputs=['行数（含表头）','列数'].map(label=>{
        const wrap=element('label',''),input=element('input','');wrap.append(label);
        input.type='number';input.min='1';input.max='100';input.required=true;input.value='3';
        wrap.append(input);form.append(wrap);return input;
      });
      const footer=element('div','sima-size-actions'),cancel=element('button',''),insert=element('button','sima-primary');
      cancel.type='button';cancel.textContent='取消';insert.type='submit';insert.textContent='插入';
      footer.append(cancel,insert);form.append(footer);chooser.append(form);host.append(chooser);
      const close=()=>{chooser.close();chooser.remove();chooser=null;};
      cancel.onclick=()=>{close();focus();};
      chooser.addEventListener('cancel',e=>{e.preventDefault();close();focus();});
      chooser.addEventListener('keydown',e=>e.stopPropagation());
      form.onsubmit=e=>{e.preventDefault();const [rows,columns]=inputs.map(i=>i.valueAsNumber);close();selectedAction('table.insert',{rows,columns});};
      chooser.showModal();inputs[0].select();
    }
    function selectedAction(id,arg) {
      const [from,to]=range(), value=text.slice(from,to);
      if(id==='insertText') {
        const inserted=typeof arg==='object'?String(arg?.text??''):String(arg??'');
        replace(from,to,inserted,clamp(arg?.cursor??inserted.length,0,inserted.length));return true;
      }
      const tokens={math:'$',bold:'**',italic:'*',strike:'~~',highlight:'==',code:'`'};
      if(id.startsWith('format.') && tokens[id.slice(7)]) {
        const t=tokens[id.slice(7)];
        if(value.startsWith(t) && value.endsWith(t) && value.length>=2*t.length) {
          const inner=value.slice(t.length,-t.length);replace(from,to,inner,0,inner.length);
        } else if(text.slice(from-t.length,from)===t && text.slice(to,to+t.length)===t)replace(from-t.length,to+t.length,value,0,value.length);
        else replace(from,to,t+value+t,t.length,t.length+value.length);return true;
      }
      const br=eol();
      if(id==='table.insert') {
        if(!arg){chooseTableSize();return true;}
        const raw=window.SimaTables.create(arg?.rows||3,arg?.columns||3);
        const prefix=from && !text.slice(0,from).endsWith(br+br)?(text.slice(0,from).endsWith(br)?br:br+br):'';
        const suffix=to<text.length && !text.slice(to).startsWith(br+br)?(text.slice(to).startsWith(br)?br:br+br):'';
        replace(from,to,prefix+raw+suffix,prefix.length+2);return true;
      }
      if(id.startsWith('table.'))return activeTable?.table?.action(id,arg) || false;
      if(!id.startsWith('paragraph.'))return false;
      const kind=id.slice(10);
      if(kind==='toc') {replace(from,to,'[TOC]');return true;}
      const wrappers={code:['```','```'],math:['$$','$$'],mermaid:['```mermaid','```']};
      if(wrappers[kind]){
        const [open,close]=wrappers[kind],content=value||(kind==='mermaid'?'flowchart TD\n  A --> B':'');
        const before = kind==='math' && from && !/[\r\n]/.test(text[from-1]) ? br : '';
        const after = kind==='math' && to<text.length && !/[\r\n]/.test(text[to]) ? br : '';
        const pos = before.length+open.length+br.length;
        replace(from,to,before+open+br+content+br+close+after,pos,pos+content.length);return true;
      }
      const prefixes={paragraph:'',quote:'> ',bullet:'- ',ordered:'1. ',task:'- [ ] '};
      const prefix=/^h[1-6]$/.test(kind)?'#'.repeat(+kind[1])+' ':prefixes[kind];
      if(prefix===undefined)return false;
      const start=from===0?0:Math.max(text.lastIndexOf('\n',from-1),text.lastIndexOf('\r',from-1))+1;
      const last=Math.max(from,to-1), tail=text.slice(last).search(/[\r\n]/);
      const end=tail<0?text.length:last+tail;
      const line=text.slice(start,end), converted=line.replace(/^([ \t]*)(?:#{1,6}[ \t]+|>[ \t]*|(?:[-*+]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)?/gm,(_,indent)=>indent+prefix);
      const at=clamp(from-start+converted.length-line.length,0,converted.length);
      if(from===to)replace(start,end,converted,at);else replace(start,end,converted,0,converted.length);
      return true;
    }
    function action(id,arg) {
      if(composing){pendingActions.push(()=>action(id,arg));return;}
      readSelection();
      if(id==='list.outdent')return outdentList();
      if(id==='list.indent')return changeList('indent');
      if(id==='edit.undo'||id==='edit.redo')return history(id==='edit.redo');
      if(options.literal && !['edit.selectAll','edit.copy','edit.cut','edit.paste','insertText'].includes(id))return false;
      if(id==='view.source') {
        const reading=viewportAnchor();source=!source;viewport.style.removeProperty('--outline-tail');draw(true,true);restoreAnchor(reading);return true;
      }
      if(id==='view.yaml'){
        yamlCollapsed=active?.type==='yaml' || !yamlCollapsed;
        if(!source) {
          const y=blocks.find(b=>b.type==='yaml');
          if(y) {
            if(y===active && yamlCollapsed) {
              finishBlock();
            } else {
              const preview=y.node.querySelector('.md-meta-block');
              if(preview) preview.hidden=yamlCollapsed;
              y.node.querySelector('.sima-yaml-toggle')?.setAttribute('aria-expanded',String(!yamlCollapsed));
            }
            options.onViewChange?.();
          }
        }
        return true;
      }
      if(id==='view.focus'||id==='view.typewriter'){
        if(id==='view.focus')focusMode=!focusMode;else typewriter=!typewriter;
        viewport.classList.toggle('sima-focus-mode',focusMode);viewport.classList.toggle('sima-typewriter',typewriter);
        if(typewriter)reveal('center');return true;
      }
      if(id==='edit.selectAll' && imageCaption && document.activeElement===imageCaption){imageCaption.select();return true;}
      if(id==='edit.selectAll'){pick(0,text.length);draw(true,true,false);return true;}
      if(id==='edit.copy'||id==='edit.cut'||id==='edit.paste'){
        focus();return document.execCommand(id.slice(5));
      }
      return selectedAction(id,arg);
    }
    function syncVisible() {
      if (host.hidden) { closeImagePreview?.(); clearImageSelection(); }
      if(!host.hidden && host.isConnected){
        for(const other of document.querySelectorAll('.sima-document#write'))if(other!==doc)other.removeAttribute('id');
        doc.id='write';
        if(pendingScroll!==null){viewport.scrollTop=pendingScroll;pendingScroll=null;}
      } else doc.removeAttribute('id');
    }
    const visibility=new MutationObserver(syncVisible);visibility.observe(host,{attributes:true,attributeFilter:['hidden']});
    function getState() {
      readSelection();
      return {selection:{...selection},reading:!active && !activeTable,source,yamlPinned:!yamlCollapsed,focusMode,typewriter,tableWidths:tableWidths.map(w=>w&&[...w]),scrollTop:pendingScroll??viewport.scrollTop};
    }
    function setState(state={}) {
      tableWidths=Array.isArray(state.tableWidths)?state.tableWidths.map(w=>Array.isArray(w)?w.slice():[]):[];
      source=!!options.literal || !!state.source;yamlCollapsed=!(state.yamlPinned ?? (options.settings?.autoHideYaml === false));focusMode=!!state.focusMode;typewriter=!!state.typewriter;
      const s=state.selection?.ranges?.[0] || state.selection || {};
      pick(s.anchor??s.from??0,s.head??s.to??s.anchor??0);
      const parsed=source ? [] : unpack();
      const isYaml=parsed.find(b=>b.type==='yaml' && selection.head>=b.start && selection.head<=b.end);
      const edit=source || !state.reading && !!(selection.anchor || selection.head) && !(isYaml && yamlCollapsed);
      draw(edit,false);
      pendingScroll=Number(state.scrollTop)||0;syncVisible();
    }
    function setText(next) {
      text=String(next??'');undo.length=redo.length=0;hits=[];currentHit=null;
      pick(selection.anchor,selection.head);draw(false,false);filePreview?.refresh();
    }
    function rangeAtPoint(x,y) {
      const range=document.caretRangeFromPoint?.(x,y);
      if(range)return range;
      const p=document.caretPositionFromPoint?.(x,y);
      if(!p)return null;
      const caret=document.createRange();
      caret.setStart(p.offsetNode,p.offset);caret.collapse(true);
      return caret;
    }
    function hitPoint(x,y) {
      const r=rangeAtPoint(x,y);
      return r?sourcePoint(r.startContainer,r.startOffset):null;
    }
    function editAtClick(b,caret,anchor,head) {
      const line=caret?.getBoundingClientRect();
      const blockTop=b.node.getBoundingClientRect().top;
      // An edit can change Markdown structure or reference definitions in other blocks.
      if (anchor<b.start || head<b.start || anchor>b.end || head>b.end || b.table ||
          (active && (active===b || active.source!==text.slice(active.start,active.end)))) {
        choose(anchor,head,true,false);
      } else {
        const previous=active;
        finishBlock();
        pick(anchor,head);
        outlineJump=null;
        b.node.replaceChildren();
        if(b.type==='yaml')yamlButton(b);
        fieldBlock(b,true);
        if(previous && hits.length) highlightRendered();
        options.onOutlineChange?.();
      }
      // Rendered lists and wrapped links can have a very different height in source.
      // Keep the clicked line at the same screen coordinate after layout and focus.
      const editedLine=line?.height ? caretRect(head) : null;
      if(editedLine?.height) viewport.scrollTop+=editedLine.top-line.top;
      else if(active) viewport.scrollTop+=active.node.getBoundingClientRect().top-blockTop;
    }
    // WebKit returns the nearest caret even for a click in the margin or
    // well beyond a line's last glyph. Only actual text should activate it.
    function searchWhitespace(e) {
      if ((!hits.length && !options.isSearchActive?.()) || source || !text.length || e.button !== 0) return false;
      const target=e.target;
      if (target===viewport || target===doc) return true;
      if (!doc.contains(target) || target.closest('textarea,button,a,input,summary,.sima-text-pair,.sima-table-block')) return false;
      const block=target.closest('.sima-block');
      if (!block) return false;
      if (block.dataset.kind==='blank') return true;
      if (target.closest('img,svg,math,pre,hr')) return false;
      const caret=document.caretRangeFromPoint?.(e.clientX,e.clientY);
      const pos=caret ? null : document.caretPositionFromPoint?.(e.clientX,e.clientY);
      const node=caret?.startContainer ?? pos?.offsetNode;
      if (!node) return target===block;
      if (node.nodeType!==Node.TEXT_NODE || !block.contains(node)) return true;
      const offset=caret?.startOffset ?? pos.offset, around=document.createRange();
      around.setStart(node,Math.max(0,offset-1));
      around.setEnd(node,Math.min(node.length,offset+1));
      return !Array.from(around.getClientRects()).some(r=>
        e.clientX>=r.left && e.clientX<=r.right && e.clientY>=r.top && e.clientY<=r.bottom);
    }
    function imageEnd(grip) {
      const box = grip.closest('.sima-block'), block = blocks.find(b => b.node === box);
      if (!block) return null;
      const raw = text.slice(block.start, block.end), offset = Number(grip.dataset.offset);
      const cell = grip.closest('[data-row][data-column]');
      if (!cell) return block.start + rawOffset(raw, offset);
      const model = window.SimaTables.parse(raw);
      const start = model?.rows[cell.dataset.row]?.[cell.dataset.column]?.start;
      return start == null ? null : block.start + start + offset;
    }
    function editImageSource(frame, top) {
      const grip = frame.querySelector('.sima-image-grip'), img = frame.querySelector('img');
      const block = blocks.find(b => b.node === frame.closest('.sima-block'));
      const imageSyntaxEnd = imageEnd(grip);
      if (!block || imageSyntaxEnd == null) return;
      const end = imageSyntaxEnd + window.SimaRender.imageLayout.exec(text.slice(imageSyntaxEnd))[0].length;
      const syntax = frame.dataset.imageSource;
      // Markdown-it normalizes newlines. Check the exact occurrence before editing.
      const raw = text.slice(block.start, end);
      const normalized = normalize(raw);
      const offset = normalized.length - syntax.length;
      if (offset < 0 || !normalized.endsWith(syntax)) return;
      const start = block.start + rawOffset(raw, offset);
      const cell = frame.closest('[data-row][data-column]');
      const localStart = Number(grip.dataset.offset) - normalize(text.slice(start, imageSyntaxEnd)).length;
      const caption = element('span', 'sima-image-source');
      const input = element('textarea', 'sima-image-caption');
      input.rows = 1;
      input.spellcheck = false;
      input.setAttribute('aria-label', 'Markdown');
      input.value = text.slice(start, end);
      caption.dataset.source = input.value;
      const context = {...block.context, ...renderOptions, editableImages:true};
      let length = end - start, edited = false;
      function renderValue() {
        const fragment = document.createElement('template');
        fragment.innerHTML = window.SimaRender.inline(input.value, context);
        for (const handle of fragment.content.querySelectorAll('.sima-image-grip')) {
          handle.dataset.offset = localStart + Number(handle.dataset.offset);
        }
        return fragment.content;
      }
      input.finishImageEdit = () => {
        if (!edited || !frame.isConnected) return;
        const outer = frame.parentElement?.hasAttribute('data-image-align') ? frame.parentElement : frame;
        outer.replaceWith(renderValue());
      };
      function update(record = true) {
        caption.dataset.source = input.value;
        const old = text.slice(start, start + length);
        if (normalize(old) === input.value) return;
        const value = input.value.replace(/\n/g, eol(old.includes('\n') ? old : text));
        const change = difference(old, value);
        write(start + change.from, start + change.oldEnd, change.inserted, {
          anchor:start + rawOffset(value,input.selectionStart), head:start + rawOffset(value,input.selectionEnd)
        }, record);
        if (record) {
          undo.at(-1).imageStart = start;
          undo.at(-1).imageLayout = true;
        }
        const delta = value.length - length;
        shiftBlock(block, delta);
        const peers = (cell || block.node).querySelectorAll('.sima-image-grip');
        const oldEnd = localStart + normalize(old).length;
        for (const peer of peers) if (peer !== grip && Number(peer.dataset.offset) >= oldEnd) {
          peer.dataset.offset = Number(peer.dataset.offset) + input.value.length - normalize(old).length;
        }
        length = value.length;
        edited = true;
        if (cell) block.table?.syncImageSource(text.slice(block.start, block.end), cell);
        const rendered = renderValue();
        const next = rendered.querySelector('.sima-sized-image');
        if (next && next.dataset.imageSource === input.value) {
          const picture = next.querySelector('img');
          for (const attr of ['src','alt','title','width','data-markdown-src','data-wiki-image']) {
            if (!picture.hasAttribute(attr)) img.removeAttribute(attr);
            else if (img.getAttribute(attr) !== picture.getAttribute(attr)) img.setAttribute(attr, picture.getAttribute(attr));
          }
          frame.classList.toggle('sima-fluid-svg',next.classList.contains('sima-fluid-svg'));
          grip.dataset.offset = next.querySelector('.sima-image-grip').dataset.offset;
        }
      }
      function selectSource() {
        const selected = text.slice(start, start + length);
        pick(start + rawOffset(selected,input.selectionStart), start + rawOffset(selected,input.selectionEnd));
      }
      input.restoreImageEdit = (entry, reverse) => {
        if (entry.imageStart !== start) return false;
        const old = text.slice(start, start + length), at = entry.from - start;
        const gone = reverse ? entry.old : entry.inserted, added = reverse ? entry.inserted : entry.old;
        if (old.slice(at, at + gone.length) !== gone) return false;
        const next = old.slice(0, at) + added + old.slice(at + gone.length);
        const target = reverse ? entry.after : entry.before;
        const index = n => normalize(next.slice(0, clamp(n - start, 0, next.length))).length;
        const left = index(Math.min(target.anchor,target.head)), right = index(Math.max(target.anchor,target.head));
        input.value = normalize(next);
        input.setSelectionRange(left, right, target.head < target.anchor ? 'backward' : 'forward');
        update(false);
        return true;
      };
      input.onselect = selectSource;
      input.onbeforeinput = selectSource;
      input.oninput = e => {
        if (e.isComposing) caption.dataset.source = input.value;
        else update();
      };
      input.oncompositionend = () => update();
      input.onkeydown = e => {
        if (!e.isComposing && !composing && ['Enter','Escape'].includes(e.key)) {
          e.preventDefault(); clearImageSelection();
        }
        if (!(e.metaKey || e.ctrlKey) || ['a','x','c','v'].includes(e.key.toLowerCase())) e.stopPropagation();
      };
      for (const event of ['copy','cut','paste','dblclick']) input.addEventListener(event,e=>e.stopPropagation());
      imageCaption = input;
      caption.append(input);
      frame.prepend(caption);
      activeTable = null;
      input.focus({preventScroll:true});
      input.setSelectionRange(input.value.length,input.value.length);
      selectSource();
      // Flow the source into the document while keeping a second click on the image.
      viewport.scrollTop += img.getBoundingClientRect().top - top;
    }
    function selectImageAt(start, viewportY) {
      draw(false);
      const frame = [...doc.querySelectorAll('.sima-sized-image')].find(candidate => {
        const end = imageEnd(candidate.querySelector('.sima-image-grip'));
        if (end == null) return false;
        const layout = window.SimaRender.imageLayout.exec(text.slice(end))[0];
        return end + layout.length - candidate.dataset.imageSource.length === start;
      });
      if (!frame) { locate(start, 0, viewportY); return; }
      const top = frame.getBoundingClientRect().top;
      if (Number.isFinite(viewportY)) viewport.scrollTop += top - viewportY;
      editImageSource(frame, frame.getBoundingClientRect().top);
    }
    function saveImageLayout(grip, changes, refocus = false) {
      const pos = imageEnd(grip);
      if (pos == null) return;
      const [old, oldWidth, oldAlign] = window.SimaRender.imageLayout.exec(text.slice(pos));
      const {width = oldWidth, align = oldAlign} = changes;
      const next = (width ? '{width=' + width + '}' : '') + (align ? '{align=' + align + '}' : '');
      if (old === next) return;
      write(pos, pos + old.length, next, {anchor:pos, head:pos});
      undo.at(-1).imageLayout = true;
      draw(false);
      if (refocus) [...doc.querySelectorAll('.sima-image-grip')].find(g => imageEnd(g) === pos)?.focus({preventScroll:true});
    }
    let resizing = null, swallowResizeClick = false;
    on(viewport, 'contextmenu', e => {
      if (e.target === imageCaption) { e.stopPropagation(); return; }
      const grip = e.target.closest('.sima-sized-image')?.querySelector('.sima-image-grip');
      if (!grip || composing || !options.onImageMenu) return;
      e.stopPropagation();
      const current = grip.closest('[data-image-align]')?.dataset.imageAlign;
      const choices = [['left','图片居左'],['center','图片居中'],['right','图片居右']];
      const items = choices.map(([align,label]) =>
        [label, () => saveImageLayout(grip,{align}), align===current ? 'check' : null]);
      const image = grip.previousElementSibling;
      const point = {x:e.clientX,y:e.clientY};
      const useNative = e.target === image;
      // Preserve WebKit's default menu on the image itself, including linked-image actions.
      e.preventDefault();
      const bodyEnd = imageEnd(grip);
      if (bodyEnd == null) return;
      const end = bodyEnd + window.SimaRender.imageLayout.exec(text.slice(bodyEnd))[0].length;
      const raw = grip.closest('.sima-sized-image').dataset.imageSource;
      const start = end - raw.length;
      options.onImageMenu(point, image, items, useNative, {raw, start:text.slice(start,end) === raw ? start : null});
    }, {capture:true});
    on(viewport, 'pointerdown', e => {
      swallowResizeClick = false;
      const frame = e.target.closest('.sima-sized-image');
      if (!frame && !e.target.closest('dialog')) clearImageSelection();
      if (e.button === 0 && frame && !e.target.closest('.sima-image-grip')) {
        // A table cell normally switches to its text field on pointer-down.
        e.stopPropagation();
        if (e.target.matches('img')) e.preventDefault();
        return;
      }
      if ((e.button===2 || e.ctrlKey) && e.target.closest('.sima-sized-image')) {
        e.stopPropagation();
        return;
      }
      const grip = e.target.closest('.sima-image-grip');
      if (!grip || composing || e.button !== 0) return;
      e.stopPropagation();
      e.preventDefault();
      const img = grip.previousElementSibling;
      const align = grip.closest('[data-image-align]')?.dataset.imageAlign;
      resizing = {grip, img, id:e.pointerId, x:e.clientX, scale:align==='right' ? -1 : align==='center' ? 2 : 1, width:img.getBoundingClientRect().width,
        original:img.getAttribute('width')};
      grip.setPointerCapture(e.pointerId);
    }, {capture:true});
    on(doc, 'pointermove', e => {
      if (resizing?.id !== e.pointerId) return;
      const delta = e.clientX - resizing.x;
      if (Math.abs(delta) < 2 && resizing.next == null) return;
      resizing.next = clamp(Math.round(resizing.width + delta*resizing.scale), 1, 99999);
      resizing.img.width = resizing.next;
    });
    function endResize(e) {
      if (resizing?.id !== e.pointerId) return;
      const {grip, img, original, next} = resizing;
      resizing = null;
      if (e.type === 'pointerup' && next != null) {
        swallowResizeClick = true;
        saveImageLayout(grip, {width:next});
      }
      else if (original == null) img.removeAttribute('width');
      else img.setAttribute('width', original);
    }
    for (const event of ['pointerup', 'pointercancel', 'lostpointercapture']) on(doc, event, endResize);
    on(viewport, 'click', e => {
      if (swallowResizeClick || e.target.closest('.sima-image-grip')) {
        swallowResizeClick = false; e.preventDefault(); e.stopPropagation();
        return;
      }
      const frame = e.target.closest('.sima-sized-image');
      if (!frame || e.button !== 0) return;
      // Keep Command-click navigation for a linked image.
      if (e.target === imageCaption) { e.stopPropagation(); return; }
      if ((e.metaKey || e.ctrlKey) && frame.closest('a[href]')) return;
      e.preventDefault(); e.stopPropagation();
      if (composing || frame.contains(imageCaption)) return;
      const top = frame.querySelector('img').getBoundingClientRect().top;
      clearImageSelection();
      if (active) finishBlock();
      editImageSource(frame,top);
    }, {capture:true});
    on(doc, 'dblclick', e => {
      const grip = e.target.closest('.sima-image-grip');
      if (grip) { e.preventDefault(); e.stopPropagation(); saveImageLayout(grip, {width:null}); return; }
      const image = e.target.closest('.sima-sized-image > img');
      if (!image || composing || e.button !== 0) return;
      e.preventDefault(); e.stopPropagation();
      if (closeImagePreview) return;
      const top = viewport.scrollTop, left = viewport.scrollLeft;
      closeImagePreview = window.SimaFilePreview.previewImage(host, image, () => {
        closeImagePreview = null;
        viewport.scrollTo(left, top);
      });
    }, {capture:true});
    on(doc, 'keydown', e => {
      const grip = e.target.closest('.sima-image-grip');
      if (!grip || !['ArrowLeft','ArrowRight','Enter',' '].includes(e.key)) return;
      e.preventDefault();
      e.stopPropagation();
      const width = Math.round(grip.previousElementSibling.getBoundingClientRect().width);
      const delta = e.key === 'ArrowLeft' ? -8 : 8;
      saveImageLayout(grip, {width:e.key.startsWith('Arrow') ? clamp(width + delta, 1, 99999) : null}, true);
    }, {capture:true});
    let pointerFocusing=false;
    on(viewport,'mousedown',e=>{
      pointerFocusing=true;
      setTimeout(()=>{pointerFocusing=false;},0);
      // Let the scrollbar perform its native drag and track clicks.
      if (e.target===viewport) {
        const rect=viewport.getBoundingClientRect();
        if (e.clientX>=rect.left+viewport.clientLeft+viewport.clientWidth ||
            e.clientY>=rect.top+viewport.clientTop+viewport.clientHeight) return;
      }
      if (searchWhitespace(e)) e.preventDefault();
    });
    on(viewport,'beforeinput',e=>{
      if (e.inputType==='historyUndo'||e.inputType==='historyRedo') {
        if(!composing){e.preventDefault();history(e.inputType==='historyRedo');}return;
      }
      if(e.target===field && !composing){readField();beforeSelection={...selection};}
    });
    on(viewport,'compositionstart',e=>{
      if(e.target===field)readField();
      beforeSelection={...selection};composing=true;viewport.classList.add('sima-composing');
    });
    on(viewport,'compositionend',e=>{
      composing=false;viewport.classList.remove('sima-composing');if(e.target===field)inputChange();
      const commands=pendingActions;pendingActions=[];
      queueMicrotask(()=>{if(!destroyed)commands.forEach(f=>f());});
    });
    on(viewport,'input',e=>{if(e.target===field && !e.isComposing)inputChange();});
    on(viewport,'select',e=>{if(e.target===field&&!composing)readField();}, {capture:true});
    on(viewport,'click',e=>{
      if(!source && !composing && e.button===0 && e.target.closest('.sima-end-entry')) {
        e.preventDefault();
        clearImageSelection();
        const newline=eol();
        const trailing=normalize(text).match(/\n*$/)[0].length;
        const separator=text.length ? newline.repeat(Math.max(0,2-trailing)) : '';
        pick(text.length);
        replace(text.length,text.length,separator);
        return;
      }
      const equation=e.target.closest('a[data-math-target]');
      if(equation){
        e.preventDefault();
        let target=document.getElementById(equation.dataset.mathTarget);
        if (!target && active) {
          draw(false);
          mathView?.schedule(0,()=>document.getElementById(equation.dataset.mathTarget)?.scrollIntoView({block:'center'}));
        } else target?.scrollIntoView({block:'center'});
        return;
      }
      const link=e.target.closest('a[href]');
      if(link){e.preventDefault();options.onLink?.(link.dataset.link||link.getAttribute('href'),{wiki:link.hasAttribute('data-wiki'),newTab:e.metaKey||e.ctrlKey});return;}
      if(composing || e.target.closest('textarea,button,details.sima-svg-preview,.sima-table-block,.sima-text-pair') || searchWhitespace(e))return;
      const box=e.target.closest('.sima-block'),b=blocks.find(item=>item.node===box);
      if(!b)return;
      if(b.type==='yaml' && !e.target.closest('.md-meta-block')) return;
      if(e.target.matches('input[type=checkbox]')){
        const checks=[...box.querySelectorAll('input[type=checkbox]')], raw=text.slice(b.start,b.end);
        const m=[...raw.matchAll(/^[ \t]*(?:[-*+]|\d+[.)])\s+\[([ xX])\]/gm)][checks.indexOf(e.target)];
        if(m){const pos=b.start+m.index+m[0].lastIndexOf('[')+1;write(pos,pos+1,m[1]===' '?'x':' ',{anchor:pos,head:pos});draw(false);}
        return;
      }
      const dom=window.getSelection();
      if(dom && !dom.isCollapsed && doc.contains(dom.anchorNode) && doc.contains(dom.focusNode)){
        const anchor=sourcePoint(dom.anchorNode,dom.anchorOffset), head=sourcePoint(dom.focusNode,dom.focusOffset);
        if(anchor!=null && head!=null){
          const caret=document.createRange();
          caret.setStart(dom.focusNode,dom.focusOffset);caret.collapse(true);
          editAtClick(b,caret,anchor,head);return;
        }
      }
      const caret=rangeAtPoint(e.clientX,e.clientY);
      const inside=caret && box.contains(caret.startContainer);
      const point=inside ? sourcePoint(caret.startContainer,caret.startOffset) : b.start;
      editAtClick(b,inside ? caret : null,point??b.start,point??b.start);
    });
    on(viewport,'focusin',e=>{
      if(e.target===viewport && !pointerFocusing && viewport.matches(':focus-visible') && !field && !composing && !activeTable)focus();
    });
    // A selection dragged across rendered blocks can leave keyboard focus on the page body.
    on(document,'keydown',e=>{
      if (e.key!=='Tab' || e.metaKey || e.ctrlKey || e.altKey || options.literal ||
          composing || e.isComposing || e.keyCode===229 || e.defaultPrevented) return;
      if (e.target!==field) {
        if (e.target!==document.body && e.target!==document.documentElement && !viewport.contains(e.target)) return;
        if (e.target.closest?.('button,input,textarea,[contenteditable],.sima-table-block')) return;
        const dom=window.getSelection();
        if (!dom || dom.isCollapsed || !doc.contains(dom.anchorNode) || !doc.contains(dom.focusNode)) return;
      }
      readSelection();
      if (e.shiftKey ? outdentList() : changeList('indent')) {e.preventDefault();e.stopPropagation();}
    });
    on(viewport,'keydown',e=>{
      if(composing||e.isComposing||e.keyCode===229||e.defaultPrevented)return;
      const key=e.key, cmd=e.metaKey||e.ctrlKey;
      if(cmd && !e.altKey){
        if(key.toLowerCase()==='z'){
          e.preventDefault();e.stopPropagation();history(e.shiftKey);return;
        }
        if(key.toLowerCase()==='a' && !e.shiftKey && e.target===field){
          e.preventDefault();e.stopPropagation();action('edit.selectAll');return;
        }
      }
      if(e.target!==field)return;
      readField();
      const [lo,hi]=range();
      if(key==='Escape'&&!source){
        e.preventDefault();draw(false);return;
      }
      if(source)return;
      const direction=['ArrowUp','ArrowLeft'].includes(key)?-1:['ArrowDown','ArrowRight'].includes(key)?1:0;
      if(direction) {
        const pos=selection.head,atEdge=direction<0?pos===active.start:pos===active.end;
        const oneLine=!field.value.includes('\n') && field.clientHeight<parseFloat(getComputedStyle(field).lineHeight)*1.8;
        if(atEdge || oneLine && ['ArrowUp','ArrowDown'].includes(key)){
          const idx = blocks.indexOf(active);
          const neighbor = direction < 0 ? blocks.slice(0,idx).reverse().find(b=>!b.node.hidden) : blocks.slice(idx+1).find(b=>!b.node.hidden);
          if(neighbor){
            e.preventDefault();
            const n=direction<0?neighbor.end:neighbor.start;
            if(e.shiftKey)choose(selection.anchor,n,true,false);else choose(n);
            reveal();return;
          }
        }
      }
      if(lo===hi && ((key==='Backspace'&&lo===active.start&&lo>0)||(key==='Delete'&&hi===active.end&&hi<text.length))){
        e.preventDefault();const back=key==='Backspace';
        const count=(back?text.slice(lo-2,lo):text.slice(hi,hi+2))==='\r\n'?2:1;
        replace(back?lo-count:lo,back?hi:hi+count,'');return;
      }
      if (key === 'Enter' && !cmd && !e.altKey) {
        if (!e.shiftKey && changeList('enter')) { e.preventDefault(); return; }
        const inList = parseBlocks().some(b => b.listItems && b.start <= lo && hi <= b.end);
        if (e.shiftKey && inList) {
          const line = normalize(text.slice(0,lo)).split('\n').at(-1);
          const marker = line.match(/^([ \t]*(?:[-+*]|\d+[.)])[ \t]+)/);
          const indent = marker ? ' '.repeat(columns(marker[1])) : line.match(/^[ \t]*/)[0];
          e.preventDefault(); replace(lo,hi,'  '+eol()+indent); return;
        }
        if (['paragraph','heading'].includes(active.type) && !inList) {
          e.preventDefault(); replace(lo,hi,e.shiftKey ? '  '+eol() : eol()+eol()); return;
        }
      }
      if(key==='Enter' && !e.shiftKey&&!cmd&&!e.altKey){
        const line=normalize(text.slice(active.start,lo)).split('\n').at(-1);
        const m=/^(\s*)([-*+]|\d+[.)]|>)(\s+)(\[[ xX]\]\s+)?(.*)$/.exec(line);
        if(m && !['code','fence','yaml','math','mermaid'].includes(active.type)){
          e.preventDefault();
          if(!m[5].trim())replace(lo-line.length,hi,'');
          else {
            const marker=/^\d/.test(m[2])?String(parseInt(m[2],10)+1)+m[2].slice(-1):m[2];
            replace(lo,hi,eol()+m[1]+marker+m[3]+(m[4]?'[ ] ':''));
          }
        }
      }
    });
    on(doc,'error',e=>{
      const img = e.target;
      if (!img.matches?.('img[data-markdown-src]') || !img.src.startsWith('simaq-asset://')) return;
      const url = new URL(img.src);
      if (!/\.(?:hei[cf]|tiff?|avif|bmp|ico|jfif|webp|jxl|jp2)$/i.test(url.pathname) || url.searchParams.has('preview')) return;
      url.searchParams.set('preview','png');
      img.src = url.href;
    },{capture:true});
    function imageFiles(transfer) {
      const files = Array.from(transfer?.files || []);
      return files.filter(file => file.type.startsWith('image/') ||
        /\.(?:png|apng|jpe?g|jfif|jp2|jxl|gif|webp|avif|hei[cf]|tiff?|bmp|ico|svg)$/i.test(file.name));
    }
    async function insertImages(files, a, b, preview, separateParagraph = false) {
      const anchor = {a,b}, links = [];
      pendingAssets.add(anchor);
      let failure;
      try {
        for (const file of files) {
          if (destroyed) break;
          const path = await options.onAsset(file);
          const label = (file.name || '截图').replace(/[\r\n]+/g,' ').replace(/[\\\[\]]/g,'\\$&');
          if (path) links.push('![' + label + '](' + path + ')');
        }
      } catch (error) { failure = error; }
      finally { pendingAssets.delete(anchor); }
      if (!destroyed && links.length) {
        const trailing = separateParagraph && anchor.a ? normalize(text.slice(0,anchor.a)).match(/\n*$/)[0].length : 2;
        const value = eol().repeat(Math.max(0,2-trailing)) + links.join(eol());
        if (preview && !source) {
          const end = anchor.a + value.length;
          write(anchor.a,anchor.b,value,{anchor:end,head:end});
          draw(false);
        } else replace(anchor.a,anchor.b,value);
      }
      if (failure) (options.onError || window.alert)(String(failure.message || failure));
    }
    function imageDropPoint(e) {
      if (field && e.target === field) {
        // WebKit exposes the textarea's host at the pointer. Its mirror has the
        // same line breaks and glyph positions, including highlighted spans.
        field.style.pointerEvents = 'none';
        mirror.style.pointerEvents = 'auto';
        mirror.style.webkitUserSelect = 'text';
        try {
          const caret = rangeAtPoint(e.clientX,e.clientY);
          if (caret && mirror.contains(caret.startContainer)) {
            const prefix = document.createRange();
            prefix.selectNodeContents(mirror);
            prefix.setEnd(caret.startContainer,caret.startOffset);
            const raw = text.slice(active.start,active.end);
            return Math.min(active.end,active.start + rawOffset(raw,prefix.toString().length));
          }
          return active.end;
        } finally {
          field.style.removeProperty('pointer-events');
          mirror.style.removeProperty('pointer-events');
          mirror.style.removeProperty('-webkit-user-select');
        }
      }
      if (e.target.closest('.sima-end-entry')) return text.length;
      return hitPoint(e.clientX,e.clientY) ?? (e.clientY < doc.getBoundingClientRect().top ? 0 : text.length);
    }
    on(viewport,'dragover',e=>{
      if (!options.onAsset || !e.dataTransfer?.types.includes('Files') || e.target.closest('.sima-references,dialog')) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'copy';
    });
    on(viewport,'drop',e=>{
      if (!options.onAsset || e.target.closest('.sima-references,dialog')) return;
      const files = imageFiles(e.dataTransfer);
      if (!files.length) return;
      e.preventDefault();
      e.stopPropagation();
      const at = imageDropPoint(e);
      void insertImages(files,at,at,true,!!e.target.closest('.sima-end-entry'));
    },{capture:true});
    on(viewport,'paste',e=>{
      if (composing || e.defaultPrevented || e.target === imageCaption || !options.onAsset) return;
      const files = imageFiles(e.clipboardData);
      if (!files.length) return;
      e.preventDefault();
      readSelection();
      void insertImages(files,...range(),false);
    },{capture:true});
    // A drag starting inside an active native textarea cannot extend outside it without a source-level continuation.
    let drag=null;
    on(viewport,'pointerdown',e=>{drag=e.target===field && !source?{x:e.clientX,y:e.clientY,start:field}:null;});
    on(document,'pointerup',e=>{
      const d=drag;drag=null;
      if(!d||d.start!==field||e.target===field||!doc.contains(e.target)||Math.hypot(e.clientX-d.x,e.clientY-d.y)<4)return;
      const end=hitPoint(e.clientX,e.clientY);if(end==null)return;
      const raw=text.slice(active.start,active.end), start=active.start+rawOffset(raw,end<active.start?field.selectionEnd:field.selectionStart);
      choose(start,end,true,false);
    });
    on(doc,'focusout',e=>{if(e.target.matches('.sima-table-cell-input')) mathView?.schedule();});
    draw(false);syncVisible();
    if (options.literal) filePreview = window.SimaFilePreview?.mount(viewport, {
      path:options.path, getText:()=>text, locate,
      replace:next=>replace(0,text.length,next,0)
    });
    return {getText:()=>text,selectImageAt,setText,getState,setState,focus,locate,outlineLocations,centeredHeading,goToHeading,goToBeginning,showSearchResult,action,setHighlights,
      refreshImages(wikiOnly = false){
        const selector = wikiOnly ? 'img[data-wiki-image]' : 'img[data-markdown-src]';
        for (const img of doc.querySelectorAll(selector)) {
          const url = window.SimaRender.imageURL(img.dataset.markdownSrc, renderOptions.path, img.hasAttribute('data-wiki-image'));
          if (img.getAttribute('src') !== url) img.src = url;
        }
      },
      html:()=>options.literal ? '<pre>'+escape(text)+'</pre>' : window.SimaRender.exportWithDiagrams(text,renderOptions),
      destroy(){destroyed=true;closeImagePreview?.();clearImageSelection();mathView?.destroy();detachScrollbar();filePreview?.destroy();events.abort();visibility.disconnect();for(const b of blocks)b.table?.destroy();host.replaceChildren();}
    };
  }
  window.SimaEditor={create};
})();
