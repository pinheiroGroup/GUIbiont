@get "/api/config" function(req::HTTP.Request)
    config_path = joinpath(@__DIR__, "..", "..", "config.json")
    if isfile(config_path)
        return JSON3.read(read(config_path, String))
    end
    return Dict("enable_clean_data_tab" => true)
end

@get "/api/models" function(req::HTTP.Request)
    model_list = sort(collect(keys(MODEL_REGISTRY)))
    return [Dict(
        "name"        => name,
        "param_names" => MODEL_REGISTRY[name].param_names,
        "model_type"  => occursin("NL", string(typeof(MODEL_REGISTRY[name]))) ? "NL" : "ODE",
    ) for name in model_list]
end

@get "/api/optimizers" function(req::HTTP.Request)
    names = sort(collect(keys(OPTIMIZER_MAP)))
    return [Dict(
        "name" => n,
        "type" => is_stochastic_optimizer(n) ? "stochastic" : "deterministic",
    ) for n in names]
end
