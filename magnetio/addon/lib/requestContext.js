import { AsyncLocalStorage } from 'node:async_hooks';

const storage = new AsyncLocalStorage();

/**
 * Run a callback within a request context that carries the client IP.
 */
export function runWithClientIp(ip, fn) {
  return storage.run({ clientIp: ip }, fn);
}

/**
 * Retrieve the client IP from the current async context.
 * Returns undefined if called outside a request context.
 */
export function getClientIp() {
  return storage.getStore()?.clientIp;
}
