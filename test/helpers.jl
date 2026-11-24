# Shared fixtures for the tests.

# Run `f` with its printed output thrown away. The solver and the projection
# print progress tables that would otherwise bury the test results.
quietly(f) = redirect_stdout(f, devnull)

# A parameter set with a toy tax system whose answers can be worked out by hand.
# Dollar amounts equal model units (mu_dollar = 1), every income type is taxed
# as ordinary income, and there is no consumption or lump-sum tax.
#
#   Single brackets:  10% to 50, 20% to 100, 30% above
#   Joint brackets:   the same with every threshold doubled
#   Payroll tax:      10% up to 100
#   Benefit taxation: thresholds 20 and 40
function toy_tax_params()
    par = create_params()
    par[:mu_dollar]       = 1.0
    par[:ord_brackets]    = Float64[0, 50, 100]
    par[:ord_rates]       = Float64[0.10, 0.20, 0.30]
    par[:pref_brackets]   = Float64[0, 50]
    par[:pref_rates]      = Float64[0.0, 0.15]
    par[:ord_brackets_mfj]  = 2 .* par[:ord_brackets]
    par[:ord_rates_mfj]     = copy(par[:ord_rates])
    par[:pref_brackets_mfj] = 2 .* par[:pref_brackets]
    par[:pref_rates_mfj]    = copy(par[:pref_rates])
    par[:theta_lab_ORD]   = 1.0
    par[:theta_corp_ORD]  = 1.0
    par[:theta_pass_ORD]  = 1.0
    par[:theta_corp_PREF] = 0.0
    par[:payroll_rate]    = 0.10
    par[:payroll_cap]     = 100.0
    par[:tau_con]         = 0.0
    par[:tau_lumpsum]     = 0.0
    par[:ss_tax_use_provisional] = true
    par[:ss_tax_thresh1]  = 20.0
    par[:ss_tax_thresh2]  = 40.0
    par
end

# A benefit formula with bend points at AIME 1 and 5 (in model units).
toy_pia_params(; first_rr = 0.9, second_rr = 0.32, third_rr = 0.15) = Dict{Symbol,Any}(
    :ss_bend1 => 1000.0, :ss_bend2 => 5000.0, :mu_dollar => 1000.0,
    :first_rr => first_rr, :second_rr => second_rr, :third_rr => third_rr,
    :spousal_cap => 0.1, :min_benefit_floor => 0.0)

# A full parameter set shrunk so the household problem solves in seconds:
# 8 asset points, 2 productivity states, and 2 permanent types.
function tiny_model_params(; kwargs...)
    par = create_params()
    par[:n_a] = 8
    par[:n_z] = 2
    par[:a_max] = 20.0
    par[:z_perm_vals] = [0.0, 0.5]
    par[:p_perm_vals] = [0.5, 0.5]
    par[:max_iter_equil] = 2
    for (k, v) in kwargs
        par[k] = v
    end
    par
end
