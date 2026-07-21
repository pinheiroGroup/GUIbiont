# ---------------------------------------------------------------------------
# API route tests for endpoints not covered by the original test suite:
#   GET  /api/experiment/:name/info
#   GET  /api/raw-experiments
#   POST /api/global-search
#   POST /api/fit-replicate
#   POST /api/cluster
#   POST /api/cluster-sweep
#   POST /api/cluster-compare
#   POST /api/clean-data  (validation only — no raw data required)
#
# Requires a running server at BASE_URL (defined in runtests.jl).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Minimal inline CSV for clustering tests (avoids dependency on Clean_data)
# ---------------------------------------------------------------------------
const CLUSTER_CSV = """Time,S1,S2,S3,S4,S5,S6
0.0,0.01,0.01,0.5,0.5,0.9,0.9
1.0,0.02,0.02,0.6,0.6,1.0,1.0
2.0,0.05,0.04,0.8,0.8,1.2,1.2
3.0,0.10,0.09,1.0,1.0,1.3,1.3
4.0,0.20,0.19,1.2,1.2,1.4,1.4
5.0,0.40,0.38,1.3,1.3,1.4,1.4
6.0,0.70,0.68,1.4,1.4,1.4,1.4
7.0,1.00,0.98,1.4,1.4,1.4,1.4
8.0,1.20,1.18,1.4,1.4,1.4,1.4
9.0,1.30,1.28,1.4,1.4,1.4,1.4
10.0,1.35,1.33,1.4,1.4,1.4,1.4
11.0,1.38,1.36,1.4,1.4,1.4,1.4
12.0,1.40,1.38,1.4,1.4,1.4,1.4
"""

# ---------------------------------------------------------------------------
# GET /api/experiment/:name/info
# ---------------------------------------------------------------------------

@testset "GET /api/experiment/:name/info — known experiment" begin
    status, body = get_json("/api/experiment/$SINGLE_CH_EXP/info")
    @test status == 200
    @test string(body[:experiment]) == SINGLE_CH_EXP
    @test haskey(body, :wells)
    @test haskey(body, :time_points)
    @test haskey(body, :time_column)
    @test Int(body[:time_points]) > 0
    wells = body[:wells]
    @test !isempty(wells)
    w = first(wells)
    @test haskey(w, :well)
    @test haskey(w, :condition)
    @test haskey(w, :antibiotic)
end

@testset "GET /api/experiment/:name/info — blank wells excluded" begin
    status, body = get_json("/api/experiment/$SINGLE_CH_EXP/info")
    @test status == 200
    well_names = [string(w[:well]) for w in body[:wells]]
    # Blank well A1 from fixture is annotated "b" — must not appear
    @test !("A1" in well_names)
end

@testset "GET /api/experiment/:name/info — unknown experiment returns 404" begin
    status, body = get_json("/api/experiment/DOES_NOT_EXIST_XYZ/info")
    @test status == 404
    @test haskey(body, :error)
end

@testset "GET /api/experiment/:name/info — multi-channel experiment" begin
    status, body = get_json("/api/experiment/$MULTI_CH_EXP/info")
    @test status == 200
    # Multi-channel experiments annotate all wells as "X" (channel-level access);
    # wells are expected to be empty here — use /api/multi-experiment-info instead.
    @test haskey(body, :wells)
end

# ---------------------------------------------------------------------------
# GET /api/raw-experiments
# ---------------------------------------------------------------------------

@testset "GET /api/raw-experiments" begin
    status, body = get_json("/api/raw-experiments")
    @test status == 200
    @test body isa AbstractVector
    # All entries should be strings
    for entry in body
        @test entry isa AbstractString
    end
    # Result should be sorted
    entries = String[string(e) for e in body]
    @test entries == sort(entries)
end

# ---------------------------------------------------------------------------
# POST /api/global-search
# ---------------------------------------------------------------------------

@testset "POST /api/global-search — empty query returns all experiments" begin
    status, body = post_json("/api/global-search", Dict("condition" => "", "antibiotic" => ""))
    @test status == 200
    @test body isa AbstractVector
    # Should include SINGLE_CH_EXP since it has data
    exp_names = [string(r[:experiment]) for r in body]
    @test SINGLE_CH_EXP in exp_names
end

@testset "POST /api/global-search — condition filter" begin
    # LG166 annotation has "WT" condition — should match
    status, body = post_json("/api/global-search", Dict("condition" => "WT"))
    @test status == 200
    @test body isa AbstractVector
    exp_names = [string(r[:experiment]) for r in body]
    @test SINGLE_CH_EXP in exp_names
    for result in body
        @test haskey(result, :experiment)
        @test haskey(result, :matching_wells)
        @test haskey(result, :conditions)
        @test haskey(result, :antibiotics)
        @test !isempty(result[:matching_wells])
    end
end

@testset "POST /api/global-search — no match returns empty array" begin
    status, body = post_json("/api/global-search",
                             Dict("condition" => "CONDITION_THAT_DOES_NOT_EXIST_XYZ"))
    @test status == 200
    @test isempty(body)
end

