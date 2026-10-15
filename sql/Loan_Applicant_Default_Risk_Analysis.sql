/*
Loan Applicant Default Risk Analysis & Prediction
Author: Dipendu Roy
SQL Server | Synthetic portfolio dataset | Organised execution and explanations

HOW TO USE
Run the numbered sections in order in SSMS, inspecting validation results before
continuing. This is a first-build script, not an idempotent migration: CREATE TABLE,
SELECT INTO, imports and ADD CONSTRAINT run once. Do not rerun the entire script
against your already populated project database. Read-only analysis can be rerun.
No DROP or TRUNCATE operations are included. Adjust all eight local CSV paths if
moving the project; SQL Server must be able to read those files.
GO separates batches so CREATE OR ALTER VIEW is the first statement in its batch.

EXPECTED DATA
Applications: 30,150 raw -> 30,000 distinct. Cities: 12. Bureau: 30,000.
Prior accounts: 70,290. Decisions: 30,000. Originations: 19,393.
Monthly repayments: 232,716. Outcomes: 30,000 (10,607 unissued, no target).
Default target: any DPD >= 90 within the first 12 monthly snapshots.
Months_With_Arrears_12M follows the generator definition: count Days_Past_Due > 0.
40 invalid negative incomes become NULL; do not infer their positive values.
Applications dates use style 105 (DD-MM-YYYY) in the supplied working import;
other CSV dates use style 23 (YYYY-MM-DD). Inspect actual CSV text before changing.
BULK settings match the successful local import and are not a general CSV parser.

MODEL HANDOFF
19,393 labelled loans: Training pool 7,700 / Test 3,987 / Excluded 7,706.
Training outcomes end before 2025-01-01; test applications are Jan-Jun 2025.
The feature view uses application-time data; outcome and split fields are metadata.
6,000 pending applicants have no observed default target. Rejected is not target 0.
Exploratory SQL inspected all historical outcomes before the split was defined;
the later test is a model-fitting holdout, not a completely unseen research holdout.
Synthetic associations and scores are not validated real lending rules.

EDIT NOTES
Removed repeated previews/context switches and the obsolete duplicate PK attempt.
Moved Month_Number NOT NULL before the composite primary key.
Corrected arrears reconciliation to DPD > 0; removed its redundant follow-up.
Added explanations and batch boundaries; preserved business analysis and thresholds.
Static review only: this edited script was not executed against your SQL Server.
*/


-- ============================================================================
-- 01 | Database context
-- ============================================================================

/* Step 001
Create the project database only if absent. Existing database contents are retained.
*/
IF DB_ID(N'LoanApplicantRiskDB') IS NULL
    CREATE DATABASE LoanApplicantRiskDB;
GO

/* Step 002
Select LoanApplicantRiskDB as the context for all following batches.
*/
USE LoanApplicantRiskDB;
GO

-- ============================================================================
-- 02 | Applications: import, cleaning and typed table
-- ============================================================================

/* Step 003
Create dbo.stg_applications_raw. Staging text columns preserve source values for validation
before conversion.
*/
CREATE TABLE dbo.stg_applications_raw (
    Application_ID                  VARCHAR(120) NULL,
    Applicant_ID                    VARCHAR(120) NULL,
    Application_Date                VARCHAR(120) NULL,
    Cohort                          VARCHAR(120) NULL,
    City_ID                         VARCHAR(120) NULL,
    Age                             VARCHAR(120) NULL,
    Employment_Type                 VARCHAR(120) NULL,
    Employment_Sector               VARCHAR(120) NULL,
    Employment_Tenure_Years          VARCHAR(120) NULL,
    Housing_Status                  VARCHAR(120) NULL,
    Dependents                      VARCHAR(120) NULL,
    Monthly_Income_INR              VARCHAR(120) NULL,
    Monthly_Living_Expenses_INR     VARCHAR(120) NULL,
    Loan_Purpose                    VARCHAR(120) NULL,
    Requested_Amount_INR            VARCHAR(120) NULL,
    Requested_Term_Months           VARCHAR(120) NULL,
    Application_Channel            VARCHAR(120) NULL
);
GO

/* Step 004
Import the CSV into dbo.stg_applications_raw once. Skip its header; use comma fields, LF rows
and UTF-8; preserve empty fields as NULL. Check the next row count before continuing.
*/
BULK INSERT dbo.stg_applications_raw
FROM 'C:\Users\royzh\Desktop\Loan Applicant Default Risk Analysis & Prediction\Loan_Applicant_Default_Risk\data\raw_practice\applications_raw.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    CODEPAGE = '65001',
    KEEPNULLS
);
GO

/* Step 005
Count imported raw applications. Expected 30,150 rows before deduplication.
*/
SELECT COUNT(*) AS Imported_Rows
FROM dbo.stg_applications_raw;
GO

/* Step 006
Inspect records from dbo.stg_applications_raw. Read-only result; compare with the documented
expected counts or inspect the displayed values.
*/
SELECT *
FROM dbo.stg_applications_raw;
GO

/* Step 007
Count total rows, distinct application IDs and excess rows. Expected 30,150 total, 30,000 unique
and 150 excess copies.
*/
select count(*) as total_rows , count(distinct Application_id) as unique_applications , 
(count(*)-count(distinct Application_id)) as extra_rows 
from dbo.stg_applications_raw;
GO

/* Step 008
Display the records with repeated IDs. Rows returned identify duplicates or reconciliation
exceptions; investigate before proceeding.
*/
SELECT
    Application_ID,
    COUNT(*) AS Occurrences
FROM dbo.stg_applications_raw
GROUP BY Application_ID
HAVING COUNT(*) > 1;
GO

/* Step 009
Create and populate dbo.applications_working. DISTINCT removes complete duplicate rows; repeated
IDs with conflicting attributes would require investigation.
*/
SELECT DISTINCT *
INTO dbo.applications_working
FROM dbo.stg_applications_raw;
GO

/* Step 010
Inspect records from dbo.applications_working. Read-only result; compare with the documented
expected counts or inspect the displayed values.
*/
select *
from dbo.applications_working;
GO

/* Step 011
Profile all 17 application columns for SQL NULL and whitespace-only values separately. Expect 90
missing tenures and 120 blank loan purposes before cleaning.
*/
SELECT
    c.Column_Name,
    SUM(CASE
        WHEN c.Column_Value IS NULL THEN 1
        ELSE 0
    END) AS Null_Count,
    SUM(CASE
        WHEN c.Column_Value IS NOT NULL
         AND LTRIM(RTRIM(c.Column_Value)) = '' THEN 1
        ELSE 0
    END) AS Blank_Count
FROM dbo.applications_working AS a
CROSS APPLY (
    VALUES
        (1,  'Application_ID',              a.Application_ID),
        (2,  'Applicant_ID',                a.Applicant_ID),
        (3,  'Application_Date',            a.Application_Date),
        (4,  'Cohort',                      a.Cohort),
        (5,  'City_ID',                     a.City_ID),
        (6,  'Age',                         a.Age),
        (7,  'Employment_Type',             a.Employment_Type),
        (8,  'Employment_Sector',           a.Employment_Sector),
        (9,  'Employment_Tenure_Years',      a.Employment_Tenure_Years),
        (10, 'Housing_Status',              a.Housing_Status),
        (11, 'Dependents',                  a.Dependents),
        (12, 'Monthly_Income_INR',          a.Monthly_Income_INR),
        (13, 'Monthly_Living_Expenses_INR', a.Monthly_Living_Expenses_INR),
        (14, 'Loan_Purpose',                a.Loan_Purpose),
        (15, 'Requested_Amount_INR',        a.Requested_Amount_INR),
        (16, 'Requested_Term_Months',       a.Requested_Term_Months),
        (17, 'Application_Channel',        a.Application_Channel)
) AS c(Column_Order, Column_Name, Column_Value)
GROUP BY
    c.Column_Order,
    c.Column_Name
ORDER BY
    c.Column_Order;
GO

/* Step 012
Convert 120 blank/whitespace-only loan purposes to NULL so missing information has one
representation.
*/
UPDATE dbo.applications_working
SET Loan_Purpose = NULL
WHERE Loan_Purpose IS NOT NULL
  AND LTRIM(RTRIM(Loan_Purpose)) = '';
GO

/* Step 013
Verify blank loan purposes became NULL. Expected Null_Loan_Purpose = 120; this is an aggregate
count, not an exception-row query.
*/
SELECT COUNT(*) AS Null_Loan_Purpose
FROM dbo.applications_working
WHERE Loan_Purpose IS NULL;
GO

/* Step 014
Inspect the employment type for inconsistent spelling, casing, or spaces. Compare group counts
and inspect missing categories or unexpected values; this query does not update data.
*/
SELECT
    '[' + Employment_Type + ']' AS Employment_Type_Visible,
    DATALENGTH(Employment_Type) AS Text_Bytes,
    COUNT(*) AS Row_Count
FROM dbo.applications_working
GROUP BY
    Employment_Type,
    DATALENGTH(Employment_Type)
ORDER BY
    Employment_Type,
    Text_Bytes;
GO

/* Step 015
Standardise padded employment categories into Contract, Salaried and Self-employed; then inspect
category totals.
*/
UPDATE dbo.applications_working
SET Employment_Type =
    CASE UPPER(LTRIM(RTRIM(Employment_Type)))
        WHEN 'CONTRACT' THEN 'Contract'
        WHEN 'SALARIED' THEN 'Salaried'
        WHEN 'SELF-EMPLOYED' THEN 'Self-employed'
        ELSE Employment_Type
    END
WHERE DATALENGTH(Employment_Type)
   <> DATALENGTH(LTRIM(RTRIM(Employment_Type)));
GO

/* Step 016
Verify standardised employment categories: Salaried 19,227; Self-employed 7,133; Contract 3,640.
*/
SELECT
    Employment_Type,
    COUNT(*) AS Row_Count
FROM dbo.applications_working
GROUP BY Employment_Type;
GO

/* Step 017
Checking monthly income for invalid numbers, zero, or negative values. Inspect returned rows
against the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Monthly_Income_INR
FROM dbo.applications_working
WHERE TRY_CONVERT(DECIMAL(18, 2), Monthly_Income_INR) IS NULL
   OR TRY_CONVERT(DECIMAL(18, 2), Monthly_Income_INR) <= 0;
GO

/* Step 018
Replace the 40 invalid negative incomes with NULL. A positive amount cannot be recovered without
source evidence.
*/
UPDATE dbo.applications_working
SET Monthly_Income_INR = NULL
WHERE TRY_CONVERT(DECIMAL(18, 2), Monthly_Income_INR) < 0;
GO

/* Step 019
Check monthly living expenses for missing values, invalid numbers, or negative amounts. Inspect
returned rows against the stated rule; an empty exception result indicates no violations of this
check.
*/
SELECT
    Application_ID,
    Monthly_Living_Expenses_INR
FROM dbo.applications_working
WHERE TRY_CONVERT(DECIMAL(18, 2), Monthly_Living_Expenses_INR) IS NULL
   OR TRY_CONVERT(DECIMAL(18, 2), Monthly_Living_Expenses_INR) < 0;
GO

/* Step 020
Checking requested loan amounts. Inspect returned rows against the stated rule; an empty
exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Requested_Amount_INR
FROM dbo.applications_working
WHERE TRY_CONVERT(DECIMAL(18, 2), Requested_Amount_INR) IS NULL
   OR TRY_CONVERT(DECIMAL(18, 2), Requested_Amount_INR) <= 0;
GO

/* Step 021
Check requested loan terms for missing values, invalid integers, or values less than one month.
Inspect returned rows against the stated rule; an empty exception result indicates no violations
of this check.
*/
SELECT
    Application_ID,
    Requested_Term_Months
FROM dbo.applications_working
WHERE TRY_CONVERT(INT, Requested_Term_Months) IS NULL
   OR TRY_CONVERT(INT, Requested_Term_Months) <= 0;
GO

/* Step 022
Inspect the actual terms and their counts. Compare group counts and inspect missing categories
or unexpected values; this query does not update data.
*/
SELECT
    TRY_CONVERT(INT, Requested_Term_Months) AS Term_Months,
    COUNT(*) AS Application_Count
FROM dbo.applications_working
GROUP BY TRY_CONVERT(INT, Requested_Term_Months)
ORDER BY Term_Months;
GO

/* Step 023
Check age for missing values, invalid integers, or values outside our project’s review range of
(18–70) years. Inspect returned rows against the stated rule; an empty exception result
indicates no violations of this check.
*/
SELECT
    Application_ID,
    Age
FROM dbo.applications_working
WHERE TRY_CONVERT(INT, Age) IS NULL
   OR TRY_CONVERT(INT, Age) NOT BETWEEN 18 AND 70;
GO

/* Step 024
Check employment tenure for invalid numbers or negative values. We’ll exclude the 90 known
NULLs, since those represent missing information. Inspect returned rows against the stated rule;
an empty exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Employment_Tenure_Years
FROM dbo.applications_working
WHERE Employment_Tenure_Years IS NOT NULL
  AND (
      TRY_CONVERT(DECIMAL(10, 2), Employment_Tenure_Years) IS NULL
      OR TRY_CONVERT(DECIMAL(10, 2), Employment_Tenure_Years) < 0
  );
GO

/* Step 025
Checking Dependents. It should be a whole number of zero or more. Inspect returned rows against
the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Dependents
FROM dbo.applications_working
WHERE TRY_CONVERT(INT, Dependents) IS NULL
   OR TRY_CONVERT(INT, Dependents) < 0;
GO

/* Step 026
Checking application dates. Inspect returned rows against the stated rule; an empty exception
result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Application_Date
FROM dbo.applications_working
WHERE TRY_CONVERT(DATE, Application_Date, 105) IS NULL;
GO

/* Step 027
Next, checking the date range for each cohort. Compare group counts and inspect missing
categories or unexpected values; this query does not update data.
*/
SELECT
    Cohort,
    COUNT(*) AS Application_Count,
    MIN(TRY_CONVERT(DATE, Application_Date, 105)) AS Earliest_Date,
    MAX(TRY_CONVERT(DATE, Application_Date, 105)) AS Latest_Date
FROM dbo.applications_working
GROUP BY Cohort;
GO

/* Step 028
Inspecting housing categories for unexpected values or extra spaces. Compare group counts and
inspect missing categories or unexpected values; this query does not update data.
*/
SELECT
    '[' + Housing_Status + ']' AS Housing_Status_Visible,
    DATALENGTH(Housing_Status) AS Text_Bytes,
    COUNT(*) AS Application_Count
FROM dbo.applications_working
GROUP BY Housing_Status, DATALENGTH(Housing_Status)
ORDER BY Housing_Status, Text_Bytes;
GO

/* Step 029
Checking Application_Channel. Compare group counts and inspect missing categories or unexpected
values; this query does not update data.
*/
SELECT
    '[' + Application_Channel + ']' AS Channel_Visible,
    DATALENGTH(Application_Channel) AS Text_Bytes,
    COUNT(*) AS Application_Count
FROM dbo.applications_working
GROUP BY Application_Channel, DATALENGTH(Application_Channel)
ORDER BY Application_Channel, Text_Bytes;
GO

/* Step 030
The comma is visible, but the last character could be a space or a carriage return from the CSV
import. Let’s identify it before cleaning. Read-only result; compare with the documented
expected counts or inspect the displayed values.
*/
SELECT DISTINCT
    '[' + Application_Channel + ']' AS Channel_Visible,
    ASCII(RIGHT(Application_Channel, 1)) AS Last_Character_Code,
    ASCII(
        SUBSTRING(
            Application_Channel,
            DATALENGTH(Application_Channel) - 1,
            1
        )
    ) AS Second_Last_Character_Code
FROM dbo.applications_working;
GO

