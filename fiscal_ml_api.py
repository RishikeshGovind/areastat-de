"""
fiscal_ml_api.py

FastAPI service for Austrian municipal fiscal distress prediction.
Runs on port 8001 alongside the R Plumber API (port 8000).

Startup:
    uvicorn fiscal_ml_api:app --port 8001 --reload

Endpoints:
    GET  /health
    GET  /model_performance
    GET  /feature_importance
    POST /predict_distress
    POST /shap_explain
    POST /fiscal_forecast
"""

import logging
import os
from typing import List, Optional

import joblib
import numpy as np
import pandas as pd
import shap
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from sklearn.metrics import (
    roc_auc_score,
    average_precision_score,
    classification_report,
)
from sklearn.preprocessing import LabelEncoder
from xgboost import XGBClassifier

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ── paths ──────────────────────────────────────────────────────────────────
BASE_DIR    = os.path.dirname(os.path.abspath(__file__))
PANEL_PATH  = os.path.join(BASE_DIR, "data", "panel_dataset.csv")
MODEL_PATH  = os.path.join(BASE_DIR, "data", "xgb_fiscal_model.joblib")

# ── feature columns ────────────────────────────────────────────────────────
FISCAL_FEATURES = [
    "deficit_ratio",
    "exp_per_capita",
    "rev_per_capita",
    "exp_growth",
    "rev_growth",
    "deficit_streak",
    "share_exp_admin",
    "share_exp_education_culture",
    "share_exp_social_welfare",
    "share_exp_health",
    "share_exp_infrastructure",
    "share_exp_finance_debt",
    "share_exp_economy",
    "share_exp_utilities",
]

SOCIO_FEATURES = [
    "population",
    "pct_under15",
    "pct_over65",
    "emp_rate",
    "unemp_rate",
    "pct_foreign",
    "pct_commuters",
    "avg_hh_size",
    "pct_tertiary",
]

CATEGORICAL_FEATURES = ["settlement_class", "urban_rural"]

ALL_FEATURES: List[str] = []   # populated after data load
MODEL_META: dict = {}          # populated after training


