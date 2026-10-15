'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { expectedRound, drawDate, detailsComplete, createLottoCollector } = require('../lotto_collection');
const { parseNaverDraw } = require('../lotto_source');
const draw = (round, extra = {}) => ({ round, date: drawDate(round), numbers: [1, 13, 18, 26, 34, 38], bonus: 25,
  prizes: {}, stores: [], updatedAt: '2026-10-04T12:00:00.000Z', ...extra });
const complete = (round) => draw(round, {
  prizes: Object.fromEntries([1, 2, 3, 4, 5].map((grade) => [grade, { count: 1, totalPrize: 1000, perPrize: 1000 }])),
  stores: [1, 2].map((grade) => ({ grade, name: '테스트', address: '서울' })),
});
const at = (time) => new Date(time + '+09:00');
function fixture(latest = 1243) {
  const docs = new Map([[latest, complete(latest)], [latest - 1, complete(latest - 1)]]);
  const available = new Map();
  const requests = [], saves = [], updates = [];
  const collect = createLottoCollector({
    getLatestRound: async () => latest, getDraw: async (round) => docs.get(round),
    fetchDraw: async (round) => { requests.push(round); return available.get(round) || null; },
    saveDraw: async (result, options) => {
      saves.push({ round: result.round, ...options }); docs.set(result.round, result); latest = Math.max(latest, result.round);
    },
    updateDetails: async (round, data) => { updates.push(round); docs.set(round, { ...docs.get(round), ...data }); },
    logger: { warn() {}, info() {}, error() {} },
  });
  return { docs, available, requests, saves, updates, collect };
}

test('KST boundary retains target through late night, midnight and the following week', () => {
  for (const [time, round] of [
    ['2026-10-03T20:34:59', 1243], ['2026-10-03T20:35:00', 1244], ['2026-10-03T23:15:00', 1244],
    ['2026-10-04T00:30:00', 1244], ['2026-10-10T20:34:59', 1244], ['2026-10-10T20:35:00', 1245],
  ]) assert.equal(expectedRound(at(time)), round);
  assert.equal(drawDate(1244), '2026-10-03');
});

test('23:00 publication is collected after earlier attempts returned last week', async () => {
  const f = fixture(); f.available.set(1244, complete(1243));
  assert.equal((await f.collect({ now: at('2026-10-03T20:45:00') })).pending, true);
  assert.equal(f.saves.length, 0);
  f.available.set(1244, complete(1244));
  assert.equal((await f.collect({ now: at('2026-10-03T23:10:00') })).pending, false);
  assert.deepEqual(f.saves, [{ round: 1244, broadcast: true }]);
  await f.collect({ now: at('2026-10-03T23:15:00'), includeDetails: true });
  assert.equal(f.saves.length, 1); assert.deepEqual(f.requests, [1244, 1244]);
});

test('detail recovery job also collects missing numbers after midnight', async () => {
  const f = fixture(); await f.collect({ now: at('2026-10-03T23:55:00') });
  f.available.set(1244, complete(1244));
  assert.deepEqual((await f.collect({ now: at('2026-10-04T02:07:00'), includeDetails: true })).saved, [1244]);
});

test('a missed week catches up to calendar target in one run, without historical push', async () => {
  const f = fixture(1242); f.available.set(1243, complete(1243)); f.available.set(1244, complete(1244));
  await f.collect({ now: at('2026-10-03T23:10:00') });
  assert.deepEqual(f.saves, [{ round: 1243, broadcast: false }, { round: 1244, broadcast: true }]);
  assert.deepEqual(f.requests, [1243, 1244]);
});

test('bounded backlog continues next run and never skips an unavailable earlier round', async () => {
  const f = fixture(1239); for (let r = 1240; r <= 1244; r++) f.available.set(r, complete(r));
  assert.deepEqual((await f.collect({ now: at('2026-10-04T01:00:00') })).saved, [1240, 1241, 1242]);
  f.available.delete(1243);
  assert.deepEqual((await f.collect({ now: at('2026-10-04T02:00:00') })).saved, []);
  assert.equal(f.requests.includes(1244), false); f.available.set(1243, complete(1243));
  assert.deepEqual((await f.collect({ now: at('2026-10-04T03:00:00') })).saved, [1243, 1244]);
});

