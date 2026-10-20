"""
    module PythonCall.GC

Garbage collection of Python objects.

See [`gc`](@ref).
"""
module GC

using ..C: C
import ..PythonCall: @pyregion

if Base.VERSION ≥ v"1.11"
    eval(
        Expr(
            :public,
            :disable,
            :enable,
            :gc,
        ),
    )
end

const HOOK = Ref{WeakRef}()
const DRAIN_SCHEDULED = Threads.Atomic{Bool}(false)

"""
    PythonCall.GC.disable()

Do nothing.

!!! note

    Historically this would disable the PythonCall garbage collector. This was required
    for safety in multi-threaded code but is no longer needed, so this is now a no-op.
"""
function disable()
    Base.depwarn(
        "disabling the PythonCall GC is no longer needed for thread-safety",
        :disable,
    )
    nothing
end

"""
    PythonCall.GC.enable()

Do nothing.

!!! note

    Historically this would enable the PythonCall garbage collector. This was required
    for safety in multi-threaded code but is no longer needed, so this is now a no-op.
"""
function enable()
    Base.depwarn(
        "disabling the PythonCall GC is no longer needed for thread-safety",
        :enable,
    )
    nothing
end

"""
    PythonCall.GC.gc()

Free any Python objects waiting to be freed.

These are objects finalized while no Python thread state was attached. This explicit
operation safely establishes the state it needs and can be called from any Julia thread.
"""
function gc()
    if C.CTX.is_initialized
        @pyregion C.free_decref_queue()
    end
    nothing
end

function enqueue(ptr::C.PyPtr)
    # If the ptr is NULL there is nothing to free.
    # If C.CTX.is_initialized is false then the Python interpreter hasn't started yet
    # or has been finalized; either way attempting to free will cause an error.
    if ptr != C.PyNULL && C.CTX.is_initialized
        if C.has_tstate()
            # An attached state lets us immediately free without blocking a finalizer.
            C.Py_DecRef(ptr)
            # We may as well also free any other enqueued objects.
            C.drain_decref_queue()
        else
            # Otherwise we push the pointer onto the queue to be freed later, either:
            # (a) If a future Python object is finalized with a state already attached
            #     in the branch above.
            # (b) When a region or region break next attaches a state.
            # (c) From a task the GCHook() object below schedules in an ordinary GC.
            # (d) If the user calls PythonCall.GC.gc().
            Base.@lock C.DECREF_QUEUE.lock push!(C.DECREF_QUEUE.items, ptr)
        end
    end
    nothing
end

function enqueue_all(ptrs)
    if any(!=(C.PyNULL), ptrs) && C.CTX.is_initialized
        if C.has_tstate()
            for ptr in ptrs
                if ptr != C.PyNULL
                    C.Py_DecRef(ptr)
                end
            end
            C.drain_decref_queue()
        else
            Base.@lock C.DECREF_QUEUE.lock append!(C.DECREF_QUEUE.items, ptrs)
        end
    end
    nothing
end

"""
    GCHook()

An immortal object which frees any pending Python objects when Julia's GC runs.

This works by creating it but not holding any strong reference to it, so it is eligible
to be finalized by Julia's GC. The finalizer empties the PythonCall GC queue, directly if
a state is attached and otherwise from a task, since a finalizer must not block attaching
one. The finalizer also re-attaches itself, so the object does not actually get
collected and so the finalizer will run again at next GC.
"""
mutable struct GCHook
    function GCHook()
        finalizer(_gchook_finalizer, new())
    end
end

function _gchook_finalizer(x)
    if C.CTX.is_initialized
        finalizer(_gchook_finalizer, x)
        if !isempty(C.DECREF_QUEUE.items)
            if C.has_tstate()
                C.free_decref_queue()
            elseif !Threads.atomic_xchg!(DRAIN_SCHEDULED, true)
                # Cleared afterwards so drains blocked on the GIL can't pile up;
                # anything queued meanwhile is freed on the next attach.
                errormonitor(Threads.@spawn try
                    gc()
                finally
                    DRAIN_SCHEDULED[] = false
                end)
            end
        end
    end
    nothing
end

function __init__()
    HOOK[] = WeakRef(GCHook())
    nothing
end

end # module GC
