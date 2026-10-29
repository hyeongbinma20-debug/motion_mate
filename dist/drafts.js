const prefix='bookit.book-draft.v1:';
const fields=['title','author','genre','genreDetail','condition','conditionDetail','description','terms','method','contact'];
export const draftKey=(user,id='new')=>prefix+encodeURIComponent(user)+':'+encodeURIComponent(id||'new');
export function cleanDraft(values,cover){
  const result={version:1,fields:{}};
  for(const key of fields)if(typeof values[key]==='string')result.fields[key]=values[key];
  if(typeof cover==='string'&&cover.length<=3000000)result.cover=cover;
  return result;
}
export function draftStore(storage){return {
  read(user,id){try{const value=JSON.parse(storage.getItem(draftKey(user,id)));return value?.version===1&&value.fields?cleanDraft(value.fields,value.cover):null;}catch{return null;}},
  write(user,id,value){storage.setItem(draftKey(user,id),JSON.stringify(value));},
  drop(user,id){storage.removeItem(draftKey(user,id));},
  clear(user){const start=prefix+encodeURIComponent(user)+':';for(let i=storage.length-1;i>=0;i--){const key=storage.key(i);if(key?.startsWith(start))storage.removeItem(key);}},
};}
export function clearUserDrafts(user){if(!user)return;try{draftStore(sessionStorage).clear(user);}catch{}}
export function attachBookDraft(form,{user,id,cover,applyCover,onWarning}){
  let storage;try{storage=sessionStorage;}catch{storage={getItem:()=>null,removeItem(){},setItem(){throw Error('storage unavailable');}};}
  const store=draftStore(storage),baseCover=cover();
  const values=()=>Object.fromEntries(fields.map(key=>[key,form.elements.namedItem(key)?.value||'']));
  const base=JSON.stringify(values());let committed=false,lastError=false;
  const dirty=()=>!committed&&(JSON.stringify(values())!==base||cover()!==baseCover);
  const notice=form.querySelector('[data-draft-status]');
  const announce=message=>{if(notice)notice.textContent=message;};
  const restored=store.read(user,id);
  if(restored){for(const [key,value] of Object.entries(restored.fields)){const input=form.elements.namedItem(key);if(input)input.value=value;}if(restored.cover!==undefined)applyCover(restored.cover);announce('이 탭에 임시 저장한 내용을 복원했어요. 저장 버튼을 눌러야 책장에 반영돼요.');}
  const save=()=>{
    if(committed)return true;
    try {
      if(!dirty()){store.drop(user,id);return true;}
      store.write(user,id,cleanDraft(values(),cover()!==baseCover?cover():undefined));
      lastError=false;announce('작성 내용을 이 탭에 임시 저장했어요. 새로고침하거나 돌아와도 이어서 쓸 수 있어요.');return true;
    }catch{if(!lastError)onWarning('임시 저장 공간이 부족하거나 사용할 수 없어요. 작성 화면을 유지했어요. 책 저장을 먼저 완료해주세요.');lastError=true;return false;}
  };
  form.addEventListener('input',save);form.addEventListener('change',save);
  return {save,dirty,finish(){committed=true;try{store.drop(user,id);}catch{}},discard(){committed=true;try{store.drop(user,id);}catch{}}};
}
