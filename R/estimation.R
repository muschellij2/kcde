## Functions for parameter estimation
##
## kcde
## est_kcde_params_stepwise_crossval
## est_kcde_params_stepwise_crossval_one_potential_step
## kcde_crossval_estimate_parameter_loss

#' Estimate the parameters for kcde.  There is redundancy here in that X_names,
#' y_names, time_name are all included in the kcde_control object as well as
#' parameters to this function.  Decide on an interface.
#' 
#' @param X_names a character vector of length >= 1 containing names of
#'     variables in the data data frame to use in forming the lagged
#'     observation process used for calculating weights
#' @param y_names a character vector of length 1 containing the name of the
#'     variable in the data data frame to use as the target for prediction
#' @param data a data frame where rows are consecutive observations
#' @param kcde_control a list of parameters kcde_controlling how the fit is done.
#'     See the documentation for kcde_control.
#' 
#' @return an object representing an estimated kcde model.  Currently, a list
#'     with 7 components.
kcde <- function(X_names,
        y_names,
        data,
        init_theta_vector,
        init_phi_vector,
        kcde_control) {
    ## get/validate kcde_control argument
    if(missing(kcde_control)) {
        kcde_control <- create_kcde_control_default(X_names, y_names, data)
        warning("kcde_control argument not supplied to kcde -- using defaults, which may be bad")
    } else {
        validate_kcde_control(kcde_control, X_names, y_names, data)
    }
    
    ## estimate lags and kernel parameters via cross-validation
    param_estimates <- est_kcde_params_stepwise_crossval(data=data,
        kcde_control=kcde_control,
        init_theta_vector=init_theta_vector,
        init_phi_vector=init_phi_vector)
    
    return(list(kcde_control=kcde_control,
		vars_and_offsets=param_estimates$vars_and_offsets,
        theta_hat=param_estimates$theta_hat,
        phi_hat=param_estimates$phi_hat,
        all_evaluated_models=param_estimates$all_evaluated_models,
        all_evaluated_model_descriptors=param_estimates$all_evaluated_model_descriptors,
        train_data=data))
}

