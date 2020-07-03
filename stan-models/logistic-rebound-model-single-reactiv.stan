/* In order to test if the multiple-reactivation model is any good,
 * we have to compare it to the single reactivation model. i.e.
 * exponentially distributed reactivation time + deterministic 
 * exponential growth.
 * 
 * Abbreviations:
 * Cndl: conditional
 */


functions {
    /* A "potentially censored" normal distribution.
     * Typically used for virus load measurements 
     * that can fall below a dectection limit.
     * The type of censoring is determined by the control
     * parameter cc.
     */
    real censored_normal_lpdf(real x, real xhat, real sigma, int cc) {
        real lp;
        if ( cc == 0 ) {
            lp = normal_lpdf(x | xhat, sigma);
        } else if ( cc == 1 ) {
            lp = normal_lcdf(x | xhat, sigma);
        } else if ( cc == 2 ) {
            lp = normal_lccdf(x | xhat, sigma);
        } else if ( cc == 3 ) {
            lp = 0;
        } else {
            reject("invalid censor code");
        }
        return lp;
    }
    vector log_logistic_model(vector ts, real r, real logK, 
            real logTheta, real log1mTheta, real tm) {
        vector[num_elements(ts)] xs;
        for ( j in 1:num_elements(ts) ) {
            xs[j] =  logTheta + logK - log_sum_exp(-r*(ts[j]-tm) + log1mTheta, logTheta);
        }
        return xs;
    }
    vector seq(real xmin, real xmax, int n) { // n should be > 2
        real mesh; // Delta x
        if ( xmin >= xmax || n < 2 ) {
            reject("invalid parameters passed to seq function");
        }
        mesh = (xmax - xmin)/(n-1);
        return xmin - mesh + cumulative_sum(rep_vector(mesh, n));
    }
}

data {
    // Data
    int<lower=0> NumSubjects;
    int<lower=0> NumTimePts[NumSubjects];
    vector[max(NumTimePts)] TimePts[NumSubjects];
    int<lower=0> NumSimTimePts;
    vector[max(NumTimePts)] VirusLoad[NumSubjects];
    int CensorCode[NumSubjects, max(NumTimePts)];
    real<lower=0> StartART[NumSubjects]; // used as covariate for growth rate
    real<lower=0> DetectionLimit; // required for computing reboundTime
    real PriorMeanLogK;
    real<lower=0> PriorSdLogK;
    real PriorMeanLogR;
    real<lower=0> PriorSdLogR;
    real<lower=0> PriorMeanAlphaLogR;
    real<lower=0> PriorSdAlphaLogR;
    real<lower=0> MaxR;
    real<lower=0> PriorMeanSigma;
    real<lower=0> PriorSdSigma;
    // priors for the reactivation model
    real PriorMeanLogLambda;
    real<lower=0> PriorSdLogLambda;
    real PriorMeanLogVZero;
    real<lower=0> PriorSdLogVZero;
    real MaxLogVZero;
    real PriorMeanAlphaLogLambda;
    real<lower=0> PriorSdAlphaLogLambda;
    // drug washout delay
    real DrugDelay;
}

transformed data {
    // Transformed Data
    vector[NumSubjects] MeanTimePts;
    vector[max(NumTimePts)] LogVirusLoad[NumSubjects];
    real LogDetectionLimit = log(DetectionLimit);
    vector[NumSubjects] StartARTStd; // standardized StartART
    real LogMaxR = log(MaxR);
    
    for ( n in 1:NumSubjects ) {
        real x = 0.0; int k = 0;
        // only use uncensored observations
        for ( j in 1:NumTimePts[n] ) {
            if ( CensorCode[n, j] == 0 ) {
                x += TimePts[n][j]; k += 1;
            }
        }
        MeanTimePts[n] = x / k;
        LogVirusLoad[n][1:NumTimePts[n]] = log(VirusLoad[n][1:NumTimePts[n]]);
    }
    
    StartARTStd = (to_vector(StartART) - mean(StartART)) / sd(StartART);
}

parameters {
    vector<lower=LogDetectionLimit>[NumSubjects] logK;
    vector<upper=LogMaxR>[NumSubjects] logr;
    real<lower=0> sigma;
    
    real mu_logr;
    real<lower=0> sigma_logr;
    real alpha_logr; // weight of StartART
    
    real mu_logK;
    real<lower=0> sigma_logK;
    
    // reactivation model parameters
    real<upper=min({MaxLogVZero, LogDetectionLimit})> logv0;
    vector[NumSubjects] loglambda;
    real mu_loglambda;
    real<lower=0> sigma_loglambda;
    real alpha_loglambda;
    
    real<lower=0> fstReactivTime[NumSubjects];
}

