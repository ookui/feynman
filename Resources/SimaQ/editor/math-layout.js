// Each editor owns a formula plan. SVG output is reusable only when the compiled
// MathML (including resolved labels, numbers and macros) still matches.
(function (global) {
  'use strict';
  let queue = Promise.resolve(), scopeSerial = 0;
  const blocked = /\\(?:href|url|html|class|style|cssId|require|unicode)\b/i;
  const simpleCommands = new Set('frac sqrt sum prod int alpha beta gamma delta sigma pi theta mu infty le ge times cdot left right mathbb mathfrak mathcal mathrm mathbf text'.split(' '));
  const signature = entry => JSON.stringify([entry.display,entry.tex]);
  const sourceOf = node => ({tex:node.dataset.tex,display:node.dataset.display==='1'});

  async function layout(entries,previous,current) {
    async function reuse(key,render) {
      const node=current.get(key) || previous.get(key) || await render();
      current.set(key,node);
      return node;
    }
    const mj=global.MathJax;
    await mj.startup.promise;
    const standalone=entries.every(({tex})=>!tex.includes('%') && !tex.includes('^^') &&
      Array.from(tex.matchAll(/\\([a-zA-Z]+|.)/gs),m=>m[1])
        .every(name=>simpleCommands.has(name) || ('{},;! $%_#&'.includes(name) && name.length===1)));
    if (standalone) {
      const result=[];
      for (const entry of entries) {
        const key=signature(entry);
        result.push(await reuse(key,()=>mj.tex2svgPromise(entry.tex,{display:entry.display})));
      }
      return result;
    }

    // The document compile pass resolves forward references before producing SVG.
    // Fresh TeX input isolates labels, counters and user macros across tabs and exports.
    const startup=mj.startup;
    const output=new startup.constructors.svg({...mj.config.svg,fontData:startup.output.font});
    const doc=startup.mathjax.document(global.document,{InputJax:startup.getInputJax(),OutputJax:output});
    const beforeInsertion=mj._.core.MathItem.STATE.INSERTED-1;
    for (const {tex,display} of entries) {
      const item=new doc.options.MathItem(tex,doc.inputJax[0],display);
      item.start.node=global.document.body;
      item.setMetrics(16,8,640,1);
      doc.math.push(item);
    }
    await startup.mathjax.handleRetriesFor(()=>doc.compile());
    const result=[];
    for (const item of doc.math) {
      const key=startup.toMML(item.root);
      result.push(await reuse(key,async()=>{
        await startup.mathjax.handleRetriesFor(()=>item.convert(doc,beforeInsertion));
        return item.typesetRoot;
      }));
    }
    return result;
  }

  function createPlan() {
    let cache=new Map();
    let lastKey, lastJob;
    return entries=>{
      const key=JSON.stringify(entries.map(signature));
      if (key!==lastKey) {
        lastKey=key;
        const job=queue.then(async()=>{
          const current=new Map();
          const outputs=await layout(entries,cache,current);
          cache=current;
          return outputs;
        });
        lastJob=job;
        queue=job.catch(()=>{if (lastJob===job) lastKey=undefined;});
      }
      return lastJob;
    };
  }

  function insert(node,result,scope) {
    const output=result.cloneNode(true);
    if (scope) {
      for (const el of output.querySelectorAll('[id]')) el.id=scope+el.id;
      for (const a of output.querySelectorAll('a')) {
        const href=a.getAttribute('href') || a.getAttribute('xlink:href');
        if (!href?.startsWith('#') || href.length<2) continue;
        const target=scope+decodeURIComponent(href.slice(1));
        a.setAttribute('href','#'+encodeURIComponent(target));
        if (a.hasAttribute('xlink:href')) a.setAttributeNS('http://www.w3.org/1999/xlink','xlink:href','#'+encodeURIComponent(target));
        a.dataset.mathTarget=target;
      }
    }
    node.replaceChildren(output);
  }

  function preview(root,getBlocks) {
    const plan=createPlan(), scope='sima-math-'+(++scopeSerial)+'-';
    const applied=new WeakMap();
    let timer, revision=0;
    function schedule(delay=0,afterRender) {
      const current=++revision;
      clearTimeout(timer);
      timer=setTimeout(async()=>{
        const nodes=[...root.querySelectorAll('.sima-tex')];
        if (!nodes.length) return;
        const entries=[], byBlock=new Map();
        for (const block of getBlocks()) {
          const positions=new Map();
          for (const entry of block.formulas || []) {
            if (blocked.test(entry.tex)) continue;
            const key=signature(entry);
            if (!positions.has(key)) positions.set(key,[]);
            positions.get(key).push(entries.length);
            entries.push(entry);
          }
          byBlock.set(block.start,positions);
        }
        const outputs=await plan(entries).catch(()=>null);
        if (!outputs || revision!==current) return;
        for (const node of nodes) {
          const block=node.closest('.sima-block');
          const index=byBlock.get(Number(block?.dataset.start))?.get(signature(sourceOf(node)))?.shift();
          const result=outputs[index];
          if (result && applied.get(node)!==result) {
            insert(node,result,scope);
            applied.set(node,result);
          }
        }
        afterRender?.();
      },delay);
    }
    return {schedule,destroy(){revision++;clearTimeout(timer);}};
  }

  async function exportDocument(doc) {
    const nodes=[...doc.querySelectorAll('.sima-tex')];
    if (!nodes.length) return;
    const outputs=await createPlan()(nodes.map(sourceOf));
    nodes.forEach((node,i)=>node.replaceWith(outputs[i].cloneNode(true)));
    const style=doc.createElement('style');
    const sheet=global.MathJax.svgStylesheet();
    style.textContent=sheet.sheet ? Array.from(sheet.sheet.cssRules,r=>r.cssText).join('\n') : sheet.textContent;
    doc.head.append(style);
  }
  global.SimaMath={preview,exportDocument};
})(globalThis);
