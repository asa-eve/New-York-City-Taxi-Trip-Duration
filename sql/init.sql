DROP SCHEMA public CASCADE;
CREATE SCHEMA public;


CREATE TABLE train_data      AS SELECT * FROM pg_read_file('/data/train.csv')      WITH NO DATA;
CREATE TABLE test_data       AS SELECT * FROM pg_read_file('/data/test.csv')       WITH NO DATA;
CREATE TABLE weather_data    AS SELECT * FROM pg_read_file('/data/weather.csv')    WITH NO DATA;
CREATE TABLE fastest_routes_raw_1 AS SELECT * FROM pg_read_file('/data/fastest_routes_train_part_1.csv') WITH NO DATA;
CREATE TABLE fastest_routes_raw_2 AS SELECT * FROM pg_read_file('/data/fastest_routes_train_part_2.csv') WITH NO DATA;


COPY train_data      FROM '/data/train.csv'      CSV HEADER;
COPY test_data       FROM '/data/test.csv'       CSV HEADER;
COPY weather_data    FROM '/data/weather.csv'    CSV HEADER;
COPY fastest_routes_raw_1 FROM '/data/fastest_routes_train_part_1.csv' CSV HEADER;
COPY fastest_routes_raw_2 FROM '/data/fastest_routes_train_part_2.csv' CSV HEADER;

CREATE TABLE fastest_routes_raw AS
  SELECT * FROM fastest_routes_raw_1
  UNION ALL
  SELECT * FROM fastest_routes_raw_2;


-- =======================================================================================
-- =======================================================================================
-- =======================================================================================


CREATE OR REPLACE FUNCTION haversine_fn(
    lon1 FLOAT, lat1 FLOAT,
    lon2 FLOAT, lat2 FLOAT
) RETURNS FLOAT AS $$
DECLARE
    R FLOAT := 6371000; -- Earth radius in meters
    dlon FLOAT;
    dlat FLOAT;
    a FLOAT;
    c FLOAT;
BEGIN
    -- Convert to radians
    lon1 := RADIANS(lon1);
    lat1 := RADIANS(lat1);
    lon2 := RADIANS(lon2);
    lat2 := RADIANS(lat2);

    dlon := lon2 - lon1;
    dlat := lat2 - lat1;

    a := SIN(dlat / 2)^2 + COS(lat1) * COS(lat2) * SIN(dlon / 2)^2;
    c := 2 * ATAN2(SQRT(a), SQRT(1 - a));

    RETURN R * c;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


CREATE OR REPLACE FUNCTION bearing_fn(
    lon1 FLOAT, lat1 FLOAT,
    lon2 FLOAT, lat2 FLOAT
) RETURNS FLOAT AS $$
DECLARE
    dlon FLOAT;
    x FLOAT;
    y FLOAT;
    ang FLOAT;
    brg FLOAT;
BEGIN
    -- Convert to radians
    lon1 := RADIANS(lon1);
    lat1 := RADIANS(lat1);
    lon2 := RADIANS(lon2);
    lat2 := RADIANS(lat2);

    dlon := lon2 - lon1;

    x := SIN(dlon) * COS(lat2);
    y := COS(lat1) * SIN(lat2) - SIN(lat1) * COS(lat2) * COS(dlon);

    ang := ATAN2(x, y);
    brg := DEGREES(ang);

    IF brg < 0 THEN
        brg := brg + 360.0;
    END IF;

    -- Handle identical points
    IF ABS(lon1 - lon2) < 1e-9 AND ABS(lat1 - lat2) < 1e-9 THEN
        RETURN NULL;
    END IF;

    RETURN brg;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- =======================================================================================
-- =======================================================================================
-- =======================================================================================


-- Step 1: Combine train and test
CREATE TABLE all_data AS
SELECT *, 'train' AS dset FROM train_data
UNION ALL
SELECT *, 'test' AS dset, NULL::timestamp AS dropoff_datetime, NULL::int AS trip_duration FROM test_data;

-- Step 2: Geospatial features
ALTER TABLE all_data
ADD COLUMN bearing FLOAT,
ADD COLUMN dist FLOAT,
ADD COLUMN jfk_dist_pick FLOAT,
ADD COLUMN jfk_dist_drop FLOAT,
ADD COLUMN lg_dist_pick FLOAT,
ADD COLUMN lg_dist_drop FLOAT;

-- Assuming you have a UDF for haversine and bearing
UPDATE all_data
SET bearing = bearing_fn(pickup_longitude, pickup_latitude, dropoff_longitude, dropoff_latitude),
    dist = haversine_fn(pickup_longitude, pickup_latitude, dropoff_longitude, dropoff_latitude),
    jfk_dist_pick = haversine_fn(pickup_longitude, pickup_latitude, -73.778889, 40.639722),
    jfk_dist_drop = haversine_fn(dropoff_longitude, dropoff_latitude, -73.778889, 40.639722),
    lg_dist_pick  = haversine_fn(pickup_longitude, pickup_latitude, -73.872611, 40.77725),
    lg_dist_drop  = haversine_fn(dropoff_longitude, dropoff_latitude, -73.872611, 40.77725);

