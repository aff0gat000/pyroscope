import http from 'k6/http';
import { sleep, group } from 'k6';

const J11 = __ENV.JVM11_URL || 'http://demo-jvm11:8080';
const J21 = __ENV.JVM21_URL || 'http://demo-jvm21:8080';

export const options = {
  vus: 10,
  duration: '5m',
  thresholds: { http_req_failed: ['rate<0.5'] },
};

function hit(base, path) {
  http.get(`${base}${path}`, { timeout: '5s', tags: { endpoint: path } });
}

export default function () {
  for (const base of [J11, J21]) {
    group(base, () => {
      hit(base, '/health');
      hit(base, '/registry');
      hit(base, '/blocking/on-eventloop?ms=50');
      hit(base, '/blocking/execute-blocking?ms=80');
      hit(base, `/http/client?host=${base.includes('11') ? 'demo-jvm21' : 'demo-jvm11'}&port=8080`);
      hit(base, `/redis/set?k=demo&v=${__VU}-${__ITER}`);
      hit(base, '/redis/get?k=demo');
      hit(base, '/postgres/query');
      hit(base, `/mongo/insert?msg=v${__VU}`);
      hit(base, '/mongo/find');
      hit(base, `/couchbase/upsert?id=k-${__VU}&v=${__ITER}`);
      hit(base, `/couchbase/get?id=k-${__VU}`);
      hit(base, `/kafka/produce?v=k-${__VU}-${__ITER}`);
      hit(base, '/f2f/call?p=ping');
      hit(base, '/framework/future-chain');
      hit(base, '/vault/read?path=secret/data/demo');
    });
  }
  hit(J21, '/vt/sleep?ms=50');
  sleep(0.2);
}
