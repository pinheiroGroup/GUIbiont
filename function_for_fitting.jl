using Kinbiont,Plots,CSV,DataFrames,Tables,Statistics

function  analysis_file(
    label_exp::String, #label of the experiment
    path_to_data::String, # path to the folder to analyze
    model::String, # string of the used model
    param;
    path_to_annotation::Any=missing,# path to the annotation of the wells
    path_to_results="NA", # path where save results
    loss_type="RE", # string of the type of the used loss
    smoothing=false, # 1 do smoothing of data with rolling average
    type_of_smoothing="lowess",
    verbose=false, # 1 true verbose
    write_res=false, # write results
    pt_avg=1, # number of points to do smoothing average
    pt_smoothing_derivative=7, # number of points to do ssmooth_derivative
    do_blank_subtraction="avg_blank", # string on how to use blank (NO,avg_subtraction,time_avg)
    correct_negative="remove", # if "thr_correction" it put a thr on the minimum value of the data with blank subracted, if "blank_correction" uses blank distrib to impute negative values
    thr_negative=0.01,  # used only if correct_negative == "thr_correction"
    method_multiple_scattering_correction="interpolation",
    calibration_OD_curve="NA",  #  the path to calibration curve to fix the data
    thr_lowess=0.05,
    path_to_plot ="NA",
    blank_value=0.0,
    blank_array=[0.0],
    percentile_thr = 0.05,
    win_stat_phase=5,
    opt_params...
)
    # read annotation file

    if write_res == true
        mkpath(path_to_results)
    end

    parameter_of_optimization = initialize_df_results(model)

    model2 ="piecewise_adjusted_logistic"
    parameter_of_optimization2 = initialize_df_results(model2)
    #"gr, N_max, lag, shape, linear_const,"
    param2 = [0.6,0.6,5.0,1.0,0.01]
    lb_new =[0.0,0.0,0.0,0.0,-0.01]
    ub_new = [10.0,20.0,35.0,10.0,0.01]
    results_Log_Lin = [
        "label_exp",
        "well_name",
        "t_start",
        "t_end",
        "t_of_max",
        "empirical_max_Growth_rate",
        "Growth_rate",
        "sigma_gr",
        "dt",
        "sigma_confidence_dt_upper",
        "sigma_confidence_dt_lower",
        "intercept",
        "sigma_intercept",
        "Pearson_correlation",
    ] 

   
    # Preprocess annotation file to handle missing values
    # First, check if the annotation file needs cleaning before calling reading_annotation
    annotation_needs_cleaning = false
    try
        # Quick check for missing values in second column
        annotation_test_df = CSV.File(path_to_annotation, header=false, limit=50) |> DataFrame
        for i in 1:nrow(annotation_test_df)
            if ncol(annotation_test_df) >= 2 && (ismissing(annotation_test_df[i, 2]) || annotation_test_df[i, 2] == "")
                annotation_needs_cleaning = true
                break
            end
        end
    catch
        # If we can't read the file for testing, assume it needs cleaning
        annotation_needs_cleaning = true
    end
    
    if annotation_needs_cleaning
        println("Warning: Annotation file contains empty values in second column. Pre-cleaning...")
        
        # Read the annotation file manually and clean it
        annotation_df = CSV.File(path_to_annotation, header=false) |> DataFrame
        
        # Clean each row
        for i in 1:nrow(annotation_df)
            # Handle empty second column specifically
            if ncol(annotation_df) >= 2 && (ismissing(annotation_df[i, 2]) || annotation_df[i, 2] == "")
                annotation_df[i, 2] = "X"  # Mark as excluded well
            end
            
            # Ensure consistent number of columns and replace missing with empty strings
            for j in 1:ncol(annotation_df)
                if ismissing(annotation_df[i, j])
                    annotation_df[i, j] = ""
                end
            end
        end
        
        # Remove completely empty rows
        annotation_df = annotation_df[.!all(x -> ismissing(x) || x == "", eachrow(annotation_df)), :]
        
        # Write cleaned annotation file temporarily
        temp_annotation_path = replace(path_to_annotation, ".csv" => "_temp_cleaned.csv")
        CSV.write(temp_annotation_path, annotation_df, header=false)
        
        # Use the cleaned file
        try
            names_of_annotated_df, properties_of_annotation, list_of_blank, list_of_discarded = reading_annotation(temp_annotation_path)
            rm(temp_annotation_path) # Clean up temp file
            println("Successfully processed annotation file after cleaning.")
        catch e
            rm(temp_annotation_path) # Clean up temp file
            println("Error: Could not process annotation file even after cleaning: ", e)
            rethrow(e)
        end
    else
        # File looks clean, use it directly
        names_of_annotated_df, properties_of_annotation, list_of_blank, list_of_discarded = reading_annotation(path_to_annotation)
    end


    # reading files
    dfs_data = CSV.File(path_to_data)

    # shaping df for the inference
    names_of_cols = propertynames(dfs_data)

    # excluding blank data and discarded wells
    if length(list_of_blank) > 0
        names_of_cols = filter!(e -> !(e in list_of_blank), names_of_cols)
    end

    if length(list_of_discarded) > 0
        names_of_cols = filter!(e -> !(e in list_of_discarded), names_of_cols)
    end

    times_data = dfs_data[names_of_cols[1]]

    if length(list_of_blank) > 0
        blank_array = reduce(vcat, [(dfs_data[k]) for k in list_of_blank])
        blank_array = convert(Vector{Float64}, blank_array)

        blank_value = blank_subtraction(
            dfs_data,
            list_of_blank;
            method=do_blank_subtraction
        )

    end


    ## considering replicates
    list_replicate = unique(properties_of_annotation)
    list_replicate = filter!(e -> e != "b", list_replicate)


    # for on the columns to analyze
     AUC = ["AUC"]
     DELTA_OD = ["DELTA_OD"]
     stat_time = ["stat_time"]
     N0 = ["N0"]

    for well_name in names_of_cols[2:end]

        data_values = copy(dfs_data[well_name])



        # blank subtraction 
        data_values = data_values .- blank_value

        index_missing = findall(ismissing, data_values)
        index_tot = eachindex(data_values)
        index_tot = setdiff(index_tot, index_missing)
        data = Matrix(transpose(hcat(times_data[index_tot], data_values[index_tot])))

        # correcting negative values after blank subtraction
        data = negative_value_correction(data,
            blank_array;
            method=correct_negative,
            thr_negative=thr_negative,
            )

        # defining time steps of the inference

        max_t = data[1, end]
        min_t = data[1, 1]



        # multiple scattering correctionas
        data = correction_OD_multiple_scattering(data, calibration_OD_curve; method=method_multiple_scattering_correction)
        # smoothing data

        data_log_lin = data 
        if smoothing == true

                data =     Kinbiont.smoothing_data(
                    data;
                    method=type_of_smoothing,
                    pt_avg=pt_avg,
                    thr_lowess=thr_lowess    )
            
        end
        # cutting data for cp
        data_cut = find_stationary_phase(data;percentile_thr=percentile_thr,pt_smooth_derivative=pt_smoothing_derivative,win_size=win_stat_phase)
      
        if data_cut == nothing
            println("No stationary phase found for well ", string(well_name))
            data_cut = data
            data_log_lin_cut = data
        else
            index_to_use = findall(data_log_lin[1,:] .< data_cut[1,end])
            data_log_lin_cut = data_log_lin[:,index_to_use]
        end



        # inference
        data = Matrix(data)
        data_cut = Matrix(data_cut)

        stationary_phase_start_temp = data_cut[1, end]
        AUC_temp = sum([  data_cut[2,i] *(data_cut[1,i].-data_cut[1,i-1]) for i in 2:length(data_cut[1,:])])
        DELTA_OD_temp = data_cut[2, end] - data_cut[2, 1]

        temp_results_1 = fitting_one_well_ODE_constrained(
            data_cut, # dataset first row times second row OD
            string(well_name), # name of the well
            label_exp, #label of the experiment
            model, # ode model to use 
            param; # upper bound param
            pt_avg=3, # numebr of the point to generate intial condition
            pt_smooth_derivative=pt_smoothing_derivative,
            multiple_scattering_correction=false, # if true uses the given calibration curve to fix the data
            opt_params...
        )
        # plotting and save fit 
        println("Fitting of well ",string( well_name), " done")
        println(temp_results_1[2])
        path_to_plot_ode = string(path_to_plot,"_ODE_fit_aHPM/")

        plot_ODE(label_exp,
            data,
            temp_results_1[4],
            temp_results_1[3],
            model,
            string(well_name),
            stationary_phase_start_temp;
             path_to_plot = path_to_plot_ode, # path where to save Plots
             display_plots=true,# display plots in julia or not
             save_plots=true, # save the plot or not
             x_size=700,
             y_size =500,
             guidefontsize=18,
             tickfontsize=16,
             legendfontsize=10,
        )


        temp_results_2 = fitting_one_well_ODE_constrained(
            data_cut, # dataset first row times second row OD
            string(well_name), # name of the well
            label_exp, #label of the experiment
            model2, # ode model to use 
            param2; # upper bound param
            pt_avg=3, # numebr of the point to generate intial condition
            pt_smooth_derivative=pt_smoothing_derivative,
            multiple_scattering_correction=false, # if true uses the given calibration curve to fix the data
            lb = lb_new,
            ub=ub_new,
        )
        # plotting and save fit 
        println("Fitting of well ",string( well_name), " done")
        println(temp_results_2[2])
        path_to_plot_ode = string(path_to_plot,"_ODE_fit_logistic/")

        plot_ODE(label_exp,
            data,
            temp_results_2[4],
            temp_results_2[3],
            model2,
            string(well_name),
            stationary_phase_start_temp;
             path_to_plot = path_to_plot_ode, # path where to save Plots
             display_plots=true,# display plots in julia or not
             save_plots=true, # save the plot or not
             x_size=700,
             y_size =500,
             guidefontsize=18,
             tickfontsize=16,
             legendfontsize=10,
        )
        # log lin fitting of first part

        temp_results_log_lin = fitting_one_well_Log_Lin(
            data_log_lin_cut, # dataset first row times second row OD
            string(well_name), # name of the well
            label_exp; #label of the experiment
            type_of_smoothing="NO", # option, NO, gaussian, rolling avg
            pt_avg=pt_avg, # number of the point for rolling avg not used in the other cases
            pt_smoothing_derivative=pt_smoothing_derivative, # number of poits to smooth the derivative
            pt_min_size_of_win=15, # minimum size of the exp windows in number of smooted points
            type_of_win="max_with_min_OD", # how the exp. phase win is selected, "maximum" of "global_thr"
            threshold_of_exp=0.9, # threshold of growth rate in quantile to define the exp windows
            multiple_scattering_correction=false, # if true uses the given calibration curve to fix the data
            start_exp_win_thr=0.02
        )

        println("Fitting log lin ",string( well_name), " done")
        println(temp_results_log_lin[2])
        # plotting log ling fit
        path_to_plot_log_lin = string(path_to_plot,"_log_lin/")
        
        plot_log_lin(label_exp,
            data,
            temp_results_log_lin[3],
            temp_results_log_lin[2];
             path_to_plot=path_to_plot_log_lin, # path where to save Plots
             display_plots=true,# display plots in julia or not
             save_plots=true, # save the plot or not
             x_size=700,
             y_size =500,
             guidefontsize=18,
             tickfontsize=16,
             legendfontsize=10,
        )
        

        # pushing results
        results_Log_Lin = hcat(results_Log_Lin, temp_results_log_lin[2])
        parameter_of_optimization = hcat(parameter_of_optimization, temp_results_1[2])
        parameter_of_optimization2 = hcat(parameter_of_optimization2, temp_results_2[2])

        DELTA_OD = hcat(DELTA_OD, DELTA_OD_temp)
        AUC = hcat(AUC, AUC_temp)
        N0 = hcat(N0, mean(data_cut[2,1:4]))
        stat_time = hcat(stat_time, stationary_phase_start_temp)

    end

        # writing results ODE
         
     #   CSV.write(
      #      string(path_to_results, label_exp, "_parameters_", model, ".csv"),
      #      Tables.table(Matrix(parameter_of_optimization)),
     #   )

        # writing results  log-lin

      #  CSV.write(
     #       string(path_to_results, label_exp, "_parameters_log-lin.csv"),
      #      Tables.table(Matrix(results_Log_Lin)),
     #   )

        results_DF = vcat(parameter_of_optimization,
            parameter_of_optimization2[3:end,:],
            results_Log_Lin[3:end,:],
            DELTA_OD,
            AUC,
            stat_time,
            N0,
        )

        CSV.write(
            string(path_to_results, label_exp, "_total_parameters_df.csv"),
            Tables.table(Matrix(results_DF)),
        )

