(function (global) {
  'use strict';
  const factory = global.markdownit || (typeof require === 'function' && require('./vendor/markdown-it.min.js'));
  if (!factory) throw new Error('markdown-it is required');
  const md = factory({html:true, linkify:true, breaks:false});
  const esc = md.utils.escapeHtml;
  const safeTag = html => html.replace(/<!--[\s\S]*?-->|<[^>]*>/g, tag => {
    if (/^<\/?(?:b|strong|i|em|s|del|u|sub|sup|mark|kbd|p|div|span|blockquote|ul|ol|li|table|thead|tbody|tr|th|td|details|summary|br|hr)\s*\/?\s*>$/i.test(tag)) return tag;
    return esc(tag);
  });
  md.renderer.rules.html_block = (t,i) => safeTag(t[i].content);
  md.renderer.rules.html_inline = (t,i) => safeTag(t[i].content);
  function imageURL(src, note, wiki = false) {
    const raw = src.split(/[?#]/)[0];
    const parent = note.split('/').slice(0,-1);
    function resolve(base, path) {
      const parts = [...base];
      for (const item of path.split('/')) {
        if (!item || item === '.') continue;
        if (item === '..') { if (!parts.length) return null; parts.pop(); }
        else parts.push(item);
      }
      return parts.join('/');
    }
    let decoded;
    try { decoded = decodeURIComponent(raw); } catch (_) { return ''; }
    const direct = resolve(raw.startsWith('/') ? [] : parent, decoded);
    if (!direct) return '';
    const folder = global.SimaSettings?.imageFolder(note);
    const fallback = folder && !raw.startsWith('/') && !decoded.split('/').includes('..')
      ? resolve(parent, folder + '/' + decoded) : null;
    const matched = wiki && global.SimaShell?.wikiImagePath(decoded, direct, fallback);
    if (matched) return global.assetURL(matched);
    const url = global.assetURL(direct);
    return fallback && fallback !== direct ? url + '?fallback=' + encodeURIComponent(fallback) : url;
  }
  // Give standard destinations, titles and reference images first choice.
  const standardImage = md.inline.ruler.__rules__.find(rule => rule.name === 'image').fn;
  function spacedImage(state, silent) {
    const {src, pos, posMax} = state;
    if (!src.startsWith('![', pos)) return false;
    const labelEnd = md.helpers.parseLinkLabel(state, pos + 1, false);
    if (labelEnd < 0 || src[labelEnd + 1] !== '(') return false;
    const start = labelEnd + 2;
    let depth = 0, end = start, title;
    for (; end < posMax; end++) {
      const ch = src[end];
      if (/[\r\n<>]/.test(ch)) return false;
      if (ch === '\\') { end++; continue; }
      if (ch === ' ' && /["']/.test(src[end + 1] || ' ')) {
        const parsed = md.helpers.parseLinkTitle(src, end + 1, posMax);
        if (parsed.ok && src[parsed.pos] === ')') { title = parsed; break; }
      }
      if (ch === '(') depth++;
      if (ch === ')' && depth-- === 0) break;
    }
    if (end >= posMax) return false;
    const path = src.slice(start, end).trim();
    if (!path.includes(' ') || /^(?:[a-z][\w+.-]*:|\/\/)/i.test(path) ||
        !/\.[a-z\d]+(?:[?#].*)?$/i.test(path)) return false;
    const href = md.normalizeLink(md.utils.unescapeAll(path));
    if (!md.validateLink(href)) return false;
    if (!silent) {
      const label = src.slice(pos + 2, labelEnd), children = [];
      md.inline.parse(label, md, state.env, children);
      const token = state.push('image', 'img', 0);
      token.attrs = [['src', href], ['alt', '']];
      token.content = label;
      token.children = children;
      if (title) token.attrSet('title', title.str);
    }
    state.pos = (title?.pos ?? end) + 1;
    return true;
  }
  function wikiImage(state, silent) {
    const match = /^!\[\[([^|\]\n]+?\.(?:svg|png|apng|jpe?g|gif|webp|avif|hei[cf]|tiff?|bmp|ico))(?:\|([^\]\n]*))?\]\]/i.exec(state.src.slice(state.pos, state.posMax));
    if (!match || /^(?:[a-z][\w+.-]*:|\/\/)/i.test(match[1])) return false;
    if (!silent) {
      const token = state.push('image', 'img', 0);
      token.attrs = [['src', md.normalizeLink(match[1])], ['alt', '']];
      const width = /^[1-9]\d{0,4}$/.test(match[2] || '') && match[2];
      if (width) token.attrSet('width', width);
      const alt = new state.Token('text', '', 0);
      alt.content = (!width && match[2]) || match[1].split('/').pop();
      token.children = [alt];
      token.meta = {wikiImage:true};
    }
    state.pos += match[0].length;
    return true;
  }
  // A width followed by an optional alignment, both local to this image occurrence.
  const imageLayout = /^(?:\{width=([1-9]\d{0,4})\})?(?:\{align=(left|center|right)\})?/;
  md.inline.ruler.at('image', (state, silent) => {
    const start = state.pos;
    if (!wikiImage(state, silent) && !standardImage(state, silent) && !spacedImage(state, silent)) return false;
    const end = state.pos;
    const layout = state.src[end] === '{' && imageLayout.exec(state.src.slice(end, state.posMax));
    if (layout) state.pos += layout[0].length;
    if (!silent) {
      const token = state.tokens.at(-1);
      if (layout?.[1]) token.attrSet('width', layout[1]);
      token.meta = {...token.meta, align:layout?.[2]};
      if (state.env.editableImages) {
        token.meta.imageEnd = end;
        token.meta.source = state.src.slice(start, state.pos);
      }
    }
    return true;
  });
  // Inline offsets omit quote/list prefixes. Map the insertion point to the original line.
  md.core.ruler.after('inline', 'image_positions', state => {
    if (!state.env.editableImages) return;
    const lines = state.src.split('\n'), starts = [0];
    for (const line of lines) starts.push(starts.at(-1) + line.length + 1);
    for (const token of state.tokens) {
      if (!token.map || !token.children) continue;
      for (const image of token.children) {
        if (image.meta?.imageEnd == null) continue;
        const prefix = token.content.slice(0, image.meta.imageEnd).split('\n');
        const row = token.map[0] + prefix.length - 1;
        const column = lines[row]?.indexOf(token.content.split('\n')[prefix.length - 1]);
        if (column >= 0) image.meta.offset = starts[row] + column + prefix.at(-1).length;
      }
    }
  });
  const imageRule = md.renderer.rules.image;
  md.renderer.rules.image = (tokens, idx, opts, env, self) => {
    const token = tokens[idx], src = token.attrGet('src') || '';
    if (/^(?:https?:|data:|file:|\/\/|[a-z][\w+.-]*:)/i.test(src)) {
      if (!/^https?:/i.test(src)) token.attrSet('src', '');
    } else if (typeof global.assetURL === 'function') {
      token.attrSet('data-markdown-src', src);
      if (token.meta?.wikiImage) token.attrSet('data-wiki-image', '');
      token.attrSet('src', imageURL(src,env.path || '',token.meta?.wikiImage));
    }
    let html = imageRule(tokens,idx,opts,env,self);
    if (token.meta?.source && token.attrGet('src')) {
      const hint = '拖动调整图片宽度，双击恢复原尺寸';
      const fluid = /\.svg(?:$|[?#])/i.test(src) && !token.attrGet('width') ? ' sima-fluid-svg' : '';
      html = '<span class="sima-sized-image' + fluid + '" data-image-source="' + esc(token.meta.source) + '">' + html + '<button type="button" class="sima-image-grip" data-offset="' +
        (token.meta.offset ?? token.meta.imageEnd) + '" title="' + hint + '" aria-label="' + hint + '">↔</button></span>';
    }
    const align = token.meta?.align;
    return align ? '<span data-image-align="' + align + '" style="display:flex;justify-content:' +
      ({left:'flex-start',center:'center',right:'flex-end'})[align] + '">' + html + '</span>' : html;
  };
  md.inline.ruler.before('link','wiki',function(state,silent) {
    const rest=state.src.slice(state.pos), m=/^\[\[([^\]\n]+)\]\]/.exec(rest);
    if (!m) return false;
    if (!silent) {
      const parts=m[1].split('|'), target=parts.shift().trim(), label=parts.join('|').trim() || target;
      const t=state.push('html_inline','',0); t.content='<a href="'+esc(target)+'" data-wiki="true" data-link="'+esc(target)+'">'+esc(label)+'</a>'; t.meta={trustedWiki:true};
    }
    state.pos+=m[0].length; return true;
  });
  const htmlInline=md.renderer.rules.html_inline;
  md.renderer.rules.html_inline=(t,i,o,e,s)=>t[i].meta?.trustedWiki ? t[i].content : htmlInline(t,i,o,e,s);
  for (const [name,marker,tag] of [['mark','==','mark'],['sup','^','sup'],['sub','~','sub']]) {
    md.inline.ruler.before('emphasis','sima_'+name,function(state,silent){
      if(!state.src.startsWith(marker,state.pos) || (marker==='~' && state.src.startsWith('~~',state.pos)) || (marker==='^' && state.src[state.pos-1]==='[')) return false;
      const start=state.pos+marker.length,end=state.src.indexOf(marker,start);
      if(end<=start || /\s/.test(state.src[start]) || /\s/.test(state.src[end-1])) return false;
      if(!silent){const open=state.push('sima_'+name+'_open',tag,1);open.markup=marker;const txt=state.push('text','',0);txt.content=state.src.slice(start,end);const close=state.push('sima_'+name+'_close',tag,-1);close.markup=marker;}
      state.pos=end+marker.length;return true;
    });
  }
  md.inline.ruler.before('escape','sima_math',function(state,silent) {
    const pos = state.pos, src = state.src;
    if (src[pos]==='\\') {
      const ref=/^\\(?:eqref|ref)\{[^{}\s]+\}/.exec(src.slice(pos,state.posMax));
      if (ref) {
        if (!silent) state.push('sima_math','',0).content=ref[0];
        state.pos+=ref[0].length;
        return true;
      }
    }
    const parens = src.startsWith('\\(',pos);
    if (!parens && (src[pos] !== '$' || src[pos+1] === '$' || src[pos-1] === '$' || /\s/.test(src[pos+1]))) return false;
    const start = pos + (parens ? 2 : 1), close = parens ? '\\)' : '$';
    let end = start;
    while ((end = src.indexOf(close,end)) !== -1) {
      let slash = end;
      while (slash > start && src[slash-1] === '\\') slash--;
      if ((end-slash)%2 === 0) break;
      end += close.length;
    }
    if (end <= start || src.slice(start,end).includes('\n') ||
        (!parens && (/\s/.test(src[end-1]) || /[0-9]/.test(src[end+1] || '')))) return false;
    // A price can precede the opening dollar of a real formula in the same sentence.
    if (!parens && /^\d/.test(src[start])) {
      const body = src.slice(start,end);
      const amount = /^\d+(?:,\d{3})*(?:\.\d+)?(?:bn|mm|[kmbt])?/i.exec(body)[0];
      const tail = body.slice(amount.length);
      const nextFormula=/^(?:[A-Za-z\\]|\d)[^\s$\p{Script=Han}，。；：、！？（）]*\$(?!\d)/u.test(src.slice(end+1));
      if (/^\s*(?:[，。；：、！？（）]|\p{Script=Han}|[,;:]\s)/u.test(tail) ||
          (nextFormula && (!tail || /^\s+[A-Za-z]+\b/.test(tail)))) return false;
    }
    if (!silent) { const t=state.push('sima_math','',0); t.content=src.slice(start,end); }
    state.pos=end+close.length; return true;
  });
  md.inline.ruler.before('link','sima_footnote',function(state,silent) {
    const m=/^\[\^([^\]\n]+)\]/.exec(state.src.slice(state.pos));
    if(!m || !state.env.footnotes?.[m[1]]) return false;
    if(!silent){const t=state.push('sima_footnote','',0);t.content=m[1];}
    state.pos+=m[0].length;return true;
  });
  md.renderer.rules.sima_footnote=(t,i,o,env)=>'<sup class="footnote-ref" title="'+esc(env.footnotes[t[i].content])+'">['+esc(t[i].content)+']</sup>';
  function math(tex,display) {
    const marker=display?'$$':'$';
    const fallback='<code class="sima-math-source">'+esc(marker+tex+marker)+'</code>';
    if (/\\(?:href|url|html|class|style|cssId|require|unicode)\b/i.test(tex)) return fallback;
    return '<span class="sima-tex" data-display="'+Number(display)+'" data-tex="'+esc(tex)+'">'+fallback+'</span>';
  }
  md.renderer.rules.sima_math=(t,i)=>math(t[i].content,false);
  let diagramSerial=0;
  function enhanceDiagrams(root=global.document) {
    if (!global.document || !global.mermaid?.render) return;
    global.mermaid.initialize({startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,htmlLabels:false,flowchart:{htmlLabels:false}});
    return Promise.all([...root.querySelectorAll('pre.sima-mermaid-source:not([data-rendering])')].map(async pre=>{
      const source=pre.textContent;
      if (/%%\s*\{|^\s*click\s/im.test(source)) return;
      pre.dataset.rendering='1';
      try {
        const result=await global.mermaid.render('sima-diagram-'+(++diagramSerial),source);
        const parsed=new DOMParser().parseFromString(result.svg,'image/svg+xml'),svg=parsed.documentElement;
        if(svg.localName!=='svg' || parsed.querySelector('parsererror')) return;
        svg.querySelectorAll('script,foreignObject,iframe,object,embed,a,style').forEach(n=>n.remove());
        for(const el of [svg,...svg.querySelectorAll('*')]) for(const attr of [...el.attributes]) {
          if (/^on/i.test(attr.name) || /^(?:href|xlink:href|src)$/i.test(attr.name) || /url\s*\(\s*['"]?(?!#)/i.test(attr.value)) el.removeAttribute(attr.name);
        }
        const palette=parsed.createElementNS('http://www.w3.org/2000/svg','style');
        svg.classList.add('sima-diagram');
        palette.textContent='.sima-diagram :is(.node rect,.node polygon,.node ellipse,.node circle){fill:#edf3ef;stroke:#526d5b}.sima-diagram text{fill:#25312a}.sima-diagram :is(.edgePath path,path.flowchart-link,.messageLine0,.messageLine1){fill:none;stroke:#51675b}.sima-diagram marker path{fill:#51675b}';
        svg.prepend(palette);
        pre.replaceWith(global.document.importNode(svg,true));
      } catch (_) { pre.dataset.rendering='error'; }
    }));
  }
  const fence=md.renderer.rules.fence;
  md.renderer.rules.fence=(t,i,o,e,s)=> {
    const token=t[i], lang=token.info.trim().split(/\s+/)[0].toLowerCase();
    if(lang==='math') return '<div class="sima-math-display">'+math(token.content,true)+'</div>';
    if(lang==='mermaid') { if(typeof global.setTimeout==='function') global.setTimeout(()=>enhanceDiagrams(),0); return '<pre class="sima-mermaid-source"><code>'+esc(token.content)+'</code></pre>'; }
    if(global.hljs && lang && global.hljs.getLanguage(lang)) {
      try { return '<pre><code class="hljs language-'+esc(lang)+'">'+global.hljs.highlight(token.content,{language:lang}).value+'</code></pre>\n'; } catch (_) {}
    }
    return fence(t,i,o,e,s);
  };
  md.core.ruler.after('inline','sima_tasks',state=>{
    for(let i=0;i<state.tokens.length;i++) {
      const t=state.tokens[i]; if(t.type!=='inline' || !t.children?.length) continue;
      if(state.tokens[i-1]?.type!=='paragraph_open' || state.tokens[i-2]?.type!=='list_item_open') continue;
      const c=t.children[0], m=c.type==='text' && /^\[([ xX])\]\s+/.exec(c.content);
      if(m){c.content=c.content.slice(m[0].length);const checkbox=new state.Token('html_inline','',0);checkbox.meta={trustedWiki:true};checkbox.content='<input type="checkbox"'+(m[1].toLowerCase()==='x'?' checked':'')+'> ';t.children.unshift(checkbox);}
    }
  });
  md.block.ruler.before('fence','sima_math_block',function(state,start,end,silent){
    const line = n => state.src.slice(state.bMarks[n]+state.tShift[n],state.eMarks[n]).trimEnd();
    const first = line(start);
    const open = first.startsWith('$$') ? '$$' : first.startsWith('\\[') ? '\\[' : null;
    if (!open || state.sCount[start]-state.blkIndent >= 4) return false;
    const close = open === '$$' ? '$$' : '\\]';
    let next = start, content = first.slice(open.length);
    if (!content.endsWith(close)) {
      while (++next < end) {
        if (state.sCount[next] < state.blkIndent && line(next)) return false;
        if (line(next).endsWith(close)) break;
      }
      if (next === end) return false;
      content += '\n' + state.getLines(start+1,next+1,state.blkIndent,false).trimEnd();
    }
    if (silent) return true;
    const t = state.push('sima_math_block','',0);
    t.block=true; t.map=[start,next+1]; t.content=content.slice(0,-close.length).trim();
    state.line=next+1; return true;
  },{alt:['paragraph','reference','blockquote','list']});
  md.renderer.rules.sima_math_block=(t,i)=>'<div class="sima-math-display">'+math(t[i].content,true)+'</div>';
  let context={};
  function parse(source) {
    source=String(source || ''); const offsets=[0],blocks=[];
    for(const m of source.matchAll(/\r\n|\n|\r/g)) offsets.push(m.index+m[0].length);
    const lineEnd=line=>offsets[line]===undefined?source.length:offsets[line]-(source[offsets[line]-2]==='\r'?2:1);
    const yaml=/^---[^\S\r\n]*(?:\r\n|\n|\r)[\s\S]*?(?:\r\n|\n|\r)(?:---|\.\.\.)[^\S\r\n]*(?=\r\n|\n|\r|$)/.exec(source);
    let masked=yaml ? yaml[0].replace(/[^\n\r]/g,' ')+source.slice(yaml[0].length) : source;
    const footnotes={}; masked=masked.replace(/^\[\^([^\]\r\n]+)\]:[ \t]*(.*)$/gm,(whole,key,value)=>{footnotes[key]=value;return whole;});
    const env={footnotes}; const tokens=md.parse(masked,env); context={...env,footnotes};
    if(yaml) blocks.push({type:'yaml',start:0,end:yaml[0].length,source:yaml[0]});
    let blockMath, listItems, listStartLine;
    function collectMath(token) {
      const display = token.type==='sima_math_block' || (token.type==='fence' && /^math(?:\s|$)/i.test(token.info.trim()));
      if (display || token.type==='sima_math') blockMath.push({tex:token.content,display});
      if (token.children) token.children.forEach(collectMath);
    }
    for(const token of tokens){
      if (!token.level && token.map && token.nesting>=0) {
        blockMath=[];
        listItems=/^(bullet|ordered)_list_open$/.test(token.type) ? [] : null;
        listStartLine=token.map[0];
      }
      if (listItems && token.type==='list_item_open') {
        listItems.push({line:token.map[0]-listStartLine, until:token.map[1]-listStartLine, level:token.level});
      }
      if (blockMath) collectMath(token);
      if(token.level || !token.map || token.nesting<0) continue;
      const start=offsets[token.map[0]]; let end=lineEnd(token.map[1]);
      while(end>start && /[\r\n]/.test(source[end-1])) end--;
      if(start===undefined || end<start) continue;
      const raw=source.slice(start,end), type=token.type.replace(/_open$/,'');
      const block={type,start,end,source:raw,context,formulas:blockMath};
      if (listItems) block.listItems=listItems;
      blocks.push(block);
    }
    // Reference definitions consume lines without producing tokens; retain them as editable blocks.
    const covered=blocks.slice().sort((a,b)=>a.start-b.start); let pos=0;
    for(const block of [...covered,{start:source.length,end:source.length}]){
      const gap=source.slice(pos,block.start); let m; const lines=/[^\r\n]+/g;
      while((m=lines.exec(gap))) if(m[0].trim()) blocks.push({type:'definition',start:pos+m.index,end:pos+m.index+m[0].length,source:m[0],context});
      pos=Math.max(pos,block.end);
    }
    blocks.sort((a,b)=>a.start-b.start);
    let firstTitle = true;
    const used={}; context.headings=blocks.filter(b=>b.type==='heading').map(b=>{
      const title=b.source.replace(/^#{1,6}\s*/, '').replace(/\s+#+\s*$/, '').replace(/\n[=-]+\s*$/, '').trim();
      const base=title.toLowerCase().replace(/<[^>]*>/g,'').replace(/[^\p{L}\p{N}_ -]/gu,'').trim().replace(/\s+/g,'-') || 'section';
      const n=used[base]||0; used[base]=n+1; b.anchor=base+(n?'-'+n:'');
      const level = /^#{1,6}/.exec(b.source)?.[0].length || (/\n=/.test(b.source)?1:2);
      b.level = level; b.title = title;
      if (firstTitle && level === 1) { b.documentTitle = true; firstTitle = false; }
      return {title,id:b.anchor,level};
    });
    return blocks;
  }
  function renderBlock(block,options={}) {
    const src=block.source || '', env={...(block.context || context),...options};
    if(/^\s*\[toc\]\s*$/i.test(src)) return '<nav class="sima-toc">'+(env.headings||[]).map(h=>'<div class="sima-toc-level-'+h.level+'"><a href="#'+esc(h.id)+'">'+esc(h.title)+'</a></div>').join('')+'</nav>';
    if(block.type==='definition') return '<div class="sima-definition">'+esc(src)+'</div>';
    if(block.type==='yaml') return '<pre class="md-meta-block">'+esc(src)+'</pre>';
    const result=md.render(src,env);
    return block.type==='heading' && block.anchor ? result.replace(/<h([1-6])>/,'<h$1 id="'+esc(block.anchor)+'">') : result;
  }
  function inline(source,options={}) {return md.renderInline(source,{...context,...options});}
  function render(source,options={}) {return parse(source).map(b=>renderBlock(b,options)).join('\n');}
  // Work from rendered text so link destinations and Markdown delimiters never consume the excerpt budget.
  function referenceExcerpt(row) {
    const doc = global.document, template = doc.createElement('template'), env = {path:row.path};
    template.innerHTML = md.render(row.text || '',env);
    const targets = row.targets || [row];
    const destination = raw => md.normalizeLink(md.utils.unescapeAll(raw));
    const matches = (href,wiki) => targets.some(t => !!t.wiki === wiki && (wiki ? t.raw.trim() === href : destination(t.raw) === href));
    const allowed = new Set(['A','B','STRONG','I','EM','S','DEL','CODE','KBD','SUB','SUP','MARK','U']);
    const parts = [];
    let length = 0, focus;
    function append(text, parents) {
      if (!text) return;
      const chars = Array.from(text);
      parts.push({chars,parents,start:length});
      length += chars.length;
    }
    function visit(node, parents) {
      if (node.nodeType === 3) { append(node.data.replace(/\s+/gu,' '),parents); return; }
      if (node.nodeType !== 1) return;
      if (node.tagName === 'IMG') { append(node.alt,parents); return; }
      if (node.tagName === 'BR') { append(' ',parents); return; }
      const tag = node.tagName;
      let element;
      if (allowed.has(tag)) {
        element = doc.createElement(tag.toLowerCase());
        if (tag === 'A') {
          const wiki = node.hasAttribute('data-wiki'), href = node.getAttribute('href') || '';
          element.setAttribute('href',href);
          if (wiki) element.dataset.wiki = 'true';
          if (matches(href,wiki)) element.className = 'reference-target';
        }
        parents = [...parents,element];
      }
      const start = length;
      for (const child of node.childNodes) visit(child,parents);
      if (!focus && element?.classList.contains('reference-target') && length > start) focus = {start,end:length};
    }
    // The block renderer adds a trailing newline that is not part of the content.
    if (template.content.lastChild?.nodeType === 3 && !template.content.lastChild.data.trim()) template.content.lastChild.remove();
    for (const node of template.content.childNodes) visit(node,[]);
    // Reference definitions have no visible block in Markdown. Show the definition's label as the link.
    if (!focus) {
      const target = targets[0], link = doc.createElement('a');
      const label = /^\s*\[([^\]]+)\]:/.exec(row.text || '')?.[1] || row.raw.split('#')[0].split('/').pop() || row.raw;
      link.className = 'reference-target';
      link.setAttribute('href',target.wiki ? target.raw : destination(target.raw));
      if (target.wiki) link.dataset.wiki = 'true';
      parts.length = 0; length = 0;
      append(label,[link]);
      focus = {start:0,end:length};
    }
    const limit = 96, labelLimit = 60;
    const labelLength = focus.end - focus.start;
    const budget = limit - Math.min(labelLength,labelLimit);
    const start = Math.max(0,focus.start - Math.max(Math.floor(budget/2),budget-(length-focus.end)));
    const end = Math.min(length,focus.end + budget-(focus.start-start));
    const result = doc.createDocumentFragment(), copies = new Map();
    function copyRange(from,to) {
      for (const part of parts) {
        const lo = Math.max(0,from-part.start), hi = Math.min(part.chars.length,to-part.start);
        if (lo >= hi) continue;
        let parent = result;
        for (const original of part.parents) {
          if (!copies.has(original)) {
            const copy = original.cloneNode(false);
            parent.append(copy); copies.set(original,copy);
          }
          parent = copies.get(original);
        }
        parent.append(part.chars.slice(lo,hi).join(''));
      }
    }
    if (start > 0) result.append('…');
    if (labelLength > labelLimit) {
      copyRange(start,focus.start + labelLimit-13);
      result.querySelector('.reference-target')?.append('…');
      copyRange(focus.end-12,end);
    } else copyRange(start,end);
    if (end < length) result.append('…');
    return result;
  }
  function htmlDocument(source,options={}) {
    const css=String(options.css||'').replace(/<\/style/gi,'<\\/style');
    return '<!doctype html><html><head><meta charset="utf-8"><style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;line-height:1.65;max-width:900px;margin:2em auto;padding:0 2em}pre{white-space:pre-wrap}img{max-width:100%}table{border-collapse:collapse}th,td{border:1px solid #aaa;padding:.35em .6em}'+css+'</style></head><body>'+render(source,options)+'</body></html>';
  }
  async function exportWithDiagrams(source,options={}) {
    const html=htmlDocument(source,options);
    if(!global.document || !global.DOMParser) return html;
    const doc=new global.DOMParser().parseFromString(html,'text/html');
    await global.SimaMath?.exportDocument(doc);
    await enhanceDiagrams(doc);
    return '<!doctype html>\n'+doc.documentElement.outerHTML;
  }
  global.SimaRender={enhanceDiagrams,imageURL,imageLayout,parse,renderBlock,inline,render,referenceExcerpt,exportHTML:exportWithDiagrams,exportWithDiagrams};
})(globalThis);