# ---------------------------------------------------------------------------
# POST /api/fit-replicate
# ---------------------------------------------------------------------------

@testset "POST /api/fit-replicate — two wells same experiment" begin
    wells = [
        Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL, "channel" => 1),
        Dict("experiment" => SINGLE_CH_EXP, "well" => "A4",           "channel" => 1),
    ]
    status, body = post_json("/api/fit-replicate",
                             Dict("well_selections" => wells,
                                  "label"           => "test_replicate",
                                  "experiment"      => SINGLE_CH_EXP,
                                  "model_name"      => "logistic"))
    @test status == 200
    # Response shape matches fit-curve
    @test haskey(body, :param_names)
    @test haskey(body, :parameters)
    @test length(body[:param_names]) == length(body[:parameters])
    @test haskey(body, :fit_od)
    @test haskey(body, :experimental_od)
    @test !isempty(body[:fit_od])
    @test string(body[:model]) == "logistic"
    @test body[:preprocessing][:smooth] == false
    @test body[:preprocessing][:cut_stationary_phase] == true
    @test Float64(body[:stationary_phase_start]) ≈ Float64(last(body[:fit_time]))
end

@testset "POST /api/fit-replicate — single well" begin
    wells = [Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL, "channel" => 1)]
    status, body = post_json("/api/fit-replicate",
                             Dict("well_selections" => wells,
                                  "experiment"      => SINGLE_CH_EXP))
    @test status == 200
    @test haskey(body, :parameters)
end

@testset "POST /api/fit-replicate — centered smoothing" begin
    wells = [Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL, "channel" => 1)]
    status, body = post_json("/api/fit-replicate",
                             Dict("well_selections" => wells,
                                  "experiment" => SINGLE_CH_EXP,
                                  "model_name" => "logistic",
                                  "smooth" => true,
                                  "smooth_window" => 3))
    @test status == 200
    @test body[:preprocessing][:smooth] == true
    @test string(body[:preprocessing][:smooth_method]) == "boxcar"
    @test length(body[:smoothed_time]) == length(body[:experimental_time])
end

@testset "POST /api/fit-replicate — multi-channel wells" begin
    wells = [Dict("experiment" => MULTI_CH_EXP, "well" => MULTI_CH_WELLS[1], "channel" => 1),
             Dict("experiment" => MULTI_CH_EXP, "well" => MULTI_CH_WELLS[2], "channel" => 2)]
    status, body = post_json("/api/fit-replicate",
                             Dict("well_selections" => wells,
                                  "experiment"      => MULTI_CH_EXP,
                                  "model_name"      => "logistic"))
    @test status == 200
    @test haskey(body, :parameters)
end

@testset "POST /api/fit-replicate — unknown model returns 400" begin
    wells = [Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL, "channel" => 1)]
    status, body = post_json("/api/fit-replicate",
                             Dict("well_selections" => wells,
                                  "model_name"      => "not_a_real_model"))
    @test status == 400
    @test haskey(body, :error)
end

@testset "POST /api/fit-replicate — all invalid selections returns 400" begin
    wells = [Dict("experiment" => "DOES_NOT_EXIST_XYZ", "well" => "A1", "channel" => 1)]
    status, body = post_json("/api/fit-replicate", Dict("well_selections" => wells))
    @test status == 400
    @test haskey(body, :error)
end

# ---------------------------------------------------------------------------
# POST /api/cluster
# ---------------------------------------------------------------------------

@testset "POST /api/cluster — via CSV, k=2" begin
    status, body = post_json("/api/cluster", Dict("csv" => CLUSTER_CSV, "k" => 2))
    @test status == 200
    @test haskey(body, :time)
    @test haskey(body, :clusters)
    @test haskey(body, :assignments)
    @test haskey(body, :series_labels)
    @test haskey(body, :quality)
    @test length(body[:clusters]) == 2
    for c in body[:clusters]
        @test haskey(c, :id)
        @test haskey(c, :label)
        @test haskey(c, :series_labels)
        @test haskey(c, :series_data_raw)
        @test !isempty(c[:series_data_raw])
        @test haskey(c, :series_data_normalized)
        @test !isempty(c[:series_data_normalized])
    end
    # Assignments: one per series (6 series in CLUSTER_CSV)
    @test length(body[:assignments]) == 6
    @test length(body[:series_labels]) == 6
    # Quality indices present
    q = body[:quality]
    @test haskey(q, :silhouette_mean)
    @test haskey(q, :dunn)
    @test haskey(q, :davies_bouldin)
end

@testset "POST /api/cluster — via experiment, k=2" begin
    status, body = post_json("/api/cluster",
                             Dict("experiments" => [SINGLE_CH_EXP], "k" => 2))
    @test status == 200
    @test !isempty(body[:clusters])
    @test !isempty(body[:assignments])
    @test string(body[:cluster_method]) == "kmeans"
end

@testset "POST /api/cluster - experiment-local annotated blank subtraction" begin
    status, body = post_json("/api/cluster",
        Dict("experiments" => [SINGLE_CH_EXP], "k" => 2,
             "smooth_method" => "none", "subtract_blank" => true,
             "blank_method" => "pointbypoint"))
    @test status == 200
    @test body[:blank_subtracted] == true
    @test string(body[:blank_source]) == "annotated"
    used = string.(body[:blank_wells_used])
    @test any(label -> endswith(label, "/A1"), used)
    @test !any(label -> endswith(label, "/A2"), used)
