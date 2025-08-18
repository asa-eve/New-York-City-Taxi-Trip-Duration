-- Drop old tables if re-running
DROP TABLE IF EXISTS train_raw;
DROP TABLE IF EXISTS test_raw;


-- LOADING TRAIN + TEST


CREATE TABLE train_raw (
  id                   TEXT,
  vendor_id            INTEGER,
  pickup_datetime      TIMESTAMP,
  dropoff_datetime     TIMESTAMP,
  passenger_count      INTEGER,
  pickup_longitude     DOUBLE PRECISION,
  pickup_latitude      DOUBLE PRECISION,
  dropoff_longitude    DOUBLE PRECISION,
  dropoff_latitude     DOUBLE PRECISION,
  store_and_fwd_flag   TEXT,
  trip_duration        INTEGER
);


CREATE TABLE test_raw (
  id                   TEXT,
  vendor_id            INTEGER,
  pickup_datetime      TIMESTAMP,
  passenger_count      INTEGER,
  pickup_longitude     DOUBLE PRECISION,
  pickup_latitude      DOUBLE PRECISION,
  dropoff_longitude    DOUBLE PRECISION,
  dropoff_latitude     DOUBLE PRECISION,
  store_and_fwd_flag   TEXT
);


COPY train_raw
  FROM '/data/train.csv'
  WITH (FORMAT csv, HEADER);

COPY test_raw
  FROM '/data/test.csv'
  WITH (FORMAT csv, HEADER);

-- ===============================================================================
-- ===============================================================================
-- ===============================================================================
-- ===============================================================================


-- Drop merged if present
DROP TABLE IF EXISTS merged_data;

-- Stack train + test, filling missing fields with NULL
CREATE TABLE merged_data AS
SELECT
  id,
  vendor_id,
  pickup_datetime,
  dropoff_datetime,
  passenger_count,
  pickup_longitude,
  pickup_latitude,
  dropoff_longitude,
  dropoff_latitude,
  store_and_fwd_flag,
  trip_duration,
  'train' AS dset
FROM train_raw

UNION ALL

SELECT
  id,
  vendor_id,
  pickup_datetime,
  NULL::TIMESTAMP   AS dropoff_datetime,
  passenger_count,
  pickup_longitude,
  pickup_latitude,
  dropoff_longitude,
  dropoff_latitude,
  store_and_fwd_flag,
  NULL::INTEGER     AS trip_duration,
  'test'  AS dset
FROM test_raw;


-- ===============================================================================
-- ===============================================================================
-- ===============================================================================
-- ===============================================================================


-- 1) Haversine distance in meters
CREATE OR REPLACE FUNCTION haversine_fn(
  lon1 double precision, lat1 double precision,
  lon2 double precision, lat2 double precision
) 
RETURNS double precision
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
  R    CONSTANT double precision := 6371000;  -- Earth’s radius in m
  dlon double precision;
  dlat double precision;
  a    double precision;
  c    double precision;
BEGIN
  -- convert inputs to radians
  lon1 := RADIANS(lon1);  lat1 := RADIANS(lat1);
  lon2 := RADIANS(lon2);  lat2 := RADIANS(lat2);

  dlon := lon2 - lon1;
  dlat := lat2 - lat1;

  a := POWER(SIN(dlat/2), 2)
     + COS(lat1) * COS(lat2) * POWER(SIN(dlon/2), 2);

  c := 2 * ATAN2(SQRT(a), SQRT(1 - a));

  RETURN R * c;
END;
$$;


-- 2) Initial bearing (degrees clockwise from North)
CREATE OR REPLACE FUNCTION bearing_fn(
  lon1 double precision, lat1 double precision,
  lon2 double precision, lat2 double precision
) 
RETURNS double precision
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
  dlon double precision;
  x    double precision;
  y    double precision;
  ang  double precision;
  brg  double precision;
