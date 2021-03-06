library(cdcfluview)
library(dplyr)
library(lubridate)
library(ggplot2)
library(grid)
library(kcde)
library(proftools)
library(doMC)


usflu<-get_flu_data("national", "ilinet", years=1997:2015)
ili_national <- transmute(usflu,
    region.type = REGION.TYPE,
    region = REGION,
    year = YEAR,
    week = WEEK,
    total_cases = as.numeric(X..WEIGHTED.ILI))
ili_national$time <- ymd(paste(ili_national$year, "01", "01", sep = "-"))
week(ili_national$time) <- ili_national$week
ili_national$time_index <- seq_len(nrow(ili_national))

str(ili_national)

## separate kernel components for lagged total cases and leading total cases
kernel_components <- list(
    list(
        vars_and_offsets = data.frame(var_name = "time_index",
            offset_value = 0L,
            offset_type = "lag",
            combined_name = "time_index_lag0",
            stringsAsFactors = FALSE),
        kernel_fn = periodic_kernel,
        theta_fixed = list(period=pi / 52.2),
        theta_est = list("bw"),
        initialize_kernel_params_fn = initialize_params_periodic_kernel,
        initialize_kernel_params_args = NULL,
        vectorize_kernel_params_fn = vectorize_params_periodic_kernel,
        vectorize_kernel_params_args = NULL,
        update_theta_from_vectorized_theta_est_fn = update_theta_from_vectorized_theta_est_periodic_kernel,
        update_theta_from_vectorized_theta_est_args = NULL
    ),
    list(
        vars_and_offsets = data.frame(var_name = c("total_cases", "total_cases"),
            offset_value = c(0L, 1L),
            offset_type = c("lag", "lag"),
            combined_name = c("total_cases_lag0", "total_cases_lag1"),
            stringsAsFactors = FALSE),
        kernel_fn = pdtmvn_kernel,
        rkernel_fn = rpdtmvn_kernel,
        theta_fixed = list(
            parameterization = "bw-diagonalized-est-eigenvalues",
            continuous_vars = c("total_cases_lag0", "total_cases_lag1"),
            discrete_vars = NULL,
            discrete_var_range_fns = NULL,
            lower = c(total_cases_lag0 = -Inf, total_cases_lag1 = -Inf),
            upper = c(total_cases_lag0 = Inf, total_cases_lag1 = Inf)
        ),
        theta_est = list("bw"),
        initialize_kernel_params_fn = initialize_params_pdtmvn_kernel,
        initialize_kernel_params_args = NULL,
        vectorize_kernel_params_fn = vectorize_params_pdtmvn_kernel,
        vectorize_kernel_params_args = NULL,
        update_theta_from_vectorized_theta_est_fn = update_theta_from_vectorized_theta_est_pdtmvn_kernel,
        update_theta_from_vectorized_theta_est_args = NULL
    ),
    list(
        vars_and_offsets = data.frame(var_name = "total_cases",
            offset_value = 1L,
            offset_type = "horizon",
            combined_name = "total_cases_horizon1",
            stringsAsFactors = FALSE),
        kernel_fn = pdtmvn_kernel,
        rkernel_fn = rpdtmvn_kernel,
        theta_fixed = list(
            parameterization = "bw-diagonalized-est-eigenvalues",
            continuous_vars = "total_cases_horizon1",
            discrete_vars = NULL,
            discrete_var_range_fns = NULL,
            lower = c(total_cases_horizon1 = -Inf),
            upper = c(total_cases_horizon1 = Inf)
        ),
        theta_est = list("bw"),
        initialize_kernel_params_fn = initialize_params_pdtmvn_kernel,
        initialize_kernel_params_args = NULL,
        vectorize_kernel_params_fn = vectorize_params_pdtmvn_kernel,
        vectorize_kernel_params_args = NULL,
        update_theta_from_vectorized_theta_est_fn = update_theta_from_vectorized_theta_est_pdtmvn_kernel,
        update_theta_from_vectorized_theta_est_args = NULL
    ))


kcde_control <- create_kcde_control(X_names = "time_index",
    y_names = "total_cases",
    time_name = "time",
    prediction_horizons = 1L,
    kernel_components = kernel_components,
    crossval_buffer = ymd("2010-01-01") - ymd("2009-01-01"),
    loss_fn = neg_log_score_loss,
    loss_fn_prediction_type = "distribution",
    loss_args = NULL)

#tmp_file <- tempfile()
#Rprof(tmp_file, gc.profiling = TRUE, line.profiling = TRUE)

## set up parallelization
registerDoMC(cores=3)


## estimate parameters using only data up through 2014
flu_kcde_fit_orig_scale <- kcde(data = ili_national[ili_national$year <= 2014, ],
    kcde_control = kcde_control)

