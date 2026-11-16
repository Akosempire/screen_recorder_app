// Pages Chrome never lets an extension record or draw on: browser settings,
// the new tab page, other extensions and the extension stores.
export function isRestrictedUrl(url = '') {
  return /^(chrome|edge|brave|opera|vivaldi|about|chrome-extension|devtools|view-source|chrome-search):/i.test(url)
    || /^https:\/\/(chromewebstore\.google\.com|chrome\.google\.com\/webstore|microsoftedge\.microsoft\.com\/addons)/i.test(url);
}