BEGIN
  -- convert inputs to radians
  lon1 := RADIANS(lon1);  lat1 := RADIANS(lat1);
  lon2 := RADIANS(lon2);  lat2 := RADIANS(lat2);

  dlon := lon2 - lon1;

  x   := SIN(dlon) * COS(lat2);
  y   := COS(lat1)*SIN(lat2)
       - SIN(lat1)*COS(lat2)*COS(dlon);

  ang := ATAN2(x, y);
  brg := DEGREES(ang);
  IF brg < 0 THEN
    brg := brg + 360.0;
  END IF;

  RETURN brg;
END;
$$;



DROP TABLE IF EXISTS geo_features;

CREATE TABLE geo_features AS
SELECT
  md.id,

  -- Haversine distance in meters
  haversine_fn(
    md.pickup_longitude, md.pickup_latitude,
    md.dropoff_longitude, md.dropoff_latitude
  ) AS dist,

  -- Initial bearing  
  bearing_fn(
    md.pickup_longitude, md.pickup_latitude,
    md.dropoff_longitude, md.dropoff_latitude
  ) AS bearing,

  -- Distance from/to JFK
  haversine_fn(
    md.pickup_longitude, md.pickup_latitude,
   -73.778889,           40.639722
  ) AS jfk_dist_pick,
  haversine_fn(
    md.dropoff_longitude, md.dropoff_latitude,
   -73.778889,            40.639722
  ) AS jfk_dist_drop,

  -- Distance from/to LGA
  haversine_fn(
    md.pickup_longitude, md.pickup_latitude,
   -73.872611,            40.777250
  ) AS lg_dist_pick,
  haversine_fn(
    md.dropoff_longitude, md.dropoff_latitude,
   -73.872611,            40.777250
  ) AS lg_dist_drop

FROM merged_data md;


-- Optional: index on id to speed up the final join
CREATE INDEX ON geo_features(id);



-- ===============================================================================
-- ===============================================================================
-- ===============================================================================
-- ===============================================================================


DROP TABLE IF EXISTS time_features;

CREATE TABLE time_features AS
SELECT
  md.id,

  -- 1) Date only (midnight timestamp)
  md.pickup_datetime::DATE AS date,

  -- 2) Month and hour
  EXTRACT(MONTH  FROM md.pickup_datetime)::INT AS month,
  EXTRACT(HOUR   FROM md.pickup_datetime)::INT AS hour,

  -- 3) Day-of-week code (0=Sun,1=Sat,2=Mon…6=Fri)
  CASE EXTRACT(DOW FROM md.pickup_datetime)
    WHEN 0 THEN 0
    WHEN 6 THEN 1
    WHEN 1 THEN 2
    WHEN 2 THEN 3
    WHEN 3 THEN 4
    WHEN 4 THEN 5
    WHEN 5 THEN 6
  END AS wday,

  -- 4) Minute and minute_oftheday
  EXTRACT(MINUTE FROM md.pickup_datetime)::INT AS minute,
  (
    EXTRACT(HOUR   FROM md.pickup_datetime) * 60
    + EXTRACT(MINUTE FROM md.pickup_datetime)
  )::INT AS minute_oftheday,

  -- 5) Work-hour flag: Mon–Fri between 08:00 and 18:00
  CASE
    WHEN EXTRACT(ISODOW FROM md.pickup_datetime) BETWEEN 1 AND 5
     AND EXTRACT(HOUR   FROM md.pickup_datetime) BETWEEN 8 AND 18
    THEN 1 ELSE 0
  END AS work,

  -- 6) Blizzard flag: 2016-01-22 through 2016-01-29 (inclusive)
  CASE
    WHEN md.pickup_datetime::DATE
         BETWEEN '2016-01-22' AND '2016-01-29'
    THEN 1 ELSE 0
  END AS blizzard

FROM merged_data md;

-- Optional: speed up joins in the final merge
CREATE INDEX ON time_features(id);
CREATE INDEX ON time_features(date);



