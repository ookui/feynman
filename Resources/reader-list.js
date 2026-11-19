'use strict';

// Marked removes the parent indentation when tokenizing nested items. Map its
// line numbers back to the original Markdown, including continuation lines.
const listItems = new WeakMap();
const listParts = new WeakMap();
const listMarker = /^([ \t]*)([-+*]|\d+[.)])([ \t]+|$)/;
function mapListItems(root, token, raw, start) {
  const lines=raw.split('\n'), offsets=[start];
  for (const line of lines) offsets.push(offsets.at(-1)+line.length+1);
  const items=[];
  function visit(list, element, line, parent) {
    let previous=null;
    const children=[...element.children].filter(el=>el.tagName==='LI');
    for (const [i,item] of list.items.entries()) {
      const el=children[i], marker=listMarker.exec(lines[line] ?? '');
      if (!el || !marker) return;
      const count=item.raw.replace(/\n+$/,'').split('\n').length;
      const indent=columns(marker[1]), padding=columns(marker[0])-indent-marker[2].length;
      const info={start:offsets[line], end:offsets[line+count]-1, indent,
        content:indent+marker[2].length+(padding>=1 && padding<=4 ? padding : 1),
        parent,previous,items};
      items.push(info);
      listItems.set(el,info);
      if (!parent) {
        const children=item.tokens;
        const inline=children.length===1 && children[0].type==='text' ? children[0].tokens : null;
        sourceBlocks.set(el,{start:info.start,end:info.end,inline});
      }
      // Preserve the source's optional leading indentation on a standalone list.
      if (!parent && indent) el.style.marginInlineStart=indent+'ch';
      const nested=[...el.children].filter(child=>child.matches('ul,ol'));
      const sublists=[];
      let cursor=0, n=0;
      for (const child of item.tokens) {
        const at=item.text.indexOf(child.raw,cursor);
        if (at<0) continue;
        if (child.type==='list' && nested[n]) {
          const node=nested[n++], childLine=line+item.text.slice(0,at).split('\n').length-1;
          const last=visit(child,node,childLine,info);
          if (last) sublists.push({node,start:offsets[childLine],end:last.end});
        }
        cursor=at+child.raw.length;
      }
      if (sublists.length) {
        info.sublistStarts=sublists.map(sub=>sub.start);
        mapListProse(el,info,sublists,raw,start);
      }
      previous=info;
      line+=item.raw.split('\n').length-1;
    }
    return previous;
  }
  visit(token,root,0,null);
}
// Each editable span stops at a direct sublist, so editing a parent leaves
// its children mounted and clickable. A loose list can have more prose after it.
function mapListProse(el,item,sublists,raw,start) {
  let from=item.start, first=el.firstChild;
  for (const sub of [...sublists,{node:null,start:item.end}]) {
    const leading=from===item.start;
    const text=raw.slice(from-start,sub.start-start).replace(/(?:\n[ \t]*)+$/,'');
    if (leading || text.trim()) {
      const skip=leading ? 0 : text.match(/^(?:[ \t]*\n)*/)[0].length;
      const part=document.createElement('div');
      el.insertBefore(part,first);
      while (first && first!==sub.node) {
        const next=first.nextSibling;
        part.append(first);
        first=next;
      }
      listParts.set(part,{start:from+skip,end:from+text.length,leading});
    }
    if (sub.node) {
      from=sub.end+1;
      first=sub.node.nextSibling;
    }
  }
}
function columns(whitespace) {
  let column=0;
  for (const c of whitespace) column+=c==='\t' ? 4-column%4 : 1;
  return column;
}

function listItemAt(offset) {
  return [...article.querySelectorAll('li')].map(el=>listItems.get(el))
    .filter(item=>item && item.start<=offset && offset<=item.end).at(-1);
}

