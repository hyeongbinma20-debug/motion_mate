// Public catalogue only. No session, contact, request, or token is cached here.
export const projectUrl = 'https://owxdsbilstkybwsmnizh.supabase.co';
export const publicKey = 'sb_publishable_AeyQcP9L6hYo_2atiJLsrg_w5OgfbB_';
export async function deadline(task, ms = 15000) {
  let timer;
  try {
    return await Promise.race([task, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('연결이 지연되고 있어요. 잠시 후 다시 시도해주세요.')), ms);
    })]);
  } finally { clearTimeout(timer); }
}
export async function loadCatalog(fetcher = fetch, timeout = 12000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  const read = async (table, query) => {
    const response = await fetcher(`${projectUrl}/rest/v1/${table}?${query}`, {
      headers: {apikey: publicKey}, signal: controller.signal,
    });
    if (!response.ok) throw new Error('공개 책 목록을 불러오지 못했어요. 다시 시도해주세요.');
    const rows = await response.json();
    if (!Array.isArray(rows)) throw new Error('책 목록 응답을 확인할 수 없어요.');
    return rows;
  };
  try {
    const [profiles, books] = await Promise.all([
      read('bookit_profiles', 'select=id,nickname:doc->>nickname,bio:doc->>bio,interests:doc->interests,keywords:doc->>keywords&limit=1000'),
      read('bookit_books', 'select=id,owner,status,created,title:doc->>title,author:doc->>author,description:doc->>description,genre:doc->>genre,condition:doc->>condition,terms:doc->>terms&order=created.desc&limit=1000'),
    ]);
    return {version:2, users:profiles.map(p => ({...p,interests:p.interests||[],keywords:p.keywords||''})),
      books, requests:[]};
  } finally { clearTimeout(timer); }
}
// Account work starts concurrently, but never holds back the public catalogue.
export async function startLoading({catalog, account, onCatalog, onAccount, onError, timeout=15000}) {
  const publicTask = Promise.resolve().then(catalog);
  const publicResult = publicTask.then(onCatalog, error => onError('catalog', error));
  const accountResult = deadline(Promise.resolve().then(() => account(publicTask)), timeout)
    .then(onAccount, error => onError('account', error));
  await Promise.all([publicResult, accountResult]);
}
