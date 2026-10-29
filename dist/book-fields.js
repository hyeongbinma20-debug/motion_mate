export const genreExamples={
  '소설':['추리·미스터리','로맨스','판타지','SF','역사소설','한국소설','외국소설'],
  '에세이':['여행 에세이','일상 에세이','힐링 에세이','시·산문'],
  '인문':['철학','심리학','역사','사회·문화','경제·경영','언어·교육'],
  '자기계발':['습관·시간 관리','취업·진로','대화·관계','공부법','재테크'],
  '예술':['미술','음악','사진','영화','디자인','만화·그래픽노블'],
  '과학':['자연과학','수학','IT·프로그래밍','환경·생태','의학·건강'],
  '기타':[],
};
export const conditionGuides={
  '새 책':'미개봉이거나 읽은 흔적이 거의 없는 책이에요. 보관 중 생긴 흔적이 있다면 아래에 적어주세요.',
  '좋음':'읽기에 깨끗한 책이에요. 밑줄·필기나 작은 흠집이 있다면 구체적으로 알려주세요.',
  '기타':'기본 항목으로 설명하기 어려운 상태라면, 상세 상태에 직접 설명해주세요.',
  '사용감 있음':'읽을 수 있으면서 사용 흔적이 있는 책이에요. 접힘·변색·손상 위치를 알려주세요.',
};
export function validateBookDetails(fields){
  const result={};
  for(const [key,label,max] of [['genreDetail','세부 장르',40],['conditionDetail','상세 상태',300]]){
    const value=fields[key]??'';
    if(typeof value!=='string')throw Error(`${label}를 글자로 입력해주세요.`);
    if([...value].length>max)throw Error(`${label}는 ${max}자 이내로 입력해주세요.`);
    result[key]=value.trim();
  }
  if(fields.genre==='기타'&&!result.genreDetail)throw Error('기타 분야의 세부 장르를 입력해주세요.');
  if(fields.condition==='기타'&&!result.conditionDetail)throw Error('기타 상태의 상세 설명을 입력해주세요.');
  return result;
}

// Legacy exports keep previously cached pages loadable. The current UI has no example selectors.
export const conditionExamples=['밑줄·필기 없음','일부 밑줄·필기 있음','표지에 생활 흠집','모서리 접힘 있음','일부 변색 있음'];
export function addConditionExample(current,example){const next=current.trim()?current.trim()+' / '+example:example;return current.includes(example)||[...next].length>300?current:next;}
