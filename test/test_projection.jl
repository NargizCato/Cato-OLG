# project_economy and static_score_economy, run on the cached baseline `ss`.
# The tests check accounting identities and how inputs flow through, not the
# projected values themselves.

const NY = 20          # A short horizon keeps the tests fast.

project(; kw...) = quietly(() -> project_economy(ss; n_years = NY, start_year = 2025, kw...))
static(; kw...)  = quietly(() -> static_score_economy(ss; n_years = NY, start_year = 2025, kw...))

@testset "dependency path and cap path helpers" begin
    d = build_dependency_path(50; dep_start = 0.3, dep_end = 0.5)
    @test length(d) == 50
    @test issorted(d)
    @test 0.3 < d[1] < d[end] < 0.5
    @test awi_cap_path(100.0, [1.0, 1.1, 1.21]) ≈ [100.0, 110.0, 121.0]
end

function check_identities(p)
    n = length(p.year)
    @testset "accounting identities" begin
        for f in (:dep_ratio, :GDP_nominal, :GDP_real, :taxable_payroll_nom, :fica_revenue_nom,
                  :ss_outlays_nom, :ss_balance_nom, :trust_fund_nom, :ss_cost_rate,
                  :ss_balance_pct, :debt_nom, :debt_to_gdp, :payroll_cap_nom)
            @test length(getproperty(p, f)) == n
            @test all(isfinite, getproperty(p, f))
        end
        # Program income is payroll tax plus benefit taxes plus interest.
        @test p.ss_total_income_nom ≈ p.fica_revenue_nom .+ p.ss_benefit_tax_oasi_nom .+ p.trust_fund_interest_nom
        @test p.ss_balance_nom ≈ p.ss_total_income_nom .- p.ss_outlays_nom
        @test p.ss_benefit_tax_total_nom ≈ p.ss_benefit_tax_oasi_nom .+ p.ss_benefit_tax_hi_nom
        # The trust fund grows by each year's balance.
        @test p.trust_fund_nom[2:end] ≈ p.trust_fund_nom[1:end-1] .+ p.ss_balance_nom[2:end]
        # Rates are shares of taxable payroll.
        @test p.ss_cost_rate ≈ p.ss_outlays_nom ./ p.taxable_payroll_nom .* 100 rtol = 1e-9
        @test p.ss_balance_pct ≈ p.ss_balance_nom ./ p.taxable_payroll_nom .* 100 rtol = 1e-9
        @test p.debt_to_gdp ≈ p.debt_nom ./ p.GDP_nominal
        @test all(p.taxable_payroll_nom .<= p.total_pay_nom .* (1 + 1e-9))
        # Depletion and deficit years are the first years the series turn negative.
        neg = findfirst(<(0), p.trust_fund_nom)
        @test p.depletion_year == (isnothing(neg) ? nothing : p.year[neg])
        cf = findfirst(<(0), p.ss_cash_flow_nom)
        @test p.cashflow_deficit_year == (isnothing(cf) ? nothing : p.year[cf])
        # Only project_economy reports this flag; static_score_economy does not.
        hasproperty(p, :deficit_eliminated) &&
            @test p.deficit_eliminated == (p.actuarial_balance_pct >= 0)
    end
end

@testset "project_economy" begin
    p = project(g_A = 0.012, inflation = 0.025)
    @test collect(p.year) == collect(2025:2025+NY-1)
    @test p.label == "Current Law"
    check_identities(p)

    # Growth and price indexes compound from 1 in the first year.
    @test p.price_level[1] == 1.0
    @test p.price_level[end] ≈ 1.025^(NY - 1)
    @test p.cum_productivity[end] ≈ 1.012^(NY - 1)
    @test p.cola_inflation_annual == p.inflation_annual       # COLA follows CPI by default.
    # The taxable maximum starts at its base and grows with average wages.
    @test p.payroll_cap_nom[1] ≈ 176100.0
    @test p.payroll_cap_nom[end] ≈ 176100.0 * (1 + 0.012 + 0.025)^(NY - 1)
    # Without a reform there is nothing to score.
    @test isnothing(p.change_lab) && isnothing(p.score_lab)

    # A supplied dependency path is used as given, and padded if short.
    dp = collect(range(0.3, 0.4, length = 5))
    p2 = project(dep_path = dp)
    @test p2.dep_ratio[1:5] ≈ dp
    @test all(p2.dep_ratio[6:end] .== 0.4)

    # Scenario periods override growth only inside their years.
    p3 = project(g_A = 0.012, inflation = 0.025, cola_inflation = 0.02,
                 scenario_periods = [Dict(:year_start => 2030, :year_end => 2034,
                                          :g_A => 0.0, :inflation => 0.05)])
    inside = 2030 .<= p3.year .<= 2034
    @test all(p3.g_A_annual[inside] .== 0.0) && all(p3.g_A_annual[.!inside] .== 0.012)
    @test all(p3.inflation_annual[inside] .== 0.05) && all(p3.inflation_annual[.!inside] .== 0.025)
    @test all(p3.cola_inflation_annual .== 0.02)

    # A GDP anchor sets the size of the economy in the first year, and GDP and
    # payroll scale with it. The retiree count is pinned to SSA covered
    # workers instead, so outlays do not.
    pa = project(gdp_anchor = 28e12)
    pb = project(gdp_anchor = 56e12)
    @test pa.GDP_nominal[1] ≈ 28e12 / 1e9 rtol = 1e-6
    @test pb.GDP_nominal ≈ 2 .* pa.GDP_nominal
    @test pb.taxable_payroll_nom ≈ 2 .* pa.taxable_payroll_nom
    @test pb.ss_outlays_nom ≈ pa.ss_outlays_nom

    # A larger starting trust fund leaves more in the fund every year.
    small = project(trust_fund_init = 1e12)
    large = project(trust_fund_init = 3e12)
    @test all(large.trust_fund_nom .> small.trust_fund_nom)
    @test large.actuarial_balance_pct > small.actuarial_balance_pct
end

@testset "a reform identical to the baseline scores zero" begin
    base = project()
    dyn = project(ss_reform = ss, reform_year = 2030, baseline_proj = base, label = "No change")
    @test dyn.label == "No change"
    @test dyn.change_lab ≈ 0 atol = 1e-8
    @test dyn.change_ab75 ≈ 0 atol = 1e-8
    @test dyn.ss_balance_nom ≈ base.ss_balance_nom
    check_identities(dyn)

    sbase = static()
    sta = static(ss_reform = ss, reform_year = 2030, baseline_proj = sbase)
    @test sta.change_lab ≈ 0 atol = 1e-8
    @test sta.ss_balance_nom ≈ sbase.ss_balance_nom
    check_identities(sta)
end

@testset "static_score_economy" begin
    s = static(g_A = 0.012, inflation = 0.025)
    @test collect(s.year) == collect(2025:2025+NY-1)
    check_identities(s)
    # The static baseline uses the same accounting as the dynamic one.
    p = project(g_A = 0.012, inflation = 0.025)
    @test s.payroll_cap_nom ≈ p.payroll_cap_nom
    # Eliminating the taxable maximum raises payroll tax revenue.
    nocap = static(ss_reform = ss, reform_year = 2027, baseline_proj = s, eliminates_cap = true)
    yr = findfirst(==(2030), nocap.year)
    @test nocap.fica_revenue_nom[yr] > s.fica_revenue_nom[yr]
end
