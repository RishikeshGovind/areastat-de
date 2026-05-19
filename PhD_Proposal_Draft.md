# PhD Research Proposal

**Programme:** Economics and Statistics
**Department:** Banking and Finance

---

## Title

**Predicting Subnational Fiscal Distress: Machine Learning, Spatial Spillovers, and Financial Stability Implications Across European Local Governments**

---

## Abstract

Local governments across Europe hold substantial debt, deliver critical public services, and are deeply embedded in national banking systems. Yet the prediction and early detection of municipal fiscal distress remains methodologically underdeveloped relative to its corporate and sovereign counterparts. This proposal argues that the intersection of machine learning, spatial econometrics, and public finance offers a productive frontier for both academic research and financial stability analysis. Drawing on granular panel data from European local government finance statistics, this thesis will develop and evaluate predictive models for subnational fiscal distress, examine the spatial and structural drivers of fiscal vulnerability, and assess the implications for bank exposure and systemic risk. The research will contribute to the growing literature on algorithmic credit risk modelling, subnational public finance, and the macroprudential consequences of local government financial fragility.

---

## 1. Motivation and Research Gap

The fiscal health of local governments is a material concern for financial stability. Municipalities are significant issuers of sub-sovereign debt, counterparties to regional banks, and providers of the infrastructure and welfare services that underpin economic activity. The 2010–2012 European sovereign debt crisis demonstrated that subnational fiscal stress can rapidly interact with banking sector fragility, yet local government credit risk has attracted far less systematic research than corporate or sovereign risk.

Traditional approaches to municipal credit assessment — bond ratings, rule-based fiscal indicators, debt-to-revenue thresholds — face well-documented limitations: they are backward-looking, jurisdiction-specific, and poorly calibrated to the diverse institutional and economic contexts that exist across European local government systems. At the same time, the proliferation of high-quality administrative and statistical data from Eurostat, national statistical offices, and central banks creates an opportunity to develop more rigorous, data-driven approaches.

Machine learning methods — particularly gradient-boosted trees, penalised regression, and neural networks — have demonstrated strong out-of-sample predictive performance in corporate bankruptcy and sovereign default modelling. However, their application to subnational fiscal risk is nascent. Key gaps include: the absence of cross-country comparative studies; limited integration of spatial dependence and geographic spillover effects; and a lack of interpretability analysis connecting model outputs to actionable policy and financial stability insights.

This thesis addresses these gaps directly.

---

## 2. Research Questions

1. **Prediction:** Can machine learning models outperform conventional fiscal indicators and logistic regression benchmarks in predicting municipal fiscal distress across European local governments?

2. **Drivers:** What structural, demographic, and macroeconomic factors most strongly drive subnational fiscal vulnerability, and do these drivers vary systematically across urban-rural gradients and institutional contexts?

3. **Spatial dynamics:** To what extent does fiscal distress exhibit spatial dependence — that is, do neighbouring municipalities show correlated fiscal outcomes beyond what shared macroeconomic conditions would predict?

4. **Financial stability:** What are the implications of concentrated subnational fiscal vulnerability for bank balance sheets and regional financial stability, particularly for savings banks and cooperative banks with high local government exposure?

---

## 3. Proposed Methodology

The thesis will follow a three-paper structure.

### Paper 1 — Baseline Predictive Models for Municipal Fiscal Distress

Using Austria as a well-documented and data-rich initial setting, this paper will establish a rigorous prediction framework. The Austrian *Gemeindegebarung* panel (2010–2019), covering all 2,100+ municipalities, provides annual expenditure, revenue, deficit, and debt data at municipal level. This will be linked to Statistik Austria's socioeconomic and demographic indicators across six thematic domains.

A binary distress indicator will be constructed from deficit persistence, debt-service coverage, and expenditure-revenue imbalance. Models estimated will include: logistic regression (benchmark), LASSO and ridge regression, random forests, and XGBoost. Model performance will be evaluated by AUC-ROC, precision-recall curves, and out-of-sample Brier scores. Shapley Additive Explanations (SHAP) will be used to decompose variable importance and produce interpretable, municipality-level risk attribution.

An interactive web-based research tool has been developed to support this work, enabling dynamic exploration of municipal profiles, clustering typologies, and ML-based distress predictions across Austrian Gemeinden and Bezirke.

### Paper 2 — Spatial Econometrics of Fiscal Vulnerability

This paper will extend the framework to incorporate spatial dependence explicitly. Fiscal distress may be spatially correlated for several reasons: shared regional labour markets, common exposure to sectoral shocks, inter-municipal fiscal transfers, and tax competition effects.

Spatial lag and spatial error models will be estimated using GeoDa and R's `spdep` package. Moran's I statistics will be used to test for spatial clustering of fiscal distress and its determinants. The paper will test whether spatial spillovers persist after controlling for observable covariates, and estimate the magnitude of indirect effects — the degree to which a fiscal shock in one municipality propagates to its neighbours.