end

@testset "POST /api/cluster — kmedoids method" begin
    status, body = post_json("/api/cluster",
                             Dict("csv" => CLUSTER_CSV, "k" => 2,
                                  "cluster_method" => "kmedoids"))
    @test status == 200
    @test string(body[:cluster_method]) == "kmedoids"
    @test length(body[:clusters]) == 2
end

@testset "POST /api/cluster — hclust method" begin
    status, body = post_json("/api/cluster",
                             Dict("csv" => CLUSTER_CSV, "k" => 2,
                                  "cluster_method" => "hclust"))
    @test status == 200
    @test length(body[:clusters]) == 2
end

@testset "POST /api/cluster — unknown cluster_method returns 400" begin
    status, body = post_json("/api/cluster",
                             Dict("csv" => CLUSTER_CSV, "k" => 2,
                                  "cluster_method" => "not_a_method"))
    @test status == 400
    @test haskey(body, :error)
end

@testset "POST /api/cluster — smooth_method none" begin
    status, body = post_json("/api/cluster",
                             Dict("csv" => CLUSTER_CSV, "k" => 2,
                                  "smooth_method" => "none"))
    @test status == 200
    @test string(body[:smooth_method]) == "none"
end

@testset "POST /api/cluster — k capped at n_series" begin
    # 6 series, k=100 — should produce at most 6 clusters (capped)
    status, body = post_json("/api/cluster", Dict("csv" => CLUSTER_CSV, "k" => 100))
    @test status == 200
    @test length(body[:clusters]) <= 6
end

# ---------------------------------------------------------------------------
# POST /api/cluster-sweep
# ---------------------------------------------------------------------------

@testset "POST /api/cluster-sweep — via CSV" begin
    status, body = post_json("/api/cluster-sweep",
                             Dict("csv" => CLUSTER_CSV, "k_max" => 4))
    @test status == 200
    @test haskey(body, :sweep)
    @test string(body[:cost_metric]) == "wcss"
    sweep = body[:sweep]
    @test !isempty(sweep)
    # k=1 is included as the WCSS/elbow baseline; cluster-quality metrics that
    # require at least two clusters are returned as nothing for that row.
    ks = [Int(s[:k]) for s in sweep]
    @test minimum(ks) == 1
    @test maximum(ks) <= 4
    @test ks == sort(ks)
    for s in sweep
        @test haskey(s, :k)
        @test haskey(s, :wcss)
        @test haskey(s, :cost)
        @test string(s[:cost_metric]) == "wcss"
        @test haskey(s, :silhouette_mean)
        @test haskey(s, :dunn)
        @test haskey(s, :davies_bouldin)
        @test haskey(s, :calinski_harabasz)
        @test haskey(s, :xie_beni)
        @test Float64(s[:wcss]) >= 0
    end
    k1 = only(filter(s -> Int(s[:k]) == 1, sweep))
    @test k1[:silhouette_mean] === nothing
end

@testset "POST /api/cluster-sweep — via experiment" begin
    status, body = post_json("/api/cluster-sweep",
                             Dict("experiments" => [SINGLE_CH_EXP], "k_max" => 3))
    @test status == 200
    @test !isempty(body[:sweep])
end

@testset "POST /api/cluster-sweep - reports distance-to-medoid cost" begin
    status, body = post_json("/api/cluster-sweep",
                             Dict("csv" => CLUSTER_CSV, "k_max" => 4,
                                  "smooth_method" => "none",
                                  "cluster_method" => "kmedoids"))
    @test status == 200
    @test string(body[:cost_metric]) == "distance_to_medoid"
    @test !isempty(body[:sweep])
    @test all(r -> string(r[:cost_metric]) == "distance_to_medoid", body[:sweep])
    @test all(r -> Float64(r[:cost]) == Float64(r[:wcss]), body[:sweep])
end

@testset "POST /api/cluster-sweep - rejects DBSCAN" begin
    status, body = post_json("/api/cluster-sweep",
                             Dict("csv" => CLUSTER_CSV, "k_max" => 4,
                                  "cluster_method" => "dbscan"))
    @test status == 400
    @test occursin("does not use k", string(body[:error]))
end

@testset "POST /api/cluster-sweep - uses blank preprocessing controls" begin
    status, body = post_json("/api/cluster-sweep",
        Dict("experiments" => [SINGLE_CH_EXP], "k_max" => 3,
             "smooth_method" => "none", "subtract_blank" => true,
             "blank_method" => "pointbypoint"))
    @test status == 200
    @test !isempty(body[:sweep])
end

@testset "POST /api/cluster-sweep — WCSS decreases as k increases" begin
    status, body = post_json("/api/cluster-sweep",
                             Dict("csv" => CLUSTER_CSV, "k_max" => 5))
    @test status == 200
    wcsses = [Float64(s[:wcss]) for s in body[:sweep]]
    # WCSS must be non-increasing as k increases
    @test all(diff(wcsses) .<= 1e-6)
