"""Reproducible synthetic lending simulation. No real personal or lender data."""
from pathlib import Path
import calendar, json, shutil, zipfile
import numpy as np
import pandas as pd

SEED = 28092026
N = 30000
AS_OF = pd.Timestamp('2026-08-31')
ROOT = Path(__file__).resolve().parent / 'Loan_Applicant_Risk_Synthetic'
rng = np.random.default_rng(SEED)
for folder in ['data/clean','data/raw_practice','documentation','sql','generator']:
    (ROOT/folder).mkdir(parents=True,exist_ok=True)

def sigmoid(x): return 1/(1+np.exp(-x))
def plus_month(d,m):
    d=pd.Timestamp(d); y=d.year+(d.month-1+m)//12; mo=(d.month-1+m)%12+1
    return pd.Timestamp(y,mo,min(d.day,calendar.monthrange(y,mo)[1]))
def iso(d): return pd.Timestamp(d).strftime('%Y-%m-%d') if pd.notna(d) else None
def money(x): return round(float(x),2)
def write(df,name,folder='clean'):
    df.to_csv(ROOT/f'data/{folder}/{name}.csv',index=False,float_format='%.4f',date_format='%Y-%m-%d')

cities=[('C01','Kolkata','West Bengal','Metro',1.0),('C02','Mumbai','Maharashtra','Metro',1.45),
 ('C03','Bengaluru','Karnataka','Metro',1.35),('C04','Delhi','Delhi','Metro',1.3),
 ('C05','Chennai','Tamil Nadu','Metro',1.15),('C06','Hyderabad','Telangana','Metro',1.15),
 ('C07','Pune','Maharashtra','Large city',1.2),('C08','Ahmedabad','Gujarat','Large city',1.05),
 ('C09','Jaipur','Rajasthan','Large city',.9),('C10','Lucknow','Uttar Pradesh','Large city',.85),
 ('C11','Indore','Madhya Pradesh','Other city',.8),('C12','Bhubaneswar','Odisha','Other city',.8)]