/* Step 031
Remove only the observed trailing comma plus CHAR(13) from channels; preserve the actual channel
text.
*/
UPDATE dbo.applications_working
SET Application_Channel =
    LEFT(Application_Channel, DATALENGTH(Application_Channel) - 2)
WHERE RIGHT(Application_Channel, 2) = ',' + CHAR(13);
GO

/* Step 032
Verify cleaned channel names and lengths: Branch, Mobile App, Partner and Web, with no comma or
carriage-return suffix.
*/
SELECT
    '[' + Application_Channel + ']' AS Channel_Visible,
    DATALENGTH(Application_Channel) AS Text_Bytes,
    COUNT(*) AS Application_Count
FROM dbo.applications_working
GROUP BY Application_Channel, DATALENGTH(Application_Channel)
ORDER BY Application_Channel;
GO

/* Step 033
Inspecting Employment_Sector for unexpected categories or extra spaces. Compare group counts and
inspect missing categories or unexpected values; this query does not update data.
*/
SELECT
    '[' + Employment_Sector + ']' AS Sector_Visible,
    DATALENGTH(Employment_Sector) AS Text_Bytes,
    COUNT(*) AS Application_Count
FROM dbo.applications_working
GROUP BY Employment_Sector, DATALENGTH(Employment_Sector)
ORDER BY Employment_Sector, Text_Bytes;
GO

/* Step 034
Inspect the remaining Loan_Purpose categories, keeping the known missing values. Compare group
counts and inspect missing categories or unexpected values; this query does not update data.
*/
SELECT
    CASE
        WHEN Loan_Purpose IS NULL THEN '[NULL]'
        ELSE '[' + Loan_Purpose + ']'
    END AS Purpose_Visible,
    DATALENGTH(Loan_Purpose) AS Text_Bytes,
    COUNT(*) AS Application_Count
FROM dbo.applications_working
GROUP BY Loan_Purpose, DATALENGTH(Loan_Purpose)
ORDER BY Loan_Purpose, Text_Bytes;
GO

/* Step 035
Checking whether employment tenure is consistent with age. Inspect returned rows against the
stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Age,
    Employment_Tenure_Years
FROM dbo.applications_working
WHERE TRY_CONVERT(DECIMAL(10, 2), Employment_Tenure_Years) > TRY_CONVERT(INT, Age) - 18;
GO

/* Step 036
Inspecting City_ID. Compare group counts and inspect missing categories or unexpected values;
this query does not update data.
*/
SELECT
    '[' + City_ID + ']' AS City_ID_Visible,
    DATALENGTH(City_ID) AS Text_Bytes,
    COUNT(*) AS Application_Count
FROM dbo.applications_working
GROUP BY City_ID, DATALENGTH(City_ID)
ORDER BY City_ID, Text_Bytes;
GO

/* Step 037
Confirm 30,000 working rows and 30,000 unique IDs before typed-table creation. Expected missing
counts: tenure 90, purpose 120, income 40.
*/
SELECT
    COUNT(*) AS Total_Rows,
    COUNT(DISTINCT Application_ID) AS Unique_Applications,
    SUM(CASE WHEN Employment_Tenure_Years IS NULL
             THEN 1 ELSE 0 END) AS Missing_Tenure,
    SUM(CASE WHEN Loan_Purpose IS NULL
             THEN 1 ELSE 0 END) AS Missing_Loan_Purpose,
    SUM(CASE WHEN Monthly_Income_INR IS NULL
             THEN 1 ELSE 0 END) AS Missing_Income
FROM dbo.applications_working;
GO

/* Step 038
Create and populate dbo.applications_clean. Convert validated source fields to dates/numbers
while preserving intended missing values. CONVERT raises an error on unexpected invalid input.
*/
SELECT
    Application_ID,
    Applicant_ID,
    CONVERT(DATE, Application_Date, 105) AS Application_Date,
    Cohort,
    City_ID,
    CONVERT(INT, Age) AS Age,
    Employment_Type,
    Employment_Sector,
    CONVERT(DECIMAL(10, 2), Employment_Tenure_Years)
        AS Employment_Tenure_Years,
    Housing_Status,
    CONVERT(INT, Dependents) AS Dependents,
    CONVERT(DECIMAL(18, 2), Monthly_Income_INR)
        AS Monthly_Income_INR,
    CONVERT(DECIMAL(18, 2), Monthly_Living_Expenses_INR)
        AS Monthly_Living_Expenses_INR,
    Loan_Purpose,
    CONVERT(DECIMAL(18, 2), Requested_Amount_INR)
        AS Requested_Amount_INR,
    CONVERT(INT, Requested_Term_Months)
        AS Requested_Term_Months,
    Application_Channel
INTO dbo.applications_clean
FROM dbo.applications_working;
GO

/* Step 039
Inspect the clean applications schema in INFORMATION_SCHEMA.COLUMNS. Dates should be DATE, whole
numbers INT, amounts DECIMAL(18,2), tenure DECIMAL(10,2), and retained text VARCHAR.
*/
SELECT
    COLUMN_NAME,
    DATA_TYPE,
    CHARACTER_MAXIMUM_LENGTH,
    NUMERIC_PRECISION,
    NUMERIC_SCALE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo'
  AND TABLE_NAME = 'applications_clean'
ORDER BY ORDINAL_POSITION;
GO

/* Step 040
Make the specified column in dbo.applications_clean NOT NULL before defining keys. Existing
NULLs must be resolved first.
*/
ALTER TABLE dbo.applications_clean
ALTER COLUMN Application_ID VARCHAR(120) NOT NULL;
GO

/* Step 041
Add the primary key to dbo.applications_clean. The listed column(s) uniquely identify each row
and must be non-null.
*/
ALTER TABLE dbo.applications_clean
ADD CONSTRAINT PK_applications_clean
    PRIMARY KEY (Application_ID);
GO

-- ============================================================================
-- 03 | City dimension and application relationship
-- ============================================================================

/* Step 042
Create dbo.stg_city. Staging text columns preserve source values for validation before
conversion.
*/
IF OBJECT_ID('dbo.stg_city', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.stg_city (
        City_ID   VARCHAR(120) NULL,
        City      VARCHAR(120) NULL,
        State     VARCHAR(120) NULL,
        City_Tier VARCHAR(120) NULL
    );
END;
GO

/* Step 043
Import the 12-city CSV into staging once. FIRSTROW=2 skips headers; comma/LF specify delimiters;
CODEPAGE=65001 reads UTF-8 and KEEPNULLS retains missing fields. Inspect all 12 rows next.
*/
BULK INSERT dbo.stg_city
FROM 'C:\Users\royzh\Desktop\Loan Applicant Default Risk Analysis & Prediction\Loan_Applicant_Default_Risk\data\clean\dim_city.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    CODEPAGE = '65001',
    KEEPNULLS
);
GO

/* Step 044
Inspect records from dbo.stg_city. Read-only result; compare with the documented expected counts
or inspect the displayed values.
*/
SELECT *
FROM dbo.stg_city;
GO

/* Step 045
Checking City_Tier, the last CSV column, for hidden trailing characters. Compare group counts
and inspect missing categories or unexpected values; this query does not update data.
*/
SELECT
    '[' + City_Tier + ']' AS Tier_Visible,
    DATALENGTH(City_Tier) AS Text_Bytes,
    ASCII(RIGHT(City_Tier, 1)) AS Last_Character_Code,
    COUNT(*) AS City_Count
FROM dbo.stg_city
GROUP BY City_Tier, DATALENGTH(City_Tier),
         ASCII(RIGHT(City_Tier, 1));
GO

/* Step 046
Find missing or whitespace-only values in the four city columns. Expected zero exception rows.
Duplicate city IDs are checked separately next.
*/
SELECT *
FROM dbo.stg_city
WHERE NULLIF(LTRIM(RTRIM(City_ID)), '') IS NULL
   OR NULLIF(LTRIM(RTRIM(City)), '') IS NULL
   OR NULLIF(LTRIM(RTRIM(State)), '') IS NULL
   OR NULLIF(LTRIM(RTRIM(City_Tier)), '') IS NULL;
GO

/* Step 047
Duplicate city IDs. Rows returned identify duplicates or reconciliation exceptions; investigate
before proceeding.
*/
SELECT City_ID, COUNT(*) AS Row_Count
FROM dbo.stg_city
GROUP BY City_ID
HAVING COUNT(*) > 1;
GO

/* Step 048
Create dbo.dim_city with required fields and its primary key.
*/
CREATE TABLE dbo.dim_city (
    City_ID   VARCHAR(120) NOT NULL,
    City      VARCHAR(120) NOT NULL,
    State     VARCHAR(120) NOT NULL,
    City_Tier VARCHAR(120) NOT NULL,
    CONSTRAINT PK_dim_city PRIMARY KEY (City_ID)
);
GO

/* Step 049
Insert the 12 validated staging rows into the existing dim_city table. This does not create a
table or change data types; run once to avoid duplicate primary keys.
*/
INSERT INTO dbo.dim_city (City_ID, City, State, City_Tier)
SELECT City_ID, City, State, City_Tier
FROM dbo.stg_city;
GO

/* Step 050
Checking whether every application’s city exists in this table. Inspect returned rows against
the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT DISTINCT a.City_ID
FROM dbo.applications_clean AS a
LEFT JOIN dbo.dim_city AS c
    ON a.City_ID = c.City_ID
WHERE c.City_ID IS NULL;
GO

/* Step 051
Enforce the shown parent-child relationship between dbo.applications_clean, dbo.dim_city. Orphan
references will be rejected; this does not enforce unlisted cross-column business rules.
*/
ALTER TABLE dbo.applications_clean
ADD CONSTRAINT FK_applications_clean_dim_city
    FOREIGN KEY (City_ID)
    REFERENCES dbo.dim_city (City_ID);
GO

-- ============================================================================
-- 04 | Bureau summary
-- ============================================================================

/* Step 052
Create dbo.stg_bureau_summary. Staging text columns preserve source values for validation before
conversion.
*/
CREATE TABLE dbo.stg_bureau_summary (
    Application_ID                  VARCHAR(120) NULL,
    Snapshot_Date                   VARCHAR(120) NULL,
    Prior_Account_Count             VARCHAR(120) NULL,
    Active_Account_Count            VARCHAR(120) NULL,
    Credit_History_Months           VARCHAR(120) NULL,
    Synthetic_Credit_Score          VARCHAR(120) NULL,
    Total_Outstanding_INR           VARCHAR(120) NULL,
    Existing_Monthly_Obligation_INR  VARCHAR(120) NULL,
    Card_Utilisation_Ratio          VARCHAR(120) NULL,
    Total_Late_Payments_Last12M      VARCHAR(120) NULL,
    Max_Prior_DPD_Last12M            VARCHAR(120) NULL,
    Enquiries_Last6M                VARCHAR(120) NULL
);
GO

/* Step 053
Import the CSV into dbo.stg_bureau_summary once. Skip its header; use comma fields, LF rows and
UTF-8; preserve empty fields as NULL. Check the next row count before continuing.
*/
BULK INSERT dbo.stg_bureau_summary
FROM 'C:\Users\royzh\Desktop\Loan Applicant Default Risk Analysis & Prediction\Loan_Applicant_Default_Risk\data\clean\bureau_summary.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    CODEPAGE = '65001',
    KEEPNULLS
);
GO

/* Step 054
Count imported bureau snapshots. Expected one row per application: 30,000.
*/
SELECT COUNT(*) AS Total_Rows
FROM dbo.stg_bureau_summary;
GO

/* Step 055
Inspect records from dbo.stg_bureau_summary. Read-only result; compare with the documented
expected counts or inspect the displayed values.
*/
SELECT TOP (5) *
FROM dbo.stg_bureau_summary
ORDER BY Application_ID;
GO

/* Step 056
Confirming the row count and application IDs. Read-only result; compare with the documented
expected counts or inspect the displayed values.
*/
SELECT
    COUNT(*) AS Total_Rows,
    COUNT(DISTINCT Application_ID) AS Unique_Applications,
    SUM(
        CASE
            WHEN NULLIF(LTRIM(RTRIM(Application_ID)), '') IS NULL
            THEN 1 ELSE 0
        END
    ) AS Missing_Application_ID
FROM dbo.stg_bureau_summary;
GO

/* Step 057
Verify that every bureau record matches an application. Inspect returned rows against the stated
rule; an empty exception result indicates no violations of this check.
*/
SELECT b.Application_ID
FROM dbo.stg_bureau_summary AS b
LEFT JOIN dbo.applications_clean AS a
    ON b.Application_ID = a.Application_ID
WHERE a.Application_ID IS NULL;
GO

/* Step 058
Checking for missing, blank, or invalid snapshot dates. Inspect returned rows against the stated
rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Snapshot_Date
FROM dbo.stg_bureau_summary
WHERE TRY_CONVERT(
          DATE,
          NULLIF(LTRIM(RTRIM(Snapshot_Date)), ''),
          23
      ) IS NULL;
GO

/* Step 059
Checking whether any credit summary was captured after its application date. Inspect returned
rows against the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    b.Application_ID,
    b.Snapshot_Date,
    a.Application_Date
FROM dbo.stg_bureau_summary AS b
INNER JOIN dbo.applications_clean AS a
    ON b.Application_ID = a.Application_ID
WHERE TRY_CONVERT(DATE, b.Snapshot_Date, 23)
    > a.Application_Date;
GO

/* Step 060
Check prior and active account counts for missing values, invalid integers, negative values, or
active accounts exceeding total prior accounts. Inspect returned rows against the stated rule;
an empty exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Prior_Account_Count,
    Active_Account_Count
FROM dbo.stg_bureau_summary
WHERE TRY_CONVERT(INT,
          NULLIF(LTRIM(RTRIM(Prior_Account_Count)), '')) IS NULL
   OR TRY_CONVERT(INT,
          NULLIF(LTRIM(RTRIM(Active_Account_Count)), '')) IS NULL
   OR TRY_CONVERT(INT, Prior_Account_Count) < 0
   OR TRY_CONVERT(INT, Active_Account_Count) < 0
   OR TRY_CONVERT(INT, Active_Account_Count) > TRY_CONVERT(INT, Prior_Account_Count);
GO

/* Step 061
Checking Credit_History_Months for missing, blank, invalid, or negative values. Inspect returned
rows against the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Credit_History_Months
FROM dbo.stg_bureau_summary
WHERE TRY_CONVERT(
          INT,
          NULLIF(LTRIM(RTRIM(Credit_History_Months)), '')
      ) IS NULL
   OR TRY_CONVERT(INT, Credit_History_Months) < 0;
GO

/* Step 062
Inspect minimum/maximum numeric scores and distinguish missing from nonnumeric values. Recorded
range 471-891, missing scores 4,235, invalid nonblank scores zero. These are synthetic scores.
*/
SELECT
    MIN(TRY_CONVERT(INT, Synthetic_Credit_Score)) AS Minimum_Score,
    MAX(TRY_CONVERT(INT, Synthetic_Credit_Score)) AS Maximum_Score,
    SUM(
        CASE
            WHEN NULLIF(LTRIM(RTRIM(Synthetic_Credit_Score)), '') IS NULL
            THEN 1 ELSE 0
        END
    ) AS Missing_Scores,
    SUM(
        CASE
            WHEN NULLIF(LTRIM(RTRIM(Synthetic_Credit_Score)), '') IS NOT NULL
             AND TRY_CONVERT(INT, Synthetic_Credit_Score) IS NULL
            THEN 1 ELSE 0
        END
    ) AS Invalid_Scores
FROM dbo.stg_bureau_summary;
GO

