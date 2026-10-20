@testitem "python info" begin
    @testset "python_executable_path" begin
        @test PythonCall.python_executable_path() isa String
        @test occursin("python", PythonCall.python_executable_path())
    end
    @testset "python_library_path" begin
        @test PythonCall.python_library_path() isa String
        @test occursin("python", PythonCall.python_library_path())
    end
    @testset "python_library_handle" begin
        @test PythonCall.python_library_handle() isa Ptr{Cvoid}
        @test PythonCall.python_library_handle() != C_NULL
    end
    @testset "python_version" begin
        @test PythonCall.python_version() isa VersionNumber
        @test PythonCall.python_version().major == 3
    end
end

@testitem "Python regions and task-safe thread states" setup = [Setup] begin
    using Base.Threads

    @test !PythonCall.C.has_tstate()
    @test @pyregion pyconvert(Int, pyint(12)) == 12
    @test !PythonCall.C.has_tstate()

    # Nested regions reuse the state cached by the owning Julia thread. A break
    # must relinquish that cache while yielding, keep the task on the same Julia
    # thread, and restore both the cache and the task's original stickiness.
    test_task = current_task()
    oldsticky = test_task.sticky
    @pyregion begin
        local state = PythonCall.C.TASK_STATE()
        local thread_state = PythonCall.C.THREAD_STATE()
        local tid = threadid()
        @test test_task.sticky
        @test thread_state.task === test_task
        @test thread_state.task_state === state
        @pyregion @test PythonCall.C.current_task_state(test_task) === state
        @pyregionbreak begin
            @test test_task.sticky
            @test thread_state.task === nothing
            yield()
            @test threadid() == tid
        end
        @test thread_state.task === test_task
        @test thread_state.task_state === state
    end
    @test test_task.sticky == oldsticky
    @test PythonCall.C.THREAD_STATE().task === nothing

    @test @pyregion begin
        @pyregion pyconvert(Int, pyint(1)) == 1
        @pyregionbreak begin
            yield()
            @pyregion pyconvert(Int, pyint(2)) == 2
            @pyregionbreak yield()
        end
        pyconvert(Int, pyint(3)) == 3
    end

    # A task waiting in ordinary Julia code must release its Python state so that
    # another task on the same Julia thread can use Python. The bounded wait makes
    # a missing break fail promptly instead of leaving the test suite deadlocked.
    started = Channel{Nothing}(1)
    ready = Ref(false)
    break_status = Ref(:not_started)
    values = Ref((0, 0))
    @sync begin
        @async @pyregion begin
            put!(started, nothing)
            first = pyconvert(Int, pybuiltins.sum([1, 2, 3]))
            break_status[] = @pyregionbreak timedwait(() -> ready[], 2; pollint=0.001)
            second = pyconvert(Int, pybuiltins.sum([4, 5, 6]))
            values[] = (first, second)
        end
        @async begin
            take!(started)
            @test pyconvert(Int, pybuiltins.sum([7, 8, 9])) == 24
            ready[] = true
        end
    end
    @test break_status[] == :ok
    @test values[] == (6, 15)

    @test_throws ErrorException @pyregion @pyregionbreak error("region exception")
    @test !PythonCall.C.has_tstate()
    @test_throws PyException @pyregion pybuiltins.int("not an integer")
    @test pyconvert(Int, pyint(5)) == 5

    results = fetch.([@spawn begin
        total = 0
        for i in 1:100
            total += pyconvert(Int, pyint(i))
            @pyregionbreak yield()
        end
        total
    end for _ in 1:max(8, 2nthreads())])
    @test all(==(5050), results)

    f = pyfunc() do
        yield()
        pyconvert(Int, pybuiltins.sum([1, 2, 3]))
    end
    @test pyconvert(Int, f()) == 6

    @test pyconvert(Int, @py 1 + @jl(pyconvert(Int, pyint(2)))) == 3
end