function indentList(first,last,outdent,selection) {
  if (!first || !last || first.items!==last.items) return false;
  const items=first.items, selected=items.slice(items.indexOf(first),items.indexOf(last)+1);
  const edits=[], breaks=new Set(), body=state.body;
  function paragraphBreak(at) {
    if (at>0 && at<body.length && body.slice(body.lastIndexOf('\n',at-2)+1,at-1).trim() &&
        !/^[ \t]*(?:\n|$)/.test(body.slice(at))) breaks.add(at);
  }
  let covered=-1, groupParent, delta=0;
  for (const item of selected) {
    if (item.start<covered) continue; // Moving a parent also moves its descendants.
    if (groupParent!==item.parent || outdent) {
      groupParent=item.parent;
      if (outdent) delta=-Math.max(0,item.indent-(item.parent?.indent ?? 0));
      else if (item.previous) delta=Math.max(0,item.previous.content-item.indent);
      else {
        // Without a preceding sibling Markdown permits up to three spaces of
        // visual indentation. Four would turn the list into a code block.
        const extra=item.indent-(item.parent?.content ?? 0);
        delta=extra<2 ? 2 : 0;
      }
    }
    covered=item.end;
    const unlist=outdent && !item.parent && item.indent===0;
    if (unlist) {
      paragraphBreak(item.start);
      paragraphBreak(item.end+1);
      for (const at of item.sublistStarts ?? []) paragraphBreak(at);
      delta=-item.content;
    }
    if (!delta && !unlist) continue;
    for (let at=item.start; at<=item.end;) {
      const newline=state.body.indexOf('\n',at);
      const end=newline<0 ? item.end : Math.min(item.end,newline);
      const line=state.body.slice(at,end);
      if (line.trim()) {
        const stripMarker=unlist && at===item.start;
        const prefix=stripMarker ? line.match(/^[ \t]*(?:[-+*]|\d+[.)])(?:[ \t]+|$)(?:\[[ xX]\](?:[ \t]+|$))?/)[0] : line.match(/^[ \t]*/)[0];
        const value=stripMarker ? '' : ' '.repeat(Math.max(0,columns(prefix)+delta));
        if (value!==prefix) edits.push({at,prefix,value});
      }
      at=end+1;
    }
  }
  for (const edit of edits) {
    if (breaks.delete(edit.at)) edit.value='\n'+edit.value;
  }
  for (const at of breaks) edits.push({at,prefix:'',value:'\n'});
  edits.sort((a,b)=>a.at-b.at);
  if (!edits.length) return true;
  const start=edits[0].at, end=edits.at(-1).at+edits.at(-1).prefix.length;
  let value='', cursor=start;
  for (const change of edits) {
    value+=state.body.slice(cursor,change.at)+change.value;
    cursor=change.at+change.prefix.length;
  }
  function moved(offset) {
    let shift=0;
    for (const change of edits) {
      if (offset<change.at) break;
      const diff=change.value.length-change.prefix.length;
      if (offset<change.at+change.prefix.length) return change.at+shift+Math.max(change.value.startsWith('\n') ? 1 : 0,offset-change.at+diff);
      shift+=diff;
    }
    return offset+shift;
  }
  const after=selection.rendered ? selection : {...selection,start:moved(selection.start),end:moved(selection.end)};
  const step={start,removed:state.body.slice(start,end),value,restoreCaret:first.start,caret:moved(first.start),
    listBefore:selection,listAfter:after};
  if (state.editID) recordBlockSplice(step);
  else commitRange(step);
  return true;
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
    edit.field.setSelectionRange(selection.start-edit.start,selection.end-edit.start,selection.backward ? 'backward' : 'forward');
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

function indentEditingItem(edit,outdent) {
  const {field}=edit, start=fieldStart(edit)+field.selectionStart, end=fieldStart(edit)+field.selectionEnd;
  const selection={start,end,backward:field.selectionDirection==='backward'};
  closeBlock(false,false);
  let lastOffset=end>start ? end-1 : end;
  while (lastOffset>start && state.body[lastOffset]==='\n') lastOffset--;
  const first=listItemAt(start), last=listItemAt(lastOffset);
  indentList(first,last,outdent,selection);
  // A list at its outer boundary still owns Tab and keeps the caret in place.
  if (!activeBlock && getSelection().isCollapsed) restoreListSelection(selection);
}

function indentRenderedItems(range,outdent) {
  const pos=positionForRange(range);
  if (!pos) return false;
  const hits=index.spans.filter(s=>pos.start<s.end && pos.end>s.start);
  const owner=s=>listItems.get((s.element.parentElement ?? s.element).closest('li'));
  const first=owner(hits[0]), last=owner(hits.at(-1));
  const sel=getSelection();
  return indentList(first,last,outdent,{...pos,rendered:true,
    backward:sel.anchorNode===range.endContainer && sel.anchorOffset===range.endOffset});
}
