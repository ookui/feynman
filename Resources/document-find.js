function showDocumentFind(find, clear) {
  let bar = document.querySelector('#document-find');
  if (bar) { bar.querySelector('input').select(); return; }
  bar = document.createElement('form');
  bar.id = 'document-find';
  Object.assign(bar.style,{position:'fixed',right:'12px',top:'8px',zIndex:999,background:'white',padding:'6px',border:'1px solid #ccc',borderRadius:'6px'});
  const input=document.createElement('input');
  input.type='search'; input.placeholder='查找当前文档'; input.setAttribute('aria-label',input.placeholder);
  bar.append(input);
  const run = direction => { if (input.value) find(input.value,direction); else clear(); };
  function close() { clear(); bar.remove(); }
  for(const [label, action] of [['↑',()=>run(-1)],['↓',()=>run(1)],['×',close]]) {
    const b=document.createElement('button');b.type='button';b.textContent=label;b.onclick=action;bar.append(b);
  }
  input.oninput=()=>run(0);
  bar.onsubmit=e=>{e.preventDefault();run(1);};
  bar.onkeydown=e=>{if(e.key==='Escape'){e.preventDefault();close();}else if(e.key==='Enter'&&e.shiftKey){e.preventDefault();run(-1);}};
  document.body.append(bar);input.focus();
}
async function importImage(file, path) {
  const encoded = await new Promise((resolve,reject)=>{
    const r=new FileReader();r.onerror=()=>reject(r.error);r.onload=()=>resolve(r.result.split(',')[1]);r.readAsDataURL(file);
  });
  return webkit.messageHandlers.imageImport.postMessage({file:path,name:file.name,mime:file.type,data:encoded});
}
