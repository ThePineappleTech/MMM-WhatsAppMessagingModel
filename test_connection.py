"""Quick checks before the first MMM retrain.   Run:  python test_connection.py"""
import importlib

print('1) packages ...')
for pkg in ['pandas', 'numpy', 'sklearn', 'boto3', 'cryptography', 'snowflake.connector', 'dotenv']:
    try:
        importlib.import_module(pkg)
        print(f'   ok       {pkg}')
    except ImportError:
        print(f'   MISSING  {pkg}   -> run: pip install -r requirements.txt')
        raise SystemExit(1)

import os
from dotenv import load_dotenv, dotenv_values

here = os.path.dirname(os.path.abspath(__file__))
env_path = os.path.join(here, '.env')
print('2) AWS keys from .env ...')
if not os.path.exists(env_path):
    print(f'   MISSING  no .env file at {env_path}')
else:
    names = list(dotenv_values(env_path).keys())
    print(f'   .env contains these NAMES (values not shown): {names}')
load_dotenv(env_path)
for k in ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY']:
    print(f'   {"ok     " if os.getenv(k) else "MISSING"}  {k}')
if not (os.getenv('AWS_ACCESS_KEY_ID') and os.getenv('AWS_SECRET_ACCESS_KEY')):
    print('   -> the .env must have lines named exactly AWS_ACCESS_KEY_ID=... and AWS_SECRET_ACCESS_KEY=...')
    raise SystemExit(1)

import MMM_auto_retrain as a

print('3) Snowflake login (downloads the key from S3, then logs in as PROGRAM) ...')
conn = a.get_snowflake_conn()
cur = conn.cursor()
print('   ok      ', cur.execute('select current_user(), current_role()').fetchone())

print('4) MMM tables (needs Part 1 of MMM_production_scoring.sql to have been run) ...')
for t in ['CPC_MODEL_REGISTRY', 'CPC_MODEL_WEIGHTS', 'CONTINUOUS_PUSH_CAMPAIGN_HISTORY']:
    try:
        n = cur.execute(f'select count(*) from PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.{t}').fetchone()[0]
        print(f'   ok       {t}: {n} rows')
    except Exception as e:
        print(f'   PROBLEM  {t}: {str(e).splitlines()[0]}')
try:
    print('   champion:', cur.execute("""select model_version from PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_MODEL_REGISTRY
                                         where status = 'champion' order by promoted_at desc limit 1""").fetchone())
except Exception:
    pass
conn.close()
print('done - if everything says ok, run:  python MMM_auto_retrain.py --dry-run')
