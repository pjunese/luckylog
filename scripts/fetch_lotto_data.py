"""
로또 전체 회차 당첨번호 수집 스크립트
사용법: python3 scripts/fetch_lotto_data.py
결과: assets/lotto_history.json
"""

import urllib.request
import urllib.parse
import re
import json
import time
import random
import os

TOTAL_ROUNDS = 1217
OUTPUT_PATH = os.path.join(os.path.dirname(__file__), '..', 'assets', 'lotto_history.json')

USER_AGENTS = [
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 13_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Safari/605.1.15',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
]


def fetch_round(round_num, retry=3):
    query = urllib.parse.quote(f'로또 {round_num}')
    url = f'https://search.naver.com/search.naver?query={query}'

    for attempt in range(retry):
        try:
            req = urllib.request.Request(url, headers={
                'User-Agent': random.choice(USER_AGENTS),
                'Accept-Language': 'ko-KR,ko;q=0.9',
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            })
            with urllib.request.urlopen(req, timeout=10) as res:
                html = res.read().decode('utf-8')

            balls = re.findall(r'<span[^>]*ball[^>]*>(\d+)<', html)
            lotto_section = html[html.find('cs_lotto'):html.find('cs_lotto') + 600]
            date_match = re.search(r'(\d{4}\.\d{2}\.\d{2})', lotto_section)

            if len(balls) >= 7:
                return {
                    'round': round_num,
                    'numbers': [int(b) for b in balls[:6]],
                    'bonus': int(balls[6]),
                    'date': date_match.group(1).replace('.', '-') if date_match else '',
                }
        except Exception as e:
            if attempt < retry - 1:
                wait = 5 + random.uniform(2, 5)
                print(f'    재시도 {attempt+1}/{retry} ({round_num}회) - {wait:.1f}초 대기...')
                time.sleep(wait)
            else:
                print(f'  ❌ {round_num}회 최종 실패: {e}')
    return None


def main():
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)

    # 기존 데이터 로드 (이어서 수집 가능)
    existing = {}
    if os.path.exists(OUTPUT_PATH):
        with open(OUTPUT_PATH, 'r') as f:
            data = json.load(f)
            existing = {d['round']: d for d in data}
        print(f'기존 데이터: {len(existing)}회차 로드됨')

    missing = [r for r in range(1, TOTAL_ROUNDS + 1) if r not in existing]
    print(f'수집 필요: {len(missing)}회차')
    print(f'예상 시간: 약 {len(missing) * 2 // 60}분\n')

    if not missing:
        print('✅ 이미 모든 데이터가 있습니다!')
        return

    results = dict(existing)
    failed = []

    for i, round_num in enumerate(missing):
        result = fetch_round(round_num)

        if result:
            results[result['round']] = result
            print(f'  ✅ {result["round"]}회: {result["numbers"]} +{result["bonus"]}  ({i+1}/{len(missing)})')
        else:
            failed.append(round_num)

        # 50개마다 저장
        if (i + 1) % 50 == 0:
            _save(results, OUTPUT_PATH)
            print(f'\n💾 중간 저장 ({len(results)}회차)\n')

        # 요청 간 랜덤 딜레이 (1.5~3초)
        time.sleep(random.uniform(1.5, 3.0))

    _save(results, OUTPUT_PATH)
    print(f'\n✅ 완료! 총 {len(results)}회차 저장됨')

    if failed:
        print(f'⚠️  실패한 회차 {len(failed)}개: {failed[:20]}{"..." if len(failed) > 20 else ""}')
        print('다시 스크립트 실행하면 실패 회차만 재시도합니다.')


def _save(results, path):
    sorted_data = [results[r] for r in sorted(results.keys())]
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(sorted_data, f, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
