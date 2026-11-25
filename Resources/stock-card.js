'use strict';
const article = document.querySelector('#doc');
const imageSources = new WeakMap();
const post = message => window.webkit.messageHandlers.reader.postMessage(message);
function renderCard(sections) {
  const content = document.createDocumentFragment();
  for (const section of sections) {
    const element = document.createElement('section');
    element.dataset.file = section.path;
    const text = (tag, value, style) => {
      const node = document.createElement(tag);
      node.textContent = value;
      node.className = style;
      element.append(node);
      return node;
    };
    if (section.title) text('h3', section.title, 'card-title');
    if (section.workbook) text('button', section.workbook, 'workbook').onclick = () => post({action:'model'});
    for (const line of section.lines) text('p', line, 'card-line');
    if (section.markdown) element.append(sanitize(marked.parse(section.markdown), section.path));
    content.append(element);
  }
  article.replaceChildren(content);
}
article.addEventListener('click', event => {
  const link = event.target.closest('a[href]');
  if (!link) return;
  event.preventDefault();
  post({action:'link', file:link.closest('section').dataset.file, href:link.getAttribute('href')});
});
new ResizeObserver(() => post({action:'height', height:article.getBoundingClientRect().height})).observe(article);
// Hand the vertical gesture to the dashboard when the card has reached an edge.
addEventListener('wheel', event => {
  if (event.ctrlKey || event.metaKey || Math.abs(event.deltaX) > Math.abs(event.deltaY)) return;
  const delta = event.deltaY * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? innerHeight : 1);
  const page = document.scrollingElement;
  if ((delta < 0 && page.scrollTop <= 1) || (delta > 0 && page.scrollTop + page.clientHeight >= page.scrollHeight - 1)) {
    event.preventDefault();
    post({action:'pageScroll', delta});
  }
}, {passive:false});