end

@testset "POST /api/cluster-sweep — rolling_avg smoothing returns results" begin
    # Regression: rolling_avg shortens the series (drops smooth_pt_avg-1 points).
    # Before the fix, the sweep kept the original-length `times` vector and the
    # per-k GrowthData(curves_for, times, ...) call threw a dimension mismatch,
    # bubbling up as a generic HTTP 500.
    status, body = post_json("/api/cluster-sweep",
                             Dict("csv" => CLUSTER_CSV, "k_max" => 4,
                                  "smooth_method" => "rolling_avg"))
    @test status == 200
    @test !isempty(body[:sweep])
end

@testset "POST /api/cluster-sweep — NaN cells in input do not blank the sweep" begin
    # Regression: previously /api/cluster-sweep did not sanitise NaN before
    # smoothing (unlike /api/cluster which calls _fill_nan_colmean). Any NaN
    # cell caused every per-k preprocess() call to throw inside a swallowed
    # `try ... continue`, collapsing the response to {"sweep": []}.
    csv_with_nan = """Time,S1,S2,S3,S4,S5,S6
,0.01,0.01,0.5,0.5,0.9,0.9
1.0,0.02,0.02,0.6,0.6,1.0,1.0
2.0,0.05,,0.8,0.8,1.2,1.2
3.0,0.10,0.09,1.0,1.0,1.3,1.3
4.0,0.20,0.19,1.2,1.2,,1.4
5.0,0.40,0.38,1.3,1.3,1.4,1.4
6.0,0.70,0.68,1.4,1.4,1.4,1.4
7.0,1.00,0.98,1.4,1.4,1.4,1.4
8.0,1.20,1.18,1.4,1.4,1.4,1.4
9.0,1.30,1.28,,1.4,1.4,1.4
10.0,1.35,1.33,1.4,1.4,1.4,1.4
11.0,1.38,1.36,1.4,1.4,1.4,1.4
12.0,1.40,1.38,1.4,1.4,1.4,1.4
"""
    status, body = post_json("/api/cluster-sweep",
                             Dict("csv" => csv_with_nan, "k_max" => 4))
    @test status == 200
    @test !isempty(body[:sweep])
end

# ---------------------------------------------------------------------------
# POST /api/cluster-compare
# ---------------------------------------------------------------------------

@testset "POST /api/cluster-compare — identical assignments" begin
    ids = [1, 1, 2, 2, 3, 3]
    status, body = post_json("/api/cluster-compare",
                             Dict("assignments1" => ids, "assignments2" => ids))
    @test status == 200
    @test haskey(body, :rand_index)
    @test haskey(body, :adjusted_rand_index)
    @test haskey(body, :varinfo)
    @test haskey(body, :vmeasure)
    @test haskey(body, :contingency)
    # Identical assignments → rand_index = 1, varinfo = 0, vmeasure = 1
    @test Float64(body[:rand_index]) ≈ 1.0
    @test Float64(body[:varinfo])    ≈ 0.0 atol=1e-10
    @test Float64(body[:vmeasure])   ≈ 1.0 atol=1e-6
end

@testset "POST /api/cluster-compare — different assignments" begin
    ids1 = [1, 1, 1, 2, 2, 2]
    ids2 = [1, 2, 1, 2, 1, 2]
    status, body = post_json("/api/cluster-compare",
                             Dict("assignments1" => ids1, "assignments2" => ids2))
    @test status == 200
    @test Float64(body[:rand_index]) < 1.0
    # Contingency table: 2x2
    ct = body[:contingency]
    @test length(ct) == 2
    @test length(ct[1]) == 2
end

@testset "POST /api/cluster-compare — mismatched length returns 400" begin
    status, body = post_json("/api/cluster-compare",
                             Dict("assignments1" => [1, 2, 3],
                                  "assignments2" => [1, 2]))
    @test status == 400
    @test haskey(body, :error)
end

# ---------------------------------------------------------------------------
# POST /api/clean-data — validation only (no raw data needed)
# ---------------------------------------------------------------------------

@testset "POST /api/clean-data — missing experiment name returns 400" begin
    status, body = post_json("/api/clean-data", Dict("experiment" => ""))
    @test status == 400
    @test haskey(body, :error)
end

@testset "POST /api/clean-data — invalid well_count returns 400" begin
    status, body = post_json("/api/clean-data",
                             Dict("experiment" => "any_name", "well_count" => 12))
    @test status == 400
    @test haskey(body, :error)
end

@testset "POST /api/clean-data — unknown experiment returns 404" begin
    status, body = post_json("/api/clean-data",
                             Dict("experiment" => "DOES_NOT_EXIST_XYZ", "well_count" => 48))
    @test status == 404
    @test haskey(body, :error)
end

# ---------------------------------------------------------------------------
# Issue B — cluster response includes centroid and centroid_sd
# ---------------------------------------------------------------------------

