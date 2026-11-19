'use strict';

// Marked retains the spelling of reference links, titles and escaped destinations.
const imageSources = new WeakMap();
function tagImageSource(html,raw) {
  const escaped = raw.replaceAll('&','&amp;').replaceAll('"','&quot;').replaceAll('<','&lt;');
  return html.replace(/<img\b/i, () => '<img data-image-markdown="' + escaped + '"');
}
marked.use({renderer:{
  image(token) { return tagImageSource(marked.Renderer.prototype.image.call(this,token),token.raw); },
  html(token) {
    // Preserve original quotes, attributes and spacing when the source uses HTML.
    const html = marked.Renderer.prototype.html.call(this,token);
    const image = /^\s*(<img\b(?:[^>"']|"[^"]*"|'[^']*')*>)\s*$/i.exec(html);
    return image ? tagImageSource(html,image[1]) : html;
  }
}});

let selectedImage = null;
const imageLine = document.querySelector('#image-source');
function imageBookmark(image = selectedImage, fromEnd = false) {
  if (!image || !article.contains(image)) return null;
  const images = [...article.querySelectorAll('img')];
  return {index:images.indexOf(image) - (fromEnd ? images.length : 0), raw:imageSources.get(image), src:image.src};
}
function restoreImageSelection(bookmark, keepInput = false) {
  const image = [...article.querySelectorAll('img')].at(bookmark.index);
  if (!image || image.src !== bookmark.src || imageSources.get(image) !== bookmark.raw) return null;
  selectImage(image,keepInput);
  return image;
}
// A recreated image has no intrinsic size until WebKit delivers its load event.
// Reserve the known size so rebuilding a long note cannot clamp its scroll position.
function preserveImageSizes(content) {
  const sizes = new Map();
  for (const image of article.querySelectorAll('img[src]')) {
    if (image.naturalWidth) sizes.set(image.src,[image.naturalWidth,image.naturalHeight]);
    else if (image.hasAttribute('width')) sizes.set(image.src,[Number(image.getAttribute('width')),Number(image.getAttribute('height'))]);
  }
  for (const image of content.querySelectorAll('img[src]')) {
    const size = sizes.get(image.src);
    if (!size) continue;
    [image.width,image.height] = size;
    const release = () => {
      image.removeAttribute('width');
      image.removeAttribute('height');
    };
    image.addEventListener('load',release,{once:true});
    image.addEventListener('error',release,{once:true});
  }
}
function positionImageLine() {
  if (!selectedImage?.isConnected) { clearImageSelection(); return; }
  const rect = selectedImage.getBoundingClientRect();
  const articleRect = article.getBoundingClientRect();
  const left = Math.max(2,Math.min(rect.left,innerWidth-80));
  imageLine.style.left = left + 'px';
  imageLine.style.maxWidth = Math.max(60,Math.min(innerWidth-2,articleRect.right)-left) + 'px';
  imageLine.style.top = Math.max(0,rect.top-imageLine.offsetHeight) + 'px';
  imageLine.style.visibility = rect.bottom > 0 && rect.top < innerHeight ? 'visible' : 'hidden';
}
const imageResize = new ResizeObserver(() => { if (selectedImage) positionImageLine(); });
function clearImageSelection() {
  selectedImage?.classList.remove('selected-image');
  selectedImage = null;
  imageResize.disconnect();
  imageLine.hidden = true;
}
function selectImage(image, keepInput = false) {
  if (image === selectedImage) return;
  selectedImage?.classList.remove('selected-image');
  imageResize.disconnect();
  selectedImage = image;
  image.classList.add('selected-image');
  if (!keepInput) imageLine.value = imageSources.get(image) || image.alt;
  imageLine.readOnly = !imageSourceRange(image);
  imageLine.style.width = (imageLine.value.length + 2) + 'ch';
  imageLine.hidden = false;
  imageResize.observe(image);
  imageResize.observe(article);
  positionImageLine();
}
function imageForGesture(event) {
  let image = event.target.closest('img');
  if (!image || !article.contains(image)) return null;
  event.preventDefault();
  event.stopImmediatePropagation();
  clearTimeout(editTimer);
  getSelection().removeAllRanges();
  if (pendingClick?.file === file && !pendingClick.target?.deletion) pendingClick.target = {cancelForImage:true};
  if (activeBlock) {
    const previousTop = image.getBoundingClientRect().top;
    const fromEnd = !!(activeBlock.holder.compareDocumentPosition(image) & Node.DOCUMENT_POSITION_FOLLOWING);
    const bookmark = imageBookmark(image,fromEnd);
    closeBlock();
    image = restoreImageSelection(bookmark);
    if (image) scrollBy(0,image.getBoundingClientRect().top-previousTop);
  } else selectImage(image);
  return image;
}
// Probe the rendered block to distinguish duplicate references and Markdown
// examples in code spans. Only offer text mutations for a verified source range.
function imageSourceRange(image) {
  if (!state.editable || image.closest('details')) return null;
  let block = image;
  while (block && !sourceBlocks.has(block)) block = block.parentElement;
  if (!block) return null;
  const {start,end} = sourceBlocks.get(block), source = state.body.slice(start,end);
  const raw = imageSources.get(image);
  if (!raw) return null;
  const ordinal = block === image ? 0 : [...block.querySelectorAll('img')].indexOf(image);
  const marker = 'feynman-probe-' + crypto.randomUUID();
  for (let at = source.indexOf(raw); at >= 0; at = source.indexOf(raw,at+raw.length)) {
    const lexer = new marked.Lexer();
    lexer.tokens.links = {...documentLinks};
    const placeholder = raw.startsWith('<') ? '<img src="'+marker+'">' : '![]('+marker+')';
    const tokens = lexer.lex(source.slice(0,at)+placeholder+source.slice(at+raw.length));
    const probe = document.createElement('template');
    probe.innerHTML = marked.Parser.parse(tokens);
    if (probe.content.querySelectorAll('img')[ordinal]?.getAttribute('src') === marker) return {start:start+at,raw};
  }
  return null;
}
// An image click selects the figure. Only a click in the source field takes text focus.
imageLine.addEventListener('keydown',event => {
  if (event.isComposing || event.keyCode === 229 || event.key !== 'Enter') return;
  event.preventDefault();
  event.stopPropagation();
  if (imageLine.readOnly || !selectedImage) return;
  const range = imageSourceRange(selectedImage), value = imageLine.value.trim();
  if (!range) { tell('正文已更新，请重新选择图片。'); return; }
  if (value === range.raw) { imageLine.blur(); return; }
  const lexer = new marked.Lexer();
  lexer.tokens.links = {...documentLinks};
  const fragment = sanitize(marked.Parser.parseInline(lexer.inlineTokens(value)));
  if (fragment.childNodes.length !== 1 || !fragment.firstChild.matches?.('img[src]') ||
      imageSources.get(fragment.firstChild) !== value) {
    tell('请输入完整的图片引用，例如 ![图片说明](assets/image.png)。');
    return;
  }
  const step = {start:range.start,removed:range.raw,value,restoreCaret:range.start,caret:range.start,
    imageIndex:imageBookmark().index};
  if (state.editID && !activeBlock) recordBlockSplice(step);
  else commitRange(step);
});
document.addEventListener('pointerdown',event => {
  if (event.target.closest('#doc img')) event.stopPropagation();
},true);
document.addEventListener('mousedown',event => {
  if (event.target === imageLine) return;
  if (!event.target.closest('#doc img')) { clearImageSelection(); return; }
  if (event.button === 0 || event.button === 2) imageForGesture(event);
},true);
document.addEventListener('click',event => { imageForGesture(event); },true);
document.addEventListener('dblclick',event => {
  const image = imageForGesture(event);
  if (image?.getAttribute('src')) send({action:'previewImage', src:image.src, title:image.alt});
},true);
document.addEventListener('contextmenu',event => {
  const image = imageForGesture(event);
  if (!image) return;
  const range = imageSourceRange(image);
  send({action:'imageMenu',src:image.getAttribute('src') || '',title:image.alt,raw:imageSources.get(image),
    start:range?.start ?? null,body:state.body,x:event.clientX,y:event.clientY});
},true);
window.addEventListener('resize',() => { if (selectedImage) positionImageLine(); });
document.addEventListener('scroll',() => { if (selectedImage) positionImageLine(); },true);
document.addEventListener('keydown',event => {
  if (event.key === 'Escape' && selectedImage && !event.isComposing && event.keyCode !== 229) { clearImageSelection(); event.preventDefault(); }
});

function replaceSelectedImage(fileName,body,start,raw,value) {
  if (file !== fileName || body !== state.body || !selectedImage ||
      imageSources.get(selectedImage) !== raw || imageSourceRange(selectedImage)?.start !== start) {
    tell('正文已更新，请重新选择图片。');
    return;
  }
  clearImageSelection();
  commitRange({start,removed:raw,value,restoreCaret:start,caret:start+value.length});
}
