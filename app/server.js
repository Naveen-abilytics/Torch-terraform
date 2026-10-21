'use strict';

const http = require('http');

const PORT = Number(process.env.PORT || 8080);
const SERVICE_NAME = process.env.SERVICE_NAME || 'sample-app';
const STARTED_AT = new Date().toISOString();

// The app's configuration arrives as environment variables that the ECS agent
// resolved from AWS Secrets Manager (see the task definition's `secrets`
// block). Only the names are ever exposed; the values are never logged and
// never returned by an endpoint.
const CONFIG_KEYS = Object.keys(process.env)
  .filter((key) => key.startsWith('APP_'))
  .sort();

const configSource = CONFIG_KEYS.length > 0 ? 'aws-secrets-manager' : 'none';

function health() {
  return {
    status: 'healthy',
    service: SERVICE_NAME,
    started_at: STARTED_AT,
    uptime_seconds: Math.round(process.uptime()),
  };
}

function info() {
  return {
    service: SERVICE_NAME,
    version: '2.0.0',
    runtime: process.version,
    region: process.env.AWS_REGION || 'unknown',
    task: process.env.ECS_TASK_ID || 'unknown',
    started_at: STARTED_AT,
    config: {
      source: configSource,
      // Names only. The values live in Secrets Manager and are not exposed.
      keys: CONFIG_KEYS,
    },
  };
}

function root() {
  return {
    service: SERVICE_NAME,
    // APP_MESSAGE comes from Secrets Manager. It is application copy, not a
    // credential, so showing it proves the injection path works end to end.
    message: process.env.APP_MESSAGE || 'Hello from the sample ECS app.',
    endpoints: ['/', '/health', '/info'],
  };
}

const routes = {
  '/': root,
  '/health': health,
  '/info': info,
};

const server = http.createServer((req, res) => {
  const path = (req.url || '/').split('?')[0];
  const handler = routes[path];

  res.setHeader('content-type', 'application/json');
  res.setHeader('cache-control', 'no-store');

  if (!handler) {
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'not_found', path }, null, 2));
    return;
  }

  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify(handler(), null, 2));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[${SERVICE_NAME}] listening on 0.0.0.0:${PORT}`);
  console.log(
    `[${SERVICE_NAME}] loaded ${CONFIG_KEYS.length} configuration value(s) from ${configSource}: ` +
      (CONFIG_KEYS.length > 0 ? CONFIG_KEYS.join(', ') : '(none)')
  );
});

function shutdown(signal) {
  console.log(`[${SERVICE_NAME}] received ${signal}, shutting down`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
