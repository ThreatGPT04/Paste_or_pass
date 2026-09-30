-- Paste or Pass: admin reports for the Supabase dashboard
-- ------------------------------------------------------------------
-- Run once in Supabase -> SQL Editor. Safe to re-run.
--
-- Creates read-only views in a private schema called "admin". They
-- appear in Table Editor (switch the schema dropdown from "public" to
-- "admin") and need your Supabase login to see.
--
-- The game's publishable key cannot reach them. Supabase's API only
-- serves the schemas listed under Settings -> API -> Exposed schemas
-- (public by default), and anon/authenticated get no rights on "admin"
-- below. Do NOT add "admin" to the exposed schemas.
--
-- Day boundaries use Asia/Kolkata time. To change the time zone,
-- replace every 'Asia/Kolkata' in this file (e.g. with 'Australia/Perth')
-- and re-run.
--
-- A "player" is a first + last name pair, ignoring case and extra
-- spaces, so someone who plays twice counts once in unique players.
-- ------------------------------------------------------------------

create schema if not exists admin;
revoke all on schema admin from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on schema admin from anon, authenticated';
  end if;
end $$;

-- Every game played, newest first, with a clean player key and local time.
create or replace view admin.all_games as
select
  s.id,
  s.first_name,
  s.last_name,
  s.score,
  s.total,
  round(100.0 * s.score / nullif(s.total, 0))::int      as percent,
  s.grade,
  s.fooled,
  s.played_at at time zone 'Asia/Kolkata'                as played_at_local,
  lower(regexp_replace(trim(s.first_name), '\s+', ' ', 'g')) || ' ' ||
  lower(regexp_replace(trim(s.last_name),  '\s+', ' ', 'g')) as player_key
from public.scores s
order by s.played_at desc;

-- Headline numbers.
create or replace view admin.summary as
select
  count(*)                                                    as games_played,
  count(distinct player_key)                                  as unique_players,
  round(avg(score), 2)                                        as average_score,
  coalesce(max(score), 0)                                     as best_score,
  count(*) filter (where score = total)                       as perfect_games,
  count(*) filter (where fooled)                              as games_fooled,
  round(100.0 * count(*) filter (where fooled) / nullif(count(*), 0), 1)
                                                              as percent_fooled,
  min(played_at_local)                                        as first_game,
  max(played_at_local)                                        as latest_game
from admin.all_games;

-- One row per player: best score, how many times they played, rank.
-- Ties on best score go to whoever reached it first.
create or replace view admin.leaderboard as
with per_player as (
  select
    player_key,
    count(*)                                   as attempts,
    max(score)                                 as best_score,
    round(avg(score), 2)                       as average_score,
    max(played_at_local)                       as last_played
  from admin.all_games
  group by player_key
),
first_best as (
  select distinct on (g.player_key)
    g.player_key, trim(g.first_name) as first_name, trim(g.last_name) as last_name,
    g.played_at_local as best_reached_at
  from admin.all_games g
  join per_player p on p.player_key = g.player_key and g.score = p.best_score
  order by g.player_key, g.played_at_local
)
select
  rank() over (order by p.best_score desc)                           as rank,
  f.first_name,
  f.last_name,
  p.best_score,
  p.attempts,
  p.average_score,
  f.best_reached_at,
  p.last_played
from per_player p
join first_best f using (player_key)
order by p.best_score desc, f.best_reached_at asc;

-- The overall winner(s): everyone tied on the top score, first to reach it first.
create or replace view admin.top_scorer as
select * from admin.leaderboard where rank = 1;

-- How many games ended on each score, 0 to 10.
create or replace view admin.score_distribution as
select
  n.score,
  count(g.id)                                                         as games,
  round(100.0 * count(g.id) / nullif(sum(count(g.id)) over (), 0), 1) as percent
from generate_series(0, 10) as n(score)
left join admin.all_games g on g.score = n.score
group by n.score
order by n.score;

-- Activity per day.
create or replace view admin.daily as
select
  played_at_local::date                        as day,
  count(*)                                     as games_played,
  count(distinct player_key)                   as unique_players,
  round(avg(score), 2)                         as average_score,
  count(*) filter (where score = total)        as perfect_games,
  count(*) filter (where fooled)               as games_fooled
from admin.all_games
group by 1
order by 1 desc;

-- Activity per hour, to see when the booth was busiest.
create or replace view admin.hourly as
select
  date_trunc('hour', played_at_local)          as hour,
  count(*)                                     as games_played,
  round(avg(score), 2)                         as average_score
from admin.all_games
group by 1
order by 1 desc;

-- Views run with the owner's rights, so keep them away from API roles.
revoke all on all tables in schema admin from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema admin from anon, authenticated';
  end if;
end $$;