end



function find_stationary_phase(data;percentile_thr=0.05,pt_smooth_derivative=7,win_size=5,thr_od=0.02)
    
    index_od = findall(data[2,:] .> thr_od)
    if length(index_od) == 0
        return nothing
    end
    data_t = data[:,index_od]
    specific_growth_rate = Kinbiont.specific_gr_evaluation(data_t,pt_smooth_derivative)
    thr = maximum(specific_growth_rate) * percentile_thr
    maximum_index = argmax(specific_growth_rate)
    index = findall(specific_growth_rate .> thr)
    if length(index) > win_size

    # find the first point after maximum where the growth rate is lower than the threshold
    for i in maximum_index:(length(specific_growth_rate).-win_size)

        if all(specific_growth_rate[i:(i+win_size-1)] .< thr)
            # Snap to OD peak within the next win_size points.
            # The SGR threshold detects deceleration, but OD may still rise
            # for a few timepoints before the true plateau is reached.
            base_idx    = i + index_od[1] - 1
            search_end  = min(base_idx + win_size, size(data, 2))
            peak_offset = argmax(data[2, base_idx:search_end])
            cutoff_idx  = base_idx + peak_offset - 1
            return data[:,1:cutoff_idx]
        end
    end

end
    return nothing
end






function plot_ODE(
    label_exp,
    data,
    fit_times,
    fit,
    model_string,
    well_name,
    stationary_phase_start;
     path_to_plot="NA", # path where to save Plots
     display_plots=true,# display plots in julia or not
     save_plots=false, # save the plot or not
     x_size=700,
     y_size =500,
     guidefontsize=18,
     tickfontsize=16,
     legendfontsize=10,
     )

 # plotting standard fits



        Plots.scatter(
            data[1,:],
             data[2,:],
             xlabel="Time",
             ylabel="OD [arb. units]",
             label=["Data " nothing],
             markersize=4,
             color=:black,
             title=string(label_exp, " ", well_name),
             guidefontsize=guidefontsize,
             tickfontsize=tickfontsize,
             legendfontsize=legendfontsize,
             size=(x_size,y_size),
         )

         Plots.vline!(
            [ fit_times[1],fit_times[end]],
            c=:black,
            lines = 2,
            label=[string("Start of stat. phase ") nothing],
            guidefontsize=guidefontsize,
            tickfontsize=tickfontsize,
            legendfontsize=legendfontsize,
            size=(x_size,y_size),

        )
       if length(fit_times) == length(fit)
         display(
             Plots.plot!(
                fit_times,
                 fit,
                 xlabel="Time",
                 ylabel="OD [arb. units]",
                 label=[string("Fitting ", model_string) nothing],
                 c=:red,
                 lines = 4,
                 alpha = 0.5,
                 guidefontsize=guidefontsize,
                 tickfontsize=tickfontsize,
                 legendfontsize=legendfontsize,
                 size=(x_size,y_size),
             ),
         )
       end

         if save_plots
            mkpath(path_to_plot)

             savefig(string(path_to_plot, label_exp, "_", model_string, "_", well_name, ".svg"))
         end



