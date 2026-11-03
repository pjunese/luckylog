const { onSchedule } = require('firebase-functions/v2/scheduler');
const { onCall, onRequest, HttpsError } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');
const { getAuth } = require('firebase-admin/auth');
const axios = require('axios');
const { verifyAppleIdentity } = require('./apple_identity');
const jwksClient = require('jwks-rsa');
const { createBackend, requireAdmin } = require('./backend');
const { createLottoCollector } = require('./lotto_collection');
const { fetchFromNaver: _fetchFromNaver } = require('./lotto_source');

// Firebase Secret Manager에 등록된 시크릿
const adminSecret = defineSecret('ADMIN_SECRET');
const nearbyKey = defineSecret('KAKAO_LOCAL_REST_KEY');

initializeApp();
const db = getFirestore();
const backend = createBackend({ db, messaging: getMessaging(), FieldValue, HttpsError });

exports.registerUser = onCall(
  { region: 'asia-northeast3', timeoutSeconds: 120 },
  backend.registerUser
);

// Keep the Local REST key on the server; the client supplies only coordinates.
exports.searchNearbyStores = onCall(
  { region: 'asia-northeast3', enforceAppCheck: true, maxInstances: 3, concurrency: 10,
    timeoutSeconds: 20, secrets: [nearbyKey] },
  require('./nearby_search').createNearbySearch({ db, http: axios, key: () => nearbyKey.value(), HttpsError })
);

// ─────────────────────────────────────────
// 수동으로 특정 회차 저장 (onRequest 방식)
// 사용: GET /manualSaveLotto?round=1218&secret=YOUR_SECRET
// ─────────────────────────────────────────
exports.manualSaveLotto = onRequest(
  { region: 'asia-northeast3', secrets: [adminSecret] },
  async (req, res) => {
    if (req.query.secret !== adminSecret.value()) {
      return res.status(403).json({ error: '인증 실패' });
    }

    const round = parseInt(req.query.round, 10);
    if (!round || isNaN(round)) {
      return res.status(400).json({ error: 'round 파라미터가 필요합니다. 예: ?round=1218' });
    }

    console.log(`[manualSaveLotto] ${round}회 수집 시작`);
    const result = await _fetchFromNaver(round);
    if (!result) {
      return res.status(500).json({ error: `${round}회 수집 실패 (네이버 파싱 실패)` });
    }

    await _saveToFirestore(result);
    console.log(`[manualSaveLotto] ✅ ${round}회 저장 완료`);
    return res.json({ success: true, data: result });
  }
);

// ─────────────────────────────────────────
// 과거 회차 일괄 수집 (prizes + stores 백필)
// 사용: GET /batchSaveLotto?from=1100&to=1150
// ─────────────────────────────────────────
exports.batchSaveLotto = onRequest(
  { region: 'asia-northeast3', timeoutSeconds: 540, secrets: [adminSecret] },
  async (req, res) => {
    if (req.query.secret !== adminSecret.value()) {
      return res.status(403).json({ error: '인증 실패' });
    }

    const from = parseInt(req.query.from, 10);
    const to = parseInt(req.query.to, 10);
    if (!from || !to || from > to || to - from > 60) {
      return res.status(400).json({ error: 'from, to 필요. 최대 60회차씩. 예: ?from=1100&to=1150' });
    }

    const results = [];
    for (let round = from; round <= to; round++) {
      // 이미 prizes + stores(grade포함) 있는지 확인
      const existing = await db.collection('lotto_draws').doc(String(round)).get();
      const force = req.query.force === 'true';
      if (!force && existing.exists) {
        const data = existing.data();
        const hasPrizes = data.prizes && Object.keys(data.prizes).length > 0;
        const hasGrade = Array.isArray(data.stores) && data.stores.length > 0 && data.stores[0].grade !== undefined;
        if (hasPrizes && hasGrade) {
          results.push({ round, status: 'skip' });
          continue;
        }
      }

      const result = await _fetchFromNaver(round);
      if (result) {
        await _saveToFirestore(result);
        results.push({ round, status: 'saved', numbers: result.numbers, stores: result.stores.length });
      } else {
        results.push({ round, status: 'failed' });
      }
      // 네이버 요청 간격 (1.5초)
      await new Promise(r => setTimeout(r, 1500));
    }

    return res.json({ total: results.length, results });
  }
);