-- ===============================================================================
-- ===============================================================================
-- ===============================================================================
-- ===============================================================================


DROP TABLE IF EXISTS weather_raw;

CREATE TABLE weather_raw (
  date                  TEXT,
  maximum_temperature   INTEGER,
  minimum_temperature   INTEGER,
  average_temperature   DOUBLE PRECISION,
  precipitation         TEXT,
  snow_fall             TEXT,
  snow_depth            TEXT
);

COPY weather_raw
  FROM '/data/weather.csv'
  WITH (FORMAT CSV, HEADER);





DROP TABLE IF EXISTS weather_features;


CREATE TABLE weather_features AS
SELECT
  -- normalize date into a real DATE, handling both styles
  CASE
    WHEN weather_raw.date ~ '^\d{4}-\d{1,2}-\d{1,2}$' THEN
      TO_DATE(weather_raw.date, 'YYYY-MM-DD')
    ELSE
      TO_DATE(weather_raw.date, 'FMDD-FMMM-YYYY')
  END AS date,

  COALESCE(NULLIF(weather_raw.precipitation, 'T')::NUMERIC, 0.01) AS rain,
  COALESCE(NULLIF(weather_raw.snow_fall,      'T')::NUMERIC, 0.01) AS s_fall,
  COALESCE(NULLIF(weather_raw.snow_depth,     'T')::NUMERIC, 0.01) AS s_depth,

  (COALESCE(NULLIF(weather_raw.precipitation, 'T')::NUMERIC, 0.01)
   + COALESCE(NULLIF(weather_raw.snow_fall,   'T')::NUMERIC, 0.01)
  ) AS all_precip,

  CASE
    WHEN COALESCE(NULLIF(weather_raw.snow_fall,  'T')::NUMERIC, 0.01) > 0
      OR COALESCE(NULLIF(weather_raw.snow_depth, 'T')::NUMERIC, 0.01) > 0
    THEN 1 ELSE 0
  END AS has_snow,

  CASE
    WHEN COALESCE(NULLIF(weather_raw.precipitation, 'T')::NUMERIC, 0.01) > 0
    THEN 1 ELSE 0
  END AS has_rain,

  weather_raw.maximum_temperature AS max_temp,
  weather_raw.minimum_temperature AS min_temp,
  weather_raw.average_temperature AS avg_temp

FROM weather_raw;

CREATE INDEX ON weather_features(date);




-- ===============================================================================
-- ===============================================================================
-- ===============================================================================
-- ===============================================================================

DROP TABLE IF EXISTS fr_raw;

CREATE TABLE fr_raw (
  id                    TEXT,
  starting_street       TEXT,
  end_street            TEXT,
  total_distance        DOUBLE PRECISION,
  total_travel_time     DOUBLE PRECISION,
  number_of_steps       INTEGER,
  street_for_each_step  TEXT,
  distance_per_step     TEXT,
  travel_time_per_step  TEXT,
  step_maneuvers        TEXT,
  step_direction        TEXT,
  step_location_list    TEXT
);

COPY fr_raw
  FROM '/data/fastest_routes_train_part_1.csv'
  WITH (FORMAT CSV, HEADER);

COPY fr_raw
  FROM '/data/fastest_routes_train_part_2.csv'
  WITH (FORMAT CSV, HEADER);




DROP TABLE IF EXISTS route_features;

CREATE TABLE route_features AS
SELECT
  id,
  total_distance,
  total_travel_time,

  -- convert m/s to km/h
  (total_distance / NULLIF(total_travel_time, 0)) * 3.6 AS fastest_speed,

  number_of_steps,

  -- count 'left' turns
  ((LENGTH(LOWER(step_direction))
    - LENGTH(REPLACE(LOWER(step_direction), 'left', '')))
   / LENGTH('left'))::INT AS left_turns,

  -- count 'right' turns
  ((LENGTH(LOWER(step_direction))
    - LENGTH(REPLACE(LOWER(step_direction), 'right', '')))
   / LENGTH('right'))::INT AS right_turns,

  -- count all 'turn' maneuvers
  ((LENGTH(LOWER(step_maneuvers))
    - LENGTH(REPLACE(LOWER(step_maneuvers), 'turn', '')))
   / LENGTH('turn'))::INT AS turns

