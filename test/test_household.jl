# Household problem, population distribution and the steady-state solver, on
# the tiny model from helpers.jl. These check that the pieces fit together and
# return well-formed results, not that the economy matches any target.

function tiny_prices(par)
    Dict{Symbol,Any}(:w => 1.0, :pi_corp => 0.05, :pi_pass => 0.05,
                     :r_G => par[:r_G], :pK => 1.0, :beq => 0.0,
                     :psi_cap => 0.6, :psi_debt => 0.4)
end

@testset "compute_distribution_couples" begin
    par = tiny_model_params()
    grids = setup_grids(par)
    na, nz, nj = par[:n_a], par[:n_z], par[:n_ages]
    # Nobody ever saves, so everyone stays at the lowest asset point.
    x = compute_distribution_couples(par, grids, zeros(na, nz, nz, nj),
                                     zeros(na, nz, nj), zeros(na, nz, nj))
    @test size(x.x_c) == (na, nz, nz, nj)
    @test size(x.x_s1) == size(x.x_s2) == (na, nz, nj)
    total = sum(x.x_c) + sum(x.x_s1) + sum(x.x_s2)
    @test total ≈ 1.0
    @test all(x.x_c .>= 0) && all(x.x_s1 .>= 0) && all(x.x_s2 .>= 0)
    @test sum(x.x_c[2:end, :, :, :]) + sum(x.x_s1[2:end, :, :]) + sum(x.x_s2[2:end, :, :]) ≈ 0 atol = 1e-14
    # Everyone enters as a couple; widows and widowers appear only later.
    @test sum(x.x_s1[:, :, 1]) == 0 && sum(x.x_s2[:, :, 1]) == 0
    @test sum(x.x_c[:, :, :, 1]) > 0
    # With no population growth, each cohort only shrinks with age.
    alive(j) = sum(x.x_c[:, :, :, j]) * 2 + sum(x.x_s1[:, :, j]) + sum(x.x_s2[:, :, j])
    @test all(alive(j + 1) <= alive(j) + 1e-15 for j in 1:nj-1)
    # Women outlive men in the life table, so more widows (survivor2) than widowers.
    @test sum(x.x_s2) > sum(x.x_s1)

    # Savings at the top of the grid move mass to the top point.
    xt = compute_distribution_couples(par, grids, fill(par[:a_max], na, nz, nz, nj),
                                      fill(par[:a_max], na, nz, nj), fill(par[:a_max], na, nz, nj))
    @test sum(xt.x_c[end, :, :, 2:end]) ≈ sum(xt.x_c[:, :, :, 2:end])

    # Population growth makes younger cohorts larger than older ones.
    pg = tiny_model_params(g_pop = 0.02)
    xg = compute_distribution_couples(pg, setup_grids(pg), zeros(na, nz, nz, nj),
                                      zeros(na, nz, nj), zeros(na, nz, nj))
    @test sum(xg.x_c[:, :, :, 1]) > sum(x.x_c[:, :, :, 1])
end

@testset "solve_household_couples" begin
    par = tiny_model_params()
    grids = setup_grids(par)
    na, nz, nj = par[:n_a], par[:n_z], par[:n_ages]
    Jr = par[:J_retire] - par[:J_start] + 1
    hh = solve_household_couples(par, grids, tiny_prices(par), 0.0, 0.5)

    c = hh.couple
    @test size(c.V) == size(c.pol_a) == size(c.pol_c) == (na, nz, nz, nj)
    @test size(c.pol_n1) == size(c.pol_n2) == (na, nz, nz, nj)
    @test size(hh.surv1.pol_a) == size(hh.surv2.pol_a) == (na, nz, nj)
    @test size(hh.AIME1) == size(hh.AIME2) == (nz, nz)

    for arr in (c.V, c.pol_a, c.pol_c, c.pol_n1, c.pol_n2,
                hh.surv1.V, hh.surv1.pol_c, hh.surv2.V, hh.surv2.pol_c)
        @test all(isfinite, arr)
    end
    @test all(c.pol_c .> 0) && all(hh.surv1.pol_c .> 0) && all(hh.surv2.pol_c .> 0)
    @test all(c.pol_a .>= par[:a_min] - 1e-10)              # No borrowing.
    @test all(hh.surv1.pol_a .>= par[:a_min] - 1e-10)
    for n in (c.pol_n1, c.pol_n2, hh.surv1.pol_n, hh.surv2.pol_n)
        @test all(0 .<= n .< 1)
    end
    # Nobody works after the retirement age.
    @test all(c.pol_n1[:, :, :, Jr:end] .== 0) && all(c.pol_n2[:, :, :, Jr:end] .== 0)
    @test all(hh.surv1.pol_n[:, :, Jr:end] .== 0)
    # The more productive spouse (zp2 = 0.5) builds the larger AIME on average.
    @test sum(hh.AIME2) > sum(hh.AIME1)
    @test all(hh.AIME1 .>= 0) && all(hh.AIME2 .>= 0)
    @test isfinite(hh.aime_pct_change)

    # Value is increasing in assets for working-age couples.
    @test all(diff(c.V[:, 1, 1, 10]) .>= -1e-8)
