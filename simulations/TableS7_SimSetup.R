###############################################################
# Simulation setup for Table S7 -------------------------------
# Errors in binary outcome, -----------------------------------
# Continuous covariate (multiplicative) -----------------------
# Varied differential error max -------------------------------
###############################################################

set.seed(918)

# Set sample sizes --------------------------------------------
N <- 1000 # Phase-I = N
n <- 250 # Phase-II/audit size = n

# True parameter values for P(Y|X,Z) --------------------------
beta0 <- -1
beta1 <- 1
beta2 <- -0.5

# Generate true values Y, X, Z --------------------------------
Z <- rbinom(n = N, size = 1, prob = 0.25)
X <- rnorm(n = N, mean = 0, sd = 1)
Y <- rbinom(n = N, size = 1, prob = (1 + exp(-(beta0 + beta1 * X + beta2 * Z))) ^ (- 1))

# Generate error-prone X* = X x U -----------------------------
## For U ~ Unif(0, eta0) if C = 0, ~ Unif(0, eta1) if C = 1 ---
eta0 <- 1; eta1 <- 2
U <- runif(n = N, min = 0, max = ifelse(Z == 0, eta0, eta1))
Xstar <- X * U

# Parameters for error model P(Y*|X*,Y,X,Z) -------------------
## Set sensitivity/specificity of Y* --------------------------
sensY <- 0.95; specY <- 0.90
theta0 <- - log(specY / (1 - specY))
theta1 <- - theta0 - log((1 - sensY) / sensY)
theta2 <- 1; theta3 <- 1; theta4 <- - 0.5

# Generate error-prone Y* from error model P(Y*|X*,Y,X,Z) -----
Ystar <- rbinom(n = N, size = 1, prob = (1 + exp(- (theta0 + theta1 * Y + theta2 * X + theta3 * Xstar + theta4 * Z))) ^ (- 1))

# Draw audit of size n based on design ------------------------
## Unvalidated case-control: case-control based on Y^* --------
## V is a TRUE/FALSE vector where TRUE = validated ------------
V <- seq(1, N) %in% c(sample(x = which(Ystar == 0), size = 0.5 * n, replace = FALSE),
                      sample(x = which(Ystar == 1), size = 0.5 * n, replace = FALSE))

# Build dataset ------------------------------------------------
sdat <- cbind(Y, X, Ystar, Xstar, Z, V)
# Make Phase-II variables Y, X NA for unaudited subjects -------
sdat[!V, c("Y", "X")] <- NA

# Fit models ---------------------------------------------------
## (1) Naive model ---------------------------------------------
naive <- glm(Ystar ~ Xstar + Z, family = "binomial", data = sdat)
beta_naive <- naive$coefficients[2]
se_naive <- sqrt(diag(cov(naive)))[2]

## (2) Complete data -------------------------------------------
cd <- glm(Y[V] ~ X[V] + Z[V], family = "binomial", data = sdat)
beta_cd <- cd$coefficients[2]
se_cd <- sqrt(diag(cov(cd)))[2]

## (3) Horvitz Thompson ------------------------------------
sample_wts <- ifelse(Ystar[V] == 0, 1 / ((0.5 * n) / (table(Ystar)[1])), 1 / ((0.5 * n) / (table(Ystar)[2])))
ht <- glm(Y[V] ~ X[V] + Z[V], family = "binomial", weights = sample_wts)
beta_ht <- ht$coefficients[2]
se_ht <- sqrt(diag(sandwich::sandwich(ht)))[2]

## (4) Generalized raking ----------------------------------
### Influence function for logistic regression
### Taken from: https://github.com/T0ngChen/multiwave/blob/master/sim.r
inf.fun <- function(fit) {
  dm <- model.matrix(fit)
  Ihat <- (t(dm) %*% (dm * fit$fitted.values * (1 - fit$fitted.values))) / nrow(dm)
  ## influence function
  infl <- (dm * resid(fit, type = "response")) %*% solve(Ihat)
  infl
}

naive_infl <- inf.fun(naive) # error-prone influence functions based on naive model
colnames(naive_infl) <- paste0("if", 1:3)

# Add naive influence functions to sdat -----------------------------------------------
sdat <- cbind(id = 1:N, sdat, naive_infl)
library(survey)
sstudy <- twophase(id = list(~id, ~id),
                   data = data.frame(sdat),
                   strat = list(NULL, ~Ystar),
                   subset = ~V)

# Calibrate raking weights to the sum of the naive influence functions ----------------
scal <- calibrate(sstudy, ~ if1 + if2 + if3, phase = 2, calfun = "raking")
# Fit analysis model using calibrated weights -----------------------------------------
rake <- svyglm(Y ~ X + Z, family = "binomial", design = scal)
beta_rake <- rake$coefficients[2]
se_rake <- sqrt(diag(vcov(rake)))[2]

## (5) SMLE ------------------------------------------------
### Construct B-spline basis -------------------------------
### We chose cubic B-splines, with 20 df for N = 1000 ------
nsieve <- 20
B <- matrix(0, nrow = N, ncol = nsieve)
B[which(Z == 0),1:(0.75 * nsieve)] <- splines::bs(x = Xstar[which(Z == 0)], df = 0.75 * nsieve, Boundary.knots = range(Xstar[which(Z == 0)]), intercept = TRUE)
B[which(Z == 1),(0.75 * nsieve + 1):nsieve] <- splines::bs(x = Xstar[which(Z == 1)], df = 0.25 * nsieve, Boundary.knots = range(Xstar[which(Z == 1)]), intercept = TRUE)
colnames(B) <- paste0("bs", seq(1, nsieve))
sdat <- cbind(sdat, B)

### R package: implementation of proposed SMLE approach ----
### To download the package, run: devtools::install_github("sarahlotspeich/logreg2ph")
library("logreg2ph")
smle <- logreg2ph(Y_unval = "Ystar",
                  Y_val = "Y",
                  X_unval = "Xstar",
                  X_val = "X",
                  C = "Z",
                  Validated = "V",
                  Bspline = colnames(B),
                  data = sdat,
                  noSE = FALSE,
                  MAX_ITER = 1000,
                  TOL = 1E-4)
beta_smle <- smle$Coefficients$Coefficient[2]
se_smle <- smle$Coefficients$SE[2]