#Rprof(NULL)
#pd <- readProfileData(tmp_file)
#options(width = 300)
#hotPaths(pd, maxdepth = 27)


## sample from predictive distribution for first week in 2015
predictive_sample <- kcde_predict(kcde_fit = flu_kcde_fit_orig_scale,
        prediction_data = ili_national[ili_national$year == 2014 & ili_national$week == 53, , drop = FALSE],
        leading_rows_to_drop = 0,
        trailing_rows_to_drop = 1L,
        additional_training_rows_to_drop = NULL,
        prediction_type = "sample",
        n = 10000L)

ggplot() +
	geom_density(aes(x = predictive_sample)) +
	geom_vline(aes(xintercept = ili_national$total_cases[ili_national$year == 2015 & ili_national$week == 1]),
		colour = "red") +
	xlab("Total Cases") +
	ylab("Predictive Density") +
	ggtitle("Realized total cases vs. one week ahead predictive density\nWeek 1 of 2015") +
	theme_bw()



## obtain kernel weights and centers
debug(kcde_kernel_centers_and_weights_predict_given_lagged_obs)
predictive_kernel_weights_and_centers <- kcde_predict(kcde_fit = flu_kcde_fit_orig_scale,
    prediction_data = ili_national[ili_national$year == 2014 & ili_national$week == 53, , drop = FALSE],
    leading_rows_to_drop = 0,
    trailing_rows_to_drop = 1L,
    additional_training_rows_to_drop = NULL,
    prediction_type = "centers-and-weights")




ggplot() +
    geom_point(aes(x = predictive_kernel_weights_and_centers$centers[, 1],
        y = predictive_kernel_weights_and_centers$weights)) +
    theme_bw()


matching_predictive_value <- compute_offset_obs_vecs(data = flu_kcde_fit_orig_scale$train_data,
    vars_and_offsets = flu_kcde_fit_orig_scale$vars_and_offsets,
    time_name = flu_kcde_fit_orig_scale$kcde_control$time_name,
    leading_rows_to_drop = 0,
    trailing_rows_to_drop = 1L,
    additional_rows_to_drop = NULL,
    na.action = flu_kcde_fit_orig_scale$kcde_control$na.action)

ggplot() +
    geom_point(aes(y = predictive_kernel_weights_and_centers$centers[, 1],
            x = matching_predictive_value$total_cases_lag0,
            alpha = predictive_kernel_weights_and_centers$weights)) +
    theme_bw()







## One kernel component for lagged total cases and leading total cases
kernel_components <- list(
    list(
        vars_and_offsets = data.frame(var_name = "time_index",
            offset_value = 0L,
            offset_type = "lag",
            combined_name = "time_index_lag0",
            stringsAsFactors = FALSE),
        kernel_fn = periodic_kernel,
        theta_fixed = list(period=pi / 52.2),
        theta_est = list("bw"),
        initialize_kernel_params_fn = initialize_params_periodic_kernel,
        initialize_kernel_params_args = NULL,
        vectorize_kernel_params_fn = vectorize_params_periodic_kernel,
        vectorize_kernel_params_args = NULL,
        update_theta_from_vectorized_theta_est_fn = update_theta_from_vectorized_theta_est_periodic_kernel,
        update_theta_from_vectorized_theta_est_args = NULL
    ),
    list(
        vars_and_offsets = data.frame(var_name = c("total_cases", "total_cases", "total_cases"),
            offset_value = c(0L, 1L, 1L),
            offset_type = c("lag", "lag", "horizon"),
            combined_name = c("total_cases_lag0", "total_cases_lag1", "total_cases_horizon1"),
            stringsAsFactors = FALSE),
        kernel_fn = pdtmvn_kernel,
        rkernel_fn = rpdtmvn_kernel,
        theta_fixed = list(
            parameterization = "bw-diagonalized-est-eigenvalues",
            continuous_vars = c("total_cases_lag0", "total_cases_lag1", "total_cases_horizon1"),
            discrete_vars = NULL,
            discrete_var_range_fns = NULL,
            lower = c(total_cases_lag0 = -Inf, total_cases_lag1 = -Inf, total_cases_horizon1 = -Inf),
            upper = c(total_cases_lag0 = Inf, total_cases_lag1 = Inf, total_cases_horizon1 = Inf)
        ),
        theta_est = list("bw"),
        initialize_kernel_params_fn = initialize_params_pdtmvn_kernel,
        initialize_kernel_params_args = NULL,
        vectorize_kernel_params_fn = vectorize_params_pdtmvn_kernel,
        vectorize_kernel_params_args = NULL,
        update_theta_from_vectorized_theta_est_fn = update_theta_from_vectorized_theta_est_pdtmvn_kernel,
        update_theta_from_vectorized_theta_est_args = NULL
    ))


