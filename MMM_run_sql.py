"""
Run MMM_production_scoring.sql through Python, part by part. No Snowflake worksheet needed.

    python MMM_run_sql.py setup              # Part 1  (once): tables, registry, v3 weights, spam-guard view
    python MMM_run_sql.py daily              # Parts 2+3 (every morning, before Make sends): score + pick
    python MMM_run_sql.py daily --daily-n 150   # same, with a different volume for today
    python MMM_run_sql.py confirm            # Part 4  (after Make has sent): log confirmed sends
    python MMM_run_sql.py checks             # Part 5  : pool size, arm balance, must-be-zero checks
    python MMM_run_sql.py build-tasks        # no Snowflake: after editing Parts 2-4 of the production SQL,
                                             # rewrite the procedure bodies in MMM_snowflake_tasks.sql to match

It uses the same Snowflake connection as MMM_auto_retrain.py (RSA key from S3, keys from .env)
and always runs the SET lines at the top of the SQL file first, so the parts see the same settings
they would in a worksheet.
"""
import argparse
import os
import re
import sys
from datetime import datetime

import pandas as pd

def get_snowflake_conn():
    from MMM_auto_retrain import get_snowflake_conn as _conn   # also loads .env; imported lazily so
    return _conn()                                            # build-tasks works without Snowflake packages

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_FILE = os.path.join(HERE, 'MMM_production_scoring.sql')
TASKS_FILE = os.path.join(HERE, 'MMM_snowflake_tasks.sql')
pd.set_option('display.width', 200, 'display.max_columns', 30)


def log(*a):
    print(f'[{datetime.now():%H:%M:%S}]', *a, flush=True)


def split_statements(sql: str) -> list:
    """Split SQL into statements, dropping comments. Understands '...' strings, "..." identifiers,
    -- line comments and /* */ block comments, so apostrophes or semicolons in comments are harmless."""
    out, buf, i, n = [], [], 0, len(sql)
    while i < n:
        c, nxt = sql[i], sql[i + 1] if i + 1 < n else ''
        if c == '-' and nxt == '-':                       # line comment
            j = sql.find('\n', i); i = n if j == -1 else j
            continue
        if c == '/' and nxt == '*':                       # block comment
            j = sql.find('*/', i + 2); i = n if j == -1 else j + 2
            buf.append(' ')
            continue
        if c in ("'", '"'):                               # string literal or quoted identifier
            q, j = c, i + 1
            while j < n:
                if sql[j] == '\\' and q == "'":
                    j += 2; continue
                if sql[j] == q:
                    if j + 1 < n and sql[j + 1] == q:
                        j += 2; continue
                    break
                j += 1
            buf.append(sql[i:j + 1]); i = j + 1
            continue
        if c == ';':
            stmt = ''.join(buf).strip()
            if stmt:
                out.append(stmt)
            buf = []; i += 1
            continue
        buf.append(c); i += 1
    tail = ''.join(buf).strip()
    if tail:
        out.append(tail)
    return out


def load_parts() -> dict:
    """{'header': [...], 1: [...], ..., 5: [...]} — statements of each PART of the SQL file."""
    text = open(SQL_FILE, encoding='utf-8').read()
    marks = [(int(m.group(1)), text.rfind('/*', 0, m.start()))
             for m in re.finditer(r'^\s*PART ([1-5]) —', text, flags=re.M)]
    parts = {'header': split_statements(text[:marks[0][1]])}
    for k, (num, start) in enumerate(marks):
        end = marks[k + 1][1] if k + 1 < len(marks) else len(text)
        parts[num] = split_statements(text[start:end])
    return parts


def run(conn, statements, label):
    cur = conn.cursor()
    for k, stmt in enumerate(statements, 1):
        first = ' '.join(stmt.split())[:90]
        log(f'{label} [{k}/{len(statements)}] {first}...')
        cur.execute(stmt)
        head = stmt.lstrip().split(None, 1)[0].upper()
        if head in ('SELECT', 'WITH') and cur.description:
            df = cur.fetch_pandas_all()
            print(df.to_string(index=False) if len(df) else '   (no rows)', flush=True)
        elif head in ('INSERT', 'DELETE', 'UPDATE') and cur.rowcount is not None:
            print(f'   rows affected: {cur.rowcount}', flush=True)
    cur.close()


