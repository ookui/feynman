'use strict';

// Run with node Tests/ListModelTests.cjs. Use the exact lexer and outline code
// loaded by the app so every expected edit also goes through a fresh parse.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const resources = process.argv[2] ? path.resolve(process.argv[2]) : path.resolve(__dirname,'../Resources');
const marked = require(path.join(resources,'marked.umd.js'));
const context = vm.createContext({marked});
for (const file of ['reader-list-model.js','reader-list.js']) {
  vm.runInContext(fs.readFileSync(path.join(resources,file),'utf8'),context);
}
const parse = vm.runInContext('clipboardList',context);
let cases = 0;
function check(value,expected,label) { assert.deepEqual(value,expected,label); cases++; }
function head(outline,text) { return outline.rows.find(row => row.node && row.text === text); }
function move(body,labels,out) {
  const tree = parse(body);
  if (!tree.move(labels.map(text => head(tree,text)),out)) return body;
  return tree.write();
}
function enter(body,label,offset,end=offset) {
  const tree = parse(body), row = head(tree,label);
  const caret = tree.split({row,offset},{row,offset:end},false);
  const result = tree.write();
  return [result,caret.row.offset+caret.offset];
}
function nodes(body) {
  const tree = parse(body);
  return Array.from(tree.rows.filter(row => row.node),row => [row.text,row.parent?.text ?? null]);
}
const compact = '1. 中芯国际\n2. 2. 2. 华虹半导体\n3. - ';
for (const source of [compact,'- [x] 项目\n  - 子项\n\n  补充说明\n\n- 尾项',
  '1. 父项\n\t- 子项\n\n   ```\n   2. 示例\n   ```\n2. 末项','- A\n  1) B\n     - C\n  + D\n- E',
  '3.  父\n    * 子\n      换行\n\n    下一段','0005) 中文','1. A\n2. ','- ![图](x.png)\n- **加粗**']) {
  check(parse(source).write(),source,'无操作往返');
}
const old = parse(compact);
check(old.position(compact.indexOf('华虹')).row.text,'华虹半导体','同一行上的三个标记各自拥有源码范围');
let flattened='1. 中芯国际\n2. 2. 2. 华虹半导体';
flattened=move(flattened,['华虹半导体'],true);
check(flattened,'1. 中芯国际\n2. 2. 华虹半导体','历史同一行重叠退一级');
check(move(flattened,['华虹半导体'],true),'1. 中芯国际\n2. 华虹半导体','再退一级去除空壳且保留正文');
for (const marker of ['-','*','+','1.','1)','9.','99)','999.']) {
  const next = /^\d/.test(marker) ? (Number.parseInt(marker)+1)+marker.at(-1) : marker;
  const body = marker+' 一';
  const [added,caret] = enter(body,'一',1);
  check(added,body+'\n'+next+' ','连续编号 '+marker);
  check(caret,added.length,'光标 '+marker);
  check(move(body,['一'],false),body,'首项无前一兄弟 '+marker);
  const two = added+'二';
  const nested = move(two,['二'],false);
  check(nodes(nested),[['一',null],['二','一']],'缩进 '+marker);
  check(move(nested,['二'],true),two,'退级 '+marker);
}
for (const outer of ['-','*','1.','9)']) {
  const w = ' '.repeat(outer.length+1);
  for (const inner of ['-','+','1.','1)']) {
    const inner2 = /^\d/.test(inner) ? '2'+inner.at(-1) : inner;
    const original = outer+' 父\n'+w+inner+' 子\n'+w+' '.repeat(inner.length+1)+'- 孙\n'+w+inner2+' 弟';
    const lifted = move(original,['子'],true);
    check(nodes(lifted),[['父',null],['子',null],['孙','子'],['弟','子']],'混合层级退级 '+outer+inner);
  }
}
const width = '8. 甲\n9. 乙\n   - 孙\n10. 丙';
check(enter(width,'甲',1)[0],'8. 甲\n9. \n10. 乙\n    - 孙\n11. 丙','9→10 同步移动子树');
check(enter('1. 甲乙\n   - 子\n2. 丙','甲乙',1)[0],'1. 甲\n2. 乙\n   - 子\n3. 丙','中间拆项');
check(enter('1. 甲乙丙','甲乙丙',1,2)[0],'1. 甲\n2. 丙','选区拆项');
check(enter('1. 甲\n   - 子\n2. 丙','甲',1)[0],'1. 甲\n   - 子\n2. \n3. 丙','在后代之后插入同级');
check(enter('- A\n  * B\n  * ','',0)[0],'- A\n  * B\n- ','空子项退一级');
check(enter('- A\n- ','',0)[0],'- A\n\n','空顶层退出');
check(enter('- [x] 完成','[x] 完成',6)[0],'- [x] 完成\n- [ ] ','任务项继承未完成框');
check(move('- 父\n- 子\n  9) 孙\n- 弟',['子','弟'],false),'- 父\n  - 子\n    9) 孙\n  - 弟','选区跟随完整子树');
const paste = parse('1. A\n2. \n3. D');
paste.paste(head(paste,''),0,0,parse('1. B\n   - 子\n2. C'));
check(paste.write(),'1. A\n2. B\n   - 子\n3. C\n4. D','粘贴嵌套列表并顺排');
const join = parse('1. A\n2. B\n   - 子\n3. C');
join.join(head(join,'A'),head(join,'B'));
check(join.write(),'1. AB\n   - 子\n2. C','合并时保留后代');
let long = '1. 第1项';
for (let i=2;i<=110;i++) {
  const previous='第'+(i-1)+'项';
  const [newBody,caret] = enter(long,previous,previous.length);
  check(caret,newBody.length,'光标始终在新增项 '+i);
  long = newBody+'第'+i+'项';
}
check(nodes(long).length,110,'连续 110 项');
check(long.split('\n').every((line,i) => line === (i+1)+'. 第'+(i+1)+'项'),true,'连续输入没有重复编号');

