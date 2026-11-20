'use strict';

const listItems = new WeakMap();
const listParts = new WeakMap();
const listRoots = new WeakMap();

function mapListItems(element, token, raw, start) {
  const roots = listStructure(token, raw, start);
  listRoots.set(element, roots);
  function bind(list, nodes) {
    const elements = [...list.children].filter(el => el.matches('li'));
    nodes.forEach((node,i) => {
      const el = elements[i];
      if (!el) return;
      node.root = element;
      listItems.set(el,node);
      if (node.ordered) list.start = node.first;
      if (node.task && state.editable !== false) {
        const box = el.querySelector('input[type=checkbox]');
        if (box && box.closest('li') === el) {
          box.disabled = false;
          box.setAttribute('aria-label','完成此项');
          box.onclick = event => {
            event.stopPropagation();
            let at = node.start+node.prefix.length+1;
            if (activeBlock && activeBlock.end <= node.start) at += blockValue(activeBlock).length-(activeBlock.end-activeBlock.start);
            closeBlock(false,false);
            const removed = state.body[at];
            if (!/[ xX]/.test(removed ?? '')) return;
            const change = {start:at,removed,value:removed === ' ' ? 'x' : ' ',caret:at+2,restoreCaret:at+2};
            if (state.editID) recordBlockSplice(change); else commitRange(change);
          };
        }
      }
      const nested = [...el.children].filter(child => child.matches('ol,ul'));
      const groups = node.groups;
      let from = node.start, first = el.firstChild;
      for (let j=0; j<=groups.length; j++) {
        const group = groups[j], sub = group && nested[j];
        if (group && !sub) break;
        const until = sub ? group[0].start : node.end;
        const range = raw.slice(from-start,until-start);
        const leading = from === node.start;
        const skip = leading ? 0 : range.match(/^(?:[ \t]*\n)*/)[0].length;
        const end = until-range.match(/(?:\n[ \t]*)*$/)[0].length;
        if (leading || end > from+skip) {
          const span = {start:from+skip,end,leading,node};
          // Each head and each prose segment owns its actual source span.
          // Parents stay mounted while their descendants are being edited.
          let part = el;
          if (groups.length) {
            part = document.createElement('div');
            el.insertBefore(part,first);
            while (first && first !== sub) {
              const next = first.nextSibling;
              part.append(first);
              first = next;
            }
          }
          listParts.set(part,span);
          const children = node.token.tokens;
          const inline = children.length === 1 && ['text','paragraph'].includes(children[0].type) ? children[0].tokens : null;
          sourceBlocks.set(part,{...span,inline});
        }
        if (sub) {
          bind(sub,group);
          from = Math.min(node.end, group.at(-1).end + 1);
          first = sub.nextSibling;
        }
      }
    });
  }
  bind(element,roots);
}

function outlineFor(node) {
  const blocks = [node.root];
  function extend(back) {
    for (;;) {
      const outer = back ? blocks[0] : blocks.at(-1);
      const el = back ? outer.previousElementSibling : outer.nextElementSibling;
      if (!listRoots.has(el)) break;
      const left = back ? el : outer, right = back ? outer : el;
      if (state.body.slice(listRoots.get(left).at(-1).end,listRoots.get(right)[0].start) !== '\n') break;
      if (back) blocks.unshift(el); else blocks.push(el);
    }
  }
  extend(true);
  extend(false);
  return new ListOutline(state.body, blocks.flatMap(el => listRoots.get(el)));
}

