import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.57.4';
import {saveBook} from './save-book.js';
import {projectUrl,publicKey,loadCatalog} from './catalog.js';

// This is a public browser key; authorization is enforced by database policies.
export const client = createClient(projectUrl,publicKey);
export const legacyKey = 'bookit.demo.v1';
let session;
function check(result) { if(result.error) throw new Error(result.error.message); return result.data; }
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
    requests:requests.map(r=>({id:r.id,from:r.sender,to:r.recipient,target:r.target,offered:r.offered,status:r.status,message:r.message,notes:r.notes,confirmations:r.confirmations,created:r.created,closedReason:r.closed_reason}))};
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
export async function logout() { check(await client.auth.signOut());session=null;return load(); }
export async function verify(email,token){session=check(await client.auth.verifyOtp({email,token,type:'signup'})).session;await ensureProfile();return load();}

// Convert the existing UI's single user action to an explicit server command.
// The server independently validates ownership, state and allowed fields.
export async function sync(before,after) {
  const different=(a,b)=>JSON.stringify(a)!==JSON.stringify(b);
  const priority=r=>r.status==='수락됨'&&before.requests.find(x=>x.id===r.id)?.status==='대기 중'?0:1;
  for(const r of [...after.requests].sort((a,b)=>priority(a)-priority(b))) {
    const old=before.requests.find(x=>x.id===r.id);
    if(!old){await write('propose',r);return load();}
    if(different(old,r)) {
      if(different(old.notes,r.notes))await write('notes',{id:r.id,note:r.notes[currentId()]||''});
      else await write('transition',{id:r.id,action:different(old.confirmations,r.confirmations)?'완료':r.status});
      return load();
    }
  }
  for(const b of after.books)if(different(before.books.find(x=>x.id===b.id),b))return saveBook(client,write,after,b);
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