kcde_control <- create_kcde_control(X_names = "time_index",
    y_names = "total_cases",
    time_name = "time",
    prediction_horizons = 1L,
    kernel_components = kernel_components,
    crossval_buffer = ymd("2010-01-01") - ymd("2009-01-01"),
    loss_fn = neg_log_score_loss,
    loss_fn_prediction_type = "distribution",
    loss_args = NULL)

#tmp_file <- tempfile()
#Rprof(tmp_file, gc.profiling = TRUE, line.profiling = TRUE)

## set up parallelization
registerDoMC(cores=3)


## estimate parameters using only data up through 2014
flu_kcde_fit_orig_scale <- kcde(data = ili_national[ili_national$year <= 2014, ],
    kcde_control = kcde_control)

#Rprof(NULL)
#pd <- readProfileData(tmp_file)
#options(width = 300)
#hotPaths(pd, maxdepth = 27)


## sample from predictive distribution for first week in 2015
predictive_sample <- kcde_predict(kcde_fit = flu_kcde_fit_orig_scale,
    prediction_data = ili_national[ili_national$year == 2014 & ili_national$week %in% c(52, 53), , drop = FALSE],
    leading_rows_to_drop = 1L,
    trailing_rows_to_drop = 1L,
    additional_training_rows_to_drop = NULL,
    prediction_type = "sample",
    n = 10000L)

ggplot() +
    geom_density(aes(x = predictive_sample)) +
    geom_vline(aes(xintercept = ili_national$total_cases[ili_national$year == 2015 & ili_national$week == 1]),
        colour = "red") +
    xlab("Total Cases") +
    ylab("Predictive Density") +
    ggtitle("Realized total cases vs. one week ahead predictive density\nWeek 1 of 2015") +
    theme_bw()



## obtain kernel weights and centers
predictive_kernel_weights_and_centers <- kcde_predict(kcde_fit = flu_kcde_fit_orig_scale,
    prediction_data = ili_national[ili_national$year == 2014 & ili_national$week %in% c(52, 53), , drop = FALSE],
    leading_rows_to_drop = 1L,
    trailing_rows_to_drop = 1L,
    additional_training_rows_to_drop = NULL,
    prediction_type = "centers-and-weights")




ggplot() +
    geom_point(aes(x = predictive_kernel_weights_and_centers$centers[, 1],
            y = predictive_kernel_weights_and_centers$weights)) +
    theme_bw()


matching_predictive_value <- compute_offset_obs_vecs(data = flu_kcde_fit_orig_scale$train_data,
    vars_and_offsets = flu_kcde_fit_orig_scale$vars_and_offsets,
    time_name = flu_kcde_fit_orig_scale$kcde_control$time_name,
    leading_rows_to_drop = 1L,
    trailing_rows_to_drop = 1L,
    additional_rows_to_drop = NULL,
    na.action = flu_kcde_fit_orig_scale$kcde_control$na.action)

ggplot() +
    geom_point(aes(y = predictive_kernel_weights_and_centers$centers[, 1],
            x = matching_predictive_value$total_cases_lag0,
            alpha = predictive_kernel_weights_and_centers$weights)) +
    theme_bw()







## With filtering, one kernel component for lagged total cases and leading total cases
options(error = recover)

library(cdcfluview)
library(dplyr)
library(lubridate)
library(ggplot2)
library(grid)
library(kcde)
library(proftools)
library(doMC)


usflu<-get_flu_data("national", "ilinet", years=1997:2015)
ili_national <- transmute(usflu,
    region.type = REGION.TYPE,
    region = REGION,
    year = YEAR,
    week = WEEK,
    total_cases = as.numeric(X..WEIGHTED.ILI))
ili_national$time <- ymd(paste(ili_national$year, "01", "01", sep = "-"))
week(ili_national$time) <- ili_national$week
ili_national$time_index <- seq_len(nrow(ili_national))

