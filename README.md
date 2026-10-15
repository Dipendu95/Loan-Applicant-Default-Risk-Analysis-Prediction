# Loan Applicant Default Risk Analysis & Prediction

## Brief One Line Summary

An end-to-end SQL, Python and Power BI project that analyses historical loan defaults and prioritises new applicants for risk review using synthetic data.

## Overview

This project follows the lending journey from application and credit history to loan issuance, repayment and default outcomes. It combines data cleaning, exploratory analysis, predictive modelling and a two-page interactive dashboard.

| Applications analysed | Historical issued loans | New applicants scored | Priority review applicants |
| :---: | :---: | :---: | :---: |
| **30,000** | **19,393** | **6,000** | **1,300** |

> **Synthetic portfolio project:** All applicants, lending decisions and repayment outcomes are simulated. Findings demonstrate analytical methods and are not validated real-world lending rules.

## Problem Statement

A lending team needs to understand historical default patterns and decide which new applications deserve closer attention. Treating every application with equal urgency can make it difficult to focus review capacity.

The project addresses three questions:

- Which application-time characteristics are associated with higher observed default rates?
- Can a model rank new applicants by estimated default risk?
- How can a dashboard turn those estimates into an understandable review queue?

The intended output supports **manual review prioritisation**, not automatic approval or rejection.

## Dataset

The dataset was generated specifically for this project and represents a fictional Indian lending scenario across 12 cities.

| Applicant group | Applications | Period / status |
| --- | ---: | --- |
| Historical approved | 19,393 | January 2023–June 2025; 12 months of loan outcomes |
| Historical rejected | 4,607 | January 2023–June 2025; no issued-loan outcome |
| New applicants | 6,000 | August 2026; pending decisions |
| **Total** | **30,000** | |

Eight core tables cover applications, cities, bureau summaries, prior credit accounts, decisions, originations, monthly repayments and outcomes. They include **70,290 prior credit accounts** and **232,716 monthly repayment observations**.

**Target:** `Default_90DPD_12M = 1` when a loan reaches at least 90 days past due in one of its first 12 monthly snapshots. A value of 0 means no such event during the complete observation window; it does not mean the full loan has been repaid.

Rejected and pending applications have no observed loan outcome. Their missing labels are not converted to zero.

## Tools and Technologies

