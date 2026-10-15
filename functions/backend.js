'use strict';

const validNumbers = (numbers) => Array.isArray(numbers) && numbers.length === 6 &&
  numbers.every((n) => Number.isInteger(n) && n >= 1 && n <= 45) &&
  new Set(numbers).size === 6;

function calcGrade(numbers, bonus, mine) {
  if (!validNumbers(mine)) return 0;
  const matches = mine.filter((n) => numbers.includes(n)).length;
  if (matches === 6) return 1;
  if (matches === 5) return mine.includes(bonus) ? 2 : 3;
  return matches === 4 ? 4 : matches === 3 ? 5 : 0;
}

function requireAdmin(request, HttpsError) {
  if (!request.auth) throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
  if (request.auth.token?.admin !== true) {
    throw new HttpsError('permission-denied', '관리자 권한이 필요합니다.');
  }
}

function createBackend({ db, messaging, FieldValue, HttpsError }) {
  const timestamp = () => FieldValue.serverTimestamp();
  const positiveInteger = (n) => Number.isSafeInteger(n) && n > 0;

  async function registerUser(request) {
    if (!request.auth) throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    // Only server-verified custom-auth UIDs determine identity, never request.data.
    const uid = request.auth.uid;
    const identity = /^(kakao:([0-9]+)|apple:([^/\s:]+))$/.exec(uid);
    if (!identity || request.auth.token?.firebase?.sign_in_provider !== 'custom') {
      throw new HttpsError('permission-denied', '지원하지 않는 로그인 계정입니다.');
    }
    const provider = uid.startsWith('kakao:') ? 'kakao' : 'apple';
    const providerUserId = uid.slice(provider.length + 1);
    const userRef = db.collection('users').doc(uid);
    // The historical bare-ID namespace was Kakao only. Apple may never claim it.
    const legacyRef = provider === 'kakao' ? db.collection('users').doc(providerUserId) : null;
    const result = await db.runTransaction(async (tx) => {
      const user = await tx.get(userRef);
      const legacy = legacyRef ? await tx.get(legacyRef) : null;
      const existing = user.data() || {};
      const legacyData = legacy?.data() || {};
      const canMigrate = legacy?.exists &&
        (!legacyData.provider || legacyData.provider === provider) &&
        (!legacyData.providerUserId || String(legacyData.providerUserId) === providerUserId) &&
        (!legacyData.migratedTo || legacyData.migratedTo === uid);
      const migrate = canMigrate && existing.legacyMigrationComplete !== true;
      const source = user.exists ? existing : canMigrate ? legacyData : {};
      let userNumber = positiveInteger(source.userNumber) ? source.userNumber : 0;
      let reservation;
      if (userNumber) {
        reservation = await tx.get(db.collection('user_numbers').doc(String(userNumber)));
        if (reservation.exists && reservation.data().uid !== uid) userNumber = 0;
      }
      const counterRef = db.collection('meta').doc('userCount');
      if (!userNumber) {
        const counter = await tx.get(counterRef);
        // Include legacy users if the historic counter is absent or stale.
        const highest = await tx.get(db.collection('users').where('userNumber', '>=', 1)
          .orderBy('userNumber', 'desc').limit(1));
        const highestNumber = highest.empty ? 0 : highest.docs[0].data().userNumber;
        const count = counter.data()?.count;
        userNumber = Math.max(positiveInteger(count) ? count : 0,
          positiveInteger(highestNumber) ? highestNumber : 0) + 1;
        if (!positiveInteger(userNumber)) throw new HttpsError('internal', '회원 번호 범위 초과');
        tx.set(counterRef, { count: userNumber }, { merge: true });
      }
      tx.set(db.collection('user_numbers').doc(String(userNumber)), { uid });
      const profile = {
        userNumber, provider, providerUserId, updatedAt: timestamp(),
        fcmToken: FieldValue.delete(), fcmTokenUpdatedAt: FieldValue.delete(),
      };
      if (!user.exists) {
        profile.nickname = typeof source.nickname === 'string' && source.nickname.length > 0 &&
          source.nickname.length <= 20 ? source.nickname : `user_${userNumber}`;
        profile.createdAt = source.createdAt || timestamp();
      }
      if (migrate) {
        profile.migratedFromLegacyId = providerUserId;
        tx.set(legacyRef, { migratedTo: uid, fcmToken: FieldValue.delete(),
          fcmTokenUpdatedAt: FieldValue.delete() }, { merge: true });
      }
      tx.set(userRef, profile, { merge: true });
      return { userNumber, migrate };
    });

    if (result.migrate) {
      // Retain the legacy source as a backup. Each page can safely be retried:
      // a target record (including a tombstone) always wins over an old copy.
      for (const collection of ['number_sets', 'purchase_history']) {
        let cursor;
        while (true) {
          let query = legacyRef.collection(collection).orderBy('__name__').limit(200);
          if (cursor) query = query.startAfter(cursor);
          const page = await query.get();
          if (page.empty) break;
          await db.runTransaction(async (tx) => {
            const targets = page.docs.map((doc) => userRef.collection(collection).doc(doc.id));
            const snapshots = await tx.getAll(...targets);
            snapshots.forEach((snapshot, i) => {
              if (!snapshot.exists) tx.set(targets[i], page.docs[i].data());
            });
          });
          cursor = page.docs[page.docs.length - 1];
        }
      }
      await userRef.update({ legacyMigrationComplete: true, updatedAt: timestamp() });
    }
    return { userNumber: result.userNumber };
  }

  async function enabledTokens(userRef) {
    const devices = await userRef.collection('devices').where('enabled', '==', true).get();
    return [...new Set(devices.docs.map((doc) => doc.data().token)
      .filter((token) => typeof token === 'string' && token.length > 0 && token.length <= 4096))];
  }

  async function sendToDevices(userRef, payload) {
    const tokens = await enabledTokens(userRef);
    for (const token of tokens) {
      try {
        await messaging.send({ token, ...payload });
      } catch (error) {
        console.warn('[FCM] 기기 발송 실패:', error.code || error.message);
      }
    }
    return tokens.length;
  }

  async function processDrawResults(result, { notify = false } = {}) {
    const { round, numbers, bonus } = result;
    if (round <= 1222) return;
    const users = await db.collection('users').get();
    const stats = { totalParticipants: 0, totalSets: 0, winners: { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 } };
    for (const user of users.docs) {
      // The legacy source remains as a recovery copy, not a second participant.
      if (user.data().migratedTo) continue;
      const history = await user.ref.collection('purchase_history').where('round', '==', round).get();
      let bestGrade = 0;
      let validSets = 0;
      for (const record of history.docs) {
        const data = record.data();
        if (data.deleted === true) continue;
        let games;
        try { games = typeof data.games === 'string' ? JSON.parse(data.games) : data.games; }
        catch (_) { continue; }
        if (!Array.isArray(games)) continue;
        for (const game of games) {
          if (!validNumbers(game)) continue;
          validSets++;
          const grade = calcGrade(numbers, bonus, game);
          if (grade > 0) {
            stats.winners[grade]++;
            if (bestGrade === 0 || grade < bestGrade) bestGrade = grade;
          }
        }
      }
      if (!validSets) continue;
      stats.totalParticipants++;
      stats.totalSets += validSets;
      if (notify) {
        const win = bestGrade > 0;
        const labels = { 1: '1등 🏆', 2: '2등 🥈', 3: '3등 🥉', 4: '4등', 5: '5등' };
        await sendToDevices(user.ref, {
          notification: {
            title: win ? `🎉 ${round}회 ${labels[bestGrade]} 당첨!` : `🎱 ${round}회 추첨 결과`,
            body: win ? '로또노트에서 당첨 결과를 확인하세요.' : '아쉽게도 이번엔 낙첨이에요. 다음 기회에! 🍀',
          },
          data: { round: String(round), grade: String(bestGrade), type: win ? 'win_result' : 'lose_result' },
        });
      }
    }
    await db.collection('service_stats').doc(String(round)).set({
      round, ...stats, processedAt: new Date().toISOString(),
    });
  }

  async function saveToFirestore(result, { broadcast = false } = {}) {
    if (!positiveInteger(result.round) || !validNumbers(result.numbers) ||
      !Number.isInteger(result.bonus) || result.bonus < 1 || result.bonus > 45 ||
      result.numbers.includes(result.bonus)) throw new Error('유효하지 않은 추첨 결과');
    const drawRef = db.collection('lotto_draws').doc(String(result.round));
    const metaRef = db.collection('meta').doc('latest');
    // The transaction grants a single invocation the notification attempt.
    // Historical saves and repeated draws still refresh statistics but never push.
    const notify = await db.runTransaction(async (tx) => {
      const draw = await tx.get(drawRef);
      const meta = await tx.get(metaRef);
      const latest = meta.data()?.round || 0;
      tx.set(drawRef, result, { merge: true });
      if (result.round > latest) tx.set(metaRef, { round: result.round, updatedAt: result.updatedAt });
      return broadcast && !draw.exists && result.round > latest;
    });
    // Await all result/stat work before returning from the Cloud Function.
    await processDrawResults(result, { notify });
    if (notify) {
      try {
        await messaging.send({ topic: 'draw_result', notification: {
          title: `🎱 제${result.round}회 로또 당첨번호 발표`,
          body: `${result.numbers.join(', ')} + 보너스 ${result.bonus}`,
        }, data: { round: String(result.round), type: 'draw_result' } });
      } catch (error) { console.warn('[FCM] 전체 알림 발송 실패:', error.code || error.message); }
    }
  }

  return { registerUser, enabledTokens, sendToDevices, processDrawResults, saveToFirestore };
}

module.exports = { createBackend, requireAdmin, validNumbers, calcGrade };