// Reparse after every move. Compare ownership for every node against the
// intended outline, including siblings several levels away from the caret.
let seed = 131;
function random(n) { seed=(Math.imul(seed,1664525)+1013904223)>>>0; return seed%n; }
for (let trial=0;trial<12;trial++) {
  let body = Array.from({length:18},(_,i) => ['-', '*', '+', (i+1)+'.', (i+1)+')'][random(5)]+' 项'+i).join('\n');
  for (let step=0;step<60;step++) {
    const tree=parse(body), heads=tree.rows.filter(row => row.node), row=heads[random(heads.length)];
    const out=!!row.parent && random(3)!==0;
    if (!tree.move([row],out)) continue;
    body=tree.write();
    const expected=Array.from(heads,row=>[row.text,row.parent?.text ?? null]);
    check(nodes(body),expected,'结构操作后再解析 '+trial+'/'+step+'\n'+body);
  }
}

// Exercise the production key/input handlers and splice/undo path with an
// in-memory text field. Geometry and pointer tests live in MacSmoke.
const reader = fs.readFileSync(path.join(resources,'reader.js'),'utf8');
function functionSource(name,until) {
  return reader.slice(reader.indexOf('function '+name+'('),reader.indexOf(until,reader.indexOf('function '+name+'(')+1));
}
vm.runInContext(functionSource('blockValue','function editableSpan')+
  functionSource('handleBlockKey',"\ndocument.addEventListener('keydown'"),context);
