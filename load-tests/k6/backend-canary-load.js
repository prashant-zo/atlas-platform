import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 20 },
    { duration: '5m', target: 20 }, 
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<200'],
  },
};

const BACKEND_URL = __ENV.BACKEND_URL || 'http://ingress-nginx-controller.ingress-nginx.svc:80/';
const HOST_HEADER = __ENV.HOST_HEADER || 'backend.atlas.local';

export default function () {
  const res = http.get(BACKEND_URL, {
    headers: { Host: HOST_HEADER },
    tags:    { name: 'backend-get' },
  });

  check(res, {
    'status is 200': (r) => r.status === 200,
    'response has version': (r) => r.body && r.body.includes('version'),
  });

  sleep(0.2);
}
