// Slice the source at top-level Markdown headings. Never render HTML back to Markdown.
function splitStockReport(original, headings, final) {
  const source = original.replace(/\r\n?/g, '\n');
  const extraCRs = [];
  if (source.length !== original.length) {
    for (const match of original.matchAll(/\r\n/g)) extraCRs.push(match.index - extraCRs.length);
  }
  const offset = n => n + extraCRs.filter(p => p < n).length;
  class ReportTokenizer extends marked.Tokenizer {
    heading(src) {
      const token = super.heading(src);
      if (token) token.start = source.length - src.length;
      return token;
    }
    html(src) {
      const token = super.html(src);
      if (token) token.start = source.length - src.length;
      return token;
    }
    reflink(src, links) {
      let label;
      const token = super.reflink(src, new Proxy(links, {
        get(target, key) { label = key; return target[key]; }
      }));
      if (token && (token.type === 'image' || token.type === 'link')) token.reference = label;
      return token;
    }
  }
  const tokens = marked.lexer(source, {...marked.defaults, tokenizer: new ReportTokenizer()});
  const chapters = [], introTokens = [], definitions = new Map();
  let end = source.length, finished = false;
  for (const token of tokens) {
    if (token.type === 'html' && token.raw.trim() === '<!-- feynman-report-end -->' &&
        !source.slice(token.start + token.raw.length).trim()) {
      finished = true;
      end = token.start;
      break;
    }
    if (token.type === 'heading' && token.depth === 2 && /^\d+[.、．]\s*/.test(token.text)) {
      const title = token.text.replace(/^(\d+)[.、．]\s*/, '$1. ').replace(/\s*〔[^〕]*〕\s*$/, '').trim();
      if (title !== headings[chapters.length]) {
        if (final) throw Error('章节标题与模板不一致：' + token.text);
        break;
      }
      const newline = source.indexOf('\n', token.start);
      chapters.push({start:token.start, bodyStart:newline < 0 ? source.length : newline + 1,
                     tokens:[], refs:new Set()});
    } else if (token.type === 'def') {
      definitions.set(token.tag, {chapter:Math.max(0,chapters.length-1), raw:token.raw});
    } else if (chapters.length) {
      chapters[chapters.length-1].tokens.push(token);
    } else {
      // The optional report title and introductory material belong to chapter zero.
      introTokens.push(token);
    }
  }
  if (final && (chapters.length !== headings.length || !finished)) {
    throw Error('全文结构不完整，识别到 ' + chapters.length + ' / ' + headings.length + ' 章' +
                (finished ? '。' : '，缺少全文结束标记。'));
  }
  if (chapters.length) chapters[0].tokens.unshift(...introTokens);
  return chapters.map((chapter, i) => {
    let body = original.slice(offset(chapter.bodyStart), offset(chapters[i+1]?.start ?? end));
    if (i === 0) body = original.slice(0, offset(chapter.start)) + body;
    if (final && !body.trim()) throw Error('章节缺少正文：' + headings[i]);
    marked.walkTokens(chapter.tokens, token => { if (token.reference) chapter.refs.add(token.reference); });
    for (const key of chapter.refs) {
      const def = definitions.get(key);
      if (def && def.chapter !== i) body += '\n\n' + def.raw;
    }
    return body;
  });
}