context.check = check;
vm.runInContext(`
let state={file:'test',editID:'session'}, activeBlock, blocks;
const changes=[], redo=[];
const classes={add(){},remove(){},toggle(){}};
function mappedBlocks(){return blocks;}
function paragraphBody(edit){return state.body.slice(0,edit.start)+blockValue(edit)+state.body.slice(edit.end);}
function closeBlock(){if(activeBlock)state.body=paragraphBody(activeBlock);activeBlock=null; map();}
function map(){
  blocks=[];
  let at=0;
  for(let t of marked.lexer(state.body)){
    if(t.type==='paragraph' && /^ {0,3}(?:[-+*]|\\d{1,9}[.)])[ \\t]+$/.test(t.raw)) t=marked.lexer(t.raw.trimEnd())[0];
    if(t.type!=='list')continue;
    const raw=t.raw.trimEnd(),start=state.body.indexOf(raw,at);
    at=start+raw.length;at+=state.body.slice(at).match(/^[ \\t]*/)[0].length;
    const roots=listStructure(t,state.body.slice(start,at),start);
    const root={previousElementSibling:map.last};if(map.last)map.last.nextElementSibling=root;
    listRoots.set(root,roots);map.last=root;
    function visit(node){
      const el={};node.root=root;
      const end=node.groups.length ? Math.min(node.end,node.groups[0][0].start) : node.end;
      const text=state.body.slice(node.start,end).replace(/(?:\\n[ \\t]*)+$/,'');
      listParts.set(el,{node,start:node.start,end:node.start+text.length});blocks.push(el);
      node.groups.flat().forEach(visit);
    }
    roots.forEach(visit);
  }
  map.last=null;
}
function field(value,i){
  return {value,selectionStart:i,selectionEnd:i,selectionDirection:'forward',setSelectionRange(a,b){this.selectionStart=a;this.selectionEnd=b;},
    setRangeText(v,a,b){this.value=this.value.slice(0,a)+v+this.value.slice(b);this.setSelectionRange(Math.max(a,this.selectionStart-b+a+v.length),Math.max(a,this.selectionEnd-b+a+v.length));}};
}
function restoreListSelection(sel){
  const el=blocks.findLast(el=>{const s=listParts.get(el);return s.start<=sel.start && sel.start<=s.end;});
  const part=listParts.get(el),node=part?.node;
  const start=part?.start ?? sel.start,end=part?.end ?? sel.start, prefix=node?.prefix ?? '';
  const value=state.body.slice(start+prefix.length,end), i=Math.max(0,sel.start-start-prefix.length);
  activeBlock={start,end,tag:node?'LI':'DIV',list:node,listPrefix:prefix,acceptMarker:!value.trim(),field:field(value,i),
    holder:{closest:()=>({classList:classes})}};
}
function recordBlockSplice(step){
  closeBlock();
  const body=state.body;
  check(body.slice(step.start,step.start+step.removed.length),step.removed,'保存范围');
  state.body=body.slice(0,step.start)+step.value+body.slice(step.start+step.removed.length);
  changes.push([body,state.body,step]);redo.length=0;
  map();restoreListSelection(step.listAfter);
}
function start(body,at=body.length){state.body=body;activeBlock=null;map();restoreListSelection({start:at,end:at});}
function key(key,shiftKey=false){handleBlockKey({key,shiftKey,preventDefault(){}},activeBlock);}
function type(text){
  const e=activeBlock,f=e.field;
  f.setRangeText(text,f.selectionStart,f.selectionEnd);
  return listInput(e,{});
}
function body(){return paragraphBody(activeBlock);}
function undo(back){
  const step=(back?changes:redo).pop();(back?redo:changes).push(step);
  state.body=step[back?0:1];activeBlock=null;map();restoreListSelection(step[2][back?'listBefore':'listAfter']);
}
const document={execCommand(_c,_u,text){type(text);return true;}};
start('1. 中芯国际');key('Enter');
for(const c of '2. 2. 华虹半导体')type(c);
check(body(),'1. 中芯国际\\n2. 华虹半导体','截图中反复手输 2. 消重');
key('Enter');type('-');
check(body(),'1. 中芯国际\\n2. 华虹半导体\\n- ','只输入短横线时也只写入一个标记');
type(' ');type('圆点');key('Tab');
check(body(),'1. 中芯国际\\n2. 华虹半导体\\n   - 圆点','数字中缩进圆点');
key('Tab',true);key('Enter');type('末项');
check(body(),'1. 中芯国际\\n2. 华虹半导体\\n3. 圆点\\n4. 末项','退出混排后继续编号');
start('9. A\\n10. 甲乙');activeBlock.field.setSelectionRange(1,1);key('Enter');
check(body(),'9. A\\n10. 甲\\n11. 乙','用 Enter 从中间拆开');
undo(true);check(body(),'9. A\\n10. 甲乙','单步撤销');undo(false);check(body(),'9. A\\n10. 甲\\n11. 乙','单步重做');
start('- 项目');key('Enter');type('2027');type('年');check(body(),'- 项目\\n- 2027年','普通数字正文');
key('Enter');type('3.14');check(body(),'- 项目\\n- 2027年\\n- 3.14','小数正文');
key('Enter');type('-');type('5%');check(body(),'- 项目\\n- 2027年\\n- 3.14\\n- -5%','负数正文');
start('- A');key('Enter');key('Tab');type('中文');key('Tab',true);
check(body(),'- A\\n\\n- 中文','空白子项可填写中文后退级');
start('- [x] 完成');key('Enter');check(body(),'- [x] 完成\\n- [ ] ','任务项续写');
start('3.');type('裸编号');check(body(),'3. 裸编号','补齐原始文件里的编号空格');
start('- A');key('Enter',true);type('续行');check(body(),'- A  \\n  续行','Shift+Enter 保留在项内');
`,context);

require(path.join(resources,'SimaQ/editor/render.js'));
const separated='- **重复**\r\n\r\n\r\n- **重复**\r\n  1. 子项\r\n     续行\r\n\r\n-';
const [listBlock]=SimaRender.parse(separated);
const listHTML=SimaRender.renderBlock(listBlock,{editableList:true});
check([...listHTML.matchAll(/data-list-lines="(\d+) (\d+)"/g)].map(match=>match.slice(1)),[
  ['0','1'],['3','4'],['4','6'],['7','8']
],'分隔空行留在项外，嵌套项的续行留在项内，空项拥有自己的范围');
check((listHTML.match(/<strong>重复<\/strong>/g)||[]).length,2,'相同内容各自保留格式');

vm.runInContext(fs.readFileSync(path.join(resources,'text-selection-gesture.js'),'utf8'),context);
const Gesture=vm.runInContext('TextSelectionGesture',context);
const press={button:0,detail:1,clientX:100,clientY:100};
const gesture=new Gesture(press);
check(gesture.isDrag({...press,clientX:103,clientY:102}),false,'轻移保持单击');
check(gesture.isDrag(press),false,'轻移后回到原点保持单击');
check(gesture.shifted,true,'记住发生过轻移，允许收回原生临时选区');
check(gesture.isDrag({...press,clientX:82}),true,'最后一次事件也参与拖选判断');
check(gesture.isDrag(press),true,'拖回起点仍是同一次拖选');
check(Gesture.plainPress(press),true,'普通左键单击');
for(const extra of [{detail:2},{shiftKey:true},{metaKey:true},{altKey:true},{ctrlKey:true},{button:2}])
  check(Gesture.plainPress({...press,...extra}),false,'保留系统的多击或修饰键操作');
console.log(cases+' list checks passed');
