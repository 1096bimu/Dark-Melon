'use strict';
const items = new Map();
document.querySelectorAll('.photo').forEach(button => {
  const image = button.querySelector('img');
  items.set(Number(button.dataset.index), {src: image.getAttribute('src'), alt: image.alt});
});
const photos = [...items].sort((a,b)=>a[0]-b[0]).map(([,photo])=>photo);
const viewer=document.querySelector('#viewer'), large=document.querySelector('#large'), status=document.querySelector('#status');
let selected=0, request=0;
async function show(index){
  selected=(index+photos.length)%photos.length;
  const photo=photos[selected], token=++request;
  document.querySelector('#counter').textContent=`${selected+1} / ${photos.length}`;
  document.querySelector('#caption').textContent=photo.alt;
  document.querySelector('#original').href=photo.src;
  status.textContent='Loading…';large.hidden=true;
  const next=new Image();next.src=photo.src;
  try{await next.decode();if(token!==request)return;large.src=photo.src;large.alt=photo.alt;large.hidden=false;status.textContent='';}
  catch{if(token===request)status.textContent='Could not load this photo. Try Open original.';}
}
document.querySelectorAll('.photo').forEach(b=>b.addEventListener('click',()=>{viewer.showModal();document.body.classList.add('viewing');show(Number(b.dataset.index));}));
document.querySelector('#close').onclick=()=>viewer.close();
viewer.addEventListener('close',()=>{request++;document.body.classList.remove('viewing');});
document.querySelector('#previous').onclick=()=>show(selected-1);
document.querySelector('#next').onclick=()=>show(selected+1);
viewer.addEventListener('keydown',event=>{if(event.key==='ArrowLeft'||event.key==='ArrowRight'){event.preventDefault();show(selected+(event.key==='ArrowRight'?1:-1));}});
const hdr=matchMedia('(dynamic-range: high)');
function reportHDR(){document.querySelector('#hdr-status').textContent=hdr.matches?'Browser reports HDR display capability':'Browser reports SDR display capability';}
hdr.addEventListener('change',reportHDR);reportHDR();