-- Step 3: Temporal features
ALTER TABLE all_data
ADD COLUMN date DATE,
ADD COLUMN month INT,
ADD COLUMN hour INT,
ADD COLUMN minute INT,
ADD COLUMN minute_oftheday INT,
ADD COLUMN wday INT,
ADD COLUMN work INT,
ADD COLUMN blizzard INT;

UPDATE all_data
SET date = DATE_TRUNC('day', pickup_datetime),
    month = EXTRACT(MONTH FROM pickup_datetime)::INT,
    hour = EXTRACT(HOUR FROM pickup_datetime)::INT,
    minute = EXTRACT(MINUTE FROM pickup_datetime)::INT,
    minute_oftheday = EXTRACT(HOUR FROM pickup_datetime)::INT * 60 + EXTRACT(MINUTE FROM pickup_datetime)::INT,
    wday = EXTRACT(DOW FROM pickup_datetime),
    work = CASE WHEN EXTRACT(HOUR FROM pickup_datetime) BETWEEN 8 AND 18 AND EXTRACT(DOW FROM pickup_datetime) BETWEEN 1 AND 5 THEN 1 ELSE 0 END,
    blizzard = CASE WHEN DATE_TRUNC('day', pickup_datetime) BETWEEN '2016-01-22' AND '2016-01-29' THEN 1 ELSE 0 END;

-- Step 4: Weather join
CREATE TABLE weather_clean AS
SELECT
  DATE(date) AS date,
  COALESCE(NULLIF(precipitation, 'T')::FLOAT, 0.01) AS rain,
  COALESCE(NULLIF("snow fall", 'T')::FLOAT, 0.01) AS s_fall,
  COALESCE(NULLIF("snow depth", 'T')::FLOAT, 0.01) AS s_depth,
  ("maximum temperature") AS max_temp,
  ("minimum temperature") AS min_temp
FROM weather_data;

ALTER TABLE weather_clean
ADD COLUMN all_precip FLOAT,
ADD COLUMN has_snow BOOLEAN,
ADD COLUMN has_rain BOOLEAN;

UPDATE weather_clean
SET all_precip = s_fall + rain,
    has_snow = (s_fall > 0 OR s_depth > 0),
    has_rain = (rain > 0);

-- Join weather
CREATE TABLE enriched_data AS
SELECT a.*, w.rain, w.s_fall, w.all_precip, w.has_snow, w.has_rain, w.s_depth, w.max_temp, w.min_temp
FROM all_data a
LEFT JOIN weather_clean w ON a.date = w.date;

-- Step 5: Fastest routes
CREATE TABLE fastest_routes AS
SELECT
  id,
  total_distance,
  total_travel_time,
  number_of_steps,
  LENGTH(REGEXP_REPLACE(step_direction, '[^lL][^eE][^fF][^tT]', '', 'g')) AS left_turns,
  LENGTH(REGEXP_REPLACE(step_direction, '[^rR][^iI][^gG][^hH][^tT]', '', 'g')) AS right_turns,
  LENGTH(REGEXP_REPLACE(step_maneuvers, '[^tT][^uU][^rR][^nN]', '', 'g')) AS turns,
  (total_distance / NULLIF(total_travel_time, 0)) * 3.6 AS fastest_speed
FROM fastest_routes_raw;

-- Join fastest routes
CREATE TABLE final_data AS
SELECT e.*, fr.total_distance, fr.total_travel_time, fr.fastest_speed,
       fr.number_of_steps, fr.left_turns, fr.right_turns, fr.turns
FROM enriched_data e
LEFT JOIN fastest_routes fr ON e.id = fr.id;

-- Step 6: Final flags and encodings
ALTER TABLE final_data
ADD COLUMN jfk_trip INT,
ADD COLUMN lg_trip INT;

UPDATE final_data
SET jfk_trip = CASE WHEN jfk_dist_pick < 2000 OR jfk_dist_drop < 2000 THEN 1 ELSE 0 END,
    lg_trip = CASE WHEN lg_dist_pick < 2000 OR lg_dist_drop < 2000 THEN 1 ELSE 0 END;

-- Categorical encoding (example for vendor_id)
ALTER TABLE final_data
ADD COLUMN vendor_id_1 INT,
ADD COLUMN vendor_id_2 INT;

UPDATE final_data
SET vendor_id_1 = CASE WHEN vendor_id = 1 THEN 1 ELSE 0 END,
    vendor_id_2 = CASE WHEN vendor_id = 2 THEN 1 ELSE 0 END;

-- store_and_fwd_flag encoding
ALTER TABLE final_data
ADD COLUMN store_and_fwd_flag_0 INT,
ADD COLUMN store_and_fwd_flag_1 INT;

UPDATE final_data
SET store_and_fwd_flag_0 = CASE WHEN store_and_fwd_flag = 'N' THEN 1 ELSE 0 END,
    store_and_fwd_flag_1 = CASE WHEN store_and_fwd_flag = 'Y' THEN 1 ELSE 0 END;

