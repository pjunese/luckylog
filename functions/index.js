const { onSchedule } = require('firebase-functions/v2/scheduler');
const { onCall, onRequest, HttpsError } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');
const { getAuth } = require('firebase-admin/auth');
const axios = require('axios');
const jwt = require('jsonwebtoken');
const jwksClient = require('jwks-rsa');

// Firebase Secret Manager에 등록된 시크릿
const adminSecret = defineSecret('ADMIN_SECRET');

initializeApp();
const db = getFirestore();

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
const APPLE_BUNDLE_ID = 'com.pjunese.lottonote';
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
    // 토큰 값 자체는 남기지 않고, 형태만 기록해 원인을 좁힌다.
    const t = accessToken || '';
    console.warn(
      `[verifyKakao] 실패 status=${e.response?.status} ` +
        `body=${JSON.stringify(e.response?.data ?? null)} ` +
        `tokenLen=${t.length} head=${t.slice(0, 6)} tail=${t.slice(-4)}`
    );
    throw e;
  }
}

function _verifyApple(identityToken) {
  return new Promise((resolve, reject) => {
    jwt.verify(
      identityToken,
      getAppleSigningKey,
      {
        algorithms: ['RS256'],
        issuer: 'https://appleid.apple.com',
        audience: APPLE_BUNDLE_ID,
      },
      (err, payload) => {
        if (err) return reject(err);
        if (!payload || !payload.sub) return reject(new Error('애플 토큰에 sub 없음'));
        resolve(`apple:${payload.sub}`);
      }
    );
  });
}