@testitem "exe = @ENV" begin
    mktempdir() do dir
        # A throwaway environment prepended to the load path overrides the `exe`
        # preference for a child process while still resolving PythonCall from ours.
        write(
            joinpath(dir, "Project.toml"),
            "[extras]\nPythonCall = \"6099a3de-0909-46bc-b1f4-468b9a2dfc0d\"\n",
        )
        write(joinpath(dir, "LocalPreferences.toml"), "[PythonCall]\nexe = \"@ENV\"\n")
        sep = Sys.iswindows() ? ";" : ":"
        loadpath = join([dir, Base.active_project(), "@stdlib"], sep)
        exe = PythonCall.python_executable_path()
        code = "using PythonCall; print(PythonCall.python_executable_path())"
        cmd = `$(Base.julia_cmd()) --startup-file=no -e $code`

        # variable set: it is used as the executable
        withset = addenv(cmd, "JULIA_LOAD_PATH" => loadpath, "JULIA_PYTHONCALL_EXE" => exe)
        @test readchomp(withset) == exe

        # variable unset: fails at load time with a clear message
        unset = addenv(cmd, "JULIA_LOAD_PATH" => loadpath, "JULIA_PYTHONCALL_EXE" => nothing)
        err = IOBuffer()
        proc = run(pipeline(ignorestatus(unset), stdout = devnull, stderr = err))
        @test !success(proc)
        @test occursin("JULIA_PYTHONCALL_EXE is not set", String(take!(err)))
    end
end

@testitem "GC while other threads wait for the GIL" begin
    # A Julia thread blocked on the GIL outside a GC-safe region stops any GC from
    # completing, and then the process can't even be interrupted, so run these in a
    # killable subprocess.
    script = """
    using PythonCall
    function on_thread(f, tid)
        task = Task(f)
        task.sticky = true
        @ccall jl_set_task_tid(task::Any, (tid - 1)::Cint)::Cint
        schedule(task)
    end
    busy = pyeval("lambda n: sum(1 for _ in range(n))", Main)
    waiter_work() = pyconvert(Int, pybuiltins.len(pylist([1, 2])))
    waiter_work()

    # GC while another thread waits to attach a state
    holding = Threads.Atomic{Bool}(false)
    waiting = Threads.Atomic{Bool}(false)
    holder = on_thread(2) do
        @pyregion begin
            holding[] = true
            while !waiting[]
            end
            # Hold the GIL without yielding so the waiter blocks on it
            Libc.systemsleep(0.5)
            GC.gc()
        end
    end
    waiter = on_thread(3) do
        while !holding[]
            yield()
        end
        waiting[] = true
        waiter_work()
    end
    wait(holder)
    if fetch(waiter) != 2
        exit(1)
    end

    # GC while another thread is in plain Python code, which re-takes the GIL
    # after dropping it at every switch interval
    started = Threads.Atomic{Bool}(false)
    looper = on_thread(2) do
        started[] = true
        pyconvert(Int, busy(10_000_000))
    end
    collector = on_thread(3) do
        while !started[]
            yield()
        end
        Libc.systemsleep(0.1)
        @pyregion begin
            waiter_work()
            GC.gc()
        end
    end
    wait(collector)
    if fetch(looper) != 10_000_000
        exit(2)
    end

    # GC from Python-to-Julia callbacks while another thread contends for the GIL
    callback = pyfunc(i -> (GC.gc(false); length(rand(100))))
    call_all = pyeval("lambda f, n: sum(f(i) for i in range(n))", Main)
    contender = on_thread(2) do
        pyconvert(Int, busy(5_000_000))
    end
    caller = on_thread(3) do
        pyconvert(Int, call_all(callback, 200))
    end
    wait(contender)
    if fetch(caller) != 20_000
        exit(3)
    end
    """
    # Calls into Python stay GC-unsafe on Julia 1.12, see `@gcsafe_ccall`
    if v"1.12" <= VERSION < v"1.13"
        @test_skip false
    else
        cmd = `$(Base.julia_cmd()) --startup-file=no --threads=3 --project=$(Base.active_project()) -e $script`
        proc = run(pipeline(cmd; stdout, stderr); wait = false)
        status = timedwait(() -> process_exited(proc), 10)
        if status != :ok
            kill(proc, Base.SIGKILL)
        end
        @test status == :ok
        @test success(proc)
    end
end
