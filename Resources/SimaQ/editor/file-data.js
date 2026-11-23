/* Preserve source tokens, including large JSON integers and quoted CSV fields. */
(function (global) {
  'use strict';
  function json(source) {
    JSON.parse(source.replace(/^\uFEFF/, ''));
    const tokens = [...source.matchAll(/"(?:\\[\s\S]|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null|[{}\[\],:]/g)];
    let cursor = 0;
    function value(depth = 0) {
      if (depth > 200) throw Error('JSON nesting exceeds 200 levels.');
      const token = tokens[cursor++], raw = token[0];
      const node = {start:token.index, end:token.index + raw.length, raw};
      if (raw !== '{' && raw !== '[') {
        node.type = raw[0] === '"' ? 'string' : /^(true|false)$/.test(raw) ? 'boolean' : raw === 'null' ? 'null' : 'number';
        return node;
      }
      node.type = raw === '{' ? 'object' : 'array';
      node.children = [];
      const close = raw === '{' ? '}' : ']';
      while (tokens[cursor][0] !== close) {
        let key = String(node.children.length);
        if (raw === '{') { key = JSON.parse(tokens[cursor++][0]); cursor++; }
        node.children.push({key, node:value(depth + 1)});
        if (tokens[cursor][0] === ',') cursor++;
      }
      node.end = tokens[cursor++].index + 1;
      return node;
    }
    return {root:value(), tokens};
  }
  function formatJSON(source) {
    const {tokens} = json(source);
    let level = 0, result = source.startsWith('\uFEFF') ? '\uFEFF' : '';
    const line = () => '\n' + '  '.repeat(level);
    tokens.forEach((token, i) => {
      const t = token[0], previous = tokens[i - 1]?.[0], next = tokens[i + 1]?.[0];
      if (t === '{' || t === '[') {
        result += t; level++;
        if (next !== '}' && next !== ']') result += line();
      } else if (t === '}' || t === ']') {
        level--;
        if (previous !== '{' && previous !== '[') result += line();
        result += t;
      } else if (t === ',') result += ',' + line();
      else if (t === ':') result += ': ';
      else result += t;
    });
    return result.replace(/\n/g, source.includes('\r\n') ? '\r\n' : '\n') + (source.match(/(?:\r\n|\n|\r)$/)?.[0] || '');
  }
  function csv(source) {
    let at = source.startsWith('\uFEFF') ? 1 : 0, row = [], rows = [];
    while (at < source.length) {
      const start = at;
      let value = '';
      if (source[at] === '"') {
        at++;
        let closed = false;
        while (at < source.length) {
          if (source[at] !== '"') { value += source[at++]; continue; }
          if (source[at + 1] === '"') { value += '"'; at += 2; continue; }
          at++; closed = true; break;
        }
        if (!closed) throw Error('Unclosed CSV quote at character ' + (start + 1));
        while (source[at] === ' ' || source[at] === '\t') at++;
        if (at < source.length && !/[,\r\n]/.test(source[at])) throw Error('Unexpected character after CSV quote at ' + (at + 1));
      } else {
        while (at < source.length && !/[,\r\n]/.test(source[at])) value += source[at++];
      }
      row.push({value, start, end:at});
      const separator = source[at++];
      if (separator === ',') {
        if (at === source.length) row.push({value:'', start:at, end:at});
      } else {
        rows.push(row); row = [];
        if (separator === '\r' && source[at] === '\n') at++;
      }
    }
    if (row.length) rows.push(row);
    return rows;
  }
  const api = {json, formatJSON, csv};
  global.SimaFileData = api;
  if (typeof module !== 'undefined') module.exports = api;
})(globalThis);
