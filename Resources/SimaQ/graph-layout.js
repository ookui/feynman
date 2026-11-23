// File order is stable. Keep neighboring subtrees close in the initial drawing, then
// refine connected components with springs and Barnes–Hut repulsion.
(function installGraphLayout(global) {
  'use strict';
  function hilbert(index, side) {
    let x=0, y=0;
    for (let step=1; step<side; step*=2) {
      const rx=(index>>1)&1, ry=(index^rx)&1;
      if (!ry) {
        if (rx) { x=step-1-x; y=step-1-y; }
        [x,y]=[y,x];
      }
      x+=step*rx; y+=step*ry; index=Math.floor(index/4);
    }
    return [x,y];
  }

  // A bounded modularity pass groups densely cross-linked notes before the first
  // frame. Links in either direction contribute to proximity.
  function orderCommunities(group,nodes) {
    const points=group.nodes;
    if (points.length<24) return;
    const volume=new Map();
    let total=0;
    for (const n of points) {
      n.cluster=n.id; volume.set(n.id,n.neighbors.size); total+=n.neighbors.size;
    }
    for (let pass=0;pass<6;pass++) {
      let changed=false;
      for (const n of points) {
        const counts=new Map(), degree=n.neighbors.size, prev=n.cluster;
        volume.set(prev,volume.get(prev)-degree);
        for (const id of n.neighbors) {
          const cluster=nodes[id].cluster;
          counts.set(cluster,(counts.get(cluster)||0)+1);
        }
        let best=prev, score=(counts.get(prev)||0)-degree*volume.get(prev)/total;
        for (const [cluster,count] of counts) {
          const gain=count-degree*volume.get(cluster)/total;
          if (gain>score+1e-9) { score=gain; best=cluster; }
        }
        n.cluster=best; volume.set(best,volume.get(best)+degree);
        if (best!==prev) changed=true;
      }
      if (!changed) break;
    }
    const groups=new Map();
    for (const n of points) {
      if (!groups.has(n.cluster)) groups.set(n.cluster,[]);
      groups.get(n.cluster).push(n);
    }
    group.nodes=Array.from(groups.values()).flat();
  }

  const fullTurn=2*Math.PI;
  const goldenAngle=Math.PI*(3-Math.sqrt(5));

  function seedComponent(group,nodes) {
    const points=group.nodes;
    const body=points.length>3 ? points.filter(n=>n.neighbors.size>1) : points;
    const side=2**Math.ceil(Math.log2(body.length)/2);
    let mx=0,my=0;
    for (const [index,n] of body.entries()) {
      const [x,y]=hilbert(index,side);
      n.x=x*65; n.y=y*65; mx+=n.x; my+=n.y;
    }
    mx/=body.length; my/=body.length;
    if (body.length!==points.length) for (const parent of body) {
      const leaves=[];
      for (const id of parent.neighbors) if (nodes[id].neighbors.size===1) leaves.push(nodes[id]);
      const bearing=parent.x===mx && parent.y===my ? parent.id*goldenAngle : Math.atan2(parent.y-my,parent.x-mx);
      // A sparse branch fans outwards. A large index spreads its leaves over rings.
      let first=0,ring=0;
      while (first<leaves.length) {
        const distance=85+ring*56, span=leaves.length<=5 ? Math.PI*.9 : fullTurn;
        const count=Math.min(leaves.length-first,Math.max(1,Math.floor(distance*span/60)));
        for (let i=0;i<count;i++) {
          const leaf=leaves[first+i], angle=bearing+ring*goldenAngle+span*((i+.5)/count-.5);
          leaf.offsetX=distance*Math.cos(angle); leaf.offsetY=distance*Math.sin(angle);
          leaf.parent=parent; leaf.x=parent.x+leaf.offsetX; leaf.y=parent.y+leaf.offsetY;
        }
        first+=count; ring++;
      }
    }
    let left=Infinity,right=-Infinity,top=Infinity,bottom=-Infinity;
    for (const n of points) {
      left=Math.min(left,n.x); right=Math.max(right,n.x); top=Math.min(top,n.y); bottom=Math.max(bottom,n.y);
    }
    for (const n of points) { n.x-=(left+right)/2; n.y-=(top+bottom)/2; }
    group.width=right-left+90; group.height=bottom-top+90;
    // Allow room for both ends of a short link and a legible title around each island.
    group.footprint=points.length===1 ? 48 : Math.hypot(right-left,bottom-top)/2+65;
    group.heat=points.length>1 ? 1 : 0;
  }

  function place(group,x,y,angle=0) {
    group.x=x; group.y=y;
    const cos=Math.cos(angle),sin=Math.sin(angle);
    for (const n of group.nodes) {
      const dx=n.x,dy=n.y;
      n.x=x+dx*cos-dy*sin; n.y=y+dx*sin+dy*cos;
    }
  }

  function packComponents(components) {
    const core=components.filter(c=>c.nodes.length>3).sort((a,b)=>b.height-a.height);
    const outer=components.filter(c=>c.nodes.length<=3).sort((a,b)=>b.footprint-a.footprint);
    const wrap=Math.sqrt(core.reduce((sum,c)=>sum+c.width*c.height,0)*1.45);
    let x=0,y=0,width=0,row=0;
    for (const c of core) {
      if (x && x+c.width>wrap) { x=0; y+=row; row=0; }
      c.x=x+c.width/2; c.y=y+c.height/2; x+=c.width;
      width=Math.max(width,x); row=Math.max(row,c.height);
    }
    let rim=0,first=0,ring=0;
    for (const c of core) {
      place(c,c.x-width/2,c.y-(y+row)/2);
      // Leave clearance for the core to expand as the force solver settles.
      for (const n of c.nodes) rim=Math.max(rim,1.2*Math.hypot(n.x,n.y)+n.radius+45);
    }
    if (!core.length && outer.length) {
      place(outer[0],0,0); rim=outer[0].footprint; first++;
    }
    while (first<outer.length) {
      const maxFoot=outer[first].footprint, distance=rim+maxFoot+12;
      let used=0,end=first;
      while (end<outer.length) {
        const arc=2*Math.asin(outer[end].footprint/distance);
        if (used+arc>fullTurn) break;
        used+=arc; end++;
      }
      const spacing=(fullTurn-used)/(end-first);
      let angle=-Math.PI/2+ring*goldenAngle;
      for (let i=first;i<end;i++) {
        const c=outer[i],half=Math.asin(c.footprint/distance);
        angle+=half;
        place(c,distance*Math.cos(angle),distance*Math.sin(angle),angle+Math.PI/2);
        angle+=half+spacing;
      }
      rim=distance+maxFoot; first=end; ring++;
    }
  }

  function layout(data) {
    const nodes=data.nodes.map((row,id)=>({...row,id,degree:0,neighbors:new Set(),vx:0,vy:0}));
    for (const [a,b] of data.edges) {
      nodes[a].degree++; nodes[b].degree++;
      nodes[a].neighbors.add(b); nodes[b].neighbors.add(a);
    }
    const order=nodes.slice().sort((a,b)=>b.degree-a.degree || a.id-b.id);
    const components=[];
    for (const root of order) {
      if (root.component) continue;
      const group={nodes:[],heat:0};
      const stack=[root]; root.component=group;
      while (stack.length) {
        const n=stack.pop();
        group.nodes.push(n);
        // Area rises with total degree and approaches six times an isolated note's area.
        n.radius=5*Math.sqrt(1+5*n.degree/(n.degree+6));
        for (const id of n.neighbors) {
          if (nodes[id].component) continue;
          nodes[id].component=group; stack.push(nodes[id]);
        }
      }
      orderCommunities(group,nodes);
      seedComponent(group,nodes);
      components.push(group);
    }
    packComponents(components);
    return {nodes,order,edges:data.edges,components};
  }

  // Each cell stores its mass and centroid. Near cells are opened, distant cells
  // contribute one approximate force. Bucket leaves also handle coincident points.
  function tree(points,x,y,size) {
    let mx=0,my=0;
    for (const n of points) { mx+=n.x; my+=n.y; }
    const cell={x,y,size,mass:points.length,mx:mx/points.length,my:my/points.length};
    if (points.length<=4 || size<.1) { cell.points=points; return cell; }
    const half=size/2, buckets=[[],[],[],[]];
    for (const n of points) buckets[(n.x>=x+half?1:0)+(n.y>=y+half?2:0)].push(n);
    cell.children=[];
    for (let i=0;i<4;i++) if (buckets[i].length)
      cell.children.push(tree(buckets[i],x+(i%2)*half,y+(i>>1)*half,half));
    return cell;
  }
  function repel(n,cell) {
    const dx=n.x-cell.mx,dy=n.y-cell.my,d2=dx*dx+dy*dy;
    if (cell.size*cell.size<.65*d2) {
      const force=275*cell.mass/(d2+36);
      n.ax+=dx*force; n.ay+=dy*force;
    } else if (cell.points) {
      for (const m of cell.points) {
        if (m===n) continue;
        const dx=n.x-m.x || .01*(n.id>m.id?1:-1), dy=n.y-m.y;
        const distance=Math.hypot(dx,dy), overlap=n.radius+m.radius+13-distance;
        const force=275/(distance*distance+36)+Math.max(0,overlap)*.17/distance;
        n.ax+=dx*force; n.ay+=dy*force;
      }
    } else for (const child of cell.children) repel(n,child);
  }
  function tick(group,all,pin) {
    const points=group.nodes;
    let left=Infinity,right=-Infinity,top=Infinity,bottom=-Infinity;
    for (const n of points) {
      left=Math.min(left,n.x); right=Math.max(right,n.x);
      top=Math.min(top,n.y); bottom=Math.max(bottom,n.y);
    }
    const root=tree(points,left,top,Math.max(1,right-left,bottom-top)*1.001);
    for (const n of points) {
      n.ax=(group.x-n.x)*.017; n.ay=(group.y-n.y)*.017;
      if (n.parent) {
        n.ax+=.12*(n.parent.x+n.offsetX-n.x);
        n.ay+=.12*(n.parent.y+n.offsetY-n.y);
      }
      repel(n,root);
      for (const id of n.neighbors) {
        const m=all[id], dx=m.x-n.x, dy=m.y-n.y, distance=Math.hypot(dx,dy)||1;
        const rest=57+n.radius+m.radius, strength=.16/Math.max(1,Math.sqrt(n.neighbors.size));
        const force=(distance-rest)*strength/distance;
        n.ax+=dx*force; n.ay+=dy*force;
      }
    }
    for (const n of points) {
      if (n===pin) { n.vx=0; n.vy=0; continue; }
      n.vx=(n.vx+n.ax*group.heat)*.67; n.vy=(n.vy+n.ay*group.heat)*.67;
      const factor=Math.min(1,26/(Math.hypot(n.vx,n.vy)||1));
      n.x+=n.vx*factor; n.y+=n.vy*factor;
    }
    group.heat*=.94;
    if (group.heat<.018) group.heat=0;
  }
  function solver(graph) {
    const queue=graph.components.filter(c=>c.heat);
    const queued=new Set(queue);
    let cursor=0;
    return {
      reheat(n) {
        const c=n.component;
        if (c.nodes.length===1) return;
        c.heat=Math.max(c.heat,.65);
        if (!queued.has(c)) { queue.push(c); queued.add(c); }
      },
      step(pin,interactive=false) {
        // During a gesture a component may advance at most one tick per frame.
        let remaining=interactive ? queue.length : Infinity;
        const until=performance.now()+5;
        while (queue.length && remaining-- > 0) {
          const c=queue[cursor];
          tick(c,graph.nodes,pin);
          if (!c.heat) {
            queued.delete(c); queue[cursor]=queue[queue.length-1]; queue.pop();
          } else cursor++;
          if (cursor>=queue.length) cursor=0;
          if (performance.now()>=until) break;
        }
        return queue.length>0;
      }
    };
  }
  // WKWebView loads the application from file URLs. A bundled, self-contained
  // worker also works in engines which assign opaque origins to local files.
  const workerSource=()=>new Blob(['(',installGraphLayout.toString(),')(self);'],{type:'text/javascript'});
  global.SimaGraphLayout={layout,solver,workerSource};
  if (typeof WorkerGlobalScope!=='undefined' && global instanceof WorkerGlobalScope) {
    let graph,simulation;
    global.onmessage=({data})=>{
      if (data.graph) { graph=layout(data.graph); simulation=solver(graph); }
      if (data.move) {
        const n=graph.nodes[data.move.id];
        n.x=data.move.x; n.y=data.move.y; simulation.reheat(n);
      }
      const running=simulation.step(graph.nodes[data.pin],data.interactive);
      const positions=new Float64Array(graph.nodes.length*2);
      for (const n of graph.nodes) { positions[n.id*2]=n.x; positions[n.id*2+1]=n.y; }
      global.postMessage({running,positions},[positions.buffer]);
    };
  }
})(globalThis);
