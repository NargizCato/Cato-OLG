# Benefit formula, the five benefit rules, the caregiver AIME modifier and the
# AIME calculation. The toy formula has bend points at AIME 1 and 5.

@testset "compute_PIA" begin
    par = toy_pia_params()
    @test compute_PIA(0.0, par) == 0.0
    @test compute_PIA(0.5, par) ≈ 0.9 * 0.5
    @test compute_PIA(3.0, par) ≈ 0.9 * 1 + 0.32 * 2
    @test compute_PIA(8.0, par) ≈ 0.9 * 1 + 0.32 * 4 + 0.15 * 3
    # Continuous at the bend points, with the right slope in each segment.
    h = 1e-9
    for b in (1.0, 5.0)
        @test compute_PIA(b - h, par) ≈ compute_PIA(b + h, par) atol = 1e-8
    end
    slope(b) = (compute_PIA(b + 1e-6, par) - compute_PIA(b - 1e-6, par)) / 2e-6
    @test slope(0.5) ≈ 0.9 rtol = 1e-6
    @test slope(3.0) ≈ 0.32 rtol = 1e-6
    @test slope(8.0) ≈ 0.15 rtol = 1e-6
    # Bend points are in dollars, so a larger mu_dollar moves them down.
    p2 = toy_pia_params(); p2[:mu_dollar] = 2000.0
    @test compute_PIA(3.0, p2) ≈ 0.9 * 0.5 + 0.32 * 2.0 + 0.15 * 0.5
end

@testset "benefits_current_law" begin
    par = toy_pia_params()
    hi, lo = 8.0, 0.5
    Phi, Plo = compute_PIA(hi, par), compute_PIA(lo, par)
    # The lower earner gets the larger of their own PIA and half the spouse's.
    @test all(benefits_current_law(hi, lo, par, :couple) .≈ (Phi, Phi / 2))
    @test all(benefits_current_law(lo, hi, par, :couple) .≈ (Phi / 2, Phi))
    # Two similar earners keep their own PIAs.
    @test all(benefits_current_law(3.0, 2.5, par, :couple) .≈
              (compute_PIA(3.0, par), compute_PIA(2.5, par)))
    # A survivor gets the larger of the two PIAs.
    @test all(benefits_current_law(lo, hi, par, :survivor1) .≈ (Phi, 0.0))
    @test all(benefits_current_law(hi, lo, par, :survivor2) .≈ (0.0, Phi))
    # Any other status falls back to own PIAs.
    @test all(benefits_current_law(hi, lo, par, :single) .≈ (Phi, Plo))
end

@testset "benefits_capped_spousal" begin
    par = toy_pia_params()                     # spousal_cap = 0.1
    Phi = compute_PIA(8.0, par); Plo = compute_PIA(0.5, par)
    b = benefits_capped_spousal(8.0, 0.5, par, :couple)
    @test b[1] ≈ Phi
    @test b[2] ≈ Plo + 0.1                     # Top-up limited to the cap.
    # With a cap that never binds, the rule is current law.
    par[:spousal_cap] = 1e9
    for st in (:couple, :survivor1, :survivor2)
        @test all(benefits_capped_spousal(8.0, 0.5, par, st) .≈ benefits_current_law(8.0, 0.5, par, st))
    end
end

@testset "benefits_earnings_sharing" begin
    par = toy_pia_params()
    shared = compute_PIA((8.0 + 0.5) / 2, par)
    @test all(benefits_earnings_sharing(8.0, 0.5, par, :couple) .≈ (shared, shared))
    @test all(benefits_earnings_sharing(0.5, 8.0, par, :couple) .≈ (shared, shared))
    @test all(benefits_earnings_sharing(8.0, 0.5, par, :survivor1) .≈ (shared, 0.0))
    @test all(benefits_earnings_sharing(8.0, 0.5, par, :survivor2) .≈ (0.0, shared))
end

@testset "benefits_caregiver_credits" begin
    par = toy_pia_params()
    # No spousal top-up for couples; survivors keep the larger PIA.
    @test all(benefits_caregiver_credits(8.0, 0.5, par, :couple) .≈
              (compute_PIA(8.0, par), compute_PIA(0.5, par)))
    @test all(benefits_caregiver_credits(0.5, 8.0, par, :survivor1) .≈
              benefits_current_law(0.5, 8.0, par, :survivor1))
