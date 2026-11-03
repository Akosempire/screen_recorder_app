/** A file name Chrome's downloads accept: letters, digits and simple punctuation. */
export const safeName = (s) => (s || 'Recording')
  .normalize('NFKD')
  .replace(/\p{M}+/gu, '')
  .replace(/[^\p{L}\p{N} ._(),'-]+/gu, '-')
  .replace(/-{2,}/g, '-')
  .replace(/\s+/g, ' ')
  .replace(/^[\s.-]+|[\s.-]+$/g, '')
  .slice(0, 100) || 'Recording';