kernel_components <- list(
#    list(
#        vars_and_offsets = data.frame(var_name = "time_index",
#            offset_value = 0L,
#            offset_type = "lag",
#            combined_name = "time_index_lag0",
#            stringsAsFactors = FALSE),
#        kernel_fn = periodic_kernel,
#        theta_fixed = list(period=pi / 52.2),
#        theta_est = list("bw"),
#        initialize_kernel_params_fn = initialize_params_periodic_kernel,
#        initialize_kernel_params_args = NULL,
#        vectorize_kernel_params_fn = vectorize_params_periodic_kernel,
#        vectorize_kernel_params_args = NULL,
#        update_theta_from_vectorized_theta_est_fn = update_theta_from_vectorized_theta_est_periodic_kernel,
#        update_theta_from_vectorized_theta_est_args = NULL
#    ),
    list(
        vars_and_offsets = data.frame(var_name = c("filtered_total_cases", "filtered_total_cases", "total_cases"),
            offset_value = c(0L, 1L, 1L),
            offset_type = c("lag", "lag", "horizon"),
            combined_name = c("filtered_total_cases_lag0", "filtered_total_cases_lag1", "total_cases_horizon1"),
            stringsAsFactors = FALSE),
#        vars_and_offsets = data.frame(var_name = c("filtered_total_cases", "total_cases"),
#            offset_value = c(1L, 1L),
#            offset_type = c("lag", "horizon"),
#            combined_name = c("filtered_total_cases_lag1", "total_cases_horizon1"),
#            stringsAsFactors = FALSE),
        kernel_fn = pdtmvn_kernel,
        rkernel_fn = rpdtmvn_kernel,
        theta_fixed = list(
            parameterization = "bw-diagonalized-est-eigenvalues",
            continuous_vars = c("filtered_total_cases_lag0", "filtered_total_cases_lag1", "total_cases_horizon1"),
            discrete_vars = NULL,
            discrete_var_range_fns = NULL,
            lower = c(filtered_total_cases_lag0 = -Inf,
                filtered_total_cases_lag1 = -Inf,
                total_cases_horizon1 = -Inf),
            upper = c(filtered_total_cases_lag0 = Inf,
                filtered_total_cases_lag1 = Inf,
                total_cases_horizon1 = Inf)
        ),
        theta_est = list("bw"),
        initialize_kernel_params_fn = initialize_params_pdtmvn_kernel,
        initialize_kernel_params_args = NULL,
        vectorize_kernel_params_fn = vectorize_params_pdtmvn_kernel,
        vectorize_kernel_params_args = NULL,
        update_theta_from_vectorized_theta_est_fn = update_theta_from_vectorized_theta_est_pdtmvn_kernel,
        update_theta_from_vectorized_theta_est_args = NULL
    ))

#filter_control <- list(
#    list(
#        var_name = "total_cases",
#        max_filter_window_size = 13,
##        filter_fn = stats::filter, # signal::filter throws error on internal NAs
#        filter_fn = two_pass_filter,
#        fixed_filter_params = list(
#            n = 12,
#            ftype = "bandpass",
#            density = 16
#        ),
#        filter_args_fn = compute_filter_args_pm_opt_filter,
#        filter_args_args = NULL,
#        initialize_filter_params_fn = initialize_filter_params_pm_opt_filter,
#        initialize_filter_params_args = NULL,
#        vectorize_filter_params_fn = vectorize_filter_params_pm_opt_filter,
#        vectorize_filter_params_args = NULL,
#        update_filter_params_from_vectorized_fn = update_filter_params_from_vectorized_pm_opt_filter,
#        update_filter_params_from_vectorized_args = NULL
#    )
#)




filter_control <- list(
    list(
        var_name = "total_cases",
        max_filter_window_size = 13,
        filter_fn = two_pass_signal_filter,
        fixed_filter_params = list(
            n = 12,
            type = "pass",
            impute_fn = interior_linear_interpolation
        ),
        filter_args_fn = compute_filter_args_butterworth_filter,
        filter_args_args = NULL,
        initialize_filter_params_fn = initialize_filter_params_butterworth_filter,
        initialize_filter_params_args = NULL,
        vectorize_filter_params_fn = vectorize_filter_params_butterworth_filter,
        vectorize_filter_params_args = NULL,
        update_filter_params_from_vectorized_fn = update_filter_params_from_vectorized_butterworth_filter,
        update_filter_params_from_vectorized_args = NULL,
        transform_fn = log,
        detransform_fn = exp
    )
)


kcde_control <- create_kcde_control(X_names = "time_index",
    y_names = "total_cases",
    time_name = "time",
    prediction_horizons = 1L,
    filter_control = filter_control,
    kernel_components = kernel_components,
    crossval_buffer = ymd("2010-01-01") - ymd("2009-01-01"),
    loss_fn = neg_log_score_loss,
    loss_fn_prediction_args = list(
        prediction_type = "distribution",
        log = TRUE),
    loss_args = NULL)

#tmp_file <- tempfile()
#Rprof(tmp_file, gc.profiling = TRUE, line.profiling = TRUE)

## set up parallelization
registerDoMC(cores=3)


## estimate parameters using only data up through 2014
#debug(compute_filter_values)
#debug(est_kcde_params_stepwise_crossval)
flu_kcde_fit_orig_scale <- kcde(data = ili_national[ili_national$year <= 2014, ],
    kcde_control = kcde_control)

#Rprof(NULL)
#pd <- readProfileData(tmp_file)
#options(width = 300)
#hotPaths(pd, maxdepth = 27)

analysis_time_ind <- which(ili_national$year == 2014 & ili_national$week == 53)

