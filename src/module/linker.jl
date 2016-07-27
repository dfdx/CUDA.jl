# Linking of different PTX modules

import Base: unsafe_convert, show, cconvert

export
    CuLink, complete, destroy,
    addData, addFile


typealias CuLinkState_t Ptr{Void}

immutable CuLink
    handle::CuLinkState_t

    options::Dict{CUjit_option,Any}
    optionKeys::Vector{CUjit_option}
    optionVals::Vector{Ptr{Void}}

    function CuLink()
        handle_ref = Ref{CuLinkState_t}()

        options = Dict{CUjit_option,Any}()
        options[ERROR_LOG_BUFFER] = Array(UInt8, 1024*1024)
        @static if DEBUG
            options[GENERATE_LINE_INFO] = true
            options[GENERATE_DEBUG_INFO] = true

            options[INFO_LOG_BUFFER] = Array(UInt8, 1024*1024)
            options[LOG_VERBOSE] = true
        end
        optionKeys, optionVals = encode(options)

        @apicall(:cuLinkCreate,
                (Cuint, Ptr{CUjit_option}, Ptr{Ptr{Void}}, Ptr{CuModule_t}),
                length(optionKeys), optionKeys, optionVals, handle_ref)

        new(handle_ref[], options, optionKeys, optionVals)
    end
end

unsafe_convert(::Type{CuLinkState_t}, link::CuLink) = link.handle
show(io::IO,link::CuLink) = print(io, typeof(link), "(", link.handle, ")")

"Complete a pending linker invocation."
function complete(link::CuLink)
    cubin_ref = Ref{Ptr{Void}}()
    size_ref = Ref{Csize_t}()

    try
        @apicall(:cuLinkComplete,
                (Ptr{CuLinkState_t}, Ptr{Ptr{Void}}, Ptr{Csize_t}),
                link.handle, cubin_ref, size_ref)
    catch err
        (err == ERROR_NO_BINARY_FOR_GPU || err == ERROR_INVALID_IMAGE) || rethrow(err)
        options = decode(link.optionKeys, link.optionVals)
        rethrow(CuError(err.code, options[ERROR_LOG_BUFFER]))
    end

    @static if DEBUG
        options = decode(link.optionKeys, link.optionVals)
        if isempty(options[INFO_LOG_BUFFER])
            debug("JIT info log is empty")
        else
            debug("JIT info log: ", repr_indented(options[INFO_LOG_BUFFER]))
        end
    end

    return unsafe_wrap(Array, convert(Ptr{UInt8}, cubin_ref[]), size_ref[])
end

function destroy(link::CuLink)
    @apicall(:cuLinkDestroy, (Ptr{CuLinkState_t},), link.handle)
end

function addData(link::CuLink, name::String, data::Union{Vector{UInt8},String}, typ::CUjit_input)
    # NOTE: ccall can't directly convert String to Ptr{Void}, so step through a typed Ptr
    if typ == PTX
        # additionally, in the case of PTX there shouldn't be any embedded NULLs
        typed_ptr = pointer(unsafe_convert(Cstring, cconvert(Cstring, String(data))))
    else
        typed_ptr = pointer(unsafe_convert(Vector{UInt8}, cconvert(Vector{UInt8}, data)))
    end
    untyped_ptr = convert(Ptr{Void}, typed_ptr)

    @apicall(:cuLinkAddData,
             (Ptr{CuLinkState_t}, CUjit_input, Ptr{Void}, Csize_t, Cstring, Cuint, Ptr{CUjit_option}, Ptr{Ptr{Void}}),
             link.handle, typ, untyped_ptr, length(data), name, 0, C_NULL, C_NULL)

    return nothing
end

function addFile(link::CuLink, path::String, typ::CUjit_input)
    @apicall(:cuLinkAddFile,
             (Ptr{CuLinkState_t}, CUjit_input, Cstring, Cuint, Ptr{CUjit_option}, Ptr{Ptr{Void}}),
             link.handle, typ, path, 0, C_NULL, C_NULL)

    return nothing
end
