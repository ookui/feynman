// Positions are in document space. Only the camera and labels change on zoom.
(() => {
  'use strict';
  const clamp = (n, lo, hi) => Math.max(lo, Math.min(hi, n));
  function mount(panel,{tr,colorFor,open}) {
    const canvas=panel.querySelector('canvas'), ctx=canvas.getContext('2d');
    const tip=panel.querySelector('.graph-tip'), counts=panel.querySelector('.graph-counts');
    const message=panel.querySelector('.graph-message'), zoomLabel=panel.querySelector('.graph-scale');
    let graph=null, selected=null, hovered=null, drag=null, frame=0, width=0, height=0;
    let simulator, worker, busy=false, running=false, pendingMove=null, paused=false;
    let scale=1, fitScale=1, cx=0, cy=0, fitting=true;
    const sx=n=>(n.x-cx)*scale+width/2, sy=n=>(n.y-cy)*scale+height/2;
    let dotScale=1, hitCells=new Map();
    const labelWidths=new Map();
    let lastFont, labelPlan=null, interactive=false;
    const radius=n=>n.radius*dotScale;
    function drawSoon() { if(!paused && !frame) frame=requestAnimationFrame(draw); }
    function fit() {
      if(!graph || !width || !height || !graph.nodes.length) return;
      let left=Infinity,top=Infinity,right=-Infinity,bottom=-Infinity;
      for (const n of graph.nodes) {
        left=Math.min(left,n.x-n.radius); right=Math.max(right,n.x+n.radius);
        top=Math.min(top,n.y-n.radius); bottom=Math.max(bottom,n.y+n.radius);
      }
      const plotWidth=Math.max(width*.8,width-100), plotHeight=Math.max(height*.8,height-48);
      fitScale=Math.min(2,plotWidth/(right-left+20),plotHeight/(bottom-top+20));
      scale=fitScale; cx=(left+right)/2; cy=(top+bottom)/2; fitting=true;
      hideTip(); drawSoon();
    }
    function advance() {
      if (!running || busy) return;
      const pin=drag?.moved ? drag.node?.id : undefined;
      if (worker) {
        busy=true;
        worker.postMessage({move:pendingMove,pin,interactive}); pendingMove=null;
      } else {
        running=simulator.step(graph.nodes[pin],interactive);
        if (running) drawSoon();
        else { labelPlan=null; interactive=false; if (fitting) fit(); }
      }
    }
    function startSimulation(data) {
      worker?.terminate(); worker=null; busy=false; pendingMove=null;
      interactive=false; labelPlan=null; simulator=SimaGraphLayout.solver(graph);
      running=!!data.edges.length;
      if (!running || data.nodes.length<400 || typeof Worker==='undefined') return;
      // Only one batch may be in flight. Wheel and pointer events stay on the UI thread.
      const url=URL.createObjectURL(SimaGraphLayout.workerSource());
      try { worker=new Worker(url); } catch { return; }
      finally { URL.revokeObjectURL(url); }
      const current=worker;
      worker.onmessage=({data:{positions,running:more}})=>{
        if (current!==worker) return;
        const pinned=drag?.node || pendingMove;
        for (const n of graph.nodes) {
          if (n.id===pinned?.id || n.id===pendingMove?.id) continue;
          n.x=positions[n.id*2]; n.y=positions[n.id*2+1];
        }
        busy=false; running=more || !!pendingMove;
        if (!running) { labelPlan=null; interactive=false; if (fitting && !paused) fit(); }
        drawSoon();
      };
      worker.onerror=()=>{
        if (current!==worker) return;
        worker.terminate(); worker=null; busy=false;
        if (pendingMove) simulator.reheat(graph.nodes[pendingMove.id]);
        pendingMove=null; running=true; drawSoon();
      };
      busy=true; worker.postMessage({graph:data});
    }
    function resize() {
      const r=canvas.getBoundingClientRect();
      if (!r.width || !r.height) return;
      const pixelRatio=window.devicePixelRatio||1;
      const pixelsWide=Math.round(r.width*pixelRatio), pixelsHigh=Math.round(r.height*pixelRatio);
      if (r.width===width && r.height===height && canvas.width===pixelsWide && canvas.height===pixelsHigh) return;
      width=r.width; height=r.height;
      if (canvas.width!==pixelsWide) canvas.width=pixelsWide;
      if (canvas.height!==pixelsHigh) canvas.height=pixelsHigh;
      ctx.setTransform(pixelRatio,0,0,pixelRatio,0,0);
      if(fitting) fit();
      drawSoon();
    }
    function hideTip() { hovered=null; tip.hidden=true; canvas.style.cursor='grab'; }
    function zoom(factor,x=width/2,y=height/2) {
      if(!graph) return;
      const next=clamp(scale*factor,Math.min(.05,fitScale/3),Math.max(12,fitScale*6));
      cx+=(x-width/2)*(1/scale-1/next); cy+=(y-height/2)*(1/scale-1/next);
      scale=next; fitting=false; hideTip(); drawSoon();
    }
    function hit(x,y) {
      if(!graph) return null;
      let best=null, nearest=Infinity;
      const col=Math.floor(x/32), row=Math.floor(y/32);
      for(let i=col-1;i<=col+1;i++) for(let j=row-1;j<=row+1;j++) {
        for (const n of hitCells.get(i+','+j)||[]) {
          const d=Math.hypot(sx(n)-x,sy(n)-y);
          if(d<=Math.max(5,radius(n)+2) && d<nearest) { best=n; nearest=d; }
        }
      }
      return best;
    }
    function hover(x,y) {
      const node=hit(x,y);
      if(node===hovered) return;
      hovered=node; canvas.style.cursor=node?'pointer':'grab';
      if(!node) tip.hidden=true;
      else {
        tip.firstElementChild.textContent=node.title;
        tip.lastElementChild.textContent=node.path;
        tip.hidden=false;
        tip.style.left=clamp(sx(node)+12,4,width-tip.offsetWidth-4)+'px';
        tip.style.top=clamp(sy(node)+12,4,height-tip.offsetHeight-4)+'px';
      }
      drawSoon();
    }
    function draw() {
      frame=0; ctx.clearRect(0,0,width,height);
      if(!graph) return;
      advance();
      const focusNode=drag?.node || hovered || selected;
      dotScale=clamp(scale,.45,1.8);
      hitCells=new Map();
      const zoomText=Math.round(100*scale/fitScale)+'%';
      if (zoomLabel.textContent!==zoomText) zoomLabel.textContent=zoomText;
      const style=getComputedStyle(canvas), ink=style.color, accent=style.borderTopColor, edge=style.outlineColor;
      function edges(focus) {
        ctx.beginPath();
        for(const [from,to] of graph.edges) {
          if(focusNode && ((from===focusNode.id || to===focusNode.id)!==focus)) continue;
          const a=graph.nodes[from], b=graph.nodes[to];
          const ax=sx(a), ay=sy(a), bx=sx(b), by=sy(b);
          if (Math.max(ax,bx)<-25 || Math.min(ax,bx)>width+25 ||
              Math.max(ay,by)<-25 || Math.min(ay,by)>height+25) continue;
          ctx.moveTo(ax,ay); ctx.lineTo(bx,by);
          if (focus) {
            const dx=bx-ax, dy=by-ay, length=Math.hypot(dx,dy);
            if(length<=radius(a)+radius(b)+10) continue;
            const ux=dx/length, uy=dy/length, x=bx-ux*(radius(b)+2), y=by-uy*(radius(b)+2);
            ctx.moveTo(x-6*ux+3*uy,y-6*uy-3*ux); ctx.lineTo(x,y);
            ctx.lineTo(x-6*ux-3*uy,y-6*uy+3*ux);
          }
        }
        ctx.globalAlpha=focus ? .92 : focusNode ? .11 : .49;
        ctx.strokeStyle=focus?accent:edge; ctx.lineWidth=focus?1.65:1; ctx.stroke();
      }
      edges(false); if(focusNode) edges(true);
      const visible=n=>sx(n)+radius(n)>=0 && sy(n)+radius(n)>=0 && sx(n)-radius(n)<=width && sy(n)-radius(n)<=height;
      const related=n=>!focusNode || n===focusNode || focusNode.neighbors.has(n.id);
      for(const n of graph.nodes) {
        if(!visible(n)) continue;
        const cell=Math.floor(sx(n)/32)+','+Math.floor(sy(n)/32);
        if (!hitCells.has(cell)) hitCells.set(cell,[]);
        hitCells.get(cell).push(n);
        ctx.globalAlpha=related(n)?1:.17;
        ctx.fillStyle=n.color||accent;
        ctx.beginPath(); ctx.arc(sx(n),sy(n),radius(n),0,Math.PI*2); ctx.fill();
        if(n===focusNode || n===hovered) {
          ctx.strokeStyle=accent; ctx.lineWidth=1.6;
          ctx.beginPath(); ctx.arc(sx(n),sy(n),radius(n)+3.5,0,Math.PI*2); ctx.stroke();
        }
      }
      const zoomSteps=Math.log2(scale/fitScale);
      const size=clamp(10+2*Math.log2(1+fitScale)+2*zoomSteps,8,22);
      const limit=Math.max(2,Math.round(6+5*fitScale+7*zoomSteps));
      ctx.font='500 '+size+'px '+style.fontFamily; ctx.textAlign='center'; ctx.textBaseline='top';
      ctx.fillStyle=ink;
      if (ctx.font!==lastFont) { lastFont=ctx.font; labelWidths.clear(); labelPlan=null; }
      if (!labelPlan || labelPlan.scale!==scale || labelPlan.limit!==limit || labelPlan.focus!==focusNode) {
        // Collision cells move with the graph. Panning cannot change which titles win.
        // Keep this plan while positions animate, then resolve collisions at rest.
        const occupied=new Set(), labels=[];
        function reserve(n) {
          const x=n.x*scale, y=n.y*scale;
          const title=n.chars.length>limit ? n.chars.slice(0,limit).join('')+'…' : n.title;
          let half=labelWidths.get(title);
          if (half===undefined) { half=ctx.measureText(title).width/2+3; labelWidths.set(title,half); }
          const gap=radius(n)+4;
          const below=[0,gap], above=[0,-gap-size-2];
          const options=[below,above];
          if (n.component.nodes.length<=3) {
            // Put peripheral captions outside the ring and keep all text horizontal.
            if (Math.abs(n.x)>Math.abs(n.y)) options.unshift([Math.sign(n.x)*(gap+half),-size/2]);
            else if (n.y<0) options.reverse();
          }
          for (const [dx,dy] of options) {
            const keys=[];
            let free=true;
            for(let i=Math.floor((x+dx-half)/14);free && i<=Math.floor((x+dx+half)/14);i++)
              for(let j=Math.floor((y+dy-1)/12);j<=Math.floor((y+dy+size+2)/12);j++) {
                const key=i+','+j;
                if (occupied.has(key)) { free=false; break; }
                keys.push(key);
              }
            if (!free) continue;
            keys.forEach(key=>occupied.add(key));
            labels.push({n,title,half,dx,dy}); return;
          }
        }
        if (focusNode) { reserve(focusNode); for (const id of focusNode.neighbors) reserve(graph.nodes[id]); }
        for (const n of graph.order) if (!focusNode || !related(n)) reserve(n);
        labelPlan={scale,limit,focus:focusNode,labels};
      }
      for (const {n,title,half,dx,dy} of labelPlan.labels) {
        const x=sx(n)+dx, y=sy(n)+dy;
        if (x+half<0 || x-half>width || y+size<0 || y>height) continue;
        ctx.globalAlpha=related(n)?1:.20; ctx.fillText(title,x,y);
      }
      ctx.globalAlpha=1;
    }
    function point(event) {
      const rect=canvas.getBoundingClientRect();
      return [event.clientX-rect.left,event.clientY-rect.top];
    }
    canvas.oncontextmenu=e=>e.preventDefault();
    canvas.addEventListener('wheel',e=>{
      e.preventDefault();
      const dy=e.deltaY*(e.deltaMode===1?16:e.deltaMode===2?height:1);
      zoom(Math.exp(-clamp(dy,-240,240)*.003),...point(e));
    },{passive:false});
    canvas.onpointerdown=e=>{
      if(e.button!==0 && e.button!==2) return;
      const [x,y]=point(e);
      const node=e.button===0 ? hit(x,y) : null;
      drag={x,y,cx,cy,lastY:y,button:e.button,moved:false,node,nx:node?.x,ny:node?.y};
      canvas.setPointerCapture(e.pointerId);
    };
    canvas.onpointermove=e=>{
      const [x,y]=point(e);
      if(!drag) return hover(x,y);
      if(drag.button===2) {
        zoom(Math.exp((drag.lastY-y)*.009),drag.x,drag.y);
        drag.lastY=y;
        return;
      }
      if(Math.hypot(x-drag.x,y-drag.y)>3) drag.moved=true;
      if(drag.moved) {
        if (drag.node) {
          const n=drag.node;
          n.x=drag.nx+(x-drag.x)/scale; n.y=drag.ny+(y-drag.y)/scale;
          interactive=true;
          if (worker) pendingMove={id:n.id,x:n.x,y:n.y};
          else simulator.reheat(n);
          running=true;
        } else { cx=drag.cx-(x-drag.x)/scale; cy=drag.cy-(y-drag.y)/scale; }
        fitting=false; hideTip(); canvas.style.cursor='grabbing'; drawSoon();
      }
    };
    canvas.onpointerup=e=>{
      if(!drag) return;
      if(e.button===0 && !drag.moved) selected=hit(...point(e));
      drag=null; canvas.style.cursor='grab'; drawSoon();
    };
    canvas.onlostpointercapture=()=>{drag=null;};
    canvas.onpointerleave=()=>{hideTip(); drawSoon();};
    canvas.ondblclick=e=>{const node=hit(...point(e)); if(node) open(node.path);};
    panel.querySelector('[data-zoom="in"]').onclick=()=>zoom(1.35);
    panel.querySelector('[data-zoom="out"]').onclick=()=>zoom(1/1.35);
    panel.querySelector('[data-zoom="fit"]').onclick=fit;
    const observer=new ResizeObserver(resize); observer.observe(canvas);
    document.addEventListener('sima:preferences',drawSoon);
    let previous='';
    return {
      update(data) {
        const signature=JSON.stringify(data);
        if(signature===previous) return;
        const path=selected?.path;
        previous=signature; hideTip(); drag=null; graph=SimaGraphLayout.layout(data);
        startSimulation(data);
        for(const n of graph.nodes) { n.color=n.color||colorFor?.(n.path); n.chars=Array.from(n.title); }
        selected=graph.nodes.find(n=>n.path===path)||null;
        counts.textContent=graph.nodes.length+' '+tr('节点')+' · '+graph.edges.length+' '+tr('关系');
        message.hidden=!!graph.nodes.length; message.textContent=tr('没有可显示的节点');
        resize();
        if (fitting) fit();
        drawSoon();
      },
      state() { return {cx,cy,scale,fitScale,fitting,selected:selected?.path||null}; },
      restore(state) {
        if (!state || !graph) return;
        selected=graph.nodes.find(n=>n.path===state.selected)||null;
        if (state.fitting) fit();
        else { ({cx,cy,scale,fitScale}=state); fitting=false; drawSoon(); }
      },
      pause(value) {
        paused=value; drag=null; hideTip();
        if (value) { cancelAnimationFrame(frame); frame=0; }
        else { resize(); drawSoon(); }
      },
      error(text) { message.hidden=false; message.textContent=text; previous=''; },
      destroy() { paused=true; worker?.terminate(); worker=null; observer.disconnect(); cancelAnimationFrame(frame); document.removeEventListener('sima:preferences',drawSoon); }
    };
  }
  window.SimaGraph={mount};
})();
