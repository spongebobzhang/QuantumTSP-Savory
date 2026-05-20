include("qtsp_window_update_two_node.jl")

# gamma and delta
script_update_stepsize(n) = 1 / (n + 100)^0.7
script_werner_perturbation(n) = 0.05 / (n + 50)^0.15
# Parameters for the QTSP window update
const QTSP_WINDOW_UPDATE_SCRIPT_PARAMS = (;
    target_tp=2.4,
    iterations=10,
    initial_window_size=10,
    initial_werner_w=0.75,
    max_window_size=100,
    sim_time=nothing,
    # probe is to calculate the w_next based on plus/minus Werner parameters
    # it's a short simulation to get the gradient and won't affect the main simulation
    # probe_repeats: number of times to repeat each probe (plus and minus) for a given window size.
    probe_repeats=1,
    update_stepsize=script_update_stepsize,
    werner_perturbation=script_werner_perturbation,
    output_txt=joinpath(@__DIR__, "qtsp_window_update_results.txt"),
    flow_uuid=QTSP_DEFAULT_FLOW_UUID,
    chi=30.0,
    send_rate=nothing,
    distance_km=25.0,
    a_eta=1.0,
    beta_per_km=0.046,
    detector_a_p=0.9,
    detection_prob=nothing,
    memory_slots=nothing,
    classical_delay=0.0,
    quantum_delay=1.0,
    initial_delay=0.0,
    source_ack_timeout=10.0,
    window_stats_interval=1000.0,
)

function main()
    run_qtsp_window_update(; QTSP_WINDOW_UPDATE_SCRIPT_PARAMS...)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
