'use strict';
let editor, session, lastBody;
const host=document.querySelector('#editor');
function send(note) { webkit.messageHandlers.reader.postMessage({...note,file:session.file,id:session.editID}); }
function assetURL(path) {
  const base=session.file.split('/').slice(0,-1), parts=path.split('/');
  while(base.length && parts.length && base[0]===parts[0]) { base.shift(); parts.shift(); }
  return 'feynman-image://local/?file='+encodeURIComponent(session.file)+'&src='+encodeURIComponent('../'.repeat(base.length)+parts.map(encodeURIComponent).join('/'));
}
function replaceSelectedImage(fileName, body, start, raw, value) {
  if (session.file !== fileName || editor.getText() !== body || body.slice(start, start + raw.length) !== raw) return;
  editor.locate(start, raw.length);
  editor.action('insertText', value);
}
let imageAlignmentActions = [];
function render(data) {
  if(editor && data.editID===session.editID && data.file===session.file) return;
  editor?.destroy(); session=data;lastBody=data.body;
  editor=SimaEditor.create(host,{text:data.body,path:data.file,
    writeTableClipboard:(text,whole)=>webkit.messageHandlers.tableCopy.postMessage({id:data.editID,text,whole}),
    onAsset:async file=>(await importImage(file,data.file)).path,
    onError:message=>send({action:'error',message}),
    onLink:href=>send({action:'link',href}),
    onImageMenu(point, image, items, native, range) {
      imageAlignmentActions = items.map(item => item[1]);
      send({action:'imageMenu', src:image.src, title:image.alt, raw:range.raw, start:range.start,
            body:editor.getText(), x:point.x, y:point.y});
    },
    onChange(){
      const next=editor.getText();
      let start=0,oldEnd=lastBody.length,end=next.length;
      while(start<oldEnd && start<end && lastBody[start]===next[start])start++;
      while(oldEnd>start && end>start && lastBody[oldEnd-1]===next[end-1]){oldEnd--;end--;}
      send({action:'change',start,length:oldEnd-start,value:next.slice(start,end),caret:end,composing:host.querySelector('.sima-composing')!=null});
      lastBody=next;
    }
  });
  if (data.initialCommand === 'image.source') {
    editor.selectImageAt(data.editOffset || 0, data.viewportY);
  } else {
    editor.locate(data.editOffset || 0, data.selectionLength || 0, data.viewportY);
    if (data.initialCommand) performEditorCommand(data.initialCommand);
  }
}
// The system pasteboard carries HTML tables, rich links and native screenshots.
host.addEventListener('paste', async event => {
  if (!event.isTrusted || event.defaultPrevented || event.target.closest('dialog,.sima-table-block,.sima-image-caption')) return;
  event.preventDefault();
  const active = editor, original = active.getText(), id = session.editID;
  const {anchor, head} = active.getState().selection;
  const start = Math.min(anchor, head), end = Math.max(anchor, head);
  const plain = event.clipboardData?.getData('text/plain') || '';
  const html = event.clipboardData?.getData('text/html') || '';
  try {
    const value = await webkit.messageHandlers.notePaste.postMessage({id, selection:original.slice(start,end), html});
    if (active !== editor || active.getText() !== original || session.editID !== id) return;
    const current = active.getState().selection;
    if (current.anchor !== anchor || current.head !== head) return;
    let text = value ?? plain;
    if (!text) return;
    if (SimaRender.parse(text).some(block => block.type === 'table')) {
      if (start && !original.slice(0,start).endsWith('\n\n')) text = '\n\n' + text;
      if (end < original.length && !original.slice(end).startsWith('\n\n')) text += '\n\n';
    }
    active.action('insertText', text);
  } catch (err) { if (active === editor) send({action:'error', message:err.message}); }
});
function performEditorCommand(id) {
  if(id==='open')return;
  if(id==='edit.find'){
    let term='',index=-1,hits=[];
    showDocumentFind((q,dir)=>{
      if(term!==q||!dir){term=q;hits=[];index=-1;const rx=new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'),'giu');for(const m of editor.getText().matchAll(rx))hits.push({start:m.index,length:m[0].length});}
      if(!hits.length){editor.setHighlights([]);return;}
      index=(index+(dir||1)+hits.length)%hits.length;editor.showSearchResult(hits,hits[index]);
    },()=>editor.setHighlights([]));return;
  }
  if(id==='edit.link'){
    const saved=editor.getState().selection, a=Math.min(saved.head,saved.anchor),b=Math.max(saved.head,saved.anchor);
    const dialog=document.createElement('dialog'),form=document.createElement('form'),input=document.createElement('input'),ok=document.createElement('button');
    input.placeholder='链接地址';input.required=true;ok.textContent='插入链接';form.append(input,ok);dialog.append(form);document.body.append(dialog);
    form.onsubmit=e=>{e.preventDefault();const url=input.value;dialog.close();editor.locate(a,b-a);editor.action('insertText','['+(editor.getText().slice(a,b)||url)+']('+url.replaceAll(' ','%20')+')');};
    dialog.onclose=()=>dialog.remove();dialog.showModal();input.focus();return;
  }
  return editor.action(id);
}
