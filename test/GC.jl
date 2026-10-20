@testitem "GC.gc()" begin
    let
        pyobjs = map(pylist, 1:100)
        Threads.@threads for obj in pyobjs
            finalize(obj)
        end
    end
    @test !isempty(PythonCall.C.DECREF_QUEUE.items)
    PythonCall.GC.gc()
    @test isempty(PythonCall.C.DECREF_QUEUE.items)
end

@testitem "GC.GCHook" begin
    let
        pyobjs = map(pylist, 1:100)
        Threads.@threads for obj in pyobjs
            finalize(obj)
        end
    end
    @test !isempty(PythonCall.C.DECREF_QUEUE.items)
    GC.gc()
    # A Julia finalizer must never attach a Python thread state merely to decref,
    # so the hook drains the queue from a task instead.
    @test !PythonCall.C.has_tstate()
    @test timedwait(() -> isempty(PythonCall.C.DECREF_QUEUE.items), 10) == :ok
end

@testitem "GC queue drained on attach" begin
    let
        pyobjs = map(pylist, 1:100)
        Threads.@threads for obj in pyobjs
            finalize(obj)
        end
    end
    @test !isempty(PythonCall.C.DECREF_QUEUE.items)
    @test pyconvert(Int, pyint(1)) == 1
    @test isempty(PythonCall.C.DECREF_QUEUE.items)
end
