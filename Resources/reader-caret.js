// Measure real wrapped lines using a single text node. Measuring a split node with a marker
// can create an extra break in a word, especially with mixed Latin and Chinese text.
const caretLayout = {
  measure(field, visit) {
    const rect = field.getBoundingClientRect();
    const style = getComputedStyle(field);
    const mirror = document.createElement('div');
    mirror.className = 'paragraph-measure';
    Object.assign(mirror.style, {
      position:'fixed', left:rect.left+'px', top:rect.top-field.scrollTop+'px',
      width:field.clientWidth+'px', font:style.font, lineHeight:style.lineHeight,
      letterSpacing:style.letterSpacing, padding:style.padding, textAlign:style.textAlign,
      direction:style.direction, tabSize:style.tabSize, textIndent:style.textIndent, whiteSpace:style.whiteSpace,
      overflowWrap:style.overflowWrap, wordBreak:style.wordBreak
    });
    const text = document.createTextNode(field.value + '\u200b');
    mirror.append(text);
    document.body.append(mirror);
    const range = document.createRange();
    function at(offset) {
      range.setStart(text, offset);
      range.collapse(true);
      const caret = range.getBoundingClientRect();
      if (caret.height) return caret;
      range.setEnd(text, offset+1);
      return range.getBoundingClientRect();
    }
    try { return visit(at); } finally { mirror.remove(); }
  },

  // Find the first caret at or below a screen line without scanning a long code block.
  lowerBound(length, predicate) {
    let low = 0, high = length+1;
    while (low < high) {
      const mid = Math.floor((low+high)/2);
      if (predicate(mid)) high=mid; else low=mid+1;
    }
    return low;
  },

  segmenter:new Intl.Segmenter(undefined,{granularity:'grapheme'}),
  nearest(field, at, line, x) {
    const len = field.value.length;
    const start = this.lowerBound(len, n => at(n).top >= line-1);
    const stop = this.lowerBound(len, n => at(n).top > line+1);
    let offset = start, distance = Infinity;
    const consider = n => {
      if (n >= stop) return;
      const d = Math.abs(at(n).left-x);
      if (d < distance) { distance=d; offset=n; }
    };
    for (const part of this.segmenter.segment(field.value.slice(start, stop))) consider(start+part.index);
    consider(len);
    return Math.min(offset,len);
  },

  vertical(field, direction, desiredX) {
    return this.measure(field, at => {
      const current = at(field.selectionStart);
      const x = desiredX ?? current.left;
      const len = field.value.length;
      const next = direction > 0
        ? this.lowerBound(len, n => at(n).top > current.top+1)
        : this.lowerBound(len, n => at(n).top >= current.top-1)-1;
      return {x, offset:next<0 || next>len ? null : this.nearest(field,at,at(next).top,x)};
    });
  },

  land(field, direction, x) {
    const offset = this.measure(field, at => this.nearest(field,at,at(direction>0 ? 0 : field.value.length).top,x));
    field.setSelectionRange(offset,offset);
    this.reveal(field);
  },

  reveal(field) {
    const caret = this.measure(field, at => at(field.selectionEnd));
    const gap = 12;
    if (caret.top < gap) scrollBy(0,caret.top-gap);
    else if (caret.bottom > innerHeight-gap) scrollBy(0,caret.bottom-innerHeight+gap);
  }
};
