# LabGuru plate annotation parser — reader-agnostic.

"""
    read_labguru_annotation(path_to_annotation, path_to_save, number_of_wells)

Parse a LabGuru plate annotation CSV into a unified `annotation_clean.csv`
plus per-channel per-media simplified annotations in `path_to_save`.
"""
function read_labguru_annotation(path_to_annotation::String,
                                 path_to_save::String,
                                 number_of_wells::Int)
    mkpath(path_to_save)

    names_of_wells_tot = well_names_for_plate(number_of_wells)

    annotation_separator = detect_csv_separator(path_to_annotation)
    raw_annotation = CSV.read(path_to_annotation, normalizenames=true,
                               delim=annotation_separator, DataFrame)
    raw_annotation = raw_annotation[1:end, 4:end]

    names_of_columns = unique(raw_annotation[1:end, 4])[2:end]
    names_of_columns = names_of_columns[names_of_columns .!= "Bacterium"]
    names_of_columns = names_of_columns[names_of_columns .!= "Media"]
    names_of_columns = vcat(["Well", "Bacterium", "Media"], names_of_columns)
    names_of_columns = vcat(names_of_columns, "Replicate")
    names_of_columns = vcat(names_of_columns, "Channels")

    letters_of_wells   = raw_annotation[2:end, 1]
    number_of_well     = raw_annotation[2:end, 2]
    temp_list_of_wells = string.(letters_of_wells, number_of_well)
    names_of_wells     = unique(string.(letters_of_wells, number_of_well))
    raw_annotation[2:end, 1] = string.(letters_of_wells, number_of_well)

    full_annotation        = Matrix{Any}(missing, length(names_of_wells_tot), length(names_of_columns))
    full_annotation[:, 1]  = names_of_wells_tot

    row2 = [string(raw_annotation[2, i]) for i in 1:ncol(raw_annotation)]
    concentration_column   = something(findfirst(==("Concentration"),   row2), 9)
    well_annotation_column = something(findfirst(==("Well Annotation"), row2), 10)

    for kk in 1:length(names_of_wells)
        well_rows        = findall(temp_list_of_wells .== names_of_wells[kk])
        reduced_raw_data = Matrix(raw_annotation[well_rows .+ 1, :])

        for mm in 2:length(names_of_columns)
            metadata_oi = names_of_columns[mm]

            if metadata_oi == "Replicate" || metadata_oi == "Channels"
                temp_metadata        = reduced_raw_data[:, well_annotation_column]
                non_missing_metadata = filter(!ismissing, temp_metadata)
                splitted_inf = isempty(non_missing_metadata) ?
                               [["X"]] :
                               unique(split.(non_missing_metadata, "&"))

                well_idx = findall(full_annotation[:, 1] .== names_of_wells[kk])
                if splitted_inf[1][1] != "b" && splitted_inf[1][1] != "X"
                    if metadata_oi == "Channels"
                        full_annotation[well_idx, mm] .= splitted_inf[1][1]
                    elseif metadata_oi == "Replicate" && length(splitted_inf[1]) > 1
                        full_annotation[well_idx, mm] .= splitted_inf[1][2]
                    end
                else
                    full_annotation[well_idx, 2] .= splitted_inf[1][1]
                end

            else
                oi_metadata = reduced_raw_data[reduced_raw_data[:, 4] .== metadata_oi, :]
                well_idx    = findall(full_annotation[:, 1] .== names_of_wells[kk])

                if size(oi_metadata, 1) == 1
                    if ismissing(oi_metadata[:, concentration_column][1])
                        full_annotation[well_idx, mm] = oi_metadata[:, 6]
                    else
                        full_annotation[well_idx, mm] .= string(
                            oi_metadata[:, 6][1], "_",
                            replace(oi_metadata[:, concentration_column][1], "," => ".")
                        )
                    end
                elseif size(oi_metadata, 1) > 1
                    temp = join(oi_metadata[:, 6] .* "_" .* oi_metadata[:, concentration_column], "_")
                    full_annotation[well_idx, mm] .= replace(temp, "," => ".")
                end
            end
        end
    end

    CSV.write(joinpath(path_to_save, "annotation_clean.csv"),
              Tables.table(Matrix(full_annotation)), writeheader=false)

    list_of_media    = filter(!ismissing, unique(full_annotation[:, names_of_columns .== "Media"]))
    list_of_channels = unique(Iterators.flatten(
        split.(string.(filter(!ismissing, unique(full_annotation[:, end]))), "")
    ))

    for i in 1:(size(full_annotation, 2) - 1)
        if any(ismissing, full_annotation[:, i])
            full_annotation[ismissing.(full_annotation[:, i]), i] .= "X"
        end
    end

    index_of_blanks = findall(full_annotation[:, 2] .== "b")
    n_fa_cols = size(full_annotation, 2)

    for cc in 1:length(list_of_channels)
        for uu in 1:length(list_of_media)
            reduced_notation        = Matrix{Any}(missing, length(names_of_wells_tot), 2)
            reduced_notation[:, 2] .= "X"
            reduced_notation[:, 1] .= names_of_wells_tot

            temp_channel = list_of_channels[cc]
            temp_media   = list_of_media[uu]

            index_of_correct_media  = findall(
                Vector(full_annotation[:, names_of_columns .== "Media"][:, 1]) .== temp_media
            )
            index_of_correct_blanks = intersect(index_of_correct_media, index_of_blanks)
            reduced_notation[index_of_correct_blanks, 2] .= "b"
            oi_wells = setdiff(index_of_correct_media, index_of_correct_blanks)

            for ff in 1:length(oi_wells)
                row    = oi_wells[ff]
                ch_val = full_annotation[row, n_fa_cols]
                if !ismissing(ch_val)
                    if sum(split(string(ch_val), "") .== string(temp_channel)) > 0
                        reduced_notation[row, 2] =
                            join(full_annotation[row, 2:(n_fa_cols - 1)], "_")
                    end
                end
            end

            CSV.write(
                joinpath(path_to_save, "annotation_channel_$(temp_channel)_media_$(temp_media).csv"),
                Tables.table(Matrix(reduced_notation)),
                writeheader=false,
            )
        end
    end
end