density_eval_points <- matrix(seq(from = 0.01, to = 10, length = 100))
colnames(density_eval_points) <- "total_cases_horizon1"
eval_density <- kcde_predict(kcde_fit = flu_kcde_fit_orig_scale,
    prediction_data = ili_national[seq_len(analysis_time_ind), , drop = FALSE],
    leading_rows_to_drop = 0L,
    trailing_rows_to_drop = 0L,
    additional_training_rows_to_drop = NULL,
    prediction_type = "distribution",
    prediction_test_lead_obs = density_eval_points)

ggplot() +
    geom_line(aes(x = density_eval_points[, 1], y = eval_density)) +
    geom_vline(aes(xintercept = ili_national$total_cases[ili_national$year == 2015 & ili_national$week == 1]),
        colour = "red") +
    xlab("Total Cases") +
    ylab("Predictive Density") +
    ggtitle("Realized total cases vs. one week ahead predictive density\nWeek 1 of 2015") +
    theme_bw()


## sample from predictive distribution for first week in 2015
predictive_sample <- kcde_predict(kcde_fit = flu_kcde_fit_orig_scale,
    prediction_data = ili_national[seq_len(analysis_time_ind), , drop = FALSE],
    leading_rows_to_drop = 0L,
    trailing_rows_to_drop = 0L,
    additional_training_rows_to_drop = NULL,
    prediction_type = "sample",
    n = 10000L)

ggplot() +
    geom_density(aes(x = predictive_sample)) +
    geom_vline(aes(xintercept = ili_national$total_cases[ili_national$year == 2015 & ili_national$week == 1]),
        colour = "red") +
    xlab("Total Cases") +
    ylab("Predictive Density") +
    ggtitle("Realized total cases vs. one week ahead predictive density\nWeek 1 of 2015") +
    theme_bw()



ggplot() +
    geom_density(aes(x = predictive_sample)) +
    geom_line(aes(x = density_eval_points[, 1], y = eval_density), colour = "blue") +
    geom_vline(aes(xintercept = ili_national$total_cases[ili_national$year == 2015 & ili_national$week == 1]),
        colour = "red") +
    xlab("Total Cases") +
    ylab("Predictive Density") +
    ggtitle("Realized total cases vs. one week ahead predictive density\nWeek 1 of 2015") +
    theme_bw()


## obtain kernel weights and centers
predictive_kernel_weights_and_centers <- kcde_predict(kcde_fit = flu_kcde_fit_orig_scale,
    prediction_data = ili_national[seq_len(analysis_time_ind), , drop = FALSE],
    leading_rows_to_drop = 1L,
    trailing_rows_to_drop = 1L,
    additional_training_rows_to_drop = NULL,
    prediction_type = "centers-and-weights")




ggplot() +
    geom_point(aes(x = predictive_kernel_weights_and_centers$centers[, 1],
            y = predictive_kernel_weights_and_centers$weights)) +
    theme_bw()


matching_predictive_value <- compute_offset_obs_vecs(data = flu_kcde_fit_orig_scale$train_data,
    filter_control = flu_kcde_fit_orig_scale$kcde_control$filter_control,
    phi = flu_kcde_fit_orig_scale$phi_hat,
    vars_and_offsets = flu_kcde_fit_orig_scale$vars_and_offsets,
    time_name = flu_kcde_fit_orig_scale$kcde_control$time_name,
    leading_rows_to_drop = 0L,
    trailing_rows_to_drop = 0L,
    additional_rows_to_drop = NULL,
    na.action = flu_kcde_fit_orig_scale$kcde_control$na.action)



ggplot() +
    geom_point(aes(y = predictive_kernel_weights_and_centers$centers[, 1],
            x = matching_predictive_value$filtered_total_cases_lag0,
            alpha = predictive_kernel_weights_and_centers$weights)) +
    theme_bw()


analysis_time_filtered_and_offset_data <- compute_offset_obs_vecs(
    data = ili_national[seq_len(analysis_time_ind), , drop = FALSE],
    filter_control = flu_kcde_fit_orig_scale$kcde_control$filter_control,
    phi = flu_kcde_fit_orig_scale$phi_hat,
    vars_and_offsets = flu_kcde_fit_orig_scale$vars_and_offsets[flu_kcde_fit_orig_scale$vars_and_offsets$offset_type == "lag", , drop = FALSE],
    time_name = flu_kcde_fit_orig_scale$kcde_control$time_name,
    leading_rows_to_drop = 0L,
    trailing_rows_to_drop = 0L,
    additional_rows_to_drop = NULL,
    na.action = flu_kcde_fit_orig_scale$kcde_control$na.action)
analysis_time_filtered_and_offset_data <-
    analysis_time_filtered_and_offset_data[nrow(analysis_time_filtered_and_offset_data), , drop = FALSE]

