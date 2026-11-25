# Unit tests for the OLG model and the run_job.jl entry point.
#
#   julia --project=. test/runtests.jl
#
# The tests check that the code does what it says: formulas, accounting
# identities, array shapes, and input handling. They do not check calibration
# targets such as the baseline actuarial balance, so a recalibration should not
# break them. Where a test needs numbers, it uses small made-up inputs whose
# answers can be worked out by hand.
#
# Including run_job.jl loads the model (source/functions_pwbm_w_spouse.jl), the
# cached baseline `ss` and `dep_fit`, and the job helpers, without running a job.

using Test

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO_ROOT, "run_job.jl"))
include(joinpath(@__DIR__, "helpers.jl"))

@testset "OLG model" begin
    include(joinpath(@__DIR__, "test_numerics.jl"))
    include(joinpath(@__DIR__, "test_taxes.jl"))
    include(joinpath(@__DIR__, "test_benefits.jl"))
    include(joinpath(@__DIR__, "test_household.jl"))
    include(joinpath(@__DIR__, "test_projection.jl"))
    include(joinpath(@__DIR__, "test_run_job.jl"))
end
