// Keep the reading table in the report's normal text/highlight index. Mount the same cell
// editor as SimaQ only for the active table, using its Markdown offsets for every write.
const tableSources = new WeakMap();
const tableWidths = new Map();

// The active field is replaced by a repaint after structural edits, so its native
// undo stack cannot restore them. Journal the exact Markdown splice instead.
const blockHistory = {file:null, body:null, undo:[], redo:[]};

function applyBlockSplice(step, restore) {
  closeBlock(false,false);
  const value = restore ? step.removed : step.value;
  const length = restore ? step.value.length : step.removed.length;
  const caret = restore ? step.restoreCaret : step.caret;
  const body = state.body.slice(0,step.start) + value + state.body.slice(step.start+length);
  if (step.tableCount || step.insertedTables) {
    const removed=restore ? step.insertedTables || 0 : step.tableCount;
    const added=restore ? step.tableCount : step.insertedTables || 0;
    const widths = [...tableWidths];
    tableWidths.clear();
    for (const [i,w] of widths) {
      if (i < step.ordinal) tableWidths.set(i,w);
      else if (i >= step.ordinal+removed) tableWidths.set(i-removed+added,w);
    }
    if (restore) for (const [i,w] of step.widths ?? []) tableWidths.set(i,w);
  }
  send({action:'change', id:state.editID, start:step.start, length, value, caret});
  paint({...state,body},true);
  openBlockAt(caret,null,restore ? step.cell : null);
  if (restore && step.cellUndo && activeBlock?.grid) activeBlock.cellUndo.push(...step.cellUndo);
  blockHistory.body = body;
}

function recordBlockSplice(step) {
  const body=activeBlock ? paragraphBody(activeBlock) : state.body;
  if (blockHistory.file!==file || blockHistory.body!==body) blockHistory.undo.length=0;
  blockHistory.file=file;
  blockHistory.redo.length=0;
  if (step.tableCount) step.widths=[...tableWidths].filter(([i])=>i>=step.ordinal && i<step.ordinal+step.tableCount);
  blockHistory.undo.push(step);
  if (blockHistory.undo.length>40) blockHistory.undo.shift();
  applyBlockSplice(step,false);
}

function removeTableBlock(edit, ordinal) {
  if (activeBlock!==edit) return;
  const body = paragraphBody(edit);
  const left=body.slice(0,edit.start), right=body.slice(edit.start+edit.raw.length);
  const before=left.match(/\n*$/)[0].length, after=right.match(/^\n*/)[0].length;
  const edge=before===left.length || after===right.length;
  const start=edit.start-(edge ? before : 0);
  const skip=edge ? after : Math.min(before,after);
  const selection=edit.grid.getSelection();
  recordBlockSplice({start, removed:body.slice(start,edit.start+edit.raw.length+skip), value:'',
    restoreCaret:edit.start, caret:start+after-skip, ordinal, tableCount:1,
    cell:{row:selection.top,column:selection.left}, cellUndo:edit.cellUndo});
}

document.addEventListener('keydown', event => {
  if ((!event.metaKey && !event.ctrlKey) || event.altKey || event.key.toLowerCase()!=='z' ||
      event.isComposing || !activeBlock || !state.editID || blockHistory.file!==file ||
      !activeBlock.holder.contains(event.target)) return;
  const restore=!event.shiftKey;
  const from=restore ? blockHistory.undo : blockHistory.redo;
  if (!from.length || paragraphBody(activeBlock)!==blockHistory.body) return;
  event.preventDefault();
  event.stopPropagation();
  const step=from.pop();
  (restore ? blockHistory.redo : blockHistory.undo).push(step);
  applyBlockSplice(step,restore);
},true);

function applyTableWidths(table,widths) {
  let cols = table.querySelector('colgroup');
  if (!widths?.some(Boolean)) { cols?.remove(); return; }
  if (!cols) { cols=document.createElement('colgroup'); table.prepend(cols); }
  cols.replaceChildren(...Array.from(table.rows[0].cells, (_,c) => {
    const col = document.createElement('col');
    if (widths[c]) col.style.width = widths[c]+'px';
    return col;
  }));
}

function prepareTable(table, raw, start, end, ordinal) {
  const model = SimaTables.parse(raw);
  if (!model) return;
  const holder = document.createElement('div');
  holder.className = 'note-table-scroll';
  table.replaceWith(holder);
  holder.append(table);
  applyTableWidths(table,tableWidths.get(ordinal));
  [...table.rows].forEach(row => [...row.cells].forEach((cell,c) => {
    if (model.align[c]) cell.style.textAlign = model.align[c];
  }));
  sourceBlocks.delete(table);
  sourceBlocks.set(holder, {start,end});
  tableSources.set(holder, {model,ordinal});
  if (state.editable !== false) {
    const line=document.createElement('button');
    line.type='button';
    line.className='after-table-line';
    line.setAttribute('aria-label','在表格下方输入正文');
    line.onmousedown=event => event.preventDefault();
    line.onclick=() => requestBlock(end,null,{afterTable:true});
    holder.after(line);
  }
}

