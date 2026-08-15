import { createClient } from 'redis';
import { logger } from './logger.js';

let client = null;
let enabled = false;

const PREFIX = 'magnetio:stats';

async function getClient() {
  if (client) return client;
  if (!process.env.REDIS_URI) return null;

  try {
    client = createClient({ url: process.env.REDIS_URI });
    client.on('error', err => logger.debug(`Analytics redis error: ${err.message}`));
    await client.connect();
    enabled = true;
    return client;
  } catch (err) {
    logger.debug(`Analytics disabled: ${err.message}`);
    return null;
  }
}

function todayKey() {
  return new Date().toISOString().slice(0, 10);
}

export async function trackRequest(type, configHash) {
  const redis = await getClient();
  if (!redis) return;

  const day = todayKey();
  try {
    await Promise.all([
      redis.incr(`${PREFIX}:requests:${day}`),
      redis.incr(`${PREFIX}:requests:total`),
      redis.incr(`${PREFIX}:${type}:${day}`),
      redis.pfAdd(`${PREFIX}:users:${day}`, configHash),
      redis.pfAdd(`${PREFIX}:users:total`, configHash),
    ]);
  } catch {
    // analytics are best-effort, never block requests
  }
}

export async function getStats() {
  const redis = await getClient();
  if (!redis) return { enabled: false };

  const day = todayKey();
  try {
    const [
      totalRequests,
      todayRequests,
      todayStreams,
      todayCatalogs,
      todaySubtitles,
      todayPages,
      totalUsers,
      todayUsers,
    ] = await Promise.all([
      redis.get(`${PREFIX}:requests:total`),
      redis.get(`${PREFIX}:requests:${day}`),
      redis.get(`${PREFIX}:stream:${day}`),
      redis.get(`${PREFIX}:catalog:${day}`),
      redis.get(`${PREFIX}:subtitle:${day}`),
      redis.get(`${PREFIX}:page:${day}`),
      redis.pfCount(`${PREFIX}:users:total`),
      redis.pfCount(`${PREFIX}:users:${day}`),
    ]);

    const last7 = [];
    for (let i = 0; i < 7; i++) {
      const d = new Date();
      d.setDate(d.getDate() - i);
      const key = d.toISOString().slice(0, 10);
      const [reqs, users] = await Promise.all([
        redis.get(`${PREFIX}:requests:${key}`),
        redis.pfCount(`${PREFIX}:users:${key}`),
      ]);
      last7.push({ date: key, requests: parseInt(reqs || '0', 10), users });
    }

    return {
      enabled: true,
      total: {
        requests: parseInt(totalRequests || '0', 10),
        uniqueUsers: totalUsers,
      },
      today: {
        date: day,
        requests: parseInt(todayRequests || '0', 10),
        uniqueUsers: todayUsers,
        streams: parseInt(todayStreams || '0', 10),
        catalogs: parseInt(todayCatalogs || '0', 10),
        subtitles: parseInt(todaySubtitles || '0', 10),
        pages: parseInt(todayPages || '0', 10),
      },
      last7days: last7,
    };
  } catch (err) {
    return { enabled: true, error: err.message };
  }
}
