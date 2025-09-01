



function detect_csv_separator(file_path::String)
    # Read first few lines to detect separator
    lines = String[]
    open(file_path, "r") do file
        for i in 1:min(5, countlines(file))
            seekstart(file)
            for j in 1:i
                line = readline(file)
                if j == i
                    push!(lines, line)
                    break
                end
            end
        end
    end
    
    # Count occurrences of potential separators
    comma_count = sum(count(',', line) for line in lines)
    semicolon_count = sum(count(';', line) for line in lines)
    
    # Return the separator with higher count
    return semicolon_count > comma_count ? ';' : ','
end

function cleaning_data_synergy(path_to_data::String,
    path_to_save::String)

    mkpath(path_to_save)
    # Detect separator first
    separator = detect_csv_separator(path_to_data)
    df_GC = CSV.File(path_to_data; delim=separator, normalizenames=true)
    col_names = propertynames(df_GC)
    #searching the channels of data
    temp_data = DataFrame(df_GC)
    # Handle missing values when searching for "Time"
    col2_values = temp_data[:, col_names[2]]
    time_positions = findall(x -> !ismissing(x) && x == "Time", col2_values)
    position_start_times = time_positions
    #searching NA
    count_of_channels = 0
    
    for i in 1:length(position_start_times)
        count_of_channels += 1
        
        if count_of_channels < length(position_start_times)
            temp_data_matrix = temp_data[position_start_times[i]:(position_start_times[i+1]-1),2:end ]
            NA_of_temp_data = findfirst(ismissing.(temp_data_matrix[!, 2]))
            temp_data_matrix = temp_data_matrix[1:(NA_of_temp_data-1),: ]
            times =temp_data_matrix[:,1]
            temp_data_matrix[2:end,1] = string.([  (parse(Float64,split(times[s],":")[1])*3600 + parse(Float64,split(times[s],":")[2])*60 +parse(Float64,split(times[s],":")[3]))/60  for s in 2:length(times)])            
            temp_col_names = propertynames(        temp_data_matrix)
            temp_data_matrix = select!(temp_data_matrix, Not(temp_col_names[2]))

           
            temp_data_matrix[2:end,:] =   string.(tryparse.(Float64, replace.(temp_data_matrix[2:end,:], "," => ".")) )

            temp_data_matrix[2:end,1] = string.(tryparse.(Float64, temp_data_matrix[2:end,1])./60)
        
            CSV.write(string(path_to_save,"data_channel_",i,".csv"),temp_data_matrix, writeheader = false )

        else

            temp_data_matrix = temp_data[position_start_times[i]:end,2:end ]
            NA_of_temp_data_second_col = findfirst(ismissing.(temp_data_matrix[!, 2]))
            temp_data_matrix = temp_data_matrix[1:(NA_of_temp_data_second_col-1),: ]
            times =temp_data_matrix[:,1]
            temp_data_matrix[2:end,1] = string.([  (parse(Float64,split(times[s],":")[1])*3600 + parse(Float64,split(times[s],":")[2])*60 +parse(Float64,split(times[s],":")[3]))/60  for s in 2:length(times)])            
         
            temp_col_names = propertynames(        temp_data_matrix)
            temp_data_matrix = select!(temp_data_matrix, Not(temp_col_names[2]))

           
            temp_data_matrix[2:end,:] =   string.(tryparse.(Float64, replace.(temp_data_matrix[2:end,:], "," => ".")) )
            temp_data_matrix[2:end,1] = string.(tryparse.(Float64, temp_data_matrix[2:end,1])./60)


        
            CSV.write(string(path_to_save,"data_channel_",i,".csv"),temp_data_matrix, writeheader = false )

        end
        

    end

    
end



