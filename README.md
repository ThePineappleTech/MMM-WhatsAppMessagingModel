# MMM — Moving Messaging Model

MMM picks, every morning, which leads should get a WhatsApp discount message today. It replaces the
monthly bulk discount campaigns (Jul / Aug / Sep 2026) with a continuous daily process: a small,
model-ranked batch every day, a random control group to measure what the messages actually add, and a
ledger of everyone ever picked or messaged.

Snowflake does the daily work (SQL stored procedures on a schedule). Python is only used once a month
to retrain the model. The send itself is done by a separate Make process that reads one table.

*Glossary:* **MMM** = Moving Messaging Model. **CPC** = continuous push campaign (the prefix of the
Snowflake tables). **Q2S** = quoted, never bought (split into quote < 45 days and > 45 days old).
**L2S** = lead that never quoted. **UCID** = tracking code on the link in the message (a click creates a
lead with that UCID). **Template ID** = the approved WhatsApp template Twilio sent. **AUC** = how well a
model ranks people (0.5 = random, 1.0 = perfect).

---

## 1. How a day works

| Time (SAST) | Who | What happens |
|---|---|---|
| 10:30 Mon–Sat | Snowflake task `MMM_DAILY_PICK_TASK` | Scores everyone eligible with the current champion model, holds back anyone who must not be messaged, picks the top 2 × `daily_n` (default 200), logs **every** pick in the ledger, and fills `SEND_TODAY` with the treated half (+ today's date). |
| During the day | Make | Reads `CONTINUOUS_PUSH_CAMPAIGN_SEND_TODAY`, sends only if `selected_date` = today, picks the template from the `audience` column, and sets `has_been_messaged = TRUE` on every row it sent. |
| 18:00 Mon–Sat | Snowflake task `MMM_CONFIRM_SENDS_TASK` | Writes a "sent" row to the ledger for every ticked row, then deletes those rows from `SEND_TODAY`. Rows left behind = picked but not sent (visible for checking). |
| Monthly | You: `python MMM_auto_retrain.py` | Rebuilds the training data, retrains, compares with the live model, and promotes the new one only if it is at least as good. The next 10:30 run uses it automatically. |

Why picks are logged in the morning (not only at night): if logging waited for the evening and that
step failed, the next morning would pick the same top people again and message them twice. Morning
logging also records the control group, which is never messaged but is needed for the comparison.

### Tables (all in `PINEAPPLE_DATABASE.MESSAGING_AUDIENCES`)

| Table / view | Written by | Read by | Purpose |
|---|---|---|---|
| `CONTINUOUS_PUSH_CAMPAIGN_AUDIENCE` | morning task | you (checks) | Everyone eligible today, scored, with discount, arm and hold flags. Rebuilt daily. |
| `CONTINUOUS_PUSH_CAMPAIGN_PICKED_TODAY` | morning task | evening task | Today's 2 × `daily_n` picks (both arms). |
| `CONTINUOUS_PUSH_CAMPAIGN_SEND_TODAY` | morning task; Make ticks rows; evening task deletes sent rows | Make | The list Make sends from. |
| `CONTINUOUS_PUSH_CAMPAIGN_HISTORY` | morning task (picks), evening task (sends) | cooldown, spam guard, retraining | **Append-only ledger.** Never recreated. |
| `CONTINUOUS_PUSH_CAMPAIGN_DO_NOT_MESSAGE_7D` (view) | — | morning task, Make | Anyone who got a discount WhatsApp or was picked/sent in the last 7 days. |
| `CPC_DISCOUNT_TEMPLATES` | you (one INSERT per new template) | spam guard, model features, retraining | The one place to register discount WhatsApp template IDs. |
| `CPC_MODEL_WEIGHTS` | setup, retraining | morning task | One weight per (model, feature, level). |
| `CPC_MODEL_REGISTRY` | setup, retraining | morning task | Which model version is the live "champion", with its test results. |
| `sandbox.pineapp_will.cpc_training_frame` | retraining | retraining | Training data, rebuilt at every retrain. |

---

## 2. Who can be picked (eligibility and exclusions)

Eligibility is the September 2026 audience build, re-run every day, with the changes noted.

**Q2S (quoted, never bought)**
- Governing quote = the first quote of the person's latest quote "episode" (quotes more than 45 days
  apart start a new episode); quote no older than 365 days. Under 45 days → `Q2S_LT45`, else `Q2S_GT45`.
