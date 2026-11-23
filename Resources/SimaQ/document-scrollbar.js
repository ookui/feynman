/* A painted vertical thumb for WebKit scrollports, including the HTML reader. */
(function () {
  'use strict';
  function attach(viewport) {
    const page = viewport === document.scrollingElement || viewport === document.documentElement;
    const scrollTarget = page ? window : viewport;
    const layer = document.createElement('div'), thumb = document.createElement('div');
    layer.className = 'sima-scroll-layer';
    layer.setAttribute('aria-hidden', 'true');
    layer.append(thumb);
    (page ? document.body : viewport).prepend(layer);
    Object.assign(layer.style, {
      position: page ? 'fixed' : 'sticky', top: '0', left: '0', right: '0',
      height: '0', pointerEvents: 'none', zIndex: '2147483646'
    });
    Object.assign(thumb.style, {
      position: 'absolute', top: '0', right: '2px', width: '10px', boxSizing: 'border-box',
      border: '2px solid transparent', borderRadius: '8px', backgroundClip: 'padding-box',
      backgroundColor: 'var(--muted, #85898e)', touchAction: 'none',
      userSelect: 'none', visibility: 'hidden', pointerEvents: 'none'
    });
    let timer, drag;
    function hide() {
      thumb.style.visibility = 'hidden';
      thumb.style.pointerEvents = 'none';
    }
    function geometry() {
      const height = page ? window.innerHeight : viewport.clientHeight;
      const range = Math.max(0, viewport.scrollHeight - height);
      const track = Math.max(0, height - 4);
      const size = Math.min(track, Math.max(30, track * height / Math.max(1, height + range)));
      return {range, size, travel:track - size};
    }
    function show() {
      clearTimeout(timer);
      const {range, size, travel} = geometry();
      if (!range || !travel) { hide(); return; }
      const progress = Math.min(1, Math.max(0, viewport.scrollTop / range));
      thumb.style.height = size + 'px';
      thumb.style.transform = 'translateY(' + (2 + progress * travel) + 'px)';
      thumb.style.visibility = 'visible';
      thumb.style.pointerEvents = 'auto';
      if (!drag) timer = setTimeout(hide, 850);
    }
    thumb.onpointerdown = event => {
      if (event.button !== 0 || !event.isPrimary) return;
      event.preventDefault();
      thumb.setPointerCapture(event.pointerId);
      drag = {id:event.pointerId, y:event.clientY, top:viewport.scrollTop};
      clearTimeout(timer);
    };
    thumb.onpointermove = event => {
      if (drag?.id !== event.pointerId) return;
      const {range, travel} = geometry();
      if (travel > 0) viewport.scrollTop = drag.top + (event.clientY - drag.y) * range / travel;
    };
    thumb.onlostpointercapture = () => { drag = null; show(); };
    thumb.onclick = event => event.stopPropagation();
    scrollTarget.addEventListener('scroll', show, {passive:true});
    return () => {
      scrollTarget.removeEventListener('scroll', show);
      clearTimeout(timer);
      layer.remove();
    };
  }
  window.SimaScrollbar = {attach};
})();