// ─────────────────────────────────────────
// 카카오/애플 로그인 → Firebase 커스텀 토큰 발급
//
// 클라이언트가 보낸 accountKey를 그대로 믿으면 아무나 남의 계정으로
// 토큰을 받을 수 있으므로, 반드시 여기서 자격증명을 검증한다.
//   - 카카오: 액세스 토큰으로 카카오 API에 사용자 조회
//   - 애플: identityToken(JWT) 서명을 애플 공개키로 검증
// 검증된 사용자 ID로만 uid('kakao:123' / 'apple:xxx')를 만든다.
// ─────────────────────────────────────────
const appleJwks = jwksClient({
  jwksUri: 'https://appleid.apple.com/auth/keys',
  cache: true,
  cacheMaxEntries: 5,
  cacheMaxAge: 10 * 60 * 1000,
});

function getAppleSigningKey(header, callback) {
  appleJwks.getSigningKey(header.kid, (err, key) => {
    if (err) return callback(err);
    callback(null, key.getPublicKey());
  });
}

async function _verifyKakao(accessToken) {
  try {
    const res = await axios.get('https://kapi.kakao.com/v2/user/me', {
      headers: { Authorization: `Bearer ${accessToken}` },
      timeout: 8000,
    });
    const id = res.data && res.data.id;
    if (!id) throw new Error('카카오 응답에 id 없음');
    return `kakao:${id}`;
  } catch (e) {
    // Credentials, including fragments, must never be logged.
    console.warn(
      `[verifyKakao] 실패 status=${e.response?.status} ` +
        `code=${e.code || 'unknown'}`
    );
    throw e;
  }
}

function _verifyApple(identityToken) {
  return verifyAppleIdentity(identityToken, getAppleSigningKey);
}

exports.createAuthToken = onCall(
  { region: 'asia-northeast3' },
  async (request) => {
    const provider = request.data && request.data.provider;
    const credential = request.data && request.data.credential;

    if (typeof provider !== 'string' || typeof credential !== 'string' ||
        credential.length < 1 || credential.length > 16384) {
      throw new HttpsError('invalid-argument', 'provider와 credential이 필요합니다.');
    }

    let uid;
    try {
      if (provider === 'kakao') {
        uid = await _verifyKakao(credential);
      } else if (provider === 'apple') {
        uid = await _verifyApple(credential);
      } else {
        throw new HttpsError('invalid-argument', `지원하지 않는 provider: ${provider}`);
      }
    } catch (e) {
      if (e instanceof HttpsError) throw e;
      console.warn(`[createAuthToken] ${provider} 검증 실패:`, e.message);
      throw new HttpsError('unauthenticated', '로그인 자격증명 검증에 실패했습니다.');
    }

    try {
      const token = await getAuth().createCustomToken(uid);
      console.log(`[createAuthToken] 발급 완료: ${uid}`);
      return { token, uid };
    } catch (e) {
      console.error('[createAuthToken] 토큰 발급 실패:', e.message);
      throw new HttpsError('internal', '토큰 발급에 실패했습니다.');
    }
  }
);