function read_labguru_annotation(path_to_annotation::String,
    path_to_save::String, number_of_wells::Int)

    mkpath(path_to_save)
   if number_of_wells == 96
        seq_number = 1:1:12
        seq_letters = ["A","B","C","D","E","F","G","H"]
        names_of_wells_tot = [ seq_letters[tt] .* string.(seq_number) for tt in 1:length(seq_letters)]

        names_of_wells_tot =  reduce(vcat,     names_of_wells_tot)
      
    end

   if number_of_wells == 48
     seq_number = 1:1:8
     seq_letters = ["A","B","C","D","E","F"]
     names_of_wells_tot = [ seq_letters[tt] .* string.(seq_number) for tt in 1:length(seq_letters)]

     names_of_wells_tot =  reduce(vcat,     names_of_wells_tot)
   end
   
   if number_of_wells == 6
    println("TO DO")
   end
   # Detect separator for annotation file
   annotation_separator = detect_csv_separator(path_to_annotation)
   raw_annotation = CSV.read(path_to_annotation, normalizenames=true, delim=annotation_separator, DataFrame)

   raw_annotation =  raw_annotation[1:end,4:end]
   names_of_columns = unique(raw_annotation[1:end,4])[2:end]
   names_of_columns = names_of_columns[names_of_columns .!= "Bacterium"]
   names_of_columns = names_of_columns[names_of_columns .!= "Media"]
   
   names_of_columns = vcat(["Well","Bacterium","Media"], names_of_columns )
   names_of_columns = vcat(names_of_columns,"Replicate" )   
   # names_of_columns = vcat(names_of_columns,"Concentration" )
   names_of_columns = vcat(names_of_columns,"Channels" )
   
   letters_of_wells = raw_annotation[2:end,1]
   number_of_well = raw_annotation[2:end,2]
   
   temp_list_of_wells =string.(letters_of_wells,number_of_well)
   names_of_wells = unique(string.(letters_of_wells,number_of_well))
   raw_annotation[2:end,1] = string.(letters_of_wells,number_of_well)
   full_annotation = Matrix{Any}(missing,length(names_of_wells_tot),length(names_of_columns)) 
   # names_of_blanks =  temp_list_of_wells[findall(raw_annotation[:,7] .== "b")]
   # names_of_discarded_wells = temp_list_of_wells[findall(raw_annotation[:,7] .== "X")]
   full_annotation[:,1] = names_of_wells_tot
   
   colums_raw_annotation  =  [string(raw_annotation[2,i])  for i in 1:length(raw_annotation[2,:])]
   
    # Find concentration and well annotation columns by searching row 2 content
    concentration_column = Int[]
    well_annotation_column = Int[]
    
    for i in 1:length(colums_raw_annotation)
        if colums_raw_annotation[i] == "Concentration"
            push!(concentration_column, i)
        elseif colums_raw_annotation[i] == "Well Annotation"
            push!(well_annotation_column, i)
        end
    end
    
    # If not found, use default positions for LabGuru format (after skipping first 3 columns)
    if isempty(concentration_column)
        concentration_column = [9]  # Concentration column position after column selection
    end
    
    if isempty(well_annotation_column)
        well_annotation_column = [10]  # Well Annotation column position after column selection  
    end
   
   for kk in 1:(length(names_of_wells)   ) # searching over all wells names
   
       wells_reduced_raw_data = findall(temp_list_of_wells.== names_of_wells[kk])
   
       reduced_raw_data = Matrix(raw_annotation[wells_reduced_raw_data .+ 1, :])
   
      
   
       for mm in 2:length(names_of_columns) # over metadata names
   
           metadata_oi = names_of_columns[mm]
          # println(metadata_oi)
           if metadata_oi == "Replicate"  || metadata_oi == "Channels"
                 
               temp_metadata =  reduced_raw_data[:,well_annotation_column]
   
                    
   
              if size(temp_metadata)[1]>= 1 
                splitted_inf = unique( split.(temp_metadata,"&"))
                
   
                   if splitted_inf[1][1] != "b" && splitted_inf[1][1] != "X"
   
                       if metadata_oi == "Channels" # over metadata names
   
                           full_annotation[ findall(full_annotation[:,1].== names_of_wells[kk]) ,mm] .= splitted_inf[1][1]
                       end
               
                       if metadata_oi == "Replicate" && length(splitted_inf[1])>1
   
                           full_annotation[ findall(full_annotation[:,1].== names_of_wells[kk]) ,mm] .= splitted_inf[1][2]
   
                       end
                   else
                       splitted_inf = unique( split.(temp_metadata,"&"))
   
               
                       full_annotation[ findall(full_annotation[:,1].== names_of_wells[kk]) ,2] .= splitted_inf[1][1]
   
                   end
               end
   
   
           
           else
               oi_metadata =  reduced_raw_data[reduced_raw_data[:, 4] .== metadata_oi,:]
   
               if size(oi_metadata)[1] == 1
   
                   if ismissing(oi_metadata[:,concentration_column[1]][1])
                       full_annotation[ findall(full_annotation[:,1].== names_of_wells[kk]) ,mm] = oi_metadata[:,6]
   
                   else    
                       full_annotation[ findall(full_annotation[:,1].== names_of_wells[kk]) ,mm] .= string(oi_metadata[:,6][1], "_", replace(oi_metadata[:,concentration_column[1]][1], "," => "." ))
                   end 
   
               elseif size(oi_metadata)[1] > 1
                
   
                    temp = join(oi_metadata[:,6].*"_".*oi_metadata[:,concentration_column[1]],"_")
                   full_annotation[ findall(full_annotation[:,1].== names_of_wells[kk]) ,mm] .= replace(temp, "," => "." )
                   
               end    
   
               
              
           end
       
       end    
   
    
   end
   
   # writing full annotation
   CSV.write(string(path_to_save,"annotation_clean.csv"),Tables.table(Matrix(full_annotation)), writeheader = false )
   # writing simplified annotation for each channel
   list_of_media = unique(full_annotation[:,names_of_columns .== "Media"])
   list_of_media = filter(!ismissing, list_of_media)
   
   list_of_channels = unique(full_annotation[:,end])
   list_of_channels =  filter(!ismissing, list_of_channels)
   list_of_channels = join(list_of_channels)
   list_of_channels = split(list_of_channels,"")
   list_of_channels = unique(list_of_channels)
   
   for i in 1:(size(full_annotation)[2]-1)
       if length(ismissing.(full_annotation[:,i]))>0
           full_annotation[ismissing.(full_annotation[:,i]),i] .= "X"
       end    
   end
   
   index_of_blanks = findall(full_annotation[:,2].== "b")
   
   
   
   for cc in 1:length(list_of_channels)
       for uu in 1:length(list_of_media)
         # creating simplfy notation
         reduced_notation = Matrix{Any}(missing,length(names_of_wells_tot),2) 
         reduced_notation[:,2] .= "X"
         reduced_notation[:,1] .= names_of_wells_tot
   
         temp_channel = list_of_channels[cc]
         temp_media = list_of_media[uu]
         # index of correct media
   
         index_of_correct_media = findall(Vector(full_annotation[:,names_of_columns .== "Media"][:,1]) .== temp_media)  
         # index of the blanks
         index_of_correct_blanks = intersect(index_of_correct_media,index_of_blanks)
         reduced_notation[index_of_correct_blanks,2] .= "b"
         oi_wells = setdiff(index_of_correct_media,index_of_correct_blanks) 
         
         # index of correct channel
           for ff in 1:length(oi_wells)
               if !ismissing(full_annotation[oi_wells[ff],end])
                   temp_c =split.(full_annotation[oi_wells[ff],end],"")
                   a= sum(temp_c .== temp_channel)
               if a>0.0
                   reduced_notation[oi_wells[ff],2] = join(full_annotation[oi_wells[ff],2:(end-1)],"_")
       
               end   
       
           end
       end 
       CSV.write(string(path_to_save,"annotation_channel_",temp_channel,"_media_",temp_media,".csv"),Tables.table(Matrix(reduced_notation)), writeheader = false )
   
       
     end 
   
   end  
end