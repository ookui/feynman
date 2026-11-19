'use strict';
const host = document.querySelector('#terminal');
const editor = document.querySelector('#draft'), send = document.querySelector('#send');
const term = new Terminal({fontFamily:'Menlo, monospace',fontSize:13,scrollback:4000,screenReaderMode:true,
  cursorBlink:true,theme:{background:'#20232a',foreground:'#ecedf0',cursor:'#d4def0'}});
const post = (action, args={}) => window.webkit.messageHandlers.console.postMessage({action,...args});
term.open(host);
let started = false, submitted = false;
function fit() {
  const screen=term.element.querySelector('.xterm-screen').getBoundingClientRect();
  if (!screen.width || !screen.height || host.clientWidth<100 || host.clientHeight<40) return;
  const cols=Math.max(10,Math.floor((host.clientWidth-16)/(screen.width/term.cols)));
  const rows=Math.max(4,Math.floor(host.clientHeight/(screen.height/term.rows)));
  if (cols!==term.cols || rows!==term.rows) term.resize(cols,rows);
  post(started?'resize':'ready',{cols,rows});
  started=true;
}
new ResizeObserver(fit).observe(host);
requestAnimationFrame(fit);
function setDraft(text) {
  editor.value=text;
  editor.setSelectionRange(0,0);
  editor.scrollTop=0;
  send.disabled=!text.trim();
  editor.focus();
}
function offerFollowUp() {
  submitted=false;
  const composer=document.querySelector('#composer');
  composer.classList.add('follow-up');
  composer.hidden=false;
  editor.placeholder='输入追问…';
  editor.setAttribute('aria-label','追问当前问题');
  document.querySelector('#hint').textContent='回车发送 · Shift 回车换行 · Esc 结束对话';
  setDraft('');
}
function showExit(message) {
  submitted=true;
  document.querySelector('#composer').hidden=true;
  const exit=document.querySelector('#exit');
  exit.textContent=message+' · 按 Esc 收起终端';
  exit.hidden=false;
}
function submit() {
  if(submitted || !editor.value.trim()) return;
  submitted=true;
  document.querySelector('#composer').hidden=true;
  post('submit',{text:editor.value,cols:term.cols,rows:term.rows});
  term.focus();
}
editor.oninput=()=>{ send.disabled=!editor.value.trim(); };
editor.onkeydown=e=>{
  if(e.key==='Enter' && !e.shiftKey && !e.isComposing && e.keyCode!==229) { e.preventDefault(); submit(); }
};
send.onclick=submit;
function receive(base64) { term.write(Uint8Array.from(atob(base64), c=>c.charCodeAt(0))); }
term.onData(data=>post('input',{data}));
