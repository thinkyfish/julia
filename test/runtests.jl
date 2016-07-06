# This file is a part of Julia. License is MIT: http://julialang.org/license
using Base.Test
include("choosetests.jl")
tests, net_on = choosetests(ARGS)
tests = unique(tests)

const max_worker_rss = if haskey(ENV, "JULIA_TEST_MAXRSS_MB")
    parse(Int, ENV["JULIA_TEST_MAXRSS_MB"]) * 2^20
else
    typemax(Csize_t)
end

const node1_tests = String[]
function move_to_node1(t)
    if t in tests
        splice!(tests, findfirst(tests, t))
        push!(node1_tests, t)
    end
end
# Base.compile only works from node 1, so compile test is handled specially
move_to_node1("compile")
move_to_node1("enums")
move_to_node1("docs")
move_to_node1("dates")
move_to_node1("string")
move_to_node1("core")
move_to_node1("int")
move_to_node1("broadcast")
move_to_node1("loading")
move_to_node1("reflection")
move_to_node1("subarray")
move_to_node1("mmap")
move_to_node1("inference")
# In a constrained memory environment, run the parallel test after all other tests
# since it starts a lot of workers and can easily exceed the maximum memory
max_worker_rss != typemax(Csize_t) && move_to_node1("parallel")

cd(dirname(@__FILE__)) do
    n = 1
    if net_on
        n = min(8, Sys.CPU_CORES, length(tests))
        n > 1 && addprocs(n; exeflags=`--check-bounds=yes --startup-file=no --depwarn=error`)
        BLAS.set_num_threads(1)
    end

    @everywhere include("testdefs.jl")
    results=[]
    @sync begin
        for p in workers()
            @async begin
                while length(tests) > 0
                    test = shift!(tests)
                    local resp
                    try
                        resp = remotecall_fetch(t -> runtests(t), p, test)
                    catch e
                        resp = [e]
                    end
                    push!(results, (test, resp))
                    if (isa(resp, Integer) && (resp > max_worker_rss)) || isa(resp, Exception)
                        if n > 1
                            rmprocs(p, waitfor=0.5)
                            p = addprocs(1; exeflags=`--check-bounds=yes --startup-file=no --depwarn=error`)[1]
                            remotecall_fetch(()->include("testdefs.jl"), p)
                        else
                            # single process testing, bail if mem limit reached, or, on an exception.
                            isa(resp, Exception) ? rethrow(resp) : error("Halting tests. Memory limit reached : $resp > $max_worker_rss")
                        end
                    end
                end
            end
        end
    end
    # Free up memory =)
    n > 1 && rmprocs(workers(), waitfor=5.0)
    for t in node1_tests
        n > 1 && print("\tFrom worker 1:\t")
        local resp
        try
            resp = runtests(t)
        catch e
            resp = [e]
        end
        push!(results, (t, resp))
    end

    o_ts = Base.Test.DefaultTestSet("Overall")
    Base.Test.push_testset(o_ts)
    for res in results
        if isa(res[2][1], Exception)
             Base.showerror(STDERR,res[2][1])
        elseif isa(res[2][1], Base.Test.DefaultTestSet)
             Base.Test.push_testset(res[2][1])
             Base.Test.record(o_ts, res[2][1])
             Base.Test.pop_testset()
        end
    end
    println()
    Base.Test.print_test_results(o_ts,1)
    for res in results
        if !isa(res[2][1], Exception)
            println("Tests for $(res[1]) took $(res[2][2]) seconds, of which $(res[2][4]) were spent in gc ($(100*res[2][4]/res[2][2]) % ), and allocated $(res[2][3]) bytes.")
        else
            o_ts.anynonpass = true
        end
    end

    if !o_ts.anynonpass
        println("    \033[32;1mSUCCESS\033[0m")
    else
        println("    \033[31;1mFAILURE\033[0m")
        Base.Test.print_test_errors(o_ts)
        error()
    end
end
