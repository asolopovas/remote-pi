/** Optional explicitly owned HTTPS origin for metadata; never infer upstream. */
export function siteUrl(value) {
  if (typeof value !== "string" || value !== value.trim() || /[\s?#@\\]/.test(value)) return undefined;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || url.pathname !== "/") return undefined;
    if (value !== url.origin && value !== `${url.origin}/`) return undefined;
    return url.origin;
  } catch {
    return undefined;
  }
}