ggplot() +
    geom_path(aes(y = matching_predictive_value$filtered_total_cases_lag0,
            x = matching_predictive_value$filtered_total_cases_lag1),
        colour = "grey") +
    geom_point(aes(y = matching_predictive_value$filtered_total_cases_lag0,
            x = matching_predictive_value$filtered_total_cases_lag1,
            alpha = predictive_kernel_weights_and_centers$weights)) +
    geom_point(aes(y = analysis_time_filtered_and_offset_data$filtered_total_cases_lag0,
            x = analysis_time_filtered_and_offset_data$filtered_total_cases_lag1),
        colour = "red") +
    theme_bw()


ggplot() +
    geom_line(aes(x = time, y = total_cases),
        data = flu_kcde_fit_orig_scale$train_data) +
    geom_line(aes(x = time, y = filtered_total_cases_lag0),
        colour = "red",
        data = matching_predictive_value) +
    theme_bw()


one_pass_filter_control <- flu_kcde_fit_orig_scale$kcde_control$filter_control
one_pass_filter_control[[1]]$filter_n <- one_pass_signal_filter

one_pass_matching_predictive_value <- compute_offset_obs_vecs(data = flu_kcde_fit_orig_scale$train_data,
    filter_control = one_pass_filter_control,
    phi = flu_kcde_fit_orig_scale$phi_hat,
    vars_and_offsets = flu_kcde_fit_orig_scale$vars_and_offsets,
    time_name = flu_kcde_fit_orig_scale$kcde_control$time_name,
    leading_rows_to_drop = 0L,
    trailing_rows_to_drop = 0L,
    additional_rows_to_drop = NULL,
    na.action = flu_kcde_fit_orig_scale$kcde_control$na.action)

ggplot() +
    geom_line(aes(x = time, y = total_cases),
        data = flu_kcde_fit_orig_scale$train_data) +
    geom_line(aes(x = time, y = filtered_total_cases_lag0),
        colour = "red",
        data = matching_predictive_value) +
    geom_line(aes(x = time, y = filtered_total_cases_lag0),
        colour = "blue",
        data = one_pass_matching_predictive_value) +
    theme_bw()






## With filtering, log scale kernel, one kernel component for lagged total cases and leading total cases
options(error = recover)

library(cdcfluview)
library(dplyr)
library(lubridate)
library(ggplot2)
library(grid)
library(kcde)
library(proftools)
library(doMC)


usflu<-get_flu_data("national", "ilinet", years=1997:2015)
ili_national <- transmute(usflu,
    region.type = REGION.TYPE,
    region = REGION,
    year = YEAR,
    week = WEEK,
    total_cases = as.numeric(X..WEIGHTED.ILI))
ili_national$time <- ymd(paste(ili_national$year, "01", "01", sep = "-"))
week(ili_national$time) <- ili_national$week
ili_national$time_index <- seq_len(nrow(ili_national))

kernel_components <- list(
#    list(
#        vars_and_offsets = data.frame(var_name = "time_index",
#            offset_value = 0L,
#            offset_type = "lag",
#            combined_name = "time_index_lag0",
#            stringsAsFactors = FALSE),
#        kernel_fn = periodic_kernel,
#        theta_fixed = list(period=pi / 52.2),
#        theta_est = list("bw"),
#        initialize_kernel_params_fn = initialize_params_periodic_kernel,
#        initialize_kernel_params_args = NULL,
#        vectorize_kernel_params_fn = vectorize_params_periodic_kernel,
#        vectorize_kernel_params_args = NULL,
#        update_theta_from_vectorized_theta_est_fn = update_theta_from_vectorized_theta_est_periodic_kernel,
#        update_theta_from_vectorized_theta_est_args = NULL
#    ),
    list(
        vars_and_offsets = data.frame(var_name = c("filtered_total_cases", "filtered_total_cases", "total_cases"),
            offset_value = c(0L, 1L, 1L),
            offset_type = c("lag", "lag", "horizon"),
            combined_name = c("filtered_total_cases_lag0", "filtered_total_cases_lag1", "total_cases_horizon1"),
            stringsAsFactors = FALSE),
        kernel_fn = log_pdtmvn_kernel,
        rkernel_fn = rlog_pdtmvn_kernel,
        theta_fixed = list(
            parameterization = "bw-diagonalized-est-eigenvalues",
            continuous_vars = c("filtered_total_cases_lag0", "filtered_total_cases_lag1", "total_cases_horizon1"),
            discrete_vars = NULL,
            discrete_var_range_fns = NULL,
            lower = c(filtered_total_cases_lag0 = -Inf,
                filtered_total_cases_lag1 = -Inf,
                total_cases_horizon1 = -Inf),
            upper = c(filtered_total_cases_lag0 = Inf,
                filtered_total_cases_lag1 = Inf,
                total_cases_horizon1 = Inf)
        ),
        theta_est = list("bw"),
        initialize_kernel_params_fn = initialize_params_pdtmvn_kernel,
        initialize_kernel_params_args = NULL,
        vectorize_kernel_params_fn = vectorize_params_pdtmvn_kernel,
        vectorize_kernel_params_args = NULL,
        update_theta_from_vectorized_theta_est_fn = update_theta_from_vectorized_theta_est_pdtmvn_kernel,
        update_theta_from_vectorized_theta_est_args = NULL
    ))