- Needs a known vehicle make/model and a valid premium.
- Discount (see below) must be ≤ 17 % and the new premium must be at least 3 % below the last quote.

**L2S (lead, never quoted)**
- Latest lead no older than 15 days; never quoted (golden quote set or a `quoted` event); never insured.

**Excluded for everyone**
- Currently active policy (`pa_active`) or a successfully created policy (`mtr_policy_requests_full`).
- Ever: Do Not Call; Existing Motor Policyholder or Sale Made outcome; any No Insurable Risk outcome;
  Incorrect / Wrong Number / Disconnected. L2S also: "Still shopping for a car".
- Temporary Disconnected Number in the last 90 days.
- Opted out of WhatsApp (`OPT_OUT_WHATSAPP_LOGGING`).
- Dealership lead in the last 2 days.
- Missing / junk names ("Nofirstname"/"Nolastname") and known test accounts.

**Held back today (still eligible, just not selectable)**
- **Phone-first:** a Callback Scheduled outcome or a new lead in the last 1 day — the floor is working them.
- **Cooldown:** picked (either arm) in the last 7 days.
- **7-day spam guard:** received a discount WhatsApp (any template in `CPC_DISCOUNT_TEMPLATES`), or was
  confirmed/picked for sending by MMM, in the last 7 days. Checked again when `SEND_TODAY` is built.

**Discount offered** (decided before scoring; it never influences who is picked)
- Q2S: the highest of 7 %, prior discount + 3 (rounded up), the PSM recommendation if it is higher than
  the prior discount, and the customer's alpha-locked online discount if one is active. Above 17 % →
  excluded, not capped. On the Aug/Sep audiences this averages ≈ 10 %.
- L2S: flat 10 %.

**Treated vs control.** A fixed hash of the phone number puts each person in `treated` or `control`
(50/50, for life). Both arms are picked the same way; only treated people are messaged. Comparing the
two later shows how many sales the messages *cause*, which the model alone cannot tell you.

---

## 3. The model

### 3.1 What it predicts

MMM is **two logistic regressions** (a type of GLM, generalised linear model):

| Model | Trained on | Predicts |
|---|---|---|
| **deliver** | all campaign sends | P(the WhatsApp is delivered) |
| **click** | delivered sends only | P(the person clicks the tracked link within 7 days, given it was delivered) |

Each person's ranking score is

    p_click = P(delivered) × P(click | delivered)        = expected clicks per message sent

Why two models: in Aug/Sep, 36 % of campaign sends never reached anyone (18,684 failed, 7,868 never
confirmed) and produced one click between them. Delivery is very predictable from WhatsApp history,
so splitting the problem lets the click model learn only from people who could actually have clicked.

| Final status of the send | Sends | Click rate |
|---|---|---|
| read | 29,485 | 1.27 % |
| delivered, not read (read receipts can be switched off) | 18,362 | 0.42 % |
| failed / undelivered | 18,684 | 0.01 % |
| sent, never confirmed | 7,868 | 0.00 % |

**Why clicks and not sales:** only 78 Aug/Sep sales came through a tracked click; most sales came via
phone or organically. Training on all sales would teach the model to find people who buy anyway. A
click only happens because of the message.

### 3.2 Features (all binned)

Every number is cut into bins, and every bin ("level") gets its own weight.

