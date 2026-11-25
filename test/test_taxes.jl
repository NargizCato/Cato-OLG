# Tax schedules, benefit taxation and household tax functions, on the toy tax
# system from helpers.jl.

@testset "apply_tax_schedule" begin
    br = [0.0, 10.0, 20.0]
    rt = [0.1, 0.2, 0.3]
    @test apply_tax_schedule(0.0, br, rt) == 0.0
    @test apply_tax_schedule(-5.0, br, rt) == 0.0
    @test apply_tax_schedule(5.0, br, rt) ≈ 0.5
    @test apply_tax_schedule(10.0, br, rt) ≈ 1.0
    @test apply_tax_schedule(25.0, br, rt) ≈ 1.0 + 2.0 + 1.5
    # The top rate applies without limit, and tax is continuous and increasing.
    @test apply_tax_schedule(1000.0, br, rt) ≈ 3.0 + 0.3 * 980
    incomes = 0.0:0.5:40.0
    taxes = [apply_tax_schedule(y, br, rt) for y in incomes]
    @test issorted(taxes)
    @test maximum(diff(taxes)) <= 0.3 * 0.5 + 1e-12
    # Integer bracket vectors are accepted too.
    @test apply_tax_schedule(25.0, [0, 10, 20], rt) ≈ 4.5
end

@testset "taxable_ss_benefits" begin
    par = toy_tax_params()                      # Thresholds 20 and 40.
    z = taxable_ss_benefits(0.0, 100.0, par)
    @test z.total == 0.0 && z.oasi == 0.0 && z.hi == 0.0
    # Provisional income 15 is below the first threshold.
    @test taxable_ss_benefits(30.0, 0.0, par).total == 0.0
    # Provisional income 25: half the excess over 20 is taxable, all in tier 1.
    t = taxable_ss_benefits(30.0, 10.0, par)
    @test t.total ≈ 2.5 && t.oasi ≈ 2.5 && t.hi == 0.0
    # Provisional income 55: tier 1 capped at half the benefit, total at 85%.
    t = taxable_ss_benefits(30.0, 40.0, par)
    @test t.oasi ≈ 15.0
    @test t.total ≈ 0.85 * 30.0
    @test t.hi ≈ t.total - t.oasi
    # Never more than 85% of benefits, whatever the other income.
    for other in (0.0, 30.0, 1e6)
        @test taxable_ss_benefits(30.0, other, par).total <= 0.85 * 30.0 + 1e-12
    end
end

@testset "tau_HH" begin
    par = toy_tax_params()
    T(y; ss = 0.0, c = 0.0) = tau_HH(y, 0.0, 0.0, 0.0, ss, c, par)
    @test T(0.0) == 0.0
    @test T(60.0) ≈ (0.1 * 50 + 0.2 * 10) + 0.1 * 60           # Income tax + payroll tax.
    @test T(150.0) ≈ (0.1 * 50 + 0.2 * 50 + 0.3 * 50) + 0.1 * 100   # Payroll tax capped at 100.
    @test T(100.0 + 1.0) - T(100.0) ≈ 0.3                       # Above the cap, only income tax.

    # Capital and debt income are ordinary income in the toy system.
    @test tau_HH(0.0, 60.0, 0.0, 0.0, 0.0, 0.0, par) ≈ 7.0
    @test tau_HH(0.0, 0.0, 60.0, 0.0, 0.0, 0.0, par) ≈ 7.0
    @test tau_HH(0.0, 0.0, 0.0, 60.0, 0.0, 0.0, par) ≈ 7.0

    # Consumption and lump-sum taxes add on.
    p2 = toy_tax_params(); p2[:tau_con] = 0.1; p2[:tau_lumpsum] = 2.0
    @test tau_HH(60.0, 0.0, 0.0, 0.0, 0.0, 10.0, p2) ≈ T(60.0) + 0.1 * 10 + 2.0

    # Model units scale with mu_dollar: tax in dollars, divided back by mu.
    p3 = toy_tax_params(); p3[:mu_dollar] = 2.0
    @test tau_HH(30.0, 0.0, 0.0, 0.0, 0.0, 0.0, p3) ≈ T(60.0) / 2

    # The decomposed version gives the same total.
    for (y, ss) in ((0.0, 30.0), (10.0, 30.0), (60.0, 30.0), (150.0, 50.0))
        d = tau_HH_decomposed(y, 5.0, 3.0, 2.0, ss, 4.0, par)
        @test d.total_tax ≈ tau_HH(y, 5.0, 3.0, 2.0, ss, 4.0, par)
        @test d.ss_tax_rev_oasi >= 0 && d.ss_tax_rev_hi >= 0
    end
    # No benefits, no tax revenue from benefits.
    d = tau_HH_decomposed(60.0, 0.0, 0.0, 0.0, 0.0, 0.0, par)
    @test d.ss_tax_rev_oasi == 0.0 && d.ss_tax_rev_hi == 0.0

    # Without the provisional-income formula, a flat share of benefits is taxed.
    p4 = toy_tax_params(); p4[:ss_tax_use_provisional] = false; p4[:theta_ss_ORD] = 0.5
    @test tau_HH(0.0, 0.0, 0.0, 0.0, 40.0, 0.0, p4) ≈ apply_tax_schedule(20.0, p4[:ord_brackets], p4[:ord_rates])
end

@testset "tau_HH_couple" begin
    par = toy_tax_params()           # Joint brackets are the single brackets doubled.
    single = tau_HH(60.0, 0.0, 0.0, 0.0, 0.0, 0.0, par)
    @test tau_HH_couple(60.0, 60.0, 0.0, 0.0, 0.0, 0.0, 0.0, par) ≈ 2 * single
    # Each spouse pays payroll tax up to their own cap.
    @test tau_HH_couple(150.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, par) ≈
          apply_tax_schedule(150.0, par[:ord_brackets_mfj], par[:ord_rates_mfj]) + 0.1 * 100
    @test tau_HH_couple(80.0, 80.0, 0.0, 0.0, 0.0, 0.0, 0.0, par) ≈
          apply_tax_schedule(160.0, par[:ord_brackets_mfj], par[:ord_rates_mfj]) + 0.1 * 160
    for (y1, y2, ss) in ((0.0, 0.0, 40.0), (30.0, 10.0, 40.0), (120.0, 90.0, 60.0))
        d = tau_HH_couple_decomposed(y1, y2, 5.0, 3.0, 2.0, ss, 4.0, par)
        @test d.total_tax ≈ tau_HH_couple(y1, y2, 5.0, 3.0, 2.0, ss, 4.0, par)
        @test d.ss_tax_rev_oasi >= 0 && d.ss_tax_rev_hi >= 0
    end
end

@testset "marginal tax rates on labor" begin
    par = toy_tax_params()
    @test mtr_lab(30.0, 0.0, par) ≈ 0.10 + 0.10 atol = 1e-9     # 10% bracket + payroll.
    @test mtr_lab(70.0, 0.0, par) ≈ 0.20 + 0.10 atol = 1e-9
    @test mtr_lab(130.0, 0.0, par) ≈ 0.30 atol = 1e-9           # Above the payroll cap.
    # Couple: the bracket depends on combined earnings.
    @test mtr_lab_couple(30.0, 0.0, 0.0, par) ≈ 0.20 atol = 1e-9
    @test mtr_lab_couple(30.0, 80.0, 0.0, par) ≈ 0.30 atol = 1e-9
    @test mtr_lab_couple(130.0, 0.0, 0.0, par) ≈ 0.20 atol = 1e-9  # 20% joint bracket, above the cap.
end
