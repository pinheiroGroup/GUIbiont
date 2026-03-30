# =============================================================================
# ML Downstream Analysis
# =============================================================================
# spearman_correlations  — Spearman ρ between every feature and every growth param
# forest_importance      — random-forest impurity importance per feature
# =============================================================================

"""
    spearman_correlations(params, features, param_names, feature_names)
        -> Vector{Dict}

Compute Spearman rank correlation between every feature column and every
growth-parameter column.  Missing / NaN values are pairwise-excluded.

Returns a vector of Dicts, one per feature, with keys:
  "feature"      — feature name (String)
  param_name...  — ρ value (Float64, NaN when fewer than 3 valid pairs)
"""
function spearman_correlations(
    params::Matrix{Float64},
    features::Matrix{Float64},
    param_names::Vector{String},
    feature_names::Vector{String},
)::Vector{Dict{String,Any}}
    n_features = length(feature_names)
    n_params   = length(param_names)
    out = Vector{Dict{String,Any}}(undef, n_features)

    for j in 1:n_features
        row = Dict{String,Any}("feature" => feature_names[j])
        xj  = features[:, j]
        for k in 1:n_params
            yk   = params[:, k]
            mask = .!isnan.(xj) .& .!isnan.(yk)
            row[param_names[k]] = sum(mask) >= 3 ?
                Float64(corspearman(xj[mask], yk[mask])) : NaN
        end
        out[j] = row
    end
    return out
end

"""
    forest_importance(params, features, param_name_idx, feature_names;
                      n_trees=100, max_depth=5, seed=42)
        -> Vector{Dict}

Train a random forest to predict the growth parameter at column `param_name_idx`
from the feature matrix, then return impurity-based feature importances sorted
descending.

Returns a vector of Dicts with keys "feature" and "importance".
Returns an empty vector if fewer than 10 complete rows are available.
"""
function forest_importance(
    params::Matrix{Float64},
    features::Matrix{Float64},
    param_col::Int,
    feature_names::Vector{String};
    n_trees::Int  = 100,
    max_depth::Int = 5,
    seed::Int     = 42,
)::Vector{Dict{String,Any}}
    y    = params[:, param_col]
    mask = .!isnan.(y) .& all(.!isnan.(features), dims=2)[:]
    sum(mask) < 10 && return Dict{String,Any}[]

    Xm = features[mask, :]
    ym = y[mask]

    model = build_forest(ym, Xm; n_trees=n_trees, max_depth=max_depth, rng=seed)
    imp   = impurity_importance(model)

    order = sortperm(imp; rev=true)
    return [Dict{String,Any}("feature" => feature_names[i], "importance" => imp[i])
            for i in order]
end
