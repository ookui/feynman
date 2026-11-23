function sourcePoint(node, offset) {
  const parent=node.nodeType===Node.TEXT_NODE ? node.parentElement : node;
  let owner=parent;
  while(owner && owner!==article && !editableSpan(owner))owner=owner.parentElement;
  const span=owner && editableSpan(owner);
  if(!span)return 0;
  const walker=document.createTreeWalker(owner,NodeFilter.SHOW_TEXT);
  let at=span.start;
  while(walker.nextNode()){
    const n=walker.currentNode,found=state.body.indexOf(n.data,at);
    if(found<0||found+n.length>span.end)continue;
    if(n===node)return found+offset;
    at=found+n.length;
  }
  return span.start;
}
function performEditorCommand(command) {
  if(command==='edit.find'){
    showDocumentFind((query,dir)=>{window.find(query,false,dir<0,true,false,false,false);},()=>{});return;
  }
  if(!state?.editable)return;
  if(activeBlock?.grid && command.startsWith('table.') && command!=='table.insert'){
    activeBlock.grid.action(command.slice(6));return;
  }
  let start=state.sourceOffset||0, length=0;
  const selection=getSelection();
  if(activeBlock?.field && !activeBlock.grid){
    const field=activeBlock.field;start=fieldStart(activeBlock)+field.selectionStart;length=field.selectionEnd-field.selectionStart;
  }else if(activeBlock)start=blockCaret(activeBlock);
  else if(selection.rangeCount && article.contains(selection.anchorNode)){
    const range=selection.getRangeAt(0);
    if (range.collapsed) start=sourcePoint(range.startContainer,range.startOffset);
    else {
      const walker=document.createTreeWalker(article,NodeFilter.SHOW_TEXT);
      let first,last;
      while(walker.nextNode()) {
        const n=walker.currentNode;
        if(!n.length || !range.intersectsNode(n) || n.parentElement?.closest('button,details')) continue;
        if(n===range.startContainer && range.startOffset===n.length || n===range.endContainer && range.endOffset===0) continue;
        if(!n.data.trim() && n.parentElement===article) continue;
        first ??= n;
        last=n;
      }
      if(first && last) {
        start=sourcePoint(first,first===range.startContainer ? range.startOffset : 0);
        length=Math.max(0,sourcePoint(last,last===range.endContainer ? range.endOffset : last.length)-start);
      }
    }
  }
  send({action:'rich',command,start,length});
}
document.addEventListener('dragover',e=>{if(state?.editable && e.dataTransfer.types.includes('Files'))e.preventDefault();});
document.addEventListener('drop',async e=>{
  if(!state?.editable)return;
  const images=Array.from(e.dataTransfer.files).filter(f=>f.type.startsWith('image/')||/\.(svg|heic|heif|jxl|tiff?)$/i.test(f.name));
  if(!images.length)return;
  e.preventDefault();
  const path=file, body=activeBlock ? paragraphBody(activeBlock) : state.body;
  const point=document.caretRangeFromPoint(e.clientX,e.clientY);
  const at=activeBlock?.field===e.target ? blockCaret(activeBlock) : point && article.contains(point.startContainer) ? sourcePoint(point.startContainer,point.startOffset) : body.length;
  try{
    const links=[];for(const img of images)links.push((await importImage(img,path)).markdown);
    if(file===path)send({action:'dropImages',body,at,value:links.join('\n\n')});
  }catch(err){tell(err.message);}
});

function revealSearchHit(hit) {
  CSS.highlights?.delete('search-active');
  if (!hit) { window.scrollTo(0, 0); return; }
  const target=mappedBlocks(true).filter(el=>{
    const span=editableSpan(el);
    return span && span.start<=hit.start && span.end>=hit.start;
  }).at(-1);
  if(!target)return;
  const walker=document.createTreeWalker(target,NodeFilter.SHOW_TEXT);
  let cursor=editableSpan(target).start, first,last;
  while(walker.nextNode()){
    const node=walker.currentNode, start=state.body.indexOf(node.data,cursor);
    if(start<0)continue;
    cursor=start+node.length;
    if(!first && cursor>hit.start && start<hit.start+hit.length)first=[node,Math.max(0,hit.start-start)];
    if(first && start<hit.start+hit.length)last=[node,Math.min(node.length,hit.start+hit.length-start)];
  }
  target.scrollIntoView({block:'center'});
  if(first && last){
    const range=document.createRange();range.setStart(...first);range.setEnd(...last);
    if(window.Highlight)CSS.highlights.set('search-active',new Highlight(range));
    const rect=range.getBoundingClientRect();
    if(rect.height)scrollBy(0,rect.top-innerHeight*.35);
  }
}
