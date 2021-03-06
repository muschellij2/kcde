% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/prediction.R
\name{kcde_dist_predict_given_lagged_lead_obs}
\alias{kcde_dist_predict_given_lagged_lead_obs}
\title{Make predictions from an estimated kcde model forward prediction_horizon time
steps from the end of predict_data, based on the kernel functions and
bandwidths specified in the kcde_fit object.  This function requires that the
lagged and lead observation vectors have already been computed.}
\usage{
kcde_dist_predict_given_lagged_lead_obs(train_lagged_obs, train_lead_obs,
  prediction_lagged_obs, prediction_test_lead_obs, kcde_fit, log)
}
\arguments{
\item{train_lagged_obs}{is a matrix (with column names) containing the
lagged observation vector computed from the training data.  Each row
corresponds to a time point.  Each column is a (lagged) variable.}

\item{train_lead_obs}{is a vector with length = nrow(train_lagged_obs) with
the value of the prediction target variable corresponding to each row in
the train_lagged_obs matrix.}

\item{prediction_lagged_obs}{is a matrix (with column names) containing the
lagged observation vector computed from the prediction data.  There is
one row, representing one time point.  Each column is a (lagged) variable.}

\item{prediction_test_lead_obs}{is a matrix (with column names) containing
prediction target vectors computed from the prediction data.  Each row
represents one time point.  Each column is a (leading) target variable.}

\item{kcde_fit}{is an object representing a fitted kcde model}
}
\value{
a list with three components:
    log_weights: a vector of length = length(train_lagged_obs) with
        the log of weights assigned to each observation (up to a constant of
        proportionality if normalize_weights is FALSE)
    weights: a vector of length = length(train_lagged_obs) with
        the weights assigned to each observation (up to a constant of
        proportionality if normalize_weights is FALSE)
    centers: a copy of the train_lead_obs argument -- kernel centers
}
\description{
Make predictions from an estimated kcde model forward prediction_horizon time
steps from the end of predict_data, based on the kernel functions and
bandwidths specified in the kcde_fit object.  This function requires that the
lagged and lead observation vectors have already been computed.
}