function applyListChange(outline, before, from, to=from) {
  const raw = state.body.slice(outline.start,outline.end);
  let value = outline.write();
  // Turning a root into prose must also separate it from adjacent non-list blocks.
  const shift = !outline.rows[0].mark && outline.start>0 && !/\n[ \t]*\n$/.test(state.body.slice(0,outline.start)) ? 1 : 0;
  if (shift) value = '\n'+value;
  if (outline.rows.at(-1).node && !outline.rows.at(-1).mark && outline.end < state.body.length &&
      !/^\n[ \t]*\n|^\n$/.test(state.body.slice(outline.end))) value += '\n';
  const offset = p => outline.start + shift + p.row.offset + p.offset;
  const after = before.rendered ? before : {start:offset(from),end:offset(to),backward:before.backward};
  if (value === raw) { restoreListSelection(after); return; }
  // Journal only the changed slice, including marker-width changes on later lines.
  let a = 0, b = raw.length, c = value.length;
  while (a<b && a<c && raw[a]===value[a]) a++;
  while (b>a && c>a && raw[b-1]===value[c-1]) { b--; c--; }
  const step = {start:outline.start+a,removed:raw.slice(a,b),value:value.slice(a,c),
    caret:after.rendered ? outline.start : after.end, restoreCaret:before.rendered ? outline.start : before.end,
    listBefore:before,listAfter:after};
  if (state.editID) recordBlockSplice(step); else commitRange(step);
}

function indentRenderedItems(range,out) {
  const position = positionForRange(range);
  if (!position) return false;
  const spans = index.spans.filter(s => position.start<s.end && position.end>s.start);
  const owner = span => span && listItems.get(span.element.parentElement?.closest('li'));
  const first = owner(spans[0]), last = owner(spans.at(-1));
  if (!first || !last) return false;
  const outline = outlineFor(first), a = outline.heads.get(first), b = outline.heads.get(last);
  if (!b) return false;
  const heads = outline.rows.slice(outline.rows.indexOf(a),outline.rows.indexOf(b)+1).filter(row => row.node);
  const set = new Set(heads);
  const roots = heads.filter(row => !set.has(row.parent));
  if (outline.move(roots,out)) {
    const sel = getSelection();
    applyListChange(outline,{...position,rendered:true,backward:sel.anchorNode===range.endContainer && sel.anchorOffset===range.endOffset});
  }
  return true;
}

// When a field is replaced after a structural command, its native text undo
// stack disappears. Keep the completed typing run between two outline steps.
function rememberListTyping(edit, caret) {
  const removed = state.body.slice(edit.start,edit.end), value = blockValue(edit);
  if (!state.editID || removed === value) return;
  if (blockHistory.file !== file || blockHistory.body !== state.body) blockHistory.undo.length = 0;
  blockHistory.file = file;
  blockHistory.redo.length = 0;
  blockHistory.undo.push({start:edit.start,removed,value,caret,restoreCaret:edit.entryCaret});
  if (blockHistory.undo.length > 40) blockHistory.undo.shift();
  blockHistory.body = paragraphBody(edit);
}

function pendingListMark(edit) {
  return edit.acceptMarker && /^(?:[-+*]|\d{1,9}[.)])$/.test(edit.field.value);
}

function listSourcePrefix(edit) {
  if (!edit.listPrefix) return '';
  if (pendingListMark(edit)) return edit.listPrefix.match(/^[ \t]*/)[0];
  return edit.listPrefix + (edit.field.value && !/[ \t]$/.test(edit.listPrefix) ? ' ' : '');
}

function listInput(edit, event) {
  if (!edit.listPrefix || event.isComposing || edit.composing) return false;
  const field = edit.field;
  const typed = edit.acceptMarker && listMarker.exec(field.value);
  if (typed && !typed[1] && typed[3] && !field.value.includes('\n')) {
    field.setRangeText('',0,typed[0].length,'preserve');
    editListCommand(edit,'marker',typed);
    return true;
  }
  edit.acceptMarker = !field.value || (edit.acceptMarker && /^(?:\d{1,9}[.)]?|[-+*])$/.test(field.value));
  edit.holder.closest('li')?.classList.toggle('typing-list-marker',!!pendingListMark(edit));
  return false;
}

function clipboardList(text) {
  const body = text.replace(/\r\n?/g,'\n');
  const tokens = marked.lexer(body).filter(t => t.type !== 'space');
  if (!tokens.length || tokens.some(t => t.type !== 'list')) return null;
  let cursor = 0;
  const roots = [];
  for (const token of tokens) {
    const raw = token.raw.trimEnd(), start = body.indexOf(raw,cursor);
    if (start < 0 || body.slice(cursor,start).trim()) return null;
    cursor = start+raw.length;
    cursor += body.slice(cursor).match(/^[ \t]*/)[0].length;
    roots.push(...listStructure(token,body.slice(start,cursor),start));
  }
  return roots.length && !body.slice(cursor).trim() ? new ListOutline(body,roots) : null;
}

