'use strict';

// Coordinates always refer to the original Markdown. Marked supplies membership,
// including which apparent markers actually belong to code or continuation text.
const listMarker = /^([ \t]*)([-+*]|\d{1,9}[.)])([ \t]+|$)/;
const listTask = /^\[([ xX])\](?:[ \t]+|$)/;
function columns(text) {
  let width = 0;
  for (const ch of text) width += ch === '\t' ? 4 - width % 4 : 1;
  return width;
}
function listStructure(token, raw, start) {
  const lines = raw.split('\n'), offsets = [start];
  for (const line of lines) offsets.push(offsets.at(-1) + line.length + 1);
  function group(list, line, parent, column) {
    const result = [];
    for (const item of list.items) {
      const text = lines[line], marker = text && listMarker.exec(text.slice(column));
      if (!marker) break;
      const at = offsets[line] + column, prefix = marker[0], mark = marker[2];
      const indent = columns(text.slice(0, column) + marker[1]);
      const pad = columns(text.slice(0, column) + prefix) - indent - mark.length;
      const count = item.raw.trimEnd().split('\n').length;
      const until = Math.min(lines.length, line + count);
      const node = {start:at, end:offsets[until]-1, indent, content:indent+mark.length+(pad>=1 && pad<=4 ? pad : 1),
        prefix, mark, gap:marker[3], compact:column>0, parent, groups:[], first:Number(list.start), ordered:list.ordered,
        ordinal:list.ordered ? Number(list.start) + result.length : null, task:item.task, loose:list.loose, token:item};
      result.push(node);
      // Count token lines, not occurrences of the text: task paragraphs in Marked
      // include "[x]" in token.raw even though item.text has already removed it.
      let childLine = line;
      for (const child of item.tokens) {
        if (child.type === 'list') {
          const compact = childLine === line ? column + prefix.length : 0;
          const children = group(child, childLine, node, compact);
          if (children.length) node.groups.push(children);
        }
        childLine += child.raw.split('\n').length - 1;
      }
      line += item.raw.split('\n').length - 1;
      column = 0;
    }
    return result;
  }
  return group(token, 0, null, 0);
}

