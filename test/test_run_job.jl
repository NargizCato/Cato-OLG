# The AWS Batch entry point: reading jobs, converting JSON values, building
# parameters and projection keywords, and writing results. The last test set
# runs whole jobs into a temporary folder.

@testset "coerce: JSON values to the types the model expects" begin
    @test coerce(67, 70.0) === 70                       # Integer parameters stay Int.
    @test coerce(0, 0.25) === 0.25                      # ...unless the value is fractional.
    @test coerce(0.1, 1) === 1.0
    @test coerce(176100.0, "Inf") === Inf
    @test coerce(true, false) === false
    @test coerce([0.1, 0.2], [1, 2]) == [1.0, 2.0]
    @test coerce([0.1, 0.2], [1, 2]) isa Vector{Float64}
    @test coerce("wage", "cpi") == "cpi"

    @test coerce_keyword(:n_years, 30.0) === 30
    @test coerce_keyword(:reform_year, 2030.0) === 2030
    @test coerce_keyword(:g_A, 1) === 1.0
    @test coerce_keyword(:cola_cap, true) === true
    @test coerce_keyword(:payroll_cap, "Inf") === Inf
    @test coerce_keyword(:ss_cola, "cpi") == "cpi"
    @test coerce_keyword(:dep_path, [1, 2]) == [1.0, 2.0]
    sp = coerce_keyword(:scenario_periods, [Dict("year_start" => 2030.0, "year_end" => 2040, "g_A" => 0)])
    @test sp[1][:year_start] === 2030 && sp[1][:year_end] === 2040 && sp[1][:g_A] === 0.0
end

@testset "build_params" begin
    par = build_params(Dict("J_retire" => 70, "payroll_rate" => 0.124,
                            "payroll_cap" => "Inf", "p_perm_vals" => [1, 0, 0, 0]))
    @test par[:J_retire] === 70
    @test par[:payroll_rate] === 0.124
    @test par[:payroll_cap] === Inf
    @test par[:p_perm_vals] == [1.0, 0.0, 0.0, 0.0]
    @test par[:J_start] === create_params()[:J_start]      # Untouched keys keep defaults.
    @test build_params(Dict()) == create_params()
    err = try build_params(Dict("payroll_tax_rate" => 0.1)); nothing catch e; e end
    @test err isa ErrorException
    @test occursin("Unknown parameter", sprint(showerror, err))
end

@testset "projection_kwargs" begin
    kw0 = projection_kwargs(Dict())
    # Every calibrated README value is filled in when the job sets nothing.
    for (k, v) in pairs(CALIBRATED_PROJECTION)
        @test kw0[k] == v
    end
    @test kw0[:dep_path] === dep_fit

    kw = projection_kwargs(Dict("n_years" => 75, "g_A" => 1e-2, "cola_cap" => true,
                                "trust_fund_init" => 28_000, "inflation" => 0.03))
    @test kw[:n_years] === 75 && kw[:g_A] === 0.01
    @test kw[:cola_cap] === true
    @test kw[:trust_fund_init] === 28000.0
    @test kw[:inflation] === 0.03                         # Job values override the defaults.
    @test kw[:trust_fund_rate] === CALIBRATED_PROJECTION.trust_fund_rate

    @test !haskey(drop(kw, PROJECT_ONLY), :cola_cap)
    @test haskey(drop(kw, STATIC_ONLY), :cola_cap)

    # Every keyword a job can produce is accepted by the function it is passed to.
    proj_kws   = Set(Base.kwarg_decl(only(methods(project_economy))))
    static_kws = Set(Base.kwarg_decl(only(methods(static_score_economy))))
    @test issubset(keys(drop(kw0, STATIC_ONLY)), proj_kws)
    @test issubset(keys(drop(kw0, PROJECT_ONLY)), static_kws)
    @test issubset(Set(PROJECT_ONLY), proj_kws)
    @test issubset(Set(STATIC_ONLY), static_kws) && isdisjoint(Set(STATIC_ONLY), proj_kws)
    # Known bug: static_score_economy now accepts the COLA-cap keywords too,
    # but main() still drops PROJECT_ONLY before the static run, so a job with
    # "cola_cap": true gets a static score without the cap.
    @test_broken isdisjoint(Set(PROJECT_ONLY), static_kws)
