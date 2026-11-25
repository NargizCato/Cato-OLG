# The AWS Batch path through run_job.jl, run here without AWS.
#
# In production the backburner Lambda (aws-platform, stacks/backburner) starts
# the container with the job JSON as its only argument and OUTPUT_S3_URI set
# to s3://<bucket>/results/<id>/, then serves <that prefix>score.json and
# score.xlsx. These tests run main() the same way, with a stand-in `aws`
# command on PATH that maps s3://bucket/key to a temporary folder, so they
# check that a job runs and its results land where the Lambda reads them.
# They do not test the Docker image or AWS permissions.

const FAKE_AWS = raw"""
#!/bin/sh
# Stand-in for `aws s3 cp SRC DST`. s3://bucket/key maps to $FAKE_S3_ROOT/bucket/key.
echo "$*" >> "$FAKE_S3_ROOT/calls.log"
[ "$FAKE_AWS_FAIL" = 1 ] && { echo "upload failed" >&2; exit 1; }
[ "$1" = s3 ] && [ "$2" = cp ] || { echo "unsupported: $*" >&2; exit 2; }
map() { case "$1" in s3://*) echo "$FAKE_S3_ROOT/${1#s3://}" ;; *) echo "$1" ;; esac; }
src=$(map "$3")
if [ "$4" = - ]; then cat "$src"; exit; fi
dst=$(map "$4")
mkdir -p "$(dirname "$dst")" && cp "$src" "$dst"
"""

# Runs f(s3_root, data_dir) with the stand-in `aws` first on PATH and a fresh
# fake bucket and local output folder. `env` adds or overrides variables.
function with_fake_aws(f; env...)
    mktempdir() do root
        bin = mkpath(joinpath(root, "bin"))
        s3 = mkpath(joinpath(root, "s3"))
        data = mkpath(joinpath(root, "data"))
        write(joinpath(bin, "aws"), FAKE_AWS)
        chmod(joinpath(bin, "aws"), 0o755)
        withenv("PATH" => bin * ":" * ENV["PATH"], "FAKE_S3_ROOT" => s3,
                "OUTPUT_DIR" => data, "OUTPUT_S3_URI" => nothing,
                "FAKE_AWS_FAIL" => nothing, (string(k) => v for (k, v) in env)...) do
            f(s3, data)
        end
    end
end

# The job argument as the Lambda builds it: json.dumps(job, separators=(",", ":")).
batch_arg(job) = JSON.json(job)

const SHORT = Dict("n_years" => 10)
const TINY_REFORM = Dict("n_a" => 8, "n_z" => 2, "a_max" => 20.0, "z_perm_vals" => [0.0, 0.5],
                         "p_perm_vals" => [0.5, 0.5], "max_iter_equil" => 1, "J_retire" => 68)

@testset "AWS Batch: results land where the Lambda reads them" begin
    with_fake_aws(OUTPUT_S3_URI = "s3://olg-bucket/results/job-123/") do s3, data
        quietly(() -> main(batch_arg(Dict("projection" => SHORT))))
        prefix = joinpath(s3, "olg-bucket", "results", "job-123")
        for f in ("score.json", "score.xlsx")
            @test isfile(joinpath(prefix, f))
            @test read(joinpath(prefix, f)) == read(joinpath(data, f))   # The local copy is what was uploaded.
        end
        summary = JSON.parsefile(joinpath(prefix, "score.json"))
        @test collect(keys(summary)) == ["Baseline"]
        @test haskey(summary["Baseline"], "actuarial_balance_pct")
        XLSX.openxlsx(joinpath(prefix, "score.xlsx")) do xf
            @test "Baseline" in XLSX.sheetnames(xf)
        end
    end
end

@testset "AWS Batch: a reform job writes every score" begin
    with_fake_aws(OUTPUT_S3_URI = "s3://olg-bucket/results/job-456/") do s3, _
        job = Dict("label" => "Tiny reform", "reform_year" => 2028, "params" => TINY_REFORM,
                   "benefit_fn" => "benefits_earnings_sharing", "aime_modifier" => nothing,
                   "projection" => SHORT, "static" => true)
        quietly(() -> main(batch_arg(job)))
        summary = JSON.parsefile(joinpath(s3, "olg-bucket", "results", "job-456", "score.json"))
        @test Set(keys(summary)) == Set(["Baseline", "Dynamic", "Static"])
        @test summary["Dynamic"]["label"] == "Tiny reform"
        XLSX.openxlsx(joinpath(s3, "olg-bucket", "results", "job-456", "score.xlsx")) do xf
            @test issubset(["Baseline", "Dynamic", "Static"], XLSX.sheetnames(xf))
        end
    end
