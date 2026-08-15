import Keyv from 'keyv';
import KeyvRedis from '@keyv/redis';
import { logger } from './logger.js';

let _store = null;

function getStore() {
  if (_store) return _store;
  if (process.env.REDIS_URI) {
    const redis = new KeyvRedis(process.env.REDIS_URI);
    _store = new Keyv({ store: redis, namespace: 'scraper' });
    logger.info('Scraper cache: Redis');
  } else {
    _store = new Keyv({ namespace: 'scraper' });
    logger.warn('Scraper cache: in-memory (set REDIS_URI for production)');
  }
  _store.on('error', err => logger.error(`Cache error: ${err.message}`));
  return _store;
}

export async function cacheHas(key) {
  const store = getStore();
  const hit = await store.get(key);
  return hit !== undefined;
}

export async function cacheWrap(key, loader, ttlSeconds = 3600) {
  const store = getStore();
  const hit = await store.get(key);
  if (hit !== undefined) return { value: hit, cached: true };
  const value = await loader();
  const isEmpty = Array.isArray(value) && value.length === 0;
  if (!isEmpty) {
    await store.set(key, value, ttlSeconds * 1000);
  }
  return { value, cached: false };
}