transformed parameters {
    vector<upper=0>[NumSubjects] logTheta; // log(ell / K)
    vector<upper=0>[NumSubjects] log1mTheta; // log(1-ell/K)
    vector<lower=0>[NumSubjects] r;
    vector<lower=0>[NumSubjects] lambda;
    real<lower=0> v0;
    real<lower=0> reboundTime[NumSubjects];

    logTheta = LogDetectionLimit - logK;
    for ( n in 1:NumSubjects ) {
        log1mTheta[n] = log1m_exp(logTheta[n]);
    }
    
    r = exp(alpha_logr * StartARTStd + logr);
    lambda = exp(alpha_loglambda * StartARTStd + loglambda);
    
    v0 = exp(logv0);
    
    for ( n in 1:NumSubjects ) {
        // rebound time prediction under exponential growth assumption
        reboundTime[n] = DrugDelay + fstReactivTime[n] + (LogDetectionLimit - logv0) / r[n];
    }
}

model {
    for ( n in 1:NumSubjects ) {
        logr[n] ~ normal(mu_logr, sigma_logr) T[,LogMaxR];
        logK[n] ~ normal(mu_logK, sigma_logK) T[LogDetectionLimit,];
    }
    
    sigma ~ normal(PriorMeanSigma, PriorSdSigma);
    
    mu_logr ~ normal(PriorMeanLogR, PriorSdLogR); 
    sigma_logr ~ normal(0.0, PriorSdLogR);
    alpha_logr ~ normal(PriorMeanAlphaLogR, PriorSdAlphaLogR);
    
    mu_logK ~ normal(PriorMeanLogK, PriorSdLogK);
    sigma_logK ~ normal(0.0, PriorSdLogK);
    
    // priors for the reactivation model
    loglambda ~ normal(mu_loglambda, sigma_loglambda);
    mu_loglambda ~ normal(PriorMeanLogLambda, PriorSdLogLambda);
    sigma_loglambda ~ normal(0.0, PriorSdLogLambda);
    alpha_loglambda ~ normal(PriorMeanAlphaLogLambda, PriorSdAlphaLogLambda);
    
    logv0 ~ normal(PriorMeanLogVZero, PriorSdLogVZero);
       
    // likelihood of the VL observations
    for ( n in 1:NumSubjects ) {
        // auxiliary variables
        vector[NumTimePts[n]] ts = TimePts[n][1:NumTimePts[n]];
        vector[NumTimePts[n]] logVLhat = log_logistic_model(ts, r[n], 
                logK[n], logTheta[n], log1mTheta[n], reboundTime[n]);
                
        for ( i in 1:NumTimePts[n] ) {
            LogVirusLoad[n,i] ~ censored_normal(logVLhat[i], sigma, CensorCode[n,i]);
        }
    }
    
    // the first reactivation time is exponentially distributed
    for ( n in 1:NumSubjects ) {
        fstReactivTime[n] ~ exponential(lambda[n]);
    }
}

generated quantities {
    vector[NumSimTimePts] logVLhat[NumSubjects];
    vector[NumSimTimePts] logVLsim[NumSubjects];
    real timeToReboundsim[NumSubjects];
    vector[sum(NumTimePts)] loglikes;
    
    for ( n in 1:NumSubjects ) {
        vector[NumSimTimePts] simTimePts = seq(0, TimePts[n, NumTimePts[n]], NumSimTimePts);
        // simulate VL data, predict VL curves
        vector[NumSimTimePts] predictions = log_logistic_model(simTimePts, r[n], logK[n], 
                logTheta[n], log1mTheta[n], reboundTime[n]);
        logVLhat[n] = predictions;
        for ( i in 1:NumSimTimePts ) {
            logVLsim[n, i] = predictions[i] + normal_rng(0, sigma);
        }
        timeToReboundsim[n] = DrugDelay + exponential_rng(lambda[n]) + (LogDetectionLimit - logv0) / r[n];
    }
    
    // record log-likelihoods of observations for WAIC computation
    for ( n in 1:NumSubjects ) {
        // auxiliary variables
        vector[NumTimePts[n]] ts = TimePts[n][1:NumTimePts[n]];
        vector[NumTimePts[n]] xs = log_logistic_model(ts, r[n], 
                logK[n], logTheta[n], log1mTheta[n], reboundTime[n]);
        // store loglikes in the loglikes vector
        for ( i in 1:NumTimePts[n] ) {
            loglikes[sum(NumTimePts[:(n-1)])+i] = 
                    censored_normal_lpdf(LogVirusLoad[n,i] | xs[i], sigma, CensorCode[n,i]);
        }
    }
}
