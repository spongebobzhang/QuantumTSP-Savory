using Graphs
using ConcurrentSim
using ResumableFunctions
using Statistics
using QuantumSavory
using QuantumSavory.ProtocolZoo: EntanglerProt, SwapperProt, EntanglementTracker, EntanglementCounterpart

"""
Throughput demo on chain v0-v1-v2-v3 (indices 1-4).

- Continuous nearest-neighbor entanglement generation
- Sequential swapping at v1 then v2
- Consumption/counting at endpoints v0 and v3

Outputs are written next to this script:
- fidelity_summary.txt
- fidelity_log.csv
"""
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

function throughput_demo(; T=200.0)
    # Node mapping: v0=>1, v1=>2, v2=>3, v3=>4
    # Slot layout:
    #   v0[1] <-> v1[1]
    #   v1[2] <-> v2[1]
    #   v2[2] <-> v3[1]
    net = RegisterNet(path_graph(4), [Register(1), Register(2), Register(2), Register(1)])
    sim = get_time_tracker(net)

    # Keep tag metadata synchronized during swapping.
    for node in vertices(net)
        @process EntanglementTracker(sim, net, node)()
    end

    # Continuous deterministic entanglers on the three elementary links.
    @process EntanglerProt(sim, net, 1, 2;
        rounds=-1, success_prob=1.0, attempt_time=0.2, retry_lock_time=0.01,
        chooseslotA=1, chooseslotB=1)()
    @process EntanglerProt(sim, net, 2, 3;
        rounds=-1, success_prob=1.0, attempt_time=0.2, retry_lock_time=0.01,
        chooseslotA=2, chooseslotB=1)()
    @process EntanglerProt(sim, net, 3, 4;
        rounds=-1, success_prob=1.0, attempt_time=0.2, retry_lock_time=0.01,
        chooseslotA=2, chooseslotB=1)()

    # Sequential swappers at intermediate nodes.
    @process SwapperProt(sim, net, 2;
        nodeL=(x -> x < 2), nodeH=(x -> x > 2),
        chooseL=argmin, chooseH=argmax, rounds=-1, retry_lock_time=0.01)()
    @process SwapperProt(sim, net, 3;
        nodeL=(x -> x < 3), nodeH=(x -> x > 3),
        chooseL=argmin, chooseH=argmax, rounds=-1, retry_lock_time=0.01)()

    # Consumer logs endpoint observables and Bell-state fidelity, then frees qubits.
    log = NamedTuple{(:t, :obs1, :obs2, :fidelity), Tuple{Float64, Float64, Float64, Float64}}[]
    @process fidelity_consumer(sim, net, 1, 4, log, 0.01)

    run(sim, T)

    successes = length(log)
    throughput = successes / T
    mean_zz = successes == 0 ? NaN : mean(x.obs1 for x in log)
    mean_xx = successes == 0 ? NaN : mean(x.obs2 for x in log)
    mean_fidelity = successes == 0 ? NaN : mean(x.fidelity for x in log)

    outdir = @__DIR__
    summary_path = joinpath(outdir, "fidelity_summary.txt")
    csv_path = joinpath(outdir, "fidelity_log.csv")

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

    println("T = ", T)
    println("successes = ", successes)
    println("throughput (pairs/time) = ", throughput)
    println("mean <ZZ> = ", mean_zz, ", mean <XX> = ", mean_xx)
    println("mean fidelity to |Phi+> = ", mean_fidelity)
    println("wrote ", summary_path)
    println("wrote ", csv_path)
    return (
        T=T,
        successes=successes,
        throughput=throughput,
        mean_zz=mean_zz,
        mean_xx=mean_xx,
        mean_fidelity=mean_fidelity
    )
end

throughput_demo(T=200.0)