#' Use a stepwise procedure to estimate parameters and select lags by optimizing
#' a cross-validation estimate of predictive performance
#' 
#' @param data the data frame to use in performing cross validation
#' @param kcde_control a list of parameters specifying how the fitting is done
#' 
#' @return a list with two components: vars_and_offsets is the estimated "optimal" lags
#'     to use for each variable, and theta_hat is the estimated "optimal"
#'     kernel parameters to use for each combination of variable and lag
est_kcde_params_stepwise_crossval <- function(data,
        kcde_control,
        init_theta_vector,
        init_phi_vector) {
    all_vars_and_offsets <- plyr::rbind.fill(lapply(kcde_control$kernel_components,
		function(kernel_component) {
			kernel_component$vars_and_offsets
		}))
    predictive_vars_and_offsets <- all_vars_and_offsets[
        all_vars_and_offsets$offset_type == "lag", , drop = FALSE]
    
    ## initialize cross-validation process
    ## the variable selected in previous iteration
    selected_var_lag_ind <- NULL
    ## cross-validation estimate of loss associated with current estimates
    crossval_prediction_loss <- Inf
    ## initial parameters: no lagged variables selected, all prediction target variables included
    current_model_vars_and_offsets <- all_vars_and_offsets[
        all_vars_and_offsets$offset_type == "horizon", , drop = FALSE]
    theta_hat <- vector("list", length(kcde_control$kernel_components))
    phi_hat <- vector("list", length(kcde_control$filter_control))
    
    all_evaluated_models <- list()
    all_evaluated_model_descriptors <- list()
    
    ## If na.action is "na.omit", we want to ensure that the same rows are dropped from all models
    ## so that we can make a reasonable comparison between models.  Here, we calculate which rows
    ## to drop based on all NA's in all variables and all lags and prediction horizons for those
    ## variables that are in the all_vars_and_offsets object.
    ## 
    ## In this process, we assume that the initial filter parameters generate all possible NAs
    ## (i.e., changing the filter parameters from their initial values could not generate more
    ## NAs.
    if(identical(kcde_control$na.action, "na.omit")) {
        all_na_drop_rows <- compute_na_rows_after_filter_and_offset(
            data = data,
            phi = phi_hat,
            vars_and_offsets = all_vars_and_offsets,
            kcde_control = kcde_control
        )
    } else {
        stop("Unsupported na.action")
    }
    
    if(identical(kcde_control$variable_selection_method, "stepwise")) {
        repeat {
            ## get cross-validation estimates of performance for model obtained by
            ## adding or removing each variable/lag combination (except for the one
            ## updated in the previous iteration) from the model, as well as the
            ## corresponding parameter estimates
            
            ## commented out use of foreach:
            ## parallelization now happens within kcde_crossval_estimate_parameter_loss
#        crossval_results <- foreach(i=seq_len(nrow(predictive_vars_and_offsets)),
#            .packages=c("kcde", kcde_control$par_packages),
#            .combine="c") %dopar% {
            crossval_results <- lapply(seq_len(nrow(predictive_vars_and_offsets)),
                function(i) {
                    descriptor_updated_model <- update_vars_and_offsets(
                        prev_vars_and_offsets = current_model_vars_and_offsets,
                        update_var_name = predictive_vars_and_offsets[i, "var_name"],
                        update_offset_value = predictive_vars_and_offsets[i, "offset_value"],
                        update_offset_type = predictive_vars_and_offsets[i, "offset_type"])
                    
                    model_i_previously_evaluated <- any(sapply(
                            all_evaluated_model_descriptors,
                            function(descriptor) {
                                identical(descriptor_updated_model, descriptor)
                            }
                        ))
                    
                    if(!model_i_previously_evaluated && any(descriptor_updated_model$offset_type == "lag")) {
                        potential_step_result <- 
                            est_kcde_params_stepwise_crossval_one_potential_step(
                                prev_vars_and_offsets=current_model_vars_and_offsets,
                                prev_theta=theta_hat,
                                prev_phi=phi_hat,
                                update_var_name=predictive_vars_and_offsets[i, "var_name"],
                                update_lag_value=predictive_vars_and_offsets[i, "offset_value"],
                                data=data,
                                all_na_drop_rows = all_na_drop_rows,
                                kcde_control=kcde_control)
                        
                        return(potential_step_result)
#	               return(list(potential_step_result)) # put results in a list so that combine="c" is useful
                    } else {
                        return(NULL) # represents a model that has been previously evaluated or doesn't include any predictive variables
                    }
                }
            ) # This parenthesis is used only when foreach is not used above
            
            ## drop elements corresponding to previously explored models or models without any predictive variables
            non_null_components <- sapply(crossval_results,
                function(component) { !is.null(component) }
            )
            crossval_results <- crossval_results[non_null_components]
            
            all_evaluated_models <- c(all_evaluated_models, crossval_results)
            all_evaluated_model_descriptors <-
                c(all_evaluated_model_descriptors,
                    lapply(crossval_results, function(component) {
                            component$vars_and_offsets
                        }))
            
            if(length(crossval_results) == 0L) {
                ## all models were a null model or a model that was previously evaluated
                ## stop search
                break
            }
            
            ## pull out loss achieved by each model, find the best value
            loss_achieved <- sapply(crossval_results, function(component) {
                    component$loss
                })
            optimal_loss_ind <- which.min(loss_achieved)
            
#        print("loss achieved is:")
#        print(loss_achieved)
#        print("\n")
            
            ## either update the model and keep going or stop the search
            if(loss_achieved[optimal_loss_ind] < crossval_prediction_loss) {
                ## found a model improvement -- update and continue
                selected_var_lag_ind <- optimal_loss_ind
                crossval_prediction_loss <- loss_achieved[selected_var_lag_ind]
                current_model_vars_and_offsets <-
                    crossval_results[[selected_var_lag_ind]]$vars_and_offsets
                theta_hat <- crossval_results[[selected_var_lag_ind]]$theta
                phi_hat <- crossval_results[[selected_var_lag_ind]]$phi
            } else {
                ## could not find a model improvement -- stop search
                break
            }
        }
    } else if(identical(kcde_control$variable_selection_method, "all_included")) {
        descriptor_updated_model <- update_vars_and_offsets(
            prev_vars_and_offsets = current_model_vars_and_offsets,
            update_var_name = predictive_vars_and_offsets[, "var_name"],
            update_offset_value = predictive_vars_and_offsets[, "offset_value"],
            update_offset_type = predictive_vars_and_offsets[, "offset_type"])
        
        crossval_results <- 
            list(est_kcde_params_stepwise_crossval_one_potential_step(
                prev_vars_and_offsets=current_model_vars_and_offsets,
                prev_theta=theta_hat,
                prev_phi=phi_hat,
                init_theta_vector=init_theta_vector,
                init_phi_vector=init_phi_vector,
                update_var_name=predictive_vars_and_offsets[, "var_name"],
                update_lag_value=predictive_vars_and_offsets[, "offset_value"],
                data=data,
                all_na_drop_rows = all_na_drop_rows,
                kcde_control=kcde_control))
        
        all_evaluated_models <- c(all_evaluated_models, crossval_results)
        all_evaluated_model_descriptors <-
            c(all_evaluated_model_descriptors,
                lapply(crossval_results, function(component) {
                        component$vars_and_offsets
                    }))
        
        current_model_vars_and_offsets <-
            crossval_results[[1]]$vars_and_offsets
        theta_hat <- crossval_results[[1]]$theta
        phi_hat <- crossval_results[[1]]$phi
    } else {
        stop("Invalid variable selection method")
    }
    
    return(list(vars_and_offsets=current_model_vars_and_offsets,
        theta_hat=theta_hat,
        phi_hat=phi_hat,
        all_evaluated_models=all_evaluated_models,
        all_evaluated_model_descriptors=all_evaluated_model_descriptors))
}