![SQL Server](https://img.shields.io/badge/SQL_Server-CC2927?style=flat-square)
![Python](https://img.shields.io/badge/Python-3776AB?style=flat-square&logo=python&logoColor=white)
![pandas](https://img.shields.io/badge/pandas-150458?style=flat-square&logo=pandas&logoColor=white)
![scikit-learn](https://img.shields.io/badge/scikit--learn-F7931E?style=flat-square&logo=scikitlearn&logoColor=white)
![Power BI](https://img.shields.io/badge/Power_BI-F2C811?style=flat-square)

| Tool | Use |
| --- | --- |
| SQL Server / SSMS | CSV imports, cleaning, validation, joins, analysis and feature views |
| Python / pandas | Export checks, data preparation and scoring outputs |
| scikit-learn | Preprocessing pipelines, Logistic Regression, Random Forest and evaluation |
| Google Colab | Notebook execution |
| joblib | Saving the fitted model and preprocessing pipeline |
| Power BI / Power Query / DAX | Data model, measures, filters and interactive reporting |

## Methods

### 1. SQL cleaning and validation

- Removed 150 duplicate rows from 30,150 raw application records.
- Standardised employment categories and cleaned application-channel text.
- Converted 120 blank loan purposes and 40 invalid negative incomes to NULL.
- Retained 90 missing tenure values and meaningful bureau missingness for later preprocessing.
- Converted dates and numeric types, checked business rules, and added primary and foreign keys.
- Reconciled prior-account totals with bureau summaries and outcomes with monthly repayment records.

### 2. Feature engineering

Created application-time features such as existing obligation-to-income ratio, living expense ratio, requested amount-to-annual-income ratio, outstanding balance-to-annual-income ratio and missing-value flags.

Estimated free cash flow subtracts living expenses and existing obligations from income; it excludes the proposed loan's EMI.

The model uses **32 predictors: 24 numeric and eight categorical**. Identifiers, raw dates, cohort, split metadata and future loan outcomes are excluded from predictors. Post-decision loan terms and repayment records are not model inputs.

### 3. Model development

Numeric features use median imputation and standard scaling. Categorical features use constant-value imputation and one-hot encoding. These transformations are fitted inside the training pipelines.

| Dataset stage | Rows | Definition |
| --- | ---: | --- |
| Training pool | 7,700 | Historical loans whose observation windows ended before 1 January 2025 |
| Model training | 6,160 | Stratified 80% of that pool |
| Internal validation | 1,540 | Remaining stratified 20% |
| Later test | 3,987 | Applications from January–June 2025 |
| Excluded from this evaluation | 7,706 | Other labelled historical loans |

Logistic Regression and Random Forest were compared using validation results. Random Forest was selected, and a **20% threshold** gave the highest validation F1 among the seven tested thresholds. It was fixed before the later test evaluation.

The forest uses 300 trees, maximum depth 8, minimum leaf size 20 and `random_state=42`.

### 4. Final scoring

After evaluation, a fresh pipeline with the selected settings was fitted on all **19,393 labelled historical loans**. Their outcomes were available before the August 2026 scoring cohort.

Applicants with predicted probabilities **≥20%** receive a priority-review flag. Others receive standard review. This threshold is a demonstration choice based on validation F1, not a financially optimised credit policy.

## Key Insights

These findings describe the synthetic approved-loan population with observed outcomes.

| Finding | Evidence |
| --- | --- |
| Historical default rate | **2,544 of 19,393 loans — 13.12%** |
| Lower credit scores were associated with higher default rates | **36.20%** below 600 versus **5.12%** at 800+ |
| Higher existing obligations were associated with higher default rates | **39.83%** above a 60% obligation ratio versus **8.95%** above 0–20% |
| Default rates differed by employment type | Contract **15.34%**, self-employed **14.08%**, salaried **12.35%** |
| Previous credit delays were associated with higher default rates | **15.44%** for prior accounts with delays versus **6.40%** for prior accounts without delays |
| Affordability was the largest simulated rejection reason | **57.33%** of historical rejections |

Segment sizes differ, and these associations do not establish causation. For example, the below-600 score band has 221 observed loans.

Among applicants with known income ratios, 21.15% of new applicants have existing obligations above 40% of income, compared with 13.25% of historically approved applicants. Including rejected applicants raises the historical comparison to 20.56%, so the comparison population matters.

## Dashboard/Model/Output

### Page 1 — Historical Applications & Defaults

Historical application, approval, rejection and default KPIs, with default-rate comparisons by credit score, employment type and existing obligation ratio. City and application-date filters support exploration.

![Historical Applications and Defaults dashboard](screenshots/historical_applications_defaults.jpg)

### Page 2 — New Applicant Risk

New-applicant scoring totals, review-status distribution, priority reviews by city and an applicant table sorted by predicted risk. A city filter allows focused review.

![New Applicant Risk dashboard](screenshots/new_applicant_risk.jpg)

### Model comparison

| Model | Validation ROC-AUC | Validation average precision |
| --- | ---: | ---: |
| Logistic Regression | 0.7218 | 0.3541 |
| **Random Forest** | **0.7320** | **0.3685** |

### Later test performance

| Metric | Result |
| --- | ---: |
| ROC-AUC | **0.6932** |
| Average precision | **0.2683** |
| Precision at 20% threshold | **29.08%** |
| Recall at 20% threshold | **32.95%** |
| F1 score | **0.3089** |

The evaluated model flagged 588 of 3,987 test applications: **171 defaults were identified**, 348 were missed, and 417 flagged loans did not default. The remaining 3,051 non-default loans were not flagged.

These test results describe the model trained on 6,160 rows, not an independent evaluation of the later refit on all historical loans.

### Deliverables

- [SQL analysis and cleaning script](sql/Loan_Applicant_Default_Risk_Analysis.sql)
- [Python modelling notebook](Python/Loan_Applicant_Default_Risk_Model.ipynb)
- [Power BI dashboard](powerbi/Loan_Applicant_Default_Risk.pbix)
- `new_applicant_risk_predictions.csv` — applicant probabilities and review flags.
- `loan_applicant_risk_model.joblib` — preprocessing pipeline, model, feature list and scoring threshold.

## How to Run This Project?

1. **Prepare the files.** Keep the source CSVs under `data/raw_practice/` and `data/clean/`. Keep the SQL script in `sql/`, the notebook in `Python/` and the report in `powerbi/`.
2. **Run SQL.** Update the eight CSV paths in `Loan_Applicant_Default_Risk_Analysis.sql`. Run its numbered sections in SSMS and inspect the validation results. The script creates `LoanApplicantRiskDB` if absent. It is a first-build script: do not rerun the whole script against an already populated database.
3. **Export modelling data with headers.** Export `vw_model_development` as `model_development.csv` (19,393 rows, 41 columns) and `vw_new_applicants_to_score` as `new_applicants_to_score.csv` (6,000 rows, 38 columns) into `data/model_exports/`. Use these SQL exports rather than the original generator's convenience model files.
4. **Run Python.** Open the notebook in Google Colab, upload the two exports and run cells in order. Required packages are pandas, scikit-learn and joblib. The notebook validates schemas, parses dates, compares models, evaluates the selected model and scores the new applicants.
5. **Save outputs.** Download the prediction CSV and model bundle. The final notebook cell also exports validation comparisons, test predictions and a JSON run summary with package versions.
6. **Open Power BI.** Open `powerbi/Loan_Applicant_Default_Risk.pbix`. To refresh on another computer, update the SQL Server connection and prediction CSV path. Use the page filters and slicers to explore results.

Keep `README.md` and the `screenshots/` folder at repository root so the dashboard images display. The SQL and notebook filenames should match the links above, without download suffixes such as `(1)`.

**Reproduction note:** The notebook retains saved results from the original run. Some later edited or added cells have cleared outputs and need execution. This documentation was checked against code, saved outputs and dashboard evidence; it does not claim a fresh end-to-end rerun.

## Results & Conclusion

The project connects SQL data preparation, Python modelling and Power BI reporting in one workflow. It produces a review queue for **6,000 new applicants**, including **1,300 priority reviews (21.67%)** and **4,700 standard reviews**. Average predicted risk is **15.38%**, which is a model estimate rather than an observed default rate.

The later test shows modest predictive discrimination and a clear trade-off between identifying defaults and generating unnecessary reviews. The output is suitable for demonstrating review prioritisation and transparent reporting of model limitations.

Important limits:

- All data are synthetic; the model may learn simulator behaviour that does not transfer to real borrowers.
- Outcomes exist only for approved issued loans, so performance on rejected applicants or the entire applicant population is unproven.
- SQL exploratory analysis already used test-period labels. The later test is held out from model fitting, but is not a completely unseen research holdout.
- Probability calibration, fairness, financial loss and review-capacity optimisation were not assessed.
- New applicants have no observed outcomes yet; the final refitted model and its threshold need future evaluation.

## Future Work

- Evaluate probability calibration and reliability of predicted risk bands.
- Investigate the performance difference between internal validation and the later test period.
- Compare thresholds under explicit review-capacity and business-cost assumptions.
- Monitor applicant characteristics and outcomes as new loans mature.
- Assess subgroup performance and fairness before considering any real-world use.

## Author & Contact

**Dipendu Roy**  
Aspiring Data Analyst | SQL · Python · Power BI · Excel

For project questions and feedback, please open an issue in this GitHub repository.