def build_tasks():
    """Copy Parts 2-4 of MMM_production_scoring.sql into the two procedures in MMM_snowflake_tasks.sql.
    Session variables cannot be used inside procedures, so each statement becomes an EXECUTE IMMEDIATE
    string with $model_version / $daily_n / $cooldown_days replaced by procedure values."""
    parts = load_parts()
    q = "'"
    MV = q * 3 + ' || mv || ' + q * 3            # ->  'MMM_vX'  inside the generated SQL
    DN = q + ' || P_DAILY_N::VARCHAR || ' + q
    CD = q + ' || P_COOLDOWN_DAYS::VARCHAR || ' + q

    def subst(text, mv, dn, cd):
        text = re.sub(r'\$model_version\b', lambda _: mv, text, flags=re.I)
        text = re.sub(r'\$daily_n\b', lambda _: dn, text, flags=re.I)
        return re.sub(r'\$cooldown_days\b', lambda _: cd, text, flags=re.I)

    def dyn(stmt):
        e = subst(stmt.replace(q, q * 2), MV, DN, CD)
        if '$' in e or '\\' in e:
            raise ValueError('statement contains $ or a backslash that cannot be embedded safely:\n' + stmt[:200])
        back = e.replace(MV, "'X'").replace(DN, '1').replace(CD, '2').replace(q * 2, q)
        if back != subst(stmt, "'X'", '1', '2'):
            raise ValueError('round-trip check failed for:\n' + stmt[:200])
        return e

    def block(stmts, label):
        return '\n\n'.join(f"    -- {label} statement {k}: {' '.join(s.split())[:70]}...\n"
                           f"    stmt := '{dyn(s)}';\n    EXECUTE IMMEDIATE :stmt;"
                           for k, s in enumerate(stmts, 1))

    p2 = [s for s in parts[2] if not s.upper().startswith('SET MODEL_VERSION')]
    txt = open(TASKS_FILE, encoding='utf-8').read()
    for head, tail, stmts, label in [
            ("    -- ===== PART 2: score everyone eligible =====\n",
             "\n\n    SELECT COUNT(*), COUNT_IF(selectable) INTO :n_eligible, :n_select", p2, 'part 2'),
            ("    -- ===== PART 3: pick today's people, log every pick, build SEND_TODAY =====\n",
             "\n\n    SELECT COUNT(*) INTO :n_send", parts[3], 'part 3'),
            ("    n_unsent   NUMBER;\nBEGIN\n", "\n\n    SELECT COUNT(*) INTO :n_sent", parts[4], 'part 4')]:
        a = txt.index(head) + len(head)
        b = txt.index(tail, a)
        txt = txt[:a] + block(stmts, label) + txt[b:]
    open(TASKS_FILE, 'w', encoding='utf-8').write(txt)
    log(f'rewrote the procedure bodies in {TASKS_FILE}. Now run that file in a Snowflake worksheet '
        f'(before go-live: Run All; after go-live: only the two CREATE PROCEDURE blocks).')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('step', choices=['setup', 'daily', 'confirm', 'checks', 'build-tasks'])
    ap.add_argument('--daily-n', type=int, help='override SET daily_n for this run')
    args = ap.parse_args()

    if args.step == 'build-tasks':
        build_tasks()
        return 0

    parts = load_parts()
    plan = {'setup': [1], 'daily': [2, 3, 5], 'confirm': [4], 'checks': [5]}[args.step]
    conn = get_snowflake_conn()
    log('connected to Snowflake')
    try:
        run(conn, parts['header'], 'settings')
        if args.daily_n:
            run(conn, [f'SET daily_n = {int(args.daily_n)}'], 'settings')
        for p in plan:
            run(conn, parts[p], f'part {p}')
    finally:
        conn.close()
    log(f'{args.step} finished')
    if args.step == 'daily':
        log('SEND_TODAY is ready for Make: PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CONTINUOUS_PUSH_CAMPAIGN_SEND_TODAY')
    return 0


if __name__ == '__main__':
    sys.exit(main())