#filter_control <- list(
#    list(
#        var_name = "total_cases",
#        max_filter_window_size = 13,
##        filter_fn = stats::filter, # signal::filter throws error on internal NAs
#        filter_fn = two_pass_filter,
#        fixed_filter_params = list(
#            n = 12,
#            ftype = "bandpass",
#            density = 16
#        ),
#        filter_args_fn = compute_filter_args_pm_opt_filter,
#        filter_args_args = NULL,
#        initialize_filter_params_fn = initialize_filter_params_pm_opt_filter,
#        initialize_filter_params_args = NULL,
#        vectorize_filter_params_fn = vectorize_filter_params_pm_opt_filter,
#        vectorize_filter_params_args = NULL,
#        update_filter_params_from_vectorized_fn = update_filter_params_from_vectorized_pm_opt_filter,
#        update_filter_params_from_vectorized_args = NULL
#    )
#)




filter_control <- list(
    list(
        var_name = "total_cases",
        max_filter_window_size = 13,
        filter_fn = two_pass_signal_filter,
        fixed_filter_params = list(
            n = 12,
            type = "pass",
            impute_fn = interior_linear_interpolation
        ),
        filter_args_fn = compute_filter_args_butterworth_filter,
        filter_args_args = NULL,
        initialize_filter_params_fn = initialize_filter_params_butterworth_filter,
        initialize_filter_params_args = NULL,
        vectorize_filter_params_fn = vectorize_filter_params_butterworth_filter,
        vectorize_filter_params_args = NULL,
        update_filter_params_from_vectorized_fn = update_filter_params_from_vectorized_butterworth_filter,
        update_filter_params_from_vectorized_args = NULL,
        transform_fn = log,
        detransform_fn = exp
    )
)


kcde_control <- create_kcde_control(X_names = "time_index",
    y_names = "total_cases",
    time_name = "time",
    prediction_horizons = 1L,
    filter_control = filter_control,
    kernel_components = kernel_components,
    crossval_buffer = ymd("2010-01-01") - ymd("2009-01-01"),
    loss_fn = neg_log_score_loss,
    loss_fn_prediction_type = "distribution",
    loss_args = NULL)

#tmp_file <- tempfile()
#Rprof(tmp_file, gc.profiling = TRUE, line.profiling = TRUE)

## set up parallelization
registerDoMC(cores=3)


## estimate parameters using only data up through 2014
#debug(compute_filter_values)
#debug(est_kcde_params_stepwise_crossval)
flu_kcde_fit_log_scale <- kcde(data = ili_national[ili_national$year <= 2014, ],
    kcde_control = kcde_control)

#Rprof(NULL)
#pd <- readProfileData(tmp_file)
#options(width = 300)
#hotPaths(pd, maxdepth = 27)


## sample from predictive distribution for first week in 2015
analysis_time_ind <- which(ili_national$year == 2014 & ili_national$week == 53)

flu_kcde_fit_log_scale$kcde_control$kernel_components[[1]]$rkernel_fn <- rlog_pdtmvn_kernel

predictive_sample <- kcde_predict(kcde_fit = flu_kcde_fit_log_scale,
    prediction_data = ili_national[seq_len(analysis_time_ind), , drop = FALSE],
    leading_rows_to_drop = 0L,
    trailing_rows_to_drop = 0L,
    additional_training_rows_to_drop = NULL,
    prediction_type = "sample",
    n = 100000L)

ggplot() +
    geom_density(aes(x = predictive_sample)) +
    geom_vline(aes(xintercept = ili_national$total_cases[ili_national$year == 2015 & ili_national$week == 1]),
        colour = "red") +
    xlab("Total Cases") +
    ylab("Predictive Density") +
    ggtitle("Realized total cases vs. one week ahead predictive density\nWeek 1 of 2015") +
    theme_bw()




density_eval_points <- matrix(seq(from = 0.01, to = 10, length = 100))
colnames(density_eval_points) <- "total_cases_horizon1"
eval_density <- kcde_predict(kcde_fit = flu_kcde_fit_log_scale,
    prediction_data = ili_national[seq_len(analysis_time_ind), , drop = FALSE],
    leading_rows_to_drop = 0L,
    trailing_rows_to_drop = 0L,
    additional_training_rows_to_drop = NULL,
    prediction_type = "distribution",
    prediction_test_lead_obs = density_eval_points)

