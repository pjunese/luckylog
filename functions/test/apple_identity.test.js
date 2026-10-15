const test = require('node:test');
const assert = require('node:assert/strict');
const { generateKeyPairSync } = require('node:crypto');
const jwt = require('jsonwebtoken');
const { verifyAppleIdentity } = require('../apple_identity');
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const key = (_header, callback) => callback(null, publicKey);
function token(overrides = {}) {
  return jwt.sign({ sub: 'test-user', iss: 'https://appleid.apple.com',
    aud: 'com.pjunese.lottonote', exp: Math.floor(Date.now() / 1000) + 60,
    ...overrides }, privateKey, { algorithm: 'RS256' });
}
for (const aud of ['com.pjunese.lottonote', 'com.pjunese.lottonote.dev']) {
  test(`accepts signed Apple token for ${aud}`, async () => {
    assert.equal(await verifyAppleIdentity(token({ aud }), key), 'apple:test-user');
  });
}
for (const [label, overrides] of [
  ['foreign app', { aud: 'com.attacker.app' }],
  ['lookalike app', { aud: 'com.pjunese.lottonote.dev.evil' }],
  ['wrong issuer', { iss: 'https://attacker.example' }],
  ['expired token', { exp: 1 }],
  ['missing subject', { sub: '' }],
]) {
  test(`rejects ${label}`, async () => {
    await assert.rejects(verifyAppleIdentity(token(overrides), key));
  });
}
test('rejects an invalid signature', async () => {
  const other = generateKeyPairSync('rsa', { modulusLength: 2048 });
  await assert.rejects(verifyAppleIdentity(token(), (_h, cb) => cb(null, other.publicKey)));
});
