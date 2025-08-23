# 🗽 New York City Taxi Trip Duration


## Running
1. Clone repository
    - `git clone https://github.com/asa-eve/New-York-City-Taxi-Trip-Duration.git`
2. Prepare data
    - download competition datasets from official
    - get hands on external datasets
      - [Weather dataset in NYC 2016](https://www.kaggle.com/datasets/mathijs/weather-data-in-new-york-city-2016)
      - estimate of the fastest routes for each trip using Open Source Routing Machine (will require some internet searching)
          - in some sense creates "leaking", due to features like `speed` and `distance` (which give strong relation to `trip duration`)
          - **NOTE**: in reality, this dataset can be seen as "past collected data", to make more accurate predictions in the present
3. Lauching (Git Bash & Jupyter)
   - either using `.sh` files, or by following notebooks

## 📃 File Structure
```
New-York-City-Taxi-Trip-Duration/
├── start-model-training.sh
├── start-sql-data-processing.sh
├── notebooks/
│   ├── EDA.ipynb
│   └── model_training.ipynb
├── docker/
│   ├── model_training
│       ├── train_model.py
│       ├── run_training.dockerfile
│       └── docker-compose.yml
│   └── sql_data_processing
│       ├── data_transform.sql
│       └── docker-compose.yml
├── output/
│   ├── models/
│   └── graphs/
└── .gitignore
```

## 📊 Competition Overview

This project is based on [New York City Taxi Trip Duration](https://www.kaggle.com/competitions/nyc-taxi-trip-duration) the competition hosted on Kaggle.
- based on the [2016 NYC Yellow Cab trip](https://cloud.google.com/bigquery/public-data/nyc-tlc-trips) record data made available in Big Query on Google Cloud Platform

### Objective
Predict the duration of taxi trips in New York City using features such as pickup/dropoff coordinates, timestamps, and passenger count.
**Evaluation Metric**: Root Mean Squared Error (RMSE)

### **Dataset Summary**:
- `train.csv`: 1,458,644 trip records
- `test.csv`: 625,134 trip records

### **Features**:
- `pickup_datetime`, `dropoff_datetime`
- `pickup_longitude`, `pickup_latitude`, `dropoff_longitude`, `dropoff_latitude`
- `passenger_count`, `vendor_id`, `store_and_fwd_flag`
- `trip_duration` (target variable)

## 📈 Exploratory Data Analysis (EDA)
Very helpful [notebook to follow in R](https://www.kaggle.com/code/headsortails/nyc-taxi-eda-update-the-fast-the-curious/report).
Good insights:
### 1. **Simple visualization**
   - most of the trips are around Manhatten (notable places are airports - JFK & La Guardia)
       - from January to July of 2016 
   - `trip duration` - shows potential outliers for removal
   - `pickup / dropout` dates / count - failry homogeneous, drops late January - early February (winter)
   - `store and fwd flag` - shows that usually no storing of data happened (<0.5%)
   - `week day` vs. `number of pickups` - monday (least common), friday (most common)
   - `hour` vs. `number of pickups` - drops (4-5 am & 4-5 pm), probably working hours
### 2. **Feature relation** (with target)
   - `trip duration` vs. `hour/week day` - shows strong relation and influence
   - `trip duration` vs. `passenger count` - occasional 0 passenger trips, `vendor 1` has all >24h trips, `vendor 2` has all >6 passenger trips, nearly identical median between vendors for 1-6 passengers 
   - `density` vs. `trip duration` (by vendor) - close medians (~660s mark), with `vendor 2` having heavier right tail inflating its mean value
   - `store and fwd flag` vs. `trip duration` - minimal difference in flags data 
### 3. **Feature engineering** (`work`, `airport ride` flags)
   - `trip duration` vs. `direct distance` (calculated by Cosine law distance) -> duration rises with distance, 24h and <10m trips are artifacts
   - `trip duration` vs. `direct distance` filtered + log-log -> urban routing inefficiency (duration scales sub-linearly with distance for longer rides)
   - `avg speed` distribution -> centered at 15km/h (true for NYC), speed >50km/h (anomalies/noise)
   - `median speed` vs. `weekday/hour` -> distinct patterns for `work` hours 
   - `bearing` vs. `duration / distance / speed` -> peaks for 30 & -150 degrees (Manhatten orientation)
   - `pickup / dropoff` rates in JFK & LG airports -> 2 clusters around each airport (<2km) - could use as `airport flag` feature
   - `JFK trips` vs. `LG trips` vs. `non-airport trips` -> airport proximity is a strong predictor for higher trip duration
### 4. **Anomalies detection & removal**
   - `>24 hour` trips - most of the trips are around Manhatten & align with airport routes -> unlikely 24h trips (low avg speed <0.05 km/h)
   - map of `22-24 hour` trips - artifacts (rather than long rides)
   - `zero distance` trips - set >5m (less are unlikely)
   - `short distance / high speed` trips - cutoff by 100 km/h (most distances >100m, yet >1000km/h speeds appear)
   - `pickups/dropoff > 300km` from JFK airport - shows trips across San-Francisco -> obvious artifacts in data (NYC)
### 5. **External datasets features**
   - Weather dataset (not very useful)
       - no clear rise in `median speed` for `rain / snow` flag
       - biggest blizzard on Jan 23rd caused largest drop in volume & speed
   - Fastest routes dataset
       - median distance 2.8 km (~ 5 min)
       - distance & travel time nearly linear (except at extremes)
       - turns don't tell everything (travel time rises with number of steps)
       - `actual duration` exceed `durations` of trips by a wide margin -> traffic delays
       - `direct distances` slightly exceed `fastest routing distances` -> yet highly correlated
       - `actual speed` vs. `fastest theoretical speed` -> theoretical <20 km/h (cluster at 15km/h), distinct peaks in theoretical speeds (25-30km/h, 40km/h) - speed-limit areas 
       - new feature - `fastest speed` (`total distance` / `total travel time`)
### 6. **Correlation** (with target)
   - strongest - `distance` related features, `total travel time`
   - moderate - `airport flags`
   - low - `weather variables`
### 7. **Classification feature**
   - `trip duration` distribution count - **shows 3 clear groups** (fast / mid / slow - rides)
   - `fast / slow` proportions by features - `slow` (airport flag, snow) - `fast` (weekends, off-work hours)
   - `fast / slow` speed density - slow pickups (around airports & adjacent areas) - fast pickups (Newark airport & outer Manhatten)
   - `fast` dominate non-work hours & weekends | `slow` dominate work-hours, weekdays and airport flags
     
## Data preprocessing (result of EDA)
1. **Geospatial features**
   - `bearing`
   - `haversine distance` for dropoff/pickup - dropoff/pickup distance to JFK and LG airports
2. **Temporal features**
   - `month`, `week day`, `hour`, `minute`, `minute of the day`, `work hours flag`
3. **Weather features (external dataset)**
   - `blizard flag`, `rain`, `snow`, `snow depth`, `max temp`, `min temp`
4. **Fastest routes (external dataset)**
   - `fastest speed`, `left turns`, `right turns`, `turns`
5. **Final processing features**
   - One-hot-Encoding for `vendor_id` and `store_and_fwd_flag`
   - `jfk airport trip flag` (<2km away distance)
   - `lg airport trip flag` (<2km away distance)
6. **Additional cleaning**
   - removing 24 hour trips
   - removing San-Francisco trips (artifacts)
   - `trip duration` transformation (natural logarithm) - achieves normal distribution
   - replacing infinity values with NaNs + dropping

## 🤖 Model Training & Results
After EDA (non-linear feature relationships) it became obvious - that regression models will perform worse.

  Model | RMSE
  --- | --- 
  `Ridge regression` (poly features) | 0.4150
  `XGBoost` | 0.3494
  `LightGBM` | 0.3485
  `Stacking` (all 3) with `XGBoost` | 0.3459

### This result is top 1% (of public scores).
