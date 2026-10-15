# Queries for the narrative sample

These read `ravensight.events`, the table behind the AI analyst's `run_sql`
tool and the MCP server. Both scope every query to your game and leave out
synthetic (playtest) sessions by default, so the queries below do not filter
on `game_id` or `synthetic` themselves.

Event data is in `props`, a `Map(String, String)` of the top level keys each
event sent. Numbers arrive as text, so read them with `toFloat64OrZero` or
`toUInt32OrZero`. `game_version` is a column: the SDK sends the app's
version when it opens a session.

The events the sample sends:

| Event | Keys besides `run_id` and the two totals |
| --- | --- |
| `run_started`, `run_resumed`, `run_saved` | none |
| `run_ended` | `outcome` |
| `encounter_started`, `encounter_completed` | `encounter_id`, `encounter_key`, `attempt` |
| `choice_made` | `encounter_id`, `encounter_key`, `attempt`, `choice_key`, `option_key` |
| `encounter_rerolled` | `encounter_id`, `encounter_key`, `attempt`, `previous_attempt`, `rolled_back` |
| `progression_loaded` | `unlocked_count` |
| `unlock_earned` | `unlock_id`, `unlocked_count` |

Every event carries `foreground_seconds_total` and
`idle_seconds_estimate_total`: running totals for the run, across every
launch that resumed it.

Every query here was run against a local ClickHouse with the same events
schema and a small hand made dataset (two runs, a reroll, two versions),
and returned the expected rows. They have not been run against production
data.

## Time per run: MAX, never SUM

Each event carries the run's total so far, so the run's time is the largest
value seen. Summing would add the same seconds once per event.

```sql
SELECT
    props['run_id'] AS run_id,
    max(toFloat64OrZero(props['foreground_seconds_total'])) AS foreground_seconds,
    max(toFloat64OrZero(props['idle_seconds_estimate_total'])) AS idle_seconds_estimate
FROM ravensight.events
WHERE props['run_id'] != ''
  AND ts >= now() - INTERVAL 30 DAY
GROUP BY run_id
ORDER BY foreground_seconds DESC
LIMIT 100
```

The idle figure is an estimate: input gaps longer than the threshold (60
seconds in the sample) count the part beyond it. Report it beside the
foreground time. Subtracting it gives an engaged estimate, and should be
labelled as one.

## Median run time by game version

A run resumed after an update spans two versions; this credits it to the
version it was last played on.

```sql
SELECT
    version,
    count() AS runs,
    quantile(0.5)(foreground_seconds) AS median_foreground_seconds
FROM
(
    SELECT
        props['run_id'] AS run_id,
        argMax(game_version, ts) AS version,
        max(toFloat64OrZero(props['foreground_seconds_total'])) AS foreground_seconds
    FROM ravensight.events
    WHERE props['run_id'] != ''
    GROUP BY run_id
)
GROUP BY version
ORDER BY version
```

## Choices by game version and stable key

Group by `choice_key` and `option_key`, the content's own ids, never the
display text (which changes with every copy edit and translation). Count
the final attempt only: choices made in an attempt the player rerolled are
still in the data, under the earlier `attempt` number.

```sql
WITH final_attempts AS
(
    SELECT
        props['encounter_id'] AS encounter_id,
        max(toUInt32OrZero(props['attempt'])) AS final_attempt
    FROM ravensight.events
    WHERE event_name = 'encounter_completed'
    GROUP BY encounter_id
)
SELECT
    e.game_version AS version,
    e.props['choice_key'] AS choice_key,
    e.props['option_key'] AS option_key,
    uniqExact(e.props['encounter_id']) AS encounters
FROM ravensight.events AS e
INNER JOIN final_attempts AS fa
    ON fa.encounter_id = e.props['encounter_id']
   AND fa.final_attempt = toUInt32OrZero(e.props['attempt'])
WHERE e.event_name = 'choice_made'
GROUP BY version, choice_key, option_key
ORDER BY version, choice_key, encounters DESC
```

`uniqExact` on the encounter id counts each encounter once even if the
player changed their mind inside one attempt.

## Reroll rate by encounter

```sql
SELECT
    game_version AS version,
    props['encounter_key'] AS encounter_key,
    uniqExactIf(props['encounter_id'], event_name = 'encounter_started') AS encounters,
    countIf(event_name = 'encounter_rerolled') AS rerolls,
    round(rerolls / greatest(encounters, 1), 2) AS rerolls_per_encounter
FROM ravensight.events
WHERE event_name IN ('encounter_started', 'encounter_rerolled')
GROUP BY version, encounter_key
ORDER BY rerolls_per_encounter DESC
```

## Earned unlocks, not loaded ones

`unlock_earned` is only sent for something earned in that session. Loading
a save sends one `progression_loaded` with a count, so counting
`unlock_earned` never counts the same unlock again on every launch.

```sql
SELECT
    game_version AS version,
    props['unlock_id'] AS unlock_id,
    count() AS earned
FROM ravensight.events
WHERE event_name = 'unlock_earned'
GROUP BY version, unlock_id
ORDER BY version, earned DESC
```

How much progress players bring back when they load:

```sql
SELECT
    quantile(0.5)(toUInt32OrZero(props['unlocked_count'])) AS median_unlocks_on_load
FROM ravensight.events
WHERE event_name = 'progression_loaded'
  AND ts >= now() - INTERVAL 30 DAY
```