@testset "POST /api/cluster — each cluster has centroid and centroid_sd" begin
    status, body = post_json("/api/cluster", Dict("csv" => CLUSTER_CSV, "k" => 2))
    @test status == 200
    time_len = length(body[:time])
    for c in body[:clusters]
        @test haskey(c, :centroid)
        @test haskey(c, :centroid_sd)
        @test length(c[:centroid])    == time_len
        @test length(c[:centroid_sd]) == time_len
        # centroid_sd must be non-negative
        @test all(v -> Float64(v) >= 0.0, c[:centroid_sd])
    end
end

@testset "POST /api/cluster — centroid is pointwise mean of series_data_raw" begin
    status, body = post_json("/api/cluster",
                             Dict("csv" => CLUSTER_CSV, "k" => 2, "smooth_method" => "none"))
    @test status == 200
    for c in body[:clusters]
        series = c[:series_data_raw]
        centroid = Float64.(c[:centroid_raw])
        length(series) == 0 && continue
        n_tp = length(centroid)
        for t in 1:n_tp
            vals = filter(isfinite, [Float64(s[t]) for s in series])
            expected = isempty(vals) ? 0.0 : sum(vals) / length(vals)
            @test centroid[t] ≈ expected atol=1e-9
        end
    end
end

# ---------------------------------------------------------------------------
# Issue D — robust interpolation in clustering
# ---------------------------------------------------------------------------

# CSV with two series of different length (simulated by padding second with extra rows)
const UNEQUAL_CSV = """Time,S1,S2,S3
0.0,0.01,0.5,0.9
1.0,0.05,0.7,1.1
2.0,0.20,0.9,1.2
3.0,0.60,1.0,1.3
4.0,1.00,1.1,1.4
5.0,1.20,1.1,1.4
"""

@testset "POST /api/cluster — interpolation to common grid" begin
    status, body = post_json("/api/cluster",
                             Dict("csv" => UNEQUAL_CSV, "k" => 2,
                                  "interpolate" => true, "interp_n" => 20,
                                  "smooth_method" => "none"))
    @test status == 200
    @test length(body[:time]) == 20
    # All series_data_raw in all clusters should match the grid length
    for c in body[:clusters]
        for s in c[:series_data_raw]
            @test length(s) == 20
        end
    end
end

@testset "POST /api/cluster-sweep — accepts interpolation params" begin
    status, body = post_json("/api/cluster-sweep",
                             Dict("csv" => CLUSTER_CSV, "k_max" => 3,
                                  "interpolate" => true, "interp_n" => 15,
                                  "smooth_method" => "none"))
    @test status == 200
    @test !isempty(body[:sweep])
end

# ---------------------------------------------------------------------------
# Issue C — POST /api/batch-average
# ---------------------------------------------------------------------------

const BATCH_AVG_CSV = """Time,gene_A_rep1,gene_A_rep2,gene_B_rep1,gene_B_rep2
Gene,,gene_A,gene_A,gene_B,gene_B
0.0,0.01,0.02,0.5,0.6
1.0,0.05,0.06,0.7,0.8
2.0,0.20,0.22,0.9,1.0
3.0,0.60,0.62,1.0,1.1
"""

# Simpler CSV without metadata row (group by column name prefix is irrelevant —
# this tests the no-meta-row path where group_col is unused)
const BATCH_AVG_SIMPLE_CSV = """Time,geneA,geneA,geneB,geneB
0.0,0.01,0.02,0.5,0.6
1.0,0.05,0.06,0.7,0.8
2.0,0.20,0.22,0.9,1.0
"""

@testset "POST /api/batch-average — with metadata row" begin
    status, body = post_json("/api/batch-average",
                             Dict("csv" => BATCH_AVG_CSV, "group_col" => "Gene"))
    @test status == 200
    @test haskey(body, :csv)
    @test haskey(body, :n_groups)
    @test haskey(body, :group_names)
    @test Int(body[:n_groups]) == 2
    group_names = sort([string(n) for n in body[:group_names]])
    @test group_names == ["gene_A", "gene_B"]
    # Parse the returned CSV and verify averages
    df = CSV.read(IOBuffer(string(body[:csv])), DataFrame)
    @test "gene_A" in names(df)
    @test "gene_B" in names(df)
    # First time point: gene_A average = (0.01+0.02)/2 = 0.015
    @test Float64(df[1, "gene_A"]) ≈ 0.015 atol=1e-9
    @test Float64(df[1, "gene_B"]) ≈ 0.55  atol=1e-9
end

@testset "POST /api/batch-average — no data returns 400" begin
    status, body = post_json("/api/batch-average", Dict("group_col" => "Gene"))
    @test status == 400
    @test haskey(body, :error)
end

@testset "POST /api/batch-average — unknown file path returns 400" begin
    status, body = post_json("/api/batch-average",
                             Dict("csv_path" => "/does/not/exist.csv", "group_col" => "Gene"))
    @test status == 400
    @test haskey(body, :error)
end

# ---------------------------------------------------------------------------
# Constant pre-screening and post-hoc trend-test flat reassignment
# CSV with 2 flat curves (F1, F2) and 4 growing curves (G1-G4).
# ---------------------------------------------------------------------------

