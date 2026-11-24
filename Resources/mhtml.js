'use strict';

// MIME boundaries delimit complete lines. Keep transfer bodies byte-for-byte until
// the part's transfer encoding and character set are known.
class MHTMLArchive {
  constructor(binary) {
    this.parts = [];
    this.locations = new Map();
    this.pages = [];
    this.readPart(binary, '', 0);
    if (!this.pages.length) throw Error('存档中没有可阅读的 HTML 页面。');
    if (!this.pages.includes(this.root)) this.root = this.pages[0];
  }
  static parameter(header, key) {
    const match = new RegExp('(?:^|;)\\s*'+key+'\\s*=\\s*(?:"((?:\\\\.|[^"\\\\])*)"|([^;\\s]+))','i').exec(header);
    return match ? (match[1] ?? match[2]).replace(/\\(.)/g,'$1') : '';
  }
  static url(value, base) {
    try { const url = new URL(value,base || 'https://archive.invalid/'); url.hash = ''; return url.href; }
    catch { return value; }
  }
  readPart(raw, base, depth) {
    const divider = /\r?\n\r?\n/.exec(raw);
    if (!divider || depth > 20) return;
    const headers = {};
    for (const line of raw.slice(0,divider.index).replace(/\r?\n[ \t]+/g,' ').split(/\r?\n/)) {
      const at = line.indexOf(':');
      if (at > 0) headers[line.slice(0,at).toLowerCase()] = line.slice(at+1).trim();
    }
    const header = headers['content-type'] || '', type = header.split(';')[0].trim().toLowerCase();
    const data = raw.slice(divider.index + divider[0].length);
    const location = MHTMLArchive.url(headers['content-location'] || headers['snapshot-content-location'] || '',
                                      headers['content-base'] || base);
    if (type.startsWith('multipart/')) {
      const boundary = MHTMLArchive.parameter(header,'boundary');
      if (!boundary) return;
      const escaped = boundary.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
      const delimiter = new RegExp('(?:^|\\r?\\n)--'+escaped+'(--)?[ \\t]*(?:\\r?\\n|$)','g');
      let from = null, ended = false;
      for (const m of data.matchAll(delimiter)) {
        if (from !== null) this.readPart(data.slice(from,m.index),location,depth+1);
        if (m[1]) { ended = true; break; }
        from = m.index+m[0].length;
      }
      if (!ended && from !== null) this.readPart(data.slice(from),location,depth+1);
      if (!depth) this.root = this.locations.get('cid:'+MHTMLArchive.parameter(header,'start').replace(/^<|>$/g,''));
      return;
    }
    if (!type) return;
    const id = (headers['content-id'] || '').replace(/^<|>$/g,'');
    const part = {type, location, id, encoding:(headers['content-transfer-encoding'] || '').toLowerCase(),
                  charset:MHTMLArchive.parameter(header,'charset'), data};
    this.parts.push(part);
    if (id) this.locations.set('cid:'+id,part);
    if (headers['content-location'] && !this.locations.has(location)) this.locations.set(location,part);
    if (['text/html','application/xhtml+xml'].includes(type)) this.pages.push(part);
  }
  resolve(value, base) {
    if (/^cid:/i.test(value)) {
      try { return this.locations.get('cid:'+decodeURIComponent(value.slice(4).split('#')[0])); }
      catch { return undefined; }
    }
    return this.locations.get(MHTMLArchive.url(value,base));
  }
  static bytes(part) {
    let data = part.data;
    if (part.encoding === 'base64') data = atob(data.replace(/\s/g,''));
    else if (part.encoding === 'quoted-printable') data = data.replace(/=[ \t]*\r?\n|=([\da-f]{2})/gi,(_,hex)=>hex ? String.fromCharCode(parseInt(hex,16)) : '');
    return Uint8Array.from(data,c=>c.charCodeAt(0));
  }
  static text(part) {
    const bytes = MHTMLArchive.bytes(part);
    const prefix = new TextDecoder('windows-1252').decode(bytes.subarray(0,4096));
    const charset = part.charset || (bytes[0]===255 && bytes[1]===254 ? 'utf-16le' :
      bytes[0]===254 && bytes[1]===255 ? 'utf-16be' : /(?:charset\s*=\s*["']?|@charset\s+["'])([\w.-]+)/i.exec(prefix)?.[1]) || 'utf-8';
    try { return new TextDecoder(charset).decode(bytes); }
    catch { return new TextDecoder().decode(bytes); }
  }
}
globalThis.MHTMLArchive = MHTMLArchive;

function showMHTML(encoded) {
  const archive = new MHTMLArchive(atob(encoded));
  const blobs = new Map(), building = new Set(), documents = new Map();
  const html = part => {
    if (!documents.has(part)) documents.set(part,new DOMParser().parseFromString(MHTMLArchive.text(part),'text/html'));
    return documents.get(part);
  };
  function resource(value, base) {
    if (!value || value.startsWith('#') || /^data:(?:image|audio|video|font)\//i.test(value)) return value;
    const part = archive.resolve(value,base);
    return part ? blob(part)+(value.includes('#') ? '#'+value.split('#').slice(1).join('#') : '') : '';
  }
  function css(value, base) {
    return value.replace(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*?))\s*\)/gi,(_,a,b,c)=>
      'url("'+resource((a ?? b ?? c).trim(),base)+'")')
      .replace(/(@import\s+)(["'])(.*?)\2/gi,(_,rule,q,url)=>rule+q+resource(url,base)+q);
  }
  function documentBlob(part) {
    const doc = html(part).cloneNode(true);
    const originalBase = doc.querySelector('base[href]')?.getAttribute('href');
    const base = originalBase ? MHTMLArchive.url(originalBase,part.location) : part.location;
    doc.querySelectorAll('script,base,object,embed,meta[http-equiv],link:not([rel~="stylesheet" i])').forEach(el=>el.remove());
    for (const el of doc.querySelectorAll('*')) {
      for (const attr of el.getAttributeNames()) {
        if (/^on/i.test(attr) || ['srcdoc','integrity','crossorigin','nonce','ping','action','formaction'].includes(attr)) el.removeAttribute(attr);
      }
      if (el.matches('a,area')) {
        const href = el.getAttribute('href') || '';
        if (href && !href.startsWith('#')) {
          const local = resource(href,base);
          const external = MHTMLArchive.url(href,base) + (href.includes('#') ? href.slice(href.indexOf('#')) : '');
          if (local || /^https?:/i.test(external)) el.setAttribute('href',local || external);
          else el.removeAttribute('href');
        }
        el.removeAttribute('target');
      }
      for (const name of ['src','poster','background','href','xlink:href']) {
        if (!el.hasAttribute(name) || (name==='href' && el.matches('a,area'))) continue;
        const local = resource(el.getAttribute(name),base);
        if (local) el.setAttribute(name,local); else el.removeAttribute(name);
      }
      if (el.hasAttribute('srcset')) {
        const candidates = [];
        for (const m of el.getAttribute('srcset').matchAll(/(?:^|,\s*)(data:[^\s]+|[^\s,]+)\s*([^,]*)(?=,|$)/gi)) {
          const local = resource(m[1],base);
          if (local) candidates.push((local+' '+m[2]).trim());
        }
        if (candidates.length) el.setAttribute('srcset',candidates.join(', ')); else el.removeAttribute('srcset');
      }
      if (el.localName==='style') el.textContent = css(el.textContent,base);
      if (el.hasAttribute('style')) el.setAttribute('style',css(el.getAttribute('style'),base));
      if (el.localName==='iframe') { el.removeAttribute('loading'); el.removeAttribute('allow'); }
    }
    const policy = doc.createElement('meta');
    policy.httpEquiv = 'Content-Security-Policy';
    policy.content = "default-src 'none'; img-src blob: data:; style-src 'unsafe-inline' blob:; font-src blob: data:; media-src blob: data:; frame-src blob:; form-action 'none'; base-uri 'none'";
    doc.head.prepend(policy);
    return new Blob(['<!doctype html>',doc.documentElement.outerHTML],{type:'text/html;charset=utf-8'});
  }
  function blob(part) {
    if (blobs.has(part)) return blobs.get(part);
    if (building.has(part)) return '';
    building.add(part);
    try {
      const file = archive.pages.includes(part) ? documentBlob(part) : part.type==='text/css'
        ? new Blob([css(MHTMLArchive.text(part),part.location)],{type:'text/css;charset=utf-8'})
        : new Blob([MHTMLArchive.bytes(part)],{type:part.type});
      const url = URL.createObjectURL(file);
      blobs.set(part,url);
      return url;
    } finally { building.delete(part); }
  }
  // Browsers can capture a wrapper page containing the actual report several frames deep.
  // Follow its saved frames only when the wrapper has no substantial article of its own.
  function readingPage(part, seen = new Set()) {
    if (seen.has(part)) return null;
    seen.add(part);
    const doc = html(part);
    const prose = [...doc.querySelectorAll('p')].reduce((n,p)=>n+p.textContent.trim().length,0);
    if (prose >= 240 || (doc.querySelector('h1,article') && prose >= 80)) return part;
    for (const frame of doc.querySelectorAll('iframe[src],frame[src]')) {
      const child = archive.resolve(frame.getAttribute('src'),part.location);
      if (archive.pages.includes(child)) {
        const page = readingPage(child,seen);
        if (page) return page;
      }
    }
    return null;
  }
  const first = readingPage(archive.root) || archive.root;
  const picker = document.querySelector('select'), frame = document.querySelector('#page');
  for (const [i,part] of archive.pages.entries()) {
    picker.add(new Option(html(part).title || ('页面 '+(i+1)),String(i),false,part===first));
  }
  picker.parentElement.hidden = archive.pages.length < 2;
  function openPage() { frame.src = blob(archive.pages[picker.selectedIndex]); }
  picker.onchange = openPage;
  openPage();
  document.querySelector('#status').hidden = true;
  frame.hidden = false;
}
