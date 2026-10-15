const jwt = require('jsonwebtoken');

// Exact app IDs only: never accept an audience supplied by the client.
const APPLE_AUDIENCES = Object.freeze([
  'com.pjunese.lottonote',
  'com.pjunese.lottonote.dev',
]);

function verifyAppleIdentity(identityToken, getSigningKey) {
  return new Promise((resolve, reject) => {
    jwt.verify(identityToken, getSigningKey, {
      algorithms: ['RS256'],
      issuer: 'https://appleid.apple.com',
      audience: APPLE_AUDIENCES,
    }, (error, payload) => {
      if (error) return reject(error);
      if (!payload || typeof payload.sub !== 'string' || !payload.sub.trim()) {
        return reject(new Error('Apple token has no valid subject'));
      }
      resolve(`apple:${payload.sub}`);
    });
  });
}
module.exports = { verifyAppleIdentity };