# ── FastAPI app ─────────────────────────────────────────────────────────────
app = FastAPI(
    title="Fiscal Distress ML API",
    description="XGBoost + SHAP predictions for Austrian Gemeinde fiscal health.",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── global state (loaded once at startup) ──────────────────────────────────
panel: pd.DataFrame = None
model: XGBClassifier = None
explainer: shap.TreeExplainer = None
label_encoders: dict = {}
test_results: dict = {}


# ══════════════════════════════════════════════════════════════════════════
# Data preparation
# ══════════════════════════════════════════════════════════════════════════

def prepare_data(df: pd.DataFrame):
    """
    Build feature matrix X and binary target y.

    Target: will this municipality be IN DEFICIT in the following year?
    This is a genuine prediction task (t → t+1), not classifying known state.
    """
    global label_encoders, ALL_FEATURES

    df = df.copy()
    df = df.sort_values(["gcd", "year"]).reset_index(drop=True)

    # Create next-year deficit flag as target
    df["future_deficit"] = (
        df.groupby("gcd")["in_deficit"].shift(-1)
    )

    # Drop last year per zone (no future to predict) and rows missing target
    df = df.dropna(subset=["future_deficit"])
    df["future_deficit"] = df["future_deficit"].astype(int)

    # Encode categoricals
    for col in CATEGORICAL_FEATURES:
        if col in df.columns:
            le = LabelEncoder()
            df[col + "_enc"] = le.fit_transform(df[col].fillna("Unknown"))
            label_encoders[col] = le

    cat_encoded = [c + "_enc" for c in CATEGORICAL_FEATURES if c in df.columns]

    # Use socio features only where available (NaN-safe — XGBoost handles NaN)
    available_socio = [f for f in SOCIO_FEATURES if f in df.columns]

    ALL_FEATURES = FISCAL_FEATURES + available_socio + cat_encoded

    X = df[ALL_FEATURES].copy()
    y = df["future_deficit"]
    meta = df[["gcd", "year", "bundesland", "settlement_class",
               "urban_rural", "deficit_ratio", "deficit_streak",
               "exp_per_capita", "rev_per_capita"]]

    return X, y, meta, df


def train_model(X: pd.DataFrame, y: pd.Series, meta: pd.DataFrame):
    """
    Temporal train/test split:
      Train  : 2011 – 2016  (predict 2012–2017)
      Validate: 2017        (predict 2018)
      Test   : 2018–2019    (predict 2019–next)
    """
    global model, explainer, test_results, MODEL_META

    train_mask = meta["year"] <= 2016
    val_mask   = meta["year"] == 2017
    test_mask  = meta["year"] >= 2018

    X_train, y_train = X[train_mask], y[train_mask]
    X_val,   y_val   = X[val_mask],   y[val_mask]
    X_test,  y_test  = X[test_mask],  y[test_mask]

    logger.info(f"Train: {len(X_train)} | Val: {len(X_val)} | Test: {len(X_test)}")
    logger.info(f"Train deficit rate: {y_train.mean():.2%}")

    # Class imbalance weight
    neg, pos = (y_train == 0).sum(), (y_train == 1).sum()
    scale_pos = neg / pos if pos > 0 else 1.0

    model = XGBClassifier(
        n_estimators=400,
        max_depth=5,
        learning_rate=0.05,
        subsample=0.8,
        colsample_bytree=0.8,
        scale_pos_weight=scale_pos,
        eval_metric="auc",
        early_stopping_rounds=30,
        random_state=42,
        n_jobs=-1,
    )

    model.fit(
        X_train, y_train,
        eval_set=[(X_val, y_val)],
        verbose=False,
    )

    # Test performance
    y_prob = model.predict_proba(X_test)[:, 1]
    y_pred = (y_prob >= 0.5).astype(int)

    auc  = roc_auc_score(y_test, y_prob)
    ap   = average_precision_score(y_test, y_prob)
    report = classification_report(y_test, y_pred, output_dict=True)

    test_results = {
        "auc_roc":            round(auc,  4),
        "avg_precision":      round(ap,   4),
        "accuracy":           round(report["accuracy"], 4),
        "precision_deficit":  round(report.get("1", {}).get("precision", 0), 4),
        "recall_deficit":     round(report.get("1", {}).get("recall", 0), 4),
        "f1_deficit":         round(report.get("1", {}).get("f1-score", 0), 4),
        "n_test":             int(len(y_test)),
        "test_years":         "2018–2019",
        "train_years":        "2011–2016",
    }

    logger.info(f"Test AUC: {auc:.4f} | AP: {ap:.4f}")

    # SHAP explainer (TreeExplainer is fast + exact for XGBoost)
    explainer = shap.TreeExplainer(model)

    MODEL_META = {
        "features":       ALL_FEATURES,
        "target":         "future_deficit (in_deficit at t+1)",
        "n_features":     len(ALL_FEATURES),
        "best_iteration": model.best_iteration,
        "scale_pos_weight": round(scale_pos, 2),
    }

    # Persist model to disk
    joblib.dump({"model": model, "label_encoders": label_encoders,
                 "features": ALL_FEATURES}, MODEL_PATH)
    logger.info(f"Model saved → {MODEL_PATH}")


def encode_zone_df(df: pd.DataFrame) -> pd.DataFrame:
    """Apply fitted label encoders to a zone dataframe."""
    df = df.copy()
    for col, le in label_encoders.items():
        if col in df.columns:
            df[col + "_enc"] = df[col].apply(
                lambda v: le.transform([v])[0]
                if v in le.classes_ else -1
            )
    return df


# ══════════════════════════════════════════════════════════════════════════
# Startup
# ══════════════════════════════════════════════════════════════════════════

@app.on_event("startup")
async def startup():
    global panel

    logger.info("Loading panel_dataset.csv …")
    if not os.path.exists(PANEL_PATH):
        logger.error(f"panel_dataset.csv not found at {PANEL_PATH}")
        return

    panel = pd.read_csv(PANEL_PATH, dtype={"gcd": str})
    panel["gcd"] = panel["gcd"].str.zfill(5)
    logger.info(f"Panel loaded: {len(panel):,} rows | {panel['gcd'].nunique():,} Gemeinden "
                f"| years {panel['year'].min()}–{panel['year'].max()}")

    # Load cached model or train fresh
    if os.path.exists(MODEL_PATH):
        logger.info("Loading cached model …")
        cached = joblib.load(MODEL_PATH)
        global model, explainer, label_encoders, ALL_FEATURES
        model          = cached["model"]
        label_encoders = cached["label_encoders"]
        ALL_FEATURES   = cached["features"]
        explainer      = shap.TreeExplainer(model)
        logger.info("Cached model loaded.")
    else:
        logger.info("Training XGBoost model …")
        X, y, meta, _ = prepare_data(panel)
        train_model(X, y, meta)
        logger.info("Model training complete.")


# ══════════════════════════════════════════════════════════════════════════
# Request / response schemas
# ══════════════════════════════════════════════════════════════════════════

class ZoneRequest(BaseModel):
    ids: List[str]
    year: Optional[int] = None   # defaults to latest available

class ShapRequest(BaseModel):
    ids: List[str]
    year: Optional[int] = None
    top_n: Optional[int] = 8

class ForecastRequest(BaseModel):
    ids: List[str]
    horizon: Optional[int] = 3   # years ahead to forecast


# ══════════════════════════════════════════════════════════════════════════
# Endpoints
# ══════════════════════════════════════════════════════════════════════════

@app.get("/health")
def health():
    return {
        "status":        "ok",
        "model_loaded":  model is not None,
        "panel_rows":    len(panel) if panel is not None else 0,
        "latest_year":   int(panel["year"].max()) if panel is not None else None,
        "n_features":    len(ALL_FEATURES),
    }


@app.get("/model_performance")
def model_performance():
    if model is None:
        raise HTTPException(503, "Model not loaded.")
    return {
        "model":        "XGBoostClassifier",
        "meta":         MODEL_META,
        "test_metrics": test_results,
        "interpretation": {
            "auc_roc":   "Area under ROC curve (1.0 = perfect, 0.5 = random)",
            "avg_precision": "Area under precision-recall curve — better metric for imbalanced targets",
            "recall_deficit": "% of true future deficits the model catches",
        }
    }


@app.get("/feature_importance")
def feature_importance():
    """Global SHAP feature importance (mean |SHAP value| across all training rows)."""
    if model is None or panel is None:
        raise HTTPException(503, "Model not loaded.")

    sample = panel[panel["year"] <= 2016].copy()
    sample = encode_zone_df(sample)
    available = [f for f in ALL_FEATURES if f in sample.columns]
    X_sample  = sample[available].fillna(0).head(2000)

    shap_vals = explainer.shap_values(X_sample)
    mean_abs  = np.abs(shap_vals).mean(axis=0)

    importance = sorted(
        [{"feature": f, "mean_shap": round(float(v), 5)}
         for f, v in zip(available, mean_abs)],
        key=lambda x: x["mean_shap"],
        reverse=True,
    )

    return {
        "method":     "mean |SHAP value| over training sample",
        "n_samples":  len(X_sample),
        "importance": importance,
    }


@app.post("/predict_distress")
def predict_distress(req: ZoneRequest):
    """
    Predict probability that each selected zone will be IN DEFICIT
    in the year following the requested year.
    """
    if model is None or panel is None:
        raise HTTPException(503, "Model not loaded.")

    ids = [str(i).zfill(5) for i in req.ids]
    yr  = req.year or int(panel["year"].max())

    zone_data = panel[(panel["gcd"].isin(ids)) & (panel["year"] == yr)].copy()
    if zone_data.empty:
        raise HTTPException(404, f"No data for selected zones in year {yr}.")

    zone_data = encode_zone_df(zone_data)
    available = [f for f in ALL_FEATURES if f in zone_data.columns]
    X         = zone_data[available]

    probs = model.predict_proba(X)[:, 1]
    preds = (probs >= 0.5).astype(int)

    results = []
    for i, (_, row) in enumerate(zone_data.iterrows()):
        prob = float(probs[i])
        results.append({
            "gcd":              row["gcd"],
            "year_used":        yr,
            "predicts_year":    yr + 1,
            "bundesland":       row.get("bundesland"),
            "settlement_class": row.get("settlement_class"),
            "urban_rural":      row.get("urban_rural"),
            "distress_probability": round(prob, 4),
            "predicted_deficit":    int(preds[i]),
            "risk_category": (
                "High"   if prob >= 0.65 else
                "Medium" if prob >= 0.35 else
                "Low"
            ),
            "current_deficit_ratio": round(float(row.get("deficit_ratio", 0) or 0), 4),
            "deficit_streak":        int(row.get("deficit_streak", 0) or 0),
        })

    results.sort(key=lambda x: x["distress_probability"], reverse=True)

    return {
        "model":   "XGBoostClassifier",
        "year":    yr,
        "note":    f"Predicts fiscal deficit in {yr + 1}",
        "zones":   results,
    }


@app.post("/shap_explain")
def shap_explain(req: ShapRequest):
    """
    SHAP waterfall explanation for each selected zone.
    Returns top-N features driving the distress prediction.
    """
    if model is None or panel is None:
        raise HTTPException(503, "Model not loaded.")

    ids = [str(i).zfill(5) for i in req.ids]
    yr  = req.year or int(panel["year"].max())
    top_n = min(req.top_n or 8, len(ALL_FEATURES))

    zone_data = panel[(panel["gcd"].isin(ids)) & (panel["year"] == yr)].copy()
    if zone_data.empty:
        raise HTTPException(404, f"No data for selected zones in year {yr}.")

    zone_data = encode_zone_df(zone_data)
    available = [f for f in ALL_FEATURES if f in zone_data.columns]
    X         = zone_data[available]

    shap_vals = explainer.shap_values(X)
    base_val  = float(explainer.expected_value)
    probs     = model.predict_proba(X)[:, 1]

    explanations = []
    for i, (_, row) in enumerate(zone_data.iterrows()):
        sv    = shap_vals[i]
        order = np.argsort(np.abs(sv))[::-1][:top_n]

        contributions = [
            {
                "feature":     available[j],
                "value":       round(float(X.iloc[i, j]), 4) if not pd.isna(X.iloc[i, j]) else None,
                "shap_value":  round(float(sv[j]), 5),
                "direction":   "increases_risk" if sv[j] > 0 else "decreases_risk",
            }
            for j in order
        ]

        explanations.append({
            "gcd":                  row["gcd"],
            "year":                 yr,
            "distress_probability": round(float(probs[i]), 4),
            "base_probability":     round(float(1 / (1 + np.exp(-base_val))), 4),
            "top_drivers":          contributions,
            "interpretation": (
                "Each shap_value shows how much that feature "
                "pushes the prediction above (positive) or "
                "below (negative) the base rate."
            ),
        })

    return {
        "year":         yr,
        "base_rate":    round(float(1 / (1 + np.exp(-base_val))), 4),
        "explanations": explanations,
    }


@app.post("/fiscal_forecast")
def fiscal_forecast(req: ForecastRequest):
    """
    Multi-year fiscal distress forecast for selected zones.
    Iteratively predicts distress probability for each year in the horizon.
    Note: uncertainty increases with each step — treat as indicative.
    """
    if model is None or panel is None:
        raise HTTPException(503, "Model not loaded.")

    ids     = [str(i).zfill(5) for i in req.ids]
    horizon = min(req.horizon or 3, 5)
    yr      = int(panel["year"].max())

    base_data = panel[(panel["gcd"].isin(ids)) & (panel["year"] == yr)].copy()
    if base_data.empty:
        raise HTTPException(404, f"No base data found for selected zones in {yr}.")

    forecasts = {gcd: [] for gcd in base_data["gcd"].unique()}

    current = base_data.copy()
    for step in range(horizon):
        pred_year = yr + step + 1
        current   = encode_zone_df(current)
        available = [f for f in ALL_FEATURES if f in current.columns]
        X         = current[available]
        probs     = model.predict_proba(X)[:, 1]
        preds     = (probs >= 0.5).astype(int)

        for i, (_, row) in enumerate(current.iterrows()):
            forecasts[row["gcd"]].append({
                "year":                 pred_year,
                "distress_probability": round(float(probs[i]), 4),
                "predicted_deficit":    int(preds[i]),
            })

        # Roll forward: update deficit_streak based on prediction
        current = current.copy()
        current["deficit_streak"] = np.where(
            preds == 1,
            current["deficit_streak"].fillna(0) + 1,
            0,
        )
        current["in_deficit"]   = preds
        current["deficit_ratio"] = np.where(
            preds == 1,
            current["deficit_ratio"].fillna(0).abs(),
            -current["deficit_ratio"].fillna(0).abs(),
        )
        current["year"] = pred_year

    output = [
        {
            "gcd":             gcd,
            "bundesland":      base_data.loc[base_data["gcd"] == gcd, "bundesland"].iloc[0],
            "settlement_class":base_data.loc[base_data["gcd"] == gcd, "settlement_class"].iloc[0],
            "base_year":       yr,
            "forecast":        steps,
        }
        for gcd, steps in forecasts.items()
    ]

    return {
        "base_year": yr,
        "horizon":   horizon,
        "note":      "Forecast uncertainty compounds each year. Use for indicative planning only.",
        "zones":     output,
    }
