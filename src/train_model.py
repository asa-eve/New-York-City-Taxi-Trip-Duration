import numpy as np
import pandas as pd

from sklearn.model_selection import train_test_split
from sklearn.pipeline import make_pipeline
from sklearn.impute import SimpleImputer
from sklearn.preprocessing import PolynomialFeatures, StandardScaler

from sklearn.linear_model import Ridge
from sklearn.ensemble import StackingRegressor
from lightgbm import LGBMRegressor
from xgboost import XGBRegressor

from sklearn.metrics import mean_squared_error


def train_model():

    df_clean_SQL = pd.read_csv('../data/df_clean.csv')

    train_part, valid = train_test_split(df_clean_SQL, train_size=0.8, random_state=4321)
    X_train = train_part.drop(columns=['trip_duration'])
    y_train = train_part['trip_duration']
    X_valid = valid.drop(columns=['trip_duration'])
    y_valid = valid['trip_duration']

    poly_ridge = make_pipeline(
        SimpleImputer(strategy='median'),
        PolynomialFeatures(degree=1, include_bias=False),
        StandardScaler(),
        Ridge(alpha=1.0, random_state=42)
    )

    lgbm = LGBMRegressor(
        n_estimators=500,
        learning_rate=0.1,
        random_state=42,
    )


    xgb_base = XGBRegressor(
        n_estimators=1000,
        max_depth=5,
        learning_rate=0.3,
        colsample_bytree=0.7,
        subsample=0.7,
        objective='reg:squarederror',
        random_state=4321,
        n_jobs=-1
    )

    estimators = [
        ('poly_ridge', poly_ridge),
        ('lgbm',       lgbm),
        ('xgb_base',   xgb_base)
    ]

    meta_model = XGBRegressor(
        n_estimators=300,
        max_depth=3,
        learning_rate=0.1,
        objective='reg:squarederror',
        random_state=4321
    )

    stack = StackingRegressor(
        estimators=estimators,
        final_estimator=meta_model,
        cv=3,
        passthrough=False,
        n_jobs=1
    )
    stack.fit(X_train, y_train)

    print("First-layer models inside the stack:")
    for name, est in stack.named_estimators_.items():
        preds_i = est.predict(X_valid)
        rmse_i  = np.sqrt(mean_squared_error(y_valid, preds_i))
        print(f" - {name:<12} → RMSE: {rmse_i:.4f}")

    stack_preds = stack.predict(X_valid)
    stack_rmse  = np.sqrt(mean_squared_error(y_valid, stack_preds))
    print(f"\n{'StackingRegressor':<25} RMSE: {stack_rmse:.4f}")


if __name__ == "__main__":
    train_model()