#' Estimate the parameters theta and corresponding cross-validated estimate of
#' loss for one possible model obtained by adding or removing a variable/lag
#' combination from the model obtained in the previous iteration of the stepwise
#' search procedure.
#' 
#' @param prev_vars_and_offsets list representing combinations of variables and lags
#'     included in the model obtained at the previous step
#' @param prev_theta list representing the kernel parameter estimates obtained
#'     at the previous step
#' @param update_var_name the name of the variable to try adding or removing
#'     from the model
#' @param update_offset_value the value of the offset for the variable specified by
#'     update_var_name to try adding or removing from the model
#' @param data the data frame with observations used in estimating model
#'     parameters
#' @param kcde_control a list of parameters specifying how the fitting is done
#' 
#' @return a list with three components: loss is a cross-validation estimate of
#'     the loss associated with the estimated parameter values for the given
#'     model, lags is a list representing combinations of variables and lags
#'     included in the updated model, and theta is a list representing the
#'     kernel parameter estimates in the updated model
est_kcde_params_stepwise_crossval_one_potential_step <- function(
		prev_vars_and_offsets,
    	prev_theta,
        prev_phi,
        init_theta_vector,
        init_phi_vector,
    	update_var_name,
    	update_lag_value,
    	data,
        all_na_drop_rows,
        kcde_control) {
    ## updated variable and lag combinations included in model
    updated_vars_and_offsets <- update_vars_and_offsets(
        prev_vars_and_offsets = prev_vars_and_offsets,
		update_var_name = update_var_name,
		update_offset_value = update_lag_value,
        update_offset_type = "lag")
    
    ## Initialize filtering parameters phi
    phi_init <- initialize_phi(prev_phi = prev_phi,
        updated_vars_and_offsets = updated_vars_and_offsets,
        update_var_name = update_var_name,
        update_offset_value = update_lag_value,
        update_offset_type = "lag",
        data = data,
        kcde_control = kcde_control)
    
    if(missing(init_phi_vector) || is.null(init_phi_vector)) {
        phi_est_init <- extract_vectorized_phi_est_from_phi(phi = phi_init,
            filter_control = kcde_control$filter_control)
    } else {
        phi_est_init <- init_phi_vector
    }
    
    ## create data frame of "examples" -- lagged observation vectors and
    ## corresponding prediction targets
    max_filter_window_size <- suppressWarnings(max(unlist(lapply(
                    kcde_control$filter_control,
                    function(filter_var_component) {
                        filter_var_component$max_filter_window_size
                    }
                ))))
    if(max_filter_window_size == -Inf) {
        max_filter_window_size <- 0L
    }
    
    max_lag <- max(unlist(lapply(kcde_control$kernel_components,
                function(kernel_component) {
                    kernel_component$vars_and_offsets$offset_value[
                        kernel_component$vars_and_offsets$offset_type == "lag"
                    ]
                }
            )))
    
    max_horizon <- max(unlist(lapply(kcde_control$kernel_components,
                function(kernel_component) {
                    kernel_component$vars_and_offsets$offset_value[
                        kernel_component$vars_and_offsets$offset_type == "horizon"
                    ]
                }
            )))
    
    cross_validation_examples <- compute_offset_obs_vecs(data = data,
        filter_control = kcde_control$filter_control,
        phi = phi_init,
        vars_and_offsets = updated_vars_and_offsets,
        time_name = kcde_control$time_name,
        leading_rows_to_drop = max_filter_window_size + max_lag,
        trailing_rows_to_drop = max_horizon,
        additional_rows_to_drop = all_na_drop_rows,
        na.action = kcde_control$na.action)
    
    ## initial values for theta
    if(identical(prev_theta, vector("list", length(kcde_control$kernel_components)))) {
        theta_init <- initialize_theta(prev_theta = prev_theta,
            updated_vars_and_offsets = updated_vars_and_offsets,
            update_var_name = updated_vars_and_offsets$var_name,
            update_offset_value = updated_vars_and_offsets$offset_value,
            update_offset_type = updated_vars_and_offsets$offset_type,
            data = cross_validation_examples,
            kcde_control = kcde_control)
    } else {
        theta_init <- initialize_theta(prev_theta = prev_theta,
            updated_vars_and_offsets = updated_vars_and_offsets,
            update_var_name = update_var_name,
            update_offset_value = update_lag_value,
            update_offset_type = "lag",
            data = cross_validation_examples,
            kcde_control = kcde_control)
    }
    
    if(missing(init_theta_vector) || is.null(init_theta_vector)) {
        theta_est_init <- extract_vectorized_theta_est_from_theta(theta = theta_init,
            vars_and_offsets = updated_vars_and_offsets,
            kcde_control = kcde_control)
    } else {
        theta_est_init <- init_theta_vector
    }
    
    ## optimize parameter values
    phi_optim_bounds <- get_phi_optim_bounds(phi = phi_init,
        filter_control = kcde_control$filter_control)
    theta_optim_bounds <- get_theta_optim_bounds(theta = theta_init,
        kcde_control = kcde_control)
    optim_result <- optim(par=c(phi_est_init, theta_est_init),
        fn=kcde_crossval_estimate_parameter_loss,
#        gr = gradient_kcde_crossval_estimate_parameter_loss,
		gr=NULL,
        phi=phi_init,
		theta=theta_init,
        vars_and_offsets=updated_vars_and_offsets,
        data=data,
        leading_rows_to_drop=max_filter_window_size + max_lag,
        trailing_rows_to_drop=max_horizon,
        additional_rows_to_drop = all_na_drop_rows,
        kcde_control=kcde_control,
        method="L-BFGS-B",
        lower = c(phi_optim_bounds$lower, theta_optim_bounds$lower),
        upper = c(phi_optim_bounds$upper, theta_optim_bounds$upper),
        #        lower=-50,
        #		upper=10000,
        #control=list(),
        hessian=FALSE)
    
#    print(optim_result)
    
    ## convert back to list and original parameter scale
    temp <- update_phi_from_vectorized_phi_est(phi_est_vector = optim_result$par,
        phi = phi_init,
        filter_control = kcde_control$filter_control)
    
    updated_phi <- temp$phi
    ## index of the first element of optim_result$par that corresponds to a theta parameter
    next_param_ind <- temp$next_param_ind
    
    updated_theta <- update_theta_from_vectorized_theta_est(
        optim_result$par[seq(from = next_param_ind,
                length = length(optim_result$par) - next_param_ind + 1)],
        theta_init,
        kcde_control)
    
    return(list(
        loss=optim_result$value,
        vars_and_offsets=updated_vars_and_offsets,
        phi=updated_phi,
        theta=updated_theta
    ))
}

