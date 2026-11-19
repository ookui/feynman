'use strict';

// Slice inline Markdown by its rendered text. Keep a link's destination and a
// formatted run's delimiters whenever any of their visible text survives.
function inlineRemainder(tokens, from, to, keepSelected=false) {
  let position=0, result='';
  for (const token of tokens) {
    const raw=token.raw, visible=sanitize(marked.Parser.parseInline([token])).textContent;
    const a=Math.max(0,from-position), b=Math.min(visible.length,to-position);
    position+=visible.length;
    if (a>=b) { if (!keepSelected) result+=raw; continue; }
    if (a===0 && b===visible.length) { if (keepSelected) result+=raw; continue; }
    const inside=token.tokens?.map(t=>t.raw).join('');
    const content=inside || visible;
    const at=raw.indexOf(content, token.type==='link' && raw.startsWith('[') ? 1 : 0);
    if (at<0) {
      // HTML character references can occupy multiple source characters.
      const units=raw.match(/&(?:#\d+|#x[\da-f]+|[a-z][a-z\d]*);|[\s\S]/gi) || [];
      const decoder=document.createElement('textarea');
      let decoded='', kept='';
      for (const unit of units) {
        decoder.innerHTML=unit==='<' ? '&lt;' : unit;
        const start=decoded.length;
        decoded+=decoder.value;
        if ((decoded.length>a && start<b)===keepSelected) kept+=unit;
      }
      if (decoded!==visible) return null;
      result+=kept;
      continue;
    }
    const rest=inside ? inlineRemainder(token.tokens,a,b,keepSelected) : keepSelected ? visible.slice(a,b) : visible.slice(0,a)+visible.slice(b);
    if (rest===null) return null;
    result+=raw.slice(0,at)+rest+raw.slice(at+content.length);
  }
  return result;
}

function blockRemainder(part, from, to, keepSelected=false) {
  const {el,span}=part, raw=state.body.slice(span.start,span.end);
  if (tableSources.has(el)) return null;
  const visible=el.textContent;
  let tokens=span.inline;
  if (!tokens || sanitize(marked.Parser.parseInline(tokens)).textContent!==visible) {
    if (!visible || !raw.includes(visible)) return null;
    // Plain text inside a quoted paragraph or a fenced code block.
    const at=raw.indexOf(visible);
    return {prefix:raw.slice(0,at), text:keepSelected ? visible.slice(from,to) : visible.slice(0,from)+visible.slice(to), suffix:raw.slice(at+visible.length)};
  }
  const inline=tokens.map(t=>t.raw).join('');
  const marker=el.matches('li') ? /^\s*(?:[-+*]|\d+[.)])\s+/.exec(raw)
    : el.matches('h1,h2,h3,h4,h5,h6') ? /^ {0,3}#{1,6}[ \t]+/.exec(raw) : null;
  const start=raw.indexOf(inline,marker?.[0].length ?? 0);
  if (start<0) return null;
  const text=inlineRemainder(tokens,from,to,keepSelected);
  return text===null ? null : {prefix:raw.slice(0,start), text, suffix:raw.slice(start+inline.length)};
}

function selectedPart(range,el) {
  if (!range.intersectsNode(el)) return null;
  const selected=document.createRange();
  selected.selectNodeContents(el);
  const before=selected.cloneRange(), after=selected.cloneRange();
  if (range.compareBoundaryPoints(Range.START_TO_START,selected)>0)
    selected.setStart(range.startContainer,range.startOffset);
  if (range.compareBoundaryPoints(Range.END_TO_END,selected)<0)
    selected.setEnd(range.endContainer,range.endOffset);
  before.setEnd(selected.startContainer,selected.startOffset);
  after.setStart(selected.endContainer,selected.endOffset);
  const hasContent=r=>r.toString().length>0 || !!r.cloneContents().querySelector('img,hr,br');
  if (!hasContent(selected) && !(el.matches('hr') && range.intersectsNode(el))) return null;
  return {el,span:sourceBlocks.get(el), from:before.toString().length,
    to:el.textContent.length-after.toString().length, whole:!hasContent(before) && !hasContent(after)};
}

function deletionForRange(range, replacement=null, cut=false) {
  const parts=mappedBlocks().filter(el=>!el.matches('button') && ![...el.children].some(child=>sourceBlocks.has(child)))
    .map(el=>selectedPart(range,el)).filter(Boolean);
  if (!parts.length) return null;
  const first=parts[0], last=parts.at(-1);
  let start=first.span.start, end=last.span.end, value='', caret=start;
  if (replacement===null && first.whole && last.whole) {
    const left=state.body.slice(0,start), right=state.body.slice(end);
    const before=left.match(/\n*$/)[0].length, after=right.match(/^\n*/)[0].length;
    if (before===left.length || after===right.length) { start-=before; end+=after; }
    else end+=Math.min(before,after);
    caret=start;
  } else {
    const split=first!==last || replacement!==null;
    const prefix=first.whole ? null : blockRemainder(first,first.from,split ? first.el.textContent.length : first.to);
    const suffix=last.whole || !split ? null : blockRemainder(last,0,last.to);
    if ((!first.whole && !prefix) || (!last.whole && split && !suffix)) {
      tell('请将选区边界移到当前块的开头或末尾，或点击块内编辑。');
      return null;
    }
    const frame=prefix || suffix;
    let left=(frame?.prefix ?? '')+(prefix?.text ?? ''), right=(suffix?.text ?? '')+(frame?.suffix ?? '');
    if (replacement?.includes('|') && replacement.includes('\n')) {
      const blocks=marked.lexer(replacement).filter(t=>t.type!=='space');
      if (blocks[0]?.type==='table' && left.trim()) left+='\n\n';
      if (blocks.at(-1)?.type==='table' && right.trim()) right='\n\n'+right;
    }
    value=left+(replacement ?? '')+right;
    caret=start+(split ? left.length+(replacement?.length ?? 0) : frame.prefix.length+Math.min(first.from,prefix.text.length));
  }
  let clipboard;
  if (cut) {
    function clipped(part) {
      return part.whole ? state.body.slice(part.span.start,part.span.end) : blockRemainder(part,part.from,part.to,true)?.text;
    }
    const head=clipped(first), tail=first===last ? '' : clipped(last);
    if (head==null || tail==null) return null;
    clipboard=head+(first===last ? '' : state.body.slice(first.span.end,last.span.start)+tail);
  }
  const tables=parts.filter(p=>tableSources.has(p.el));
  const insertedTables=value.includes('|') ? marked.lexer(value).filter(t=>t.type==='table').length : 0;
  const ordinal=tables.length ? tableSources.get(tables[0].el).ordinal :
    insertedTables ? mappedBlocks().filter(el=>tableSources.has(el) && sourceBlocks.get(el).end<=start).length : null;
  return {start,removed:state.body.slice(start,end),value,caret,clipboard,restoreCaret:first.span.start,
    tableCount:tables.length,insertedTables,ordinal};
}

// Let macOS deliver Edit menu commands, text input and marked IME text to a
// rendered selection. All durable changes still go through the Markdown splice.
let composingRange=null;
function selectedNoteRange() {
  if (!state?.editable || activeBlock && editorHasFocus(activeBlock)) return null;
  const selection=getSelection();
  if (selection.isCollapsed || !selection.rangeCount) return null;
  const range=selection.getRangeAt(0);
  if (!range.intersectsNode(article) || article.querySelector('details')?.contains(range.commonAncestorContainer)) return null;
  return range;
}

function armRangeInput() {
  if (pointerDown || composingRange) return;
  const range=selectedNoteRange();
  if (!range || !article.contains(range.commonAncestorContainer)) {
    article.removeAttribute('contenteditable');
    return;
  }
  if (!article.isContentEditable) {
    const {anchorNode,anchorOffset,focusNode,focusOffset}=getSelection();
    article.contentEditable='true';
    article.focus({preventScroll:true});
    getSelection().setBaseAndExtent(anchorNode,anchorOffset,focusNode,focusOffset);
  }
}
document.addEventListener('selectionchange',armRangeInput);
document.addEventListener('mouseup',()=>queueMicrotask(armRangeInput));
function commitRange(step) {
  if (!step) return;
  clearTimeout(editTimer);
  bar.hidden=true;
  if (!activeBlock) {
    // Keep the native input target alive while Swift checks the file and opens
    // the draft. WebKit can deliver more than one keystroke in that interval.
    requestBlock(step.start,null,{deletion:step,body:state.body});
    return;
  }
  getSelection().removeAllRanges();
  article.removeAttribute('contenteditable');
  recordBlockSplice(step);
}

async function rangeClipboard(event,action,range) {
  const step=deletionForRange(range,null,action==='cut');
  if (!step) return;
  event.preventDefault();
  const body=state.body, path=file, saved=range.cloneRange();
  try {
    const result=await window.webkit.messageHandlers.selectionClipboard.postMessage({
      file,body,action,text:step.clipboard ?? '',html:event.clipboardData?.getData('text/html') ?? ''
    });
    const current=selectedNoteRange();
    if (path!==file || body!==state.body || !current ||
        current.compareBoundaryPoints(Range.START_TO_START,saved) || current.compareBoundaryPoints(Range.END_TO_END,saved)) return;
    if (action==='cut') commitRange(step);
    else if (typeof result==='string' && result) commitRange(deletionForRange(current,result));
  } catch (error) { tell(error.message); }
}

for (const action of ['cut','paste']) document.addEventListener(action,event=>{
  const range=selectedNoteRange();
  if (event.isTrusted && range) rangeClipboard(event,action,range);
},true);

document.addEventListener('keydown',event=>{
  if (event.isComposing || event.keyCode===229 || event.altKey) return;
  const range=selectedNoteRange();
  if (!range) return;
  const key=event.key.toLowerCase();
  if ((event.metaKey || event.ctrlKey) && ['x','v'].includes(key)) {
    rangeClipboard(event,key==='x' ? 'cut' : 'paste',range);
  } else if (!event.metaKey && !event.ctrlKey && ['Backspace','Delete'].includes(event.key)) {
    event.preventDefault();
    commitRange(deletionForRange(range));
  }
},true);

article.addEventListener('beforeinput',event=>{
  if (event.target!==article || composingRange || event.isComposing) return;
  event.preventDefault();
  const range=selectedNoteRange();
  if (!range) return;
  const text=['insertParagraph','insertLineBreak'].includes(event.inputType) ? '\n\n' :
    ['insertText','insertReplacementText'].includes(event.inputType) ? event.data : null;
  if (text!=null) {
    const pending=pendingClick?.file===file && pendingClick.target?.body===state.body ? pendingClick.target.deletion : null;
    if (pending) {
      const at=pending.caret-pending.start;
      pending.value=pending.value.slice(0,at)+text+pending.value.slice(at);
      pending.caret+=text.length;
    } else commitRange(deletionForRange(range,text));
  }
  else if (event.inputType.startsWith('delete')) commitRange(deletionForRange(range));
});
article.addEventListener('compositionstart',event=>{
  const range=selectedNoteRange();
  if (event.target!==article || !range) return;
  // Stash the Markdown boundaries before WebKit modifies its temporary marked text.
  const step=deletionForRange(range,'');
  composingRange={step,file,body:state.body};
});
article.addEventListener('compositionend',event=>{
  const saved=composingRange;
  composingRange=null;
  if (!saved || saved.file!==file || saved.body!==state.body) return;
  article.removeAttribute('contenteditable');
  getSelection().removeAllRanges();
  paint(state,true);
  if (event.data && saved.step) {
    const step=saved.step, offset=step.caret-step.start;
    step.value=step.value.slice(0,offset)+event.data+step.value.slice(offset);
    step.caret+=event.data.length;
    commitRange(step);
  }
});

// A textarea owns its own selection. Once a drag leaves the edited paragraph,
// switch it back to typeset text and continue the same selection in the article.
function renderedCaretAt(sourceOffset) {
  const block=mappedBlocks().filter(el=>{
    const {start,end}=sourceBlocks.get(el);
    return start<=sourceOffset && sourceOffset<=end && !el.matches('button');
  }).at(-1);
  if (!block) return null;
  const {start,end}=sourceBlocks.get(block), raw=state.body.slice(start,end);
  const offset=sourceOffset-start, marker='\uE000';
  if (raw.includes(marker)) return null;
  // Insert a marker in a detached parse so hidden list prefixes, emphasis and
  // link destinations do not shift the drag's starting point after reflow.
  const probe=sanitize(marked.parse(raw.slice(0,offset)+marker+raw.slice(offset)));
  const visible=probe.querySelector(block.localName)?.textContent;
  let remaining=offset===0 ? 0 : offset===raw.length ? block.textContent.length : visible?.indexOf(marker);
  if (offset>0 && offset<raw.length && visible?.replace(marker,'')!==block.textContent) return null;
  if (remaining==null || remaining<0) return null;
  const nodes=document.createTreeWalker(block,NodeFilter.SHOW_TEXT);
  while (nodes.nextNode()) {
    const node=nodes.currentNode;
    if (remaining<=node.length) {
      const caret=document.createRange();
      caret.setStart(node,remaining);
      caret.collapse(true);
      return caret;
    }
    remaining-=node.length;
  }
  return null;
}

let paragraphDrag=null;
document.addEventListener('mousedown',event=>{
  paragraphDrag=null;
  if (event.button!==0 || !activeBlock || activeBlock.composing || !article.contains(event.target) ||
      event.target.closest('button,details,.sima-table-block')) return;
  paragraphDrag={edit:activeBlock,x:event.clientX,y:event.clientY,scroll:scrollY,
    fromField:!activeBlock.grid && event.target===activeBlock.field};
},true);
document.addEventListener('mousemove',event=>{
  const drag=paragraphDrag;
  if (!drag || !pointerDown) return;
  if (!drag.anchor) {
    if (activeBlock!==drag.edit || Math.hypot(event.clientX-drag.x,event.clientY-drag.y)<4) return;
    const holder=drag.edit.holder;
    const current=document.elementFromPoint(event.clientX,event.clientY);
    if (drag.fromField && holder.contains(current)) return;
    const field=drag.edit.field;
    const sourceOffset=drag.fromField ? fieldStart(drag.edit)+
      (field.selectionDirection==='backward' ? field.selectionEnd : field.selectionStart) : null;
    closeBlock(false,false);
    drag.anchor=(sourceOffset===null ? null : renderedCaretAt(sourceOffset)) ?? document.caretRangeFromPoint(drag.x,drag.y+drag.scroll-scrollY);
  }
  const tip=document.caretRangeFromPoint(event.clientX,event.clientY);
  if (!drag.anchor || !tip || !article.contains(drag.anchor.startContainer) || !article.contains(tip.startContainer)) return;
  event.preventDefault();
  getSelection().setBaseAndExtent(drag.anchor.startContainer,drag.anchor.startOffset,tip.startContainer,tip.startOffset);
},true);
document.addEventListener('mouseup',()=>{paragraphDrag=null;},true);
