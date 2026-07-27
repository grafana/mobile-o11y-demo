export function isCollectorRequest(method, requestUrl) {
  if (method !== 'POST') {
    return false;
  }

  const pathname = new URL(requestUrl ?? '/', 'http://localhost').pathname;
  return pathname === '/collect' || pathname.startsWith('/collect/');
}
