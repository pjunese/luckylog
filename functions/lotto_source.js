'use strict';
const axios = require('axios');
const { isValidDraw } = require('./lotto_collection');

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

// Validate the selected draw, not a matching entry elsewhere in the year/round menu.
function parseNaverDraw(html, round, now = new Date()) {
  if (typeof html !== 'string') return null;
  const start = html.search(/<div\b[^>]*class=["'][^"']*\bcs_lotto\b/);
  if (start < 0) return null;
  const nextSection = html.indexOf('<div class="sc_new ', start + 1);
  const section = html.slice(start, nextSection < 0 ? undefined : nextSection);
  const selected = section.match(/<a\b[^>]*class=["'][^"']*\b_select_trigger\b[^"']*["'][^>]*>\s*(\d+)회차\s*\((\d{4}\.\d{2}\.\d{2})\.?\)/);
  if (!selected || Number(selected[1]) !== round) return null;
  const extractBalls = (className) => {
    const block = section.match(new RegExp(`<div\\b[^>]*class=["'][^"']*\\b${className}\\b[^"']*["'][^>]*>([\\s\\S]*?)<\\/div>`));
    return block ? [...block[1].matchAll(/<span\b[^>]*class=["'][^"']*\bball\b[^"']*["'][^>]*>\s*(\d+)\s*<\/span>/g)]
      .map((match) => Number(match[1])) : [];
  };
  const numbers = extractBalls('winning_number');
  const bonuses = extractBalls('bonus_number');
  if (bonuses.length !== 1) return null;
  const result = {
    round, date: selected[2].replace(/\./g, '-'), numbers, bonus: bonuses[0],
    prizes: _parsePrizeTable(section), stores: _parseWinningStores(section),
    updatedAt: now.toISOString(),
  };
  return isValidDraw(result, round) ? result : null;
}

async function fetchFromNaver(round, retry = 3) {
  const url = `https://search.naver.com/search.naver?query=${encodeURIComponent(`로또 ${round}회`)}`;
  const headers = {
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Accept-Language': 'ko-KR,ko;q=0.9',
    Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  };
  for (let attempt = 0; attempt < retry; attempt++) {
    try {
      const res = await axios.get(url, { headers, timeout: 10000 });
      const result = parseNaverDraw(res.data, round);
      if (!result) console.warn(`[naver] ${round}회 결과 미게시 또는 회차/날짜/번호 검증 실패`);
      // Repeated requests cannot make an unpublished draw ready. The scheduler retries later.
      return result;
    } catch (error) {
      console.warn(`[naver] ${round}회 요청 ${attempt + 1}/${retry} 실패:`, error.message);
      if (attempt < retry - 1) await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
  return null;
}

module.exports = { parseNaverDraw, fetchFromNaver };