The analysis will be extended to a multi-country setting using Eurostat's Local Administrative Units (LAU) dataset, covering Austria, Germany, and selected Central and Eastern European countries where comparable fiscal microdata is available.

### Paper 3 — Subnational Fiscal Risk and Banking Sector Exposure

The final paper connects the municipality-level risk predictions to banking sector outcomes. Savings banks (*Sparkassen*) and cooperative banks (*Raiffeisenbanken*) in German-speaking countries have historically high local government exposure, creating a channel through which subnational fiscal stress can affect regional financial stability.

Using ECB supervisory data (where accessible) and national banking statistics, this paper will: estimate bank-level exposure to municipalities in predicted fiscal distress; test whether elevated municipal distress risk is associated with loan loss provisions or non-performing loan ratios; and examine whether spatial clustering of fiscal distress amplifies banking sector vulnerability through geographic concentration.

The modelling approach will draw on panel fixed-effects models and, where identification challenges permit, instrumental variables exploiting exogenous variation in municipal fiscal rules across states (*Bundesländer*) and countries.

---

## 4. Data Sources

| Data | Source | Coverage |
|---|---|---|
| Municipal fiscal accounts | Statistik Austria *Gemeindegebarung* | Austria, 2010–2019, 2,100+ municipalities |
| Socioeconomic indicators | Statistik Austria OGD `OGDEXT_AEST_GEMTAB_1` | Austria, municipality-level |
| EU local government finance | Eurostat LAU, COFOG | EU-27 |
| Spatial boundaries | Statistik Austria, Eurostat GISCO | Austria, EU |
| Bank exposure to public sector | ECB BSI statistics, OeNB | Austria, Euro Area |
| Urban-rural typology | ÖROK, Eurostat Degree of Urbanisation | Austria, EU |

---

## 5. Expected Contributions

**Academic:** This thesis will produce the first systematic cross-country machine learning study of subnational fiscal distress in Europe, with methodological contributions in spatial ML and interpretable prediction. The SHAP-based attribution framework will provide a new tool for decomposing local government fiscal risk that is transferable to policy and supervisory contexts.

**Policy:** The municipality-level risk scores and typology framework developed in Paper 1 are directly applicable by regional governments, fiscal oversight bodies, and central banks monitoring subnational fiscal sustainability.

**Financial stability:** The bank exposure analysis in Paper 3 will contribute to the macroprudential literature on geographic concentration risk and the bank-sovereign nexus at the subnational level, an area flagged by the ECB and national central banks as insufficiently studied.

---

## 6. Candidate Background

I hold an MSc in Risk and Investment Management, providing a strong foundation in credit risk modelling, portfolio theory, and quantitative finance. Prior to beginning doctoral studies, I worked as a statistician at the Northern Ireland Statistics and Research Agency (NISRA), where I developed experience in working with official administrative data, statistical production pipelines, and evidence-based policy analysis. This combination of financial risk expertise and applied statistical practice is directly relevant to the proposed research.

As part of developing this proposal, I have already built a functional research infrastructure: AreaStat AT (https://rishikeshgovind.github.io/areastat-at/), an interactive platform for exploring Austrian municipal statistics, typology clustering, and XGBoost-based fiscal distress prediction. This demonstrates the technical feasibility of the approach and provides a working foundation for Paper 1.

---

## 7. Indicative Timeline

| Year | Milestones |
|---|---|
| Year 1 | Literature review; data acquisition and cleaning; Paper 1 (Austria ML models) |
| Year 2 | Paper 1 submission; Paper 2 (spatial econometrics, multi-country extension) |
| Year 3 | Paper 2 submission; Paper 3 (bank exposure); thesis writing and defence preparation |

---

## 8. Selected References

- Bonfim, D. (2009). Credit risk drivers: Evaluating the contribution of firm level information and macroeconomic dynamics. *Journal of Banking & Finance.*
- Duan, J., Sun, J., & Wang, T. (2012). Multiperiod corporate default prediction — a forward intensity approach. *Journal of Econometrics.*
- Fitch Ratings (2022). *International Local and Regional Government Rating Criteria.*
- Gennaioli, N., Martin, A., & Rossi, S. (2014). Sovereign default, domestic banks, and financial institutions. *Journal of Finance.*
- LeSage, J., & Pace, R. K. (2009). *Introduction to Spatial Econometrics.* CRC Press.
- Lundberg, S., & Lee, S. I. (2017). A unified approach to interpreting model predictions. *NeurIPS.*
- Merlo, V., Ruf, S., & Winkler, A. (2021). Local government fiscal vulnerability and bank lending. *Journal of Financial Stability.*
- Rodden, J. (2002). The dilemma of fiscal federalism: Grants and fiscal performance around the world. *American Journal of Political Science.*
- Tibshirani, R. (1996). Regression shrinkage and selection via the lasso. *Journal of the Royal Statistical Society.*