function editListCommand(edit,command,argument) {
  const field = edit.field, origin = fieldStart(edit);
  const before = {start:origin+field.selectionStart,end:origin+field.selectionEnd,backward:field.selectionDirection==='backward'};
  // Reparse once so offsets/ownership include anything typed since the last paint.
  closeBlock(false,false);
  const el = mappedBlocks(true).findLast(el => {
    const part = listParts.get(el);
    return part && part.start<=before.start && before.start<=part.end;
  });
  const owner = listParts.get(el)?.node;
  if (!owner) { restoreListSelection(before); return; }
  const outline = outlineFor(owner), head = outline.heads.get(owner);
  const a = outline.position(before.start), b = outline.position(before.end);
  if (!a || !b) { restoreListSelection(before); return; }
  let caret;
  switch (command) {
  case 'indent': case 'outdent':
    if (outline.move([head],command==='outdent')) { applyListChange(outline,before,a,b); return; }
    break;
  case 'enter':
    if (a.row !== b.row) {
      const start = outline.rows.indexOf(a.row), end = outline.rows.indexOf(b.row);
      const tail = b.row.text.slice(b.offset);
      a.row.text = a.row.text.slice(0,a.offset)+tail;
      outline.rows.splice(start+1,end-start);
      b.row = a.row; b.offset = a.offset;
    }
    caret = outline.split(a,b);
    break;
  case 'paste':
    caret = outline.paste(head,a.offset,b.offset,argument);
    break;
  case 'marker':
    head.mark = argument[2]; head.first = /^\d/.test(head.mark) ? Number.parseInt(head.mark,10) : 1;
    head.gap = ' '; head.retyped = true;
    outline.dirty.add(head.parent);
    caret = {row:head,offset:a.offset};
    break;
  case 'backspace':
    if (head.parent || !outline.previous(head)) {
      outline.move([head],true);
      caret = {row:head,offset:0};
    } else {
      const prev = outline.rows.slice(0,outline.rows.indexOf(head)).findLast(row => row.node || row.text.trim());
      caret = outline.join(prev,head);
    }
    break;
  case 'delete': {
    const next = outline.rows.slice(outline.rows.indexOf(head)+1).find(row => row.node || row.text.trim());
    if (next?.node) caret = outline.join(head,next);
    break;
  }
  }
  if (caret) applyListChange(outline,before,caret); else restoreListSelection(before);
}

function restoreListSelection(selection) {
  if (selection.rendered) {
    const first=index.spans.find(s=>s.start<=selection.start && s.end>selection.start);
    const last=index.spans.find(s=>s.start<selection.end && s.end>=selection.end);
    if (!first || !last) return;
    function boundary(span,offset) {
      const node=span.element;
      if (node.nodeType===Node.TEXT_NODE) return [node,offset-span.start];
      const parent=node.parentNode, i=Array.prototype.indexOf.call(parent.childNodes,node);
      return [parent,i+(offset>span.start ? 1 : 0)];
    }
    const a=boundary(first,selection.start), b=boundary(last,selection.end);
    const sel=getSelection();
    sel.setBaseAndExtent(...(selection.backward ? b : a),...(selection.backward ? a : b));
    armRangeInput();
    return;
  }
  openBlockAt(selection.start);
  const edit=activeBlock;
  if (!edit || edit.grid) return;
  if (selection.end<=edit.end) {
    edit.field.setSelectionRange(Math.max(0,selection.start-fieldStart(edit)),Math.max(0,selection.end-fieldStart(edit)),selection.backward ? 'backward' : 'forward');
  } else {
    closeBlock(false,false);
    const a=renderedCaretAt(selection.start), b=renderedCaretAt(selection.end);
    if (a && b) {
      const [anchor,focus]=selection.backward ? [b,a] : [a,b];
      getSelection().setBaseAndExtent(anchor.startContainer,anchor.startOffset,focus.startContainer,focus.startOffset);
      armRangeInput();
    }
  }
}