| Feature | Levels | Source |
|---|---|---|
| `segment` | Q2S_LT45, Q2S_GT45, L2S | audience |
| `lead_age` | days since latest lead: 0-3, 4-7, 8-15, 16-30, 31-90, 91-180, 181-365, 365+ | leads |
| `quote_age` | days since latest quote: 0-14, 15-45, 46-90, 91-180, 181-365, 365+ | golden quotes |
| `call_age` | days since last outbound call: 0-2, 3-7, 8-30, 31-90, 91-180, 180+ | Connex (3 sales campaigns) |
| `callback_age` | days since last Callback Scheduled: 0-7, 8-30, 31-90, 90+ | Connex |
| `last_outcome` | last call outcome group: callback_scheduled, never_connected, auto_disconnected, other_connected, no_prior_call | Connex |
| `calls_30d` | outbound calls in 30 days: 0, 1-2, 3-5, 6+ | Connex |
| `lead_type` | first_time / reengaged (2+ lead submissions) | leads |
| `leads_30d` | leads in 30 days: 0, 1, 2+ | leads |
| `last_source`, `first_source` | attributed channel of latest / first lead | leads |
| `first_all` | first lead's detailed source (googlepaid, provider, facebookads, …) | leads |
| `premium` | undiscounted premium: <1000, 1000-1500, 1500-2000, 2000-3000, 3000+ (none for L2S) | discounts activity |
| `dialer_ch` | the dialer model's channel quality factor (5 bands) | dialer model |
| `prior_click` | ever clicked a previous discount campaign link | leads (UCID) |
| `wa_delivered` | WhatsApps delivered in 180 days: 0, 1-2, 3-5, 6+ | Twilio (one row per message) |
| `wa_failed` | WhatsApps failed in 180 days: 0, 1, 2+ | Twilio |
| `wa_read_rate` | read ÷ delivered: 0, 1-49 %, 50-99 %, 100 % (none = nothing delivered) | Twilio |
| `wa_replied` | ever replied in 180 days | Twilio |
| `disc_msg_age` | days since last delivered **discount** WhatsApp: 0-7, 8-14, 15-28, 29-60, 61+ | Twilio + `CPC_DISCOUNT_TEMPLATES` |
| `disc_msgs_28d` | delivered discount WhatsApps in 28 days: 0, 1, 2+ | Twilio + `CPC_DISCOUNT_TEMPLATES` |

The last two (added Oct 2026) let the model learn whether repeat messaging works. They barely vary in
the Aug/Sep data, so MMM_v3 has no weights for them yet; the monthly retrains will learn them once the
continuous process has re-messaged people.

**Tested and deliberately left out:** offer % (it is set by formula from the prior discount, and 7–9 %
offers never occurred, so its effect cannot be learned yet); prior quote discount, previous campaign's
offer %, whether that message was read, days since it (no gain: test AUC 0.756 without vs 0.754 with —
switch back on with `INCLUDE_DISCOUNT_FEATURES` in `MMM_train.py`); send hour / weekday (batch
artefacts tied to rank); the old composite score (used as the benchmark).

### 3.3 How the weights are found

For one model, a person's log-odds is the intercept plus one weight per feature (the weight of the bin
they fall in), turned into a probability with the logistic function:

    z = b0 + w(segment) + w(lead_age) + … + w(disc_msgs_28d)
    p = 1 / (1 + e^(−z))

The weights are the values that make the observed outcomes most likely (maximum likelihood), with an
**L2 penalty** that pulls every weight towards 0:

    minimise   ½ · Σ w²   +   C · Σ logloss(actual, predicted)

- A level needs a lot of evidence to earn a large weight; rare or noisy levels stay near 0. Levels with
  fewer than 100 people are pooled into one "infrequent" level first.
- **C** (how much the data is trusted vs the penalty) is chosen by 5-fold cross-validation from
  {0.03, 0.1, 0.3}. MMM_v3: C = 0.3 for deliver, 0.1 for click.
- All weights are fitted **together**, so each weight is the effect of that level *with everything else
  held fixed*. The old composite score estimated each factor on its own and multiplied them, which
  double-counts correlated factors (e.g. lead age and quote age). Fitting jointly is the main upgrade.
- After fitting on all data, the intercepts are shifted so the average prediction matches the latest
  month's real delivery and click rates (calibration). Scores then read as "expected clicks per send".
- Scoring in SQL is a lookup: for each person, sum the weight of each of their levels, apply the
  logistic function. `MMM_train.py` checks that this lookup reproduces the Python model exactly before
  anything is published.

**Reading the weights.** Every level has its own weight (there is no reference level), so a single
weight means nothing on its own. What matters is the **difference between two levels of the same
feature**: e^(w_a − w_b) is the odds multiplier of being in level a instead of b, everything else equal.
Some features overlap heavily (an L2S person always has `segment` = L2S, `quote_age` = none and
`premium` = none), so they share the credit — read their sum, not each one.