exports.createAuthToken = onCall(
  { region: 'asia-northeast3' },
  async (request) => {
    const provider = request.data && request.data.provider;
    const credential = request.data && request.data.credential;

    if (!provider || !credential) {
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

    // 계정 목록 (fcmToken 보유 여부만 노출, 토큰 값은 감춤)
    if (req.query.list === '1') {
      const snap = await db.collection('users').get();
      const users = snap.docs.map((d) => ({
        accountKey: d.id,
        hasToken: Boolean(d.data().fcmToken),
        tokenTail: d.data().fcmToken ? `...${String(d.data().fcmToken).slice(-8)}` : null,
      }));
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
        hasToken: Boolean(doc.data()?.fcmToken),
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
    const fcmToken = userDoc.data().fcmToken;
    if (!fcmToken) {
      return res.status(400).json({ error: `fcmToken 없음 (앱에서 알림 권한 허용 후 재로그인 필요): ${accountKey}` });
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
      const id = await getMessaging().send({
        token: fcmToken,
        notification: { title, body },
        data,
      });
      console.log(`[sendTestPush] ${accountKey} → ${type} 전송 완료 (${id})`);
      return res.json({ success: true, sentTo: accountKey, type, data, messageId: id });
    } catch (e) {
      console.error('[sendTestPush] 전송 실패:', e.message);
      return res.status(500).json({ error: e.message });
    }
  }
);

// ─────────────────────────────────────────
// 매주 토요일 20:40 KST 자동 실행
// 1분 간격으로 최대 20회 재시도 (최장 ~20분 실행)
// 수집 성공하면 즉시 종료
// ─────────────────────────────────────────
exports.fetchWeeklyLotto = onSchedule(
  {
    schedule: '45 20 * * 6',     // 토요일 20:45 KST
    timeZone: 'Asia/Seoul',
    region: 'asia-northeast3',
    timeoutSeconds: 1380,        // 23분 (20회 × 1분 + 여유)
    retryCount: 0,               // 외부 재시도 불필요 (내부 루프로 처리)
  },
  async () => {
    const latestRound = await _getLatestStoredRound();
    const nextRound = latestRound + 1;
    const MAX_ATTEMPTS = 20;

    console.log(`[fetchWeeklyLotto] ${nextRound}회 자동수집 시작 (최대 ${MAX_ATTEMPTS}회 시도)`);

    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      console.log(`[fetchWeeklyLotto] ${nextRound}회 시도 ${attempt}/${MAX_ATTEMPTS}`);

      const result = await _fetchFromNaver(nextRound);
      if (result) {
        await _saveToFirestore(result);
        console.log(`[fetchWeeklyLotto] ✅ ${nextRound}회 저장 완료 (${attempt}번째 시도):`, result.numbers, '+보너스', result.bonus);
        return;
      }

      if (attempt < MAX_ATTEMPTS) {
        console.log(`[fetchWeeklyLotto] 결과 미게시. 1분 후 재시도...`);
        await new Promise((r) => setTimeout(r, 60 * 1000));
      }
    }

    console.error(`[fetchWeeklyLotto] ❌ ${nextRound}회 수집 실패 (${MAX_ATTEMPTS}번 모두 실패)`);
    await _notifyAdminParsingFailed(nextRound);
  }
);

// ─────────────────────────────────────────
// 토요일 21:15~23:45 매 30분마다 당첨금/당첨점 보완
// 번호는 수집됐지만 prizes/stores가 비어있는 경우 재시도
// ─────────────────────────────────────────
exports.updatePrizeStores = onSchedule(
  {
    schedule: '15,45 21-23 * * 6',  // 토요일 21:15, 21:45, 22:15 ... 23:45 KST
    timeZone: 'Asia/Seoul',
    region: 'asia-northeast3',
    timeoutSeconds: 60,
  },
  async () => {
    const latestRound = await _getLatestStoredRound();
    if (latestRound <= 0) return;

    const doc = await db.collection('lotto_draws').doc(String(latestRound)).get();
    if (!doc.exists) {
      console.log(`[updatePrizeStores] ${latestRound}회 문서 없음 - 스킵`);
      return;
    }

    const data = doc.data();
    const prizes = data.prizes || {};
    const prize1 = prizes['1'];
    const hasPrizes = prize1 && prize1.count > 0 && prize1.perPrize > 0;
    const hasStores = Array.isArray(data.stores) && data.stores.length > 0;

    if (hasPrizes && hasStores) {
      console.log(`[updatePrizeStores] ${latestRound}회 당첨금/당첨점 이미 완료 - 스킵`);
      return;
    }

    console.log(`[updatePrizeStores] ${latestRound}회 당첨금/당첨점 미완료 - 재수집 시작 (hasPrizes=${hasPrizes}, hasStores=${hasStores})`);

    const result = await _fetchFromNaver(latestRound);
    if (!result) {
      console.warn(`[updatePrizeStores] ${latestRound}회 네이버 수집 실패`);
      return;
    }

    const newPrize1 = result.prizes?.['1'];
    if (!newPrize1 || newPrize1.count <= 0) {
      console.log(`[updatePrizeStores] ${latestRound}회 당첨금 아직 미집계 - 다음 시도 대기`);
      return;
    }

    await db.collection('lotto_draws').doc(String(latestRound)).update({
      prizes: result.prizes,
      stores: result.stores,
      updatedAt: new Date().toISOString(),
    });
    console.log(`[updatePrizeStores] ✅ ${latestRound}회 당첨금/당첨점 업데이트 완료`);
  }
);

// ─────────────────────────────────────────
// 관리자가 특정 회차를 수동으로 저장할 때 사용
// Firebase 콘솔 → Functions → 수동 호출
// ─────────────────────────────────────────
exports.manualFetchLotto = onCall(
  { region: 'asia-northeast3' },
  async (request) => {
    // Firebase Auth 인증된 사용자만 허용
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const round = request.data.round;
    if (!round || typeof round !== 'number') {
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

// 파싱 실패 시 관리자 FCM 알림 (토픽: admin_alerts)
async function _notifyAdminParsingFailed(round) {
  try {
    await getMessaging().send({
      topic: 'admin_alerts',
      notification: {
        title: '⚠️ 로또 수집 실패',
        body: `${round}회 당첨번호 자동 수집 실패. 네이버 HTML 구조 변경 가능성이 있습니다.`,
      },
      data: { round: String(round), type: 'parsing_failed' },
    });
    console.log(`[admin_alert] ${round}회 파싱 실패 알림 전송 완료`);
  } catch (e) {
    console.error('[admin_alert] 알림 전송 실패:', e.message);
  }
}

async function _getLatestStoredRound() {
  const metaDoc = await db.collection('meta').doc('latest').get();
  return metaDoc.exists ? (metaDoc.data().round ?? 1217) : 1217;
}

// 당첨판매점 파싱 (이름, 주소, 좌표, 당첨 복권수)
function _parseStoreSection(section, grade) {
  const stores = [];
  const liRegex = /<li>([\s\S]*?)<\/li>/g;
  let m;
  while ((m = liRegex.exec(section)) !== null) {
    const block = m[1];
    const nameMatch = block.match(/class="text"[^>]*>\s*([^<]+?)\s*<\/a>/);
    const addrMatch = block.match(/class="line_1">([^<]+)<\/dd>/);
    // 네이버 라벨 변경 대응: "당첨 복권수"(구) / "당첨게임 수"(신) 모두 매칭
    const countMatch = block.match(/(?:당첨 ?복권수|당첨게임 ?수)\s*<strong>(\d+)개<\/strong>/);
    const coordMatch = block.match(/lng=([\d.]+)(?:&amp;|&)lat=([\d.]+)/);
    if (!nameMatch && !addrMatch) continue;
    stores.push({
      name: nameMatch ? nameMatch[1].trim() : '',
      address: addrMatch ? addrMatch[1].trim() : '',
      count: countMatch ? parseInt(countMatch[1]) : 1,
      lat: coordMatch ? parseFloat(coordMatch[2]) : null,
      lng: coordMatch ? parseFloat(coordMatch[1]) : null,
      grade: grade, // 1 = 1등, 2 = 2등
    });
  }
  return stores;
}

function _parseWinningStores(html) {
  const stores = [];

  // 1등, 2등 _store_panel 위치를 먼저 모두 찾아서 각 섹션을 정확히 분리
  const positions = [];
  let searchFrom = 0;
  for (let i = 0; i < 2; i++) {
    const idx = html.indexOf('_store_panel', searchFrom);
    if (idx < 0) break;
    positions.push(idx);
    searchFrom = idx + 1;
  }

  for (let i = 0; i < positions.length; i++) {
    const grade = i + 1;
    const start = positions[i];
    const end = positions[i + 1] || (start + 40000);
    const section = html.slice(start, end);
    stores.push(..._parseStoreSection(section, grade));
  }

  return stores;
}

// 1~5등 당첨 정보 파싱
function _parsePrizeTable(html) {
  const prizes = {};
  // <th rowspan="3">X등</th> 블록별로 파싱
  const gradeRegex = /<th[^>]*>\s*(\d)등\s*<\/th>([\s\S]*?)(?=<th[^>]*>\s*\d등\s*<\/th>|<\/tbody>)/g;
  let m;
  while ((m = gradeRegex.exec(html)) !== null) {
    const grade = parseInt(m[1]);
    const block = m[2];
    const totalMatch = block.match(/총 당첨금<\/td>\s*<td>([\d,]+)원<\/td>/);
    // 네이버 라벨 변경 대응: "당첨 복권수"(구) / "당첨게임 수"(신) 모두 매칭
    const countMatch = block.match(/(?:당첨 ?복권수|당첨게임 ?수)<\/td>\s*<td>([\d,]+)개<\/td>/);
    const perMatch  = block.match(/1개당 당첨금<\/td>\s*<td>([\d,]+)원<\/td>/);
    prizes[grade] = {
      totalPrize: totalMatch ? parseInt(totalMatch[1].replace(/,/g, '')) : 0,
      count:      countMatch ? parseInt(countMatch[1].replace(/,/g, '')) : 0,
      perPrize:   perMatch   ? parseInt(perMatch[1].replace(/,/g, ''))   : 0,
    };
  }
  return prizes;
}

async function _fetchFromNaver(round, retry = 3) {
  const url = `https://search.naver.com/search.naver?query=${encodeURIComponent(`로또 ${round}회`)}`;
  const headers = {
    'User-Agent':
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Accept-Language': 'ko-KR,ko;q=0.9',
    Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  };

  for (let attempt = 0; attempt < retry; attempt++) {
    try {
      const res = await axios.get(url, { headers, timeout: 10000 });
      const html = res.data;

      // <span class="ball type1">3</span> 같은 패턴 파싱
      const ballRegex = /<span[^>]*\bball\b[^>]*>(\d+)<\/span>/g;
      const balls = [];
      let m;
      while ((m = ballRegex.exec(html)) !== null) {
        balls.push(parseInt(m[1], 10));
      }

      if (balls.length < 7) {
        console.warn(`[naver] ${round}회 파싱 실패 (balls: ${balls.length})`);
        continue;
      }

      // 날짜 및 회차 파싱 - "1218회차 (2026.04.04.)" 패턴
      const roundMatch = html.match(/(\d+)회차\s*\((\d{4}\.\d{2}\.\d{2})/);
      if (!roundMatch || parseInt(roundMatch[1]) !== round) {
        console.warn(`[naver] ${round}회 회차 불일치 (파싱된 회차: ${roundMatch ? roundMatch[1] : 'none'})`);
        continue;
      }
      const date = roundMatch[2].replace(/\./g, '-');

      const prizes = _parsePrizeTable(html);
      const stores = _parseWinningStores(html);
      return {
        round,
        numbers: balls.slice(0, 6),
        bonus: balls[6],
        date,
        prizes,
        stores,
        updatedAt: new Date().toISOString(),
      };
    } catch (e) {
      console.warn(`[naver] ${round}회 시도 ${attempt + 1}/${retry} 실패:`, e.message);
      if (attempt < retry - 1) {
        await new Promise((r) => setTimeout(r, 3000 + attempt * 2000));
      }
    }
  }
  return null;
}

async function _saveToFirestore(result) {
  const batch = db.batch();
  const drawRef = db.collection('lotto_draws').doc(String(result.round));
  batch.set(drawRef, result);
  const metaRef = db.collection('meta').doc('latest');
  batch.set(metaRef, { round: result.round, updatedAt: result.updatedAt });
  await batch.commit();

  // FCM 토픽 알림 발송
  try {
    await getMessaging().send({
      topic: 'draw_result',
      notification: {
        title: `🎱 제${result.round}회 로또 당첨번호 발표`,
        body: `${result.numbers.join(', ')} + 보너스 ${result.bonus}`,
      },
      data: { round: String(result.round), type: 'draw_result' },
    });
    console.log(`[FCM] 알림 전송 완료: ${result.round}회`);
  } catch (e) {
    console.warn('[FCM] 알림 전송 실패:', e.message);
  }

  // 당첨 확인 및 서비스 통계 집계 (백그라운드)
  _processDrawResults(result).catch((e) =>
    console.warn('[processDrawResults] 오류:', e.message)
  );
}

// 등수 계산
function _calcGrade(numbers, bonus, myNumbers) {
  const matchCount = myNumbers.filter((n) => numbers.includes(n)).length;
  const bonusMatch = myNumbers.includes(bonus);
  if (matchCount === 6) return 1;
  if (matchCount === 5 && bonusMatch) return 2;
  if (matchCount === 5) return 3;
  if (matchCount === 4) return 4;
  if (matchCount === 3) return 5;
  return 0;
}

// 당첨 확인 + 개인 FCM 발송 + 서비스 통계 집계
async function _processDrawResults(result) {
  const { round, numbers, bonus } = result;

  // 1222회까지는 집계 제외 (서비스 출시 전 데이터)
  if (round <= 1222) {
    console.log(`[processDrawResults] ${round}회 스킵 (1222회 이하)`);
    return;
  }

  console.log(`[processDrawResults] ${round}회 당첨 확인 시작`);

  const usersSnap = await db.collection('users').get();
  const stats = { totalParticipants: 0, totalSets: 0, winners: { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 } };

  for (const userDoc of usersSnap.docs) {
    const accountKey = userDoc.id;
    const fcmToken = userDoc.data().fcmToken;

    // 해당 회차 구매내역 조회
    const historySnap = await db
      .collection('users').doc(accountKey)
      .collection('purchase_history')
      .where('round', '==', round)
      .get();

    if (historySnap.empty) continue;

    stats.totalParticipants++;
    let bestGrade = 0;

    for (const doc of historySnap.docs) {
      const data = doc.data();
      let games;
      try {
        games = typeof data.games === 'string' ? JSON.parse(data.games) : data.games;
      } catch (_) { continue; }
      if (!Array.isArray(games)) continue;

      for (const set of games) {
        if (!Array.isArray(set) || set.length !== 6) continue;
        stats.totalSets++;
        const grade = _calcGrade(numbers, bonus, set);
        if (grade > 0) {
          stats.winners[grade] = (stats.winners[grade] || 0) + 1;
          if (grade < bestGrade || bestGrade === 0) bestGrade = grade;
        }
      }
    }

    // 구매내역이 있는 유저에게 개인 결과 FCM 발송 (당첨/낙첨 모두)
    if (fcmToken) {
      const gradeLabels = { 1: '1등 🏆', 2: '2등 🥈', 3: '3등 🥉', 4: '4등', 5: '5등' };
      const isWin = bestGrade > 0;
      const title = isWin
        ? `🎉 ${round}회 ${gradeLabels[bestGrade]} 당첨!`
        : `🎱 ${round}회 추첨 결과`;
      const body = isWin
        ? '로또노트에서 당첨 결과를 확인하세요.'
        : '아쉽게도 이번엔 낙첨이에요. 다음 기회에! 🍀';
      try {
        await getMessaging().send({
          token: fcmToken,
          notification: { title, body },
          data: {
            round: String(round),
            grade: String(bestGrade),
            type: isWin ? 'win_result' : 'lose_result',
          },
        });
        console.log(`[processDrawResults] ${accountKey} → ${isWin ? bestGrade + '등' : '낙첨'} 알림 전송`);
      } catch (e) {
        console.warn(`[processDrawResults] FCM 전송 실패 (${accountKey}):`, e.message);
      }
    }
  }

  // 서비스 전체 통계 저장
  await db.collection('service_stats').doc(String(round)).set({
    round,
    totalParticipants: stats.totalParticipants,
    totalSets: stats.totalSets,
    winners: stats.winners,
    processedAt: new Date().toISOString(),
  });

  console.log(`[processDrawResults] ${round}회 집계 완료:`, stats);
}