/* Step 063
Group missing-score applicants by prior account count. Expected 4,235 applicants with
Prior_Accounts = 0; this is a diagnostic distribution, not an exception query.
*/
SELECT
    TRY_CONVERT(INT, Prior_Account_Count) AS Prior_Accounts,
    COUNT(*) AS Missing_Score_Count
FROM dbo.stg_bureau_summary
WHERE NULLIF(LTRIM(RTRIM(Synthetic_Credit_Score)), '') IS NULL
GROUP BY TRY_CONVERT(INT, Prior_Account_Count)
ORDER BY Prior_Accounts;
GO

/* Step 064
Checking total outstanding debt for missing, invalid, or negative amounts. Inspect returned rows
against the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Total_Outstanding_INR
FROM dbo.stg_bureau_summary
WHERE TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Total_Outstanding_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(DECIMAL(18, 2), Total_Outstanding_INR) < 0;
GO

/* Step 065
Checking existing monthly obligations. Inspect returned rows against the stated rule; an empty
exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Existing_Monthly_Obligation_INR
FROM dbo.stg_bureau_summary
WHERE TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Existing_Monthly_Obligation_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(
          DECIMAL(18, 2),
          Existing_Monthly_Obligation_INR) < 0;
GO

/* Step 066
Inspect utilisation range and missing/nonnumeric values. Recorded range 0.0000-0.9900; missing
13,704; invalid nonblank values zero. Later account-level checks explain the missingness.
*/
SELECT
    MIN(TRY_CONVERT(DECIMAL(10, 4), Card_Utilisation_Ratio))
        AS Minimum_Utilisation,
    MAX(TRY_CONVERT(DECIMAL(10, 4), Card_Utilisation_Ratio))
        AS Maximum_Utilisation,
    SUM(CASE
        WHEN NULLIF(LTRIM(RTRIM(Card_Utilisation_Ratio)), '') IS NULL
        THEN 1 ELSE 0
    END) AS Missing_Utilisation,
    SUM(CASE
        WHEN NULLIF(LTRIM(RTRIM(Card_Utilisation_Ratio)), '') IS NOT NULL
         AND TRY_CONVERT(DECIMAL(10, 4), Card_Utilisation_Ratio) IS NULL
        THEN 1 ELSE 0
    END) AS Invalid_Utilisation
FROM dbo.stg_bureau_summary;
GO

/* Step 067
Validate late-payment counts. Inspect returned rows against the stated rule; an empty exception
result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Total_Late_Payments_Last12M
FROM dbo.stg_bureau_summary
WHERE TRY_CONVERT(
          INT,
          NULLIF(LTRIM(RTRIM(Total_Late_Payments_Last12M)), '')
      ) IS NULL
   OR TRY_CONVERT(INT, Total_Late_Payments_Last12M) < 0;
GO

/* Step 068
Checking Max_Prior_DPD_Last12M (DPD = days past due). Inspect returned rows against the stated
rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Max_Prior_DPD_Last12M
FROM dbo.stg_bureau_summary
WHERE TRY_CONVERT(
          INT,
          NULLIF(LTRIM(RTRIM(Max_Prior_DPD_Last12M)), '')
      ) IS NULL
   OR TRY_CONVERT(INT, Max_Prior_DPD_Last12M) < 0;
GO

/* Step 069
Checking Enquiries_Last6M. Inspect returned rows against the stated rule; an empty exception
result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Enquiries_Last6M
FROM dbo.stg_bureau_summary
WHERE TRY_CONVERT(
          INT,
          NULLIF(LTRIM(RTRIM(Enquiries_Last6M)), '')
      ) IS NULL
   OR TRY_CONVERT(INT, Enquiries_Last6M) < 0;
GO

/* Step 070
Create and populate dbo.bureau_summary_clean. Convert validated source fields to dates/numbers
while preserving intended missing values. CONVERT raises an error on unexpected invalid input.
*/
SELECT
    Application_ID,
    CONVERT(DATE, Snapshot_Date, 23) AS Snapshot_Date,
    CONVERT(INT, Prior_Account_Count) AS Prior_Account_Count,
    CONVERT(INT, Active_Account_Count) AS Active_Account_Count,
    CONVERT(INT, Credit_History_Months) AS Credit_History_Months,
    CONVERT(
        INT,
        NULLIF(LTRIM(RTRIM(Synthetic_Credit_Score)), '')
    ) AS Synthetic_Credit_Score,
    CONVERT(DECIMAL(18, 2), Total_Outstanding_INR)
        AS Total_Outstanding_INR,
    CONVERT(DECIMAL(18, 2), Existing_Monthly_Obligation_INR)
        AS Existing_Monthly_Obligation_INR,
    CONVERT(
        DECIMAL(10, 4),
        NULLIF(LTRIM(RTRIM(Card_Utilisation_Ratio)), '')
    ) AS Card_Utilisation_Ratio,
    CONVERT(INT, Total_Late_Payments_Last12M)
        AS Total_Late_Payments_Last12M,
    CONVERT(INT, Max_Prior_DPD_Last12M)
        AS Max_Prior_DPD_Last12M,
    CONVERT(INT, Enquiries_Last6M) AS Enquiries_Last6M
INTO dbo.bureau_summary_clean
FROM dbo.stg_bureau_summary;
GO

/* Step 071
Make the specified column in dbo.bureau_summary_clean NOT NULL before defining keys. Existing
NULLs must be resolved first.
*/
ALTER TABLE dbo.bureau_summary_clean
ALTER COLUMN Application_ID VARCHAR(120) NOT NULL;
GO

/* Step 072
Add the primary key to dbo.bureau_summary_clean. The listed column(s) uniquely identify each row
and must be non-null.
*/
ALTER TABLE dbo.bureau_summary_clean
ADD CONSTRAINT PK_bureau_summary_clean
    PRIMARY KEY (Application_ID);
GO

/* Step 073
Enforce the shown parent-child relationship between dbo.bureau_summary_clean,
dbo.applications_clean. Orphan references will be rejected; this does not enforce unlisted
cross-column business rules.
*/
ALTER TABLE dbo.bureau_summary_clean
ADD CONSTRAINT FK_bureau_summary_clean_applications
    FOREIGN KEY (Application_ID)
    REFERENCES dbo.applications_clean (Application_ID);
GO

/* Step 074
Verify the typed bureau table retained 30,000 rows, 4,235 missing scores and 13,704 missing
utilisation values.
*/
SELECT
    COUNT(*) AS Total_Rows,
    COUNT(*) - COUNT(Synthetic_Credit_Score) AS Missing_Scores,
    COUNT(*) - COUNT(Card_Utilisation_Ratio) AS Missing_Utilisation
FROM dbo.bureau_summary_clean;
GO

-- ============================================================================
-- 05 | Prior accounts and bureau reconciliation
-- ============================================================================

/* Step 075
Create dbo.stg_prior_credit_accounts. Staging text columns preserve source values for validation
before conversion.
*/
CREATE TABLE dbo.stg_prior_credit_accounts (
    Credit_Account_ID         VARCHAR(120) NULL,
    Application_ID            VARCHAR(120) NULL,
    Snapshot_Date             VARCHAR(120) NULL,
    Account_Type              VARCHAR(120) NULL,
    Opened_Date               VARCHAR(120) NULL,
    Account_Status            VARCHAR(120) NULL,
    Closed_Date               VARCHAR(120) NULL,
    Original_Amount_INR       VARCHAR(120) NULL,
    Credit_Limit_INR          VARCHAR(120) NULL,
    Outstanding_Balance_INR   VARCHAR(120) NULL,
    Monthly_Obligation_INR    VARCHAR(120) NULL,
    Late_Payments_Last12M     VARCHAR(120) NULL,
    Max_DPD_Last12M           VARCHAR(120) NULL
);
GO

/* Step 076
Import the CSV into dbo.stg_prior_credit_accounts once. Skip its header; use comma fields, LF
rows and UTF-8; preserve empty fields as NULL. Check the next row count before continuing.
*/
BULK INSERT dbo.stg_prior_credit_accounts
FROM 'C:\Users\royzh\Desktop\Loan Applicant Default Risk Analysis & Prediction\Loan_Applicant_Default_Risk\data\clean\prior_credit_accounts.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    CODEPAGE = '65001',
    KEEPNULLS
);
GO

/* Step 077
Count imported prior credit accounts. Expected 70,290 rows; one application can have several
accounts.
*/
SELECT COUNT(*) AS Total_Rows
FROM dbo.stg_prior_credit_accounts;
GO

/* Step 078
Inspect records from dbo.stg_prior_credit_accounts. Read-only result; compare with the
documented expected counts or inspect the displayed values.
*/
SELECT TOP (5) *
FROM dbo.stg_prior_credit_accounts
ORDER BY Credit_Account_ID;
GO

/* Step 079
Check the credit account IDs. Read-only result; compare with the documented expected counts or
inspect the displayed values.
*/
SELECT
    COUNT(*) AS Total_Rows,
    COUNT(DISTINCT Credit_Account_ID) AS Unique_Credit_Accounts,
    SUM(
        CASE
            WHEN NULLIF(LTRIM(RTRIM(Credit_Account_ID)), '') IS NULL
            THEN 1 ELSE 0
        END
    ) AS Missing_Account_ID
FROM dbo.stg_prior_credit_accounts;
GO

/* Step 080
Verify that every account links to an existing application. Inspect returned rows against the
stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    p.Credit_Account_ID,
    p.Application_ID
FROM dbo.stg_prior_credit_accounts AS p
LEFT JOIN dbo.applications_clean AS a
    ON p.Application_ID = a.Application_ID
WHERE a.Application_ID IS NULL;
GO

/* Step 081
Validate the snapshot and opened dates. Inspect returned rows against the stated rule; an empty
exception result indicates no violations of this check.
*/
SELECT
    Credit_Account_ID,
    Snapshot_Date,
    Opened_Date
FROM dbo.stg_prior_credit_accounts
WHERE TRY_CONVERT(
          DATE,
          NULLIF(LTRIM(RTRIM(Snapshot_Date)), ''),
          23
      ) IS NULL
   OR TRY_CONVERT(
          DATE,
          NULLIF(LTRIM(RTRIM(Opened_Date)), ''),
          23
      ) IS NULL;
GO

/* Step 082
Check that accounts were opened on or before their snapshot date, and snapshots were captured on
or before the application date. Inspect returned rows against the stated rule; an empty
exception result indicates no violations of this check.
*/
SELECT
    p.Credit_Account_ID,
    p.Opened_Date,
    p.Snapshot_Date,
    a.Application_Date
FROM dbo.stg_prior_credit_accounts AS p
INNER JOIN dbo.applications_clean AS a
    ON p.Application_ID = a.Application_ID
WHERE TRY_CONVERT(DATE, p.Opened_Date, 23)
    > TRY_CONVERT(DATE, p.Snapshot_Date, 23)
   OR TRY_CONVERT(DATE, p.Snapshot_Date, 23)
    > a.Application_Date;
GO

/* Step 083
Inspect account statuses before checking their closure dates. Compare group counts and inspect
missing categories or unexpected values; this query does not update data.
*/
SELECT
    '[' + Account_Status + ']' AS Status_Visible,
    DATALENGTH(Account_Status) AS Text_Bytes,
    COUNT(*) AS Account_Count
FROM dbo.stg_prior_credit_accounts
GROUP BY Account_Status, DATALENGTH(Account_Status)
ORDER BY Account_Status, Text_Bytes;
GO

/* Step 084
Check that active accounts have no closure date, and closed accounts have a valid closure date
between their opened and snapshot dates. Inspect returned rows against the stated rule; an empty
exception result indicates no violations of this check.
*/
SELECT
    Credit_Account_ID,
    Account_Status,
    Opened_Date,
    Closed_Date,
    Snapshot_Date
FROM dbo.stg_prior_credit_accounts
WHERE
    (
        Account_Status = 'Active'
        AND NULLIF(LTRIM(RTRIM(Closed_Date)), '') IS NOT NULL
    )
    OR
    (
        Account_Status = 'Closed'
        AND (
            TRY_CONVERT(
                DATE,
                NULLIF(LTRIM(RTRIM(Closed_Date)), ''),
                23
            ) IS NULL
            OR TRY_CONVERT(DATE, Closed_Date, 23)
               < TRY_CONVERT(DATE, Opened_Date, 23)
            OR TRY_CONVERT(DATE, Closed_Date, 23)
               > TRY_CONVERT(DATE, Snapshot_Date, 23)
        )
    );
GO

/* Step 085
Inspect account types. Compare group counts and inspect missing categories or unexpected values;
this query does not update data.
*/
SELECT
    '[' + Account_Type + ']' AS Account_Type_Visible,
    DATALENGTH(Account_Type) AS Text_Bytes,
    COUNT(*) AS Account_Count
FROM dbo.stg_prior_credit_accounts
GROUP BY Account_Type, DATALENGTH(Account_Type)
ORDER BY Account_Type, Text_Bytes;
GO

/* Step 086
Check Original_Amount_INR for missing, invalid, zero, or negative values. Inspect returned rows
against the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Credit_Account_ID,
    Account_Type,
    Original_Amount_INR
FROM dbo.stg_prior_credit_accounts
WHERE TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Original_Amount_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(DECIMAL(18, 2), Original_Amount_INR) <= 0;
GO

/* Step 087
Check Credit_Limit_INR for missing, invalid, or negative values. Inspect returned rows against
the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Credit_Account_ID,
    Account_Type,
    Credit_Limit_INR
FROM dbo.stg_prior_credit_accounts
WHERE TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Credit_Limit_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(DECIMAL(18, 2), Credit_Limit_INR) < 0;
GO

/* Step 088
Check that credit card accounts have a positive limit. Inspect returned rows against the stated
rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Credit_Account_ID,
    Account_Status,
    Credit_Limit_INR
FROM dbo.stg_prior_credit_accounts
WHERE Account_Type = 'Credit Card'
  AND TRY_CONVERT(DECIMAL(18, 2), Credit_Limit_INR) <= 0;
GO

/* Step 089
Check Outstanding_Balance_INR for missing, invalid, or negative values. Inspect returned rows
against the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Credit_Account_ID,
    Account_Type,
    Account_Status,
    Outstanding_Balance_INR
FROM dbo.stg_prior_credit_accounts
WHERE TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Outstanding_Balance_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(DECIMAL(18, 2), Outstanding_Balance_INR) < 0;
GO

/* Step 090
Check Monthly_Obligation_INR. Inspect returned rows against the stated rule; an empty exception
result indicates no violations of this check.
*/
SELECT
    Credit_Account_ID,
    Account_Type,
    Account_Status,
    Monthly_Obligation_INR
FROM dbo.stg_prior_credit_accounts
WHERE TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Monthly_Obligation_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(DECIMAL(18, 2), Monthly_Obligation_INR) < 0;
GO

/* Step 091
Check that closed accounts have zero outstanding balance and zero monthly obligation. Inspect
returned rows against the stated rule; an empty exception result indicates no violations of this
check.
*/
SELECT
    Credit_Account_ID,
    Outstanding_Balance_INR,
    Monthly_Obligation_INR
FROM dbo.stg_prior_credit_accounts
WHERE Account_Status = 'Closed'
  AND (
      TRY_CONVERT(DECIMAL(18, 2), Outstanding_Balance_INR) <> 0
      OR TRY_CONVERT(DECIMAL(18, 2), Monthly_Obligation_INR) <> 0
  );
GO

/* Step 092
Check Late_Payments_Last12M for missing, invalid, or negative counts. Inspect returned rows
against the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Credit_Account_ID,
    Late_Payments_Last12M
FROM dbo.stg_prior_credit_accounts
WHERE TRY_CONVERT(
          INT,
          NULLIF(LTRIM(RTRIM(Late_Payments_Last12M)), '')
      ) IS NULL
   OR TRY_CONVERT(INT, Late_Payments_Last12M) < 0;
GO

/* Step 093
Validate Max_DPD_Last12M. Inspect returned rows against the stated rule; an empty exception
result indicates no violations of this check.
*/
SELECT
    Credit_Account_ID,
    Max_DPD_Last12M
