# AI 도서 입력·대화형 추천 연결 안내

기존 GitHub Pages 화면과 Supabase 로그인을 유지합니다. AI·도서 검색 요청은 `bookit-ai` Edge Function에서 처리하며, 아래의 키는 GitHub 코드나 브라우저에 넣지 않습니다.

## 1. 서버 키 등록

발급한 키 값은 채팅으로 보내지 말고 [이 프로젝트의 Supabase Secrets](https://supabase.com/dashboard/project/owxdsbilstkybwsmnizh/functions/secrets)에 직접 등록하세요.

| Name | Value | 필요한 기능 |
| --- | --- | --- |
| `OPENAI_API_KEY` | OpenAI에서 발급한 API 키 | 표지의 제목·저자 읽기, 대화 조건 분석·후보 정렬 |
| `GOOGLE_BOOKS_API_KEY` | Books API가 활성화된 Google Cloud 프로젝트의 API 키 | 실제 도서 검색, ISBN·출판사·분류·소개·쪽수 조회 |
| `OPENAI_MODEL` | 선택 사항: `gpt-4.1-mini` | 생략하면 코드의 기본 모델 사용 |

1. [OpenAI API 키](https://platform.openai.com/api-keys)를 발급하고 API 사용 가능 상태와 프로젝트 사용 한도를 확인합니다.
2. [Google Books 공식 키 발급 안내](https://developers.google.com/books/docs/v1/using#APIKey)에 따라 Google Cloud 프로젝트에서 Books API를 활성화하고 API 키를 발급합니다. 운영 키에는 Books API 제한을 적용하세요.
3. 위 Supabase Secrets 화면에서 Name과 실제 Value를 추가하고 **Save**를 누릅니다. 등록된 비밀 값을 화면·코드·스크린샷으로 공유하지 마세요.
4. 사이트에서 다시 시도합니다. Supabase는 새 Secrets를 함수에 반영하므로 브라우저 코드에 키를 추가하거나 GitHub Pages를 다시 배포할 필요가 없습니다. [공식 Secrets 안내](https://supabase.com/docs/guides/functions/secrets)

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`는 호스팅된 함수의 플랫폼 환경 변수로 사용합니다. 관리자 키를 복사해 브라우저 설정에 넣지 마세요. 관리자 권한은 호출 제한 RPC에만 사용하고, 후보 조회는 검증한 사용자 JWT로 요청합니다.

키가 없거나 올바르지 않아도 기존 책 등록·수정·검색·관심목록·교환과 기존 맞춤 추천은 유지됩니다. 신규 AI 기능은 설정 안내를 보여주며 가짜 결과를 생성하지 않습니다. OpenAI 키와 도서 검색 키가 준비되지 않았으면 사진 분석을 먼저 호출하지 않습니다.

## 2. 사진 기반 입력 동작

- 원본 사진은 기존 업로드 검증·압축·미리보기·삭제 기능을 그대로 사용합니다.
- AI는 사진에서 제목·저자만 읽습니다. ISBN·출판사·분류·소개·쪽수는 Google Books 응답에서만 가져옵니다. 도서 소개는 조회된 소개를 짧게 잘라 사용하며, 없으면 빈칸입니다.
- 후보가 한 권이어도 사용자가 선택하고 **선택한 도서 정보로 채우기**를 눌러야 적용됩니다. 기존 제목·저자·소개가 있으면 덮어쓰기 확인을 받습니다.
- 책 상태·상태 설명·교환 조건·연락처·교환 방식·희망 분야·지역·분위기는 자동 입력으로 바뀌지 않습니다.
- 자동 입력 뒤 확인란에 체크해야 등록할 수 있습니다. 변경된 도서 정보·표지·확인 상태도 계정별 임시 저장으로 복원됩니다.
- 사진을 바꾸면 이전 사진의 검색 결과를 적용하지 않습니다. API 실패 시 기존 폼 내용은 유지하고 재시도·직접 입력을 제공합니다.

## 3. 등록 매물 기반 추천 동작

- 기존 추천 목록 위에 AI 대화 영역을 추가했습니다. 두 영역을 구분해 표시하며 기존 추천 알고리즘은 유지합니다.
- 사용자의 메시지와 구조화된 현재 조건을 서버에서 분석합니다. 필수 조건과 선호 조건을 분리하며, 이미 아는 정보는 다시 묻지 않고 필요한 질문을 한 번에 하나만 표시합니다.
- 지역·분위기·쪽수·교환 방식 등 등록된 값이 없는 항목은 필수 조건을 만족한다고 간주하지 않습니다. 대략적인 교환 지역은 공개 정보이며 상세 주소는 입력하지 않도록 안내합니다.
- DB에서 `status='available'`이고 본인 소유가 아닌 매물만 검색합니다. 필수 조건은 SQL에서 적용하고, 선호 조건으로 후보를 정렬해 최대 24권만 AI에 전달합니다.
- AI는 후보 ID와 제한된 추천 이유 코드만 반환합니다. 후보 밖 ID·중복 ID는 거부합니다. 최종 표시 직전에 DB를 다시 조회하고 상태·필수 조건을 재검사합니다.
- 링크·표지·상태·등록자·책 정보는 DB 값으로 렌더링합니다. 추천 이유도 실제 등록 값과 맞는 코드만 사용합니다. 사진·연락처·수락 후 작성한 비공개 교환 메모는 AI 후보에 포함하지 않습니다.
- 결과가 없으면 실제 검색 결과가 없다고 알리고, 사용자가 선택한 필수 조건 하나를 선호로 바꾸는 버튼을 제공합니다. 조건은 자동으로 느슨해지지 않습니다.
- AI 대화는 현재 탭 메모리에만 유지하며 로그아웃·계정 변경 시 분리됩니다. 서버 DB에는 대화나 사진을 저장하지 않습니다. AI 서비스로의 전송은 화면에 안내합니다.

## 4. DB·서버 적용 및 유지보수

- 운영 DB에 추가할 변경은 `ai-migration.sql`입니다. `schema.sql`은 새 프로젝트 초기화용이며, 기존 운영 DB에 다시 실행하지 않습니다.
- `ai-migration.sql`: 도서 부가정보, 원자적 책 저장 래퍼, 실제 매물 후보 검색, 서버 전용 호출 제한을 추가합니다. 기존 책·프로필·연락처·교환 데이터는 변경하지 않습니다. 기존 `bookit_write`는 유지하며 이전 클라이언트의 수정도 부가정보를 지우지 않습니다.
- `bookit_book_info`는 공개 도서 정보만 담고 RLS를 적용합니다. 쓰기는 기존 소유권·등록 상태 검사를 재사용하는 `bookit_write_book` RPC에서 원자적으로 처리합니다.
- `bookit_private.ai_usage`는 RLS와 권한 회수로 클라이언트 접근을 막습니다. `bookit_ai_consume`은 서버의 `service_role`만 실행할 수 있습니다. 계정별·전체 호출량을 DB 잠금과 함께 검사·증가시켜 여러 함수 인스턴스에서도 제한을 유지합니다.
- 기본 계정별 제한: 사진 분당 1회/시간당 5회/하루 20회, 직접 도서 검색 분당 3회/시간당 20회/하루 50회, 대화 분당 3회/시간당 12회/하루 40회입니다. 각 작업의 서비스 전체 제한은 분당 12회/시간당 80회/하루 200회입니다. 대화 한 번에는 최대 두 번의 모델 요청이 있을 수 있습니다. 이는 요청 수 제한이며 금액 한도는 공급자 프로젝트에서도 별도로 설정해야 합니다.
- 후보 조회·권한·제한·외부 API 실패는 분리된 오류로 처리합니다. 프롬프트나 메시지를 SQL·코드·도구 지시로 실행하지 않습니다. 모델에는 API 키를 전달하지 않습니다.

소스 수정 후 `node scripts/build-ai.mjs`를 실행하면 `supabase/functions/bookit-ai/handler.js`와 `index.ts`를 생성합니다. 서버 파일은 `dist/`에 포함하지 않습니다. Supabase 함수 편집기의 같은 두 파일을 갱신해 배포하거나, CLI가 준비된 환경에서 `supabase functions deploy bookit-ai --project-ref owxdsbilstkybwsmnizh`를 사용할 수 있습니다. 현재 프로젝트의 게이트웨이 JWT 확인을 유지하며, 함수에서도 매 요청마다 Supabase Auth로 사용자 토큰을 다시 검증합니다. 기존 로그인 방식은 바꾸지 않습니다.

## 5. 검증 명령과 한계

- 다운로드 소스 폴더: `npm run check` — 기존 기능 및 새 AI 계약·추천 ID·입력·오류·비밀값 분리 테스트.
- `node ai-test.mjs` — 실제 API 키나 유료 호출 없이 주입한 모의 응답으로 외부 API 경계를 확인합니다.
- `ai-db-test.sql` — PostgreSQL의 원자적 저장, 기존 클라이언트 호환, 실제 매물 조건 검색, 소유권·개인정보, 서버 전용 호출 제한을 검증합니다. 모든 테스트 계정·책·카운터 변경은 마지막 `ROLLBACK`으로 취소합니다.
- 브라우저 검증은 로컬 모의 도서 API·AI 응답과 운영 서버의 설정 오류 경로를 구분합니다. **실제 사진 인식 정확도와 실제 모델 응답 품질은 유효한 키 등록 후 확인해야 합니다.**

공식 API 참고: [OpenAI 이미지 입력](https://developers.openai.com/api/docs/guides/images-vision), [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses), [Google Books 도서 정보](https://developers.google.com/books/docs/v1/reference/volumes).
