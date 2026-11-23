/* Local Markdown tables. Every edit stays within the table's original source range. */
(function (global) {
  'use strict';
  const clamp=(n,min,max)=>Math.max(min,Math.min(max,n));
  function hasClosingTicks(text,start,count){const marker='`'.repeat(count);let at=text.indexOf(marker,start+count);while(at>=0){if(text[at-1]!=='`'&&text[at+count]!=='`')return true;at=text.indexOf(marker,at+count);}return false;}
  function splitRow(line, offset=0) {
    const pipes=[]; let ticks=0;
    for(let i=0;i<line.length;i++) {
      if(line[i]==='\\'){i++;continue;}
      if(line[i]==='`') {let n=1;while(line[i+n]==='`')n++;if(!ticks&&hasClosingTicks(line,i,n))ticks=n;else if(ticks===n)ticks=0;i+=n-1;continue;}
      if(line[i]==='|'&&!ticks)pipes.push(i);
    }
    const first=line.search(/\S/), last=line.trimEnd().length-1;
    const outerLeft=pipes[0]===first, outerRight=pipes.at(-1)===last;
    const boundaries=[outerLeft?pipes[0]+1:0,...pipes.filter(p=>!(outerLeft&&p===pipes[0])&&!(outerRight&&p===pipes.at(-1))).map(p=>p+1)];
    const ends=[...pipes.filter(p=>!(outerLeft&&p===pipes[0])&&!(outerRight&&p===pipes.at(-1))),outerRight?pipes.at(-1):line.length];
    return boundaries.map((start,i)=>{const end=ends[i];const part=line.slice(start,end);const lead=part.trim()?part.match(/^\s*/)[0].length:Math.floor(part.length/2);const tail=part.match(/\s*$/)[0].length;return {text:part.trim(),start:offset+start+lead,end:offset+Math.max(start+lead,end-tail)};});
  }
  function parse(raw) {
    raw=String(raw); const lines=[];let offset=0;
    for(const match of raw.matchAll(/([^\r\n]*)(\r\n|\n|\r|$)/g)){if(!match[0])break;lines.push({text:match[1],start:offset,end:offset+match[1].length,eol:match[2]});offset+=match[0].length;}
    if(lines.length<2||(!lines[0].text.includes('|')&&!lines[1].text.includes('|')))return null;
    const header=splitRow(lines[0].text,lines[0].start), divider=splitRow(lines[1].text,lines[1].start);
    if(header.length<1||divider.length!==header.length||!divider.every(c=>/^:?-{3,}:?$/.test(c.text)))return null;
    const rows=[header,...lines.slice(2).filter(l=>l.text.trim()).map(l=>splitRow(l.text,l.start))];
    const columns=header.length;
    for(const row of rows){while(row.length<columns)row.push({text:'',start:null,end:null});if(row.length>columns)row.length=columns;}
    return {raw,rows,columns,align:divider.map(c=>c.text.startsWith(':')&&c.text.endsWith(':')?'center':c.text.endsWith(':')?'right':c.text.startsWith(':')?'left':null),newline:lines[0].eol||'\n',trailing:/(\r\n|\n|\r)$/.test(raw),indent:lines[0].text.match(/^\s*/)[0],lines};
  }
  function encode(value){const text=String(value).replace(/\r\n|\r|\n/g,'<br>');let result='',ticks=0;for(let i=0;i<text.length;i++){const ch=text[i];if(ch==='\\'){result+=ch;if(i+1<text.length)result+=text[++i];continue;}if(ch==='`'){let n=1;while(text[i+n]==='`')n++;if(!ticks&&hasClosingTicks(text,i,n))ticks=n;else if(ticks===n)ticks=0;result+='`'.repeat(n);i+=n-1;continue;}result+=ch==='|'&&!ticks?'\\|':ch;}return result;}
  function encodedOffset(value,index){const encoded=encode(value);let at=0;for(let i=0;i<index;i++){if(value[i]==='\r'||value[i]==='\n'){if(value[i]==='\r'&&value[i+1]==='\n')i++;at+=4;}else{if(value[i]==='|'&&encoded[at]==='\\'&&encoded[at+1]==='|')at++;at++;}}return at;}
  function serialize(model) {
    const row=values=>model.indent+'| '+values.map(c=>encode(typeof c==='string'?c:c.text)).join(' | ')+' |';
    const divider=model.align.map(a=>a==='center'?':---:':a==='right'?'---:':a==='left'?':---':'---');
    return [row(model.rows[0]),row(divider),...model.rows.slice(1).map(row)].join(model.newline)+(model.trailing?model.newline:'');
  }
  function setCell(raw,row,column,value) {
    const model=parse(raw);if(!model||!model.rows[row]?.[column])return raw;
    const cell=model.rows[row][column], text=encode(value);
    if(cell.start!==null)return raw.slice(0,cell.start)+text+raw.slice(cell.end);
    model.rows[row][column]={text};return serialize(model);
  }
  function operate(raw,id,row=0,column=0,arg) {
    const model=parse(raw);if(!model)return raw;
    row=clamp(row,0,model.rows.length-1);column=clamp(column,0,model.columns-1);
    const blank=()=>Array.from({length:model.columns},()=>({text:''}));
    id=id.replace(/^table\./,'');
    if(id==='rowAbove'||id==='rowBelow')model.rows.splice(Math.max(1,row+(id==='rowBelow'?1:0)),0,blank());
    else if(id==='deleteRow'){if(row===0){if(model.rows.length>1)model.rows[0]=model.rows.splice(1,1)[0];else model.rows[0]=blank();}else model.rows.splice(row,1);}
    else if(id==='columnLeft'||id==='columnRight'){const at=column+(id==='columnRight'?1:0);model.rows.forEach(r=>r.splice(at,0,{text:''}));model.align.splice(at,0,null);}
    else if(id==='deleteColumn'){if(model.columns===1)return raw;model.rows.forEach(r=>r.splice(column,1));model.align.splice(column,1);}
    else if(id==='moveRowUp'||id==='moveRowDown'){const to=row+(id==='moveRowUp'?-1:1);if(row===0||to<1||to>=model.rows.length)return raw;[model.rows[row],model.rows[to]]=[model.rows[to],model.rows[row]];}
    else if(id==='moveColumnLeft'||id==='moveColumnRight'){const to=column+(id==='moveColumnLeft'?-1:1);if(to<0||to>=model.columns)return raw;model.rows.forEach(r=>{[r[column],r[to]]=[r[to],r[column]];});[model.align[column],model.align[to]]=[model.align[to],model.align[column]];}
    else if(/^align(Left|Center|Right)$/.test(id))model.align[column]=id.slice(5).toLowerCase();
    else if(id==='clear')model.rows[row][column]={text:''};
    else return raw;
    return serialize(model);
  }
  function parseTSV(value) {
    const rows=[[]];let field='',quoted=false;
    value=String(value).replace(/\r\n/g,'\n').replace(/\r/g,'\n');
    for(let i=0;i<value.length;i++){const ch=value[i];if(ch==='"'&&(quoted||field==='')){if(quoted&&value[i+1]==='"'){field+='"';i++;}else quoted=!quoted;}else if(!quoted&&(ch==='\t'||ch==='\n')){rows.at(-1).push(field);field='';if(ch==='\n')rows.push([]);}else field+=ch;}
    rows.at(-1).push(field);if(rows.length>1&&rows.at(-1).length===1&&rows.at(-1)[0]==='')rows.pop();return rows;
  }
  const quoteTSV=value=>/[\t\n\r"]/.test(value)?'"'+value.replace(/"/g,'""')+'"':value;
  function copyRectangle(raw,rect) {const model=parse(raw);if(!model)return '';return model.rows.slice(rect.top,rect.bottom+1).map(row=>row.slice(rect.left,rect.right+1).map(c=>quoteTSV(c.text.replace(/\\\|/g,'|').replace(/<br\s*\/?\s*>/gi,'\n'))).join('\t')).join('\n');}
  function pasteRectangle(raw,row,column,value,rect) {
    const model=parse(raw);if(!model)return raw;const data=parseTSV(value), height=data.length,width=Math.max(...data.map(r=>r.length));
    if(rect){row=rect.top;column=rect.left;}
    const fill=height===1&&width===1&&rect;const lastRow=fill?rect.bottom:row+height-1,lastCol=fill?rect.right:column+width-1;
    if(lastRow<model.rows.length&&lastCol<model.columns){const edits=[];for(let r=fill?rect.top:row;r<=lastRow;r++)for(let c=fill?rect.left:column;c<=lastCol;c++){const cell=model.rows[r][c];if(cell.start===null){edits.length=0;break;}edits.push({start:cell.start,end:cell.end,text:encode(fill?data[0][0]:data[r-row]?.[c-column]||'')});}if(edits.length===(lastRow-row+1)*(lastCol-column+1)){for(const edit of edits.sort((a,b)=>b.start-a.start))raw=raw.slice(0,edit.start)+edit.text+raw.slice(edit.end);return raw;}}
    while(model.align.length<=lastCol)model.align.push(null);
    model.rows.forEach(r=>{while(r.length<model.align.length)r.push({text:''});});
    while(model.rows.length<=lastRow)model.rows.push(Array.from({length:model.align.length},()=>({text:''})));
    for(let r=fill?rect.top:row;r<=lastRow;r++)for(let c=fill?rect.left:column;c<=lastCol;c++)model.rows[r][c]={text:encode(fill?data[0][0]:data[r-row]?.[c-column]||'')};
    return serialize(model);
  }
  const actions=[['rowAbove','上方插入行'],['rowBelow','下方插入行'],['columnLeft','左侧插入列'],['columnRight','右侧插入列'],['deleteRow','删除行'],['deleteColumn','删除列'],['moveRowUp','上移行'],['moveRowDown','下移行'],['moveColumnLeft','左移列'],['moveColumnRight','右移列'],['alignLeft','左对齐'],['alignCenter','居中'],['alignRight','右对齐']];
  function create(rows=3,columns=3){rows=clamp(Number(rows)||3,1,1000);columns=clamp(Number(columns)||3,1,100);return serialize({rows:Array.from({length:rows},(_,r)=>Array.from({length:columns},(_,c)=>({text:r===0?'列 '+(c+1):''}))),align:Array(columns).fill(null),indent:'',newline:'\n',trailing:false});}
  function normalizeWidths(values){return Array.isArray(values)?values.map(v=>Number.isFinite(Number(v))&&Number(v)>=64?Number(v):null):[];}
  function changeWidths(values,id,column){const widths=normalizeWidths(values);id=id.replace(/^table\./,'');if(id==='columnLeft'||id==='columnRight')widths.splice(column+(id==='columnRight'?1:0),0,null);else if(id==='deleteColumn')widths.splice(column,1);else if(id==='moveColumnLeft'||id==='moveColumnRight'){const to=column+(id==='moveColumnLeft'?-1:1);while(widths.length<=Math.max(column,to))widths.push(null);if(to>=0)[widths[column],widths[to]]=[widths[to],widths[column]];}return widths;}
  function mount(container,raw,options={}) {
    let model=parse(raw),active={row:0,column:0},anchor=null,rectangle=null,composing=false,menu=null,dragCleanup=null,destroyed=false,dragAnchor=null;const widths=normalizeWidths(options.widths);
    if(!model)throw Error('Invalid Markdown table');
    container.classList.add('sima-table-block');container.contentEditable='false';
    const make=(tag,cls,text)=>{const el=document.createElement(tag);if(cls)el.className=cls;if(text!==undefined)el.textContent=text;return el;};
    const tr = label => globalThis.SimaSettings?.menuText(label) ?? label;
    const toolbar=make('div','sima-table-toolbar');toolbar.setAttribute('role','toolbar');
    [['rowBelow','＋行'],['columnRight','＋列'],['menu','表格操作 ⋯']].forEach(([id,title])=>{const b=make('button','');b.type='button';b.dataset.menuLabel=title;b.onmousedown=e=>e.preventDefault();b.onclick=e=>id==='menu'?openMenu(e.clientX,e.clientY):action(id);toolbar.append(b);});
    function localizeToolbar() {
      toolbar.setAttribute('aria-label',tr('表格操作'));
      for (const button of toolbar.children) {
        button.title = button.textContent = tr(button.dataset.menuLabel);
      }
      closeMenu();
    }
    localizeToolbar();
    document.addEventListener('sima:menu-language',localizeToolbar);
    const scroller=make('div','sima-table-scroll');const table=make('table','sima-table');table.setAttribute('aria-label','Markdown 表格');table.setAttribute('role','grid');table.tabIndex=-1;scroller.append(table);container.replaceChildren(toolbar,scroller);
    function cellAt(row=active.row,column=active.column){return table.querySelector('[data-row="'+row+'"][data-column="'+column+'"]');}
    function selected(){return rectangle||{top:active.row,bottom:active.row,left:active.column,right:active.column};}
    function paint(){for(const cell of table.querySelectorAll('[data-row]')){const r=+cell.dataset.row,c=+cell.dataset.column,rect=selected();cell.classList.toggle('selected',r>=rect.top&&r<=rect.bottom&&c>=rect.left&&c<=rect.right);cell.setAttribute('aria-selected',String(r>=rect.top&&r<=rect.bottom&&c>=rect.left&&c<=rect.right));}if(rectangle){const a=model.rows[rectangle.top]?.[rectangle.left],z=model.rows[rectangle.bottom]?.[rectangle.right];if(a?.start!=null&&z?.end!=null)options.selection?.(a.start,z.end);}}
    function sourceSelection(input){if(rectangle||input&&document.activeElement!==input)return;const c=model.rows[active.row]?.[active.column],start=input?._sourceRange?.start??c?.start;if(start!==null&&start!==undefined)options.selection?.(start+encodedOffset(input?.value||'',input?.selectionStart||0),start+encodedOffset(input?.value||'',input?.selectionEnd||0));}
    function notify(next,kind='structure',position=active){if(next===raw)return;raw=next;model=parse(raw);options.change?.(raw,{...position,kind});}
    function focus(row=active.row,column=active.column,select=false){if(destroyed)return;active={row:clamp(row,0,model.rows.length-1),column:clamp(column,0,model.columns-1)};const cell=cellAt();if(!cell)return;for(const editing of table.querySelectorAll('.editing'))if(editing!==cell)editing.classList.remove('editing');cell.classList.add('editing');const input=cell.querySelector('textarea');input.focus();if(select)input.select();else input.setSelectionRange(input.value.length,input.value.length);paint();sourceSelection(input);options.activate?.(active);}
    function render(){table.replaceChildren();const cols=make('colgroup');model.align.forEach((_,i)=>{const col=make('col');if(widths[i])col.style.width=widths[i]+'px';cols.append(col);});table.append(cols);const head=make('thead'),body=make('tbody');table.append(head,body);
      model.rows.forEach((row,r)=>{const tr=make('tr');(r===0?head:body).append(tr);row.forEach((cell,c)=>{const td=make(r===0?'th':'td');td.dataset.row=r;td.dataset.column=c;td.setAttribute('role',r===0?'columnheader':'gridcell');td.tabIndex=0;td.style.textAlign=model.align[c]||'left';const view=make('div','sima-table-cell-view');view.textContent=cell.text.replace(/\\\|/g,'|').replace(/<br\s*\/?\s*>/gi,'\n')||'\u200b';if(options.renderInline){const result=options.renderInline(cell.text);if(typeof result==='string')view.innerHTML=result;else if(result)view.replaceChildren(result);}const input=make('textarea','sima-table-cell-input');input.value=cell.text;input.rows=Math.max(1,cell.text.split('\n').length);input.spellcheck=false;input.setAttribute('aria-label',(r===0?'表头':'第 '+r+' 行')+'，第 '+(c+1)+' 列');
        input.addEventListener('compositionstart',()=>{composing=true;});input.addEventListener('compositionend',()=>{composing=false;updateInput(input,r,c);});input.addEventListener('input',()=>{if(!composing)updateInput(input,r,c);});input.addEventListener('select',()=>sourceSelection(input));input.addEventListener('keyup',()=>sourceSelection(input));input.addEventListener('focus',()=>{active={row:r,column:c};input._sourceRange={...model.rows[r][c]};paint();sourceSelection(input);});input.addEventListener('blur',()=>{if(composing)return;input.value=model.rows[r]?.[c]?.text||'';input._sourceRange=null;td.classList.remove('editing');view.textContent=input.value.replace(/\\\|/g,'|')||'\u200b';if(options.renderInline){const result=options.renderInline(input.value);if(typeof result==='string')view.innerHTML=result;else if(result)view.replaceChildren(result);}});
        const content = make('div','sima-table-cell-content');
        content.append(view,input);
        td.append(content);
        td.addEventListener('pointerdown',e=>{if(e.target===input||e.target.closest('.sima-table-resize'))return;if(e.target.closest('a'))return;e.preventDefault();if(e.shiftKey){anchor=anchor||{...active};rectangle={top:Math.min(anchor.row,r),bottom:Math.max(anchor.row,r),left:Math.min(anchor.column,c),right:Math.max(anchor.column,c)};active={row:r,column:c};paint();table.focus();}else {anchor={row:r,column:c};rectangle=null;focus(r,c);} });
        td.addEventListener('pointerdown',e=>{if(!e.shiftKey&&e.target!==input&&!e.target.closest('.sima-table-resize')&&!e.target.closest('a'))dragAnchor={row:r,column:c};});td.addEventListener('pointerenter',e=>{if(!dragAnchor||e.buttons!==1||(dragAnchor.row===r&&dragAnchor.column===c))return;anchor=dragAnchor;active={row:r,column:c};rectangle={top:Math.min(anchor.row,r),bottom:Math.max(anchor.row,r),left:Math.min(anchor.column,c),right:Math.max(anchor.column,c)};paint();});
        td.addEventListener('focus',e=>{if(e.target===td)focus(r,c);});td.addEventListener('dblclick',()=>{rectangle=null;focus(r,c,true);});td.addEventListener('contextmenu',e=>{e.preventDefault();active={row:r,column:c};paint();openMenu(e.clientX,e.clientY);});
        if(r===0){const grip=make('span','sima-table-resize');grip.setAttribute('role','separator');grip.setAttribute('aria-label','调整第 '+(c+1)+' 列宽');grip.setAttribute('aria-orientation','vertical');grip.tabIndex=0;grip.addEventListener('pointerdown',e=>{e.preventDefault();e.stopPropagation();const start=e.clientX,initial=td.getBoundingClientRect().width;const move=ev=>{widths[c]=Math.max(64,initial+ev.clientX-start);cols.children[c].style.width=widths[c]+'px';};const stop=()=>{document.removeEventListener('pointermove',move);document.removeEventListener('pointerup',stop);dragCleanup=null;options.onWidthsChange?.([...widths]);};document.addEventListener('pointermove',move);document.addEventListener('pointerup',stop);dragCleanup=stop;});grip.addEventListener('keydown',e=>{if(!['ArrowLeft','ArrowRight'].includes(e.key))return;e.preventDefault();widths[c]=Math.max(64,(widths[c]||td.getBoundingClientRect().width)+(e.key==='ArrowLeft'?-16:16));cols.children[c].style.width=widths[c]+'px';options.onWidthsChange?.([...widths]);});td.append(grip);}tr.append(td);});});paint();}
    function updateInput(input,r,c){active={row:r,column:c};const range=input._sourceRange||model.rows[r][c],text=encode(input.value);if(range.start===null)notify(setCell(raw,r,c,input.value),'input');else{const next=raw.slice(0,range.start)+text+raw.slice(range.end);input._sourceRange={start:range.start,end:range.start+text.length};notify(next,'input');}const view=input.previousElementSibling;view.textContent=input.value.replace(/\\\|/g,'|')||'\u200b';sourceSelection(input);}
    function closeMenu(){if(menu){menu.remove();menu=null;}document.removeEventListener('pointerdown',outsideMenu,true);}
    function outsideMenu(e){if(menu&&!menu.contains(e.target))closeMenu();}
    function openMenu(x,y){closeMenu();menu=make('div','sima-table-menu');menu.setAttribute('role','menu');for(const [id,title] of actions){const label=globalThis.SimaSettings?.commands.find(c=>c.id==='table.'+id)?.label ?? title;const b=make('button','',label);b.type='button';b.setAttribute('role','menuitem');b.onmousedown=e=>e.preventDefault();b.onclick=()=>{closeMenu();action(id);};menu.append(b);}document.body.append(menu);const box=menu.getBoundingClientRect();menu.style.left=clamp(x,8,Math.max(8,innerWidth-box.width-8))+'px';menu.style.top=clamp(y,8,Math.max(8,innerHeight-box.height-8))+'px';menu.addEventListener('keydown',e=>{const buttons=[...menu.querySelectorAll('button')],i=buttons.indexOf(document.activeElement);if(e.key==='Escape'){e.preventDefault();closeMenu();focus();}if(['ArrowDown','ArrowUp','Home','End'].includes(e.key)){e.preventDefault();buttons[e.key==='Home'?0:e.key==='End'?buttons.length-1:(i+(e.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length].focus();}});menu.querySelector('button')?.focus();document.addEventListener('pointerdown',outsideMenu,true);}
    function action(id,arg){if(composing)return false;id=id.replace(/^table\./,'');if(id==='insert')return false;const next=operate(raw,id,active.row,active.column,arg);if(next===raw)return false;const previous={...active};if(/^(columnLeft|columnRight|deleteColumn|moveColumnLeft|moveColumnRight)$/.test(id)){previous.widthsBefore=[...widths];previous.widthsBefore=[...widths];const nextWidths=changeWidths(widths,id,active.column);previous.widthsAfter=[...nextWidths];widths.splice(0,widths.length,...nextWidths);previous.widthsAfter=[...widths];options.onWidthsChange?.([...widths]);}if(id==='rowAbove'&&active.row>0)active.row++;if(id==='columnLeft')active.column++;if(id==='moveRowUp'&&active.row>1)active.row--;if(id==='moveRowDown'&&active.row<model.rows.length-1)active.row++;if(id==='moveColumnLeft'&&active.column>0)active.column--;if(id==='moveColumnRight'&&active.column<model.columns-1)active.column++;notify(next,'structure',previous);rectangle=null;anchor=null;render();focus();return true;}
    function keydown(e){if(composing||e.isComposing||e.keyCode===229)return;
      if(e.shiftKey&&!e.altKey&&!e.ctrlKey&&!e.metaKey&&(rectangle||e.target.tagName!=='TEXTAREA')&&['ArrowUp','ArrowDown','ArrowLeft','ArrowRight'].includes(e.key)){e.preventDefault();anchor=anchor||{...active};const delta={ArrowUp:[-1,0],ArrowDown:[1,0],ArrowLeft:[0,-1],ArrowRight:[0,1]}[e.key];active={row:clamp(active.row+delta[0],0,model.rows.length-1),column:clamp(active.column+delta[1],0,model.columns-1)};rectangle={top:Math.min(anchor.row,active.row),bottom:Math.max(anchor.row,active.row),left:Math.min(anchor.column,active.column),right:Math.max(anchor.column,active.column)};paint();return;}
      if(e.key==='Tab'){e.preventDefault();rectangle=null;let index=active.row*model.columns+active.column+(e.shiftKey?-1:1);if(index<0){options.exit?.(-1);return;}if(index>=model.rows.length*model.columns){notify(operate(raw,'rowBelow',model.rows.length-1,active.column),'structure');render();}focus(Math.floor(index/model.columns),index%model.columns);return;}
      if(e.key==='Escape'){e.preventDefault();closeMenu();rectangle=null;cellAt()?.classList.remove('editing');table.focus({preventScroll:true});options.exit?.(1);return;}
      if(e.altKey&&e.shiftKey&&['ArrowUp','ArrowDown','ArrowLeft','ArrowRight'].includes(e.key)){e.preventDefault();action({ArrowUp:'moveRowUp',ArrowDown:'moveRowDown',ArrowLeft:'moveColumnLeft',ArrowRight:'moveColumnRight'}[e.key]);return;}
      if(e.altKey&&(e.metaKey||e.ctrlKey)){const map={ArrowUp:'rowAbove',ArrowDown:'rowBelow',ArrowLeft:'columnLeft',ArrowRight:'columnRight',Backspace:e.shiftKey?'deleteColumn':'deleteRow'};if(map[e.key]){e.preventDefault();action(map[e.key]);return;}}
      if(rectangle&&['Backspace','Delete'].includes(e.key)){e.preventDefault();const m=parse(raw),rect=selected();for(let r=rect.top;r<=rect.bottom;r++)for(let c=rect.left;c<=rect.right;c++)m.rows[r][c]={text:''};notify(serialize(m),'structure');rectangle=null;render();focus();}
    }
    function copy(e){const input=e.target.closest?.('textarea');if(!rectangle&&input&&input.selectionStart!==input.selectionEnd)return;e.clipboardData?.setData('text/plain',copyRectangle(raw,selected()));e.preventDefault();}
    function cut(e){const input=e.target.closest?.('textarea');if(!rectangle&&input&&input.selectionStart!==input.selectionEnd)return;copy(e);notify(pasteRectangle(raw,active.row,active.column,'',selected()),'paste');rectangle=null;render();focus();}
    function paste(e){if(composing)return;const text=e.clipboardData?.getData('text/plain');if(text===undefined)return;const input=e.target.closest?.('textarea');if(!rectangle&&!/[\t\r\n]/.test(text)&&input)return;e.preventDefault();notify(pasteRectangle(raw,active.row,active.column,text,rectangle),'paste');rectangle=null;render();focus();}
    function pointerup(){dragAnchor=null;}
    function clickLink(e){const link=e.target.closest?.('a');if(!link || link.dataset.mathTarget)return;const target=link.dataset.link||link.getAttribute('href');if(target&&options.openLink){e.preventDefault();e.stopPropagation();options.openLink(target,{wiki:link.hasAttribute('data-wiki'),newTab:e.metaKey||e.ctrlKey});}}
    container.addEventListener('keydown',keydown);container.addEventListener('copy',copy);container.addEventListener('cut',cut);container.addEventListener('paste',paste);container.addEventListener('click',clickLink);document.addEventListener('pointerup',pointerup);render();
    return {action,focus,syncImageSource(next,cell) {
      const parsed = parse(next);
      if (!parsed) return;
      raw = next; model = parsed;
      cell.querySelector('.sima-table-cell-input').value = model.rows[cell.dataset.row]?.[cell.dataset.column]?.text ?? '';
    },getWidths:()=>[...widths],focusAt(offset,end=offset){
      const lo=Math.min(offset,end),hi=Math.max(offset,end);let nearest=null,distance=Infinity;
      model.rows.forEach((row,r)=>row.forEach((cell,c)=>{if(cell.start===null)return;const d=lo<cell.start?cell.start-lo:lo>cell.end?lo-cell.end:0;if(d<distance){distance=d;nearest={row:r,column:c,cell};}}));
      if(!nearest)return false;
      const covered=lo>=nearest.cell.start&&hi<=nearest.cell.end;
      if(offset!==end&&!covered)return false;
      rectangle=null;anchor=null;focus(nearest.row,nearest.column);const input=cellAt().querySelector('textarea');
      const a=clamp(lo-nearest.cell.start,0,input.value.length),z=clamp(hi-nearest.cell.start,0,input.value.length);
      input.setSelectionRange(a,z,end<offset?'backward':'forward');sourceSelection(input);return covered;
    },update(next){const nextModel=parse(next);if(!nextModel)return;raw=next;model=nextModel;render();},getRaw:()=>raw,getSelection:()=>({...selected()}),select(top,left,bottom=top,right=left){anchor={row:top,column:left};active={row:top,column:left};rectangle={top:clamp(Math.min(top,bottom),0,model.rows.length-1),bottom:clamp(Math.max(top,bottom),0,model.rows.length-1),left:clamp(Math.min(left,right),0,model.columns-1),right:clamp(Math.max(left,right),0,model.columns-1)};paint();},destroy(){destroyed=true;document.removeEventListener('sima:menu-language',localizeToolbar);closeMenu();dragCleanup?.();container.removeEventListener('keydown',keydown);container.removeEventListener('copy',copy);container.removeEventListener('cut',cut);container.removeEventListener('paste',paste);container.removeEventListener('click',clickLink);document.removeEventListener('pointerup',pointerup);}};
  }
  global.SimaTables={parse,splitRow,serialize,setCell,operate,parseTSV,copyRectangle,pasteRectangle,normalizeWidths,changeWidths,create,mount};
  if(typeof module!=='undefined'&&module.exports)module.exports=global.SimaTables;
})(typeof window!=='undefined'?window:globalThis);