FROM dbo.stg_prior_credit_accounts
WHERE TRY_CONVERT(
          INT,
          NULLIF(LTRIM(RTRIM(Max_DPD_Last12M)), '')
      ) IS NULL
   OR TRY_CONVERT(INT, Max_DPD_Last12M) < 0;
GO

/* Step 094
Create and populate dbo.prior_credit_accounts_clean. Convert validated source fields to
dates/numbers while preserving intended missing values. CONVERT raises an error on unexpected
invalid input.
*/
SELECT
    Credit_Account_ID,
    Application_ID,
    CONVERT(DATE, Snapshot_Date, 23) AS Snapshot_Date,
    Account_Type,
    CONVERT(DATE, Opened_Date, 23) AS Opened_Date,
    Account_Status,
    CONVERT(
        DATE,
        NULLIF(LTRIM(RTRIM(Closed_Date)), ''),
        23
    ) AS Closed_Date,
    CONVERT(DECIMAL(18, 2), Original_Amount_INR)
        AS Original_Amount_INR,
    CONVERT(DECIMAL(18, 2), Credit_Limit_INR)
        AS Credit_Limit_INR,
    CONVERT(DECIMAL(18, 2), Outstanding_Balance_INR)
        AS Outstanding_Balance_INR,
    CONVERT(DECIMAL(18, 2), Monthly_Obligation_INR)
        AS Monthly_Obligation_INR,
    CONVERT(INT, Late_Payments_Last12M)
        AS Late_Payments_Last12M,
    CONVERT(INT, Max_DPD_Last12M)
        AS Max_DPD_Last12M
INTO dbo.prior_credit_accounts_clean
FROM dbo.stg_prior_credit_accounts;
GO

/* Step 095
Make the specified column in dbo.prior_credit_accounts_clean NOT NULL before defining keys.
Existing NULLs must be resolved first.
*/
ALTER TABLE dbo.prior_credit_accounts_clean
ALTER COLUMN Credit_Account_ID VARCHAR(120) NOT NULL;
GO

/* Step 096
Make the specified column in dbo.prior_credit_accounts_clean NOT NULL before defining keys.
Existing NULLs must be resolved first.
*/
ALTER TABLE dbo.prior_credit_accounts_clean
ALTER COLUMN Application_ID VARCHAR(120) NOT NULL;
GO

/* Step 097
Add the primary key to dbo.prior_credit_accounts_clean. The listed column(s) uniquely identify
each row and must be non-null.
*/
ALTER TABLE dbo.prior_credit_accounts_clean
ADD CONSTRAINT PK_prior_credit_accounts_clean
    PRIMARY KEY (Credit_Account_ID);
GO

/* Step 098
Enforce the shown parent-child relationship between dbo.prior_credit_accounts_clean,
dbo.applications_clean. Orphan references will be rejected; this does not enforce unlisted
cross-column business rules.
*/
ALTER TABLE dbo.prior_credit_accounts_clean
ADD CONSTRAINT FK_prior_credit_accounts_clean_applications
    FOREIGN KEY (Application_ID)
    REFERENCES dbo.applications_clean (Application_ID);
GO

/* Step 099
Compare the actual number of prior accounts with Prior_Account_Count in the bureau summary. Rows
returned identify duplicates or reconciliation exceptions; investigate before proceeding.
*/
SELECT
    b.Application_ID,
    b.Prior_Account_Count AS Bureau_Account_Count,
    COUNT(p.Credit_Account_ID) AS Actual_Account_Count
FROM dbo.bureau_summary_clean AS b
LEFT JOIN dbo.prior_credit_accounts_clean AS p
    ON b.Application_ID = p.Application_ID
GROUP BY
    b.Application_ID,
    b.Prior_Account_Count
HAVING COUNT(p.Credit_Account_ID) <> b.Prior_Account_Count;
GO

/* Step 100
Compare the active-account counts. Rows returned identify duplicates or reconciliation
exceptions; investigate before proceeding.
*/
SELECT
    b.Application_ID,
    b.Active_Account_Count AS Bureau_Active_Count,
    SUM(
        CASE WHEN p.Account_Status = 'Active'
             THEN 1 ELSE 0 END
    ) AS Actual_Active_Count
FROM dbo.bureau_summary_clean AS b
LEFT JOIN dbo.prior_credit_accounts_clean AS p
    ON b.Application_ID = p.Application_ID
GROUP BY
    b.Application_ID,
    b.Active_Account_Count
HAVING SUM(
           CASE WHEN p.Account_Status = 'Active'
                THEN 1 ELSE 0 END
       ) <> b.Active_Account_Count;
GO

/* Step 101
Compare total outstanding balances between the account details and bureau summary. Rows returned
identify duplicates or reconciliation exceptions; investigate before proceeding.
*/
SELECT
    b.Application_ID,
    b.Total_Outstanding_INR AS Bureau_Outstanding,
    COALESCE(SUM(p.Outstanding_Balance_INR), 0)
        AS Account_Total_Outstanding
FROM dbo.bureau_summary_clean AS b
LEFT JOIN dbo.prior_credit_accounts_clean AS p
    ON b.Application_ID = p.Application_ID
GROUP BY
    b.Application_ID,
    b.Total_Outstanding_INR
HAVING COALESCE(SUM(p.Outstanding_Balance_INR), 0)
       <> b.Total_Outstanding_INR;
GO

/* Step 102
Compare monthly payment obligations between the account details and bureau summary. Rows
returned identify duplicates or reconciliation exceptions; investigate before proceeding.
*/
SELECT
    b.Application_ID,
    b.Existing_Monthly_Obligation_INR AS Bureau_Monthly_Obligation,
    COALESCE(SUM(p.Monthly_Obligation_INR), 0)
        AS Account_Total_Monthly_Obligation
FROM dbo.bureau_summary_clean AS b
LEFT JOIN dbo.prior_credit_accounts_clean AS p
    ON b.Application_ID = p.Application_ID
GROUP BY
    b.Application_ID,
    b.Existing_Monthly_Obligation_INR
HAVING COALESCE(SUM(p.Monthly_Obligation_INR), 0)
       <> b.Existing_Monthly_Obligation_INR;
GO

/* Step 103
Compare total late payments and maximum DPD with the bureau summary. Rows returned identify
duplicates or reconciliation exceptions; investigate before proceeding.
*/
SELECT
    b.Application_ID,
    b.Total_Late_Payments_Last12M AS Bureau_Late_Payments,
    COALESCE(SUM(p.Late_Payments_Last12M), 0) AS Account_Late_Payments,
    b.Max_Prior_DPD_Last12M AS Bureau_Max_DPD,
    COALESCE(MAX(p.Max_DPD_Last12M), 0) AS Account_Max_DPD
FROM dbo.bureau_summary_clean AS b
LEFT JOIN dbo.prior_credit_accounts_clean AS p
    ON b.Application_ID = p.Application_ID
GROUP BY
    b.Application_ID,
    b.Total_Late_Payments_Last12M,
    b.Max_Prior_DPD_Last12M
HAVING COALESCE(SUM(p.Late_Payments_Last12M), 0)
           <> b.Total_Late_Payments_Last12M
    OR COALESCE(MAX(p.Max_DPD_Last12M), 0)
           <> b.Max_Prior_DPD_Last12M;
GO

/* Step 104
Classify the 13,704 missing utilisation values by active-card presence. Expected only No active
credit card. This distribution explains structural missingness rather than listing errors.
*/
WITH Active_Cards AS (
    SELECT
        Application_ID,
        COUNT(*) AS Active_Card_Count
    FROM dbo.prior_credit_accounts_clean
    WHERE Account_Type = 'Credit Card'
      AND Account_Status = 'Active'
    GROUP BY Application_ID
)
SELECT
    CASE
        WHEN COALESCE(c.Active_Card_Count, 0) = 0
        THEN 'No active credit card'
        ELSE 'Has active credit card'
    END AS Card_Status,
    COUNT(*) AS Missing_Utilisation_Count
FROM dbo.bureau_summary_clean AS b
LEFT JOIN Active_Cards AS c
    ON b.Application_ID = c.Application_ID
WHERE b.Card_Utilisation_Ratio IS NULL
GROUP BY
    CASE
        WHEN COALESCE(c.Active_Card_Count, 0) = 0
        THEN 'No active credit card'
        ELSE 'Has active credit card'
    END;
GO

/* Step 105
Find applicants with an active card but NULL bureau utilisation. Expected zero rows. This checks
the same implication as the previous diagnostic, at application level.
*/
SELECT b.Application_ID
FROM dbo.bureau_summary_clean AS b
WHERE b.Card_Utilisation_Ratio IS NULL
  AND EXISTS (
      SELECT 1
      FROM dbo.prior_credit_accounts_clean AS p
      WHERE p.Application_ID = b.Application_ID
        AND p.Account_Type = 'Credit Card'
        AND p.Account_Status = 'Active'
  );
GO

/* Step 106
Utilisation = total active-card balance ÷ total active-card limit. Inspect returned rows against
the stated rule; an empty exception result indicates no violations of this check.
*/
WITH Card_Totals AS (
    SELECT
        Application_ID,
        SUM(Outstanding_Balance_INR) AS Total_Card_Balance,
        SUM(Credit_Limit_INR) AS Total_Card_Limit
    FROM dbo.prior_credit_accounts_clean
    WHERE Account_Type = 'Credit Card'
      AND Account_Status = 'Active'
    GROUP BY Application_ID
),
Calculated_Utilisation AS (
    SELECT
        Application_ID,
        CAST(
            Total_Card_Balance / NULLIF(Total_Card_Limit, 0)
            AS DECIMAL(10, 4)
        ) AS Calculated_Ratio
    FROM Card_Totals
)
SELECT
    b.Application_ID,
    b.Card_Utilisation_Ratio AS Recorded_Ratio,
    c.Calculated_Ratio
FROM dbo.bureau_summary_clean AS b
LEFT JOIN Calculated_Utilisation AS c
    ON b.Application_ID = c.Application_ID
WHERE b.Card_Utilisation_Ratio <> c.Calculated_Ratio
   OR (b.Card_Utilisation_Ratio IS NULL
       AND c.Calculated_Ratio IS NOT NULL)
   OR (b.Card_Utilisation_Ratio IS NOT NULL
       AND c.Calculated_Ratio IS NULL);
GO

-- ============================================================================
-- 06 | Application decisions
-- ============================================================================

/* Step 107
Create dbo.stg_application_decisions. Staging text columns preserve source values for validation
before conversion.
*/
CREATE TABLE dbo.stg_application_decisions (
    Application_ID  VARCHAR(120) NULL,
    Decision_Date   VARCHAR(120) NULL,
    Decision        VARCHAR(120) NULL,
    Decision_Reason VARCHAR(200) NULL
);
GO

/* Step 108
Import the CSV into dbo.stg_application_decisions once. Skip its header; use comma fields, LF
rows and UTF-8; preserve empty fields as NULL. Check the next row count before continuing.
*/
BULK INSERT dbo.stg_application_decisions
FROM 'C:\Users\royzh\Desktop\Loan Applicant Default Risk Analysis & Prediction\Loan_Applicant_Default_Risk\data\clean\application_decisions.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    CODEPAGE = '65001',
    KEEPNULLS
);
GO

/* Step 109
Count imported decisions. Expected 30,000 rows: 19,393 approved, 4,607 rejected and 6,000
pending.
*/
SELECT COUNT(*) AS Total_Rows
FROM dbo.stg_application_decisions;
GO

/* Step 110
Inspect records from dbo.stg_application_decisions. Read-only result; compare with the
documented expected counts or inspect the displayed values.
*/
SELECT TOP (5) *
FROM dbo.stg_application_decisions
ORDER BY Application_ID;
GO

/* Step 111
Verify decision row count, unique application count and missing-ID count: expected 30,000 /
30,000 / 0.
*/
SELECT
    COUNT(*) AS Total_Rows,
    COUNT(DISTINCT Application_ID) AS Unique_Applications,
    SUM(CASE
        WHEN NULLIF(LTRIM(RTRIM(Application_ID)), '') IS NULL
        THEN 1 ELSE 0
    END) AS Missing_Application_ID
FROM dbo.stg_application_decisions;
GO

/* Step 112
Inspect the decision categories and counts. Compare group counts and inspect missing categories
or unexpected values; this query does not update data.
*/
SELECT
    '[' + Decision + ']' AS Decision_Visible,
    DATALENGTH(Decision) AS Text_Bytes,
    COUNT(*) AS Application_Count
FROM dbo.stg_application_decisions
GROUP BY Decision, DATALENGTH(Decision)
ORDER BY Decision, Text_Bytes;
GO

/* Step 113
Verify that every decision record matches an application. Inspect returned rows against the
stated rule; an empty exception result indicates no violations of this check.
*/
SELECT d.Application_ID
FROM dbo.stg_application_decisions AS d
LEFT JOIN dbo.applications_clean AS a
    ON d.Application_ID = a.Application_ID
WHERE a.Application_ID IS NULL;
GO

/* Step 114
Check decision dates: approved and rejected applications should have valid dates, while pending
applications should have no decision date. Inspect returned rows against the stated rule; an
empty exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Decision,
    Decision_Date
FROM dbo.stg_application_decisions
WHERE
    (
        Decision IN ('Approved', 'Rejected')
        AND TRY_CONVERT(
            DATE,
            NULLIF(LTRIM(RTRIM(Decision_Date)), ''),
            23
        ) IS NULL
    )
    OR
    (
        Decision = 'Pending'
        AND NULLIF(LTRIM(RTRIM(Decision_Date)), '') IS NOT NULL
    );
GO

/* Step 115
Check that no decision occurred before its application. Inspect returned rows against the stated
rule; an empty exception result indicates no violations of this check.
*/
SELECT
    d.Application_ID,
    a.Application_Date,
    d.Decision_Date,
    d.Decision
FROM dbo.stg_application_decisions AS d
INNER JOIN dbo.applications_clean AS a
    ON d.Application_ID = a.Application_ID
WHERE TRY_CONVERT(DATE, d.Decision_Date, 23)
    < a.Application_Date;
GO

/* Step 116
Inspect Decision_Reason, including its last character. Compare group counts and inspect missing
categories or unexpected values; this query does not update data.
*/
SELECT
    Decision,
    '[' + Decision_Reason + ']' AS Reason_Visible,
    DATALENGTH(Decision_Reason) AS Text_Bytes,
    ASCII(RIGHT(Decision_Reason, 1)) AS Last_Character_Code,
    COUNT(*) AS Application_Count
FROM dbo.stg_application_decisions
GROUP BY
    Decision,
    Decision_Reason,
    DATALENGTH(Decision_Reason),
    ASCII(RIGHT(Decision_Reason, 1))
ORDER BY Decision, Decision_Reason;
GO

/* Step 117
Check that decisions match the intended cohorts. Compare group counts and inspect missing
categories or unexpected values; this query does not update data.
*/
SELECT
    a.Cohort,
    d.Decision,
    COUNT(*) AS Application_Count
FROM dbo.stg_application_decisions AS d
INNER JOIN dbo.applications_clean AS a
    ON d.Application_ID = a.Application_ID
GROUP BY a.Cohort, d.Decision
ORDER BY a.Cohort, d.Decision;
GO

/* Step 118
Create and populate dbo.application_decisions_clean. Convert validated source fields to
dates/numbers while preserving intended missing values. CONVERT raises an error on unexpected
invalid input.
*/
SELECT
    Application_ID,
    CONVERT(
        DATE,
        NULLIF(LTRIM(RTRIM(Decision_Date)), ''),
        23
    ) AS Decision_Date,
    Decision,
    Decision_Reason