### 3.4 What weighs most (MMM_v3)

**Delivery model** — WhatsApp history dominates:

| Comparison | Odds of delivery |
|---|---|
| 6+ WhatsApps delivered in 180 days vs none | × 15 |
| No failed WhatsApps vs 2+ failed | × 5.9 |
| Lead in the last 7 days vs 16–30 days ago | × 4.1 |
| 1 lead in the last 30 days vs none | × 3.4 |
| Re-engaged vs first-time lead | × 2.0 |
| Last call auto-disconnected | lowest of all outcomes |

**Click model (given delivered)** — engagement and quote freshness:

| Comparison | Odds of a click |
|---|---|
| Q2S < 45 days vs L2S (segment only; partly offset by the L2S quote/premium levels) | × 3.7 |
| Clicked a previous discount campaign vs never | × 3.1 |
| Last call outcome Callback Scheduled vs other connected outcomes | × 2.1 |
| Premium R3,000+ vs under R1,000 | × 1.8 |
| Quote 91–180 days old vs 0–14 days old (fresh quotes are left to the phone) | × 3.0 |
| First-time lead vs re-engaged | × 0.49 |
| Latest lead from a lead provider vs an aggregator | × 0.44 |
| No lead in the last 30 days vs one | × 0.63 |

Full weights: `CPC_MODEL_WEIGHTS` in Snowflake (or `MMM_v3_weights.csv`).

### 3.5 How well it works (MMM_v3, trained on August, tested on September)

| Model | AUC per send | Top 10 % catches | Top 30 % catches |
|---|---|---|---|
| **MMM_v3** | **0.756** (95 % CI 0.71–0.80) | 38 % of clicks | 68 % |
| September composite score | 0.668 | 22 % | 47 % |

By segment (MMM vs composite): L2S 0.655 vs 0.560 · Q2S > 45d 0.779 vs 0.702 · Q2S < 45d 0.665 vs
0.663 (a tie, 16 clicks). Delivery model AUC 0.91. Test set: 20,723 September sends, 116 clicks.
A gradient-boosted tree model was also tried and did no better (0.749), so the simpler, transparent
GLM was kept.

### 3.6 Known limits

- **Clicks are not sales**, and the model predicts who responds, not who responds *because* of the
  message. The treated/control comparison answers the second question.
- **Small test set** (116 clicks) → wide confidence intervals.
- **Selection bias:** the training data is people the old composite picked; the model has never seen
  people it rejected.
- **Repeat messaging:** with a 7-day cooldown, strong scorers can be re-picked weekly. The two
  `disc_*` features will learn whether that helps or hurts; until then, watch the opt-out rate.

---

## 4. Monthly retraining (`MMM_auto_retrain.py`)

1. Connects to Snowflake as `PROGRAM` (RSA key downloaded from S3 with the AWS keys in `.env`).
2. Rebuilds `cpc_training_frame` by running `MMM_build_training_frame.sql` in Snowflake: one row per
   person per send (Aug/Sep campaigns + every pick in the ledger), features as of the send, outcomes after.
3. Pulls it into pandas (no phone numbers) and trains with `MMM_train.py`: fit on everything except the
   latest batch (the newest month), test on that batch.
4. Scores the same test batch with the live champion's weights — only if the champion never trained on it.
5. **Gate** — promote only if: test batch ≥ 30 clicks, AUC ≥ 0.65, and AUC no more than 0.01 below the
   champion. Otherwise the new weights are stored as `rejected` and the champion stays.
6. Refits on all data, recalibrates, loads the weights as `MMM_vYYYYMMDD_deliver` / `_click`, records the
   run in `CPC_MODEL_REGISTRY`, and writes a JSON report to `mmm_runs/`.

Only discount templates listed in `CPC_DISCOUNT_TEMPLATES` count as training sends, and clicks are leads
whose UCID starts with `PINCARDISC`. Run it about monthly; the first useful run is about a month after
go-live (14 Oct 2026).

---

## 5. Files

