// Saving one book must not download every profile, contact and book cover again.
export async function saveBook(client, write, after, book) {
  await write('book', book);
  const next = {...after};
  delete next.syncWarning;
  try {
    const {data: saved, error} = await client.from('bookit_books')
      .select('id,owner,status,created').eq('id', book.id).single();
    if (error) throw error;
    if (!saved || saved.id !== book.id) throw new Error('Missing saved book');
    next.books = after.books.map(b => b.id === saved.id ? {...b, ...saved} : b);
  } catch {
    // The write already succeeded. Retain it in the UI so retrying the form
    // cannot accidentally create a duplicate book after a failed refresh.
    next.syncWarning = '책은 저장됐어요. 최신 상태 확인은 목록 새로고침을 눌러주세요.';
  }
  return next;
}
