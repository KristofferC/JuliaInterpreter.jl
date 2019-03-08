"""
`Compiled` is a trait indicating that any `:call` expressions should be evaluated
using Julia's normal compiled-code evaluation. The alternative is to pass `stack=JuliaStackFrame[]`,
which will cause all calls to be evaluated via the interpreter.
"""
struct Compiled end
Base.similar(::Compiled, sz) = Compiled()  # to support similar(stack, 0)

# A type used transiently in renumbering CodeInfo SSAValues (to distinguish a new SSAValue from an old one)
struct NewSSAValue
    id::Int
end

"""
    JuliaProgramCounter(next_stmt::Int)

A wrapper specifying the index of the next statement in the lowered code to be executed.
"""
struct JuliaProgramCounter
    next_stmt::Int
end
+(x::JuliaProgramCounter, y::Integer) = JuliaProgramCounter(x.next_stmt+y)
-(x::JuliaProgramCounter, y::Integer) = JuliaProgramCounter(x.next_stmt-y)
convert(::Type{Int}, pc::JuliaProgramCounter) = pc.next_stmt
isless(x::JuliaProgramCounter, y::Integer) = isless(x.next_stmt, y)

Base.show(io::IO, pc::JuliaProgramCounter) = print(io, "JuliaProgramCounter(", pc.next_stmt, ')')

# Breakpoint support
truecondition(frame) = true
falsecondition(frame) = false
const break_on_error = Ref(false)

"""
    BreakpointState(isactive=true, condition=JuliaInterpreter.truecondition)

`BreakpointState` represents a breakpoint at a particular statement in
a `JuliaFrameCode`. `isactive` indicates whether the breakpoint is currently
[`enable`](@ref)d or [`disable`](@ref)d. `condition` is a function that accepts
a single `JuliaStackFrame`, and `condition(frame)` must return either
`true` or `false`. Execution will stop at a breakpoint only if `isactive`
and `condition(frame)` both evaluate as `true`. The default `condition` always
returns `true`.

To create these objects, see [`breakpoint`](@ref).
"""
struct BreakpointState
    isactive::Bool
    condition::Function
end
BreakpointState(isactive::Bool) = BreakpointState(isactive, truecondition)
BreakpointState() = BreakpointState(true)

"""
`JuliaFrameCode` holds static information about a method or toplevel code.
One `JuliaFrameCode` can be shared by many `JuliaStackFrame` calling frames.

Important fields:
- `scope`: the `Method` or `Module` in which this frame is to be evaluated
- `code`: the `CodeInfo` object storing (optimized) lowered code
- `methodtables`: a vector, each entry potentially stores a "local method table" for the corresponding
  `:call` expression in `code` (undefined entries correspond to statements that do not
  contain `:call` expressions)
- `used`: a `BitSet` storing the list of SSAValues that get referenced by later statements.
"""
struct JuliaFrameCode
    scope::Union{Method,Module}
    code::CodeInfo
    methodtables::Vector{Union{Compiled,TypeMapEntry}} # line-by-line method tables for generic-function :call Exprs
    breakpoints::Vector{BreakpointState}
    used::BitSet
    wrapper::Bool
    generator::Bool
    # Display options
    fullpath::Bool
end

function JuliaFrameCode(frame::JuliaFrameCode; wrapper = frame.wrapper, generator=frame.generator, fullpath=frame.fullpath)
    JuliaFrameCode(frame.scope, frame.code, frame.methodtables, frame.breakpoints, frame.used,
                   wrapper, generator, fullpath)
end

function JuliaFrameCode(scope, code::CodeInfo; wrapper=false, generator=false, fullpath=true, optimize=true)
    if optimize
        code, methodtables = optimize!(copy_codeinfo(code), moduleof(scope))
    else
        code = copy_codeinfo(code)
        methodtables = Vector{Union{Compiled,TypeMapEntry}}(undef, length(code.code))
    end
    breakpoints = Vector{BreakpointState}(undef, length(code.code))
    used = find_used(code)
    return JuliaFrameCode(scope, code, methodtables, breakpoints, used, wrapper, generator, fullpath)
