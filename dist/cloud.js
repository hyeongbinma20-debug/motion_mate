import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.57.4';
import {saveBook} from './save-book.js';
import {projectUrl,publicKey,loadCatalog} from './catalog.js';
import {recoveryService,authMessage} from './recovery.js';

// This is a public browser key; authorization is enforced by database policies.
export const client = createClient(projectUrl,publicKey);
export const legacyKey = 'bookit.demo.v1';
let session;
let recoveryStorage;try{recoveryStorage=sessionStorage;}catch{recoveryStorage={getItem:()=>null,setItem(){},removeItem(){}};}
const recovery=recoveryService(client,recoveryStorage);
client.auth.onAuthStateChange((event,value)=>{recovery.event(event,value);if(event==='PASSWORD_RECOVERY'){session=value;window.dispatchEvent(new Event('bookit:recovery'));}});
export const canResetPassword=()=>recovery.allowed(currentId());
export const requestPasswordReset=email=>recovery.request(email);
export async function resetPassword(password,confirmation){await recovery.update(currentId(),password,confirmation);check(await client.auth.signOut({scope:'local'}));session=null;return load();}
function check(result) { if(result.error) throw new Error(authMessage(result.error)); return result.data; }
export async function write(action,payload) { check(await client.rpc('bookit_write',{action,payload})); }
export async function init() { session=check(await client.auth.getSession()).session; return load(); }
export function currentId() { return session?.user.id || null; }
export async function load(catalog) {
  const signed=!!session;
  const [publicData,requests,contacts]=await Promise.all([
    catalog || loadCatalog(),
    signed?client.from('bookit_requests').select('*').order('created',{ascending:false}).limit(1000).then(check):[],
    signed?client.from('bookit_contacts').select('*').limit(1000).then(check):[],
  ]);
  const contactFor=id=>{const c=contacts.find(c=>c.id===id);return c?{contact:c.value,method:c.method}:{};};
  return {version:2,users:publicData.users.map(p=>({...p,...contactFor('profile:'+p.id),...(p.id===currentId()?{email:session.user.email}:{})})),
    books:publicData.books.map(b=>({...b,...contactFor(b.id)})),
    requests:requests.map(r=>({id:r.id,from:r.sender,to:r.recipient,target:r.target,offered:r.offered,status:r.status,message:r.message,notes:r.notes,confirmations:r.confirmations,created:r.created,closedReason:r.closed_reason,cancellations:r.cancellations||[]}))};
}
async function ensureProfile() {
  const p=check(await client.from('bookit_profiles').select('id').eq('id',currentId()).maybeSingle());
  if(!p)await write('profile',{nickname:(session.user.user_metadata.nickname||'새로운 독자').slice(0,20),bio:'',avatar:'',interests:[],keywords:'',method:'이메일',contact:session.user.email});
}
export async function login(email,password) { session=check(await client.auth.signInWithPassword({email,password})).session; await ensureProfile(); return load(); }
export async function signup(email,password,nickname) {
  const result=check(await client.auth.signUp({email,password,options:{data:{nickname},emailRedirectTo:'https://hyeongbinma20-debug.github.io/motion_mate/'}}));
  session=result.session;
  if(session){await ensureProfile();return load();}
  return null;
}
export async function logout() { check(await client.auth.signOut());recovery.clear();session=null;try{return await load();}catch{return {version:2,users:[],books:[],requests:[],loadWarning:'로그아웃은 완료됐어요. 목록 새로고침으로 책을 다시 불러와주세요.'};} }
export async function verify(email,token){session=check(await client.auth.verifyOtp({email,token,type:'signup'})).session;await ensureProfile();return load();}

// Convert the existing UI's single user action to an explicit server command.
// The server independently validates ownership, state and allowed fields.
export async function sync(before,after) {
  const different=(a,b)=>JSON.stringify(a)!==JSON.stringify(b);
  for(const b of after.books){const previous=before.books.find(x=>x.id===b.id);if(previous&&((previous.status==='available'&&b.status==='archived')||(previous.status==='archived'&&b.status==='available'))){await write(b.status==='archived'?'archive':'restore',{id:b.id});return load();}}
  const priority=r=>r.status==='수락됨'&&before.requests.find(x=>x.id===r.id)?.status==='대기 중'?0:1;
  for(const r of [...after.requests].sort((a,b)=>priority(a)-priority(b))) {
    const old=before.requests.find(x=>x.id===r.id);
    if(!old){await write('propose',r);return load();}
    if(different(old,r)) {
      if(different(old.cancellations||[],r.cancellations||[])){const previous=old.cancellations||[],next=r.cancellations||[];await write('transition',{id:r.id,action:next.length>previous.length?'합의 취소':previous.includes(currentId())?'취소 철회':'취소 거절'});}
      else if(different(old.notes,r.notes))await write('notes',{id:r.id,note:r.notes[currentId()]||''});
      else await write('transition',{id:r.id,action:different(old.confirmations,r.confirmations)?'완료':r.status});
      return load();
    }
  }
  for(const b of after.books)if(different(before.books.find(x=>x.id===b.id),b)){
    const previous=before.books.find(x=>x.id===b.id);
    if(previous&&previous.status!==b.status){await write(b.status==='archived'?'archive':'restore',{id:b.id});return load();}
    return saveBook(client,write,after,b);
  }
  for(const b of before.books)if(!after.books.some(x=>x.id===b.id)){await write('delete',{id:b.id});return load();}
  const p=after.users.find(x=>x.id===currentId());
  if(p&&different(before.users.find(x=>x.id===p.id),p))await write('profile',p);
  return load();
}
export function legacyBooks(){try{const d=JSON.parse(localStorage.getItem(legacyKey));const owner=localStorage.getItem('bookit.session');return (d?.books||[]).filter(b=>b.owner===owner&&b.status==='available'&&!/^b\d+$/.test(b.id));}catch{return [];}}
export async function importLegacy(selected,data){
  const mine=data.users.find(u=>u.id===currentId());
  for(const b of legacyBooks().filter(b=>selected.includes(b.id))){
    const id='import-'+currentId()+'-'+b.id;
    if(data.books.some(x=>x.id===id))continue;
    await write('book',{...b,id,method:mine.method||'이메일',contact:mine.contact||session.user.email});
  }
  return load();
}
export async function resume(catalogTask=loadCatalog()) {
  const [auth,catalog]=await Promise.all([client.auth.getSession(),catalogTask]);
  session=check(auth).session;
  if(session&&!catalog.users.some(p=>p.id===currentId())){await ensureProfile();return load();}
  return load(catalog);
}