INTO dbo.application_decisions_clean
FROM dbo.stg_application_decisions;
GO

/* Step 119
Make the specified column in dbo.application_decisions_clean NOT NULL before defining keys.
Existing NULLs must be resolved first.
*/
ALTER TABLE dbo.application_decisions_clean
ALTER COLUMN Application_ID VARCHAR(120) NOT NULL;
GO

/* Step 120
Add the primary key to dbo.application_decisions_clean. The listed column(s) uniquely identify
each row and must be non-null.
*/
ALTER TABLE dbo.application_decisions_clean
ADD CONSTRAINT PK_application_decisions_clean
    PRIMARY KEY (Application_ID);
GO

/* Step 121
Enforce the shown parent-child relationship between dbo.application_decisions_clean,
dbo.applications_clean. Orphan references will be rejected; this does not enforce unlisted
cross-column business rules.
*/
ALTER TABLE dbo.application_decisions_clean
ADD CONSTRAINT FK_application_decisions_clean_applications
    FOREIGN KEY (Application_ID)
    REFERENCES dbo.applications_clean (Application_ID);
GO

/* Step 122
Verify 30,000 clean decision rows with 6,000 missing decision dates and 6,000 missing reasons,
corresponding to pending applicants.
*/
SELECT
    COUNT(*) AS Total_Rows,
    COUNT(*) - COUNT(Decision_Date) AS Missing_Decision_Dates,
    COUNT(*) - COUNT(Decision_Reason) AS Missing_Decision_Reasons
FROM dbo.application_decisions_clean;
GO

-- ============================================================================
-- 07 | Loan originations
-- ============================================================================

/* Step 123
Create dbo.stg_loan_originations. Staging text columns preserve source values for validation
before conversion.
*/
CREATE TABLE dbo.stg_loan_originations (
    Loan_ID               VARCHAR(120) NULL,
    Application_ID        VARCHAR(120) NULL,
    Disbursement_Date     VARCHAR(120) NULL,
    Disbursed_Amount_INR  VARCHAR(120) NULL,
    Term_Months           VARCHAR(120) NULL,
    Annual_Interest_Rate  VARCHAR(120) NULL,
    Scheduled_EMI_INR     VARCHAR(120) NULL
);
GO

/* Step 124
Import the CSV into dbo.stg_loan_originations once. Skip its header; use comma fields, LF rows
and UTF-8; preserve empty fields as NULL. Check the next row count before continuing.
*/
BULK INSERT dbo.stg_loan_originations
FROM 'C:\Users\royzh\Desktop\Loan Applicant Default Risk Analysis & Prediction\Loan_Applicant_Default_Risk\data\clean\loan_originations.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    CODEPAGE = '65001',
    KEEPNULLS
);
GO

/* Step 125
Count loan originations. Expected 19,393 issued loans, each belonging to one approved
application.
*/
SELECT COUNT(*) AS Total_Rows
FROM dbo.stg_loan_originations;
GO

/* Step 126
Inspect records from dbo.stg_loan_originations. Read-only result; compare with the documented
expected counts or inspect the displayed values.
*/
SELECT TOP (5) *
FROM dbo.stg_loan_originations
ORDER BY Loan_ID;
GO

/* Step 127
Check loan and application ID. Read-only result; compare with the documented expected counts or
inspect the displayed values.
*/
SELECT
    COUNT(*) AS Total_Rows,
    COUNT(DISTINCT Loan_ID) AS Unique_Loans,
    COUNT(DISTINCT Application_ID) AS Unique_Applications,
    SUM(CASE
        WHEN NULLIF(LTRIM(RTRIM(Loan_ID)), '') IS NULL
        THEN 1 ELSE 0
    END) AS Missing_Loan_ID,
    SUM(CASE
        WHEN NULLIF(LTRIM(RTRIM(Application_ID)), '') IS NULL
        THEN 1 ELSE 0
    END) AS Missing_Application_ID
FROM dbo.stg_loan_originations;
GO

/* Step 128
Verify that every issued loan belongs to an approved application. Inspect returned rows against
the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    l.Loan_ID,
    l.Application_ID,
    d.Decision
FROM dbo.stg_loan_originations AS l
LEFT JOIN dbo.application_decisions_clean AS d
    ON l.Application_ID = d.Application_ID
WHERE d.Application_ID IS NULL
   OR d.Decision IS NULL
   OR d.Decision <> 'Approved';
GO

/* Step 129
Check that disbursement dates are valid and do not precede approval. Inspect returned rows
against the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    l.Loan_ID,
    l.Application_ID,
    d.Decision_Date,
    l.Disbursement_Date
FROM dbo.stg_loan_originations AS l
INNER JOIN dbo.application_decisions_clean AS d
    ON l.Application_ID = d.Application_ID
WHERE TRY_CONVERT(
          DATE,
          NULLIF(LTRIM(RTRIM(l.Disbursement_Date)), ''),
          23
      ) IS NULL
   OR TRY_CONVERT(DATE, l.Disbursement_Date, 23)
      < d.Decision_Date;
GO

/* Step 130
Check disbursed amounts for missing, invalid, zero, or negative values. Inspect returned rows
against the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Loan_ID,
    Disbursed_Amount_INR
FROM dbo.stg_loan_originations
WHERE TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Disbursed_Amount_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(DECIMAL(18, 2), Disbursed_Amount_INR) <= 0;
GO

/* Step 131
Check loan terms for missing, invalid, zero, or negative values. Inspect returned rows against
the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Loan_ID,
    Term_Months
FROM dbo.stg_loan_originations
WHERE TRY_CONVERT(
          INT,
          NULLIF(LTRIM(RTRIM(Term_Months)), '')
      ) IS NULL
   OR TRY_CONVERT(INT, Term_Months) <= 0;
GO

/* Step 132
Check annual interest rates for missing, invalid, zero, or negative values. Inspect returned
rows against the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Loan_ID,
    Annual_Interest_Rate
FROM dbo.stg_loan_originations
WHERE TRY_CONVERT(
          DECIMAL(10, 4),
          NULLIF(LTRIM(RTRIM(Annual_Interest_Rate)), '')
      ) IS NULL
   OR TRY_CONVERT(DECIMAL(10, 4), Annual_Interest_Rate) <= 0;
GO

/* Step 133
Check Scheduled_EMI_INR, the scheduled monthly instalment. Inspect returned rows against the
stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Loan_ID,
    Scheduled_EMI_INR
FROM dbo.stg_loan_originations
WHERE TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Scheduled_EMI_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(DECIMAL(18, 2), Scheduled_EMI_INR) <= 0;
GO

/* Step 134
Create and populate dbo.loan_originations_clean. Convert validated source fields to
dates/numbers while preserving intended missing values. CONVERT raises an error on unexpected
invalid input.
*/
SELECT
    Loan_ID,
    Application_ID,
    CONVERT(DATE, Disbursement_Date, 23) AS Disbursement_Date,
    CONVERT(DECIMAL(18, 2), Disbursed_Amount_INR)
        AS Disbursed_Amount_INR,
    CONVERT(INT, Term_Months) AS Term_Months,
    CONVERT(DECIMAL(10, 4), Annual_Interest_Rate)
        AS Annual_Interest_Rate,
    CONVERT(DECIMAL(18, 2), Scheduled_EMI_INR)
        AS Scheduled_EMI_INR
INTO dbo.loan_originations_clean
FROM dbo.stg_loan_originations;
GO

/* Step 135
Make the specified column in dbo.loan_originations_clean NOT NULL before defining keys. Existing
NULLs must be resolved first.
*/
ALTER TABLE dbo.loan_originations_clean
ALTER COLUMN Loan_ID VARCHAR(120) NOT NULL;
GO

/* Step 136
Make the specified column in dbo.loan_originations_clean NOT NULL before defining keys. Existing
NULLs must be resolved first.
*/
ALTER TABLE dbo.loan_originations_clean
ALTER COLUMN Application_ID VARCHAR(120) NOT NULL;
GO

/* Step 137
Add the primary key to dbo.loan_originations_clean. The listed column(s) uniquely identify each
row and must be non-null.
*/
ALTER TABLE dbo.loan_originations_clean
ADD CONSTRAINT PK_loan_originations_clean
    PRIMARY KEY (Loan_ID);
GO

/* Step 138
Enforce one originated loan per Application_ID in dbo.loan_originations_clean with a unique
constraint.
*/
ALTER TABLE dbo.loan_originations_clean
ADD CONSTRAINT UQ_loan_originations_clean_Application_ID
    UNIQUE (Application_ID);
GO

/* Step 139
Enforce the shown parent-child relationship between dbo.loan_originations_clean,
dbo.applications_clean. Orphan references will be rejected; this does not enforce unlisted
cross-column business rules.
*/
ALTER TABLE dbo.loan_originations_clean
ADD CONSTRAINT FK_loan_originations_clean_applications
    FOREIGN KEY (Application_ID)
    REFERENCES dbo.applications_clean (Application_ID);
GO

/* Step 140
Find issued amounts above requested amounts or issued terms different from requested terms.
Expected zero rows for this synthetic project.
*/
SELECT
    l.Loan_ID,
    l.Application_ID,
    a.Requested_Amount_INR,
    l.Disbursed_Amount_INR,
    a.Requested_Term_Months,
    l.Term_Months
FROM dbo.loan_originations_clean AS l
INNER JOIN dbo.applications_clean AS a
    ON l.Application_ID = a.Application_ID
WHERE l.Disbursed_Amount_INR > a.Requested_Amount_INR
   OR l.Term_Months <> a.Requested_Term_Months;
GO

/* Step 141
Recalculate EMI using monthly rate = annual rate / 12 and the amortisation formula. Return
discrepancies greater than INR 0.01. Expected zero rows; positive rates and terms were checked
earlier.
*/
WITH EMI_Check AS (
    SELECT
        Loan_ID,
        Scheduled_EMI_INR,
        ROUND(
            Disbursed_Amount_INR
            * (CAST(Annual_Interest_Rate AS FLOAT) / 12)
            / (
                1 - POWER(
                    1 + CAST(Annual_Interest_Rate AS FLOAT) / 12,
                    -Term_Months
                )
            ),
            2
        ) AS Calculated_EMI
    FROM dbo.loan_originations_clean
)
SELECT
    Loan_ID,
    Scheduled_EMI_INR,
    Calculated_EMI
FROM EMI_Check
WHERE ABS(Scheduled_EMI_INR - Calculated_EMI) > 0.01;
GO

-- ============================================================================
-- 08 | Monthly repayments
-- ============================================================================

/* Step 142
Create dbo.stg_monthly_repayments. Staging text columns preserve source values for validation
before conversion.
*/
CREATE TABLE dbo.stg_monthly_repayments (
    Loan_ID                   VARCHAR(120) NULL,
    Application_ID            VARCHAR(120) NULL,
    Month_Number              VARCHAR(120) NULL,
    Due_Date                  VARCHAR(120) NULL,
    Snapshot_Date             VARCHAR(120) NULL,
    Scheduled_Amount_INR      VARCHAR(120) NULL,
    Paid_During_Month_INR     VARCHAR(120) NULL,
    Cumulative_Scheduled_INR  VARCHAR(120) NULL,
    Cumulative_Paid_INR       VARCHAR(120) NULL,
    Arrears_INR               VARCHAR(120) NULL,
    Days_Past_Due             VARCHAR(120) NULL
);
GO

/* Step 143
Import the CSV into dbo.stg_monthly_repayments once. Skip its header; use comma fields, LF rows
and UTF-8; preserve empty fields as NULL. Check the next row count before continuing.
*/
BULK INSERT dbo.stg_monthly_repayments
FROM 'C:\Users\royzh\Desktop\Loan Applicant Default Risk Analysis & Prediction\Loan_Applicant_Default_Risk\data\clean\monthly_repayments.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    CODEPAGE = '65001',
    KEEPNULLS
);
GO

/* Step 144
Count monthly repayment snapshots. Expected 232,716 = 19,393 loans x 12 observations.
*/
SELECT COUNT(*) AS Total_Rows
FROM dbo.stg_monthly_repayments;
GO

/* Step 145
Inspect records from dbo.stg_monthly_repayments. Read-only result; compare with the documented
expected counts or inspect the displayed values.
*/
SELECT TOP (5) *
FROM dbo.stg_monthly_repayments
ORDER BY Loan_ID, TRY_CONVERT(INT, Month_Number);
GO

/* Step 146
Verify loan IDs and application IDs. Read-only result; compare with the documented expected
counts or inspect the displayed values.
*/
SELECT
    COUNT(*) AS Total_Rows,
    COUNT(DISTINCT Loan_ID) AS Unique_Loans,
    COUNT(DISTINCT Application_ID) AS Unique_Applications,
    SUM(CASE
        WHEN NULLIF(LTRIM(RTRIM(Loan_ID)), '') IS NULL
        THEN 1 ELSE 0
    END) AS Missing_Loan_ID,
    SUM(CASE
        WHEN NULLIF(LTRIM(RTRIM(Application_ID)), '') IS NULL
        THEN 1 ELSE 0
    END) AS Missing_Application_ID
FROM dbo.stg_monthly_repayments;
GO

/* Step 147
Verify that every repayment row matches the correct originated loan and application. Inspect
returned rows against the stated rule; an empty exception result indicates no violations of this
check.
*/
SELECT
    r.Loan_ID,
    r.Application_ID,
    l.Application_ID AS Originated_Application_ID
FROM dbo.stg_monthly_repayments AS r
LEFT JOIN dbo.loan_originations_clean AS l
    ON r.Loan_ID = l.Loan_ID
WHERE l.Loan_ID IS NULL
   OR r.Application_ID <> l.Application_ID;
GO

/* Step 148
Verify the repayment month structure. Each loan should have exactly one row for each month from
1 to 12. Rows returned identify duplicates or reconciliation exceptions; investigate before
proceeding.
*/
SELECT
    Loan_ID,
    TRY_CONVERT(INT, Month_Number) AS Month_Number,
    COUNT(*) AS Row_Count
FROM dbo.stg_monthly_repayments
GROUP BY
    Loan_ID,
    TRY_CONVERT(INT, Month_Number)
HAVING TRY_CONVERT(INT, Month_Number) IS NULL
    OR TRY_CONVERT(INT, Month_Number) NOT BETWEEN 1 AND 12
    OR COUNT(*) <> 1;
GO

/* Step 149
Validate the repayment dates and ensure the snapshot is on or after the due date. Inspect
returned rows against the stated rule; an empty exception result indicates no violations of this
check.
*/
SELECT
    Loan_ID,
    Month_Number,
    Due_Date,
    Snapshot_Date
FROM dbo.stg_monthly_repayments
WHERE TRY_CONVERT(
          DATE,
          NULLIF(LTRIM(RTRIM(Due_Date)), ''),
          23
      ) IS NULL
   OR TRY_CONVERT(
          DATE,
          NULLIF(LTRIM(RTRIM(Snapshot_Date)), ''),
          23
      ) IS NULL
   OR TRY_CONVERT(DATE, Due_Date, 23)
      > TRY_CONVERT(DATE, Snapshot_Date, 23);
GO

/* Step 150
Validate the scheduled and paid amounts. Inspect returned rows against the stated rule; an empty
exception result indicates no violations of this check.
*/
SELECT
    Loan_ID,
    Month_Number,
    Scheduled_Amount_INR,
    Paid_During_Month_INR
FROM dbo.stg_monthly_repayments
WHERE TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Scheduled_Amount_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(
          DECIMAL(18, 2),
          Scheduled_Amount_INR
      ) <= 0
   OR TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Paid_During_Month_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(
          DECIMAL(18, 2),
          Paid_During_Month_INR
      ) < 0;
