# 🗽 New York City Taxi Trip Duration


## Running
1. Clone repository
    - `git clone https://github.com/asa-eve/New-York-City-Taxi-Trip-Duration.git`
2. Prepare data
    - download competition datasets from official
    - get hands on external datasets
      - [Weather dataset in NYC 2016](https://www.kaggle.com/datasets/mathijs/weather-data-in-new-york-city-2016)
      - estimate of the fastest routes for each trip using Open Source Routing Machine (will require some internet searching)
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
- `pickup_longitude`, `pickup_latitude`
- `dropoff_longitude`, `dropoff_latitude`
- `passenger_count`, `vendor_id`, `store_and_fwd_flag`
- `trip_duration` (target variable)

## 📈 Exploratory Data Analysis (EDA)

## 🤖 Model Training & Results
After EDA (non-linear feature relationships) it became obvious - that regression models will perform worse. But the strategy of applying 3-4 methods right away is useful (simple, average(2), complex(2)), so I ended up with:

  Model | RMSE
  --- | --- 
  `Ridge regression` (poly features) | 0.4150
  `XGBoost` | 0.3494
  `LightGBM` | 0.3485
  `Stacking` (all 3) | 0.3459

This result is top 1% (of public scores).