test('correct round with wrong date or invalid numbers is never saved', async () => {
  const f = fixture();
  for (const bad of [draw(1244, { date: '2026-09-26' }), draw(1244, { bonus: 1 }), draw(1244, { numbers: [1, 1, 2, 3, 4, 5] })]) {
    f.available.set(1244, bad); await f.collect({ now: at('2026-10-04T01:00:00') });
  }
  assert.equal(f.saves.length, 0);
});

test('details finish later without losing partial data or sending results again', async () => {
  const f = fixture();
  f.available.set(1244, draw(1244, { prizes: { 1: complete(1244).prizes[1] }, stores: [{ grade: 1, name: '기존', address: '서울' }] }));
  await f.collect({ now: at('2026-10-03T23:10:00') });
  f.available.set(1244, draw(1244, { prizes: { 1: { count: 0, totalPrize: 0, perPrize: 0 } } }));
  await f.collect({ now: at('2026-10-04T00:07:00'), includeDetails: true });
  assert.equal(f.docs.get(1244).prizes[1].perPrize, 1000); assert.equal(f.docs.get(1244).stores.length, 1);
  f.available.set(1244, complete(1244));
  await f.collect({ now: at('2026-10-04T00:37:00'), includeDetails: true });
  assert.equal(detailsComplete(f.docs.get(1244)), true); assert.equal(f.saves.length, 1);
});

test('contradictory source cannot attach prizes to different stored numbers', async () => {
  const f = fixture(1244); f.docs.set(1244, draw(1244)); f.available.set(1244, complete(1244));
  f.available.get(1244).numbers = [2, 13, 18, 26, 34, 38];
  await f.collect({ now: at('2026-10-04T00:37:00'), includeDetails: true });
  assert.equal(f.updates.length, 0);
});

test('does not request a future draw before polling starts', async () => {
  const f = fixture(); await f.collect({ now: at('2026-10-03T20:00:00') }); assert.deepEqual(f.requests, []);
});

function html({ round = 1244, date = '2026.10.03', numbers = [1, 13, 18, 26, 34, 38], bonus = 25 } = {}) {
  const balls = (items) => items.map((n) => `<span class="ball type1">${n}</span>`).join('');
  return `${balls([44, 43, 42, 41, 40, 39, 38])}<div class="sc_new cs_lotto _lotto">
    <a class="text _select_trigger _text">${round}회차 (${date}.)</a><a>1244회차 (2026.10.03.)</a>
    <div class="winning_number">${balls(numbers)}</div><div class="bonus_number">${balls([bonus])}</div></div>`;
}

test('parser validates selected draw, ignoring outside numbers and round dropdown entries', () => {
  assert.deepEqual(parseNaverDraw(html(), 1244).numbers, [1, 13, 18, 26, 34, 38]);
  for (const input of [html({ round: 1243, date: '2026.09.26' }), html({ date: '2026.09.26' }),
    html({ bonus: 1 }), html({ numbers: [1, 1, 2, 3, 4, 5] }), html({ numbers: [1, 2, 3] }), '<html>준비 중</html>']) {
    assert.equal(parseNaverDraw(input, 1244), null);
  }
});


test('all-zero unpublished prizes stay pending, while no first-prize winner is supported', () => {
  const empty = complete(1244);
  for (const grade of [1, 2, 3, 4, 5]) empty.prizes[grade] = { count: 0, totalPrize: 0, perPrize: 0 };
  empty.stores = [];
  assert.equal(detailsComplete(empty), false);
  const noFirst = complete(1244);
  noFirst.prizes[1] = { count: 0, totalPrize: 0, perPrize: 0 };
  noFirst.stores = noFirst.stores.filter((store) => store.grade !== 1);
  assert.equal(detailsComplete(noFirst), true);
});
