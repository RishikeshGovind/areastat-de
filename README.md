# AreaStat AT

Interactive web platform for exploring demographic, socioeconomic, and fiscal patterns across Austrian municipalities (Gemeinden) and districts (Bezirke). Built as part of a PhD research proposal on municipal fiscal resilience and spatial differentiation in Austria.

**Live:** https://rishikeshgovind.github.io/areastat-at/

---

## What it does

Select any combination of municipalities or districts on the map, then explore:

- **Charts & Tables** — demographic, labour market, economic, education, migration, and household indicators benchmarked against the Austrian average
- **Run Typology** — k-means clustering that groups selected zones into socioeconomic types, with trait summaries and key differentiators
- **Analysis tab** — five fiscal and ML panels:
  - *ML Distress* — XGBoost model predicting fiscal distress probability with SHAP explanations
  - *Risk Summary* — rule-based fiscal risk scoring across selected zones
  - *Spending* — expenditure and revenue profiles per capita
  - *Clustering* — fiscal k-means groupings
  - *Trends* — time-series charts for key fiscal metrics (2010–2019)

District selections are automatically expanded to their constituent municipalities for fiscal analysis.

---

## Architecture

| Component | Stack | Hosting |
|---|---|---|
| Frontend | Vanilla JS, MapLibre GL, Chart.js, Bootstrap 4 | GitHub Pages |
| R API | R Plumber — clustering, fiscal summaries | HuggingFace Spaces (Docker) |
| Python API | FastAPI + XGBoost — ML distress model, SHAP | HuggingFace Spaces (Docker) |

---

## Data Sources

| Dataset | Source |
|---|---|
| Municipal statistics | Statistik Austria OGD — `OGDEXT_AEST_GEMTAB_1` |
| Municipal boundaries | ginseng666/GeoJSON-TopoJSON-Austria |
| Fiscal panel (2010–2019) | Statistik Austria — *Gemeindegebarung* |
| Urban-rural typology | Derived from population thresholds; override via `create-js/inputs/oerok_typology.csv` |

---

## Project Structure

```
.
├── index.html                  Map and area selection
├── profile.html                Profile, charts, analysis
├── style.css                   Shared styles
├── js/
│   └── shared.js               API URLs, i18n, shared helpers
├── plumber.R                   R API (clustering, fiscal endpoints)
├── fiscal_ml_api.py            Python ML API (XGBoost, SHAP)
├── requirements.txt            Python dependencies
├── Dockerfile.plumber          Docker build for R API
├── Dockerfile.python           Docker build for Python API
├── data.json                   Pre-built frontend data (generated)
├── data/
│   ├── final_json.rds          R data cache
│   ├── panel_dataset.csv       Fiscal panel (2010–2019)
│   └── xgb_fiscal_model.joblib Trained XGBoost model
└── create-js/
    ├── config.R                R dependencies
    ├── fetch_austria_data.R    Statistik Austria OGD pipeline
    ├── build_panel.R           Fiscal panel builder
    └── create_data.R           Main data build script
```

---

## Running Locally

### 1. Generate the profile data

```r
source("create-js/create_data.R")
```

Writes `data.json` and `data/final_json.rds`.

### 2. Start the R API

```r
plumber::plumb("plumber.R")$run(port = 8000)
```

### 3. Start the Python ML API (optional)

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn fiscal_ml_api:app --port 8001 --reload
```

### 4. Serve the frontend

Use VS Code Live Server or any local static server. Do not open HTML files directly via `file://` — browser fetch restrictions will block `data.json`.

---

## API Reference

### R Plumber (`/`)

| Endpoint | Description |
|---|---|
| `GET /cluster_typology` | Socioeconomic k-means typology for selected zones |
| `GET /fiscal_profile` | Expenditure and revenue profile |
| `GET /fiscal_risk_summary` | Rule-based fiscal risk scoring |
| `GET /fiscal_clustering` | Fiscal k-means groupings |
| `GET /fiscal_timeseries` | Time-series for fiscal metrics |
| `GET /zone_timeseries` | Indicator time-series for a single zone |

All endpoints accept `ids` as a comma-separated list of GKZ codes.

### Python ML API (`/`)

| Endpoint | Description |
|---|---|
| `GET /health` | Service status |
| `POST /predict_distress` | XGBoost distress probability per zone |
| `POST /shap_explain` | SHAP feature attributions |
| `POST /fiscal_forecast` | Indicative multi-year forecast |
| `GET /model_performance` | Model metrics (AUC-ROC, etc.) |
| `GET /feature_importance` | Global feature importance |

---

## Links

- Statistik Austria OGD: https://data.statistik.gv.at
- ÖROK typology: https://www.oerok.gv.at/raum-region/daten-und-grundlagen/regionsabgrenzungen/
- Eurostat LAU: https://ec.europa.eu/eurostat/web/nuts/local-administrative-units
