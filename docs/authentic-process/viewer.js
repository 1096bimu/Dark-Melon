'use strict';
const stage = document.querySelector('#stage');
const split = document.querySelector('#split');
const alternative = document.querySelector('#alternative');
const loading = document.querySelector('#loading');
let zoom = 1, center = {x:1500,y:1000}, request = 0;
let width = 0, height = 0, scale = 1, x = 0, y = 0;
function render() {
  width = stage.clientWidth; height = stage.clientHeight;
  scale = Math.min(width/3000,height/2000)*zoom;
  const clampCenter = (value, extent, viewport) => viewport/scale >= extent ? extent/2 : Math.max(viewport/scale/2,Math.min(extent-viewport/scale/2,value));
  center.x=clampCenter(center.x,3000,width);center.y=clampCenter(center.y,2000,height);
  x=width/2-center.x*scale;y=height/2-center.y*scale;
  stage.style.setProperty('--x',`${x}px`);stage.style.setProperty('--y',`${y}px`);stage.style.setProperty('--scale',scale);
  document.querySelector('#zoom').value=`${zoom.toFixed(1).replace('.0','')}×`;
}
function setZoom(value, px=width/2, py=height/2) {
  const imageX=(px-x)/scale,imageY=(py-y)/scale;
  zoom=Math.max(1,Math.min(12,value));
  const nextScale=Math.min(width/3000,height/2000)*zoom;
  center={x:imageX-(px-width/2)/nextScale,y:imageY-(py-height/2)/nextScale};render();
}
function setSplit(value){split.value=Math.max(0,Math.min(100,value));stage.style.setProperty('--split',`${split.value}%`);}
split.addEventListener('input',()=>setSplit(Number(split.value)));
document.querySelector('#in').onclick=()=>setZoom(zoom*1.4);
document.querySelector('#out').onclick=()=>setZoom(zoom/1.4);
document.querySelector('#fit').onclick=()=>{zoom=1;center={x:1500,y:1000};setSplit(50);render();document.querySelectorAll('.card').forEach(c=>c.setAttribute('aria-pressed','false'));};
document.querySelector('#fullscreen').onclick=async()=>{try{if(document.fullscreenElement)await document.exitFullscreen();else await document.querySelector('.comparison').requestFullscreen();}catch{loading.textContent='Full screen is unavailable in this browser.';}};
document.addEventListener('fullscreenchange',()=>{document.querySelector('#fullscreen').textContent=document.fullscreenElement?'Exit full screen':'Full screen';render();});
const images = new Map();
for(const n of [1,2]){const image=new Image();image.src=`images/alternative-${n}.jpg`;images.set(n,image);}
async function selectAlternative(n){
  const current=++request;loading.textContent='Loading photograph…';
  try{await images.get(n).decode();if(current!==request)return;
    alternative.src=images.get(n).src;alternative.classList.toggle('registered',n===2);alternative.alt=`Alternative ${n} rendition of the same scene`;
    document.querySelector('#badge').textContent=`Alternative ${n}`;
    document.querySelectorAll('[data-alt]').forEach(b=>b.setAttribute('aria-pressed',String(Number(b.dataset.alt)===n)));loading.textContent='';
  }catch{if(current===request)loading.textContent='Image could not load. Select an alternative to retry.';}
}
document.querySelectorAll('[data-alt]').forEach(b=>b.onclick=()=>selectAlternative(Number(b.dataset.alt)));
const pointers=new Map();let dividerPointer=null;
const position=e=>{const r=stage.getBoundingClientRect();return{x:e.clientX-r.left,y:e.clientY-r.top};};
stage.addEventListener('pointerdown',e=>{if(e.button!==0)return;stage.setPointerCapture(e.pointerId);if(e.target.closest('#divider')){dividerPointer=e.pointerId;return;}pointers.set(e.pointerId,position(e));});
stage.addEventListener('pointermove',e=>{
 const p=position(e);
 if(e.pointerId===dividerPointer){setSplit(p.x/width*100);return;}
 if(!pointers.has(e.pointerId))return;
 const old=pointers.get(e.pointerId);
 if(pointers.size===2){const other=[...pointers.entries()].find(([id])=>id!==e.pointerId)[1];const before=Math.hypot(old.x-other.x,old.y-other.y),after=Math.hypot(p.x-other.x,p.y-other.y);if(before>0)setZoom(zoom*after/before,(old.x+other.x)/2,(old.y+other.y)/2);center.x-=(p.x-old.x)/2/scale;center.y-=(p.y-old.y)/2/scale;}
 else{center.x-=(p.x-old.x)/scale;center.y-=(p.y-old.y)/scale;}
 pointers.set(e.pointerId,p);render();
});
for(const event of ['pointerup','pointercancel','lostpointercapture'])stage.addEventListener(event,e=>{pointers.delete(e.pointerId);if(dividerPointer===e.pointerId)dividerPointer=null;});
stage.addEventListener('wheel',e=>{e.preventDefault();const p=position(e);setZoom(zoom*Math.exp(-e.deltaY*.002),p.x,p.y);},{passive:false});
stage.addEventListener('dblclick',e=>{const p=position(e);setZoom(zoom===1?3:1,p.x,p.y);});
stage.addEventListener('keydown',e=>{if(e.target!==stage)return;const moves={ArrowLeft:[-1,0],ArrowRight:[1,0],ArrowUp:[0,-1],ArrowDown:[0,1]};if(moves[e.key]){e.preventDefault();center.x+=moves[e.key][0]*60/scale;center.y+=moves[e.key][1]*60/scale;render();}else if(['+','=','-'].includes(e.key)){e.preventDefault();setZoom(zoom*(e.key==='-'?1/1.4:1.4));}else if(e.key==='0')document.querySelector('#fit').click();});
const focuses=[{x:.275,y:.55,z:3.7},{x:.275,y:.61,z:3},{x:.30,y:.57,z:5,alt:2},{x:.64,y:.90,z:4},{x:.07,y:.57,z:2.6,alt:2},{x:.505,y:.195,z:4,alt:1}];
document.querySelectorAll('[data-focus]').forEach(button=>button.onclick=()=>{const f=focuses[Number(button.dataset.focus)];if(f.alt)selectAlternative(f.alt);zoom=f.z;center={x:f.x*3000,y:f.y*2000};setSplit(50);render();document.querySelectorAll('.card').forEach(c=>c.setAttribute('aria-pressed',String(c===button)));document.querySelector('.comparison').scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth',block:'start'});});
new ResizeObserver(render).observe(stage);
Promise.all([document.querySelector('.left img').decode(),images.get(1).decode()]).then(()=>{if(!request)loading.textContent='';}).catch(()=>{loading.textContent='Could not load photographs. Reload to retry.';});render();