GO

/* Step 151
Validate the cumulative amounts, arrears, and DPD. Inspect returned rows against the stated
rule; an empty exception result indicates no violations of this check.
*/
SELECT
    Loan_ID,
    Month_Number,
    Cumulative_Scheduled_INR,
    Cumulative_Paid_INR,
    Arrears_INR,
    Days_Past_Due
FROM dbo.stg_monthly_repayments
WHERE TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Cumulative_Scheduled_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(
          DECIMAL(18, 2),
          Cumulative_Scheduled_INR
      ) <= 0
   OR TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Cumulative_Paid_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(
          DECIMAL(18, 2),
          Cumulative_Paid_INR
      ) < 0
   OR TRY_CONVERT(
          DECIMAL(18, 2),
          NULLIF(LTRIM(RTRIM(Arrears_INR)), '')
      ) IS NULL
   OR TRY_CONVERT(
          DECIMAL(18, 2),
          Arrears_INR
      ) < 0
   OR TRY_CONVERT(
          INT,
          NULLIF(LTRIM(RTRIM(Days_Past_Due)), '')
      ) IS NULL
   OR TRY_CONVERT(INT, Days_Past_Due) < 0;
GO

/* Step 152
Check cumulative scheduled amount equals monthly scheduled amount x month number, and arrears
equals max(cumulative scheduled minus cumulative paid, 0), within INR 0.01. Expected zero rows.
This does not independently verify cumulative paid against a running sum of payments.
*/
WITH Repayment_Check AS (
    SELECT
        Loan_ID,
        Month_Number,
        TRY_CONVERT(DECIMAL(18, 2), Scheduled_Amount_INR)
            AS Scheduled_Amount,
        TRY_CONVERT(INT, Month_Number)
            AS Month_No,
        TRY_CONVERT(DECIMAL(18, 2), Cumulative_Scheduled_INR)
            AS Cumulative_Scheduled,
        TRY_CONVERT(DECIMAL(18, 2), Cumulative_Paid_INR)
            AS Cumulative_Paid,
        TRY_CONVERT(DECIMAL(18, 2), Arrears_INR)
            AS Arrears
    FROM dbo.stg_monthly_repayments
)
SELECT
    Loan_ID,
    Month_Number,
    Scheduled_Amount,
    Cumulative_Scheduled,
    Cumulative_Paid,
    Arrears
FROM Repayment_Check
WHERE ABS(
          Cumulative_Scheduled
          - (Scheduled_Amount * Month_No)
      ) > 0.01
   OR ABS(
          Arrears
          - CASE
                WHEN Cumulative_Scheduled - Cumulative_Paid > 0
                THEN Cumulative_Scheduled - Cumulative_Paid
                ELSE 0
            END
      ) > 0.01;
GO

/* Step 153
Confirm that every loan has exactly 12 repayment records covering months 1–12. Rows returned
identify duplicates or reconciliation exceptions; investigate before proceeding.
*/
SELECT
    Loan_ID,
    COUNT(*) AS Repayment_Months,
    MIN(TRY_CONVERT(INT, Month_Number)) AS First_Month,
    MAX(TRY_CONVERT(INT, Month_Number)) AS Last_Month
FROM dbo.stg_monthly_repayments
GROUP BY Loan_ID
HAVING COUNT(*) <> 12
    OR MIN(TRY_CONVERT(INT, Month_Number)) <> 1
    OR MAX(TRY_CONVERT(INT, Month_Number)) <> 12;
GO

/* Step 154
Create and populate dbo.monthly_repayments_clean. Convert validated source fields to
dates/numbers while preserving intended missing values. CONVERT raises an error on unexpected
invalid input.
*/
SELECT
    Loan_ID,
    Application_ID,
    CONVERT(INT, Month_Number) AS Month_Number,
    CONVERT(DATE, Due_Date, 23) AS Due_Date,
    CONVERT(DATE, Snapshot_Date, 23) AS Snapshot_Date,
    CONVERT(DECIMAL(18, 2), Scheduled_Amount_INR)
        AS Scheduled_Amount_INR,
    CONVERT(DECIMAL(18, 2), Paid_During_Month_INR)
        AS Paid_During_Month_INR,
    CONVERT(DECIMAL(18, 2), Cumulative_Scheduled_INR)
        AS Cumulative_Scheduled_INR,
    CONVERT(DECIMAL(18, 2), Cumulative_Paid_INR)
        AS Cumulative_Paid_INR,
    CONVERT(DECIMAL(18, 2), Arrears_INR)
        AS Arrears_INR,
    CONVERT(INT, Days_Past_Due) AS Days_Past_Due
INTO dbo.monthly_repayments_clean
FROM dbo.stg_monthly_repayments;
GO

/* Step 155
Make the specified column in dbo.monthly_repayments_clean NOT NULL before defining keys.
Existing NULLs must be resolved first.
*/
ALTER TABLE dbo.monthly_repayments_clean
ALTER COLUMN Loan_ID VARCHAR(120) NOT NULL;
GO

/* Step 156
Make the specified column in dbo.monthly_repayments_clean NOT NULL before defining keys.
Existing NULLs must be resolved first.
*/
ALTER TABLE dbo.monthly_repayments_clean
ALTER COLUMN Application_ID VARCHAR(120) NOT NULL;
GO

/* Step 157
Make the specified column in dbo.monthly_repayments_clean NOT NULL before defining keys.
Existing NULLs must be resolved first.
*/
ALTER TABLE dbo.monthly_repayments_clean
ALTER COLUMN Month_Number INT NOT NULL;
GO

/* Step 158
Add the primary key to dbo.monthly_repayments_clean. The listed column(s) uniquely identify each
row and must be non-null.
*/
ALTER TABLE dbo.monthly_repayments_clean
ADD CONSTRAINT PK_monthly_repayments_clean
    PRIMARY KEY (Loan_ID, Month_Number);
GO

/* Step 159
Enforce the shown parent-child relationship between dbo.monthly_repayments_clean,
dbo.loan_originations_clean. Orphan references will be rejected; this does not enforce unlisted
cross-column business rules.
*/
ALTER TABLE dbo.monthly_repayments_clean
ADD CONSTRAINT FK_monthly_repayments_clean_loan
    FOREIGN KEY (Loan_ID)
    REFERENCES dbo.loan_originations_clean (Loan_ID);
GO

/* Step 160
Enforce the shown parent-child relationship between dbo.monthly_repayments_clean,
dbo.applications_clean. Orphan references will be rejected; this does not enforce unlisted
cross-column business rules.
*/
ALTER TABLE dbo.monthly_repayments_clean
ADD CONSTRAINT FK_monthly_repayments_clean_application
    FOREIGN KEY (Application_ID)
    REFERENCES dbo.applications_clean (Application_ID);
GO

-- ============================================================================
-- 09 | Outcomes and label reconciliation
-- ============================================================================

/* Step 161
Create dbo.stg_loan_outcomes. Staging text columns preserve source values for validation before
conversion.
*/
CREATE TABLE dbo.stg_loan_outcomes (
    Application_ID          VARCHAR(120) NULL,
    Loan_ID                 VARCHAR(120) NULL,
    Observed_Months         VARCHAR(120) NULL,
    Observation_End_Date    VARCHAR(120) NULL,
    Default_90DPD_12M       VARCHAR(120) NULL,
    First_Default_Snapshot  VARCHAR(120) NULL,
    Max_DPD_12M             VARCHAR(120) NULL,
    Months_With_Arrears_12M VARCHAR(120) NULL
);
GO

/* Step 162
Import the CSV into dbo.stg_loan_outcomes once. Skip its header; use comma fields, LF rows and
UTF-8; preserve empty fields as NULL. Check the next row count before continuing.
*/
BULK INSERT dbo.stg_loan_outcomes
FROM 'C:\Users\royzh\Desktop\Loan Applicant Default Risk Analysis & Prediction\Loan_Applicant_Default_Risk\data\clean\loan_outcomes.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    CODEPAGE = '65001',
    KEEPNULLS
);
GO

/* Step 163
Count outcome rows. Expected 30,000 applications, including rejected/pending rows with no loan
target.
*/
SELECT COUNT(*) AS Total_Rows
FROM dbo.stg_loan_outcomes;
GO

/* Step 164
Inspect records from dbo.stg_loan_outcomes. Read-only result; compare with the documented
expected counts or inspect the displayed values.
*/
SELECT TOP (5) *
FROM dbo.stg_loan_outcomes
ORDER BY Application_ID;
GO

/* Step 165
Check outcome row count, unique application IDs, missing application IDs and missing loan IDs.
Expected 30,000 / 30,000 / 0 / 10,607.
*/
SELECT
    COUNT(*) AS Total_Rows,
    COUNT(DISTINCT Application_ID) AS Unique_Applications,
    SUM(CASE
        WHEN NULLIF(LTRIM(RTRIM(Application_ID)), '') IS NULL
        THEN 1 ELSE 0
    END) AS Missing_Application_ID,
    SUM(CASE
        WHEN NULLIF(LTRIM(RTRIM(Loan_ID)), '') IS NULL
        THEN 1 ELSE 0
    END) AS Missing_Loan_ID
FROM dbo.stg_loan_outcomes;
GO

/* Step 166
Verify that every non-NULL outcome loan ID matches an originated loan. Inspect returned rows
against the stated rule; an empty exception result indicates no violations of this check.
*/
SELECT
    o.Application_ID,
    o.Loan_ID
FROM dbo.stg_loan_outcomes AS o
LEFT JOIN dbo.loan_originations_clean AS l
    ON o.Loan_ID = l.Loan_ID
WHERE o.Loan_ID IS NOT NULL
  AND l.Loan_ID IS NULL;
GO

/* Step 167
Find outcome application IDs inconsistent with their originated loan. Expected zero exception
rows.
*/
SELECT
    o.Application_ID,
    o.Loan_ID,
    l.Application_ID AS Originated_Application_ID
FROM dbo.stg_loan_outcomes AS o
INNER JOIN dbo.loan_originations_clean AS l
    ON o.Loan_ID = l.Loan_ID
WHERE o.Application_ID <> l.Application_ID;
GO

/* Step 168
Validate Observed_Months. Inspect returned rows against the stated rule; an empty exception
result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Loan_ID,
    Observed_Months
FROM dbo.stg_loan_outcomes
WHERE TRY_CONVERT(
          INT,
          NULLIF(LTRIM(RTRIM(Observed_Months)), '')
      ) IS NULL
   OR TRY_CONVERT(INT, Observed_Months) NOT BETWEEN 0 AND 12
   OR (
        NULLIF(LTRIM(RTRIM(Loan_ID)), '') IS NULL
        AND TRY_CONVERT(INT, Observed_Months) <> 0
      )
   OR (
        NULLIF(LTRIM(RTRIM(Loan_ID)), '') IS NOT NULL
        AND TRY_CONVERT(INT, Observed_Months) <> 12
      );
GO

/* Step 169
Validate the default target. Inspect returned rows against the stated rule; an empty exception
result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Loan_ID,
    Default_90DPD_12M
FROM dbo.stg_loan_outcomes
WHERE
    (
        NULLIF(LTRIM(RTRIM(Loan_ID)), '') IS NULL
        AND NULLIF(LTRIM(RTRIM(Default_90DPD_12M)), '') IS NOT NULL
    )
    OR
    (
        NULLIF(LTRIM(RTRIM(Loan_ID)), '') IS NOT NULL
        AND TRY_CONVERT(
                INT,
                NULLIF(LTRIM(RTRIM(Default_90DPD_12M)), '')
            ) IS NULL
    )
    OR TRY_CONVERT(
           INT,
           NULLIF(LTRIM(RTRIM(Default_90DPD_12M)), '')
       ) NOT IN (0, 1);
GO

/* Step 170
Validate Max_DPD_12M and Months_With_Arrears_12M. Inspect returned rows against the stated rule;
an empty exception result indicates no violations of this check.
*/
SELECT
    Application_ID,
    Loan_ID,
    Max_DPD_12M,
    Months_With_Arrears_12M
FROM dbo.stg_loan_outcomes
WHERE
    (
        NULLIF(LTRIM(RTRIM(Loan_ID)), '') IS NULL
        AND (
            NULLIF(LTRIM(RTRIM(Max_DPD_12M)), '') IS NOT NULL
            OR NULLIF(LTRIM(RTRIM(Months_With_Arrears_12M)), '') IS NOT NULL
        )
    )
    OR
    (
        NULLIF(LTRIM(RTRIM(Loan_ID)), '') IS NOT NULL
        AND (
            TRY_CONVERT(
                INT,
                NULLIF(LTRIM(RTRIM(Max_DPD_12M)), '')
            ) IS NULL
            OR TRY_CONVERT(INT, Max_DPD_12M) < 0
            OR TRY_CONVERT(
                INT,
                NULLIF(LTRIM(RTRIM(Months_With_Arrears_12M)), '')
            ) IS NULL
            OR TRY_CONVERT(INT, Months_With_Arrears_12M)
                NOT BETWEEN 0 AND 12
        )
    );
GO

/* Step 171
Check missing/invalid outcome dates and any first-default date outside disbursement-to-
observation-end bounds. Unissued applications must have no observation/default dates. This query
does not verify observation end equals the final repayment snapshot.
*/
SELECT
    o.Application_ID,
    o.Loan_ID,
    o.Observation_End_Date,
    o.First_Default_Snapshot,
    l.Disbursement_Date
FROM dbo.stg_loan_outcomes AS o
LEFT JOIN dbo.loan_originations_clean AS l
    ON o.Loan_ID = l.Loan_ID
WHERE
    (
        NULLIF(LTRIM(RTRIM(o.Loan_ID)), '') IS NULL
        AND (
            NULLIF(LTRIM(RTRIM(o.Observation_End_Date)), '') IS NOT NULL
            OR NULLIF(LTRIM(RTRIM(o.First_Default_Snapshot)), '') IS NOT NULL
        )
    )
    OR
    (
        NULLIF(LTRIM(RTRIM(o.Loan_ID)), '') IS NOT NULL
        AND (
            TRY_CONVERT(
                DATE,
                NULLIF(LTRIM(RTRIM(o.Observation_End_Date)), ''),
                23
            ) IS NULL
            OR (
                NULLIF(LTRIM(RTRIM(o.First_Default_Snapshot)), '') IS NOT NULL
                AND (
                    TRY_CONVERT(
                        DATE,
                        o.First_Default_Snapshot,
                        23
                    ) IS NULL
                    OR TRY_CONVERT(
                        DATE,
                        o.First_Default_Snapshot,
                        23
                    ) < l.Disbursement_Date
                    OR TRY_CONVERT(
                        DATE,
                        o.First_Default_Snapshot,
                        23
                    ) > TRY_CONVERT(
                        DATE,
                        o.Observation_End_Date,
                        23
                    )
                )
            )
        )
    );
GO

/* Step 172
Create and populate dbo.loan_outcomes_clean. Convert validated source fields to dates/numbers
while preserving intended missing values. CONVERT raises an error on unexpected invalid input.
*/
SELECT
    Application_ID,
    NULLIF(LTRIM(RTRIM(Loan_ID)), '') AS Loan_ID,
    CONVERT(INT, Observed_Months) AS Observed_Months,
    CONVERT(
        DATE,
        NULLIF(LTRIM(RTRIM(Observation_End_Date)), ''),
        23
    ) AS Observation_End_Date,
    CONVERT(
        INT,
        NULLIF(LTRIM(RTRIM(Default_90DPD_12M)), '')
    ) AS Default_90DPD_12M,
    CONVERT(
        DATE,
        NULLIF(LTRIM(RTRIM(First_Default_Snapshot)), ''),
        23
    ) AS First_Default_Snapshot,
    CONVERT(
        INT,
        NULLIF(LTRIM(RTRIM(Max_DPD_12M)), '')
    ) AS Max_DPD_12M,
    CONVERT(
        INT,
        NULLIF(LTRIM(RTRIM(Months_With_Arrears_12M)), '')
    ) AS Months_With_Arrears_12M
