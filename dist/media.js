import {projectUrl,publicKey} from './catalog.js';
const cache=new Map();
let observer;
export function clearMedia(){cache.clear();}
export function preloadMedia(kind,ids){
  const pending=[...new Set(ids)].filter(id=>typeof id==='string'&&/^[\w-]{1,160}$/.test(id)&&!cache.has(kind+':'+id));
  for(let offset=0;offset<pending.length;offset+=24){
    const batch=pending.slice(offset,offset+24),controller=new AbortController(),timer=setTimeout(()=>controller.abort(),20000);
    const field=kind==='book'?'cover':'avatar',table=kind==='book'?'bookit_books':'bookit_profiles';
    const query=new URLSearchParams({select:`id,image:doc->>${field}`,id:'in.('+batch.join(',')+')',limit:String(batch.length)});
    const task=fetch(`${projectUrl}/rest/v1/${table}?${query}`,{headers:{apikey:publicKey},signal:controller.signal}).then(async response=>{if(!response.ok)throw Error('사진을 불러오지 못했어요.');const rows=await response.json();if(!Array.isArray(rows))throw Error('사진 응답을 확인하지 못했어요.');return new Map(rows.map(row=>[row.id,row.image||'']));}).finally(()=>clearTimeout(timer));
    for(const id of batch){const item=task.then(rows=>{if(!rows.has(id))throw Error('사진 정보를 찾을 수 없어요.');return rows.get(id);});item.catch(()=>{});cache.set(kind+':'+id,item);}
  }
}
export function loadMedia(kind,id){
  const key=kind+':'+id;
  if(!cache.has(key))cache.set(key,(async()=>{
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),20000);
    try {
      const field=kind==='book'?'cover':'avatar',table=kind==='book'?'bookit_books':'bookit_profiles';
      const query=new URLSearchParams({select:`image:doc->>${field}`,id:'eq.'+id,limit:'1'});
      const response=await fetch(`${projectUrl}/rest/v1/${table}?${query}`,{headers:{apikey:publicKey},signal:controller.signal});
      if(!response.ok)throw Error('사진을 불러오지 못했어요. 목록 새로고침으로 다시 시도해주세요.');
      const rows=await response.json();
      if(!Array.isArray(rows)||!rows.length)throw Error('사진 정보를 찾을 수 없어요.');
      return rows[0].image||'';
    } finally {clearTimeout(timer);}
  })());
  return cache.get(key);
}
const isPhoto=value=>/^data:image\/(?:png|jpeg|webp);base64,/i.test(value);
function apply(node,kind,value){
  if(!node.isConnected)return;
  if(isPhoto(value)){
    const img=document.createElement('img');img.src=value;img.alt=kind==='book'?'책 표지':'프로필';img.decoding='async';
    if(kind==='book'){node.className='cover photo';node.replaceChildren(img);}
    else{img.className='avatar';node.replaceWith(img);}
  } else if(kind==='book'&&['light','essay','store','fish','sea','art','sapiens','winter'].includes(value)){
    node.className='cover '+value;
  }
}
export function hydrateMedia(root,data){
  observer?.disconnect();
  const hydrate=async node=>{
    const kind=node.dataset.bookCover?'book':'profile',id=node.dataset.bookCover||node.dataset.profileAvatar;
    const model=(kind==='book'?data.books:data.users).find(row=>row.id===id);
    if(!model)return;
    try {const field=kind==='book'?'cover':'avatar',before=model[field];const value=await loadMedia(kind,id);if(model[field]===before)model[field]=value;apply(node,kind,model[field]);}
    catch {if(node.isConnected)node.title='사진을 불러오지 못했어요. 목록 새로고침으로 다시 시도해주세요.';}
  };
  const nodes=root.querySelectorAll('[data-book-cover],[data-profile-avatar]');
  const group=visible=>{for(const kind of ['book','profile'])preloadMedia(kind,visible.filter(node=>kind==='book'?node.dataset.bookCover:node.dataset.profileAvatar).map(node=>node.dataset.bookCover||node.dataset.profileAvatar));visible.forEach(hydrate);};
  if(!('IntersectionObserver' in window)){group([...nodes]);return;}
  observer=new IntersectionObserver(entries=>{const visible=[];for(const entry of entries)if(entry.isIntersecting){observer.unobserve(entry.target);visible.push(entry.target);}group(visible);},{rootMargin:'160px'});
  nodes.forEach(node=>observer.observe(node));
}