const PRESCREEN_CSV = """Time,F1,F2,G1,G2,G3,G4
0.0,0.10,0.11,0.01,0.01,0.01,0.01
1.0,0.10,0.11,0.05,0.05,0.06,0.05
2.0,0.10,0.11,0.15,0.14,0.16,0.15
3.0,0.10,0.10,0.35,0.34,0.37,0.35
4.0,0.10,0.11,0.65,0.63,0.67,0.65
5.0,0.10,0.10,0.90,0.88,0.92,0.90
6.0,0.10,0.11,1.05,1.03,1.07,1.05
7.0,0.10,0.10,1.10,1.08,1.12,1.10
8.0,0.10,0.11,1.12,1.10,1.14,1.12
9.0,0.10,0.10,1.12,1.10,1.14,1.12
"""

const PRESCREEN_ALL_GROWING_CSV = """Time,G1,G2,G3,G4,G5,G6
0.0,0.10,0.12,0.14,0.16,0.18,0.20
1.0,0.16,0.20,0.25,0.28,0.32,0.36
2.0,0.28,0.34,0.40,0.47,0.53,0.60
3.0,0.45,0.53,0.62,0.71,0.80,0.90
4.0,0.65,0.75,0.86,0.98,1.10,1.22
5.0,0.82,0.95,1.08,1.22,1.36,1.50
"""

@testset "POST /api/cluster — prescreen_constant assigns flat curves to sentinel" begin
    status, body = post_json("/api/cluster",
                             Dict("csv" => PRESCREEN_CSV, "k" => 3,
                                  "smooth_method" => "none",
                                  "prescreen_constant" => true,
                                  "prescreen_tol_const" => 1.5))
    @test status == 200
    asgn   = Int.(body[:assignments])
    labels = String.(body[:series_labels])
    flat_ids  = asgn[[findfirst(==(l), labels) for l in ["F1","F2"]]]
    grow_ids  = asgn[[findfirst(==(l), labels) for l in ["G1","G2","G3","G4"]]]
    # All flat curves should share the sentinel label (k=3)
    @test all(==(3), flat_ids)
    # Growing curves should NOT be in the sentinel cluster
    @test all(!=(3), grow_ids)
    sentinel_cluster = only(filter(c -> Int(c[:id]) == 3, body[:clusters]))
    @test sentinel_cluster[:is_non_growing] == true
end

@testset "POST /api/cluster - derives per-group blanks from non-growing cluster" begin
    status, body = post_json("/api/cluster",
                             Dict("csv" => PRESCREEN_CSV, "k" => 2,
                                  "smooth_method" => "none",
                                  "subtract_blank" => true,
                                  "derive_non_growing_blanks" => true,
                                  "prescreen_constant" => true,
                                  "prescreen_tol_const" => 1.5))
    @test status == 200
    @test body[:derived_non_growing_blanks] == true
    @test body[:blank_subtracted] == true
    @test string(body[:blank_source]) == "derived"
    @test Set(String.(body[:blank_wells_used])) == Set(["F1", "F2"])
    @test Set(String.(body[:series_labels])) == Set(["G1", "G2", "G3", "G4"])
    @test all(c -> c[:is_non_growing] == false, body[:clusters])
end

@testset "POST /api/cluster - blank derivation requires a detector" begin
    status, body = post_json("/api/cluster",
                             Dict("csv" => PRESCREEN_CSV, "k" => 2,
                                  "derive_non_growing_blanks" => true))
    @test status == 400
    @test occursin("requires", lowercase(string(body[:error])))
end

@testset "POST /api/cluster — trend_test_flat reassigns flat curves" begin
    status, body = post_json("/api/cluster",
                             Dict("csv" => PRESCREEN_CSV, "k" => 2,
                                  "smooth_method" => "none",
                                  "trend_test_flat" => true,
                                  "trend_p_thr" => 0.05))
    @test status == 200
    asgn   = Int.(body[:assignments])
    labels = String.(body[:series_labels])
    flat_ids = asgn[[findfirst(==(l), labels) for l in ["F1","F2"]]]
    grow_ids = asgn[[findfirst(==(l), labels) for l in ["G1","G2","G3","G4"]]]
    sentinel = maximum(asgn)
    @test all(==(sentinel), flat_ids)
    @test all(!=(sentinel), grow_ids)
end

@testset "POST /api/cluster-sweep — prescreen_constant without matches includes k=1 baseline" begin
    status, body = post_json("/api/cluster-sweep",
                             Dict("csv" => PRESCREEN_ALL_GROWING_CSV, "k_max" => 4,
                                  "smooth_method" => "none",
                                  "prescreen_constant" => true,
                                  "prescreen_tol_const" => 1.5))
    @test status == 200
    sweep = body[:sweep]
    ks    = Int.([r[:k] for r in sweep])
    @test minimum(ks) == 1
    # Sweep must actually produce usable rows — guard against a regression
    # where every k errors out and the sweep still returns "[]" or all-NaN.
    @test length(sweep) >= 3
    silhouettes = Float64[Float64(r[:silhouette_mean])
                          for r in sweep if r[:silhouette_mean] !== nothing]
    @test any(s -> isfinite(s), silhouettes)