end

@testset "lookup tables" begin
    @test lookup(BENEFIT_FNS, "benefits_current_law", "benefit rule") === benefits_current_law
    @test length(BENEFIT_FNS) == 5
    @test lookup(AIME_MODIFIERS, "caregiver_modifier", "AIME modifier") === caregiver_modifier
    err = try lookup(BENEFIT_FNS, "nope", "benefit rule"); nothing catch e; e end
    @test occursin("Unknown benefit rule \"nope\"", sprint(showerror, err))
end

@testset "read_job" begin
    @test read_job("{\"label\": \"x\"}")["label"] == "x"
    @test read_job("  {\"reform_year\": 2030}")["reform_year"] == 2030
    mktempdir() do dir
        f = joinpath(dir, "job.json")
        write(f, "{\"label\": \"from file\", \"params\": {\"J_retire\": 70}}")
        job = read_job(f)
        @test job["label"] == "from file"
        @test job["params"]["J_retire"] == 70
    end
end

@testset "the existing selftest still passes" begin
    @test (quietly(selftest); true)
end

# Runs `main` on a job and returns the written summary and the workbook's sheets.
function run_job_in(dir, job::AbstractDict)
    withenv("OUTPUT_DIR" => dir, "OUTPUT_S3_URI" => nothing) do
        quietly(() -> main(JSON.json(job)))
    end
    prefix = get(job, "output_prefix", "score")
    summary = JSON.parsefile(joinpath(dir, "$prefix.json"))
    # XLSX leaves its default empty "Sheet1" in the workbook, so read only
    # the sheets the summary names.
    sheets = XLSX.openxlsx(joinpath(dir, "$prefix.xlsx")) do xf
        Dict(name => DataFrame(XLSX.gettable(xf[name])) for name in keys(summary))
    end
    summary, sheets
end

@testset "main: whole jobs" begin
    short = Dict("n_years" => 10)

    @testset "baseline only" begin
        mktempdir() do dir
            summary, sheets = run_job_in(dir, Dict("projection" => short, "output_prefix" => "base"))
            @test collect(keys(summary)) == ["Baseline"]
            @test summary["Baseline"]["label"] == "Current Law"
            for k in ("actuarial_balance_pct", "annual_balance_75_pct", "depletion_year")
                @test haskey(summary["Baseline"], k)
            end
            df = sheets["Baseline"]
            @test nrow(df) == 10
            @test df.year == 2025:2034
            @test names(df) == names(proj_to_df(quietly(() -> project_economy(ss; n_years = 3))))
        end
    end

    @testset "reform needs a reform year" begin
        err = try
            mktempdir(dir -> run_job_in(dir, Dict("benefit_fn" => "benefits_earnings_sharing",
                                                  "projection" => short)))
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("reform_year", sprint(showerror, err))
    end

    @testset "unknown benefit rule is rejected" begin
        @test_throws ErrorException mktempdir(dir -> run_job_in(dir, Dict("benefit_fn" => "nope")))
    end

    # A reform job on the tiny model: solves a reform steady state, then
    # writes the Baseline, Dynamic and Static scores.
    @testset "reform with dynamic and static scores" begin
        tiny = Dict("n_a" => 8, "n_z" => 2, "a_max" => 20.0, "z_perm_vals" => [0.0, 0.5],
                    "p_perm_vals" => [0.5, 0.5], "max_iter_equil" => 1, "J_retire" => 68)
        mktempdir() do dir
            summary, sheets = run_job_in(dir, Dict("label" => "Tiny reform", "reform_year" => 2028,
                                                   "params" => tiny, "projection" => short))
            @test Set(keys(summary)) == Set(["Baseline", "Dynamic", "Static"])
            @test summary["Dynamic"]["label"] == "Tiny reform"
            @test summary["Static"]["label"] == "Tiny reform (static)"
            @test summary["Dynamic"]["change_lab"] isa Real
            @test all(nrow(df) == 10 for df in values(sheets))
            # "static": false skips the static score.
            summary2, _ = run_job_in(mktempdir(), Dict("reform_year" => 2028, "params" => tiny,
                                                       "projection" => short, "static" => false))
            @test Set(keys(summary2)) == Set(["Baseline", "Dynamic"])
        end
    end
end
