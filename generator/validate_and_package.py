from pathlib import Path
import hashlib,json,shutil,zipfile
import numpy as np
import pandas as pd

source=Path(__file__).resolve().parent
root=source/'Loan_Applicant_Risk_Synthetic'
report=json.loads((root/'documentation/validation_report.json').read_text())
app=pd.read_csv(root/'data/clean/applications.csv')
cr=pd.read_csv(root/'data/clean/prior_credit_accounts.csv')
rep=pd.read_csv(root/'data/clean/monthly_repayments.csv')
orig=pd.read_csv(root/'data/clean/loan_originations.csv')
out=pd.read_csv(root/'data/clean/loan_outcomes.csv')
def check(name,result):
    report['checks'][name]=bool(result)
    assert result,name
longclosed=(pd.to_datetime(cr.Snapshot_Date)-pd.to_datetime(cr.Closed_Date)).dt.days>=360
check('long-closed accounts have no recent late payments',cr.loc[longclosed,'Late_Payments_Last12M'].eq(0).all())
j=orig.merge(app[['Application_ID','Application_Date','Requested_Amount_INR']],on='Application_ID',validate='one_to_one')
check('disbursement after application',(j.Disbursement_Date>j.Application_Date).all())
check('offers do not exceed requests',(j.Disbursed_Amount_INR<=j.Requested_Amount_INR).all())
r=orig.Annual_Interest_Rate/12
emi=orig.Disbursed_Amount_INR*r/(1-(1+r)**(-orig.Term_Months))
check('EMI independently recomputed',np.allclose(emi,orig.Scheduled_EMI_INR,atol=.006))
check('snapshot after due date',(rep.Snapshot_Date>=rep.Due_Date).all())
check('unique scoring applicants',pd.read_csv(root/'data/clean/new_applicants_to_score.csv').Application_ID.is_unique)
# Independently recompute FIFO ages for a deterministic sample of 100 loans.
allok=True
for loan in orig.Loan_ID.sample(100,random_state=17):
    rows=rep.loc[rep.Loan_ID==loan].sort_values('Month_Number')
    for _,row in rows.iterrows():
        unpaid=rows[(rows.Month_Number<=row.Month_Number)&(rows.Cumulative_Scheduled_INR>row.Cumulative_Paid_INR+.01)]
        expected=0 if unpaid.empty else (pd.Timestamp(row.Snapshot_Date)-pd.Timestamp(unpaid.iloc[0].Due_Date)).days
        allok=allok and int(row.Days_Past_Due)==expected
check('independent FIFO DPD verification on 100 loans',allok)

# Sanity check of learnability, not a recommended model or claimed real performance.
from sklearn.impute import SimpleImputer
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import make_pipeline
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score,average_precision_score
df=pd.read_csv(root/'data/clean/model_training.csv')
df['Existing_DTI']=df.Existing_Monthly_Obligation_INR/df.Monthly_Income_INR
df['Requested_Loan_Income']=df.Requested_Amount_INR/(12*df.Monthly_Income_INR)
cols=['Synthetic_Credit_Score','Card_Utilisation_Ratio','Max_Prior_DPD_Last12M','Total_Late_Payments_Last12M','Existing_DTI','Requested_Loan_Income','Enquiries_Last6M','Credit_History_Months','Employment_Tenure_Years','Requested_Term_Months']
tr=df.Suggested_Split.eq('Train'); te=df.Suggested_Split.eq('Test')
model=make_pipeline(SimpleImputer(add_indicator=True),StandardScaler(),LogisticRegression(max_iter=1000))
model.fit(df.loc[tr,cols],df.loc[tr,'Default_90DPD_12M'])
p=model.predict_proba(df.loc[te,cols])[:,1]
auc=roc_auc_score(df.loc[te,'Default_90DPD_12M'],p)
report['simulation_sanity_check']={'model':'Numeric-only logistic regression; retrospective cohort split','test_roc_auc':round(float(auc),4),'test_pr_auc':round(float(average_precision_score(df.loc[te,'Default_90DPD_12M'],p)),4),'test_default_rate':round(float(df.loc[te,'Default_90DPD_12M'].mean()),4),'note':'Checks that exported features have imperfect signal. This is synthetic performance only, not a deployment backtest or real-lender benchmark.'}
check('outcome has usable but imperfect signal',.55<auc<.95)
(root/'documentation/validation_report.json').write_text(json.dumps(report,indent=2))
shutil.copy2(source/'build_dataset.py',root/'generator/build_dataset.py')
shutil.copy2(source/'validate_and_package.py',root/'generator/validate_and_package.py')
manifest=[]
for f in sorted(root.rglob('*')):
    if f.is_file() and f.name!='manifest.json':
        manifest.append({'path':str(f.relative_to(root)),'bytes':f.stat().st_size,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()})
(root/'documentation/manifest.json').write_text(json.dumps(manifest,indent=2))
outpath=source/'Loan_Applicant_Risk_Synthetic_30000.zip'
with zipfile.ZipFile(outpath,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for f in sorted(root.rglob('*')):
        if f.is_file(): z.write(f,f.relative_to(root.parent))
with zipfile.ZipFile(outpath) as z: assert z.testzip() is None
print(json.dumps({'archive':str(outpath),'bytes':outpath.stat().st_size,'stats':report},indent=2))