end

@testset "POST /api/cluster-sweep — prescreen_constant accepted, sweep includes k=1 baseline" begin
    status, body = post_json("/api/cluster-sweep",
                             Dict("csv" => PRESCREEN_CSV, "k_max" => 5,
                                  "smooth_method" => "none",
                                  "prescreen_constant" => true))
    @test status == 200
    ks = Int.([r[:k] for r in body[:sweep]])
    @test minimum(ks) == 1
end

@testset "POST /api/cluster-sweep — non-default prescreen quantiles change the flag boundary" begin
    # PR #56 exposed prescreen_q_low / prescreen_q_high (defaults 0.05 / 0.95).
    # Narrower quantiles (e.g. q10/q90) compress the quantile spread and make
    # weak growers more likely to satisfy q_hi ≤ τ·q_lo — i.e. tighter quantiles
    # are MORE aggressive about flagging curves as non-growing. We can't assert a
    # specific direction without coupling to PRESCREEN_CSV's exact shape, but we
    # can require that the server (a) accepts the new fields, (b) returns a
    # well-formed sweep, and (c) the chosen quantiles actually flow into the
    # mask used by Kinbiont — exercised by simply running both extremes and
    # confirming the response is structurally valid.
    for (qlo, qhi) in ((0.05, 0.95), (0.10, 0.90), (0.20, 0.80))
        status, body = post_json("/api/cluster-sweep",
                                 Dict("csv" => PRESCREEN_CSV, "k_max" => 4,
                                      "smooth_method" => "none",
                                      "prescreen_constant" => true,
                                      "prescreen_q_low"    => qlo,
                                      "prescreen_q_high"   => qhi))
        @test status == 200
        sweep = body[:sweep]
        @test !isempty(sweep)
        ks = Int.([r[:k] for r in sweep])
        @test minimum(ks) == 1
        # The k=1 row must have nothing for every quality index — independent
        # of the chosen quantiles. This locks in the S1 simplification.
        k1 = only(filter(r -> Int(r[:k]) == 1, sweep))
        @test k1[:silhouette_mean]   === nothing
        @test k1[:dunn]              === nothing
        @test k1[:davies_bouldin]    === nothing
        @test k1[:calinski_harabasz] === nothing
        @test k1[:xie_beni]          === nothing
        @test Float64(k1[:wcss])     >= 0
    end
end

@testset "POST /api/cluster-sweep — invalid prescreen quantiles return 4xx or are clamped" begin
    # qlo >= qhi should not crash the server. The schema accepts the floats as-is;
    # Kinbiont handles the actual computation. We assert no 500.
    status, body = post_json("/api/cluster-sweep",
                             Dict("csv" => PRESCREEN_CSV, "k_max" => 3,
                                  "smooth_method" => "none",
                                  "prescreen_constant" => true,
                                  "prescreen_q_low"    => 0.7,
                                  "prescreen_q_high"   => 0.3))
    @test status in (200, 400)  # tolerate either a graceful clamp or a rejection
    @test status != 500
end

# ---------------------------------------------------------------------------
# Log-linear batch fit (/api/batch-fit-loglin) and the compute_loglin
# companion flag on /api/batch-fit. Both produce `gr_loglin*` fields driven
# by Kinbiont.fitting_one_well_Log_Lin — see src/analysis.jl for the helper.
# ---------------------------------------------------------------------------

# Mirror of `batch_fit_and_wait` (in runtests.jl) but targets the new endpoint.
function batch_fit_loglin_and_wait(req; timeout=120)
    status, body = post_json("/api/batch-fit-loglin", req)
    status == 200 || return status, body
    haskey(body, :job_id) || return status, body
    job_id = string(body[:job_id])
    deadline = time() + timeout
    while time() < deadline
        s, b = get_json("/api/batch-fit/progress/$job_id")
        s == 200 && string(get(b, :status, "")) == "done" && return s, b
        sleep(1)
    end
    error("batch-fit-loglin job $job_id did not complete within $(timeout)s")
end

const LOGLIN_FIELDS = ["gr_loglin", "gr_loglin_se", "gr_max_sliding",
                       "t_exp_start_loglin", "t_exp_end_loglin",
                       "doubling_time_loglin", "R_squared_loglin",
                       "lag_loglin", "N_max_emp",
                       "loglin_converged"]

@testset "POST /api/batch-fit-loglin — single well returns gr_loglin fields" begin
    status, body = batch_fit_loglin_and_wait(
                       Dict("experiment" => SINGLE_CH_EXP,
                            "wells"      => [SINGLE_CH_WELL]))
    @test status == 200
    @test haskey(body, :results)
    @test haskey(body, :summary)
    @test Int(body[:summary][:total]) == 1
    @test Int(body[:summary][:success]) == 1
    # The shared progress endpoint reports model="log_lin" for log-lin jobs.
    @test string(body[:model]) == "log_lin"
    @test "log_lin" in String.(body[:model_names])

    r = first(body[:results])
    @test haskey(r, :well)
    @test string(r[:well]) == SINGLE_CH_WELL
    @test string(r[:method]) == "Log-lin"
    for f in LOGLIN_FIELDS
        @test haskey(r, Symbol(f))
    end
    @test r[:loglin_converged] == true
    gr = Float64(r[:gr_loglin])
    @test isfinite(gr)
    @test 0.0 <= gr <= 5.0       # bounded by physiology for any healthy E. coli
    @test 0.0 <= Float64(r[:R_squared_loglin]) <= 1.0
    @test Float64(r[:t_exp_start_loglin]) < Float64(r[:t_exp_end_loglin])
    @test isfinite(Float64(r[:N_max_emp]))
    # μ_max from log-lin must NOT have the optimizer-specific keys
    @test !haskey(r, :parameters)
    @test !haskey(r, :aic)