end


function plot_log_lin(
    label_exp,
    data,
    fit,
    results_lin_log_fit;
     path_to_plot="NA", # path where to save Plots
     display_plots=true,# display plots in julia or not
     save_plots=true, # save the plot or not
     x_size=700,
      y_size =500,
     guidefontsize=18,
     tickfontsize=16,
     legendfontsize=10,
     )

     fit_temp =fit
     data_temp =data
     y_fit_temp =fit_temp[:,2]
     x_fit_temp =fit_temp[:,1]
     y_data_temp =data_temp[2,:]
     x_data_temp =data_temp[1,:]
     well_name =results_lin_log_fit[2]
     label_exp =results_lin_log_fit[1]
     coeff_1 =results_lin_log_fit[12]
     coeff_2 =results_lin_log_fit[7]


   y_fit_temp =fit_temp[:,2]
   x_fit_temp =fit_temp[:,1]
   y_data_temp =data_temp[2,:]
   x_data_temp =data_temp[1,:]


       Plots.scatter(
           x_data_temp,
           log.(y_data_temp),
           xlabel="Time",
           ylabel="Log(Arb. Units)",
           label=["Log Data " nothing],
           markersize=1,
           color=:black,
           title=string(label_exp, " ", well_name),
           guidefontsize=guidefontsize,
           tickfontsize=tickfontsize,
           legendfontsize=legendfontsize,
           size=(x_size,y_size),

       )

       Plots.plot!(
           x_fit_temp,
           y_fit_temp,
           xlabel="Time ",
           ylabel="Log(Arb. Units)",
           label=[string("Fitting Log-Lin ") nothing],
           c=:red,
           guidefontsize=guidefontsize,
           tickfontsize=tickfontsize,
           legendfontsize=legendfontsize,
           size=(x_size,y_size),

       ),
   
   display(
       Plots.vline!(
           [x_fit_temp[1], x_fit_temp[end]],
           c=:black,
           label=[string("Window of exp. phase ") nothing],
           guidefontsize=guidefontsize,
           tickfontsize=tickfontsize,
           legendfontsize=legendfontsize,
           size=(x_size,y_size),

       ),
   )
   if save_plots
        mkpath(path_to_plot)

       savefig(string(path_to_plot, label_exp, "_Log_Lin_Fit_", well_name, ".svg"))
   end


end