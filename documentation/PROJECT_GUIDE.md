# Project guide

## Business brief

A fictional lender wants to analyse affordability and previous credit behaviour at application time, then estimate which issued loans would reach serious delinquency within a year. The deliverable is a risk-analysis dashboard and an optional probability model for prioritising manual review of new synthetic applications.

## Table grain and relationships

| Table | One row represents | Key / relationship |
|---|---|---|
| dim_city | A city | City_ID, 12 rows |
| applications | A unique applicant's application | Application_ID; City_ID links to dim_city |
| bureau_summary | Credit summary as of the application date | Application_ID, one-to-one with applications |
| prior_credit_accounts | A prior account at the application snapshot | Credit_Account_ID; many accounts to one application |
| application_decisions | Historical decision or pending status | Application_ID, one-to-one |
| loan_originations | A disbursed historical loan | Loan_ID; zero or one per application |
| monthly_repayments | One of 12 monthly loan observations | Composite Loan_ID + Month_Number |
| loan_outcomes | Application's available outcome or missing-outcome status | Application_ID, one-to-one |

Aggregate prior accounts to application grain before joining them to repayment facts. Joining two many-row tables directly can inflate income, balances and payment totals. In Power BI, use single-direction relationships from the application and loan keys to their detail tables. Add a date dimension for application trends; repayment snapshots represent a different date role.

## Target and denominator

`Default_90DPD_12M = 1` means the loan reached **at least 90 calendar days past due in one of the first 12 monthly snapshots**. Once the event occurs, the target remains 1 even if the borrower later catches up. This is a project-specific serious-delinquency definition, not a claim about statutory default classifications.

`0` means all 12 observations are available and no observation crossed that threshold. It does **not** mean the full loan was repaid. Loans can have terms up to 60 months; the package shows only the first year.

Blank means no funded loan outcome exists: historical rejected applicants or new pending applicants. Do not replace blank labels with zero or label a rejection as a default. Synthetic data does not remove this conceptual difference.

Default-rate denominator: historical issued loans with 12 observed months and non-null target. Application approval-rate denominator: historical applications only. New pending applications must not enter either denominator.

The cash simulation is monthly. Payments are aggregated within each billing window; their exact daily transaction times are not available. DPD is calculated at month end against the oldest partially or wholly unpaid installment using FIFO allocation. Thus the recorded event date is the first qualifying snapshot, not the exact day of crossing.

## Financial conventions

- Application incomes, expenses and existing obligations are monthly amounts.
- Expenses exclude debt payments to avoid double-counting the obligations.
- Nominal annual loan interest rates are fractions; 0.15 means 15%.
- EMI uses reducing-balance amortisation, rounded to two decimals. No origination fees, taxes, penalties, prepayment, write-offs or recoveries are simulated.
- EMI rounding may require a final-term adjustment in a real amortisation schedule. Do not reconstruct full-term principal balances from this first-year dataset.
- `Arrears_INR` contains scheduled interest and principal installments. It is not loss, exposure at default or principal balance.
- Prior installment obligations use a simplified approximation; credit-card obligations use 5% of outstanding balance. These are simulation conventions, not lender rules.
- Historical bureau data is a summary/snapshot, not individual prior repayment transactions. A closed account can have recent historical late payments.

## Application-time modelling

Use the application attributes and bureau_summary. Derive existing debt-to-income ratio, requested loan-to-income ratio, and available monthly surplus. Applicant identifiers are join keys, not predictors. City can be used for descriptive analysis; demographic fields need not enter the baseline model.

Exclude: decision, decision reason, disbursed amount, contracted interest rate, EMI from originations, all new-loan payment fields, observation length, first default date, maximum future DPD and all outcome fields except the supervised target. The approved amount and rate occur after the application decision. Exclude `Cohort`, `Suggested_Split`, identifiers and raw dates from ordinary numerical model inputs.

The `model_training.csv` is a convenience view of application-time features plus the target and a proposed chronological partition. Use training data only to learn imputations, encodings, scaling and fitted model parameters. Evaluate with precision, recall, PR-AUC, ROC-AUC and calibration. Class imbalance should be retained in validation and test sets. Do not optimise a threshold on the test set.

Suggested partition: applications before July 2024 for training; July-December 2024 for validation; January-June 2025 for testing. This is a **retrospective application-cohort evaluation**. The 12-month label windows overlap later application periods, so this partition is not a faithful historical deployment backtest. For a strict deployment-time evaluation, restrict training to loans whose observation windows closed before the scoring date. All historical outcomes are available before the August 2026 new scoring batch.

Use `new_applicants_to_score.csv` for inference after model evaluation. There are no hidden true outcomes supplied for these 6,000 pending applicants. Predicted probabilities are estimates in the simulated world, not facts or automatic approvals.

## Raw-data practice copy

The raw applications CSV contains the same underlying records plus deliberately introduced issues:

- 150 duplicate application rows.
- 180 original rows with padded uppercase employment categories.
- 120 original rows with whitespace-only purposes.
- 90 original rows with missing employment tenure.
- 40 original rows with a negative income value.

Issue selections can overlap; duplicates can repeat affected rows. Counts above refer to original-row edits before duplicates. Trim and standardise categories; detect and investigate invalid amounts; distinguish blanks from NULL; deduplicate only after comparing full records. Do not silently use absolute values for negative incomes or invent missing purposes. Quarantine ambiguous records or document imputation. Clean reference CSVs are available for checking your work, not as an excuse to hide cleaning decisions.

Natural missingness is separate: no bureau score for no-history applicants; no utilisation ratio without active cards; no closure date on active accounts; no outcome for unfunded applications.

## Questions for the project

1. What share of historical applications was approved, and how did that change by month and channel?
2. How do requested amounts compare with income and existing monthly obligations?
3. Which bureau-history bands have higher observed 12-month default rates among funded loans?
4. How do thin-file applicants differ from established-credit applicants?
5. Where do arrears accumulate, and how often do delinquent loans later cure?
6. How much lower are disbursed amounts than requests?
7. How does default frequency vary across application cohorts? Include counts to avoid small-group overinterpretation.
8. How does performance change between training, validation and test cohorts?
9. Which threshold offers an acceptable balance of missed defaults and false alerts under explicitly invented business costs?
10. How does the August 2026 applicant mix compare with the historical modelling population?

## Limitations to state in interviews

The lender, decisions and outcomes are fictional. There are no actual identities or third-party data. Geographic names provide an Indian scenario, not evidence about those regions. Relationships are intentionally noisy but generated from a fixed simulator. The model may learn that simulator rather than transferable credit behaviour. Underwriting selection means the funded population differs from rejected applicants. Actual deployment would require real consented data, population validation, fairness review and lender governance.

Use the reproducible generator to explain assumptions openly. Do not present simulated savings, approval gains or model performance as actual business results.
