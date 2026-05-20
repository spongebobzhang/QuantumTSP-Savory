using Graphs
using ConcurrentSim
using Statistics
using ResumableFunctions
using QuantumSavory
using QuantumSavory.ProtocolZoo: EntanglerProt, SwapperProt, EntanglementTracker, EntanglementCounterpart

@resumable function fidelity_consumer(sim, net, nodeA, nodeB, log, period)
    regA = net[nodeA]
    regB = net[nodeB]
    target = projector((Z1⊗Z1 + Z2⊗Z2) / sqrt(2))

    while true
        q1meta = query(regA, EntanglementCounterpart, nodeB, ❓; locked=false, assigned=true)
        if isnothing(q1meta)
            @yield timeout(sim, period)
            continue
        end

        q2meta = query(regB, EntanglementCounterpart, nodeA, q1meta.slot.idx; locked=false, assigned=true)
        if isnothing(q2meta)
            @yield timeout(sim, period)
            continue
        end

        q1 = q1meta.slot
        q2 = q2meta.slot
        @yield lock(q1) & lock(q2)

        untag!(q1, q1meta.id)
        untag!(q2, q2meta.id)

        ob1 = real(observable((q1, q2), Z⊗Z))
        ob2 = real(observable((q1, q2), X⊗X))
        fid = real(observable((q1, q2), target))
        push!(log, (t=now(sim), obs1=ob1, obs2=ob2, fidelity=fid))

        traceout!(regA[q1.idx], regB[q2.idx])
        unlock(q1)
        unlock(q2)
        @yield timeout(sim, period)
    end
end