citydf=pd.DataFrame([c[:4] for c in cities],columns=['City_ID','City','State','City_Tier'])
apps=[]; bureau=[]; summaries=[]; decisions=[]; originations=[]; repayments=[]; outcomes=[]
for i in range(N):
    aid=f'APP{i+1:06d}'; cid=f'SYN{i+1:06d}'
    historical=i<24000
    ad=pd.Timestamp('2023-01-01')+pd.Timedelta(days=int(rng.integers(0,912))) if historical else pd.Timestamp('2026-08-01')+pd.Timedelta(days=int(rng.integers(0,31)))
    city=cities[int(rng.integers(len(cities)))]; age=int(np.clip(rng.normal(36,9),21,62))
    employment=rng.choice(['Salaried','Self-employed','Contract'],p=[.64,.24,.12])
    tenure=round(min(age-18,rng.gamma(2,2.3)),1)
    sector=rng.choice(['Technology','Manufacturing','Retail','Healthcare','Education','Transport','Hospitality','Other'])
    stability=rng.normal(0,1)
    income=money(np.clip(rng.lognormal(np.log(43000*city[4]),.53)*(1.13 if employment=='Self-employed' else .88 if employment=='Contract' else 1),15000,350000))
    dependents=int(rng.choice([0,1,2,3,4],p=[.19,.26,.33,.17,.05]))
    housing=rng.choice(['Rent','Owned','Family'],p=[.46,.26,.28])
    expense=money(income*np.clip(rng.normal(.36+.035*dependents+(.08 if housing=='Rent' else 0),.09),.18,.83))
    count=int(rng.choice([0,1,2,3,4,5,6],p=[.14,.16,.25,.23,.13,.06,.03]))
    arows=[]
    for j in range(count):
        typ=rng.choice(['Credit Card','Personal Loan','Vehicle Loan','Home Loan'],p=[.47,.31,.17,.05])
        histmonths=int(rng.integers(2,max(3,min(180,(age-18)*12))))
        opened=ad-pd.Timedelta(days=30*histmonths+int(rng.integers(0,29)))
        active=bool(rng.random()<.72)
        closed=opened+pd.Timedelta(days=int(rng.integers(30,max(31,(ad-opened).days-1)))) if not active else pd.NaT
        limit=money(np.clip(income*rng.uniform(1,5),15000,800000)) if typ=='Credit Card' else 0.0
        original=limit if typ=='Credit Card' else money(income*rng.uniform(2,10 if typ!='Home Loan' else 35))
        util=float(np.clip(rng.beta(2,3)+.10*stability,0,.99))
        bal=money(limit*util if typ=='Credit Card' else original*rng.uniform(.08,.95)) if active else 0.0
        emi=money(bal*.05 if typ=='Credit Card' else original/(rng.choice([24,36,48,60]))*1.12) if active else 0.0
        latep=float(sigmoid(-2+.75*stability+(.3 if employment=='Contract' else 0)))
        # A long-closed account cannot have a late payment in the recent window.
        eligiblemonths=min(12,histmonths) if active else max(0,min(histmonths,12-int((ad-closed).days/30)))
        late=int(rng.binomial(eligiblemonths,latep))
        maxdpd=int(rng.choice([7,15,30,60,90,120],p=[.23,.22,.28,.16,.08,.03])) if late else 0
        row=[f'CR{i+1:06d}_{j+1}',aid,iso(ad),typ,iso(opened),'Active' if active else 'Closed',iso(closed),original,limit,bal,emi,late,maxdpd]
        arows.append(row); bureau.append(row)
    activecount=sum(r[5]=='Active' for r in arows)
    totalbal=money(sum(r[9] for r in arows)); existingemi=money(sum(r[10] for r in arows))
    cards=[r for r in arows if r[3]=='Credit Card' and r[5]=='Active']
    creditlimit=sum(r[8] for r in cards)
    utilratio=round(sum(r[9] for r in cards)/creditlimit,4) if creditlimit else None
    priorlate=sum(r[11] for r in arows); priormax=max([r[12] for r in arows],default=0)
    histm=max([int((ad-pd.Timestamp(r[4])).days/30) for r in arows],default=0)
    enquiries=int(np.clip(rng.poisson(np.exp(.3+.22*stability)),0,15))
    score=int(np.clip(765-20*stability-2.7*priorlate-.48*priormax-55*(utilratio or 0)-7*enquiries+rng.normal(0,27),300,900)) if count else None
    summaries.append([aid,iso(ad),count,activecount,histm,score,totalbal,existingemi,utilratio,priorlate,priormax,enquiries])
    purpose=rng.choice(['Debt Consolidation','Medical','Education','Home Improvement','Wedding','Consumer Purchase'],p=[.27,.14,.12,.17,.13,.17])
    req=money(np.clip(np.round(income*rng.lognormal(np.log(5),.5)/5000)*5000,30000,1500000))
    term=int(rng.choice([12,24,36,48,60],p=[.07,.22,.35,.24,.12]))
    apps.append([aid,cid,iso(ad),'Historical' if historical else 'New_Scoring',city[0],age,employment,sector,tenure,housing,dependents,income,expense,purpose,req,term,rng.choice(['Mobile App','Web','Branch','Partner'],p=[.43,.25,.17,.15])])
    # Internal simulation parameters are never exported as application predictors.
    monthlyrate=.18/12
    requestedemi=req*monthlyrate/(1-(1+monthlyrate)**(-term))
    foir=(existingemi+requestedemi)/income
    risklog=-3.0+2.8*max(foir-.35,0)+.60*stability+.008*priormax+.06*enquiries+.35*(count==0)+.35*(employment=='Contract')+.30*(employment=='Self-employed')+.75*max((expense+existingemi+requestedemi)/income-.9,0)
    if not historical:
        decisions.append([aid,None,'Pending',None]); outcomes.append([aid,None,0,None,None,None,None,None]); continue
    acceptp=float(sigmoid(2.8-4.8*max(foir-.38,0)-.012*max(650-(score or 650),0)-.006*priormax+rng.normal(0,.6)))
    approved=bool(rng.random()<acceptp)
    decisiondate=ad+pd.Timedelta(days=int(rng.integers(0,5)))
    reason='Approved under simulated policy' if approved else ('Affordability review' if foir>.65 else 'Credit history review' if priormax>=60 else 'Other underwriting review')
    decisions.append([aid,iso(decisiondate),'Approved' if approved else 'Rejected',reason])
    if not approved:
        outcomes.append([aid,None,0,None,None,None,None,None]); continue
    loan=f'LN{i+1:06d}'; disb=decisiondate+pd.Timedelta(days=int(rng.integers(1,5)))
    approvedamt=money(req*rng.choice([1,.9,.8],p=[.78,.15,.07]))
    apr=round(float(np.clip(.115+.055*sigmoid(risklog+2)+(.016 if count==0 else 0)+rng.normal(0,.012),.10,.27)),4)
    r=apr/12; emi=money(approvedamt*r/(1-(1+r)**(-term)))
    originations.append([loan,aid,iso(disb),approvedamt,term,apr,emi])
    dues=[plus_month(disb,m) for m in range(1,13)]
    # Sudden unobserved disruption, ordinary late payments, partial payments and cures.
    shock=bool(rng.random()<sigmoid(risklog))
    shockstart=int(rng.integers(1,9)); shockend=shockstart+int(rng.integers(4,8))
    cumcash=0.0; maxdpd=0; firstdefault=None; late_months=0
    for m,due in enumerate(dues,1):
        snapshot=due+pd.offsets.MonthEnd(0)
        bill=money(m*emi); owed=money(bill-cumcash)
        shocked=shock and shockstart<=m<=shockend
        if shocked: cash=money(emi*rng.choice([0,.15,.35],p=[.68,.21,.11]))
        elif rng.random()<sigmoid(-3.3+.45*stability+.7*max(foir-.5,0)):
            cash=money(emi*rng.choice([0,.5,.8],p=[.25,.4,.35]))
        else:
            catchup=1 if rng.random()<.68 else rng.uniform(.1,.7)
            cash=money(min(owed,emi+max(0,owed-emi)*catchup))
        cash=min(cash,owed); cumcash=money(cumcash+cash); arrears=money(bill-cumcash)
        fullycovered=min(m,int((cumcash+.001)//emi))
        dpd=max(0,(snapshot-dues[fullycovered]).days) if arrears>.01 else 0
        maxdpd=max(maxdpd,dpd); late_months+=int(dpd>0)
        if dpd>=90 and firstdefault is None: firstdefault=iso(snapshot)
        repayments.append([loan,aid,m,iso(due),iso(snapshot),emi,cash,bill,cumcash,arrears,dpd])
    outcomes.append([aid,loan,12,iso(dues[-1]+pd.offsets.MonthEnd(0)),int(firstdefault is not None),firstdefault,maxdpd,late_months])

tables={
 'dim_city':citydf,
 'applications':pd.DataFrame(apps,columns=['Application_ID','Applicant_ID','Application_Date','Cohort','City_ID','Age','Employment_Type','Employment_Sector','Employment_Tenure_Years','Housing_Status','Dependents','Monthly_Income_INR','Monthly_Living_Expenses_INR','Loan_Purpose','Requested_Amount_INR','Requested_Term_Months','Application_Channel']),
 'prior_credit_accounts':pd.DataFrame(bureau,columns=['Credit_Account_ID','Application_ID','Snapshot_Date','Account_Type','Opened_Date','Account_Status','Closed_Date','Original_Amount_INR','Credit_Limit_INR','Outstanding_Balance_INR','Monthly_Obligation_INR','Late_Payments_Last12M','Max_DPD_Last12M']),
 'bureau_summary':pd.DataFrame(summaries,columns=['Application_ID','Snapshot_Date','Prior_Account_Count','Active_Account_Count','Credit_History_Months','Synthetic_Credit_Score','Total_Outstanding_INR','Existing_Monthly_Obligation_INR','Card_Utilisation_Ratio','Total_Late_Payments_Last12M','Max_Prior_DPD_Last12M','Enquiries_Last6M']),
 'application_decisions':pd.DataFrame(decisions,columns=['Application_ID','Decision_Date','Decision','Decision_Reason']),
 'loan_originations':pd.DataFrame(originations,columns=['Loan_ID','Application_ID','Disbursement_Date','Disbursed_Amount_INR','Term_Months','Annual_Interest_Rate','Scheduled_EMI_INR']),
 'monthly_repayments':pd.DataFrame(repayments,columns=['Loan_ID','Application_ID','Month_Number','Due_Date','Snapshot_Date','Scheduled_Amount_INR','Paid_During_Month_INR','Cumulative_Scheduled_INR','Cumulative_Paid_INR','Arrears_INR','Days_Past_Due']),
 'loan_outcomes':pd.DataFrame(outcomes,columns=['Application_ID','Loan_ID','Observed_Months','Observation_End_Date','Default_90DPD_12M','First_Default_Snapshot','Max_DPD_12M','Months_With_Arrears_12M'])}
for name,df in tables.items():
    # Nullable counts remain integers in CSV, not misleading strings such as 1.0.
    for c in df:
        if c in ['Synthetic_Credit_Score','Default_90DPD_12M','Max_DPD_12M','Months_With_Arrears_12M']:
            df[c]=df[c].astype('Int64')
    write(df,name)

# Learning copy: untouched reference tables remain separate and reproducible.
raw=tables['applications'].copy()
ix=rng.choice(N,180,replace=False); raw.loc[ix,'Employment_Type']=raw.loc[ix,'Employment_Type'].map(lambda x:' '+x.upper()+' ')
ix=rng.choice(N,120,replace=False); raw.loc[ix,'Loan_Purpose']=' '
ix=rng.choice(N,90,replace=False); raw.loc[ix,'Employment_Tenure_Years']=np.nan
ix=rng.choice(N,40,replace=False); raw.loc[ix,'Monthly_Income_INR']=-raw.loc[ix,'Monthly_Income_INR']
raw=pd.concat([raw,raw.sample(150,random_state=SEED)],ignore_index=True)
write(raw,'applications_raw','raw_practice')

# Modelling views: only as-of-application fields plus explicitly marked label/split.
features=tables['applications'].merge(tables['bureau_summary'].drop(columns='Snapshot_Date'),on='Application_ID',validate='one_to_one')
model=features.merge(tables['loan_outcomes'][['Application_ID','Default_90DPD_12M']],on='Application_ID',validate='one_to_one')
labelled=model[model.Default_90DPD_12M.notna()].copy()
labelled['Suggested_Split']=np.where(labelled.Application_Date<'2024-07-01','Train',np.where(labelled.Application_Date<'2025-01-01','Validation','Test'))
write(labelled,'model_training')
write(features[features.Cohort=='New_Scoring'],'new_applicants_to_score')

# Concrete integrity checks, including recomputing the label from performance.
checks={}
def check(name,ok):
    checks[name]=bool(ok)
    assert bool(ok),name
app=tables['applications']; cr=tables['prior_credit_accounts']; rep=tables['monthly_repayments']; orig=tables['loan_originations']; out=tables['loan_outcomes']; dec=tables['application_decisions']
check('30000 unique applications',len(app)==N and app.Application_ID.is_unique)
check('6000 new unlabeled applicants',len(features[features.Cohort=='New_Scoring'])==6000)
check('at least 10000 labeled historical applications',len(labelled)>=10000)
for name,df in tables.items():
    if 'Application_ID' in df: check(name+' application foreign keys',df.Application_ID.isin(app.Application_ID).all())
check('unique credit account keys',cr.Credit_Account_ID.is_unique)
check('unique loan keys',orig.Loan_ID.is_unique)
check('one loan per approved application',set(orig.Application_ID)==set(dec.loc[dec.Decision=='Approved','Application_ID']))
check('monthly repayment foreign keys',set(rep.Loan_ID)==set(orig.Loan_ID))
check('12 distinct monthly rows per issued loan',rep.groupby('Loan_ID').Month_Number.nunique().eq(12).all() and not rep.duplicated(['Loan_ID','Month_Number']).any())
check('no prior credit account opened after application', (cr.Opened_Date<cr.Snapshot_Date).all())
check('closed accounts closed before application',(cr.loc[cr.Account_Status=='Closed','Closed_Date']<cr.loc[cr.Account_Status=='Closed','Snapshot_Date']).all())
check('no future repayment snapshots',(rep.Snapshot_Date<=iso(AS_OF)).all())
check('cash cannot exceed billed amount',(rep.Cumulative_Paid<=rep.Cumulative_Scheduled_INR+.01).all() if 'Cumulative_Paid' in rep else (rep.Cumulative_Paid_INR<=rep.Cumulative_Scheduled_INR+.01).all())
check('arrears reconciliation',np.allclose(rep.Arrears_INR,rep.Cumulative_Scheduled_INR-rep.Cumulative_Paid_INR,atol=.011))
check('cumulative cash reconciliation',np.allclose(rep.groupby('Loan_ID').Paid_During_Month_INR.cumsum(),rep.Cumulative_Paid_INR,atol=.011))
recalc=rep.groupby('Application_ID').Days_Past_Due.max().ge(90).astype(int)
check('default labels agree with monthly arrears',out.set_index('Application_ID').loc[recalc.index,'Default_90DPD_12M'].astype(int).eq(recalc).all())
check('rejected and pending have no invented outcome',out.loc[out.Loan_ID.isna(),'Default_90DPD_12M'].isna().all())
roll=cr.groupby('Application_ID').Monthly_Obligation_INR.sum().reindex(app.Application_ID,fill_value=0).to_numpy()
check('bureau obligations reconcile',np.allclose(roll,tables['bureau_summary'].Existing_Monthly_Obligation_INR,atol=.011))
check('valid ages and employment tenure',(app.Age>=21).all() and (app.Employment_Tenure_Years<=app.Age-18).all())
check('training views contain no future fields',not any(c in labelled for c in ['Decision','Decision_Reason','Annual_Interest_Rate','Max_DPD_12M','Months_With_Arrears_12M','Disbursed_Amount_INR']))
stats={'seed':SEED,'as_of_date':iso(AS_OF),'rows':{k:len(v) for k,v in tables.items()},'model_training_rows':len(labelled),'new_scoring_rows':6000,'historical_rejected':int((dec.Decision=='Rejected').sum()),'default_count':int(labelled.Default_90DPD_12M.sum()),'default_rate':float(labelled.Default_90DPD_12M.mean()),'split_counts':labelled.Suggested_Split.value_counts().to_dict(),'checks':checks}
(ROOT/'documentation/validation_report.json').write_text(json.dumps(stats,indent=2))

# Field dictionary: units, grain and availability are essential to correct analysis.
descriptions={
'Applicant_ID':'Fictional person identifier. One unique applicant per application; not a model predictor.',
'Application_ID':'Application primary/foreign key. Identifier, not a model predictor.',
'Cohort':'Historical (2023 to June 2025) or New_Scoring (August 2026). Routing metadata, not a predictor.',
'Synthetic_Credit_Score':'Simulated bureau-style score, 300-900. NOT a CIBIL score. Missing for applicants with no prior accounts.',
'Card_Utilisation_Ratio':'Active card balances / active card limits; 0-1. Missing if no active card limit, not zero.',
'Prior_Account_Count':'Number of prior bureau accounts. Zero is a valid thin-file applicant.',
'Credit_History_Months':'Floor of longest account age in days / 30; 0 for no history.',
'Existing_Monthly_Obligation_INR':'Sum of current monthly obligations on prior accounts; includes simplified card minimums.',
'Late_Payments_Last12M':'Count of late payments in available prior-account history, up to 12 months.',
'Total_Late_Payments_Last12M':'Sum of account late-payment counts; may exceed 12 across multiple accounts.',
'Max_Prior_DPD_Last12M':'Maximum prior-account days past due over the available last 12 months; before this application.',
'Max_DPD_Last12M':'Prior-account maximum delinquency in available last 12 months. Not delinquency on the new loan.',
'Monthly_Income_INR':'Monthly income available at application; scenario assumption, not verified bank data.',
'Monthly_Living_Expenses_INR':'Estimated monthly household living expense, excluding existing debt payments.',
'Annual_Interest_Rate':'Annual nominal loan interest rate expressed as a fraction, e.g. 0.15 = 15%. Post-decision; exclude from applicant model.',
'Scheduled_EMI_INR':'Reducing-balance EMI = principal*r/(1-(1+r)^(-term)), rounded to paise; r=annual nominal rate/12.',
'Credit_Limit_INR':'Prior card credit limit; 0 for installment loans. Closed-card original limit can remain recorded.',
'Monthly_Obligation_INR':'Simplified existing obligation: 5% card balance or original installment amount; 0 if closed.',
'Default_90DPD_12M':'1 if any of first 12 month-end observations has DPD >=90; 0 if all 12 observed without threshold; blank when no loan issued. Target, NEVER an input.',
'Days_Past_Due':'Calendar days between month-end snapshot and oldest not-fully-paid installment due date, using FIFO cash allocation; zero if fully current.',
'First_Default_Snapshot':'First observed month-end DPD >=90, not exact daily crossing date; remains recorded even after cure.',
'Observed_Months':'12 for issued historical loans, 0 for rejected or pending applications.',
'Arrears_INR':'Cumulative scheduled installments minus cumulative cash paid. Includes interest; NOT principal outstanding or credit loss.',
'Paid_During_Month_INR':'Cash toward installments received by this snapshot, capped at billed outstanding. May exceed one EMI during cure.',
'Decision_Reason':'Simplified synthetic policy reason; post-application decision output. Never use as applicant predictor.',
'Suggested_Split':'Chronological modelling partition: Train before July 2024, Validation July-Dec 2024, Test Jan-June 2025. Not a predictor.',
'Closed_Date':'Blank for active prior accounts; otherwise before application snapshot.',
'Enquiries_Last6M':'Simulated bureau enquiry count available before application.',
'Months_With_Arrears_12M':'Number of 12 performance snapshots with Days_Past_Due >0. Post-outcome field.',
'Disbursed_Amount_INR':'Actual issued amount; can be below request. Post-decision, not applicant-time feature.'}
dictionary=[]
alltables={**tables,'model_training':labelled,'new_applicants_to_score':features[features.Cohort=='New_Scoring']}
post={'application_decisions','loan_originations','monthly_repayments','loan_outcomes'}
for name,df in alltables.items():
    for c in df:
        role='Post-application: exclude from model inputs' if name in post else 'Available at application'
        if c in ['Application_ID','Applicant_ID','City_ID','Credit_Account_ID','Loan_ID','Cohort','Suggested_Split']: role='Identifier or routing metadata'
        if c=='Default_90DPD_12M':role='Prediction target; never predictor'
        dtype='DATE' if 'Date' in c or c=='First_Default_Snapshot' else 'BIGINT' if pd.api.types.is_integer_dtype(df[c]) else 'DECIMAL(18,4)' if pd.api.types.is_numeric_dtype(df[c]) else 'VARCHAR(120)'
        desc=descriptions.get(c,c.replace('_',' ')+('. Currency: INR.' if c.endswith('_INR') else '.'))
        dictionary.append([name,c,dtype,role,desc])
pd.DataFrame(dictionary,columns=['Table','Column','Suggested_SQL_Type','Availability','Description']).to_csv(ROOT/'documentation/data_dictionary.csv',index=False)

# Import-oriented staging schema: no destructive DROP statements.
ddl=['-- SYNTHETIC DATA ONLY. Run inside your chosen SQL Server database.','-- Import CSV headers separately; empty fields should become NULL.','-- Raw staging deliberately uses text to preserve anomalies for cleaning.']
for name,df in tables.items():
    cols=[]
    for c in df:
        rec=next(x for x in dictionary if x[0]==name and x[1]==c)
        cols.append(f'    [{c}] {rec[2]} NULL')
    ddl.append(f"CREATE TABLE dbo.[{name}] (\n"+',\n'.join(cols)+'\n);\n')
ddl.append('CREATE TABLE dbo.stg_applications_raw (\n'+',\n'.join(f'    [{c}] VARCHAR(120) NULL' for c in app.columns)+'\n);')
(ROOT/'sql/01_create_tables.sql').write_text('\n\n'.join(ddl))
print(json.dumps(stats,indent=2))