function openTableBlock(original, span, offset, cell) {
  const {model,ordinal} = tableSources.get(original);
  const holder = document.createElement('div');
  holder.className = 'editing-block';
  original.replaceWith(holder);
  const edit = {
    ...span, holder, original, raw:model.raw, sent:model.raw, caret:offset-span.start,
    get field() { return holder.querySelector('.editing textarea'); }
  };
  const undo = [], redo = [];
  edit.cellUndo=undo;
  activeBlock = edit;
  edit.grid = SimaTables.mount(holder, model.raw, {
    widths:tableWidths.get(ordinal),
    remove:() => removeTableBlock(edit,ordinal),
    writeClipboard:(text,whole) => window.webkit.messageHandlers.tableCopy.postMessage({id:state.editID,text,whole}),
    onError:error => tell(error.message ?? String(error)),
    onWidthsChange:widths => {
      tableWidths.set(ordinal,widths);
      applyTableWidths(original.querySelector('table'),widths);
    },
    renderInline:source => {
      const lexer = new marked.Lexer();
      lexer.tokens.links = documentLinks;
      const fragment = sanitize(marked.Parser.parseInline(lexer.inlineTokens(source.replace(/\\\|/g,'|'))));
      removeDeletedLinks(fragment,state);
      return fragment;
    },
    selection:(_,end) => { edit.caret = end; },
    openLink:href => send({action:'link',href}),
    change:(raw, position) => {
      undo.push({raw:edit.raw, row:position.row, column:position.column, widths:position.widthsBefore});
      if (undo.length > 80) undo.shift();
      redo.length = 0;
      edit.raw = raw;
      flushField(edit);
    },
    exit:direction => { if (!moveToNeighbor(edit,direction)) closeBlock(true); }
  });

  holder.addEventListener('keydown', event => {
    if (event.isComposing || event.keyCode===229 || activeBlock!==edit) return;
    const key = event.key;
    if ((event.metaKey || event.ctrlKey) && key.toLowerCase()==='z') {
      const from = event.shiftKey ? redo : undo, to = event.shiftKey ? undo : redo;
      const step = from.pop();
      if (!step) return;
      event.preventDefault();
      const selected = edit.grid.getSelection();
      to.push({raw:edit.raw,row:selected.top,column:selected.left,widths:edit.grid.getWidths()});
      edit.raw = step.raw;
      edit.grid.update(step.raw,step.widths);
      edit.grid.focus(step.row,step.column);
      flushField(edit);
      return;
    }
    if (key==='Escape' || ((event.metaKey || event.ctrlKey) && key.toLowerCase()==='s')) {
      event.preventDefault();
      event.stopPropagation();
      closeBlock(true);
      return;
    }
    if (event.shiftKey || event.metaKey || event.ctrlKey || event.altKey || !['ArrowUp','ArrowDown'].includes(key)) return;
    const field = edit.field;
    if (!field || field !== event.target || field.selectionStart !== field.selectionEnd) return;
    const direction = key==='ArrowDown' ? 1 : -1;
    const {offset,x} = caretLayout.vertical(field,direction,verticalX);
    verticalX = x;
    if (offset != null) {
      field.setSelectionRange(offset,offset);
      caretLayout.reveal(field);
    } else {
      const cell = field.closest('th,td'), row = cell.parentElement.rowIndex+direction;
      if (row >= 0 && row < cell.closest('table').rows.length) {
        edit.grid.focus(row,cell.cellIndex);
        caretLayout.land(edit.field,direction,x);
      } else if (!moveToNeighbor(edit,direction,x)) {
        if (direction<0) return;
        requestBlock(edit.end,null,{afterTable:true});
        caretLayout.reveal(activeBlock.field);
      }
    }
    event.preventDefault();
  }, true);
  holder.addEventListener('focusout', () => queueMicrotask(() => {
    if (activeBlock === edit && !pointerDown && !editorHasFocus(edit)) closeBlock();
  }));
  // Read the rich clipboard before the grid consumes its flattened text representation.
  holder.addEventListener('paste', event => {
    if (!event.isTrusted || event.defaultPrevented) return;
    event.preventDefault();
    pasteIntoBlock(edit,event.clipboardData?.getData('text/plain') ?? '',event.clipboardData?.getData('text/html'));
  },true);
  if (cell) {
    edit.grid.focus(cell.row,cell.column);
    const field = edit.field, local = Math.min(field.value.length,cell.caret ?? field.value.length);
    field.setSelectionRange(local,local);
    if (cell.menu) edit.grid.openMenu(cell.menu.x,cell.menu.y);
  } else edit.grid.focusAt(offset-span.start);
}

document.addEventListener('contextmenu', event => {
  const block=event.target.closest('.note-table-scroll'), td=event.target.closest('th,td');
  if (!block || !td || !tableSources.has(block) || state?.editable===false) return;
  event.preventDefault();
  const cell={row:td.parentElement.rowIndex,column:td.cellIndex,menu:{x:event.clientX,y:event.clientY}};
  requestBlock(sourceBlocks.get(block).start,null,cell);
});
