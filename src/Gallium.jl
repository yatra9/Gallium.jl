__precompile__()
module Gallium
    using ASTInterpreter
    using Base.Meta
    using DWARF
    using ObjFileBase
    using ELF
    using MachO
    using COFF
    using AbstractTrees
    import ASTInterpreter: @enter

    # Debugger User Interface
    export breakpoint, @enter, @breakpoint, @conditional

    type JuliaStackFrame
        oh
        file
        ip
        sstart
        line::Int
        linfo::LambdaInfo
        variables::Dict
        env::Environment
    end

    type CStackFrame
        ip::Ptr{Void}
        file::AbstractString
        line::Int
        declfile::AbstractString
        declline::Int
        stacktop::Bool
    end

    include("remote.jl")
    include("registers.jl")
    include("x86_64/registers.jl")
    include("x86_32/registers.jl")
    include("powerpc64le/registers.jl")
    include("win64seh.jl")
    include("modules.jl")
    include("unwind.jl")
    include("Hooking/Hooking.jl")
    include("ptrace.jl")

    using .Registers
    using .Registers: ip, get_dwarf
    using .Hooking
    using .Hooking: host_arch

    # Fake "Interpreter" that is just a native stack
    immutable NativeStack
        stack
        RCs
        modules
        session
    end
    NativeStack(stack::Vector) = NativeStack(stack,Any[],active_modules,LocalSession())

    function ASTInterpreter.language_specific_prompt(state, stack::JuliaStackFrame)
        state.julia_prompt
    end
    function ASTInterpreter.language_specific_prompt(state, stack::NativeStack)
        ASTInterpreter.language_specific_prompt(state, stack.stack[end])
    end

    ASTInterpreter.done!(stack::NativeStack) = nothing

    function ASTInterpreter.print_frame(_, io, num, x::JuliaStackFrame)
        print(io, "[$num] ")
        linfo = x.linfo
        ASTInterpreter.print_linfo_desc(io, linfo)
        println(io)
        ASTInterpreter.print_locals(io, linfo, x.env, (io,name)->begin
            if haskey(x.variables, name)
                if x.variables[name] == :available
                    println(io, "<undefined>")
                else
                    println(io, "<not available here>")
                end
            else
                println(io, "<optimized out>")
            end
        end)
    end
    ASTInterpreter.print_frame(_, io, num, x::NativeStack) =
        ASTInterpreter.print_frame(_, io, num, x.stack[end])

    function ASTInterpreter.print_status(state, x::JuliaStackFrame; kwargs...)
        if x.line < 0
            println("Got a negative line number. Bug?")
        elseif (!isa(x.file,AbstractString) || isempty(x.file)) || x.line == 0
            println("<No file found. Did DWARF parsing fail?>")
        else
            dfile = Base.find_source_file(string(x.file))
            ASTInterpreter.print_sourcecode(x.linfo,
                ASTInterpreter.readfileorhist(
                    dfile == nothing ? x.file : dfile), x.line)
        end
    end

    function ASTInterpreter.print_status(state, x::NativeStack; kwargs...)
        ASTInterpreter.print_status(state, x.stack[end]; kwargs...)
    end

    function ASTInterpreter.get_env_for_eval(x::JuliaStackFrame)
        copy(x.env)
    end
    ASTInterpreter.get_env_for_eval(x::NativeStack) =
        ASTInterpreter.get_env_for_eval(x.stack[end])
    ASTInterpreter.get_linfo(x::JuliaStackFrame) = x.linfo
    ASTInterpreter.get_linfo(x::NativeStack) =
        ASTInterpreter.get_linfo(x.stack[end])

    const GalliumFrame = Union{NativeStack, JuliaStackFrame, CStackFrame}
    using DWARF: CallFrameInfo
    function ASTInterpreter.execute_command(state, x::GalliumFrame, ::Val{:cfi}, command)
        verbose = false
        cmds = split(command, ' '; keep=false)
        if length(cmds) > 1 && cmds[2] == "verbose"
            verbose = true
        end
        modules = state.top_interp.modules
        mod, base, ip = modbaseip_for_stack(state, x)
        modrel = UInt(ip - base)
        loc, fde = Unwinder.find_fde(mod, modrel)
        cie = realize_cie(fde)
        if verbose
            println(STDOUT, "Module Base: 0x", hex(base))
            println(STDOUT, "IP: 0x", hex(UInt64(ip)))
            println(STDOUT, "FDE loc: 0x", hex(loc))
            println(STDOUT, "Modrel: 0x", hex(modrel))
        end
        target_delta = modrel - loc
        out = IOContext(STDOUT, :reg_map =>
            isa(Gallium.getarch(state.top_interp.session),Gallium.X86_64.X86_64Arch) ?
            Gallium.X86_64.dwarf_numbering : Gallium.X86_32.dwarf_numbering)
        drs = CallFrameInfo.RegStates()
        CallFrameInfo.dump_program(out, cie, ptrT = ObjFileBase.intptr(ObjFileBase.handle(mod)),
            target = UInt(target_delta), rs = drs); println(out)
        CallFrameInfo.dump_program(out, fde,
            cie = cie, target = UInt(target_delta), rs = drs)
        return false
    end

    function obtain_linetable(state, stack)
        mod, base, ip = modbaseip_for_stack(state, stack)
        dbgs = debugsections(dhandle(mod))
        lip = compute_ip(dhandle(mod), base, ip)
        cu = DWARF.searchcuforip(dbgs, lip)
        line_offset = get(DWARF.extract_attribute(cu, DWARF.DW_AT_stmt_list))
        seek(dbgs.debug_line, UInt(line_offset.value))
        DWARF.LineTableSupport.LineTable(handle(dbgs).io), lip
    end

    function ASTInterpreter.execute_command(state, stack::GalliumFrame, ::Val{:lip}, command)
        mod, base, ip = modbaseip_for_stack(state, stack)
        dbgs = debugsections(dhandle(mod))
        lip = compute_ip(dhandle(mod), base, ip)
        show(STDOUT, lip); println(STDOUT)
        return false
    end


    function ASTInterpreter.execute_command(state, stack::GalliumFrame, ::Union{Val{:linetabprog}, Val{:linetab}}, command)
        linetab = obtain_linetable(state, stack)[1]
        (command == Val{:linetabprog} ? DWARF.LineTableSupport.dump_program :
            DWARF.LineTableSupport.dump_table)(STDOUT, linetab)
        return false
    end

    function find_module(session, modules, frame::CStackFrame)
        ip = frame.ip - (frame.stacktop ? 0 : 1)
        base, mod = find_module(session, modules, ip)
    end

    function modbaseip_for_stack(state, stack)
        modules = state.top_interp.modules
        frame = isa(stack, NativeStack) ? stack.stack[end] : stack
        session = isa(state.top_interp, NativeStack) ? state.top_interp.session : LocalSession()
        ip = frame.ip - (frame.stacktop ? 0 : 1)
        base, mod = find_module(session, modules, ip)
        mod, base, ip
    end

    function ASTInterpreter.execute_command(state, stack::GalliumFrame, ::Val{:handle}, command)
        Base.LineEdit.transition(state.s, :abort)
        mod, _, __ = modbaseip_for_stack(state, stack)
        eval(Main,:(h = $(handle(mod))))
        return false
    end

    function compute_ip(handle, base, theip)
        if ObjFileBase.isrelocatable(handle)
            UInt(theip)
        elseif isa(handle, ELF.ELFHandle)
            phs = ELF.ProgramHeaders(handle)
            idx = findfirst(p->p.p_offset==0&&p.p_type==ELF.PT_LOAD, phs)
            UInt(theip + (phs[idx].p_vaddr-base))
        elseif isa(handle, COFF.COFFHandle)
            # Map from loaded address to file address
            UInt(theip) + (UInt(COFF.readoptheader(handle).windows.ImageBase) - UInt(base))
        else
            error("Don't know how to compute ip")
        end
    end

    function compute_symbol_value(handle, base, symbol)
        if isa(handle, COFF.COFFHandle)
            value = COFF.symbolvalue(symbol, COFF.Sections(ObjFileBase.handle(handle)))
            # Map from file address to loaded address
            return UInt(value) + (Int(base) - Int(COFF.readoptheader(h).windows.ImageBase))
        else
            value = ObjFileBase.symbolvalue(symbol, ObjFileBase.Sections(ObjFileBase.handle(handle)))
            return base + value
        end
    end

    function ASTInterpreter.execute_command(state, stack::GalliumFrame,
            cmd::Union{Val{:cu},Val{:sp}}, command)
        mod, base, ip = modbaseip_for_stack(state, stack)
        dbgs = debugsections(dhandle(mod))
        lip = compute_ip(dhandle(mod), base, ip)
        unit = DWARF.searchcuforip(dbgs, UInt(lip))
        (cmd == Val{:sp}()) && (unit = DWARF.searchspforip(unit, UInt(lip)))
        AbstractTrees.print_tree(show, IOContext(STDOUT,:strtab=>StrTab(dbgs.debug_str)), unit)
        return false
    end

    function ASTInterpreter.execute_command(state, stack::GalliumFrame,
            cmd::Val{:seh}, command)
        mod, base, ip = modbaseip_for_stack(state, stack)
        entry = Unwinder.find_seh_entry(mod, ip-base)
        i = 1
        while i <= length(entry.opcodes)
            i += print_op(STDOUT, entry.opcodes, i)
        end
        return false
    end

    # Use this hook to expose extra functionality
    function ASTInterpreter.execute_command(x::JuliaStackFrame, command)
        lip = UInt(x.ip)-x.sstart-1
        if isrelocatable(handle(x.oh))
            lip = UInt(x.ip)-1
        end
        if command == "ip"
            println(x.ip)
            return
        elseif command == "sstart"
            println(x.sstart)
            return
        elseif startswith(command, "bp")
            subcmds = split(command,' ')[2:end]
            if subcmds[1] == "list"
                list_breakpoints()
            elseif subcmds[1] == "disable"
                bp = breakpoints[parse(Int,subcmds[2])]
                disable(bp)
                println(bp)
            elseif subcmds[1] == "enable"
                bp = breakpoints[parse(Int,subcmds[2])]
                enable(bp)
                println(bp)
            end
        elseif startswith(command, "b")
            nothing
        end
    end

    function ASTInterpreter.execute_command(x::NativeStack, command)
        ASTInterpreter.execute_command(x.stack[end], command)
    end


    export breakpoint, breakpoint_on_error

    # Move this somewhere better
    function ObjFileBase.getSectionLoadAddress(LOI::Dict, sec)
        return LOI[Symbol(sectionname(sec))]
    end

    function search_linetab(linetab, ip)
        local last_entry
        first = true
        for entry in linetab
            if !first
                if entry.address > reinterpret(UInt64,ip)
                    return last_entry
                end
            end
            first = false
            last_entry = entry
        end
        last_entry
    end

    function rec_backtrace(RC)
        ips = Array(UInt64, 0)
        rec_backtrace(RC->(push!(ips,ip(RC)); true), RC)
        ips
    end

    function rec_backtrace_hook(RC)
        ips = Array(UInt64, 0)
        rec_backtrace_hook(RC->(push!(ips,ip(RC)); true), RC)
        ips
    end

    global active_modules = LazyJITModules()
    global allow_bad_unwind = true
    function rec_backtrace(callback, RC, session = LocalSession(), modules = active_modules, ip_only = false, cfi_cache = nothing; stacktop = true)
        callback(RC) || return
        while true
            (ok, RC) = try
                Unwinder.unwind_step(session, modules, RC, cfi_cache;
                    stacktop = stacktop, ip_only = ip_only, allow_frame_based=allow_bad_unwind)
            catch e # e.g. invalid memory access, invalid unwind info etc.
                if !allow_bad_unwind::Bool
                    println("Was at ip: ", ip(RC))
                    rethrow(e)
                end
                break
            end
            stacktop = false
            ok || break
            callback(RC) || break
        end
    end

    function step_first!(::X86_64.X86_64Arch, RC)
        set_ip!(RC,unsafe_load(convert(Ptr{UInt},get_dwarf(RC,:rsp)[])))
        set_sp!(RC,get_dwarf(RC,:rsp)[]+sizeof(Ptr{Void}))
    end

    function step_first!(::PowerPC64.PowerPC64Arch, RC)
    end

    function rec_backtrace_hook(callback, RC, session = LocalSession(), modules = active_modules, ip_only = false, arch = host_arch())
        callback(RC) || return
        step_first!(arch, RC)
        rec_backtrace(callback, RC, session, modules, ip_only; stacktop = false)
    end

    # Validate that an address is a valid location in the julia heap
    function heap_validate(ptr)
        typeptr = Ptr{Ptr{Void}}(UInt64(ptr)-sizeof(Ptr{Void}))
        Hooking.mem_validate(typeptr,sizeof(Ptr)) || return false
        T = UInt(unsafe_load(typeptr))&(~UInt(0x3))
        typetypeptr = Ptr{Ptr{Void}}(T-sizeof(Ptr))
        Hooking.mem_validate(typetypeptr,sizeof(Ptr)) || return false
        UInt(unsafe_load(typetypeptr))&(~UInt(0x3)) == UInt(pointer_from_objref(DataType))
    end

    function get_ipinfo(session::LocalSession, theip)
        Base.StackTraces.lookup(theip)
    end

    function get_ipinfo(session, theip)
        sf = StackFrame(:unknown, "", 0, Nullable{LambdaInfo}(),
            true, false, theip)
        [sf]
    end

    function getreg(RC, fbreg, reg)
        if reg == DWARF.DW_OP_fbreg
            (fbreg == -1) && error("fbreg requested but not found")
            Gallium.get_dwarf(RC, fbreg)
        else
            Gallium.get_dwarf(RC, reg)
        end
    end

    function iterate_variables(RC, found_cb, not_found_cb, dbgs, lip)
        cu = DWARF.searchcuforip(dbgs, lip)
        sp = DWARF.searchspforip(cu, lip)

        culow = DWARF.extract_attribute(cu,DWARF.DW_AT_low_pc)

        fbreg = DWARF.extract_attribute(sp, DWARF.DW_AT_frame_base)
        # Array is for DWARF 2 support.
        fbreg = isnull(fbreg) ? -1 :
            (isa(get(fbreg).value, Array) ? get(fbreg).value[1] : get(fbreg).value.expr[1]) - DWARF.DW_OP_reg0

        local getreg
        getreg = (reg)->Gallium.getreg(RC, fbreg, reg)
        getword(addr) = unsafe_load(reinterpret(Ptr{UInt64}, addr))
        addr_func(x) = x

        for vardie in (filter(children(sp)) do child
                    tag = DWARF.tag(child)
                    tag == DWARF.DW_TAG_formal_parameter ||
                    tag == DWARF.DW_TAG_variable
                end)
            name = DWARF.extract_attribute(vardie,DWARF.DW_AT_name)
            loc = DWARF.extract_attribute(vardie,DWARF.DW_AT_location)
            (isnull(name) || isnull(loc)) && continue
            name = Symbol(bytestring(get(name).value,StrTab(dbgs.debug_str)))
            loc = get(loc)
            if loc.spec.form == DWARF.DW_FORM_exprloc
                sm = DWARF.Expressions.StateMachine{typeof(loc.value).parameters[1]}()
                val = DWARF.Expressions.evaluate_simple_location(
                    sm, loc.value.expr, getreg, getword, addr_func, :NativeEndian)
                found_cb(dbgs, vardie, getreg, name, val)
            elseif loc.spec.form == DWARF.DW_FORM_sec_offset
                T = UInt64
                seek(dbgs.debug_loc, loc.value.offset)
                list = read(dbgs.debug_loc, DWARF.LocationList{T})
                sm = DWARF.Expressions.StateMachine{T}()
                found = false
                for entry in list.entries
                    if entry.first <= lip - UInt(culow.value) <= entry.last
                        val = DWARF.Expressions.evaluate_simple_location(
                            sm, entry.data, getreg, getword, addr_func, :NativeEndian)
                        found = true
                        found_cb(dbgs, vardie, getreg, name, val)
                        break
                    end
                end
                found || not_found_cb(dbgs, vardie, name)
            else
                not_found_cb(dbgs, vardie, name)
            end
        end
    end

    function make_base_stackframe(session, modules, theip; firstframe = false)
        sstart, h = try
            find_module(session, modules, theip)
        catch # Unwind got it wrong, but still include at least one stack frame
            return Base.StackFrame(Symbol("???"),Symbol("???"),0,
                Nullable{LambdaInfo}(),true,false,theip)
        end
        dh = dhandle(h)
        lip = compute_ip(dh, sstart, theip-(firstframe?0:1))
        dbgs = debugsections(dh)
        file, line, linetab = linetable_entry(dbgs, lip)
        name = symbolicate(session, modules, theip-(firstframe?0:1))
        Base.StackFrame(Symbol(name),Symbol(file),line,Nullable{LambdaInfo}(),
            true, false, theip)
    end

    function linetable_entry(dbgs, lip)
        cu = DWARF.searchcuforip(dbgs, lip)
        sp = DWARF.searchspforip(cu, lip)
        # Process Compilation Unit to get line table
        line_offset = DWARF.extract_attribute(cu, DWARF.DW_AT_stmt_list)
        line_offset = isnull(line_offset) ? 0 : convert(UInt, get(line_offset).value)

        seek(dbgs.debug_line, line_offset)
        linetab = DWARF.LineTableSupport.LineTable(handle(dbgs).io)
        entry = search_linetab(linetab, lip)
        line = entry.line
        fileentry = linetab.header.file_names[entry.file]
        if fileentry.dir_idx == 0
            found_file = Base.find_source_file(fileentry.name)
            file = found_file != nothing ? found_file : fileentry.name
        else
            file = joinpath(linetab.header.include_directories[fileentry.dir_idx],
                fileentry.name)
        end
        file, line, linetab
    end

    function frameinfo(RC, session, modules; rich_c = false, firstframe = false)
        theip = reinterpret(Ptr{Void},UInt(ip(RC)))
        ipinfo = get_ipinfo(session, theip)[end]
        fromC = ipinfo.from_c
        file = ""
        line = 0
        local declfile="", declline=0
        if fromC
            sstart, h = try
                find_module(session, modules, theip)
            catch err # Unwind got it wrong, but still include at least one stack frame
                allow_bad_unwind::Bool || rethrow(err)
                return false, Nullable(CStackFrame(theip, file, line, declfile, declline, firstframe))
            end
            if isa(h, SyntheticModule)
                return (true, Nullable(CStackFrame(theip, file, line, declfile, declline, firstframe)))
            end
            if rich_c
                dh = dhandle(h)
                lip = compute_ip(dh, sstart, theip-(firstframe?0:1))
                local dbgs=nothing, cu=nothing, sp=nothing

                try
                    dbgs = debugsections(dh)
                    cu = DWARF.searchcuforip(dbgs, lip)
                    sp = DWARF.searchspforip(cu, lip)
                catch
                end
                if sp !== nothing
                    file, line, linetab = linetable_entry(dbgs, lip)

                    declfile = DWARF.extract_attribute(sp, DWARF.DW_AT_decl_file)
                    declfile = isnull(declfile) ? "" : linetab.header.file_names[convert(UInt,get(declfile))].name
                    declline = DWARF.extract_attribute(sp, DWARF.DW_AT_decl_line)
                    declline = isnull(declline) ? 0 : convert(UInt, get(declline))
                end
            end
            return (true, Nullable(CStackFrame(theip, file, line, declfile, declline, firstframe)))
        else
            sstart, h = find_module(session, modules, theip)
            isnull(ipinfo.linfo) && return (false, Nullable{JuliaStackFrame}())
            tlinfo = get(ipinfo.linfo)
            env = ASTInterpreter.prepare_locals(tlinfo)
            copy!(env.sparams, tlinfo.sparam_vals)
            slottypes = tlinfo.slottypes
            tlinfo = tlinfo.def.lambda_template
            variables = Dict()
            dbgs = debugsections(dhandle(h))
            try
                lip = UInt(theip)-sstart-1
                if isrelocatable(handle(h))
                    lip = UInt(theip)-1
                end

                file, line, _ = linetable_entry(dbgs, lip)

                # Process Subprogram to extract local variables
                strtab = ObjFileBase.load_strtab(dbgs.debug_str)
                vartypes = Dict{Symbol,Type}()
                if slottypes === nothing
                    for name in tlinfo.slotnames
                        vartypes[name] = Any
                    end
                else
                    for (name, ty) in zip(tlinfo.slotnames, slottypes)
                        vartypes[name] = ty
                    end
                end
                variables = Dict()
                function found_cb(dbgs, vardie, getreg, name, val)
                    haskey(vartypes, name) || return
                    variables[name] = :found
                    if isa(val, DWARF.Expressions.MemoryLocation)
                        if isbits(vartypes[name])
                            ptr = reinterpret(Ptr{Void}, val.i)
                            if ptr != C_NULL && heap_validate(ptr)
                                val = unsafe_load(reinterpret(Ptr{vartypes[name]},
                                    ptr))
                            else
                                val = Nullable{vartypes[name]}()
                            end
                        else
                            ptr = reinterpret(Ptr{Void}, val.i)
                            if ptr == C_NULL
                                val = Nullable{Ptr{vartypes[name]}}()
                            elseif heap_validate(ptr)
                                val = unsafe_pointer_to_objref(ptr)
                            # This is a heuristic. Should update to check
                            # whether the variable is declared as jl_value_t
                            elseif Hooking.mem_validate(ptr, sizeof(Ptr{Void}))
                                ptr2 = unsafe_load(Ptr{Ptr{Void}}(ptr))
                                if ptr2 == C_NULL
                                    val = Nullable{Ptr{vartypes[name]}}()
                                elseif heap_validate(ptr2)
                                    val = unsafe_pointer_to_objref(ptr2)
                                end
                            end
                        end
                        variables[name] = :available
                    elseif isa(val, DWARF.Expressions.RegisterLocation)
                        # The value will generally be in the low bits of the
                        # register. This should give the appropriate value
                        val = getreg(val.i)[]
                        if !isbits(vartypes[name])
                            if val == 0
                                val = Nullable{vartypes[name]}()
                            elseif heap_validate(val)
                                val = unsafe_pointer_to_objref(Ptr{Void}(val))
                            else
                                return
                            end
                        else
                            val = reinterpret(vartypes[name],[val])[]
                        end
                        variables[name] = :available
                    end
                    varidx = findfirst(tlinfo.slotnames, name)
                    if varidx != 0
                        env.locals[varidx] = Nullable{Any}(val)
                    end
                end
                iterate_variables(RC,found_cb,(dbgs, vardie, name)->variables[name] = :found,dbgs,lip)
            catch err
                if !isa(err, ErrorException) || err.msg != "Not found"
                    @show err
                    Base.show_backtrace(STDOUT, catch_backtrace())
                end
            end
            # process SP.variables here
            #h = readmeta(IOBuffer(data))
            return (true, Nullable(JuliaStackFrame(h, file, UInt(ip(RC)), sstart, line, get(ipinfo.linfo), variables, env)))
        end
    end

    function stackwalk(RC, session = LocalSession(), modules = active_modules;
            fromhook = false, rich_c = false, ip_only = false, collectRCs=false, cficache=nothing)
        stack = Any[]
        RCs = Any[]
        firstframe = true
        (fromhook ? rec_backtrace_hook : rec_backtrace)(RC, session, modules, ip_only, cficache) do RC
            keep_walking, frame = frameinfo(RC, session, modules, rich_c = rich_c, firstframe = firstframe)
            !isnull(frame) && (push!(stack, get(frame));
                collectRCs && push!(RCs, RC))
            firstframe = false
            return keep_walking
        end
        (reverse!(stack), reverse!(RCs))
    end

    function matches_condition(interp, condition)
        condition == nothing && return true
        if isa(condition, Expr)
            ok, res = ASTInterpreter.eval_in_interp(interp, condition)
            !ok && println("Conditional breakpoint errored. Breaking.")
            return !ok || res
        else
            error("Unexpected condition kind")
        end
    end

    function process_lowlevel_conditionals(loc, RC)
        !haskey(bps_at_location, loc) && return true
        stop = true
        for bp in bps_at_location[loc]
            for cond in bp.conditions
                isa(cond, Function) && cond(loc, RC) && return true
                # Will get evaluated later
                isa(cond, Expr) && return true
                stop = false
            end
        end
        stop
    end

    macro conditional(bp, condition)
        esc(:(let bp = $bp
            push!(bp.conditions, $(Expr(:quote, condition)))
            bp
        end))
    end

    function conditional(f, bp)
        push!(bp.conditions, f)
        bp
    end

    """
        Suspends other tasks that may want to access the terminal.
        In an out of process debugger, this would be the place
        where we take control of the tty for the debugger. Since
        we're not out-of-process, we instead just prevent those
        tasks from being notified of any reads by modifying internal
        datastructures.
    """
    function suspend_other_tasks()
        STDINwaitq = STDIN.readnotify.waitq
        GlobalWaitq = copy(Base.Workqueue)
        STDIN.readnotify.waitq = Any[]
        empty!(Base.Workqueue)
        STDINwaitq, GlobalWaitq
    end
    restore_other_tasks(state) = (STDIN.readnotify.waitq = state[1]; append!(Base.Workqueue, state[2]))

    function breakpoint_hit(hook, RC)
        if !process_lowlevel_conditionals(Location(LocalSession(), hook.addr), RC)
            return
        end
        stack = stackwalk(RC; fromhook = true)[1]
        stacktop = pop!(stack)
        linfo = stacktop.linfo
        fT = linfo.def.sig.parameters[1]
        def_linfo = linfo.def.lambda_template
        argnames = [Symbol("#target_self#");def_linfo.slotnames[2:def_linfo.nargs]]
        spectypes = [fT;linfo.specTypes.parameters[2:end]...]
        bps = bps_at_location[Location(LocalSession(),hook.addr)]
        target_line = minimum(map(bps) do bp
            idx = findfirst(s->isa(s, FileLineSource), bp.sources)
            idx != 0 ? bp.sources[idx].line : def_linfo.def.line
        end)
        conditions = reduce(vcat,map(bp->bp.conditions, bps))
        thunk = Expr(:->,Expr(:tuple,map(x->Expr(:(::),x[1],x[2]),zip(argnames,spectypes))...),Expr(:block,
            :(linfo = $(quot(linfo))),
            :((loctree, code) = ASTInterpreter.reparse_meth(linfo)),
            :(__env = ASTInterpreter.prepare_locals(linfo.def.lambda_template)),
            :(copy!(__env.sparams, linfo.sparam_vals)),
            [ :(__env.locals[$i] = Nullable{Any}($(argnames[i]))) for i = 1:length(argnames) ]...,
            :(interp = ASTInterpreter.enter(linfo,__env,
                $(collect(filter(x->!isa(x,CStackFrame),stack)));
                    loctree = loctree, code = code)),
            (target_line != linfo.def.line ?
                :(ASTInterpreter.advance_to_line(interp, $target_line)) :
                :(nothing)),
            :(tty_state = Gallium.suspend_other_tasks()),
            :((isempty($conditions) ||
                any(c->Gallium.matches_condition(interp,c),$conditions)) &&
                ASTInterpreter.RunDebugREPL(interp)),
            :(Gallium.restore_other_tasks(tty_state)),
            :(ASTInterpreter.finish!(interp)),
            :(return interp.retval::$(linfo.rettype))))
        f = eval(thunk)
        t = Tuple{spectypes...}
        faddr = Hooking.get_function_addr(f, t)
        Hooking.Deopt(faddr)
    end
    abstract LocationSource
    immutable Location
        vm
        addr::UInt64
    end
    type Breakpoint
        active_locations::Vector{Location}
        inactive_locations::Vector{Location}
        sources::Vector{LocationSource}
        disable_new::Bool
        conditions::Vector{Any}
    end
    Breakpoint(locations::Vector{Location}) = Breakpoint(locations, Location[], LocationSource[], false, Any[])
    Breakpoint() = Breakpoint(Location[], Location[], LocationSource[], false, Any[])

    function print_location(io::IO, vm::LocalSession, loc)
        ipinfo = Base.StackTraces.lookup(loc.addr+1)[end]
        if ipinfo.from_c
            println(io, "At address ", loc.addr)
        else
            linfo = get(ipinfo.linfo)
            ASTInterpreter.print_linfo_desc(io, linfo, true)
            println(io)
        end
    end

    function print_locations(io::IO, locations, prefix = " - ")
        for loc in locations
            print(io,prefix)
            print_location(io, loc.vm, loc)
        end
    end

    function Base.show(io::IO, b::Breakpoint)
        if isempty(b.active_locations) && isempty(b.inactive_locations) &&
            isempty(b.sources)
            println(io, "Empty Breakpoint")
            return
        end
        println(io, "Locations (+: active, -: inactive, *: source):")
        !isempty(b.active_locations) && print_locations(io, b.active_locations, " + ")
        !isempty(b.inactive_locations) && print_locations(io, b.inactive_locations, " - ")
        for source in b.sources
            print(io," * ")
            println(io,source)
        end
    end

    const bps_at_location = Dict{Location, Set{Breakpoint}}()
    # session => (addr => loc)
    disable(s::LocalSession, loc) = unhook(Ptr{Void}(loc.addr))
    disable(loc::Location) = disable(loc.vm, loc)
    function disable(bp::Breakpoint, loc::Location)
        pop!(bps_at_location[loc],bp)
        if isempty(bps_at_location[loc])
            disable(loc)
            delete!(bps_at_location,loc)
        end
    end
    function disable(b::Breakpoint)
        locs = copy(b.active_locations)
        empty!(b.active_locations)
        for loc in locs
            disable(b, loc)
            push!(b.inactive_locations, loc)
        end
        b.disable_new = true
    end
    remove(b::Breakpoint) = (disable(b); deleteat!(breakpoints, findfirst(breakpoints, b)); nothing)

    enable(s::LocalSession, loc) = hook(breakpoint_hit, Ptr{Void}(loc.addr))
    enable(loc::Location) = enable(loc.vm, loc)
    function enable(bp::Breakpoint, loc::Location)
        if !haskey(bps_at_location, loc)
            enable(loc)
            bps_at_location[loc] = Set{Breakpoint}()
        end
        push!(bps_at_location[loc], bp)
    end
    function enable(b::Breakpoint)
        locs = copy(b.inactive_locations)
        empty!(b.inactive_locations)
        for loc in locs
            enable(b, loc)
            push!(b.active_locations, loc)
        end
        b.disable_new = false
    end

    function _breakpoint_spec(spec::LambdaInfo, bp)
        llvmf = ccall(:jl_get_llvmf, Ptr{Void}, (Any, Bool, Bool), spec.specTypes, false, true)
        @assert llvmf != C_NULL
        fptr = ccall(:jl_get_llvm_fptr, UInt64, (Ptr{Void},), llvmf)
        @assert fptr != 0
        loc = Location(LocalSession(), fptr)
        add_location(bp, loc)
    end

    function _breakpoint_method(meth::Method, bp::Breakpoint, predicate = linfo->true)
        cache = meth.sig.parameters[1].name.mt.cache
        cache != nothing || return
        Base.visit(cache) do spec
            spec.def == meth || return
            predicate(spec) || return
            _breakpoint_spec(spec, bp)
        end
    end

    type SpecSource <: LocationSource
        bp::Breakpoint
        meth::Method
        predicate
        function SpecSource(bp::Breakpoint, meth::Method, predicate)
            !haskey(TracedMethods, meth) && (TracedMethods[meth] = Set{SpecSource}())
            ccall(:jl_trace_method, Void, (Any,), meth)
            this = new(bp, meth, predicate)
            push!(TracedMethods[meth], this)
            finalizer(this,function (this)
                pop!(TracedMethods[this.meth], this)
                if isempty(TracedMethods[this.meth])
                    ccall(:jl_untrace_method, Void, (Any,), this.meth)
                    delete!(TracedMethods, this.meth)
                end
            end)
            this
        end
    end
    function fire(s::SpecSource, linfo::LambdaInfo)
        s.predicate(linfo) || return
        _breakpoint_spec(linfo, s.bp)
    end

    const TracedMethods = Dict{Method, Set{SpecSource}}()
    function Base.show(io::IO, source::SpecSource)
        print(io,"Any matching specialization of ")
        ASTInterpreter.print_linfo_desc(io, source.meth.lambda_template, true)
    end

    function rebreak_tracer(x::Ptr{Void})
        linfo = unsafe_pointer_to_objref(x)::LambdaInfo
        !haskey(TracedMethods, linfo.def) && return nothing
        for s in TracedMethods[linfo.def]
            fire(s, linfo)
        end
        nothing
    end

    function add_meth_to_bp!(bp::Breakpoint, meth::Union{Method, TypeMapEntry}, predicate = linfo->true)
        isa(meth, TypeMapEntry) && (meth = meth.func)
        _breakpoint_method(meth, bp, predicate)
        push!(bp.sources, SpecSource(bp, meth, predicate))
        bp
    end

    function breakpoint(meth::Union{Method, TypeMapEntry})
        bp = add_meth_to_bp!(Breakpoint(), meth)
        push!(breakpoints, bp)
        bp
     end

    const breakpoints = Vector{Breakpoint}()

    function list_breakpoints()
        for (i, bp) in enumerate(breakpoints)
            println("[$i] $bp")
        end
    end

    function breakpoint(addr::Ptr{Void})
        hook(breakpoint_hit, addr)
    end

    function add_location(bp, loc)
        if bp.disable_new
            push!(bp.inactive_locations, loc)
        else
            push!(bp.active_locations, loc)
            enable(bp, loc)
        end
    end

    function _breakpoint_concrete(bp, t)
        addr = try
            Hooking.get_function_addr(t)
        catch err
            error("no method found for the specified argument types")
        end
        add_location(bp, Location(LocalSession(),addr))
    end

    function breakpoint(func, args::Union{Tuple,DataType})
        argtt = Base.to_tuple_type(args)
        t = Tuple{typeof(func), argtt.parameters...}
        bp = Breakpoint()
        if Base.isleaftype(t)
            _breakpoint_concrete(bp, t)
        else
            spec_predicate(linfo) = linfo.specTypes <: t
            meth_predicate(meth) = t <: meth.lambda_template.specTypes || meth.lambda_template.specTypes <: t
            for meth in methods(func, argtt)
                add_meth_to_bp!(bp, meth, spec_predicate)
            end
            push!(bp.sources, MethSource(bp, typeof(func), meth_predicate, spec_predicate))
        end
        push!(breakpoints, bp)
        bp
    end

    include("breakfile.jl")

    function method_tracer(x::Ptr{Void})
        ccall(:jl_trace_linfo, Void, (Ptr{Void},), x)
        nothing
    end

    function __init__()
        ccall(:jl_register_linfo_tracer, Void, (Ptr{Void},), cfunction(rebreak_tracer,Void,(Ptr{Void},)))
        ccall(:jl_register_method_tracer, Void, (Ptr{Void},), cfunction(method_tracer,Void,(Ptr{Void},)))
        ccall(:jl_register_newmeth_tracer, Void, (Ptr{Void},), cfunction(newmeth_tracer, Void, (Ptr{Void},)))
        update_shlibs!(LocalSession(), active_modules)
    end

    function breakpoint(f)
        bp = Breakpoint()
        for meth in methods(f)
            add_meth_to_bp!(bp, meth)
        end
        unshift!(bp.sources, MethSource(bp, typeof(f)))
        push!(breakpoints, bp)
        bp
    end

    macro breakpoint(ex0)
        Base.gen_call_with_extracted_types(:(Gallium.breakpoint),ex0)
    end

    # For now this is a very simple implementation. A better implementation
    # would trap and reuse logic. That will become important once we actually
    # support optimized code to avoid cloberring registers. For now do the dead
    # simple, stupid thing.
    function breakpoint()
        RC = Hooking.getcontext()
        # -1 to skip breakpoint (getcontext is inlined)
        stack, RCs = stackwalk(RC; fromhook = false)
        ASTInterpreter.RunDebugREPL(NativeStack(collect(filter(x->isa(x,JuliaStackFrame),stack[1:end-1]))))
    end

    const bp_on_error_conditions = Any[]
    function breakpoint_on_error_hit(thehook, RC)
        err = unsafe_pointer_to_objref(Ptr{Void}(get_dwarf(RC, :rdi)[]))
        stack = stackwalk(RC; fromhook = true)[1]
        ips = [x.ip-1 for x in stack]
        stack = NativeStack(filter(x->isa(x,JuliaStackFrame),stack))
        if !isempty(bp_on_error_conditions) &&
            !any(c->Gallium.matches_condition(stack,c),bp_on_error_conditions)
            hook(thehook)
            rethrow(err)
        end
        Base.with_output_color(:red, STDERR) do io
            print(io, "ERROR: ")
            Base.showerror(io, err, reverse(ips); backtrace=false)
            println(io)
        end
        println(STDOUT)
        ASTInterpreter.RunDebugREPL(stack)
        # Get a somewhat sensible backtrace when returning
        try; throw(); catch; end
        hook(thehook)
        rethrow(err)
    end

    # Compiling these function has an error thrown/caught in type inference.
    # Precompile them here, to make sure we make it throught
    precompile(breakpoint_on_error_hit,(Hooking.Hook,X86_64.BasicRegs))
    precompile(Hooking.callback,(Ptr{Void},))

    function breakpoint_on_error(enable = true)
        addr = cglobal(:jl_throw)
        if enable
            hook(breakpoint_on_error_hit, addr; auto_suspend = true)
        else
            unhook(addr)
        end
    end

    include("precompile.jl")
end
