export const RECENT_LIMIT=30;
const validId=id=>typeof id==='string'&&/^[\w-]{1,160}$/.test(id);
const ids=values=>[...new Set((Array.isArray(values)?values:[]).filter(validId))];

// Favorites are private account data. The database checks ownership independently.
export function favoriteService(client,account){
  const owner=()=>{const id=account();if(!id)throw Error('로그인하고 관심목록을 이용해주세요.');return id;};
  return {
    async list(){
      const user=owner();
      const result=await client.from('bookit_favorites').select('book_id,created').eq('user_id',user).order('created',{ascending:false}).limit(1000);
      if(result.error||!Array.isArray(result.data))throw Error('관심목록을 불러오지 못했어요. 다시 시도해주세요.');
      return ids(result.data.map(row=>row.book_id));
    },
    async set(id,saved){
      const user=owner();
      if(!validId(id)||typeof saved!=='boolean')throw Error('책 정보를 확인하고 다시 시도해주세요.');
      const table=client.from('bookit_favorites');
      const result=saved?await table.upsert({user_id:user,book_id:id},{onConflict:'user_id,book_id',ignoreDuplicates:true}):await table.delete().eq('user_id',user).eq('book_id',id);
      if(result.error)throw Error(saved?'관심목록에 저장하지 못했어요. 로그인 상태와 책의 교환 가능 여부를 확인해주세요.':'관심 해제에 실패했어요. 다시 시도해주세요.');
    },
  };
}

function cleanRecent(value){
  if(!Array.isArray(value))return [];
  const seen=new Set();
  return value.filter(row=>row&&validId(row.id)&&Number.isFinite(row.viewedAt)&&row.viewedAt>0)
    .sort((a,b)=>b.viewedAt-a.viewedAt).filter(row=>{if(seen.has(row.id))return false;seen.add(row.id);return true;})
    .slice(0,RECENT_LIMIT).map(({id,viewedAt})=>({id,viewedAt}));
}

// Only book IDs and visit times are stored, separately for each account and guests.
export function recentStore(storage){
  const memory=new Map(),unpersisted=new Set();
  const key=user=>'bookit.recent.v1:'+encodeURIComponent(user||'guest');
  const read=user=>{
    const name=key(user);
    if(unpersisted.has(name)||!storage)return cleanRecent(memory.get(name));
    try{const items=cleanRecent(JSON.parse(storage.getItem(name)||'[]'));memory.set(name,items);return items;}catch{return cleanRecent(memory.get(name));}
  };
  const write=(user,value)=>{
    const name=key(user),items=cleanRecent(value);memory.set(name,items);
    try{if(!storage)throw Error();if(items.length)storage.setItem(name,JSON.stringify(items));else storage.removeItem(name);unpersisted.delete(name);return true;}catch{unpersisted.add(name);return false;}
  };
  return {
    key,
    list:read,
    visit(user,id,now=Date.now()){
      if(!validId(id))return true;
      return write(user,[{id,viewedAt:now},...read(user).filter(row=>row.id!==id)]);
    },
    remove:(user,id)=>write(user,read(user).filter(row=>row.id!==id)),
    clear:user=>write(user,[]),
    restore:(user,rows)=>write(user,[...read(user),...cleanRecent(rows)]),
  };
}