"""
Throughput demo on chain v0-v1-v2-v3 (indices 1-4).

- Continuous nearest-neighbor entanglement generation
- Sequential swapping at v1 then v2
- Consumption/counting at endpoints v0 and v3

Outputs are written next to this script:
- throughput_summary.txt
- throughput_log.csv
"""
function throughput_demo(; T=200.0, save_entangler_plots=false, save_video=false, video_dt=0.05, video_fps=10)
    # Node mapping: v0=>1, v1=>2, v2=>3, v3=>4
    # Slot layout with parallel links:
    #   v0-v1: 2 links  => v0[1,2] <-> v1[1,2]
    #   v1-v2: 3 links  => v1[3,4,5] <-> v2[1,2,3]
    #   v2-v3: 2 links  => v2[4,5] <-> v3[1,2]
    net = RegisterNet(path_graph(4), [Register(2), Register(5), Register(5), Register(2)])
    sim = get_time_tracker(net)

    # Keep tag metadata synchronized during swapping.
    for node in vertices(net)
        @process EntanglementTracker(sim, net, node)()
    end

    # Continuous deterministic entanglers on the elementary links:
    # 2 parallel on (1,2), 3 parallel on (2,3), 2 parallel on (3,4).
    e12_1 = EntanglerProt(sim, net, 1, 2;
        rounds=-1, success_prob=0.7, attempt_time=0.3, retry_lock_time=0.01,
        chooseslotA=1, chooseslotB=1)
    e12_2 = EntanglerProt(sim, net, 1, 2;
        rounds=-1, success_prob=0.7, attempt_time=0.3, retry_lock_time=0.01,
        chooseslotA=2, chooseslotB=2)
    e23_1 = EntanglerProt(sim, net, 2, 3;
        rounds=-1, success_prob=0.9, attempt_time=0.3, retry_lock_time=0.01,
        chooseslotA=3, chooseslotB=1)
    e23_2 = EntanglerProt(sim, net, 2, 3;
        rounds=-1, success_prob=0.9, attempt_time=0.3, retry_lock_time=0.01,
        chooseslotA=4, chooseslotB=2)
    e23_3 = EntanglerProt(sim, net, 2, 3;
        rounds=-1, success_prob=0.9, attempt_time=0.3, retry_lock_time=0.01,
        chooseslotA=5, chooseslotB=3)
    e34_1 = EntanglerProt(sim, net, 3, 4;
        rounds=-1, success_prob=0.8, attempt_time=0.3, retry_lock_time=0.01,
        chooseslotA=4, chooseslotB=1)
    e34_2 = EntanglerProt(sim, net, 3, 4;
        rounds=-1, success_prob=0.8, attempt_time=0.3, retry_lock_time=0.01,
        chooseslotA=5, chooseslotB=2)
    @process e12_1()
    @process e12_2()
    @process e23_1()
    @process e23_2()
    @process e23_3()
    @process e34_1()
    @process e34_2()

    # Sequential swappers at intermediate nodes.
    # argmin/argmax are applied to the local candidate slot indices at the swapping node
    @process SwapperProt(sim, net, 2;
        nodeL=(x -> x < 2), nodeH=(x -> x > 2),
        chooseL=argmin, chooseH=argmax, rounds=-1, retry_lock_time=0.01)()
    @process SwapperProt(sim, net, 3;
        nodeL=(x -> x < 3), nodeH=(x -> x > 3),
        chooseL=argmin, chooseH=argmax, rounds=-1, retry_lock_time=0.01)()

    # Consumer logs endpoint observables and Bell-state fidelity, then frees qubits.
    log = NamedTuple{(:t, :obs1, :obs2, :fidelity), Tuple{Float64, Float64, Float64, Float64}}[]
    @process fidelity_consumer(sim, net, 1, 4, log, 0.01)

    outdir = @__DIR__
    registercoords = nothing

    function make_registercoords(cm)
        p2f = getfield(cm, :Point2f)
        return [
            Base.invokelatest(p2f, 0.0, 0.0),
            Base.invokelatest(p2f, 2.0, 0.0),
            Base.invokelatest(p2f, 4.0, 0.0),
            Base.invokelatest(p2f, 6.0, 0.0),
        ]
    end

    function add_node_labels!(cm, ax, coords)
        text_fn = getfield(cm, :text!)
        xs = [getproperty(c, :data)[1] + 0.6 for c in coords]
        ys = [getproperty(c, :data)[2] for c in coords]
        labels = ["v0", "v1", "v2", "v3"]
        Base.invokelatest(text_fn, ax, xs, ys; text=labels, align=(:left, :center), color=:black, fontsize=20)
    end

    ran_simulation = false

    if save_video
        try
            video_dt > 0 || throw(ArgumentError("`video_dt` must be positive."))
            cm = Base.require(Main, :CairoMakie)
            Base.invokelatest(getfield(cm, :activate!))
            fig = Base.invokelatest(getfield(cm, :Figure))
            subfig = Base.invokelatest(getindex, fig, 1, 1)
            registercoords = make_registercoords(cm)
            observable_ctor = getfield(cm, :Observable)
            netobs = Base.invokelatest(observable_ctor, net)
            _, ax, _, _ = Base.invokelatest(registernetplot_axis, subfig, netobs; registercoords=registercoords)
            add_node_labels!(cm, ax, registercoords)
            nframes = max(1, Int(ceil(T / video_dt)))
            record_fn = getfield(cm, :record)
            video_path = joinpath(outdir, "lleg_swapping.mp4")
            Base.invokelatest() do
                record_fn(fig, video_path, 1:nframes; framerate=video_fps) do _
                    run(sim, min(now(sim) + video_dt, T))
                    netobs[] = net
                end
            end
            ran_simulation = true
            println("wrote ", video_path)
        catch err
            @warn "Skipping video export. Install/import CairoMakie and FFMPEG support to enable `save_video=true`." exception=(err, catch_backtrace())
        end
    end

    ran_simulation || run(sim, T)

    # network view
    try
        cm = Base.require(Main, :CairoMakie)
        Base.invokelatest(getfield(cm, :activate!))
        fig = Base.invokelatest(getfield(cm, :Figure))
        subfig = Base.invokelatest(getindex, fig, 1, 1)
        isnothing(registercoords) && (registercoords = make_registercoords(cm))
        _, ax, _, _ = Base.invokelatest(registernetplot_axis, subfig, net; registercoords=registercoords)
        add_node_labels!(cm, ax, registercoords)
        Base.invokelatest(getfield(cm, :save), joinpath(outdir, "network_view.png"), fig)
    catch err
        @warn "Skipping network view plot. Install/import CairoMakie to enable PNG rendering." exception=(err, catch_backtrace())
    end


    successes = length(log)
    throughput = successes / T
    mean_zz = successes == 0 ? NaN : mean(x.obs1 for x in log)
    mean_xx = successes == 0 ? NaN : mean(x.obs2 for x in log)
    mean_fidelity = successes == 0 ? NaN : mean(x.fidelity for x in log)

    summary_path = joinpath(outdir, "throughput_summary.txt")
    csv_path = joinpath(outdir, "throughput_log.csv")

    open(summary_path, "w") do io
        println(io, "T = ", T)
        println(io, "successes = ", successes)
        println(io, "throughput_pairs_per_time = ", throughput)
        println(io, "mean_ZZ = ", mean_zz)
        println(io, "mean_XX = ", mean_xx)
        println(io, "mean_fidelity_phi_plus = ", mean_fidelity)
    end

    open(csv_path, "w") do io
        println(io, "time,obs_zz,obs_xx,fidelity_phi_plus")
        for row in log
            println(io, row.t, ",", row.obs1, ",", row.obs2, ",", row.fidelity)
        end
    end

    if save_entangler_plots
        try
            # Load backend at runtime and avoid world-age issues in script execution.
            cm = Base.require(Main, :CairoMakie)
            Base.invokelatest(getfield(cm, :activate!))
            for (name, prot) in (
                ("e12_1", e12_1), ("e12_2", e12_2),
                ("e23_1", e23_1), ("e23_2", e23_2), ("e23_3", e23_3),
                ("e34_1", e34_1), ("e34_2", e34_2),
            )
                open(joinpath(outdir, "entangler_" * name * ".png"), "w") do io
                    Base.invokelatest(show, io, MIME"image/png"(), prot)
                end
            end
            println("wrote entangler_e12_1/2.png, entangler_e23_1/2/3.png, entangler_e34_1/2.png")
        catch err
            @warn "Skipping entangler plots. Install/import CairoMakie to enable `save_entangler_plots=true`." exception=(err, catch_backtrace())
        end
    end

    println("T = ", T)
    println("successes = ", successes)
    println("throughput (pairs/time) = ", throughput)
    println("mean <ZZ> = ", mean_zz, ", mean <XX> = ", mean_xx)
    println("mean fidelity to |Phi+> = ", mean_fidelity)
    println("wrote ", summary_path)
    println("wrote ", csv_path)
    return (T=T, successes=successes, throughput=throughput, mean_zz=mean_zz, mean_xx=mean_xx, mean_fidelity=mean_fidelity)
end

throughput_demo(T=200.0)
