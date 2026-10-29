const ALLOWED = new Set(['image/jpeg', 'image/png', 'image/webp']);
const MAX_FILE_SIZE = 2 * 1024 * 1024;

function dataUrl(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error('사진을 읽지 못했어요. 다른 파일을 선택해주세요.'));
    reader.readAsDataURL(blob);
  });
}

async function decode(file) {
  if (typeof createImageBitmap === 'function') return createImageBitmap(file);
  const url = URL.createObjectURL(file);
  try {
    const image = new Image();
    image.src = url;
    await image.decode();
    return image;
  } finally {
    URL.revokeObjectURL(url);
  }
}

function encode(canvas, quality) {
  return new Promise((resolve, reject) => canvas.toBlob(blob => {
    if (blob) resolve(blob);
    else reject(new Error('사진을 압축하지 못했어요. 다른 사진으로 시도해주세요.'));
  }, 'image/webp', quality));
}

export async function prepareImage(file, {maxEdge = 1000, maxBytes = 300 * 1024} = {}) {
  if (!file) return '';
  if (!ALLOWED.has(file.type)) throw new Error('JPG, PNG, WebP 파일을 선택해주세요.');
  if (file.size > MAX_FILE_SIZE) throw new Error('사진은 2MB 이하로 선택해주세요.');
  let image;
  try { image = await decode(file); }
  catch { throw new Error('올바른 이미지 파일이 아니에요.'); }
  const width = image.width || image.naturalWidth;
  const height = image.height || image.naturalHeight;
  try {
    if (!width || !height || width * height > 40000000) throw new Error('사진 해상도가 너무 커요. 더 작은 사진을 선택해주세요.');
    // Small images retain their original bytes and quality.
    if (Math.max(width, height) <= maxEdge && file.size <= maxBytes) return await dataUrl(file);
    const canvas = document.createElement('canvas');
    const context = canvas.getContext('2d');
    if (!context) throw new Error('이 브라우저에서 사진을 처리하지 못했어요.');
    let ratio = Math.min(1, maxEdge / Math.max(width, height));
    for (let pass = 0; pass < 5; pass++) {
      canvas.width = Math.max(1, Math.round(width * ratio));
      canvas.height = Math.max(1, Math.round(height * ratio));
      context.imageSmoothingQuality = 'high';
      context.drawImage(image, 0, 0, canvas.width, canvas.height);
      for (const quality of [0.82, 0.68, 0.52]) {
        const blob = await encode(canvas, quality);
        if (blob.size <= maxBytes) return await dataUrl(blob);
      }
      ratio *= 0.75;
    }
    throw new Error('사진 용량을 줄이지 못했어요. 다른 사진을 선택해주세요.');
  } finally {
    image.close?.();
  }
}
