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
)  # returns (rankings, model, Xm) or ([], nothing, nothing)
    y    = params[:, param_col]
    mask = .!isnan.(y) .& all(.!isnan.(features), dims=2)[:]
    sum(mask) < 10 && return (Dict{String,Any}[], nothing, nothing)

    Xm = features[mask, :]
    ym = y[mask]

    model = build_forest(ym, Xm, -1, n_trees, 0.7, max_depth; rng=seed)
    imp   = impurity_importance(model)

    order    = sortperm(imp; rev=true)
    rankings = [Dict{String,Any}("feature" => feature_names[i], "importance" => imp[i])
                for i in order]
    return (rankings, model, Xm)
end

"""
    cv_r2_score(params, features, param_col;
                n_folds=5, n_trees=100, max_depth=5, seed=42)
        -> NamedTuple

Predictive-performance companion to `forest_importance`: delegates to
`DecisionTree.nfoldCV_forest` using the same hyperparameters
(`n_trees`, `max_depth`, `partial_sampling = 0.7`) as the importance
run, so the reported R² describes the very same model whose feature
importances are surfaced elsewhere in the response.

Returns a NamedTuple with fields:
  mean   — mean R² across folds (Float64, NaN if not computable)
  std    — population standard deviation across folds (Float64)
  folds  — per-fold R² values (Vector{Float64})
  n      — number of valid (label, feature) rows used (Int)

When fewer than `2 * n_folds` valid rows are available the function
returns `(mean=NaN, std=NaN, folds=Float64[], n=k)` so the route can
emit a sentinel without crashing the whole ML response.
"""
function cv_r2_score(
    params::Matrix{Float64},
    features::Matrix{Float64},
    param_col::Int;
    n_folds::Int  = 5,
    n_trees::Int  = 100,
    max_depth::Int = 5,
    seed::Int     = 42,
)::NamedTuple
    y    = params[:, param_col]
    mask = .!isnan.(y) .& all(.!isnan.(features), dims=2)[:]
    k    = sum(mask)
    if k < max(10, 2 * n_folds)
        return (mean = NaN, std = NaN, folds = Float64[], n = k)
    end
    Xm = features[mask, :]
    ym = y[mask]

    # n_subfeatures = -1 and partial_sampling = 0.7 mirror forest_importance
    # so the CV R² describes the same forest whose importances we surface.
    # nfoldCV_forest is exported from DecisionTree at the web_server.jl top
    # level — use the unqualified name to keep this module decoupled from
    # how the import is wired upstream.
    fold_r2 = nfoldCV_forest(
        ym, Xm,
        n_folds, -1, n_trees, 0.7, max_depth;
        verbose = false, rng = seed,
    )

    # DecisionTree.R2 uses the textbook 1 − SS_res/SS_tot definition. When a
    # test fold has near-zero target variance (SS_tot ≈ 0), the metric can
    # explode to large negative values which carry no useful information
    # — they all mean "RF is worse than the constant-mean predictor". Clip
    # per-fold R² to [-1, 1] so the summary is interpretable: any value at
    # the −1 floor signals "no predictive signal" without pretending the
    # raw arithmetic is meaningful.
    fold_r2_clipped = clamp.(Float64.(fold_r2), -1.0, 1.0)
    finite_r2 = filter(isfinite, fold_r2_clipped)
    μ = isempty(finite_r2) ? NaN : Statistics.mean(finite_r2)
    σ = length(finite_r2) > 1 ? Statistics.std(finite_r2; corrected = false) : 0.0
    return (mean = μ, std = σ, folds = fold_r2_clipped, n = k)
end

"""
    forest_permutation_importance(model, X, y, feature_names;
                                  n_iter=10, seed=42)
        -> Vector{Dict}

Permutation feature importance for the random forest already fitted by
`forest_importance`, delegating to `DecisionTree.permutation_importance`
(see `https://scikit-learn.org/stable/modules/permutation_importance.html`
for the algorithm reference). For each feature column the routine
shuffles its values `n_iter` times, measures the drop in R² caused by
destroying that column's signal alone, and returns the mean and
standard deviation of those drops.

Returns a `Vector{Dict}` sorted descending by mean drop, with keys
`feature`, `permutation_importance` (mean), `permutation_importance_std`.

Why this is reported next to impurity importance: impurity (Gini)
importance gives correlated features the credit of whichever one the
tree happens to split on first, so two redundant columns share the
"true" importance roughly proportionally and the absolute numbers can
be misleading. Permutation importance asks instead "how much does
destroying just this column hurt the model" — if a feature is redundant
with another column the model can still use, its permutation importance
is small even when its impurity importance is large. Reporting both
lets the reviewer see when the impurity ranking is genuine versus when
it reflects feature collinearity.

Note: permutation importance is computed on the training matrix and is
therefore model-conditional — it measures dependence within the fitted
forest, not generalisation. The companion `cv_r2_score` reports
generalisation R² for the same forest hyperparameters.
"""
function forest_permutation_importance(
    model,
    X::Matrix{Float64},
    y::Vector{Float64},
    feature_names::Vector{String};
    n_iter::Int = 10,
    seed::Int   = 42,
)::Vector{Dict{String,Any}}
    p = size(X, 2)
    p == length(feature_names) || error(
        "forest_permutation_importance: feature_names length $(length(feature_names)) ≠ X columns $p"
    )

    score(m, lab, feat) = DecisionTree.R2(lab, apply_forest(m, feat))
    # DecisionTree.permutation_importance mutates the feature matrix during
    # the shuffle loop and restores it column-by-column; pass a working
    # copy so the caller's training X is untouched if it shares storage.
    # rng can be an Integer — DecisionTree.mk_rng wraps it as a
    # MersenneTwister internally, so we avoid importing Random here.
    X_work = copy(X)
    result = DecisionTree.permutation_importance(
        model, y, X_work, score, n_iter; rng = seed,
    )

    means = vec(result.mean)
    stds  = vec(result.std)
    order = sortperm(means; rev = true)
    return [
        Dict{String,Any}(
            "feature"                    => feature_names[i],
            "permutation_importance"     => means[i],
            "permutation_importance_std" => stds[i],
        )
        for i in order
    ]
end

"""
    partial_dependence(model, X, feature_idx; n_grid=30)

Compute the partial dependence of `model`'s predictions on column `feature_idx`
of feature matrix `X`. Returns `(grid, mean_predictions)`.
"""
function partial_dependence(
    model,
    X::Matrix{Float64},
    feature_idx::Int;
    n_grid::Int = 30,
)::Tuple{Vector{Float64}, Vector{Float64}}
    col  = X[:, feature_idx]
    grid = collect(range(minimum(col), maximum(col); length=n_grid))
    X_mod = copy(X)
    means = map(grid) do val
        X_mod[:, feature_idx] .= val
        Statistics.mean(apply_forest(model, X_mod))
    end
    return grid, means
end