end

@testset "solve_steady_state on a tiny model" begin
    par = tiny_model_params()
    ss_tiny = quietly(() -> solve_steady_state(par))

    for k in (:par, :grids, :hh_list, :x_list, :agg, :prices, :K, :L, :Y, :D,
              :w, :r_K, :KL, :ps, :dep_ratio, :worker_mass, :retiree_mass, :benefit_fn)
        @test haskey(ss_tiny, k)
    end
    @test length(ss_tiny.hh_list) == length(ss_tiny.x_list) == 4    # 2 x 2 couple types.
    @test ss_tiny.benefit_fn === benefits_current_law
    for v in (ss_tiny.K, ss_tiny.L, ss_tiny.Y, ss_tiny.w, ss_tiny.r_K)
        @test isfinite(v) && v > 0
    end
    @test ss_tiny.Y ≈ production(ss_tiny.K, ss_tiny.L, par[:alpha])
    @test ss_tiny.D ≈ par[:debt_to_gdp] * ss_tiny.Y
    @test ss_tiny.worker_mass > 0 && ss_tiny.retiree_mass > 0
    @test ss_tiny.dep_ratio ≈ ss_tiny.retiree_mass / ss_tiny.worker_mass
    for x in ss_tiny.x_list
        @test sum(x.x_c) + sum(x.x_s1) + sum(x.x_s2) ≈ 1.0
    end

    # Payroll statistics are internally consistent.
    ps = ss_tiny.ps
    @test 0 <= ps.taxable <= ps.total
    @test 0 <= ps.pct_above <= 1
    @test ps.avg_earn ≈ ps.total / ps.n_workers
    # The payroll tax cap binds on every earner: with a cap far below anyone's
    # earnings, taxable payroll is at most one cap per worker.
    low = copy(par)
    low[:payroll_cap] = 1e-6 * par[:mu_dollar]
    ps_low = payroll_stats_couples(low, ss_tiny.grids, ss_tiny.hh_list, ss_tiny.x_list, ss_tiny.prices)
    @test ps_low.total ≈ ps.total
    @test ps_low.taxable <= ps_low.n_workers * 1e-6 * (1 + 1e-9)
    @test ps_low.taxable < ps.taxable
    # The solver rescales dollars so average earnings hit the target.
    @test par[:mu_dollar] ≈ par[:target_avg_earn] / par[:avg_wage_mu]
    @test par[:avg_wage_mu] ≈ ps.avg_earn

    # Steady-state ratios read back the same aggregates.
    r = extract_ss_ratios(ss_tiny)
    @test r.Y == ss_tiny.Y && r.K == ss_tiny.K
    @test r.fica_rev ≈ par[:payroll_rate] * r.taxable_payroll
    @test r.ss_balance ≈ r.fica_rev - r.ss_ben + r.ss_benefit_tax_rev
    @test r.ss_benefit_tax_rev ≈ r.ss_benefit_tax_rev_oasi + r.ss_benefit_tax_rev_hi
    @test r.income_tax ≈ r.total_tax_rev - r.fica_rev
    @test r.dep_ratio ≈ r.retiree_mass / r.worker_mass

    # Removing the payroll tax cap leaves no earnings above it.
    no_cap = quietly(() -> solve_steady_state(tiny_model_params(payroll_cap = Inf, max_iter_equil = 1)))
    @test no_cap.ps.pct_above ≈ 0 atol = 1e-12
    @test no_cap.ps.taxable ≈ no_cap.ps.total

    # Each benefit rule runs end to end and is recorded on the result.
    for fn in (benefits_capped_spousal, benefits_earnings_sharing,
               benefits_caregiver_credits, benefits_price_index_floor)
        s = quietly(() -> solve_steady_state(tiny_model_params(max_iter_equil = 1); benefit_fn = fn))
        @test s.benefit_fn === fn
        @test isfinite(s.Y) && s.agg.SS_BEN > 0
    end
    s = quietly(() -> solve_steady_state(tiny_model_params(max_iter_equil = 1);
                                         benefit_fn = benefits_caregiver_credits,
                                         aime_modifier = caregiver_modifier))
    @test isfinite(s.Y)
end

@testset "solve_steady_state warns on unknown parameter keys" begin
    par = tiny_model_params(max_iter_equil = 1)
    par[:payroll_tax_rate] = 0.2                     # A misspelling of :payroll_rate.
    @test_logs (:warn, r"payroll_tax_rate.*possible misspelling") match_mode = :any quietly(() -> solve_steady_state(par))
end
