// Shared browser/server contracts. No credentials, requests or AI prompts here.
export const INFO_SELECT='isbn,publisher,category,page_count,region,moods,trade_methods,wanted_genres,source,source_id';
export const INFO_GENRES=['소설','에세이','인문','자기계발','예술','과학','기타'];
export const MOODS=['따뜻한','잔잔한','유쾌한','긴장감 있는','생각할 거리','슬픈'];
export const TRADE_METHODS=['직거래','택배'];
export const FILTER_FIELDS=['genres','moods','pages','region','methods','offerGenres','keywords'];
export const FILTER_LABELS={genres:'분야',moods:'분위기',pages:'분량',region:'지역',methods:'교환 방식',offerGenres:'제안할 책 분야',keywords:'검색어'};
const text=(v,max)=>typeof v==='string'?v.trim().slice(0,max):'';
const unique=v=>[...new Set(v)];
export function isbnValue(value){
  const isbn=text(value,30).replace(/[\s-]/g,'').toUpperCase();
  if(!isbn)return '';
  if(/^\d{13}$/.test(isbn)&&[...isbn].reduce((sum,n,i)=>sum+Number(n)*(i%2?3:1),0)%10===0)return isbn;
  if(/^\d{9}[\dX]$/.test(isbn)&&[...isbn].reduce((sum,n,i)=>sum+(n==='X'?10:Number(n))*(10-i),0)%11===0)return isbn;
  throw Error('ISBN은 올바른 10자리 또는 13자리 번호로 입력해주세요.');
}
function choice(value,allowed){return unique((Array.isArray(value)?value:typeof value==='string'?value.split(','):[]).filter(x=>allowed.includes(x))).slice(0,7);}
export function normalizeInfo(value={}){
  if(!value||typeof value!=='object'||Array.isArray(value))value={};
  const pages=value.pageCount===''||value.pageCount==null?null:Number(value.pageCount);
  if(pages!==null&&(!Number.isInteger(pages)||pages<1||pages>20000))throw Error('쪽수는 1~20,000 사이의 정수로 입력해주세요.');
  for(const [key,label,max] of [['publisher','출판사',120],['category','도서 분류',200],['region','교환 지역',60]])if(value[key]!=null&&(typeof value[key]!=='string'||value[key].length>max))throw Error(`${label}는 ${max}자 이내로 입력해주세요.`);
  return {isbn:isbnValue(value.isbn),publisher:text(value.publisher,120),category:text(value.category,200),pageCount:pages,region:text(value.region,60),moods:choice(value.moods,MOODS),tradeMethods:choice(value.tradeMethods,TRADE_METHODS),wantedGenres:choice(value.wantedGenres,INFO_GENRES),source:value.source==='google-books'?'google-books':'manual',sourceId:/^[\w-]{1,80}$/.test(value.sourceId||'')?value.sourceId:''};
}
export function infoFromRow(row){
  if(Array.isArray(row))row=row[0];
  if(!row)return normalizeInfo();
  return normalizeInfo({...row,pageCount:row.page_count??row.pageCount,tradeMethods:row.trade_methods??row.tradeMethods,wantedGenres:row.wanted_genres??row.wantedGenres,sourceId:row.source_id??row.sourceId});
}
export function infoFromFields(fields){return normalizeInfo({isbn:fields.infoIsbn,publisher:fields.infoPublisher,category:fields.infoCategory,pageCount:fields.infoPages,region:fields.infoRegion,moods:fields.infoMoods,tradeMethods:fields.infoMethods,wantedGenres:fields.infoWanted,source:fields.infoSource,sourceId:fields.infoSourceId});}
export const INFO_FIELDS=['infoIsbn','infoPublisher','infoCategory','infoPages','infoRegion','infoMoods','infoMethods','infoWanted','infoSource','infoSourceId','aiReviewed'];
export function emptyFilter(){return {genres:[],moods:[],pages:null,region:'',methods:[],offerGenres:[],keywords:''};}
export function normalizeFilter(value={}){
  if(!value||typeof value!=='object'||Array.isArray(value))value={};
  let pages=null;
  if(value.pages!=null){const min=value.pages.min==null?null:Number(value.pages.min),max=value.pages.max==null?null:Number(value.pages.max);if([min,max].some(n=>n!==null&&(!Number.isInteger(n)||n<1||n>20000))||(min!==null&&max!==null&&min>max))throw Error('원하는 분량 범위를 확인해주세요.');if(min!==null||max!==null)pages={min,max};}
  return {genres:choice(value.genres,INFO_GENRES),moods:choice(value.moods,MOODS),pages,region:text(value.region,60),methods:choice(value.methods,TRADE_METHODS),offerGenres:choice(value.offerGenres,INFO_GENRES),keywords:text(value.keywords,60)};
}
export function hasFilter(value,key){const v=value[key];return Array.isArray(v)?v.length>0:!!v;}
export function normalizeState(value={}){if(!value||typeof value!=='object'||Array.isArray(value))value={};return {required:normalizeFilter(value.required),preferred:normalizeFilter(value.preferred),asked:choice(value.asked,FILTER_FIELDS),dismissed:choice(value.dismissed,FILTER_FIELDS),lastQuestion:FILTER_FIELDS.includes(value.lastQuestion)?value.lastQuestion:null};}
export function mergeConditions(state,update){
  const next=normalizeState(state);
  for(const priority of ['required','preferred']){const filters=normalizeFilter(update[priority]);for(const key of FILTER_FIELDS)if(hasFilter(filters,key)){if(priority==='preferred'&&hasFilter(next.required,key))continue;next[priority][key]=filters[key];next.dismissed=next.dismissed.filter(x=>x!==key);if(priority==='required')next.preferred[key]=emptyFilter()[key];}}
  return next;
}
export function relaxCondition(state,key){const next=normalizeState(state);if(FILTER_FIELDS.includes(key)){next.preferred[key]=next.required[key];next.required[key]=emptyFilter()[key];}return next;}
export function filterDescription(filters,key){const value=filters[key];if(key==='pages'&&value)return value.min&&value.max?`${value.min}~${value.max}쪽`:value.min?`${value.min}쪽 이상`:`${value.max}쪽 이하`;return Array.isArray(value)?value.join(' · '):value||'';}
export function matchedReasons(book,state){
  const info=normalizeInfo(book.metadata),genres=unique([...state.required.genres,...state.preferred.genres]),moods=unique([...state.required.moods,...state.preferred.moods]);
  const reasons={};
  if(genres.includes(book.genre))reasons.genre=`찾는 분야인 ${book.genre} 책이에요`;
  const mood=info.moods.filter(m=>moods.includes(m));if(mood.length)reasons.mood=`등록자가 '${mood.join(' · ')}' 분위기로 표시했어요`;
  for(const f of [state.required,state.preferred]){
    if(f.pages&&info.pageCount&&(!f.pages.min||info.pageCount>=f.pages.min)&&(!f.pages.max||info.pageCount<=f.pages.max))reasons.pages=`등록된 분량이 ${info.pageCount}쪽이에요`;
    if(f.region&&info.region.toLowerCase().includes(f.region.toLowerCase()))reasons.region=`등록된 교환 지역은 ${info.region}이에요`;
    const methods=info.tradeMethods.filter(m=>f.methods.includes(m));if(methods.length)reasons.method=`${methods.join(' · ')} 방식으로 교환할 수 있어요`;
    if(info.wantedGenres.some(g=>f.offerGenres.includes(g)))reasons.exchange='내가 제안할 분야를 원하는 매물이에요';
    if(f.keywords&&(book.title+' '+book.author+' '+book.description+' '+info.category).toLowerCase().includes(f.keywords.toLowerCase()))reasons.keyword='검색어가 실제 책 정보에 포함돼요';
  }
  reasons.available='현재 교환 가능한 책이에요';return reasons;
}

export function matchesFilters(book,filters){
  const f=normalizeFilter(filters),m=normalizeInfo(book.metadata);
  return (!f.genres.length||f.genres.includes(book.genre))&&(!f.moods.length||f.moods.every(x=>m.moods.includes(x)))&&(!f.pages||(m.pageCount>0&&(!f.pages.min||m.pageCount>=f.pages.min)&&(!f.pages.max||m.pageCount<=f.pages.max)))&&(!f.region||m.region.toLowerCase().includes(f.region.toLowerCase()))&&(!f.methods.length||f.methods.some(x=>m.tradeMethods.includes(x)))&&(!f.offerGenres.length||f.offerGenres.some(x=>m.wantedGenres.includes(x)))&&(!f.keywords||(book.title+' '+book.author+' '+book.description+' '+m.category).toLowerCase().includes(f.keywords.toLowerCase()));
}