// ─────────────────────────────────────────
// [테스트 전용] 알림 탭 → 화면이동 검증용 푸시 발송
//
//   목록 조회: GET /sendTestPush?secret=X&list=1
//   발송     : GET /sendTestPush?secret=X&accountKey=kakao:123&type=win_result&round=1230
//
// type: win_result | lose_result | draw_result
// 실제 발송 payload와 동일한 구조를 사용해야 검증이 유효하다.
// 검증이 끝나면 이 함수는 삭제해도 된다.
// ─────────────────────────────────────────
exports.sendTestPush = onRequest(
  { region: 'asia-northeast3', secrets: [adminSecret] },
  async (req, res) => {
    if (req.query.secret !== adminSecret.value()) {
      return res.status(403).json({ error: '인증 실패' });
    }

    // 계정별 활성 기기 수만 노출 (토큰 값은 감춤)
    if (req.query.list === '1') {
      const snap = await db.collection('users').get();
      const users = [];
      for (const user of snap.docs) {
        const tokens = await backend.enabledTokens(user.ref);
        users.push({ accountKey: user.id, enabledDevices: tokens.length });
      }
      return res.json({ count: users.length, users });
    }

    // 커스텀 토큰 발급 권한 확인 (IAM 전파 여부 점검용)
    if (req.query.checkAuth === '1') {
      const out = {};
      try {
        await getAuth().createCustomToken('__permission_probe__');
        out.canCreateCustomToken = true;
      } catch (e) {
        out.canCreateCustomToken = false;
        out.tokenError = e.message;
      }
      // Authentication 서비스 자체가 프로비저닝됐는지 확인
      try {
        const list = await getAuth().listUsers(1);
        out.authProvisioned = true;
        out.userCount = list.users.length;
      } catch (e) {
        out.authProvisioned = false;
        out.authError = e.message;
      }
      return res.json(out);
    }

    // 백업 상태 조회 (앱 삭제 전 데이터 확인용)
    if (req.query.inspect === '1') {
      const key = req.query.accountKey;
      if (!key) return res.status(400).json({ error: 'accountKey 필요' });
      const ref = db.collection('users').doc(key);
      const [doc, sets, history] = await Promise.all([
        ref.get(),
        ref.collection('number_sets').get(),
        ref.collection('purchase_history').get(),
      ]);
      // Firebase Auth 세션(커스텀 토큰 로그인) 생성 여부
      let authUser = null;
      try {
        const u = await getAuth().getUser(key);
        authUser = {
          uid: u.uid,
          createdAt: u.metadata.creationTime,
          lastSignInAt: u.metadata.lastSignInTime,
        };
      } catch (_) {
        authUser = null; // 아직 커스텀 토큰으로 로그인한 적 없음
      }

      return res.json({
        accountKey: key,
        exists: doc.exists,
        numberSets: sets.size,
        purchaseHistory: history.size,
        enabledDevices: (await backend.enabledTokens(ref)).length,
        updatedAt: doc.data()?.updatedAt ?? null,
        firebaseAuth: authUser,
      });
    }

    const accountKey = req.query.accountKey;
    const type = req.query.type || 'win_result';
    const round = parseInt(req.query.round, 10) || 9999;

    if (!accountKey) {
      return res.status(400).json({ error: 'accountKey 필요. 먼저 ?list=1 로 조회하세요.' });
    }
    if (!['win_result', 'lose_result', 'draw_result'].includes(type)) {
      return res.status(400).json({ error: 'type은 win_result | lose_result | draw_result' });
    }

    const userDoc = await db.collection('users').doc(accountKey).get();
    if (!userDoc.exists) {
      return res.status(404).json({ error: `계정 없음: ${accountKey}` });
    }
    const tokens = await backend.enabledTokens(userDoc.ref);
    if (!tokens.length) {
      return res.status(400).json({ error: '알림이 활성화된 기기가 없습니다.' });
    }

    // 실제 발송과 동일한 payload 구성
    let title, body, data;
    if (type === 'win_result') {
      title = `🎉 ${round}회 5등 당첨! [테스트]`;
      body = '로또노트에서 당첨 결과를 확인하세요.';
      data = { round: String(round), grade: '5', type: 'win_result' };
    } else if (type === 'lose_result') {
      title = `🎱 ${round}회 추첨 결과 [테스트]`;
      body = '아쉽게도 이번엔 낙첨이에요. 다음 기회에! 🍀';
      data = { round: String(round), grade: '0', type: 'lose_result' };
    } else {
      title = `🎱 제${round}회 로또 당첨번호 발표 [테스트]`;
      body = '1, 2, 3, 4, 5, 6 + 보너스 7';
      data = { round: String(round), type: 'draw_result' };
    }

    try {
      const ids = [];
      for (const token of tokens) {
        ids.push(await getMessaging().send({ token, notification: { title, body }, data }));
      }
      return res.json({ success: true, sentTo: accountKey, type, data, messageIds: ids });
    } catch (e) {
      console.error('[sendTestPush] 전송 실패:', e.message);
      return res.status(500).json({ error: e.message });
    }
  }
);