| File | Needed? | What it is |
|---|---|---|
| `MMM_production_scoring.sql` | **Yes** | The source of truth for all daily SQL. Part 1 setup (tables, registry, weights, templates, spam-guard view), Part 2 scoring, Part 3 picking, Part 4 confirming sends, Part 5 checks. |
| `MMM_snowflake_tasks.sql` | **Yes** | The two stored procedures (Parts 2–3 and Part 4 wrapped for Snowflake) and the two scheduled tasks, plus test and monitoring queries. |
| `MMM_build_training_frame.sql` | **Yes** | Builds the training data; run automatically by the retrain. |
| `MMM_train.py` | **Yes** | Features, both models, validation, calibration, weights export. Imported by the retrain; can also run alone on a CSV. |
| `MMM_auto_retrain.py` | **Yes** | The monthly retrain: Snowflake in, Snowflake out, with the gate. |
| `requirements.txt` | **Yes** | Python packages: `pip install -r requirements.txt`. |
| `.env` | **Yes** (never share) | `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, only used to fetch the Snowflake key from S3. |
| `MMM_run_sql.py` | Optional, recommended | Runs parts of the production SQL from Python (`setup`, `daily`, `confirm`, `checks`) — a fallback if a task fails — and `build-tasks`, which rewrites the procedures in `MMM_snowflake_tasks.sql` after you edit Parts 2–4. |
| `test_connection.py` | Optional | One-command health check: packages, keys, Snowflake login, MMM tables. |

Not needed to run MMM (analysis history, can be archived): `cpc_batch3_training_frame.sql`,
`cpc_batch4_training_frame_v2.sql`, `continuous_campaign_model_analysis.sql`,
`continuous_campaign_batch2_pre_challenger.sql`, `cpc_click_relationships.csv`,
`MMM_v3_weights.csv` (a copy of what is already in Snowflake), `continuous_campaign_flow_detailed.jpg`.

---

## 6. Runbook

**First-time setup (done)**
`pip install -r requirements.txt` → `python test_connection.py` → `python MMM_run_sql.py setup` →
run `MMM_snowflake_tasks.sql` in a worksheet (creates procedures, runs a score-only test, creates the
tasks paused).

**Go-live (13–14 Oct 2026)**
1. Register Make's template ID(s):
   `INSERT INTO PINEAPPLE_DATABASE.MESSAGING_AUDIENCES.CPC_DISCOUNT_TEMPLATES (template_id, description) VALUES ('<id>', 'continuous campaign');`
2. Confirm the continuous UCIDs start with `PINCARDISC`.
3. On the 13th after 10:30: `ALTER TASK … MMM_DAILY_PICK_TASK RESUME;` and the same for `MMM_CONFIRM_SENDS_TASK`.

**Every day** — the "Did it run?" query in `MMM_snowflake_tasks.sql` shows each run's result, e.g.
`OK: model MMM_v3, eligible 23446, selectable 22606, SEND_TODAY rows 98`.

**Common changes**
| I want to… | Do this |
|---|---|
| Send more / fewer per day | Suspend the task, `ALTER TASK … MODIFY AS CALL …MMM_DAILY_PICK(150, 7, FALSE);`, resume. |
| Change the cooldown | Same, change the second number. |
| Pause over a holiday | `ALTER TASK … SUSPEND;` (and `RESUME` after). |
| Re-run today's pick after a failure | `EXECUTE TASK …MMM_DAILY_PICK_TASK;` (re-runs are safe: today's picks are re-used, not doubled). |
| Add a template | One `INSERT` into `CPC_DISCOUNT_TEMPLATES`. |
| Change eligibility / scoring SQL | Edit Parts 2–4 of `MMM_production_scoring.sql` → `python MMM_run_sql.py build-tasks` → in a worksheet, run only the two `CREATE OR REPLACE PROCEDURE` blocks. |
| Retrain | `python MMM_auto_retrain.py --dry-run`, then without `--dry-run`. |

**Careful:** after go-live, do not press Run All on `MMM_snowflake_tasks.sql` — `CREATE OR REPLACE TASK`
recreates the tasks *paused*, and the daily pick silently stops. If you do, run the two `RESUME` lines.