FROM fr_raw;

CREATE INDEX ON route_features(id);



-- ===============================================================================
-- ===============================================================================
-- ===============================================================================
-- ===============================================================================

DROP TABLE IF EXISTS final_features;


CREATE TABLE final_features AS
SELECT
  md.id,
  md.vendor_id,
  md.pickup_datetime,
  md.dropoff_datetime,
  md.passenger_count,
  md.pickup_longitude,
  md.pickup_latitude,
  md.dropoff_longitude,
  md.dropoff_latitude,
  md.store_and_fwd_flag,
  md.trip_duration,
  md.dset,

  -- from time_features
  t.date,
  t.month,
  t.hour,
  t.wday,
  t.minute,
  t.minute_oftheday,
  t.work,
  t.blizzard,

  -- from weather_features
  w.rain,
  w.s_fall,
  w.s_depth,
  w.all_precip,
  w.has_snow,
  w.has_rain,
  w.max_temp,
  w.min_temp,

  -- from route_features
  r.total_distance,
  r.total_travel_time,
  r.fastest_speed,
  r.number_of_steps,
  r.left_turns,
  r.right_turns,
  r.turns,

  -- from geo_features
  g.dist,
  g.bearing,
  g.jfk_dist_pick,
  g.jfk_dist_drop,
  g.lg_dist_pick,
  g.lg_dist_drop,



  -- factorized store_and_fwd_flag (Y→1, N→0)
  CASE
    WHEN md.store_and_fwd_flag = 'Y' THEN 1
    ELSE 0
  END AS store_and_fwd_flag_code,

  -- one‐hot store_and_fwd_flag
  CASE WHEN md.store_and_fwd_flag = 'Y' THEN 1 ELSE 0 END AS store_and_fwd_flag_1,
  CASE WHEN md.store_and_fwd_flag = 'N' THEN 1 ELSE 0 END AS store_and_fwd_flag_0,

  -- one‐hot vendor_id (assuming values 1 & 2)
  CASE WHEN md.vendor_id = 1 THEN 1 ELSE 0 END AS vendor_id_1,
  CASE WHEN md.vendor_id = 2 THEN 1 ELSE 0 END AS vendor_id_2,

  -- JFK/LGA trip flags (<2 km)
  CASE 
    WHEN g.jfk_dist_pick < 2000 OR g.jfk_dist_drop < 2000 
    THEN 1 
    ELSE 0 
  END AS jfk_trip,

  CASE 
    WHEN g.lg_dist_pick < 2000 OR g.lg_dist_drop < 2000 
    THEN 1 
    ELSE 0 
  END AS lg_trip



FROM merged_data md
  LEFT JOIN time_features    t ON md.id = t.id
  LEFT JOIN weather_features w ON t.date = w.date
  LEFT JOIN route_features   r ON md.id = r.id
  LEFT JOIN geo_features     g ON md.id = g.id
;
  
CREATE INDEX ON final_features(id);
CREATE INDEX ON final_features(date);


-- ===============================================================================
-- ===============================================================================
-- ===============================================================================
-- ===============================================================================


-- 1) Drop old exports if you re-run
DROP TABLE IF EXISTS df_train_full;
DROP TABLE IF EXISTS df_clean;
DROP TABLE IF EXISTS df_test;