// Poll frequently on draw night, with an all-week recovery job for late results.
// Each invocation is short; no fixed 20-minute retry deadline or sleeping worker.
const collectLotto = createLottoCollector({
  getLatestRound: _getLatestStoredRound,
  getDraw: async (round) => {
    const doc = await db.collection('lotto_draws').doc(String(round)).get();
    return doc.exists ? doc.data() : null;
  },
  fetchDraw: _fetchFromNaver,
  saveDraw: _saveToFirestore,
  reportPending: _notifyAdminParsingFailed,
  updateDetails: (round, data) => db.collection('lotto_draws').doc(String(round)).update(data),
});

exports.fetchWeeklyLotto = onSchedule(
  {
    schedule: '*/5 20-23 * * 6',
    timeZone: 'Asia/Seoul', region: 'asia-northeast3',
    timeoutSeconds: 300, retryCount: 0, maxInstances: 1, concurrency: 1,
  },
  async () => { await collectLotto(); }
);

exports.updatePrizeStores = onSchedule(
  {
    schedule: '7,37 * * * *',
    timeZone: 'Asia/Seoul', region: 'asia-northeast3',
    timeoutSeconds: 300, retryCount: 0, maxInstances: 1, concurrency: 1,
  },
  async () => { await collectLotto({ includeDetails: true }); }
);

// ─────────────────────────────────────────
// 관리자가 특정 회차를 수동으로 저장할 때 사용
// Firebase 콘솔 → Functions → 수동 호출
// ─────────────────────────────────────────
exports.manualFetchLotto = onCall(
  { region: 'asia-northeast3' },
  async (request) => {
    requireAdmin(request, HttpsError);

    const round = request.data?.round;
    if (!Number.isSafeInteger(round) || round < 1) {
      throw new HttpsError('invalid-argument', 'round 파라미터가 필요합니다.');
    }

    const result = await _fetchFromNaver(round);
    if (!result) {
      throw new HttpsError('internal', `${round}회 수집 실패`);
    }

    await _saveToFirestore(result);
    return { success: true, data: result };
  }
);

// ─────────────────────────────────────────
// 내부 함수
// ─────────────────────────────────────────

// Escalate prolonged delays once per missing round while recovery keeps running.
async function _notifyAdminParsingFailed(round) {
  const ref = db.collection('meta').doc('drawCollectionAlert');
  const claimed = await db.runTransaction(async (tx) => {
    const doc = await tx.get(ref);
    if ((doc.data()?.round || 0) >= round) return false;
    tx.set(ref, { round, updatedAt: new Date().toISOString() });
    return true;
  });
  if (!claimed) return;
  try {
    await getMessaging().send({
      topic: 'admin_alerts',
      notification: { title: '⚠️ 로또 결과 수집 지연',
        body: `${round}회 결과를 아직 확인하지 못했습니다. 자동 재수집은 계속됩니다.` },
      data: { round: String(round), type: 'parsing_failed' },
    });
  } catch (error) { console.error('[admin_alert] 알림 발송 실패:', error.message); }
}

async function _getLatestStoredRound() {
  const metaDoc = await db.collection('meta').doc('latest').get();
  return metaDoc.exists ? (metaDoc.data().round ?? 1217) : 1217;
}

// Manual/backfill calls are deliberately silent; the weekly scheduler opts in.
async function _saveToFirestore(result, options) {
  await backend.saveToFirestore(result, options);
}
