function sanitize(html, sourceFile = file) {
  const template = document.createElement('template');
  template.innerHTML = html;
  // SVGs, including declarative animations, are rendered in an image context.
  for (const svg of template.content.querySelectorAll('svg')) {
    const image = document.createElement('img');
    svg.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
    image.alt = svg.querySelector('title')?.textContent || 'SVG';
    image.setAttribute('data-image-markdown', svg.outerHTML);
    image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg.outerHTML);
    svg.replaceWith(image);
  }
  const mediaURL = (src, image) => {
    if (!src) return '';
    if (/^https?:\/\//i.test(src) || (image && /^data:image\/(?:svg\+xml|png|jpeg|gif|webp|avif)[;,]/i.test(src))) return src;
    if (/^(?:[a-z][\w+.-]*:|\/)/i.test(src)) return '';
    return (image ? 'feynman-image' : 'feynman-media') + '://local/?' + new URLSearchParams({file:sourceFile, src});
  };
  const allowed = new Set('P BR HR H1 H2 H3 H4 H5 H6 UL OL LI STRONG EM B I S DEL CODE PRE BLOCKQUOTE TABLE THEAD TBODY TFOOT TR TH TD CAPTION COLGROUP COL A IMG SUP SUB FIGURE FIGCAPTION DIV SPAN VIDEO SOURCE'.split(' '));
  for (const el of Array.from(template.content.querySelectorAll('*'))) {
    if (el.matches('li input[type=checkbox]')) {
      const box = document.createElement('input');
      box.type = 'checkbox'; box.checked = el.hasAttribute('checked'); box.disabled = true;
      el.replaceWith(box);
      continue;
    }
    if (!allowed.has(el.tagName)) { el.replaceWith(document.createTextNode(el.textContent)); continue; }
    const imageRaw = el.tagName === 'IMG' && (el.getAttribute('data-image-markdown') || el.outerHTML);
    const href = el.getAttribute('href'), alt = el.getAttribute('alt'), src = el.getAttribute('src');
    const preserved = [];
    if (el.matches('td,th')) {
      for (const key of ['rowspan', 'colspan']) {
        const value = el.getAttribute(key);
        if (/^\d{1,3}$/.test(value)) preserved.push([key, value]);
      }
      const align = el.getAttribute('align');
      if (['left','center','right'].includes(align)) preserved.push(['align', align]);
    }
    if (el.matches('video')) {
      for (const flag of ['muted','loop','playsinline']) if (el.hasAttribute(flag)) preserved.push([flag, '']);
      const poster = mediaURL(el.getAttribute('poster'), true);
      if (poster) preserved.push(['poster', poster]);
      preserved.push(['controls', ''], ['preload', 'metadata']);
    }
    for (const attr of [...el.attributes]) el.removeAttribute(attr.name);
    for (const [key,value] of preserved) el.setAttribute(key,value);
    if (el.matches('video,video > source')) {
      const url = mediaURL(src, false);
      if (url) el.setAttribute('src', url);
    }
    if (el.tagName === 'A' && href) el.setAttribute('href', href);
    if (el.tagName === 'IMG') {
      imageSources.set(el, imageRaw);
      if (alt) el.alt = alt;
      const url = mediaURL(src, true);
      if (url) el.src = url;
    }
  }
  for (const image of template.content.querySelectorAll('img')) {
    const suffix = image.nextSibling;
    if (suffix?.nodeType !== Node.TEXT_NODE) continue;
    const match = /^(?:\{width=([1-9]\d{0,4})\})?(?:\{align=(left|center|right)\})?/.exec(suffix.data);
    if (!match[0]) continue;
    suffix.deleteData(0, match[0].length);
    if (match[1]) image.style.width = match[1] + 'px';
    if (match[2]) image.dataset.align = match[2];
  }
  return template.content;
}
function removeDeletedLinks(root,data) {
  const deadIDs = new Set(data.deletedIDs), deadPaths = new Set(data.deletedPaths);
  for (const link of root.querySelectorAll('a[href]')) {
    const href = link.getAttribute('href');
    let removed = false;
    if (href.startsWith('feynman:')) removed = deadIDs.has(href.slice(8).split('#', 1)[0]);
    else if (deadPaths.size && (!/^[a-z][\w+.-]*:/i.test(href) || href.startsWith('project:'))) {
      try {
        const target = new URL(href.startsWith('project:') ? '/' + href.slice(8) : href, new URL(data.file, 'https://project.invalid/'));
        removed = target.origin === 'https://project.invalid' && deadPaths.has(decodeURIComponent(target.pathname.slice(1)));
      } catch {}
    }
    if (removed) link.replaceWith(...link.childNodes);
  }
}
