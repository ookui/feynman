(function () {
  'use strict';
  const el = (tag, cls, text) => Object.assign(document.createElement(tag), {className:cls, textContent:text ?? ''});
  const label = text => window.SimaSettings?.menuText(text) ?? text;
  function graphicControls(body, picture, status, button, on, clickZoom = false) {
    let zoom = 1, fitting = !clickZoom, width = 0, height = 0;
    const fitScale = () => Math.min((body.clientWidth - 24) / width, (body.clientHeight - 24) / height);
    function nextClickZoom() {
      const fit = fitScale();
      const small = Math.min(1, fit);
      if (zoom > small * (1 + 1e-9)) return small;
      return fit < 1 ? 1 : 2;
    }
    function layout() {
      if (!width || !height || body.clientWidth <= 24 || body.clientHeight <= 24) return;
      if (fitting) zoom = fitScale();
      picture.style.width = Math.max(1, width * zoom) + 'px';
      picture.style.height = Math.max(1, height * zoom) + 'px';
      if (clickZoom) picture.dataset.zoomCursor = nextClickZoom() < zoom ? 'out' : 'in';
      status.textContent = Math.round(zoom * 100) + '% · ' + width + ' × ' + height;
    }
    function scale(factor, clientX, clientY) {
      if (!width || !height) return;
      const bounds = body.getBoundingClientRect(), before = picture.getBoundingClientRect();
      const x = clientX ?? bounds.left + body.clientWidth / 2;
      const y = clientY ?? bounds.top + body.clientHeight / 2;
      const cx = (x - before.left) / zoom, cy = (y - before.top) / zoom;
      fitting = false;
      zoom = Math.min(Math.max(16, fitScale() * 16), Math.max(Math.min(.05, fitScale()), zoom * factor)); layout();
      const after = picture.getBoundingClientRect();
      body.scrollLeft += after.left + cx * zoom - x;
      body.scrollTop += after.top + cy * zoom - y;
    }
    button('−', () => scale(1 / 1.25));
    button('+', () => scale(1.25));
    button('适合窗口', () => { fitting = true; layout(); body.scrollTo(0,0); });
    button('100%', () => { fitting = false; zoom = 1; layout(); });
    on(body, 'wheel', e => {
      if (!e.metaKey) return;
      e.preventDefault();
      if (e.deltaY) scale(e.deltaY < 0 ? 1.1 : 1 / 1.1, e.clientX, e.clientY);
    });
    picture.draggable = false;
    let drag = null, moved = false;
    on(picture, 'pointerdown', e => {
      if (e.button !== 0 || e.ctrlKey || drag) return;
      moved = false;
      if (!clickZoom && body.scrollWidth <= body.clientWidth && body.scrollHeight <= body.clientHeight) return;
      drag = {id:e.pointerId, x:e.clientX, y:e.clientY, left:body.scrollLeft, top:body.scrollTop};
      picture.setPointerCapture(e.pointerId);
      picture.classList.add('dragging');
      e.preventDefault();
    });
    on(picture, 'pointermove', e => {
      if (drag?.id !== e.pointerId) return;
      if (Math.hypot(e.clientX - drag.x, e.clientY - drag.y) >= 3) moved = true;
      if (moved) body.scrollTo(drag.left + drag.x - e.clientX, drag.top + drag.y - e.clientY);
    });
    function endDrag(e) {
      if (drag?.id !== e.pointerId) return;
      drag = null;
      picture.classList.remove('dragging');
      if (picture.hasPointerCapture(e.pointerId)) picture.releasePointerCapture(e.pointerId);
    }
    for (const event of ['pointerup', 'pointercancel', 'lostpointercapture']) on(picture, event, endDrag);
    if (clickZoom) on(picture, 'click', e => {
      if (e.button !== 0 || e.ctrlKey || moved) return;
      const targetZoom = nextClickZoom();
      if (targetZoom < 1) {
        fitting = true;
        layout();
        body.scrollTo(0, 0);
      } else {
        scale(targetZoom / zoom, e.clientX, e.clientY);
      }
    });
    let gestureScale = 1;
    on(body, 'gesturestart', e => { e.preventDefault(); gestureScale = 1; });
    on(body, 'gesturechange', e => {
      e.preventDefault();
      if (e.scale > 0) { scale(e.scale / gestureScale, e.clientX, e.clientY); gestureScale = e.scale; }
    });
    on(body, 'gestureend', e => e.preventDefault());
    return {
      layout,
      hasSize() { return width > 0 && height > 0; },
      setSize(w, h) { width = w; height = h; layout(); },
      state() { return {zoom, fitting}; },
      restore(state) { zoom = state.zoom; fitting = state.fitting; layout(); },
      fit() { fitting = true; layout(); body.scrollTo(0, 0); }
    };
  }
  function mount(viewport, options) {
    const kind = options.path.split('.').pop().toLowerCase();
    if (!['svg','json','csv'].includes(kind)) return null;
    const events = new AbortController();
    const on = (node, event, fn) => node.addEventListener(event, fn, {signal:events.signal});
    const panel = el('details', 'sima-file-preview');
    panel.open = true;
    const summary = el('summary', '', kind.toUpperCase() + ' ' + label('预览'));
    const toolbar = el('div', 'sima-file-tools');
    const status = el('span', 'sima-file-status');
    status.setAttribute('role', 'status');
    const body = el('div', 'sima-file-body');
    panel.append(summary, toolbar, body);
    viewport.prepend(panel);
    function button(title, action) {
      const node = el('button', '', label(title)); node.type = 'button';
      on(node, 'click', action); toolbar.append(node); return node;
    }
    let timer, blobURL, destroyed = false, lastText, revision = 0, resize;
    let update, closeForeground;
    if (kind === 'svg') {
      body.classList.add('sima-graphic-body');
      const picture = el('img', 'sima-graphic-image');
      picture.alt = options.path;
      body.append(picture);
      let sourceSize;
      const controls = graphicControls(body, picture, status, button, on);
      const dialog = el('dialog', 'sima-graphic-dialog');
      dialog.setAttribute('aria-label', options.path);
      const header = el('div', 'sima-graphic-heading');
      const title = el('strong', '', options.path.split('/').pop());
      const close = el('button', '', label('关闭') + ' · Esc'); close.type = 'button';
      const hint = el('span', 'sima-graphic-hint', label('滚轮滚动 · ⌘ + 滚轮缩放 · 拖动平移 · Esc 返回'));
      header.append(title, close); dialog.append(header, hint); panel.append(dialog);
      body.title = label('双击放大预览');
      body.tabIndex = 0;
      let inlineState;
      closeForeground = () => {
        if (!inlineState) return;
        const saved = inlineState; inlineState = null;
        dialog.close();
        panel.insertBefore(toolbar, dialog); panel.insertBefore(body, dialog);
        controls.restore(saved);
        body.scrollTo(saved.left, saved.top);
        viewport.scrollTop = saved.viewportTop;
        if (!destroyed) saved.focus?.focus({preventScroll:true});
      };
      function foreground() {
        if (dialog.open || picture.hidden || !controls.hasSize()) return;
        inlineState = {...controls.state(), left:body.scrollLeft, top:body.scrollTop,
          viewportTop:viewport.scrollTop, focus:document.activeElement};
        dialog.append(toolbar, body); dialog.showModal();
        controls.fit(); close.focus({preventScroll:true});
      }
      on(body, 'dblclick', e => { e.preventDefault(); e.stopPropagation(); foreground(); });
      on(body, 'keydown', e => { if (e.key === 'Enter' && !dialog.open) { e.preventDefault(); foreground(); } });
      on(close, 'click', closeForeground);
      on(document, 'sima:modal-opening', closeForeground);
      on(dialog, 'cancel', e => { e.preventDefault(); closeForeground(); });
      on(dialog, 'keydown', e => {
        e.stopPropagation();
        if (e.key === 'Escape') { e.preventDefault(); closeForeground(); }
      });
      on(picture, 'load', () => {
        picture.hidden = false;
        controls.setSize(sourceSize?.width || picture.naturalWidth, sourceSize?.height || picture.naturalHeight);
      });
      on(picture, 'error', () => { picture.hidden = true; status.textContent = label('预览失败，请检查源文件。'); });
      resize = new ResizeObserver(controls.layout); resize.observe(body);
      update = () => {
        const source = options.getText();
        const parsed = new DOMParser().parseFromString(source, 'image/svg+xml');
        if (parsed.querySelector('parsererror') || parsed.documentElement.localName !== 'svg') {
          picture.hidden = true; status.textContent = label('预览失败，请检查源文件。'); return;
        }
        // A viewBox-only SVG gets an arbitrary small intrinsic size in WebKit.
        // Use its coordinate dimensions for the preview's 100% reference size.
        const root = parsed.documentElement, viewBox = root.viewBox?.baseVal;
        function absoluteLength(name) {
          const raw = root.getAttribute(name)?.trim();
          if (!raw || !/^(?:\d*\.)?\d+(?:e[+-]?\d+)?(?:px|pt|pc|mm|cm|in|q)?$/i.test(raw)) return 0;
          const value = root[name]?.baseVal?.value;
          return Number.isFinite(value) && value > 0 ? value : 0;
        }
        const w = absoluteLength('width'), h = absoluteLength('height');
        sourceSize = null;
        if (w && h) sourceSize = {width:w, height:h};
        else if (viewBox?.width > 0 && viewBox?.height > 0) {
          const ratio = viewBox.width / viewBox.height;
          sourceSize = {width:w || (h ? h * ratio : viewBox.width), height:h || (w ? w / ratio : viewBox.height)};
        }
        const previous = blobURL;
        blobURL = URL.createObjectURL(new Blob([source], {type:'image/svg+xml;charset=utf-8'}));
        picture.src = blobURL;
        if (previous) URL.revokeObjectURL(previous);
      };
    } else {
      button('编辑源文件', () => options.locate(0));
      let format;
      if (kind === 'json') format = button('格式化 JSON', () => {
        try { options.replace(window.SimaFileData.formatJSON(options.getText())); }
        catch (error) { status.textContent = error.message; }
      });
      function jump(node) { options.locate(node.start, node.end - node.start); }
      function jsonNode(key, node, depth, token) {
        const title = key === null ? '' : key + ': ';
        if (!node.children) {
          const leaf = el('button', 'sima-json-leaf sima-json-' + node.type, title + node.raw);
          leaf.type = 'button'; leaf.onclick = () => { if (token === revision) jump(node); };
          return leaf;
        }
        const entry = el('details', 'sima-json-branch');
        const heading = el('summary', '', title + (node.type === 'array' ? '[ ' : '{ ') + node.children.length + (node.type === 'array' ? ' ]' : ' }'));
        const children = el('div', 'sima-json-children');
        entry.append(heading, children);
        let count = 0;
        const more = el('button', '', label('显示更多')); more.type = 'button';
        function append() {
          if (token !== revision) return;
          more.remove();
          const end = Math.min(count + 100, node.children.length);
          while (count < end) {
            const child = node.children[count++];
            children.append(jsonNode(child.key, child.node, depth + 1, token));
          }
          if (count < node.children.length) children.append(more);
        }
        more.onclick = append;
        entry.ontoggle = () => { if (entry.open && !count) append(); };
        if (depth < 2) { entry.open = true; append(); }
        return entry;
      }
      update = () => {
        const source = options.getText();
        revision++;
        const token = revision;
        body.replaceChildren();
        try {
          if (kind === 'json') {
            const {root} = window.SimaFileData.json(source);
            body.append(jsonNode(null, root, 0, token));
            format.disabled = false; status.textContent = '';
          } else {
            const rows = window.SimaFileData.csv(source);
            const table = el('table', 'sima-csv-table'), tbody = el('tbody', '');
            table.append(tbody); body.append(table);
            let count = 0;
            const more = el('button', '', label('显示更多')); more.type = 'button';
            function append() {
              if (token !== revision) return;
              more.remove();
              const end = Math.min(count + 200, rows.length);
              while (count < end) {
                const row = rows[count++], tr = el('tr', '');
                const index = el('th', '', String(count)); index.scope = 'row'; tr.append(index);
                for (const cell of row) {
                  const td = el('td', '');
                  const link = el('button', '', cell.value || '\u00a0');
                  link.type = 'button';
                  link.onclick = () => { if (token === revision) jump(cell); };
                  td.append(link); tr.append(td);
                }
                tbody.append(tr);
              }
              if (count < rows.length) body.append(more);
              status.textContent = count + ' / ' + rows.length + ' ' + label('行');
            }
            more.onclick = append; append();
          }
        } catch (error) {
          if (format) format.disabled = true;
          status.textContent = label('预览失败，请检查源文件。') + ' ' + error.message;
        }
      };
    }
    toolbar.append(status);
    function render() {
      if (destroyed || !panel.open) return;
      const source = options.getText();
      if (source === lastText) return;
      lastText = source; update();
    }
    on(panel, 'toggle', render);
    render();
    return {
      refresh() { clearTimeout(timer); timer = setTimeout(render, 180); },
      destroy() { destroyed = true; clearTimeout(timer); resize?.disconnect(); closeForeground?.(); events.abort(); if (blobURL) URL.revokeObjectURL(blobURL); panel.remove(); }
    };
  }
  function previewImage(parent, original, onClose) {
    const dialog = el('dialog', 'sima-graphic-dialog');
    const header = el('div', 'sima-graphic-heading');
    const title = original.alt || label('预览');
    dialog.setAttribute('aria-label', title);
    const closeButton = el('button', '', label('关闭') + ' · Esc');
    header.append(el('strong', '', title), closeButton);
    const toolbar = el('div', 'sima-file-tools'), status = el('span', 'sima-file-status');
    const body = el('div', 'sima-file-body sima-graphic-body');
    const picture = el('img', 'sima-graphic-image');
    picture.alt = original.alt;
    body.append(picture);
    dialog.append(header, toolbar, body);
    parent.append(dialog);
    const on = (node, event, fn) => node.addEventListener(event, fn);
    function button(title, action) {
      const b = el('button', '', label(title));
      b.type = 'button'; b.onclick = action; toolbar.append(b);
    }
    const controls = graphicControls(body, picture, status, button, on, true);
    toolbar.append(status);
    const observer = new ResizeObserver(controls.layout);
    observer.observe(body);
    function close() {
      if (!dialog.open) return;
      observer.disconnect();
      document.removeEventListener('sima:modal-opening', close);
      dialog.close(); dialog.remove(); onClose();
    }
    dialog.oncancel = e => { e.preventDefault(); close(); };
    dialog.onkeydown = e => {
      e.stopPropagation();
      if (e.key === 'Escape') { e.preventDefault(); close(); }
    };
    closeButton.onclick = close;
    document.addEventListener('sima:modal-opening', close);
    picture.onload = () => {
      const rect = original.getBoundingClientRect();
      const width = picture.naturalWidth || rect.width;
      // A viewBox-only SVG may have a synthetic intrinsic size in WebKit.
      const height = original.closest('.sima-fluid-svg') && rect.width > 0
        ? width * rect.height / rect.width : picture.naturalHeight || rect.height;
      controls.setSize(width, height);
    };
    dialog.showModal();
    picture.src = original.currentSrc || original.src;
    closeButton.focus({preventScroll:true});
    return close;
  }
  window.SimaFilePreview = {mount, previewImage};
})();
