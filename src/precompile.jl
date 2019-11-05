function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    @assert precompile(Tuple{typeof(get_call_framecode), Vector{Any}, FrameCode, Int})
end