-- 2) Export the full training set (drops cols2drop)
CREATE TABLE df_train_full AS
SELECT
  passenger_count,
  pickup_longitude,
  pickup_latitude,
  dropoff_longitude,
  dropoff_latitude,
  LN(trip_duration::DOUBLE PRECISION + 1) AS trip_duration,
  month,
  hour,
  wday,
  minute,
  minute_oftheday,
  work,
  blizzard,
  rain,
  s_fall,
  s_depth,
  all_precip,
  has_snow,
  has_rain,
  max_temp,
  min_temp,
  fastest_speed,
  number_of_steps,
  left_turns,
  right_turns,
  turns,
  dist,
  bearing,
  jfk_dist_pick,
  jfk_dist_drop,
  lg_dist_pick,
  lg_dist_drop,
  jfk_trip,
  lg_trip,
  vendor_id_1,
  vendor_id_2,
  store_and_fwd_flag_1,
  store_and_fwd_flag_0,
  total_distance,
  total_travel_time
FROM final_features
WHERE dset = 'train';

-- 3) Export the raw test set
CREATE TABLE df_test AS
SELECT
  passenger_count,
  pickup_longitude,
  pickup_latitude,
  dropoff_longitude,
  dropoff_latitude,
  LN(trip_duration::DOUBLE PRECISION + 1) AS trip_duration,
  month,
  hour,
  wday,
  minute,
  minute_oftheday,
  work,
  blizzard,
  rain,
  s_fall,
  s_depth,
  all_precip,
  has_snow,
  has_rain,
  max_temp,
  min_temp,
  fastest_speed,
  number_of_steps,
  left_turns,
  right_turns,
  turns,
  dist,
  bearing,
  jfk_dist_pick,
  jfk_dist_drop,
  lg_dist_pick,
  lg_dist_drop,
  jfk_trip,
  lg_trip,
  vendor_id_1,
  vendor_id_2,
  store_and_fwd_flag_1,
  store_and_fwd_flag_0,
  total_distance,
  total_travel_time
FROM final_features
WHERE dset = 'test';

-- 4) Build the “clean” training set with your filters + log1p transform
CREATE TABLE df_clean AS
SELECT
  passenger_count,
  pickup_longitude,
  pickup_latitude,
  dropoff_longitude,
  dropoff_latitude,
  -- log1p(trip_duration)
  LN(trip_duration::DOUBLE PRECISION + 1) AS trip_duration,
  month,
  hour,
  wday,
  minute,
  minute_oftheday,
  work,
  blizzard,
  rain,
  s_fall,
  s_depth,
  all_precip,
  has_snow,
  has_rain,
  max_temp,
  min_temp,
  fastest_speed,
  number_of_steps,
  left_turns,
  right_turns,
  turns,
  dist,
  bearing,
  jfk_dist_pick,
  jfk_dist_drop,
  lg_dist_pick,
  lg_dist_drop,
  jfk_trip,
  lg_trip,
  vendor_id_1,
  vendor_id_2,
  store_and_fwd_flag_1,
  store_and_fwd_flag_0,
  total_distance,
  total_travel_time
FROM df_train_full
WHERE 
  trip_duration < 86400          -- under 24h
  AND jfk_dist_pick < 300000     -- under 300 km
  AND jfk_dist_drop < 300000;

-- 5) Optional: add indexes to speed up downstream queries
CREATE INDEX ON df_train_full(trip_duration);
CREATE INDEX ON df_clean(trip_duration);
CREATE INDEX ON df_test(month);
CREATE INDEX ON df_test(hour);


-- ===============================================================================
-- ===============================================================================
-- ===============================================================================
-- ===============================================================================


-- Export df_train_full to CSV
COPY df_train_full
  TO '/data/df_train_full.csv'
  WITH (FORMAT CSV, HEADER);

-- Export df_clean to CSV
COPY df_clean
  TO '/data/df_clean.csv'
  WITH (FORMAT CSV, HEADER);

-- Export df_test to CSV
COPY df_test
  TO '/data/df_test.csv'
  WITH (FORMAT CSV, HEADER);