INTO dbo.loan_outcomes_clean
FROM dbo.stg_loan_outcomes;
GO

/* Step 173
Reconcile loan-level labels with monthly snapshots: default >=90 DPD, maximum DPD, first default
date and months with DPD >0. Expected mismatch totals: zero. Arrears_INR >0 previously produced
380 differences and is not the dataset definition.
*/
WITH Repayment_Aggregates AS (
    SELECT
        Loan_ID,
        MAX(Days_Past_Due) AS Calculated_Max_DPD,
        SUM(CASE WHEN Days_Past_Due > 0 THEN 1 ELSE 0 END)
            AS Calculated_Months_With_Arrears,
        CASE
            WHEN MAX(Days_Past_Due) >= 90 THEN 1
            ELSE 0
        END AS Calculated_Default_90DPD,
        MIN(
            CASE
                WHEN Days_Past_Due >= 90 THEN Snapshot_Date
            END
        ) AS Calculated_First_Default
    FROM dbo.monthly_repayments_clean
    GROUP BY Loan_ID
),
Comparison AS (
    SELECT
        o.Loan_ID,
        CASE
            WHEN ISNULL(o.Default_90DPD_12M, -1)
                 <> r.Calculated_Default_90DPD
            THEN 1 ELSE 0
        END AS Default_Mismatch,
        CASE
            WHEN ISNULL(o.Max_DPD_12M, -1)
                 <> r.Calculated_Max_DPD
            THEN 1 ELSE 0
        END AS Max_DPD_Mismatch,
        CASE
            WHEN ISNULL(o.Months_With_Arrears_12M, -1)
                 <> r.Calculated_Months_With_Arrears
            THEN 1 ELSE 0
        END AS Arrears_Months_Mismatch,
        CASE
            WHEN o.First_Default_Snapshot = r.Calculated_First_Default
              OR (
                    o.First_Default_Snapshot IS NULL
                    AND r.Calculated_First_Default IS NULL
                 )
            THEN 0 ELSE 1
        END AS First_Default_Mismatch
    FROM dbo.loan_outcomes_clean AS o
    INNER JOIN Repayment_Aggregates AS r
        ON o.Loan_ID = r.Loan_ID
)
SELECT
    SUM(Default_Mismatch) AS Default_Mismatches,
    SUM(Max_DPD_Mismatch) AS Max_DPD_Mismatches,
    SUM(Arrears_Months_Mismatch) AS Arrears_Months_Mismatches,
    SUM(First_Default_Mismatch) AS First_Default_Mismatches,
    SUM(
        CASE
            WHEN Default_Mismatch = 1
              OR Max_DPD_Mismatch = 1
              OR Arrears_Months_Mismatch = 1
              OR First_Default_Mismatch = 1
            THEN 1 ELSE 0
        END
    ) AS Total_Mismatched_Loans
FROM Comparison;
GO

/* Step 174
Make the specified column in dbo.loan_outcomes_clean NOT NULL before defining keys. Existing
NULLs must be resolved first.
*/
ALTER TABLE dbo.loan_outcomes_clean
ALTER COLUMN Application_ID VARCHAR(120) NOT NULL;
GO

/* Step 175
Add the primary key to dbo.loan_outcomes_clean. The listed column(s) uniquely identify each row
and must be non-null.
*/
ALTER TABLE dbo.loan_outcomes_clean
ADD CONSTRAINT PK_loan_outcomes_clean
    PRIMARY KEY (Application_ID);
GO

/* Step 176
Enforce the shown parent-child relationship between dbo.loan_outcomes_clean,
dbo.applications_clean. Orphan references will be rejected; this does not enforce unlisted
cross-column business rules.
*/
ALTER TABLE dbo.loan_outcomes_clean
ADD CONSTRAINT FK_loan_outcomes_clean_applications
    FOREIGN KEY (Application_ID)
    REFERENCES dbo.applications_clean (Application_ID);
GO

/* Step 177
Enforce the shown parent-child relationship between dbo.loan_outcomes_clean,
dbo.loan_originations_clean. Orphan references will be rejected; this does not enforce unlisted
cross-column business rules.
*/
ALTER TABLE dbo.loan_outcomes_clean
ADD CONSTRAINT FK_loan_outcomes_clean_loans
    FOREIGN KEY (Loan_ID)
    REFERENCES dbo.loan_originations_clean (Loan_ID);
GO

-- ============================================================================
-- 10 | Final table counts
-- ============================================================================

/* Step 178
Final row-count checking for all tables. Read-only result; compare with the documented expected
counts or inspect the displayed values.
*/
SELECT 'applications_clean' AS Table_Name, COUNT(*) AS Row_Count
FROM dbo.applications_clean
UNION ALL
SELECT 'dim_city', COUNT(*)
FROM dbo.dim_city
UNION ALL
SELECT 'bureau_summary_clean', COUNT(*)
FROM dbo.bureau_summary_clean
UNION ALL
SELECT 'prior_credit_accounts_clean', COUNT(*)
FROM dbo.prior_credit_accounts_clean
UNION ALL
SELECT 'application_decisions_clean', COUNT(*)
FROM dbo.application_decisions_clean
UNION ALL
SELECT 'loan_originations_clean', COUNT(*)
FROM dbo.loan_originations_clean
UNION ALL
SELECT 'monthly_repayments_clean', COUNT(*)
FROM dbo.monthly_repayments_clean
UNION ALL
SELECT 'loan_outcomes_clean', COUNT(*)
FROM dbo.loan_outcomes_clean
ORDER BY Table_Name;
GO

-- ============================================================================
-- 11 | Application-time feature views
-- ============================================================================

/* Step 179
Build one row per application using city and bureau features. Ratios divide by income with
NULLIF protection; free cash flow excludes proposed EMI. No future repayment fields are
predictors.
*/
CREATE OR ALTER VIEW dbo.vw_application_risk_base
AS
SELECT
    a.Application_ID,
    a.Applicant_ID,
    a.Application_Date,
    a.Cohort,
    a.City_ID,
    c.City,
    c.State,
    c.City_Tier,
    a.Age,
    a.Employment_Type,
    a.Employment_Sector,
    a.Employment_Tenure_Years,
    a.Housing_Status,
    a.Dependents,
    a.Monthly_Income_INR,
    a.Monthly_Living_Expenses_INR,
    a.Loan_Purpose,
    a.Requested_Amount_INR,
    a.Requested_Term_Months,
    a.Application_Channel,
    b.Snapshot_Date AS Bureau_Snapshot_Date,
    b.Prior_Account_Count,
    b.Active_Account_Count,
    b.Credit_History_Months,
    b.Synthetic_Credit_Score,
    b.Total_Outstanding_INR,
    b.Existing_Monthly_Obligation_INR,
    b.Card_Utilisation_Ratio,
    b.Total_Late_Payments_Last12M,
    b.Max_Prior_DPD_Last12M,
    b.Enquiries_Last6M,
    CAST(
        a.Monthly_Income_INR
        - a.Monthly_Living_Expenses_INR
        - b.Existing_Monthly_Obligation_INR
        AS DECIMAL(18, 2)
    ) AS Estimated_Free_Cash_Flow_INR,
    CAST(
        a.Monthly_Living_Expenses_INR
        / NULLIF(a.Monthly_Income_INR, 0)
        AS DECIMAL(10, 4)
    ) AS Living_Expense_Ratio,
    CAST(
        b.Existing_Monthly_Obligation_INR
        / NULLIF(a.Monthly_Income_INR, 0)
        AS DECIMAL(10, 4)
    ) AS Existing_Obligation_Ratio,
    CAST(
        a.Requested_Amount_INR
        / NULLIF(a.Monthly_Income_INR * 12, 0)
        AS DECIMAL(10, 4)
    ) AS Requested_to_Annual_Income_Ratio,
    CAST(
        b.Total_Outstanding_INR
        / NULLIF(a.Monthly_Income_INR * 12, 0)
        AS DECIMAL(10, 4)
    ) AS Outstanding_to_Annual_Income_Ratio,
    CASE
        WHEN b.Synthetic_Credit_Score IS NULL THEN 1
        ELSE 0
    END AS Credit_Score_Missing_Flag,
    CASE
        WHEN b.Card_Utilisation_Ratio IS NULL THEN 1
        ELSE 0
    END AS Card_Utilisation_Missing_Flag
FROM dbo.applications_clean AS a
LEFT JOIN dbo.bureau_summary_clean AS b
    ON a.Application_ID = b.Application_ID
LEFT JOIN dbo.dim_city AS c
    ON a.City_ID = c.City_ID;
GO

/* Step 180
Verify base-view join cardinality: 30,000 rows and 30,000 unique applications. A multiplied join
would distort both analysis and modelling.
*/
SELECT
    COUNT(*) AS Total_Rows,
    COUNT(DISTINCT Application_ID) AS Unique_Applications
FROM dbo.vw_application_risk_base;
GO

/* Step 181
Join approved historical issued loans with 12 observed months to their default label; expected
19,393 rows. Rejected and pending applications do not have target 0.
*/
CREATE OR ALTER VIEW dbo.vw_model_training
AS
SELECT
    b.*,
    o.Default_90DPD_12M
FROM dbo.vw_application_risk_base AS b
INNER JOIN dbo.application_decisions_clean AS d
    ON b.Application_ID = d.Application_ID
INNER JOIN dbo.loan_originations_clean AS l
    ON b.Application_ID = l.Application_ID
INNER JOIN dbo.loan_outcomes_clean AS o
    ON b.Application_ID = o.Application_ID
WHERE b.Cohort = 'Historical'
  AND d.Decision = 'Approved'
  AND o.Observed_Months = 12;
GO

/* Step 182
Verify the labelled historical view contains 19,393 loans: 2,544 defaults and 16,849 non-
defaults within the 12-month window. This is the full labelled pool, before the temporal
development split.
*/
SELECT
    COUNT(*) AS Training_Rows,
    SUM(CASE WHEN Default_90DPD_12M = 1 THEN 1 ELSE 0 END)
        AS Defaulted_Loans,
    SUM(CASE WHEN Default_90DPD_12M = 0 THEN 1 ELSE 0 END)
        AS Non_Defaulted_Loans
FROM dbo.vw_model_training;
GO

/* Step 183
Select the 6,000 pending New_Scoring applications using the same feature schema, without a
target.
*/
CREATE OR ALTER VIEW dbo.vw_new_applicants_to_score
AS
SELECT *
FROM dbo.vw_application_risk_base
WHERE Cohort = 'New_Scoring';
GO

/* Step 184
Verify the scoring view contains 6,000 rows and 6,000 unique application IDs.
*/
SELECT
    COUNT(*) AS Total_Rows,
    COUNT(DISTINCT Application_ID) AS Unique_Applications
FROM dbo.vw_new_applicants_to_score;
GO

-- ============================================================================
-- 12 | Default patterns and applicant comparisons
-- ============================================================================

/* Step 185
Calculate the overall observed 12-month default rate: 2,544 / 19,393 = 13.12%. This is the
baseline for synthetic approved loans, not all applicants.
*/
SELECT
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM dbo.vw_model_training;
GO


/* Step 186
Compare default rates by exploratory credit-score bands, keeping missing scores separate.
Recorded rates decrease from 36.20% below 600 to 5.12% at 800+. Interpret group sizes alongside
rates; these bands are not official lending cutoffs.
*/
WITH Score_Bands AS (
    SELECT
        Default_90DPD_12M,
        CASE
            WHEN Synthetic_Credit_Score IS NULL THEN 'No score'
            WHEN Synthetic_Credit_Score < 600 THEN 'Below 600'
            WHEN Synthetic_Credit_Score < 650 THEN '600–649'
            WHEN Synthetic_Credit_Score < 700 THEN '650–699'
            WHEN Synthetic_Credit_Score < 750 THEN '700–749'
            WHEN Synthetic_Credit_Score < 800 THEN '750–799'
            ELSE '800+'
        END AS Credit_Score_Band,
        CASE
            WHEN Synthetic_Credit_Score IS NULL THEN 0
            WHEN Synthetic_Credit_Score < 600 THEN 1
            WHEN Synthetic_Credit_Score < 650 THEN 2
            WHEN Synthetic_Credit_Score < 700 THEN 3
            WHEN Synthetic_Credit_Score < 750 THEN 4
            WHEN Synthetic_Credit_Score < 800 THEN 5
            ELSE 6
        END AS Band_Order
    FROM dbo.vw_model_training
)
SELECT
    Credit_Score_Band,
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM Score_Bands
GROUP BY Credit_Score_Band, Band_Order
ORDER BY Band_Order;
GO

/* Step 187
Compare default rates by existing monthly obligations / monthly income. The ratio excludes
proposed-loan EMI. Recorded rates: 24.02% above 40-60%, 39.83% above 60%; unknown income remains
separate.
*/
WITH Obligation_Bands AS (
    SELECT
        Default_90DPD_12M,
        CASE
            WHEN Existing_Obligation_Ratio IS NULL THEN 'Unknown income'
            WHEN Existing_Obligation_Ratio = 0 THEN '0%'
            WHEN Existing_Obligation_Ratio <= 0.20 THEN 'Above 0–20%'
            WHEN Existing_Obligation_Ratio <= 0.40 THEN 'Above 20–40%'
            WHEN Existing_Obligation_Ratio <= 0.60 THEN 'Above 40–60%'
            ELSE 'Above 60%'
        END AS Obligation_Band,
        CASE
            WHEN Existing_Obligation_Ratio IS NULL THEN 0
            WHEN Existing_Obligation_Ratio = 0 THEN 1
            WHEN Existing_Obligation_Ratio <= 0.20 THEN 2
            WHEN Existing_Obligation_Ratio <= 0.40 THEN 3
            WHEN Existing_Obligation_Ratio <= 0.60 THEN 4
            ELSE 5
        END AS Band_Order
    FROM dbo.vw_model_training
)
SELECT
    Obligation_Band,
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM Obligation_Bands
GROUP BY Obligation_Band, Band_Order
ORDER BY Band_Order;
GO

/* Step 188
Compare defaults by the worst prior days-past-due in the preceding 12 months. Recorded rates:
8.38% at zero DPD and 22.77% at 90+. Zero DPD includes applicants with no prior credit.
*/
WITH DPD_Bands AS (
    SELECT
        Default_90DPD_12M,
        CASE
            WHEN Max_Prior_DPD_Last12M IS NULL THEN 'Unknown'
            WHEN Max_Prior_DPD_Last12M = 0 THEN '0 days'
            WHEN Max_Prior_DPD_Last12M <= 30 THEN '1–30 days'
            WHEN Max_Prior_DPD_Last12M <= 60 THEN '31–60 days'
            WHEN Max_Prior_DPD_Last12M <= 89 THEN '61–89 days'
            ELSE '90+ days'
        END AS Prior_DPD_Band,
        CASE
            WHEN Max_Prior_DPD_Last12M IS NULL THEN 0
            WHEN Max_Prior_DPD_Last12M = 0 THEN 1
            WHEN Max_Prior_DPD_Last12M <= 30 THEN 2
            WHEN Max_Prior_DPD_Last12M <= 60 THEN 3
            WHEN Max_Prior_DPD_Last12M <= 89 THEN 4
            ELSE 5
        END AS Band_Order
    FROM dbo.vw_model_training
)
SELECT
    Prior_DPD_Band,
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM DPD_Bands
GROUP BY Prior_DPD_Band, Band_Order
ORDER BY Band_Order;
GO