end

@testset "benefits_price_index_floor" begin
    par = toy_pia_params()
    # With a zero floor, the rule is current law.
    for st in (:couple, :survivor1, :survivor2), (a1, a2) in ((8.0, 0.5), (0.2, 0.1))
        @test all(benefits_price_index_floor(a1, a2, par, st) .≈ benefits_current_law(a1, a2, par, st))
    end
    # A floor raises low PIAs to the floor and leaves high ones alone.
    par[:min_benefit_floor] = 1.0
    b = benefits_price_index_floor(8.0, 0.1, par, :couple)
    @test b[1] ≈ compute_PIA(8.0, par)
    @test b[2] ≈ max(1.0, compute_PIA(8.0, par) / 2)
    @test all(x -> x >= 1.0, benefits_price_index_floor(0.1, 0.1, par, :couple))
end

@testset "caregiver_modifier" begin
    par = Dict{Symbol,Any}(:J_start => 21, :cg_start_age => 25, :cg_end_age => 38,
                           :cg_credit_level => 0.5, :avg_wage_mu => 2.0,
                           :cg_n_threshold => 0.10, :cg_max_years => 3)
    nw = 46
    e1 = fill(0.3, nw); e2 = zeros(nw)
    n1 = fill(0.4, nw); n2 = zeros(nw)          # Spouse 2 never works.
    r1, r2 = caregiver_modifier(copy(e1), copy(e2), n1, n2, par)
    @test r1 == e1                               # Spouse 1 is untouched.
    credited = findall(r2 .> 0)
    @test credited == 5:7                        # Ages 25-27: first eligible years, max 3.
    @test all(r2[credited] .== 1.0)              # 0.5 x average wage.

    # Spouse 2 works full time, so no credits.
    _, r2 = caregiver_modifier(copy(e1), copy(e2), n1, fill(0.5, nw), par)
    @test all(r2 .== 0)
    # Credits never lower earnings that are already above the credit.
    hi = fill(3.0, nw)
    _, r2 = caregiver_modifier(copy(e1), copy(hi), n1, n2, par)
    @test r2 == hi
    # Years outside the age window are never credited.
    par[:cg_max_years] = 100
    _, r2 = caregiver_modifier(copy(e1), zeros(nw), n1, n2, par)
    @test findall(r2 .> 0) == 5:18               # Ages 25 to 38.
end

@testset "compute_aime_couples" begin
    par = tiny_model_params()
    grids = setup_grids(par)
    nz, na, nj = par[:n_z], par[:n_a], par[:n_ages]
    prices = Dict{Symbol,Any}(:w => 1.0)
    zero_hours = zeros(na, nz, nz, nj)
    a = compute_aime_couples(par, grids, prices, 0.0, 0.0, zero_hours, zero_hours)
    @test size(a.AIME1) == (nz, nz) && size(a.AIME2) == (nz, nz)
    @test all(a.AIME1 .== 0) && all(a.AIME2 .== 0)

    # Earnings above the AIME cap count only up to the cap.
    cap = par[:ss_cap_frac] * par[:avg_wage_mu]
    full = fill(0.9, na, nz, nz, nj)
    a = compute_aime_couples(par, grids, Dict{Symbol,Any}(:w => 1e6), 0.0, 0.0, full, full)
    @test all(a.AIME1 .≈ cap) && all(a.AIME2 .≈ cap)

    # More hours, higher AIME.
    part = fill(0.2, na, nz, nz, nj)
    lo = compute_aime_couples(par, grids, prices, 0.0, 0.0, part, part)
    hi = compute_aime_couples(par, grids, prices, 0.0, 0.0, 2 .* part, 2 .* part)
    @test all(hi.AIME1 .>= lo.AIME1) && all(hi.AIME2 .>= lo.AIME2)

    # An AIME modifier is applied to the earnings histories.
    bump(e1, e2, n1, n2, p) = (e1 .+ 0.01, e2 .+ 0.02)
    m = compute_aime_couples(par, grids, prices, 0.0, 0.0, part, part; aime_modifier = bump)
    @test m.AIME1 ≈ lo.AIME1 .+ 0.01
    @test m.AIME2 ≈ lo.AIME2 .+ 0.02
end
