'use strict';
const article = document.querySelector('#doc');
let file = '', index, draft, state;
const bar = document.querySelector('#tools');
const questionKey = text => (text.trim().match(/^(Q[1-9]\d*)\s+\S/) || [])[1] || '';
const send = payload => window.webkit.messageHandlers.reader.postMessage({...payload, file});
  // Offsets refer to readable text, not Markdown. Separators do not belong to a DOM
  // text node. Keeping that distinction lets one quote span paragraphs and cells.
  function documentIndex(root, source = file) {
    let text = '';
    let pending = '';
    const spans = [];
    const sections = [{name: '', start: 0, level: 0}];
    function boundary(separator) {
      if (separator === '\n' || !pending) pending = separator;
    }
    function visit(element) {
      if (element.nodeType === Node.TEXT_NODE) {
        if (!element.data || (/^\s*$/.test(element.data) && /\n/.test(element.data) &&
            !element.parentElement?.closest('p,pre,td,th,h1,h2,h3,h4,h5,h6'))) return;
        append(element, element.data);
        return;
      }
      if (element.nodeType !== Node.ELEMENT_NODE && element.nodeType !== Node.DOCUMENT_FRAGMENT_NODE) return;
      const tag = element.nodeName;
      if (['DETAILS','SCRIPT','STYLE','BUTTON'].includes(tag)) return;
      if (tag === 'BR') { boundary('\n'); return; }
      if (tag === 'IMG') {
        const alt = element.getAttribute('alt')?.trim();
        const name = (element.getAttribute('src') || '').split(/[/?#]/).filter(Boolean).pop();
        append(element, alt || name || '图片');
        return;
      }
      const isHeading = /^H[1-6]$/.test(tag);
      const heading = isHeading && (source !== 'questions.md' || !element.closest('blockquote,pre,table,details'));
      const block = isHeading || ['P','LI','BLOCKQUOTE','PRE','TR','TABLE','HR'].includes(tag);
      if (block) boundary('\n');
      let section;
      if (heading) {
        section = {name: element.textContent.trim(), level: Number(tag.slice(1)), element,
          start: text.length + (text && pending ? 1 : 0)};
        sections.push(section);
      }
      for (const child of element.childNodes) visit(child);
      if (heading) {
        section.headingEnd = text.length;
        section.question = section.level === 2 ? questionKey(section.name) : '';
      }
      if (block) boundary('\n');
      else if (tag === 'TD' || tag === 'TH') boundary('\t');
    }
    function append(element, value) {
      if (pending && text) text += pending;
      pending = '';
      spans.push({element, start: text.length, end: text.length + value.length});
      text += value;
    }
    visit(root);
    const parents = [];
    for (const section of sections) {
      while (parents.length && parents[parents.length - 1].level >= section.level) {
        parents.pop().end = section.start;
      }
      parents.push(section);
    }
    for (const section of parents) section.end = text.length;
    return {root, text, spans, sections};
  }

  function locate(index, item) {
    if (!index || !item.quote) return null;
    const {text, sections} = index;
    const key = item.report === 'questions.md' && questionKey(item.section);
    const question = key && sections.find(s => s.question === key);
    if (question && item.quote === item.section && ((!item.prefix && !item.suffix) || item.quote !== question.name)) {
      return {start: question.start, end: question.headingEnd};
    }
    const scopes = question ? [question] : item.section ? sections.filter(s => s.name === item.section) : [{start: 0, end: text.length}];
    const candidates = new Set();
    const contextual = new Set();
    const prefix = item.prefix || '', suffix = item.suffix || '';
    for (const scope of scopes) {
      let at = text.indexOf(item.quote, scope.start);
      while (at >= 0 && at < scope.end) {
        const end = at + item.quote.length;
        candidates.add(at);
        if (text.slice(Math.max(0, at - prefix.length), at) === prefix && text.slice(end, end + suffix.length) === suffix) {
          contextual.add(at);
        }
        at = text.indexOf(item.quote, at + 1);
      }
    }
    // A colliding quote with indistinguishable context has no trustworthy position.
    const matches = contextual.size ? contextual : candidates;
    const start = matches.size === 1 ? matches.values().next().value : -1;
    return start < 0 ? null : {start, end: start + item.quote.length};
  }

  function positionForRange(range) {
    if (!article.contains(range.startContainer) || !article.contains(range.endContainer) || range.collapsed) return null;
    let start = null, end = null;
    for (const part of index.spans) {
      if (!range.intersectsNode(part.element)) continue;
      const from = range.startContainer === part.element ? part.start + range.startOffset : part.start;
      const to = range.endContainer === part.element ? part.start + range.endOffset : part.end;
      if (from >= to) continue;
      if (start === null) start = from;
      end = to;
    }
    return start === null ? null : {start, end};
  }

  function makeDraft(position, mode) {
    if (!position) return null;
    const {start, end} = position;
    const quote = index.text.slice(start, end);
    if (!quote.trim()) return null;
    if (mode === 'selection' && [...quote].length > 500) {
      tell('请将用于新建条目的引文缩短至 500 字以内。');
      return null;
    }
    let section = '';
    for (const scope of index.sections) {
      if (scope.start > start) break;
      if (start < scope.end) section = scope.name;
    }
    const candidate = {report: file, section, quote, mode,
      prefix: [...index.text.slice(0, start)].slice(-20).join(''),
      suffix: [...index.text.slice(end)].slice(0, 20).join('')};
    if (locate(index, candidate)?.start !== start) {
      tell('同一章节有完全相同的原文和前后文。请扩大划选范围，或选择整段。');
      return null;
    }
    return candidate;
  }

function tell(message) {
  const note = document.querySelector('#notice');
  note.textContent = message; note.hidden = false;
  setTimeout(() => { note.hidden = true; }, 4000);
}
for (const [kind, label] of Object.entries({concepts:'概念', entities:'实体', events:'事件', questions:'问题'})) {
  const button = document.createElement('button');
  button.textContent = label;
  button.onmousedown = e => e.preventDefault();
  button.onclick = () => { if (draft) send({action:'extract',kind,anchor:draft}); bar.hidden = true; };
  bar.append(button);
}
const sourceBlocks = new WeakMap();
let documentLinks;
function cleanHTML(markdown) { return sanitize(marked.parse(markdown)); }
function sanitize(html) {
  const template = document.createElement('template');
  template.innerHTML = html;
  const allowed = new Set('P BR HR H1 H2 H3 H4 H5 H6 UL OL LI STRONG EM B I S DEL CODE PRE BLOCKQUOTE TABLE THEAD TBODY TR TH TD A IMG SUP SUB'.split(' '));
  for (const el of Array.from(template.content.querySelectorAll('*'))) {
    if (!allowed.has(el.tagName)) { el.replaceWith(document.createTextNode(el.textContent)); continue; }
    const imageRaw = el.tagName === 'IMG' && (el.getAttribute('data-image-markdown') || el.outerHTML);
    const href = el.getAttribute('href'), alt = el.getAttribute('alt'), src = el.getAttribute('src');
    for (const attr of [...el.attributes]) el.removeAttribute(attr.name);
    if (el.tagName === 'A' && href) el.setAttribute('href', href);
    if (el.tagName === 'IMG') {
      imageSources.set(el, imageRaw);
      if (alt) el.alt = alt;
      if (src && /^https?:\/\//i.test(src)) el.src = src;
      else if (src && !/^(?:[a-z][\w+.-]*:|\/)/i.test(src)) {
        el.src = 'feynman-image://local/?' + new URLSearchParams({file, src});
      }
    }
  }
  return template.content;
}
function removeDeletedLinks(root,data) {
  const deadIDs = new Set(data.deletedIDs), deadPaths = new Set(data.deletedPaths);
  for (const link of root.querySelectorAll('a[href]')) {
    const href = link.getAttribute('href');
    let removed = false;
    if (href.startsWith('feynman:')) removed = deadIDs.has(href.slice(8).split('#', 1)[0]);
    else if (deadPaths.size && (!/^[a-z][\w+.-]*:/i.test(href) || href.startsWith('project:'))) {
      try {
        const target = new URL(href.startsWith('project:') ? '/' + href.slice(8) : href, new URL(data.file, 'https://project.invalid/'));
        removed = target.origin === 'https://project.invalid' && deadPaths.has(decodeURIComponent(target.pathname.slice(1)));
      } catch {}
    }
    if (removed) link.replaceWith(...link.childNodes);
  }
}
function renderHistory(turns, expanded, openTurns) {
  const details = document.createElement('details');
  details.className = 'question-history';
  details.contentEditable='false';
  details.open = expanded;
  const summary = document.createElement('summary');
  summary.textContent = '追问记录' + (turns.length ? '（' + turns.length + '）' : '');
  details.append(summary);
  if (!turns.length) {
    const empty = document.createElement('p');
    empty.className = 'history-empty';
    empty.textContent = '此后完成的问答会保存在这里。';
    details.append(empty);
  }
  for (const turn of turns) {
    const section = document.createElement('section');
    section.className = 'history-turn';
    section.dataset.turnId = turn.id;
    section.classList.toggle('expanded', openTurns.has(turn.id));
    const time = document.createElement('time');
    time.dateTime = turn.date;
    const date = new Date(turn.date);
    time.textContent = Number.isNaN(date.getTime()) ? '' : date.toLocaleString('zh-CN', {year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'});
    const questionToggle = document.createElement('button');
    questionToggle.type = 'button';
    const question = document.createElement('span');
    question.className = 'history-question';
    question.textContent = turn.question;
    questionToggle.append(question);
    const answerLabel = document.createElement('h3');
    answerLabel.textContent = 'Codex 回答';
    const answer = document.createElement('div');
    answer.className = 'history-answer';
    answer.append(cleanHTML(turn.answer));
    const response = document.createElement('div');
    response.className = 'history-response';
    response.hidden = !openTurns.has(turn.id);
    questionToggle.setAttribute('aria-expanded', String(!response.hidden));
    questionToggle.onclick = () => {
      response.hidden = !response.hidden;
      section.classList.toggle('expanded', !response.hidden);
      questionToggle.setAttribute('aria-expanded', String(!response.hidden));
    };
    response.append(time, answerLabel, answer);
    section.append(questionToggle, response);
    details.append(section);
  }
  article.append(details);
}
function render(data) {
  if (composingRange && data.file===file && data.body===state.body && data.editID===state.editID) {
    state=data;
    return;
  }
  if (data.file!==file || data.editID!==state?.editID) {
    blockHistory.body=null;
    blockHistory.undo.length=0;
    blockHistory.redo.length=0;
  }
  const sameSession = data.file === file && data.editID && data.editID === state?.editID;
  if (sameSession && activeBlock) {
    // Polling and autosave can update marks and history while the IME owns the field.
    state = {...data, body: state.body};
    return;
  }
  if (sameSession && data.body === state.body) { state = data; return; }
  const begin = data.editID && !sameSession;
  disposeBlock(activeBlock);
  activeBlock = null;
  paint(data, file === data.file && !!(state?.editID || data.editID));
  if (begin) {
    openBlockAt(data.editOffset ?? 0, pendingClick?.file === file ? pendingClick.y : null);
    pendingClick = null;
  }
}
function paint(data, keepScroll = false) {
  composingRange=null;
  article.removeAttribute('contenteditable');
  if (file !== data.file) { tableWidths.clear(); verticalX = null; }
  const same = file === data.file, lastY = same ? scrollY : data.scroll;
  const selection = getSelection();
  const range = same && index && !selection.isCollapsed && selection.rangeCount ? positionForRange(selection.getRangeAt(0)) : null;
  const selectedText = range && {quote:index.text.slice(range.start,range.end),
    prefix:index.text.slice(Math.max(0,range.start-20),range.start), suffix:index.text.slice(range.end,range.end+20)};
  const historyExpanded = same && article.querySelector(".question-history")?.open === true;
  const openTurns = new Set(same ? [...article.querySelectorAll('.history-turn.expanded')].map(turn => turn.dataset.turnId) : []);
  state = data; file = data.file;
  bar.hidden = true; draft = null;
  clearTimeout(editTimer);
  const content = document.createDocumentFragment();
  let cursor = 0;
  const tokens = marked.lexer(data.body);
  documentLinks = tokens.links;
  let tableOrdinal = 0;
  for (const token of tokens) {
    const start = data.body.indexOf(token.raw, cursor);
    const block = sanitize(marked.Parser.parse([token]));
    if (start >= 0) {
      cursor = start + token.raw.length;
      const end = start + token.raw.replace(/\n+$/, '').length;
      // A raw HTML token may produce several siblings, or a bare text node.
      if (block.children.length > 1 || [...block.childNodes].some(n => n.nodeType === Node.TEXT_NODE && n.textContent.trim())) {
        const group = document.createElement('div');
        group.append(...block.childNodes);
        block.append(group);
      }
      const el = block.firstElementChild;
      if (el) {
        const inline=['paragraph','heading'].includes(token.type) ? token.tokens : null;
        sourceBlocks.set(el, {start, end, inline});
        if (token.type === 'table') prepareTable(el, data.body.slice(start,end),start,end,tableOrdinal++);
        if (token.type === 'blockquote') {
          const parts = [...token.raw.matchAll(/^(?:[ \t]{0,3}>[ \t]*)?[^\s>][^\n]*(?:\n(?![ \t]{0,3}>[ \t]*$|[ \t]*$)[^\n]+)*/gm)];
          if (parts.length === el.children.length && [...el.children].every(node => node.tagName === 'P')) {
            parts.forEach((part, i) => sourceBlocks.set(el.children[i], {start:start+part.index, end:start+part.index+part[0].length}));
          }
        }
        if (token.type === 'list') mapListItems(el,token,token.raw,start);
      }
    }
    content.append(block);
  }
  const previousImage = same && imageBookmark();
  if (same) preserveImageSizes(content);
  article.replaceChildren(content);
  if (!article.childElementCount && data.editable !== false) {
    const prompt = document.createElement('button');
    prompt.className = 'empty-note';
    prompt.textContent = '点击此处开始撰写';
    sourceBlocks.set(prompt, {start:0,end:data.body.length});
    prompt.onclick = () => requestBlock(0);
    article.append(prompt);
  }
  if (Array.isArray(data.questionHistory)) renderHistory(data.questionHistory, historyExpanded, openTurns);
  if (!previousImage || !restoreImageSelection(previousImage,true)) clearImageSelection();
  removeDeletedLinks(article,data);
  index = documentIndex(article);
  const hits = data.marks.map(m => ({...m, pos:locate(index,m.anchor)})).filter(m => m.pos);
  if (data.focus && !locate(index,data.focus)) tell('这处引文在当前版本中未能定位。');
  for (const span of index.spans) {
    if (span.element.nodeType !== Node.TEXT_NODE) continue;
    const matches = hits.filter(h => h.pos.start < span.end && h.pos.end > span.start);
    if (!matches.length) continue;
    const cut = [...new Set([span.start,span.end,...matches.flatMap(h => [Math.max(h.pos.start,span.start),Math.min(h.pos.end,span.end)])])].sort((a,b)=>a-b);
    const frag = document.createDocumentFragment();
    for (let i=1;i<cut.length;i++) {
      const from=cut[i-1],to=cut[i],text=span.element.data.slice(from-span.start,to-span.start);
      const covering=matches.filter(h=>h.pos.start<=from && h.pos.end>=to);
      if (!covering.length) { frag.append(text); continue; }
      const mark=document.createElement('mark'); mark.textContent=text; mark.className=covering[0].kind;
      mark.title=covering.map(h=>h.title).join(' · ');
      if (data.focus && covering.some(h=>h.anchor.quote===data.focus.quote && h.anchor.prefix===data.focus.prefix && h.anchor.suffix===data.focus.suffix && h.anchor.section===data.focus.section)) mark.classList.add('focus');
      mark.tabIndex = 0;
      mark.setAttribute('role', 'button');
      const activate = event => {
        event.preventDefault();
        event.stopPropagation();
        if (!getSelection().isCollapsed) return;
        const anchors = covering.map(hit => hit.anchor).sort((a,b) => a.quote.length - b.quote.length);
        send({action:'show', href:mark.closest('a')?.getAttribute('href') ?? null, ids:[...new Set(covering.map(hit=>hit.id))], anchors});
      };
      mark.onclick = activate;
      mark.onkeydown = event => {
        if (event.key === 'Enter' || event.key === ' ') activate(event);
      };
      frag.append(mark);
    }
    span.element.replaceWith(frag);
  }
  if (hits.length) index = documentIndex(article);
  if (selectedText) {
    const match = locate(index, selectedText);
    if (match) {
      const first = index.spans.find(s => s.start <= match.start && match.start < s.end);
      const last = index.spans.find(s => s.start < match.end && match.end <= s.end);
      if (first?.element.nodeType === Node.TEXT_NODE && last?.element.nodeType === Node.TEXT_NODE) {
        selection.setBaseAndExtent(first.element,match.start-first.start,last.element,match.end-last.start);
      }
    }
  }
  const highlight=article.querySelector('mark.focus');
  const heading = data.fragment && Array.from(article.querySelectorAll('h1,h2,h3,h4,h5,h6')).find(el => {
    const title = el.textContent.trim();
    return title === data.fragment || title.toLowerCase().replace(/[^\p{L}\p{N} _-]/gu, '').replace(/\s+/g, '-') === data.fragment.toLowerCase();
  });
  const resumed = !same && data.sourceOffset != null && [...article.children].find(el => {
    const span = sourceBlocks.get(el);
    return span && span.end >= data.sourceOffset;
  });
  if (keepScroll || selectedImage) scrollTo(0,lastY || 0);
  else if (resumed) resumed.scrollIntoView({block:'nearest'});
  else if (heading) heading.scrollIntoView({block:'start'});
  else if (highlight) highlight.scrollIntoView({block:'center'});
  else scrollTo(0,lastY || 0);
}
document.addEventListener('selectionchange', () => {
  const selection=getSelection();
  if (activeBlock?.field === document.activeElement || !state?.extract || !selection.rangeCount || selection.isCollapsed) { bar.hidden=true; return; }
  const range=selection.getRangeAt(0);
  draft=makeDraft(positionForRange(range),'selection');
  if (!draft) { bar.hidden=true; return; }
  bar.hidden=false;
  const rect=range.getBoundingClientRect(),box=bar.getBoundingClientRect();
  bar.style.left=Math.max(4,Math.min(rect.left,innerWidth-box.width-5))+'px';
  bar.style.top=Math.max(4,Math.min(rect.bottom+6,innerHeight-box.height-5))+'px';
});
let editTimer, activeBlock, pendingClick, verticalX = null, pointerDown = false;
function editorHasFocus(edit) {
  const focused = document.activeElement;
  return edit.holder.contains(focused) || (edit.grid && !!focused?.closest('.sima-table-menu'));
}
function disposeBlock(edit) {
  edit?.observer?.disconnect();
  edit?.grid?.destroy();
}
function blockValue(edit) {
  if (edit.grid) return edit.raw;
  const text=edit.field.value;
  return edit.afterTable && text ? '\n\n'+text+edit.suffix : text;
}
function fieldStart(edit) { return edit.start + (edit.afterTable && edit.field.value ? 2 : 0); }
function blockCaret(edit) {
  return edit.grid ? edit.start+edit.caret : fieldStart(edit)+edit.field.selectionEnd;
}

function editableSpan(el) {
  return listParts.get(el) ?? sourceBlocks.get(el) ?? listItems.get(el);
}
function mappedBlocks(includeNested = false) {
  return [...article.querySelectorAll('*')].filter(el => {
    if (!includeNested) return sourceBlocks.has(el);
    if (listItems.get(el)?.sublistStarts || (el.matches('ol,ul') && listItems.has(el.firstElementChild))) return false;
    return !!editableSpan(el);
  });
}
function paragraphBody(edit) {
  return state.body.slice(0, edit.start) + blockValue(edit) + state.body.slice(edit.end);
}
function flushField(edit, composing = false) {
  if (activeBlock !== edit) return;
  const value = blockValue(edit);
  if (value !== edit.sent || (edit.composing && !composing)) {
    send({action:'change', id:state.editID, start:edit.start, length:edit.sent.length,
      value, caret:blockCaret(edit), composing});
    edit.sent = value;
  }
  edit.composing = composing;
}
function closeBlock(done = false, notify = true) {
  const edit = activeBlock;
  if (!edit) return;
  flushField(edit);
  const caret = blockCaret(edit);
  activeBlock = null;
  disposeBlock(edit);
  if (blockValue(edit) === state.body.slice(edit.start,edit.end) && !edit.synthetic) {
    edit.holder.replaceWith(edit.original);
  } else {
    paint({...state, body:paragraphBody(edit)}, true);
  }
  if (notify) send({action:'endParagraph', id:state.editID, caret, done});
}
function openBlockAt(offset, targetY = null, target = null) {
  if (state?.editable === false) return;
  target ??= pendingClick?.file===file && pendingClick.offset===offset ? pendingClick.target : null;
  pendingClick=null;
  if (target?.cancelForImage) {
    send({action:'endParagraph',id:state.editID,caret:offset});
    return;
  }
  if (target?.deletion && target.body===state.body && state.editID) {
    getSelection().removeAllRanges();
    article.removeAttribute('contenteditable');
    recordBlockSplice(target.deletion);
    return;
  }
  const afterTable=target?.afterTable===true;
  // The innermost match selects a single list item, even when its parent covers the same offset.
  let el = mappedBlocks(true).filter(node => {
    const {start,end} = editableSpan(node);
    return start <= offset && offset <= end;
  }).pop();
  if (el && tableSources.has(el)) {
    if (!afterTable) { openTableBlock(el,sourceBlocks.get(el),offset,target); return; }
    el=el.nextElementSibling;
    if (!el?.matches('.after-table-line')) return;
  }
  if (afterTable && !el?.matches('.after-table-line')) return;
  const synthetic = !el;
  let span = afterTable ? {start:offset,end:offset} : el && editableSpan(el);
  if (!el) {
    el = document.createElement('div');
    const next = [...article.children].find(node => sourceBlocks.get(node)?.start > offset || node.matches('details'));
    article.insertBefore(el, next ?? null);
    span = {start:offset, end:offset};
  }
  const field = document.createElement('textarea');
  field.className = 'paragraph-source';
  field.setAttribute('aria-label', '编辑当前段落的 Markdown');
  field.spellcheck = false;
  field.value = state.body.slice(span.start, span.end);
  const holder = document.createElement(el.matches('li') ? 'li' : 'div');
  holder.className = 'editing-block';
  const style = getComputedStyle(el);
  holder.style.marginTop = style.marginTop;
  holder.style.marginBottom = style.marginBottom;
  if (/^H[1-6]$/.test(el.tagName)) {
    holder.style.font = style.font;
    holder.style.letterSpacing = style.letterSpacing;
  }
  holder.append(field);
  const part=listParts.get(el);
  if (part?.leading) holder.classList.add('list-head');
  const edit = {field, holder, original:el, synthetic, start:span.start, end:span.end,
    tag:part?.leading ? 'LI' : el.tagName, sent:field.value, composing:false};
  if (afterTable) {
    // Keep the insertion line out of the note until it has content. Existing line
    // endings stay attached to the following block (or to the end of the file).
    const rest=state.body.slice(offset);
    edit.afterTable=true;
    edit.suffix=rest.trim() ? '\n'.repeat(Math.max(0,2-rest.match(/^\n*/)[0].length)) : '';
    holder.classList.add('after-table-paragraph');
  }
  activeBlock = edit;
  el.replaceWith(holder);
  const resize = () => {
    field.style.height = '0px';
    field.style.height = Math.max(28, field.scrollHeight) + 'px';
  };
  let lastWidth = -1;
  edit.observer = new ResizeObserver(() => {
    if (holder.clientWidth !== lastWidth) { lastWidth = holder.clientWidth; resize(); }
  });
  edit.observer.observe(holder);
  resize();
  field.focus({preventScroll:true});
  const caret = Math.min(field.value.length, Math.max(0, offset - span.start));
  field.setSelectionRange(caret, caret);
  if (targetY != null) {
    const rect = caretLayout.measure(field, at => at(caret));
    scrollBy(0, rect.top + rect.height / 2 - targetY);
  }
  field.oninput = event => {
    resize();
    flushField(edit, event.isComposing);
    // A multiline paste may introduce several complete paragraphs in one native input event.
    if (!event.isComposing && field.value.includes('\n') && (/\n\s*\n/.test(field.value) || field.value.includes('|'))) queueMicrotask(() => {
      if (activeBlock !== edit || edit.composing) return;
      const blocks = marked.lexer(field.value).filter(token => token.type !== 'space' && token.type !== 'def');
      if (blocks.length < 2 && blocks[0]?.type !== 'table') return;
      const at = blockCaret(edit);
      closeBlock(false,false);
      openBlockAt(at);
    });
  };
  field.oncompositionend = () => flushField(edit);
  // WebKit can move focus while undo restores a paragraph separator. Let the
  // input handler finish rebuilding and focusing the restored block first.
  field.onblur = () => setTimeout(() => {
    if (!pointerDown && activeBlock === edit && !editorHasFocus(edit)) closeBlock();
  },0);
  field.onkeydown = event => handleBlockKey(event, edit);
  field.onpaste = event => {
    if (!event.isTrusted || event.defaultPrevented) return;
    event.preventDefault();
    pasteIntoBlock(edit, event.clipboardData?.getData('text/plain') ?? '', event.clipboardData?.getData('text/html'));
  };
}
async function pasteIntoBlock(edit, fallback, html) {
  const field = edit.field, focus = document.activeElement;
  const start = field?.selectionStart, end = field?.selectionEnd, before = field?.value;
  const raw = edit.raw, rect = edit.grid?.getSelection();
  try {
    const result = await window.webkit.messageHandlers.notePaste.postMessage({
      id:state.editID, selection:field ? before.slice(start,end) : '', html:html ?? '', grid:!!edit.grid
    });
    if (activeBlock !== edit || edit.field !== field || document.activeElement !== focus ||
        field?.value !== before || field?.selectionStart !== start || field?.selectionEnd !== end) return;
    if (edit.grid && Object.keys(rect).some(key => edit.grid.getSelection()[key] !== rect[key])) return;
    if (edit.grid && typeof result?.cells === 'string') { edit.grid.pasteCells(result.cells); return; }
    let text = result ?? fallback;
    const tokens = text.includes('|') && text.includes('\n')
      ? marked.lexer(text).filter(token => token.type !== 'space') : [];
    if (edit.grid) {
      if (tokens.length === 1 && tokens[0].type === 'table') {
        const table = SimaTables.parse(tokens[0].raw);
        if (table) {
          const cells = SimaTables.copyRectangle(table.raw,{top:0,left:0,bottom:table.rows.length-1,right:table.columns-1});
          edit.grid.pasteCells(cells);
          return;
        }
      }
      if (!field || field !== focus || /[\t\r\n]/.test(fallback)) {
        edit.grid.pasteCells(fallback || text);
        return;
      }
    } else if (tokens.some(token => token.type === 'table')) {
      // GFM tables need their own block even when pasted in the middle of a sentence.
      if (tokens[0]?.type === 'table' && before.slice(0,start).trim()) text = '\n\n' + text;
      if (tokens.at(-1)?.type === 'table' && before.slice(end).trim()) text += '\n\n';
    }
    if (field !== focus) return;
    field.setSelectionRange(start,end);
    document.execCommand('insertText', false, text);
  } catch (error) { tell(error.message); }
}
function requestBlock(offset, y = null, target = null) {
  if (state?.editable === false) return;
  if (activeBlock) {
    if (offset > activeBlock.end || (offset === activeBlock.end && !activeBlock.afterTable)) offset += blockValue(activeBlock).length - (activeBlock.end - activeBlock.start);
    closeBlock(false, false);
    openBlockAt(offset,y,target);
  } else { pendingClick = {file,offset,y,target}; send({action:'edit', offset, y}); }
}

function moveToNeighbor(edit, direction, x = null) {
  const back = direction < 0, blocks = mappedBlocks(true);
  const next = back ? blocks.filter(el => editableSpan(el).end < edit.start || (edit.afterTable && editableSpan(el).end===edit.start)).at(-1)
                    : blocks.find(el => editableSpan(el).start > edit.end);
  if (!next) return false;
  const span = editableSpan(next);
  let cell = null;
  if (x !== null && tableSources.has(next)) {
    const rows = next.querySelector('table').rows;
    const row = rows[back ? rows.length-1 : 0];
    const closest = [...row.cells].reduce((best,c) => {
      const bounds = c.getBoundingClientRect(), d = Math.max(bounds.left-x, x-bounds.right, 0);
      return !best || d < best.d ? {column:c.cellIndex,d} : best;
    },null);
    cell = {row:row.rowIndex,column:closest.column};
  }
  requestBlock(back ? span.end : span.start,null,cell);
  if (x !== null) caretLayout.land(activeBlock.field,direction,x);
  else caretLayout.reveal(activeBlock.field);
  return true;
}

function joinParagraph(edit, back) {
  if (edit.afterTable && (back || !edit.field.value)) return false;
  const blocks = mappedBlocks(true);
  const adjacent = back ? blocks.filter(node => editableSpan(node).end < edit.start).at(-1)
                        : blocks.find(node => editableSpan(node).start > edit.end);
  // Keep structural blocks (in particular a table's last cell and code fences) intact.
  if (!adjacent || tableSources.has(adjacent) || adjacent.matches('pre,hr') || edit.tag === 'PRE') return false;
  const neighbor = editableSpan(adjacent);
  const body = paragraphBody(edit);
  const valueEnd = fieldStart(edit) + edit.field.value.length;
  const start = back ? neighbor.end : valueEnd;
  const end = back ? edit.start : neighbor.start + blockValue(edit).length - (edit.end-edit.start);
  const gap = body.slice(start,end);
  if (!/^\s*\n\s*$/.test(gap)) return false;
  closeBlock(false,false);
  send({action:'change', id:state.editID, start, length:gap.length, value:'', caret:start});
  paint({...state,body:body.slice(0,start) + body.slice(end)}, true);
  openBlockAt(start);
  const joined = activeBlock;
  if (!joined.grid) {
    // Record the separator deletion in the native field's undo history.
    const field = joined.field, pos = field.selectionEnd;
    const value = field.value;
    field.value = value.slice(0,pos) + gap + value.slice(pos);
    field.setSelectionRange(pos,pos+gap.length);
    if (!document.execCommand('delete')) { field.value = value; field.setSelectionRange(pos,pos); }
  }
  caretLayout.reveal(joined.field);
  return true;
}

function handleBlockKey(event, edit) {
  if (event.isComposing || edit.composing || event.keyCode === 229) return;
  const {field} = edit, key = event.key;
  if (key === 'Escape' || ((event.metaKey || event.ctrlKey) && key.toLowerCase() === 's')) {
    event.preventDefault(); closeBlock(true); return;
  }
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  const marker = edit.tag === 'LI' && /^([ \t]*)([-*+]|(\d+)([.)]))([ \t]+)(?:\[[xX ]\] )?/.exec(field.value);
  if (key === 'Tab' && (edit.tag==='LI' || listParts.has(edit.original) || listMarker.test(field.value))) {
    event.preventDefault();
    indentEditingItem(edit,event.shiftKey);
    return;
  }
  if (key === 'Enter' && !event.shiftKey && (marker || /^(P|H[1-6]|BUTTON|DIV)$/.test(edit.tag))) {
    // Insert the separator into the real Markdown before handing the caret to the new paragraph.
    event.preventDefault();
    let separator = '\n\n';
    if (marker && field.value.slice(marker[0].length).trim()) {
      const bullet = marker[3] ? (Number(marker[3])+1) + marker[4] : marker[2];
      separator = '\n' + marker[1] + bullet + marker[5] + (/\[[ xX]\] $/.test(marker[0]) ? '[ ] ' : '');
    } else if (marker) field.select();
    document.execCommand('insertText', false, separator);
    const at = blockCaret(edit);
    closeBlock(false, false);
    openBlockAt(at);
    return;
  }
  if (field.selectionStart !== field.selectionEnd) return;
  if ((key === 'Backspace' && field.selectionStart === 0) ||
      (key === 'Delete' && field.selectionStart === field.value.length)) {
    if (joinParagraph(edit, key === 'Backspace')) event.preventDefault();
    return;
  }
  if (key === 'ArrowUp' || key === 'ArrowDown') {
    if (event.shiftKey) return;
    const direction = key === 'ArrowUp' ? -1 : 1;
    const {x,offset} = caretLayout.vertical(field,direction,verticalX);
    verticalX = x;
    if (offset !== null) {
      field.setSelectionRange(offset,offset);
      caretLayout.reveal(field);
    } else if (!moveToNeighbor(edit,direction,x)) return;
    event.preventDefault();
    return;
  }
  const back = key === 'Tab' ? event.shiftKey : key === 'ArrowLeft';
  const forward = key === 'Tab' ? !event.shiftKey : key === 'ArrowRight';
  if (!(back || forward) || (key !== 'Tab' && (event.shiftKey || field.selectionStart !== (back ? 0 : field.value.length)))) return;
  if (moveToNeighbor(edit, back ? -1 : 1)) event.preventDefault();
}

document.addEventListener('keydown', event => {
  if (event.shiftKey || event.metaKey || event.ctrlKey || event.altKey || !['ArrowUp','ArrowDown'].includes(event.key)) verticalX = null;
}, true);
document.addEventListener('input', () => { verticalX = null; }, true);
document.addEventListener('mousedown', () => { verticalX = null; clearTimeout(editTimer); pointerDown = true; }, true);
document.addEventListener('mouseup', () => {
  pointerDown = false;
  // The click handler gets the original DOM target before the old paragraph is redrawn.
  setTimeout(() => { if (activeBlock && !editorHasFocus(activeBlock)) closeBlock(); }, 0);
}, true);
window.addEventListener('blur', () => { pointerDown = false; if (activeBlock) closeBlock(); });
function tableLineInGap(event) {
  if (event.target!==article) return null;
  for (const line of article.querySelectorAll(':scope > .after-table-line')) {
    const next=line.nextElementSibling;
    if (event.clientY>=line.getBoundingClientRect().top && (!next || event.clientY<next.getBoundingClientRect().top)) return line;
  }
  return null;
}
let hoveredLine=null;
function highlightTableLine(line) {
  if (line===hoveredLine) return;
  hoveredLine?.classList.remove('in-table-gap');
  hoveredLine=line;
  line?.classList.add('in-table-gap');
}
article.addEventListener('pointermove', event => highlightTableLine(tableLineInGap(event)));
article.addEventListener('pointerleave', () => highlightTableLine(null));
article.addEventListener('click', event => {
  if (event.target.closest('.editing-block')) return;
  const link = event.target.closest('a');
  if (link) {
    event.preventDefault();
    if (getSelection().isCollapsed) send({action:'link', href:link.getAttribute('href')});
    return;
  }
  if (state?.editable === false || event.detail > 1 || event.target.closest('button,details,mark') || !getSelection().isCollapsed) return;
  let block = event.target;
  while (block !== article && !editableSpan(block)) block = block.parentElement;
  const line=tableLineInGap(event);
  if (line) { line.click(); return; }
  const span = editableSpan(block);
  if (!span) { if (activeBlock) closeBlock(); return; }
  const td = event.target.closest('td,th');
  let cell = null;
  if (td && tableSources.has(block)) {
    cell = {row:td.parentElement.rowIndex, column:td.cellIndex};
    const info = tableSources.get(block).model.rows[cell.row]?.[cell.column];
    if (!info) return;
    cell.start = span.start + (info.start ?? 0);
    cell.end = span.start + (info.end ?? 0);
  }
  let offset = cell?.start ?? span.start;
  const caret = document.caretRangeFromPoint(event.clientX, event.clientY);
  if (caret && block.contains(caret.startContainer)) {
    const nodes = document.createTreeWalker(cell ? td : block, NodeFilter.SHOW_TEXT);
    let cursor = offset;
    while (nodes.nextNode()) {
      const node = nodes.currentNode, at = state.body.indexOf(node.data, cursor);
      if (at < 0 || at + node.length > (cell?.end ?? span.end)) continue;
      if (node === caret.startContainer) { offset = at + caret.startOffset; break; }
      cursor = at + node.length;
    }
  }
  if (cell) cell.caret = offset-cell.start;
  if (activeBlock || state.editID) requestBlock(offset,event.clientY,cell);
  else editTimer = setTimeout(() => {
    if (getSelection().isCollapsed) requestBlock(offset,event.clientY,cell);
  }, state.extract ? (state.doubleClickDelay ?? 350) : 0);
});
let scrollTimer;
addEventListener('scroll',()=>{const path=file;clearTimeout(scrollTimer);scrollTimer=setTimeout(()=>{if(path===file) send({action:'scroll',y:scrollY});},180);});