#' Using cross-validation, estimate the loss associated with a particular set
#' of lags and kernel function parameters.  We calculate log-score loss
#' 
#' @param combined_params_vector vector of parameters for filtering and kernel
#'     functions that are being estimated
#' @param theta list of kernel function parameters, both those that are being
#'     estimated and those that are out of date.  Possibly the values of
#'     parameters being estimated are out of date; they will be replaced with
#'     the values in theta_est_vector.
#' @param vars_and_offsets list representing combinations of variables and lags
#'     included in the model
#' @param data the data frame to use in performing cross validation
#' @param kcde_control a list of parameters specifying how the fitting is done
#' 
#' @return numeric -- cross-validation estimate of loss associated with the
#'     specified parameters
kcde_crossval_estimate_parameter_loss <- function(combined_params_vector,
        phi,
		theta,
		vars_and_offsets,
    	data,
        leading_rows_to_drop,
        trailing_rows_to_drop,
        additional_rows_to_drop,
    	kcde_control) {
    ## update phi and theta with elements of combined_params_vector and
    ## transform back to list and original parameter scale
    temp <- update_phi_from_vectorized_phi_est(combined_params_vector,
        phi,
        kcde_control$filter_control)
    
    phi <- temp$phi
    ## index of the first element of combined_params_vector that corresponds
    ## to a theta parameter
    next_param_ind <- temp$next_param_ind
    
    theta <- update_theta_from_vectorized_theta_est(
        combined_params_vector[seq(from = next_param_ind,
                length = length(combined_params_vector) - next_param_ind + 1)],
        theta,
        kcde_control)
    
    ## Create data frame of filtered and lagged cross validation examples
    cross_validation_examples <- compute_offset_obs_vecs(data = data,
        filter_control = kcde_control$filter_control,
        phi = phi,
        vars_and_offsets = vars_and_offsets,
        time_name = kcde_control$time_name,
        leading_rows_to_drop = leading_rows_to_drop,
        trailing_rows_to_drop = trailing_rows_to_drop,
        additional_rows_to_drop = additional_rows_to_drop,
        na.action = kcde_control$na.action)
    
    predictive_var_combined_names <- vars_and_offsets$combined_name[vars_and_offsets$offset_type == "lag"]
    target_var_combined_names <- vars_and_offsets$combined_name[vars_and_offsets$offset_type == "horizon"]
    
    ## This could be made more computationally efficient by computing
    ## kernel values for all relevant combinations of lags for each variable,
    ## then combining as appropriate -- currently, the same kernel value may be
    ## computed multiple times in the call to kcde_predict_given_lagged_obs
    num_obs_per_crossval_group <- floor(nrow(cross_validation_examples) /
        kcde_control$par_cores)
    t_train_groups <- lapply(seq_len(kcde_control$par_cores),
        function(group_num) {
            if(!identical(group_num, as.integer(kcde_control$par_cores))) {
                return(seq(from = (group_num - 1) * num_obs_per_crossval_group + 1,
                        length = num_obs_per_crossval_group))
            } else {
                return(seq(from = (group_num - 1) * num_obs_per_crossval_group + 1,
                        to = nrow(cross_validation_examples)))
            }
        }
    )
    
#    i <- 1L # used for debugging
    kernel_values_by_t_train_group <- foreach(i = seq_along(t_train_groups),
            .packages = c("kcde", kcde_control$par_packages),
            .combine = "c") %dopar% {
        ## Allocate array to store results.  Initialize to -Inf, which
        ## means there will be no contribution when logspace_sum is used.
        result_one_group <- array(-Inf,
            dim = c(
                nrow(cross_validation_examples),
                length(t_train_groups[[i]]),
                length(target_var_combined_names) + 1
            )
        )
        
        for(t_train_ind in seq_along(t_train_groups[[i]])) {
            t_train <- t_train_groups[[i]][t_train_ind]
            ## get indices of x at which we evaluate the kernel:
            ## those indices not within t_train +/- kcde_control$crossval_buffer
            t_pred <- seq_len(nrow(cross_validation_examples))
            if(is.null(kcde_control$time_name)) {
                ## If no time variable, we just leave out index t_pred +/- as.integer(kcde_control$crossval_buffer)
                t_train_near_t_pred <- abs(t_pred - t_train) <= as.integer(kcde_control$crossval_buffer)
            } else {
                ## If there is a time variable, we compute indices to leave out based on that
                train_time <- cross_validation_examples[t_train, kcde_control$time_name]
                t_train_near_t_pred <- 
                    abs(cross_validation_examples[, kcde_control$time_name] - train_time) <= kcde_control$crossval_buffer
            }
            t_pred <- t_pred[! t_train_near_t_pred]
            
            ## assemble lagged and lead observations -- subsets of
            ## cross_validation_examples given by t_pred and t_train
            train_lagged_obs <- cross_validation_examples[
                t_train, predictive_var_combined_names, drop=FALSE]
            train_lead_obs <- cross_validation_examples[
                t_train, target_var_combined_names, drop=FALSE]
            prediction_lagged_obs <- 
                cross_validation_examples[
                    t_pred, predictive_var_combined_names, drop=FALSE]
            prediction_lead_obs <-
                cross_validation_examples[
                    t_pred, target_var_combined_names, drop=FALSE]
            
            ## kernel values for just x
            result_one_group[t_pred, t_train_ind, 1] <-
                compute_kernel_values(train_lagged_obs,
                    prediction_lagged_obs,
                    kernel_components = kcde_control$kernel_components,
                    theta = theta,
                    log = TRUE)
            
            ## kernel values for each prediction target variable
            for(target_var_ind in seq_along(target_var_combined_names)) {
                target_var_combined_name <- target_var_combined_names[target_var_ind]
                result_one_group[t_pred, t_train_ind, target_var_ind + 1] <-
                    compute_kernel_values(
                        cbind(train_lagged_obs, train_lead_obs[, target_var_combined_name, drop = FALSE]),
                        cbind(prediction_lagged_obs, prediction_lead_obs[, target_var_combined_name, drop = FALSE]),
                        kernel_components = kcde_control$kernel_components,
                        theta = theta,
                        log = TRUE)
            }
        }
        
        return(list(result_one_group))
    }
#    kernel_values_by_t_train_group <- list(result_one_group) # used for debugging
    
    ## combine array results calculated in parallel
    kernel_values_by_time_pair <- array(NA,
        dim = c(
            nrow(cross_validation_examples),
            nrow(cross_validation_examples),
            length(target_var_combined_names) + 1
        )
    )
    
    kv_row_ind <- 1L
    for(group_results in kernel_values_by_t_train_group) {
        nrow_group_results <- dim(group_results)[2]
        kernel_values_by_time_pair[
            , seq(from = kv_row_ind, length = nrow_group_results), ] <-
            group_results
        
        kv_row_ind <- kv_row_ind + nrow_group_results
    }
    
    ## for each set of kernel values computed above
    ## (x only and (x,y) for each target variable y),
    ## compute the vector log(sum_{t_train}(kernel(t_train, t_pred)))
    ## where t_pred varies in the vector entries
    log_sum_kernel_vals_by_kernel_var <- lapply(
        seq_len(dim(kernel_values_by_time_pair)[3]),
        function(target_var_ind) {
            return(logspace_sum_matrix_rows(
                as.matrix(kernel_values_by_time_pair[, , target_var_ind])
            ))
        }
    )
    
    crossval_loss_by_time_ind <-
        log_sum_kernel_vals_by_kernel_var[[2]] -
        log_sum_kernel_vals_by_kernel_var[[1]]
    
    if(length(log_sum_kernel_vals_by_kernel_var) > 2L) {
        for(target_var_ind in seq(from = 3, to = length(log_sum_kernel_vals_by_kernel_var))) {
            crossval_loss_by_time_ind <- crossval_loss_by_time_ind +
                log_sum_kernel_vals_by_kernel_var[[target_var_ind]] -
                log_sum_kernel_vals_by_kernel_var[[1]]
        }
    }
    
    cat(combined_params_vector)
    cat("\n")
    cat(-1 * sum(crossval_loss_by_time_ind))
    cat("\n")
    cat("\n")
#    if(any(is.na(crossval_loss_by_time_ind) | is.infinite(crossval_loss_by_time_ind)) ||
#        is.infinite(sum(crossval_loss_by_time_ind))) {
#        browser()
#    }
    
    ## parameters resulted in numerical instability
    ## If bw-chol parameterization was used, this is probably due to
    ## numerically 0 bandwidths.  Could have any of three effects:
    ##  - zero values, if the numerator and denominator in calculating
    ##    conditional kernel values were both so large that their difference is 0
    ##  - NA values or Inf values.
    ## In any of these cases, we return a large value;
    ## this results in rejection of these parameter values
    crossval_loss_eq_0 <- sapply(
        crossval_loss_by_time_ind,
        function(cvli) {
            isTRUE(all.equal(cvli, 0))
        }
    )
    if(any(is.na(crossval_loss_by_time_ind) |
            is.infinite(crossval_loss_by_time_ind) |
            crossval_loss_eq_0)) {
        message("NAs or Infs in cross validated estimate of loss")
        return(10^10)
    } else {
        ## multiply by -1 to get negative loss, which is minimized by optim
        return(-1 * sum(crossval_loss_by_time_ind))
    }
}
