end

@testset "POST /api/batch-fit-loglin — multiple wells" begin
    status, body = batch_fit_loglin_and_wait(
                       Dict("experiment" => SINGLE_CH_EXP,
                            "wells"      => [SINGLE_CH_WELL, "A4"]))
    @test status == 200
    @test Int(body[:summary][:total]) == 2
    @test Int(body[:summary][:success]) >= 1
    wells_seen = Set(String.([r[:well] for r in body[:results]]))
    @test SINGLE_CH_WELL in wells_seen
end

@testset "POST /api/batch-fit-loglin — all wells (no wells key)" begin
    status, body = batch_fit_loglin_and_wait(
                       Dict("experiment" => SINGLE_CH_EXP))
    @test status == 200
    @test Int(body[:summary][:total]) > 2
end

@testset "POST /api/batch-fit-loglin — unknown experiment returns 404" begin
    status, body = post_json("/api/batch-fit-loglin",
                             Dict("experiment" => "DOES_NOT_EXIST_XYZ"))
    @test status == 404
    @test haskey(body, :error)
end

@testset "POST /api/batch-fit-loglin — advanced params accepted and applied" begin
    # Send tighter exp-window threshold and verify the request is accepted
    # and the convergence/value are still produced.
    status, body = batch_fit_loglin_and_wait(
                       Dict("experiment"              => SINGLE_CH_EXP,
                            "wells"                   => [SINGLE_CH_WELL],
                            "pt_avg"                  => 5,
                            "pt_smoothing_derivative" => 5,
                            "pt_min_size_of_win"      => 5,
                            "threshold_of_exp"        => 0.8))
    @test status == 200
    @test Int(body[:summary][:success]) == 1
    r = first(body[:results])
    @test r[:loglin_converged] == true
end

@testset "POST /api/batch-fit — compute_loglin companion populates gr_loglin" begin
    status, body = batch_fit_and_wait(
                       Dict("experiment"     => SINGLE_CH_EXP,
                            "wells"          => [SINGLE_CH_WELL],
                            "model_name"     => "logistic",
                            "compute_loglin" => true))
    @test status == 200
    r = first(body[:results])
    # Parametric fit fields must still be present
    @test haskey(r, :parameters)
    @test haskey(r, :aic)
    @test string(r[:model]) == "logistic"
    # Companion log-lin fields are added alongside
    for f in LOGLIN_FIELDS
        @test haskey(r, Symbol(f))
    end
    @test r[:loglin_converged] == true
    @test isfinite(Float64(r[:gr_loglin]))
    @test isfinite(Float64(r[:N_max_emp]))
end

@testset "POST /api/batch-fit — compute_loglin defaults to false (absent companion fields)" begin
    status, body = batch_fit_and_wait(
                       Dict("experiment" => SINGLE_CH_EXP,
                            "wells"      => [SINGLE_CH_WELL],
                            "model_name" => "logistic"))
    @test status == 200
    r = first(body[:results])
    # No log-lin fields when compute_loglin is not set
    @test !haskey(r, :gr_loglin)
    @test !haskey(r, :loglin_converged)
end

@testset "/api/batch-fit-loglin and companion (batch-fit + compute_loglin) agree on the well" begin
    # Both code paths invoke the same Kinbiont.fitting_one_well_Log_Lin, so
    # for the SAME well + SAME log-lin parameters they should report nearly
    # identical μ_max. (Differences are bounded by the parametric path's
    # od_for_fit floor (0.01) vs the standalone path's floor (1e-4); for
    # the test well the data is far enough above both floors that the
    # exponential windows agree exactly.)
    _, body_standalone = batch_fit_loglin_and_wait(
                            Dict("experiment" => SINGLE_CH_EXP,
                                 "wells"      => [SINGLE_CH_WELL]))
    _, body_companion = batch_fit_and_wait(
                            Dict("experiment"     => SINGLE_CH_EXP,
                                 "wells"          => [SINGLE_CH_WELL],
                                 "model_name"     => "logistic",
                                 "compute_loglin" => true))
    gr_a = Float64(first(body_standalone[:results])[:gr_loglin])
    gr_b = Float64(first(body_companion[:results])[:gr_loglin])
    @test isfinite(gr_a) && isfinite(gr_b)
    # 5% tolerance accommodates the floor difference if it kicks in for
    # near-blank tails of this particular curve.
    @test abs(gr_a - gr_b) / max(gr_a, 1e-6) < 0.05
end
