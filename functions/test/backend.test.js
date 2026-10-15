'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { requireAdmin, validNumbers, calcGrade } = require('../backend');
class HttpsError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

test('manual administration rejects anonymous, normal, and forged truthy claims', () => {
  assert.throws(() => requireAdmin({}, HttpsError), { code: 'unauthenticated' });
  for (const admin of [undefined, false, 'true', 1, {}]) {
    assert.throws(() => requireAdmin({ auth: { token: { admin } } }, HttpsError),
      { code: 'permission-denied' });
  }
  assert.doesNotThrow(() => requireAdmin({ auth: { token: { admin: true } } }, HttpsError));
});

test('only six distinct integer lotto numbers count as a game', () => {
  assert.equal(validNumbers([1, 2, 3, 4, 5, 45]), true);
  for (const numbers of [null, '1,2,3,4,5,6', [1, 1, 1, 1, 1, 1], [0, 1, 2, 3, 4, 5],
    [1, 2, 3, 4, 5, 46], [1, 2, 3, 4, 5, 6.5], [1, 2, 3, 4, 5, '6'], [1, 2, 3, 4, 5]]) {
    assert.equal(validNumbers(numbers), false);
  }
  assert.equal(calcGrade([1, 2, 3, 4, 5, 6], 7, [1, 1, 1, 1, 1, 1]), 0);
  assert.equal(calcGrade([1, 2, 3, 4, 5, 6], 7, [1, 2, 3, 4, 5, 7]), 2);
});

test('manualFetchLotto callable enforces claims before fetching any data', async () => {
  const { manualFetchLotto } = require('../index');
  await assert.rejects(manualFetchLotto.run({ data: { round: 1230 } }), { code: 'unauthenticated' });
  await assert.rejects(manualFetchLotto.run({ auth: { uid: 'kakao:1', token: {} },
    data: { round: 1230 } }), { code: 'permission-denied' });
  await assert.rejects(manualFetchLotto.run({ auth: { uid: 'admin', token: { admin: true } },
    data: { round: 1.5 } }), { code: 'invalid-argument' });
});