// An outline is one contiguous run of list blocks. Every head, continuation,
// and blank line has its own row. Commands change ownership, then one writer
// calculates both numbering and indentation from the resulting outline.
class ListOutline {
  constructor(body, roots) {
    this.start = roots[0].start;
    this.end = roots.at(-1).end;
    this.rows = [];
    this.heads = new Map();
    const nodes = [];
    function visit(node) {
      nodes.push(node);
      for (const children of node.groups) children.forEach(visit);
    }
    roots.forEach(visit);
    let next = 0, stack = [];
    for (let at = this.start; at <= this.end;) {
      const nl = body.indexOf('\n', at), end = nl < 0 ? this.end : Math.min(nl, this.end);
      while (stack.length && stack.at(-1).end < at) stack.pop();
      if (next < nodes.length && nodes[next].start <= end) {
        while (next < nodes.length && nodes[next].start <= end) {
          const node = nodes[next++];
          const headEnd = next < nodes.length ? Math.min(nodes[next].start, end) : end;
          const row = {node, parent:this.heads.get(node.parent), mark:node.mark, gap:node.gap,
            indent:node.indent, first:node.first, text:body.slice(node.start+node.prefix.length, headEnd),
            from:node.start, textAt:node.start+node.prefix.length, to:headEnd};
          this.heads.set(node, row);
          this.rows.push(row);
          stack.push(node);
        }
      } else {
        const text = body.slice(at,end), indent = text.match(/^[ \t]*/)[0];
        this.rows.push({owner:this.heads.get(stack.at(-1)), text, indent, from:at, textAt:at, to:end});
      }
      at = end + 1;
    }
    this.dirty = new Set();
  }
  position(offset) {
    const row = this.rows.findLast(row => row.from <= offset && offset <= row.to);
    return row && {row, offset:Math.max(0, offset-row.textAt)};
  }
  endOf(row) {
    let index = this.rows.indexOf(row)+1;
    for (; index < this.rows.length; index++) {
      const next = this.rows[index];
      let parent = next.node ? next.parent : next.owner;
      while (parent && parent !== row) parent = parent.parent;
      if (!parent) break;
    }
    return index;
  }
  previous(row) {
    return this.rows.slice(0,this.rows.indexOf(row)).findLast(other => other.node && other.parent === row.parent);
  }
  move(rows, out) {
    const first = rows[0], parent = first.parent;
    if (rows.some(row => row.parent !== parent)) return false;
    const dest = out ? parent?.parent : this.previous(first);
    if (!out && !dest) return false;
    this.dirty.add(parent);
    this.dirty.add(dest);
    const last = rows.at(-1);
    // Keep document order when a middle child is lifted: its following siblings
    // and the parent's trailing prose now follow the lifted item's children.
    if (out && parent) {
      const rest = this.rows.slice(this.endOf(last), this.endOf(parent));
      for (const row of rest) {
        if (row.node && row.parent === parent) row.parent = last;
        if (!row.node && row.owner === parent) row.owner = last;
      }
    }
    if (out && parent && !parent.text && first.node.compact &&
        this.rows.slice(this.rows.indexOf(parent)+1,this.endOf(parent)).every(row =>
          !row.node || row.parent !== parent || rows.includes(row))) {
      first.joinParent = parent.node.compact;
      this.rows.splice(this.rows.indexOf(parent),1);
    }
    for (const row of rows) {
      row.parent = dest;
      row.moved = true;
      if (out && !parent) {
        row.mark = '';
        row.gap = '';
        row.text = row.text.replace(listTask, '');
      } else if (out) {
        row.mark = parent.mark;
        row.gap = parent.gap || ' ';
        row.first = parent.first;
      } else {
        row.first = 1;
      }
    }
    return true;
  }
  split(pos, selectionEnd) {
    const row = pos.row, head = row.node ? row : row.owner;
    if (!head) return;
    const tail = row.text.slice(selectionEnd.offset);
    row.text = row.text.slice(0,pos.offset);
    if (!row.text.replace(listTask,'').trim() && !tail.trim() && row === head) {
      this.move([head], true);
      return {row, offset:0};
    }
    const task = head.text.match(listTask);
    const box = task || head.node.task ? '[ ] ' : '';
    const sibling = {...head, node:{}, text:box+tail, moved:true, gap:' ', first:head.first};
    const end = this.endOf(head);
    const at = tail.length || row !== head ? this.rows.indexOf(row)+1 : end;
    if (at < end) {
      for (const child of this.rows.slice(at,end)) {
        if (child.parent === head) child.parent = sibling;
        if (child.owner === head) child.owner = sibling;
      }
    }
    const blank = head.node.loose && this.rows[at-1]?.text.trim() ? [{text:'',indent:''}] : [];
    this.rows.splice(at,0,...blank,sibling);
    this.dirty.add(head.parent);
    return {row:sibling, offset:box.length};
  }
  paste(head, from, to, inserted) {
    const at = this.rows.indexOf(head);
    const left = head.text.slice(0,from), right = head.text.slice(to);
    const rows = inserted.rows, top = rows.filter(row => row.node && !row.parent);
    const tail = rows.at(-1), caret = {row:tail,offset:tail.text.length};
    for (const item of top) {
      item.parent = head.parent;
      item.moved = true;
    }
    this.dirty.add(head.parent);
    if (left) {
      head.text = left;
      this.rows.splice(this.endOf(head),0,...rows);
    } else {
      const replacement = top.at(-1);
      for (const row of this.rows) {
        if (row.parent === head) row.parent = replacement;
        if (row.owner === head) row.owner = replacement;
      }
      this.rows.splice(at,1,...rows);
    }
    tail.text += right;
    return caret;
  }
  join(left, right) {
    const at = left.text.length;
    left.text += right.text.replace(listTask, '');
    const owner = left.node ? left : left.owner;
    for (const row of this.rows) {
      if (row.parent === right) row.parent = owner;
      if (row.owner === right) row.owner = owner;
    }
    const a = this.rows.indexOf(left), b = this.rows.indexOf(right);
    if (this.rows.slice(a+1,b).every(row => !row.node && !row.text.trim())) this.rows.splice(a+1,b-a);
    else this.rows.splice(b,1);
    this.dirty.add(right.parent);
    this.dirty.add(left.parent);
    return {row:left, offset:at};
  }
  write() {
    const groups = new Map(), lines = [];
    let previousRow, paragraph;
    let size = 0;
    const add = line => { lines.push(line); size += line.length+1; };
    for (const row of this.rows) {
      const prior = previousRow;
      previousRow = row;
      if (!row.node) {
        const delta = row.owner ? row.owner.width - row.owner.node.content : 0;
        const indent = row.indent || '';
        const padding = !delta || !row.text.trim() ? indent : ' '.repeat(Math.max(0,columns(indent)+delta));
        row.offset = size + padding.length-indent.length;
        add(padding+row.text.slice(indent.length));
        if (row.text.trim()) groups.delete(row.owner);
        continue;
      }
      const parent = row.parent;
      if (paragraph && !parent && row !== paragraph) {
        if (lines.at(-1)?.trim()) add('');
        paragraph = null;
      }
      let indent = row.moved ? (parent?.width ?? 0) : row.indent + (parent ? parent.width-(row.node.parent?.content ?? parent.width) : 0);
      indent = Math.max(0,indent);
      let mark = row.mark, gap = row.gap;
      const previous = groups.get(parent), kind = mark.slice(-1);
      const ordered = /[.)]/.test(kind);
      const number = ordered ? (previous?.kind === kind ? previous.number+1 : (row.moved || row.retyped ? row.first : row.node.ordinal)) : 0;
      if (ordered && this.dirty.has(parent)) mark = Math.min(number,999999999)+kind;
      if (!mark) {
        if (lines.length && lines.at(-1).trim()) add('');
        row.offset = size;
        row.width = 0;
        paragraph = row;
        add(row.text);
        if (this.rows.at(-1) !== row && this.rows[this.rows.indexOf(row)+1].text.trim()) add('');
        groups.delete(parent);
        continue;
      }
      groups.set(parent,{kind,number});
      if (!gap && row.text) gap = ' ';
      // A lone hyphen immediately below parent prose is a Setext underline.
      if (mark === '-' && !row.text && parent && lines.at(-1)?.trim() && prior === parent && !row.node.compact) add('');
      const originalIndent = row.node.prefix?.match(/^[ \t]*/)[0] ?? '';
      const padding = columns(originalIndent) === indent ? originalIndent : ' '.repeat(indent);
      const prefix = padding+mark+gap;
      const gapWidth = columns(prefix)-indent-mark.length;
      row.width = indent+mark.length+(gapWidth>=1 && gapWidth<=4 ? gapWidth : 1);
      if (parent && prior === parent && !parent.text && (row.joinParent || (row.node.compact && !row.moved))) {
        const joined = lines.pop();
        size -= joined.length+1;
        row.offset = size+joined.length+mark.length+gap.length;
        add(joined+mark+gap+row.text);
      } else {
        row.offset = size + prefix.length;
        add(prefix+row.text);
      }
    }
    return lines.join('\n');
  }
}