end

@testset "AWS Batch: every field the Lambda accepts is read" begin
    # The benefit rules and AIME modifiers the Lambda allows (BENEFIT_FNS and
    # the aime_modifier check in lambda/olg.py). If either list here changes,
    # the Lambda's must change with it, or the API accepts jobs that fail.
    @test Set(keys(BENEFIT_FNS)) == Set(["benefits_current_law", "benefits_capped_spousal",
                                         "benefits_earnings_sharing", "benefits_caregiver_credits",
                                         "benefits_price_index_floor"])
    @test Set(keys(AIME_MODIFIERS)) == Set(["caregiver_modifier"])
    # A job using every field with its default value runs as a baseline.
    with_fake_aws(OUTPUT_S3_URI = "s3://b/r/") do s3, _
        job = Dict("label" => "Defaults", "params" => Dict(), "benefit_fn" => "benefits_current_law",
                   "aime_modifier" => nothing, "projection" => SHORT, "static" => true)
        quietly(() -> main(batch_arg(job)))
        @test isfile(joinpath(s3, "b", "r", "score.json"))
    end
end

@testset "AWS Batch: S3 paths" begin
    # A prefix without the trailing slash still writes inside it.
    with_fake_aws(OUTPUT_S3_URI = "s3://olg-bucket/results/no-slash") do s3, _
        quietly(() -> main(batch_arg(Dict("projection" => SHORT))))
        @test isfile(joinpath(s3, "olg-bucket", "results", "no-slash", "score.json"))
        @test isfile(joinpath(s3, "olg-bucket", "results", "no-slash", "score.xlsx"))
    end
    # A job can also be read from S3.
    with_fake_aws() do s3, data
        mkpath(joinpath(s3, "jobs"))
        write(joinpath(s3, "jobs", "job.json"), batch_arg(Dict("label" => "from s3", "projection" => SHORT)))
        @test read_job("s3://jobs/job.json")["label"] == "from s3"
        quietly(() -> main("s3://jobs/job.json"))
        @test isfile(joinpath(data, "score.json"))
        @test !isdir(joinpath(s3, "olg-bucket"))            # No OUTPUT_S3_URI, no upload.
    end
end

@testset "AWS Batch: a failed upload fails the job" begin
    # If results cannot be copied to S3, main() must throw so the container
    # exits non-zero and Batch marks the job FAILED rather than SUCCEEDED
    # with nothing for the Lambda to serve.
    with_fake_aws(OUTPUT_S3_URI = "s3://olg-bucket/results/job-789/", FAKE_AWS_FAIL = "1") do s3, _
        @test_throws ProcessFailedException quietly(() -> main(batch_arg(Dict("projection" => SHORT))))
        @test !isfile(joinpath(s3, "olg-bucket", "results", "job-789", "score.json"))
    end
    # A bad job fails before anything is uploaded.
    with_fake_aws(OUTPUT_S3_URI = "s3://olg-bucket/results/job-bad/") do s3, _
        @test_throws ErrorException quietly(() -> main(batch_arg(Dict("benefit_fn" => "nope"))))
        @test !isfile(joinpath(s3, "calls.log"))
    end
end

@testset "the container entry point runs as Batch starts it" begin
    # `julia run_job.jl '<json>'`, the Dockerfile ENTRYPOINT plus the Lambda's
    # command override, in a fresh process.
    with_fake_aws(OUTPUT_S3_URI = "s3://olg-bucket/results/proc/") do s3, _
        julia = Base.julia_cmd()
        cmd = `$julia --project=$REPO_ROOT $(joinpath(REPO_ROOT, "run_job.jl")) $(batch_arg(Dict("projection" => SHORT)))`
        @test success(pipeline(cmd; stdout = devnull, stderr = devnull))
        @test isfile(joinpath(s3, "olg-bucket", "results", "proc", "score.json"))
        bad = `$julia --project=$REPO_ROOT $(joinpath(REPO_ROOT, "run_job.jl")) $(batch_arg(Dict("benefit_fn" => "nope")))`
        @test !success(pipeline(bad; stdout = devnull, stderr = devnull))   # Non-zero exit, so Batch marks it FAILED.
        @test success(pipeline(`$julia --project=$REPO_ROOT $(joinpath(REPO_ROOT, "run_job.jl")) --selftest`;
                               stdout = devnull, stderr = devnull))           # The Docker build's own check.
    end
end
