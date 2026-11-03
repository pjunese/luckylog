'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createNearbySearch, APP_IDS } = require('../nearby_search');
class HttpsError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
function fixture({ used = 0, fail = false } = {}) {
  const calls = [];
  const writes = [];
  const db = {
    doc: path => ({ path }),
    runTransaction: fn => fn({
      getAll: async (...refs) => refs.map(() => ({ data: () => ({
        count: used, expiresAt: { toMillis: () => Date.now() + 60000 },
      }) })),
      set: (ref, data) => writes.push({ ref, data }),
    }),
  };
  const http = { get: async (url, options) => {
    calls.push({ url, options });
    if (fail) throw new Error('simulated upstream credentials must not escape');
    return { data: { documents: [{ place_name: 'Store', road_address_name: 'Road',
      distance: '120', y: '37.57', x: '126.98', place_url: 'http://place.map.kakao.com/123' }] } };
  } };
  const search = createNearbySearch({ db, http, key: () => 'fixture-server-key', HttpsError });
  const request = { app: { appId: [...APP_IDS][0] }, auth: { uid: 'test-user' },
    data: { latitude: 37.5665, longitude: 126.978 } };
  return { search, request, calls, writes };
}
test('rejects missing or unrecognized App Check identity before upstream access', async () => {
  const f = fixture();
  for (const app of [undefined, { appId: 'untrusted-app' }]) {
    await assert.rejects(f.search({ ...f.request, app }), { code: 'unauthenticated' });
  }
  assert.equal(f.calls.length, 0);
  assert.equal(f.writes.length, 0);
});
test('rejects invalid coordinates before upstream access', async () => {
  const f = fixture();
  for (const latitude of [NaN, 31, 41, '37.5']) {
    await assert.rejects(f.search({ ...f.request, data: { latitude, longitude: 127 } }), { code: 'invalid-argument' });
  }
  assert.equal(f.calls.length, 0);
});
test('keeps the server key in the upstream authorization header and returns bounded public fields', async () => {
  const f = fixture();
  const result = await f.search(f.request);
  assert.equal(f.calls[0].options.headers.Authorization, 'KakaoAK fixture-server-key');
  assert.equal(f.calls[0].options.maxRedirects, 0);
  assert.equal(f.calls[0].options.params.size, 15);
  assert.equal(f.writes.length, 2);
  assert.deepEqual(result.places[0], { name: 'Store', address: 'Road', distance: 120,
    lat: 37.57, lng: 126.98, url: 'https://place.map.kakao.com/123' });
  assert.equal(JSON.stringify(result).includes('fixture-server-key'), false);
});
test('rejects requests above the per-user rate limit before upstream access', async () => {
  const f = fixture({ used: 30 });
  await assert.rejects(f.search(f.request), { code: 'resource-exhausted' });
  assert.equal(f.calls.length, 0);
});
test('does not expose upstream errors or credentials to clients', async () => {
  const f = fixture({ fail: true });
  await assert.rejects(f.search(f.request), error => error.code === 'unavailable'
    && !error.message.includes('credentials') && !error.message.includes('fixture-server-key'));
});