/* Step 189
Compare applicants without prior accounts (10.49% default) against those with prior accounts
(13.62%). The latter group combines good and poor repayment histories; do not infer causality.
*/
SELECT
    CASE
        WHEN Prior_Account_Count = 0 THEN 'No prior credit accounts'
        WHEN Prior_Account_Count > 0 THEN 'Has prior credit accounts'
        ELSE 'Unknown'
    END AS Credit_History_Group,
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM dbo.vw_model_training
GROUP BY
    CASE
        WHEN Prior_Account_Count = 0 THEN 'No prior credit accounts'
        WHEN Prior_Account_Count > 0 THEN 'Has prior credit accounts'
        ELSE 'Unknown'
    END;
GO

/* Step 190
Separate no history from existing accounts with and without recent delays. Recorded default
rates: prior accounts/no delays 6.40%, no prior accounts 10.49%, prior delays 15.44%. No delays
refers to the prior 12 months only.
*/
WITH History_Groups AS (
    SELECT
        Default_90DPD_12M,
        CASE
            WHEN Prior_Account_Count = 0
                THEN 'No prior credit accounts'
            WHEN Max_Prior_DPD_Last12M = 0
                THEN 'Prior accounts: no delays'
            WHEN Max_Prior_DPD_Last12M > 0
                THEN 'Prior accounts: previous delays'
            ELSE 'Unknown'
        END AS Credit_History_Group
    FROM dbo.vw_model_training
)
SELECT
    Credit_History_Group,
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM History_Groups
GROUP BY Credit_History_Group
ORDER BY Default_Rate_Percent;
GO

/* Step 191
Compare loan purposes; COALESCE displays missing purpose as Unknown without updating data. Home
Improvement had the highest recorded rate, 14.93%; retain group counts and do not infer purpose
causes default.
*/
SELECT
    COALESCE(Loan_Purpose, 'Unknown') AS Loan_Purpose,
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM dbo.vw_model_training
GROUP BY COALESCE(Loan_Purpose, 'Unknown')
ORDER BY Default_Rate_Percent DESC;
GO

/* Step 192
Compare employment groups. Recorded default rates: Contract 15.34%, Self-employed 14.08%,
Salaried 12.35%. These unadjusted differences are descriptive synthetic associations.
*/
SELECT
    Employment_Type,
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM dbo.vw_model_training
GROUP BY Employment_Type
ORDER BY Default_Rate_Percent DESC;
GO

/* Step 193
Compare active-card utilisation bands and preserve no-active-card applicants separately.
Recorded default rate above 90% is 24.10%, but only 83 loans fall in that band.
*/
WITH Utilisation_Bands AS (
    SELECT
        Default_90DPD_12M,
        CASE
            WHEN Card_Utilisation_Ratio IS NULL
                THEN 'No active credit card'
            WHEN Card_Utilisation_Ratio <= 0.30
                THEN '0–30%'
            WHEN Card_Utilisation_Ratio <= 0.60
                THEN 'Above 30–60%'
            WHEN Card_Utilisation_Ratio <= 0.90
                THEN 'Above 60–90%'
            ELSE 'Above 90%'
        END AS Utilisation_Band,
        CASE
            WHEN Card_Utilisation_Ratio IS NULL THEN 0
            WHEN Card_Utilisation_Ratio <= 0.30 THEN 1
            WHEN Card_Utilisation_Ratio <= 0.60 THEN 2
            WHEN Card_Utilisation_Ratio <= 0.90 THEN 3
            ELSE 4
        END AS Band_Order
    FROM dbo.vw_model_training
)
SELECT
    Utilisation_Band,
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM Utilisation_Bands
GROUP BY Utilisation_Band, Band_Order
ORDER BY Band_Order;
GO

/* Step 194
Compare requested principal / annual income. A ratio of 1 means one year of income. Above 100%
has a recorded 24.80% default rate across 512 loans; this ratio excludes term and interest.
*/
WITH Amount_Bands AS (
    SELECT
        Default_90DPD_12M,
        CASE
            WHEN Requested_to_Annual_Income_Ratio IS NULL
                THEN 'Unknown income'
            WHEN Requested_to_Annual_Income_Ratio <= 0.25
                THEN 'Up to 25%'
            WHEN Requested_to_Annual_Income_Ratio <= 0.50
                THEN 'Above 25–50%'
            WHEN Requested_to_Annual_Income_Ratio <= 1.00
                THEN 'Above 50–100%'
            ELSE 'Above 100%'
        END AS Requested_Amount_Band,
        CASE
            WHEN Requested_to_Annual_Income_Ratio IS NULL THEN 0
            WHEN Requested_to_Annual_Income_Ratio <= 0.25 THEN 1
            WHEN Requested_to_Annual_Income_Ratio <= 0.50 THEN 2
            WHEN Requested_to_Annual_Income_Ratio <= 1.00 THEN 3
            ELSE 4
        END AS Band_Order
    FROM dbo.vw_model_training
)
SELECT
    Requested_Amount_Band,
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM Amount_Bands
GROUP BY Requested_Amount_Band, Band_Order
ORDER BY Band_Order;
GO

/* Step 195
Cross-tabulate credit-score bands with existing-obligation ratio <=40% versus >40%. Below-650 /
above-40% recorded 46.07% defaults; 750+ / up-to-40% recorded 5.58%. The 40% boundary is
exploratory, not an approval rule.
*/
WITH Risk_Groups AS (
    SELECT
        Default_90DPD_12M,
        CASE
            WHEN Synthetic_Credit_Score IS NULL THEN 'No score'
            WHEN Synthetic_Credit_Score < 650 THEN 'Below 650'
            WHEN Synthetic_Credit_Score < 750 THEN '650–749'
            ELSE '750+'
        END AS Credit_Score_Group,
        CASE
            WHEN Synthetic_Credit_Score IS NULL THEN 0
            WHEN Synthetic_Credit_Score < 650 THEN 1
            WHEN Synthetic_Credit_Score < 750 THEN 2
            ELSE 3
        END AS Score_Order,
        CASE
            WHEN Existing_Obligation_Ratio IS NULL THEN 'Unknown income'
            WHEN Existing_Obligation_Ratio <= 0.40 THEN 'Up to 40%'
            ELSE 'Above 40%'
        END AS Obligation_Group
    FROM dbo.vw_model_training
)
SELECT
    Credit_Score_Group,
    Obligation_Group,
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM Risk_Groups
GROUP BY
    Credit_Score_Group,
    Score_Order,
    Obligation_Group
ORDER BY
    Score_Order,
    Obligation_Group;
GO

/* Step 196
Group by application quarter and calculate subsequent 12-month default rates. These are
application cohorts, not defaults occurring in that calendar quarter. Most rates are
12.89-13.95%; 2024 Q4 is 11.16%.
*/
SELECT
    YEAR(Application_Date) AS Application_Year,
    DATEPART(QUARTER, Application_Date) AS Application_Quarter,
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM dbo.vw_model_training
GROUP BY
    YEAR(Application_Date),
    DATEPART(QUARTER, Application_Date)
ORDER BY
    Application_Year,
    Application_Quarter;
GO

/* Step 197
Compare approved historical applicants with all pending new applicants. AVG excludes NULL.
Higher new-applicant obligations may reflect historical approval selection, so include rejected
applicants before interpreting a time shift.
*/
WITH Applicant_Groups AS (
    SELECT
        'Historical approved' AS Applicant_Group,
        Synthetic_Credit_Score,
        Existing_Obligation_Ratio,
        Requested_to_Annual_Income_Ratio,
        Prior_Account_Count
    FROM dbo.vw_model_training
    UNION ALL
    SELECT
        'New applicants' AS Applicant_Group,
        Synthetic_Credit_Score,
        Existing_Obligation_Ratio,
        Requested_to_Annual_Income_Ratio,
        Prior_Account_Count
    FROM dbo.vw_new_applicants_to_score
)
SELECT
    Applicant_Group,
    COUNT(*) AS Applications,
    CAST(
        AVG(1.0 * Synthetic_Credit_Score)
        AS DECIMAL(10, 2)
    ) AS Avg_Credit_Score,
    CAST(
        100.0 * AVG(Existing_Obligation_Ratio)
        AS DECIMAL(10, 2)
    ) AS Avg_Existing_Obligation_Percent,
    CAST(
        100.0 * AVG(Requested_to_Annual_Income_Ratio)
        AS DECIMAL(10, 2)
    ) AS Avg_Requested_to_Annual_Income_Percent,
    CAST(
        100.0 * SUM(CASE WHEN Prior_Account_Count = 0 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS No_Prior_Credit_Percent
FROM Applicant_Groups
GROUP BY Applicant_Group;
GO

/* Step 198
Count applicants above the exploratory 40% obligation boundary. Divide by known ratios only, not
all rows. Recorded shares: approved historical 13.25%, new 21.15%.
*/
WITH Applicant_Groups AS (
    SELECT
        'Historical approved' AS Applicant_Group,
        Existing_Obligation_Ratio
    FROM dbo.vw_model_training
    UNION ALL
    SELECT
        'New applicants' AS Applicant_Group,
        Existing_Obligation_Ratio
    FROM dbo.vw_new_applicants_to_score
)
SELECT
    Applicant_Group,
    COUNT(*) AS Total_Applicants,
    COUNT(Existing_Obligation_Ratio) AS Known_Ratio_Count,
    SUM(
        CASE WHEN Existing_Obligation_Ratio > 0.40
             THEN 1 ELSE 0 END
    ) AS Above_40_Percent_Count,
    CAST(
        100.0 * SUM(
            CASE WHEN Existing_Obligation_Ratio > 0.40
                 THEN 1 ELSE 0 END
        )
        / NULLIF(COUNT(Existing_Obligation_Ratio), 0)
        AS DECIMAL(5, 2)
    ) AS Above_40_Percent_Share
FROM Applicant_Groups
GROUP BY Applicant_Group;
GO

/* Step 199
Include historical rejections in the obligation comparison. Recorded above-40% shares: approved
13.25%, rejected 51.34%, new 21.15%. All historical applicants combined: 4,928 / 23,966 =
20.56%; this is closer to new applicants than the approved-only comparison.
*/
WITH Comparison_Groups AS (
    SELECT
        CASE
            WHEN a.Cohort = 'New_Scoring'
                THEN 'New applicants'
            WHEN d.Decision = 'Approved'
                THEN 'Historical approved'
            WHEN d.Decision = 'Rejected'
                THEN 'Historical rejected'
        END AS Applicant_Group,
        a.Existing_Obligation_Ratio
    FROM dbo.vw_application_risk_base AS a
    INNER JOIN dbo.application_decisions_clean AS d
        ON a.Application_ID = d.Application_ID
    WHERE a.Cohort = 'New_Scoring'
       OR (
            a.Cohort = 'Historical'
            AND d.Decision IN ('Approved', 'Rejected')
       )
)
SELECT
    Applicant_Group,
    COUNT(*) AS Total_Applicants,
    COUNT(Existing_Obligation_Ratio) AS Known_Ratio_Count,
    CAST(
        100.0 * AVG(Existing_Obligation_Ratio)
        AS DECIMAL(10, 2)
    ) AS Avg_Obligation_Percent,
    SUM(
        CASE WHEN Existing_Obligation_Ratio > 0.40
             THEN 1 ELSE 0 END
    ) AS Above_40_Percent_Count,
    CAST(
        100.0 * SUM(
            CASE WHEN Existing_Obligation_Ratio > 0.40
                 THEN 1 ELSE 0 END
        )
        / NULLIF(COUNT(Existing_Obligation_Ratio), 0)
        AS DECIMAL(5, 2)
    ) AS Above_40_Percent_Share
FROM Comparison_Groups
GROUP BY Applicant_Group
ORDER BY Applicant_Group;
GO

/* Step 200
Count each rejection reason and divide by all rejected applications using SUM(COUNT(*)) OVER().
Recorded shares: affordability 57.33%, other underwriting 26.03%, credit history 16.65%. Rounded
shares total 100.01%. These describe the simulated policy.
*/
SELECT
    Decision_Reason,
    COUNT(*) AS Rejected_Applications,
    CAST(
        100.0 * COUNT(*)
        / SUM(COUNT(*)) OVER ()
        AS DECIMAL(5, 2)
    ) AS Share_of_Rejections_Percent
FROM dbo.application_decisions_clean
WHERE Decision = 'Rejected'
GROUP BY Decision_Reason
ORDER BY Rejected_Applications DESC;
GO

/* Step 201
Inspect application and outcome-end ranges by application year. Some 2023 applications finish
observation in January 2025, so application year alone cannot determine label availability.
*/
SELECT
    YEAR(a.Application_Date) AS Application_Year,
    COUNT(*) AS Observed_Loans,
    MIN(a.Application_Date) AS First_Application_Date,
    MAX(a.Application_Date) AS Last_Application_Date,
    MIN(o.Observation_End_Date) AS Earliest_Outcome_End,
    MAX(o.Observation_End_Date) AS Latest_Outcome_End
FROM dbo.vw_model_training AS a
INNER JOIN dbo.loan_outcomes_clean AS o
    ON a.Application_ID = o.Application_ID
GROUP BY YEAR(a.Application_Date)
ORDER BY Application_Year;
GO

-- ============================================================================
-- 13 | Time-aware development split and CSV export
-- ============================================================================

/* Step 202
Count the proposed time-aware splits before exporting: training outcomes end before 2025-01-01;
test applications fall in Jan-Jun 2025; others are excluded from this evaluation. Expected 7,700
/ 3,987 / 7,706. Excluded rows remain available for the August 2026 final refit.
*/
WITH Model_Splits AS (
    SELECT
        a.Default_90DPD_12M,
        CASE
            WHEN o.Observation_End_Date < '20250101'
                THEN 'Training pool'
            WHEN a.Application_Date >= '20250101'
             AND a.Application_Date <  '20250701'
                THEN 'Test set'
            ELSE 'Excluded from this evaluation'
        END AS Dataset_Split
    FROM dbo.vw_model_training AS a
    INNER JOIN dbo.loan_outcomes_clean AS o
        ON a.Application_ID = o.Application_ID
)
SELECT
    Dataset_Split,
    COUNT(*) AS Observed_Loans,
    SUM(Default_90DPD_12M) AS Defaulted_Loans,
    CAST(
        100.0 * SUM(Default_90DPD_12M)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(5, 2)
    ) AS Default_Rate_Percent
FROM Model_Splits
GROUP BY Dataset_Split
ORDER BY Dataset_Split;
GO

/* Step 203
Attach observation end and the fixed split: mature outcomes before 2025 -> Training; Jan-Jun
2025 applications -> Test; remainder -> Excluded. Metadata must not become predictors.
*/
CREATE OR ALTER VIEW dbo.vw_model_development AS
SELECT
    a.*,
    o.Observation_End_Date,
    CASE
        WHEN o.Observation_End_Date < '20250101'
            THEN 'Training'
        WHEN a.Application_Date >= '20250101'
         AND a.Application_Date <  '20250701'
            THEN 'Test'
        ELSE 'Excluded'
    END AS Dataset_Split
FROM dbo.vw_model_training AS a
INNER JOIN dbo.loan_outcomes_clean AS o
    ON a.Application_ID = o.Application_ID;
GO

/* Step 204
Export this result with column headers to data/model_exports/model_development.csv: 19,393 rows
and 41 columns. SSMS Save Results As CSV; retain NULLs.
*/
SELECT * FROM dbo.vw_model_development ORDER BY Application_Date, Application_ID;
GO

/* Step 205
Export with headers to data/model_exports/new_applicants_to_score.csv: 6,000 rows and 38
columns. No default target is included.
*/
SELECT * FROM dbo.vw_new_applicants_to_score ORDER BY Application_Date, Application_ID;
GO
