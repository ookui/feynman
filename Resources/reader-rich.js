// Keep the reader's source spans and citation controls while rendering extended Markdown.
const richPreviewAssets = new Map();
function loadPreviewAsset(path) {
  if (!richPreviewAssets.has(path)) {
    richPreviewAssets.set(path, new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = 'SimaQ/editor/' + path;
      script.onload = resolve;
      script.onerror = () => { richPreviewAssets.delete(path); script.remove(); reject(new Error(path)); };
      document.head.append(script);
    }));
  }
  return richPreviewAssets.get(path);
}
let readerMath, currentRichBlocks = [];
function richReaderBlocks(text) {
  if (!/\$|\\\(|\\\[|==|\[toc\]|(?:`{3,}|~{3,})(?:mermaid|math)/i.test(text)) {
    currentRichBlocks = [];
    return new Map();
  }
  currentRichBlocks = SimaRender.parse(text);
  return new Map(currentRichBlocks.map(b => [b.start,b]));
}
function enrichReaderBlock(content, block, raw) {
  if (!block || raw.trimEnd() !== block.source.trimEnd()) return;
  const formula = !!block.formulas?.length;
  const diagram = /^(?:`{3,}|~{3,})mermaid\s*$/im.test(raw);
  if (!formula && !diagram && !/==[^=]|^\s*\[toc\]\s*$/i.test(raw)) return;

  const enhanced = document.createElement('template');
  enhanced.innerHTML = SimaRender.renderBlock(block);
  // Reuse the actual image elements already bound to Feynman's native file and source actions.
  const before = content.querySelectorAll('img'), after = enhanced.content.querySelectorAll('img');
  if (before.length !== after.length) return;
  after.forEach((image, i) => image.replaceWith(before[i]));
  const old = enhanced.content.firstElementChild;
  if (!old) return;
  if (diagram) {
    const holder = document.createElement('div');
    old.replaceWith(holder);
    holder.append(old);
    // The holder remains the editable source target when Mermaid replaces its <pre>.
    loadPreviewAsset('vendor/mermaid.min.js').then(() => SimaRender.enhanceDiagrams(holder)).catch(()=>{});
  }
  const element = enhanced.content.firstElementChild;
  if (formula) {
    element.classList.add('sima-block');
    element.dataset.start = block.start;
  }
  content.replaceChildren(enhanced.content);
}
async function typesetReaderMath(article) {
  if (!article.querySelector('.sima-tex')) return;
  try {
    await loadPreviewAsset('vendor/stix/ranges.js');
    await loadPreviewAsset('math-config.js');
    await loadPreviewAsset('vendor/mathjax-tex-svg.js');
    await loadPreviewAsset('math-layout.js');
    readerMath ??= SimaMath.preview(article, () => currentRichBlocks);
    readerMath.schedule();
  } catch { /* The formula's TeX source stays visible if its renderer cannot load. */ }
}