end

"""
`JuliaStackFrame` represents the current execution state in a particular call frame.

Important fields:
- `code`: the [`JuliaFrameCode`](@ref) for this frame
- `locals`: a vector containing the input arguments and named local variables for this frame.
  The indexing corresponds to the names in `frame.code.code.slotnames`.
- `ssavalues`: a vector containing the
  [Static Single Assignment](https://en.wikipedia.org/wiki/Static_single_assignment_form)
  values produced at the current state of execution
- `sparams`: the static type parameters, e.g., for `f(x::Vector{T}) where T` this would store
  the value of `T` given the particular input `x`.
- `pc`: the [`JuliaProgramCounter`](@ref) that typically represents the current position
  during execution. However, note that some internal functions instead maintain the `pc`
  as a local variable, and only update the frame's `pc` when pushing a frame on the stack.
"""
struct JuliaStackFrame
    code::JuliaFrameCode
    locals::Vector{Union{Nothing,Some{Any}}}
    ssavalues::Vector{Any}
    sparams::Vector{Any}
    exception_frames::Vector{Int}
    last_exception::Base.RefValue{Any}
    pc::Base.RefValue{JuliaProgramCounter}
    # A vector from names to the slotnumber of that name
    # for which a reference was last encountered.
    last_reference::Dict{Symbol,Int}
    callargs::Vector{Any}  # a temporary for processing arguments of :call exprs
end

function JuliaStackFrame(framecode::JuliaFrameCode, frame::JuliaStackFrame, pc::JuliaProgramCounter; kwargs...)
    pcref = frame.pc
    pcref[] = pc
    if !isempty(kwargs)
        framecode = JuliaFrameCode(framecode; kwargs...)
    end
    JuliaStackFrame(framecode, frame.locals,
                    frame.ssavalues, frame.sparams,
                    frame.exception_frames, frame.last_exception,
                    pcref, frame.last_reference, frame.callargs)
end

JuliaStackFrame(frame::JuliaStackFrame, pc::JuliaProgramCounter; kwargs...) =
    JuliaStackFrame(frame.code, frame, pc; kwargs...)

"""
`Variable` is a struct representing a variable with an asigned value.
By calling the function `locals`[@ref] on a `JuliaStackFrame`[@ref] a
`Vector` of `Variable`'s is returned.

Important fields:
- `value::Any`: the value of the local variable
- `name::Symbol`: the name of the variable as given in the source code
- `isparam::Bool`: if the variable is a type parameter, for example `T` in `f(x::T) where {T} = x` .
"""
struct Variable
    value::Any
    name::Symbol
    isparam::Bool
end
Base.show(io::IO, var::Variable) = (print(io, var.name, " = "); show(io,var.value))
Base.isequal(var1::Variable, var2::Variable) =
    var1.value == var2.value && var1.name == var2.name && var1.isparam == var2.isparam

# A type that is unique to this package for which there are no valid operations
struct Unassigned end

"""
    BreakpointRef(framecode, stmtidx)
    BreakpointRef(framecode, stmtidx, err)

A reference to a breakpoint at a particular statement index `stmtidx` in `framecode`.
If the break was due to an error, supply that as well.
"""
struct BreakpointRef
    framecode::JuliaFrameCode
    stmtidx::Int
    err
end
BreakpointRef(framecode, stmtidx) = BreakpointRef(framecode, stmtidx, nothing)

function Base.show(io::IO, bp::BreakpointRef)
    if checkbounds(Bool, bp.framecode.breakpoints, bp.stmtidx)
        lineno = linenumber(bp.framecode, bp.stmtidx)
        print(io, "breakpoint(", bp.framecode.scope, ", ", lineno)
    else
        print(io, "breakpoint(", bp.framecode.scope, ", %", bp.stmtidx)
    end
    if bp.err !== nothing
        print(io, ", ", bp.err)
    end
    print(io, ')')
end