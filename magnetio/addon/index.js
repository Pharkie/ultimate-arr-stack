import express from 'express';
import swaggerStats from 'swagger-stats';
import { serverless } from './serverless.js';
import { initBestTrackers } from './lib/magnetHelper.js';
import { destroyAllEngines } from './lib/torrentProxy.js';
import { logger } from './lib/logger.js';

const app = express();

app.use(express.json());
app.set('trust proxy', true);

// Prometheus metrics endpoint protected by basic auth
app.use(swaggerStats.getMiddleware({
  swaggerSpec: null,
  authentication: true,
  onAuthenticate: (req, username, password) => {
    return username === (process.env.METRICS_USER || 'admin') &&
           password === (process.env.METRICS_PASSWORD || 'magnetio');
  }
}));

// Serve static files with long-term caching
app.use('/static', express.static('static', { maxAge: '1y' }));

// Main addon routing via serverless handler
app.use('/', serverless);

const PORT = process.env.PORT || 7000;

async function start() {
  await initBestTrackers();
  logger.info('Best trackers initialized');

  const server = app.listen(PORT, () => {
    logger.info(`Magnetio addon running on port ${PORT}`);
  });

  const shutdown = () => {
    logger.info('Shutting down…');
    destroyAllEngines();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 10_000);
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

start();

export default app;