##' Using cross-validation, estimate the loss associated with a particular set
##' of lags and kernel function parameters.
##' 
##' @param combined_params_vector vector of parameters for filtering and kernel
##'     functions that are being estimated
##' @param theta list of kernel function parameters, both those that are being
##'     estimated and those that are out of date.  Possibly the values of
##'     parameters being estimated are out of date; they will be replaced with
##'     the values in theta_est_vector.
##' @param vars_and_offsets list representing combinations of variables and lags
##'     included in the model
##' @param data the data frame to use in performing cross validation
##' @param kcde_control a list of parameters specifying how the fitting is done
##' 
##' @return numeric -- cross-validation estimate of loss associated with the
##'     specified parameters
#kcde_crossval_estimate_parameter_loss <- function(combined_params_vector,
#    phi,
#    theta,
#    vars_and_offsets,
#    data,
#    leading_rows_to_drop,
#    trailing_rows_to_drop,
#    additional_rows_to_drop,
#    kcde_control) {
#    ## update phi and theta with elements of combined_params_vector and
#    ## transform back to list and original parameter scale
#    temp <- update_phi_from_vectorized_phi_est(combined_params_vector,
#        phi,
#        kcde_control$filter_control)
#    
#    phi <- temp$phi
#    ## index of the first element of combined_params_vector that corresponds
#    ## to a theta parameter
#    next_param_ind <- temp$next_param_ind
#    
#    theta <- update_theta_from_vectorized_theta_est(
#        combined_params_vector[seq(from = next_param_ind,
#                length = length(combined_params_vector) - next_param_ind + 1)],
#        theta,
#        kcde_control)
#    
#    ## Create data frame of filtered and lagged cross validation examples
#    cross_validation_examples <- compute_offset_obs_vecs(data = data,
#        filter_control = kcde_control$filter_control,
#        phi = phi,
#        vars_and_offsets = vars_and_offsets,
#        time_name = kcde_control$time_name,
#        leading_rows_to_drop = leading_rows_to_drop,
#        trailing_rows_to_drop = trailing_rows_to_drop,
#        additional_rows_to_drop = additional_rows_to_drop,
#        na.action = kcde_control$na.action)
#    
#    predictive_var_combined_names <- vars_and_offsets$combined_name[vars_and_offsets$offset_type == "lag"]
#    target_var_combined_names <- vars_and_offsets$combined_name[vars_and_offsets$offset_type == "horizon"]
#    
#    ## This could be made more computationally efficient by computing
#    ## kernel values for all relevant combinations of lags for each variable,
#    ## then combining as appropriate -- currently, the same kernel value may be
#    ## computed multiple times in the call to kcde_predict_given_lagged_obs
#    num_obs_per_crossval_group <- floor(nrow(cross_validation_examples) /
#            kcde_control$par_cores)
#    t_pred_groups <- lapply(seq_len(kcde_control$par_cores),
#        function(group_num) {
#            if(!identical(group_num, as.integer(kcde_control$par_cores))) {
#                return(seq(from = (group_num - 1) * num_obs_per_crossval_group + 1,
#                        length = num_obs_per_crossval_group))
#            } else {
#                return(seq(from = (group_num - 1) * num_obs_per_crossval_group + 1,
#                        to = nrow(cross_validation_examples)))
#            }
#        }
#    )
#    
#    crossval_loss_by_time_ind <- foreach(i = seq_along(t_pred_groups),
#            .packages = c("kcde", kcde_control$par_packages),
#            .combine = "c") %dopar% {
#            return(sapply(
#                    t_pred_groups[[i]],
#                    function(t_pred) {
#                        ## get training indices -- those indices not within
#                        ## t_pred +/- kcde_control$crossval_buffer
#                        t_train <- seq_len(nrow(cross_validation_examples))
#                        if(is.null(kcde_control$time_name)) {
#                            ## If no time variable, we just leave out index t_pred +/- as.integer(kcde_control$crossval_buffer)
#                            t_train_near_t_pred <- abs(t_train - t_pred) <= as.integer(kcde_control$crossval_buffer)
#                        } else {
#                            ## If there is a time variable, we compute indices to leave out based on that
#                            pred_time <- cross_validation_examples[t_pred, kcde_control$time_name]
#                            t_train_near_t_pred <- 
#                                abs(cross_validation_examples[, kcde_control$time_name] - pred_time) <= kcde_control$crossval_buffer
#                        }
#                        t_train <- t_train[! t_train_near_t_pred]
#                        
#                        ## calculate kernel weights and centers for prediction at
#                        ## prediction_lagged_obs based on train_lagged_obs and
#                        ## train_lead_obs
#                        ## assemble lagged and lead observations -- subsets of
#                        ## cross_validation_examples given by t_pred and t_train
#                        ## we can re-use the weights at different prediction_target_inds,
#                        ## and just have to adjust the kernel centers
#                        train_lagged_obs <- cross_validation_examples[
#                            t_train, predictive_var_combined_names, drop=FALSE]
#                        train_lead_obs <- cross_validation_examples[
#                            t_train, target_var_combined_names, drop=FALSE]
#                        prediction_lagged_obs <- 
#                            cross_validation_examples[
#                                t_pred, predictive_var_combined_names, drop=FALSE]
#                        prediction_lead_obs <-
#                            cross_validation_examples[
#                                t_pred, target_var_combined_names, drop=FALSE]
#                        
#                        ## for each prediction target variable, compute loss
#                        crossval_loss_by_prediction_target <- sapply(
#                            target_var_combined_names,
#                            function(target_name) {
#                                ## calculate and return value of loss function based on
#                                ## prediction and realized value
#                                loss_args <- kcde_control$loss_args
#                                
#                                loss_fn_prediction_args <- c(
#                                    kcde_control$loss_fn_prediction_args,
#                                    list(
#                                        train_lagged_obs=train_lagged_obs,
#                                        train_lead_obs=train_lead_obs[, target_name, drop = FALSE],
#                                        prediction_lagged_obs=prediction_lagged_obs,
#                                        prediction_test_lead_obs=prediction_lead_obs[, target_name, drop = FALSE],
#                                        kcde_fit=list(
#                                            theta_hat=theta,
#                                            kcde_control=kcde_control
#                                        )
#                                    )
#                                )
#                                loss_args$prediction_result <- do.call(
#                                    kcde_predict_given_lagged_obs,
#                                    loss_fn_prediction_args
#                                )
#                                
#                                loss_args$obs <- as.numeric(
#                                    cross_validation_examples[
#                                        t_pred, target_name]
#                                )
#                                
#                                return(do.call(kcde_control$loss_fn, loss_args))
#                            })
#                        
#                        return(sum(crossval_loss_by_prediction_target))
#                    }
#                ))
#        }
#    
#    cat(combined_params_vector)
#    cat("\n")
#    cat(sum(crossval_loss_by_time_ind))
#    cat("\n")
#    cat("\n")
##    if(any(is.na(crossval_loss_by_time_ind) | is.infinite(crossval_loss_by_time_ind)) ||
##        is.infinite(sum(crossval_loss_by_time_ind))) {
##        browser()
##    }
#    
#    ## parameters resulted in numerical instability
#    ## If bw-chol parameterization was used, this is probably due to
#    ## numerically 0 bandwidths.  Could have any of three effects:
#    ##  - zero values, if the numerator and denominator in calculating
#    ##    conditional kernel values were both so large that their difference is 0
#    ##  - NA values or Inf values.
#    ## In any of these cases, we return a large value;
#    ## this results in rejection of these parameter values
#    crossval_loss_eq_0 <- sapply(
#        crossval_loss_by_time_ind,
#        function(cvli) {
#            isTRUE(all.equal(cvli, 0))
#        }
#    )
#    if(any(is.na(crossval_loss_by_time_ind) |
#            is.infinite(crossval_loss_by_time_ind) |
#            crossval_loss_eq_0)) {
#        message("NAs or Infs in cross validated estimate of loss")
#        return(10^10)
#    } else {
#        return(sum(crossval_loss_by_time_ind))
#    }
#}
