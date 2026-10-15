'use strict';
const { validNumbers } = require('./backend');
const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
const FIRST_DATE = Date.UTC(2002, 11, 7);
// This is the start of polling, never proof that a result has been published.
const FIRST_POLL = Date.parse('2002-12-07T20:35:00+09:00');

function drawDate(round) {
  return new Date(FIRST_DATE + (round - 1) * WEEK_MS).toISOString().slice(0, 10);
}

function expectedRound(now = new Date()) {
  return Math.max(0, Math.floor((now.getTime() - FIRST_POLL) / WEEK_MS) + 1);
}

function isValidDraw(result, round) {
  return !!result && Number.isSafeInteger(round) && round > 0 &&
    result.round === round && result.date === drawDate(round) &&
    validNumbers(result.numbers) && Number.isInteger(result.bonus) &&
    result.bonus >= 1 && result.bonus <= 45 && !result.numbers.includes(result.bonus);
}

function validPrize(prize) {
  return !!prize && ['count', 'totalPrize', 'perPrize'].every((key) =>
    Number.isSafeInteger(prize[key]) && prize[key] >= 0) &&
    (prize.count === 0 || (prize.totalPrize > 0 && prize.perPrize > 0));
}

function detailsComplete(result) {
  return [1, 2, 3, 4, 5].every((grade) => validPrize(result?.prizes?.[grade])) &&
    Object.values(result.prizes).some((prize) => prize.count > 0) &&
    [1, 2].every((grade) => result.prizes[grade].count === 0 ||
      result.stores?.some((store) => store.grade === grade && store.name && store.address));
}

// A partial publication must not erase already collected prizes or stores.
function mergeDetails(previous, incoming) {
  const prizes = { ...previous.prizes };
  for (const [grade, prize] of Object.entries(incoming.prizes || {})) {
    if (validPrize(prize) &&
        (!validPrize(prizes[grade]) || prize.count > 0 || prizes[grade].count === 0)) {
      prizes[grade] = prize;
    }
  }
  const oldStores = previous.stores || [];
  const newStores = incoming.stores || [];
  const stores = [1, 2].flatMap((grade) => {
    const next = newStores.filter((store) => store.grade === grade);
    const old = oldStores.filter((store) => store.grade === grade);
    return next.length >= old.length ? next : old;
  });
  return { prizes, stores, updatedAt: incoming.updatedAt };
}

function createLottoCollector({ getLatestRound, getDraw, fetchDraw, saveDraw, updateDetails,
  reportPending = async () => {}, logger = console }) {
  return async function collect({ now = new Date(), includeDetails = false, broadcast = true } = {}) {
    const target = expectedRound(now);
    let latest = await getLatestRound();
    const saved = [];
    // Bounded catch-up: a missed week must not consume the next week's only attempt.
    for (let n = 0; latest < target && n < 3; n++) {
      const round = latest + 1;
      const result = await fetchDraw(round);
      if (!isValidDraw(result, round)) {
        logger.warn(`[lotto] ${round}회 결과 미게시/검증 실패. 다음 실행에서 재시도 (목표 ${target}회)`);
        break;
      }
      // Never broadcast historical catch-up as this week's result.
      await saveDraw(result, { broadcast: broadcast && round === target });
      saved.push(round);
      latest = round;
    }
    // Revisit two recent rounds so delayed details can finish across a week boundary.
    if (includeDetails) {
      for (let round = Math.min(latest, target); round > Math.max(0, Math.min(latest, target) - 2); round--) {
        const previous = await getDraw(round);
        if (!previous || detailsComplete(previous)) continue;
        const result = await fetchDraw(round);
        if (!isValidDraw(result, round)) continue;
        if (previous.bonus !== result.bonus ||
          [...previous.numbers].sort((a, b) => a - b).join() !==
          [...result.numbers].sort((a, b) => a - b).join()) {
          logger.error(`[lotto] ${round}회 저장된 번호와 원본 불일치. 상세 갱신 보류`);
          continue;
        }
        await updateDetails(round, mergeDetails(previous, result));
      }
    }
    const status = { target, latest, saved, pending: latest < target };
    if (status.pending && now.getTime() - (FIRST_POLL + (target - 1) * WEEK_MS) >= 12 * 60 * 60 * 1000) {
      await reportPending(latest + 1);
    }
    logger.info('[lotto] 수집 확인', status);
    return status;
  };
}

module.exports = { drawDate, expectedRound, isValidDraw, detailsComplete, mergeDetails, createLottoCollector };
