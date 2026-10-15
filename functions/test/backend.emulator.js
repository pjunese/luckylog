'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { doc, setDoc, updateDoc, getDoc, deleteDoc, serverTimestamp, deleteField, setLogLevel } = require('firebase/firestore');
const { initializeApp, deleteApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { HttpsError } = require('firebase-functions/v2/https');
const { createBackend } = require('../backend');
const projectId = 'demo-lotto-fix';
setLogLevel('silent');
let env, app, db, core, sent;
const auth = (uid) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'custom' } } } });
const draw = (round) => ({ round, numbers: [1, 2, 3, 4, 5, 6], bonus: 7,
  date: '2026-09-05', updatedAt: new Date().toISOString() });

test.before(async () => {
  if (!process.env.FIRESTORE_EMULATOR_HOST) throw new Error('FIRESTORE_EMULATOR_HOST is required; never run against production');
  env = await initializeTestEnvironment({ projectId,
    firestore: { rules: fs.readFileSync(path.join(__dirname, '../../firestore.rules'), 'utf8') } });
  app = initializeApp({ projectId }, 'backend-security-tests');
  db = getFirestore(app);
  sent = [];
  core = createBackend({ db, FieldValue, HttpsError, messaging: { send: async (payload) => {
    sent.push(payload); return 'fake-message-id';
  } } });
});
test.beforeEach(async () => { await env.clearFirestore(); sent.length = 0; });
test.after(async () => { await db?.terminate(); if (app) await deleteApp(app); await env?.cleanup(); });

test('concurrent registration is idempotent and assigns distinct numbers to distinct users', async () => {
  const results = await Promise.all([core.registerUser(auth('kakao:1')), core.registerUser(auth('kakao:1')),
    core.registerUser(auth('kakao:2')), core.registerUser(auth('apple:subject'))]);
  assert.equal(results[0].userNumber, results[1].userNumber);
  assert.equal(new Set([results[0].userNumber, results[2].userNumber, results[3].userNumber]).size, 3);
  assert.equal((await db.doc('meta/userCount').get()).data().count, 3);
  assert.deepEqual(await core.registerUser({ ...auth('kakao:1'), data: { uid: 'kakao:999', userNumber: 42, provider: 'apple' } }), results[0]);
  assert.equal((await db.doc('users/kakao:999').get()).exists, false);
  await assert.rejects(core.registerUser({}), { code: 'unauthenticated' });
  await assert.rejects(core.registerUser({ auth: { uid: 'kakao:1', token: {} } }), { code: 'permission-denied' });
});

test('legacy migration preserves existing targets, copies children, and cannot cross providers', async () => {
  await db.doc('users/10').set({ userNumber: 50, nickname: '원래 별명', fcmToken: 'old' });
  await db.doc('users/10/number_sets/a').set({ numbers: '[1,2,3,4,5,6]' });
  await db.doc('users/10/purchase_history/keep').set({ round: 1230, games: '[[1,2,3,4,5,6]]' });
  await db.doc('users/kakao:10/purchase_history/keep').set({ deleted: true, round: 1230 });
  assert.deepEqual(await core.registerUser(auth('kakao:10')), { userNumber: 50 });
  assert.equal((await db.doc('users/kakao:10').get()).data().nickname, '원래 별명');
  assert.equal((await db.doc('users/kakao:10/number_sets/a').get()).exists, true);
  assert.equal((await db.doc('users/kakao:10/purchase_history/keep').get()).data().deleted, true);
  assert.equal((await db.doc('users/10').get()).data().migratedTo, 'kakao:10');
  assert.equal((await db.doc('users/kakao:10').get()).data().fcmToken, undefined);
  assert.equal((await core.registerUser(auth('apple:10'))).userNumber, 51);
  assert.equal((await db.doc('users/apple:10/number_sets/a').get()).exists, false);
  assert.equal((await core.registerUser(auth('kakao:11'))).userNumber, 52);
});