ggplot() +
    geom_line(aes(x = density_eval_points[, 1], y = eval_density)) +
    geom_vline(aes(xintercept = ili_national$total_cases[ili_national$year == 2015 & ili_national$week == 1]),
        colour = "red") +
    xlab("Total Cases") +
    ylab("Predictive Density") +
    ggtitle("Realized total cases vs. one week ahead predictive density\nWeek 1 of 2015") +
    theme_bw()


## obtain kernel weights and centers
predictive_kernel_weights_and_centers <- kcde_predict(kcde_fit = flu_kcde_fit_log_scale,
    prediction_data = ili_national[seq_len(analysis_time_ind), , drop = FALSE],
    leading_rows_to_drop = 1L,
    trailing_rows_to_drop = 1L,
    additional_training_rows_to_drop = NULL,
    prediction_type = "centers-and-weights")




ggplot() +
    geom_point(aes(x = predictive_kernel_weights_and_centers$centers[, 1],
            y = predictive_kernel_weights_and_centers$weights)) +
    theme_bw()







ggplot() +
    geom_point(aes(x = predictive_kernel_weights_and_centers$centers[, 1],
            y = predictive_kernel_weights_and_centers$weights)) +
    geom_density(aes(x = predictive_sample)) +
    geom_vline(aes(xintercept = ili_national$total_cases[ili_national$year == 2015 & ili_national$week == 1]),
        colour = "red") +
    theme_bw()


ggplot() +
    geom_line(aes(x = density_eval_points[, 1], y = eval_density)) +
    geom_point(aes(x = predictive_kernel_weights_and_centers$centers[, 1],
            y = predictive_kernel_weights_and_centers$weights)) +
    geom_density(aes(x = predictive_sample), colour = "blue") +
    geom_density(aes(x = exp(predictive_sample)), colour = "red") +
    geom_vline(aes(xintercept = ili_national$total_cases[ili_national$year == 2015 & ili_national$week == 1]),
        colour = "red") +
    xlab("Total Cases") +
    ylab("Predictive Density") +
    xlim(c(0, 10)) +
    ggtitle("Realized total cases vs. one week ahead predictive density\nWeek 1 of 2015") +
    theme_bw()



matching_predictive_value <- compute_offset_obs_vecs(data = flu_kcde_fit_log_scale$train_data,
    filter_control = flu_kcde_fit_log_scale$kcde_control$filter_control,
    phi = flu_kcde_fit_log_scale$phi_hat,
    vars_and_offsets = flu_kcde_fit_log_scale$vars_and_offsets,
    time_name = flu_kcde_fit_log_scale$kcde_control$time_name,
    leading_rows_to_drop = 0L,
    trailing_rows_to_drop = 0L,
    additional_rows_to_drop = NULL,
    na.action = flu_kcde_fit_log_scale$kcde_control$na.action)



ggplot() +
    geom_point(aes(y = predictive_kernel_weights_and_centers$centers[, 1],
            x = matching_predictive_value$filtered_total_cases_lag0,
            alpha = predictive_kernel_weights_and_centers$weights)) +
    theme_bw()


analysis_time_filtered_and_offset_data <- compute_offset_obs_vecs(
    data = ili_national[seq_len(analysis_time_ind), , drop = FALSE],
    filter_control = flu_kcde_fit_log_scale$kcde_control$filter_control,
    phi = flu_kcde_fit_log_scale$phi_hat,
    vars_and_offsets = flu_kcde_fit_log_scale$vars_and_offsets[flu_kcde_fit_log_scale$vars_and_offsets$offset_type == "lag", , drop = FALSE],
    time_name = flu_kcde_fit_log_scale$kcde_control$time_name,
    leading_rows_to_drop = 0L,
    trailing_rows_to_drop = 0L,
    additional_rows_to_drop = NULL,
    na.action = flu_kcde_fit_log_scale$kcde_control$na.action)
analysis_time_filtered_and_offset_data <-
    analysis_time_filtered_and_offset_data[nrow(analysis_time_filtered_and_offset_data), , drop = FALSE]

ggplot() +
    geom_path(aes(y = matching_predictive_value$filtered_total_cases_lag0,
            x = matching_predictive_value$filtered_total_cases_lag1),
        colour = "grey") +
    geom_point(aes(y = matching_predictive_value$filtered_total_cases_lag0,
            x = matching_predictive_value$filtered_total_cases_lag1,
            colour = predictive_kernel_weights_and_centers$weights)) +
    geom_point(aes(y = analysis_time_filtered_and_offset_data$filtered_total_cases_lag0,
            x = analysis_time_filtered_and_offset_data$filtered_total_cases_lag1),
        colour = "red") +
    theme_bw()


ggplot() +
    geom_line(aes(x = time, y = total_cases),
        data = flu_kcde_fit_orig_scale$train_data) +
    geom_line(aes(x = time, y = filtered_total_cases_lag0),
        colour = "red",
        data = matching_predictive_value) +
    theme_bw()
