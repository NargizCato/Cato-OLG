# Numerical helpers, production, preferences, life tables and grids.

@testset "format_comma" begin
    @test format_comma(0) == "0"
    @test format_comma(999) == "999"
    @test format_comma(1000) == "1,000"
    @test format_comma(1234567) == "1,234,567"
    @test format_comma(1234.6) == "1,235"            # Rounds before formatting.
    @test format_comma(-1234) == "-1,234"
end

@testset "tauchen" begin
    for (n, rho) in ((2, 0.9), (5, 0.99), (7, 0.0))
        d = tauchen(n, rho, 0.1)
        @test length(d.z_grid) == n
        @test size(d.Pi) == (n, n)
        @test all(d.Pi .>= 0)
        @test all(isapprox.(sum(d.Pi, dims = 2), 1.0; atol = 1e-12))  # Rows are distributions.
        @test d.z_grid ≈ -reverse(d.z_grid)                            # Symmetric about zero.
        @test issorted(d.z_grid)
    end
    # With no persistence, tomorrow does not depend on today.
    d = tauchen(5, 0.0, 0.1)
    @test all(d.Pi[i, :] ≈ d.Pi[1, :] for i in 2:5)
end

@testset "ergodic_dist" begin
    P = [0.9 0.1; 0.3 0.7]
    pi = ergodic_dist(P)
    @test sum(pi) ≈ 1.0
    @test pi' * P ≈ pi'                     # Stationary.
    @test pi ≈ [0.75, 0.25]                 # Closed form: (0.3, 0.1) / 0.4.
    d = tauchen(5, 0.95, 0.1)
    pi5 = ergodic_dist(d.Pi)
    @test pi5' * d.Pi ≈ pi5'
    @test all(pi5 .>= -1e-12)
end

@testset "approx_interp" begin
    x = [0.0, 1.0, 3.0]
    y = [10.0, 20.0, 40.0]
    @test approx_interp(x, y, 0.0) == 10.0
    @test approx_interp(x, y, 3.0) == 40.0
    @test approx_interp(x, y, 0.5) ≈ 15.0
    @test approx_interp(x, y, 2.0) ≈ 30.0
    @test approx_interp(x, y, -5.0) == 10.0   # Flat outside the grid.
    @test approx_interp(x, y, 99.0) == 40.0
end

@testset "age_efficiency" begin
    # Quadratic in years since entry, peaking 40 years after J_start - 1.
    @test age_efficiency(20, 21) == 0.0
    @test age_efficiency(60, 21) ≈ 0.4
    @test age_efficiency(59, 21) < age_efficiency(60, 21) > age_efficiency(61, 21)
end

@testset "survival probabilities" begin
    par = create_params()
    n = par[:J_max] - par[:J_start] + 1
    for s in (survival_probs(par), survival_probs_male(par), survival_probs_female(par))
        @test length(s) == n
        @test s[end] == 0.0                   # Nobody survives past J_max.
        @test all(0 .<= s .<= 1)
    end
    @test survival_probs(par) ≈ (survival_probs_male(par) .+ survival_probs_female(par)) ./ 2 atol = 1e-12
end

@testset "production" begin
    K, L, a = 2.0, 3.0, 0.36
    Y = production(K, L, a)
    @test mpk(K, L, a) * K + mpl(K, L, a) * L ≈ Y          # Constant returns: factors exhaust output.
    @test production(2K, 2L, a) ≈ 2Y
    h = 1e-6
    @test mpk(K, L, a) ≈ (production(K + h, L, a) - production(K - h, L, a)) / 2h rtol = 1e-6
    @test mpl(K, L, a) ≈ (production(K, L + h, a) - production(K, L - h, a)) / 2h rtol = 1e-6
end

@testset "preferences" begin
    @test utility(2.0, 0.3) > utility(1.0, 0.3)            # More consumption is better.
    @test utility(1.0, 0.2) > utility(1.0, 0.5)            # More work is worse.
    @test utility(0.0, 0.3) == -1e10                       # Infeasible consumption.
    @test utility(2.0, 0.0, 0.0, 1.0) ≈ log(2.0)           # Log case, no leisure term.
    @test utility_couple(1.5, 0.3, 0.3) ≈ utility(1.5, 0.3) + 0.30 * log(0.7)
    for c in (0.1, 1.0, 7.5), s in (1.0, 2.0, 3.5)
        @test inv_mu(mu_c(c, s), s) ≈ c                    # Inverse marginal utility.
    end
    @test mu_c(0.0) == 1e10
    @test inv_mu(0.0) == 1e10

    # Hours satisfy the first-order condition gamma/(1-n) = w(1-t) c^-sigma.
    c, wz, mtr, g, s = 1.2, 2.0, 0.25, 0.30, 2.0
    n = optn(c, wz, mtr, g, s)
    @test 0.0 < n < 0.99
    @test g / (1 - n) ≈ wz * (1 - mtr) * c^(-s)
    @test optn(c, 0.0, mtr) == 0.0                          # No wage, no work.
    @test optn(c, 1e9, 0.0) == 0.99                         # Capped below full time.
    @test optn(c, 3.0, 0.2) > optn(c, 2.0, 0.2)             # Higher wage, more hours.
end

@testset "parameters and grids" begin
    p1 = create_params()
    p2 = create_params()
    p1[:payroll_rate] = 0.5
    p1[:ord_rates][1] = 0.99
    @test p2[:payroll_rate] != 0.5           # Each call returns an independent Dict.
    @test p2[:ord_rates][1] != 0.99
    @test p1[:benefit_fn] === benefits_current_law
    @test create_params(benefit_fn = benefits_earnings_sharing)[:benefit_fn] === benefits_earnings_sharing
    @test p2[:min_benefit_floor] ≈ p2[:min_benefit_floor_pct] * p2[:fpl_single_2025] / p2[:mu_dollar]

    par = tiny_model_params()
    g = setup_grids(par)
    nj = par[:n_ages]
    Jr = par[:J_retire] - par[:J_start] + 1
    @test length(g.a_grid) == par[:n_a]
    @test first(g.a_grid) == par[:a_min] && last(g.a_grid) == par[:a_max]
    @test length(g.z_grid) == par[:n_z]
    @test size(g.Pi_z) == (par[:n_z], par[:n_z])
    @test length(g.age_eff) == nj
    @test all(g.age_eff[Jr:end] .== 0.0)     # No labor productivity after retirement.
    @test length(g.surv) == length(g.surv_m) == length(g.surv_f) == nj
end

@testset "build_couple_types" begin
    par = tiny_model_params(z_perm_vals = [-0.5, 0.0, 0.5], p_perm_vals = [0.2, 0.5, 0.3])
    quietly(() -> build_couple_types(par))
    P = par[:couple_weights]
    @test length(par[:couple_types]) == 9
    @test sum(P) ≈ 1.0
    @test all(P .> 0)
    @test P ≈ P'                              # Symmetric in the two spouses.
    @test sum(ct[:weight] for ct in par[:couple_types]) ≈ 1.0

    # Stronger assortative matching puts more weight on same-type couples.
    weak = tiny_model_params(z_perm_vals = [-0.5, 0.0, 0.5], p_perm_vals = [0.2, 0.5, 0.3], rho_assort = 0.0)
    quietly(() -> build_couple_types(weak))
    @test sum(diag(P)) > sum(diag(weak[:couple_weights]))
    @test weak[:couple_weights] ≈ [0.2, 0.5, 0.3] * [0.2, 0.5, 0.3]'   # No matching: independence.
end