test('interrupted legacy migration resumes without renumbering and tolerates malformed old payloads', async () => {
  await db.doc('users/20').set({ userNumber: 'broken', nickname: { invalid: true } });
  await db.doc('users/20/purchase_history/bad').set({ games: 'invalid JSON', round: 'old' });
  let calls = 0;
  const failingDb = {
    collection: db.collection.bind(db),
    runTransaction: async (callback) => {
      if (++calls === 2) throw new Error('simulated interrupted copy');
      return db.runTransaction(callback);
    },
  };
  const interrupted = createBackend({ db: failingDb, FieldValue, HttpsError, messaging: { send: async () => {} } });
  await assert.rejects(interrupted.registerUser(auth('kakao:20')), /simulated interrupted copy/);
  assert.equal((await db.doc('users/kakao:20').get()).data().userNumber, 1);
  assert.deepEqual(await core.registerUser(auth('kakao:20')), { userNumber: 1 });
  assert.equal((await db.doc('users/kakao:20').get()).data().nickname, 'user_1');
  assert.equal((await db.doc('users/kakao:20/purchase_history/bad').get()).data().games, 'invalid JSON');
  assert.equal((await db.doc('meta/userCount').get()).data().count, 1);
});

test('owner can edit profile and sync records, but identity, counter, other users and hard deletion are protected', async () => {
  await core.registerUser(auth('kakao:1'));
  const mine = env.authenticatedContext('kakao:1').firestore();
  const other = env.authenticatedContext('kakao:2').firestore();
  const user = doc(mine, 'users/kakao:1');
  await assertSucceeds(updateDoc(user, { nickname: '새 별명', updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(user, { userNumber: 99 }));
  await assertFails(updateDoc(user, { provider: 'apple' }));
  await assertFails(updateDoc(user, { migratedTo: 'kakao:2' }));
  await assertFails(setDoc(doc(mine, 'meta/userCount'), { count: 100 }));
  await assertFails(setDoc(doc(mine, 'users/kakao:3'), { userNumber: 3 }));
  await assertFails(getDoc(doc(other, 'users/kakao:1')));
  await assertFails(deleteDoc(user));
  const record = doc(mine, 'users/kakao:1/purchase_history/one');
  await assertSucceeds(setDoc(record, { games: '[[1,2,3,4,5,6]]', round: 1230, updatedAt: serverTimestamp() }));
  await assertFails(getDoc(doc(other, 'users/kakao:1/purchase_history/one')));
  await assertSucceeds(updateDoc(record, { deleted: true, updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(record, { deleted: false, updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(record, { deleted: deleteField(), updatedAt: serverTimestamp() }));
  await assertFails(deleteDoc(record));
  await assertFails(setDoc(doc(mine, 'users/kakao:1/purchase_history/future'), {
    round: 1230, games: '[]', updatedAt: new Date('2100-01-01'),
  }));
  await assertFails(setDoc(doc(mine, 'users/kakao:1/purchase_history/missing-time'), {
    round: 1230, games: '[]',
  }));
});

test('device writes require ownership, bounded token and server timestamp; shared legacy token only removable', async () => {
  await core.registerUser(auth('kakao:1'));
  const mine = env.authenticatedContext('kakao:1').firestore();
  const device = doc(mine, 'users/kakao:1/devices/install');
  await assertSucceeds(setDoc(device, { token: 'token', enabled: true, updatedAt: serverTimestamp() }));
  await assertSucceeds(updateDoc(device, { enabled: false, token: deleteField(), updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(device, { enabled: true, updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(device, { enabled: 'yes', updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(device, { token: 'a'.repeat(4097), updatedAt: serverTimestamp() }));
  await assertFails(setDoc(doc(env.authenticatedContext('kakao:2').firestore(), 'users/kakao:1/devices/foreign'),
    { token: 'x', enabled: true, updatedAt: serverTimestamp() }));
  await db.doc('users/kakao:1').update({ fcmToken: 'legacy', fcmTokenUpdatedAt: new Date() });
  await assertFails(updateDoc(doc(mine, 'users/kakao:1'), { fcmToken: 'new' }));
  await assertSucceeds(updateDoc(doc(mine, 'users/kakao:1'), { fcmToken: deleteField(), fcmTokenUpdatedAt: deleteField() }));
});

test('guest feedback keeps working with bounded fields and no impersonation or reads', async () => {
  const guest = env.unauthenticatedContext().firestore();
  const payload = { category: '버그 신고', text: '테스트', userNumber: 0, provider: 'guest', createdAt: serverTimestamp() };
  await assertSucceeds(setDoc(doc(guest, 'feedback/good'), payload));
  await assertFails(setDoc(doc(guest, 'feedback/long'), { ...payload, text: 'x'.repeat(501) }));
  await assertFails(setDoc(doc(guest, 'feedback/fake'), { ...payload, userNumber: 1, provider: 'kakao' }));
  await assertFails(setDoc(doc(guest, 'feedback/extra'), { ...payload, extra: true }));
  await assertFails(getDoc(doc(guest, 'feedback/good')));
});

test('backfill and repeated saves never move latest backwards or send notifications', async () => {
  await db.doc('meta/latest').set({ round: 1230 });
  await core.saveToFirestore(draw(1229), { broadcast: true });
  assert.equal((await db.doc('meta/latest').get()).data().round, 1230);
  assert.equal(sent.length, 0);
  await core.saveToFirestore(draw(1231)); // manual save is silent even if newer
  assert.equal((await db.doc('meta/latest').get()).data().round, 1231);
  assert.equal(sent.length, 0);
  await Promise.all([core.saveToFirestore(draw(1232), { broadcast: true }), core.saveToFirestore(draw(1232), { broadcast: true })]);
  assert.equal(sent.filter((message) => message.topic === 'draw_result').length, 1);
  assert.equal((await db.doc('service_stats/1232').get()).exists, true);
});

test('result processing ignores malformed/deleted games and sends only enabled device tokens', async () => {
  for (const uid of ['kakao:1', 'kakao:2', 'kakao:3']) await db.doc(`users/${uid}`).set({ fcmToken: `legacy-${uid}` });
  await db.doc('users/kakao:1/purchase_history/valid').set({ round: 1230, games: '[[1,2,3,4,5,6],[1,1,1,1,1,1],[1,2,3,4,5,46]]' });
  await db.doc('users/kakao:1/purchase_history/deleted').set({ round: 1230, deleted: true, games: '[[1,2,3,4,5,6]]' });
  await db.doc('users/kakao:2/purchase_history/only-deleted').set({ round: 1230, deleted: true, games: '[[1,2,3,4,5,6]]' });
  await db.doc('users/kakao:3/purchase_history/valid').set({ round: 1230, games: '[[1,2,3,4,5,7]]' });
  await db.doc('users/kakao:1/devices/yes').set({ token: 'enabled', enabled: true });
  await db.doc('users/kakao:1/devices/no').set({ token: 'disabled', enabled: false });
  await core.saveToFirestore(draw(1230), { broadcast: true });
  const stats = (await db.doc('service_stats/1230').get()).data();
  assert.equal(stats.totalSets, 2);
  assert.equal(stats.totalParticipants, 2);
  assert.equal(stats.winners[1], 1);
  assert.equal(stats.winners[2], 1);
  assert.deepEqual(sent.filter((message) => message.token).map((message) => message.token), ['enabled']);
  await assert.rejects(core.saveToFirestore({ ...draw(1231), numbers: [1, 1, 1, 1, 1, 1] }));
});

test('save waits for personal notification completion before resolving', async () => {
  await db.doc('users/kakao:1').set({});
  await db.doc('users/kakao:1/purchase_history/ticket').set({ round: 1230, games: '[[1,2,3,4,5,6]]' });
  await db.doc('users/kakao:1/devices/yes').set({ token: 'slow', enabled: true });
  let release, entered;
  const gate = new Promise((resolve) => { release = resolve; });
  const started = new Promise((resolve) => { entered = resolve; });
  const slow = createBackend({ db, FieldValue, HttpsError, messaging: { send: async (message) => {
    if (message.token) { entered(); await gate; }
  } } });
  let finished = false;
  const pending = slow.saveToFirestore(draw(1230), { broadcast: true }).then(() => { finished = true; });
  await started;
  assert.equal(finished, false);
  release();
  await pending;
  assert.equal((await db.doc('service_stats/1230').get()).data().totalSets, 1);
});
