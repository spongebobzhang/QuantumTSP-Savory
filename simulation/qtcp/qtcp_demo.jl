using QuantumSavory
using QuantumSavory.ProtocolZoo
using ConcurrentSim
using Graphs
using Random
using Test

@testset "EndNodeController turning Flow into QDatagram" begin
    registers = [Register(5) for _ in 1:2] # 2 nodes, each with 5 memory slots
    net = RegisterNet(registers)
    sim = get_time_tracker(net)
    
    end_controller = EndNodeController(sim, net, 1) # node 1 is the source
    @process end_controller()

    test_flow = Flow(
        src=1,
        dst=2,
        npairs=10,
        uuid=42
    )

    put!(net[1], test_flow)
    run(sim, 2.0)

    mb1 = messagebuffer(net, 1)
    qdatagram = query(mb1, QDatagram, ❓, ❓, ❓, ❓, ❓, ❓)
    @test collect(qdatagram.tag)[2:7] == [42, 1, 2, 0, 1, 0.0]
end

@testset "NetworkNodeController creating LinkLevelRequest" begin
    registers = [Register(5) for _ in 1:2]
    net = RegisterNet(registers)
    sim = get_time_tracker(net)

    network_controller = NetworkNodeController(sim, net, 1)
    @process network_controller()

    test_qdatagram = QDatagram(
        flow_uuid=42,
        flow_src=1,
        flow_dst=2,
        correction=0,
        seq_num=1,
        start_time=0.0
    )

    run(sim, 1.0)
    put!(net[1], test_qdatagram)
    run(sim, 2.0)

    mb1 = messagebuffer(net, 1)
    link_request = query(mb1, LinkLevelRequest, ❓, ❓, ❓)
    @test !isnothing(link_request)
    @test collect(link_request.tag)[2:3] == [42, 1]
end

@testset "LinkController responding to LinkLevelRequest with LinkLevelReply" begin
    registers = [Register(5) for _ in 1:2]
    net = RegisterNet(registers)
    sim = get_time_tracker(net)

    link_controller = LinkController(
        sim=sim,
        net=net,
        nodeA=1,
        nodeB=2
    )
    @process link_controller()

    test_request = LinkLevelRequest(
        flow_uuid=42,
        seq_num=1,
        remote_node=2
    )

    put!(net[1], test_request)
    run(sim, 3.0)

    mb1 = messagebuffer(net, 1)
    mb2 = messagebuffer(net, 2)

    link_reply1 = query(mb1, LinkLevelReply, ❓, ❓, ❓)
    link_reply2 = query(mb2, LinkLevelReply, ❓, ❓, ❓)
    link_reply_at_destination1 = query(mb1, LinkLevelReplyAtHop, ❓, ❓, ❓)
    link_reply_at_destination2 = query(mb2, LinkLevelReplyAtHop, ❓, ❓, ❓)

    @test !isnothing(link_reply1) && isnothing(link_reply2)
    @test isnothing(link_reply_at_destination1) && !isnothing(link_reply_at_destination2)
    @test link_reply1.tag[2] == 42
    @test link_reply1.tag[3] == 1
    @test link_reply_at_destination2.tag[2] == 42
    @test link_reply_at_destination2.tag[3] == 1
end

@testset "LinkController responding to LinkLevelRequest and NetworkNodeController forwarding QDatagrams" begin
    registers = [Register(5) for _ in 1:3]
    net = RegisterNet(registers)
    sim = get_time_tracker(net)

    network_controller = NetworkNodeController(sim, net, 1)
    @process network_controller()

    link_controller = LinkController(
        sim=sim,
        net=net,
        nodeA=1,
        nodeB=2
    )
    @process link_controller()

    test_qdatagram = QDatagram(
        flow_uuid=42,
        flow_src=1,
        flow_dst=3,
        correction=0,
        seq_num=1,
        start_time=0.0
    )

    put!(net[1], test_qdatagram)
    run(sim, 5.0)

    mb2 = messagebuffer(net, 2)
    forwarded_qdatagram = query(mb2, QDatagram, 42, 1, 3, 0, 1, ❓)
    @test !isnothing(forwarded_qdatagram)
end

@testset "Complete QTCP protocol flow" begin
    registers = [Register(5) for _ in 1:5]
    net = RegisterNet(registers)
    sim = get_time_tracker(net)

    source_controller = EndNodeController(sim, net, 1)
    dest_controller = EndNodeController(sim, net, 5)
    @process source_controller()
    @process dest_controller()

    for node in 1:5
        network_controller = NetworkNodeController(sim, net, node)
        @process network_controller()
    end

    for edge in edges(net)
        link_controller = LinkController(
            sim=sim,
            net=net,
            nodeA=edge.src,
            nodeB=edge.dst
        )
        @process link_controller()
    end

    test_flow = Flow(
        src=1,
        dst=5,
        npairs=4,
        uuid=99
    )

    put!(net[1], test_flow)
    run(sim, 1000.0)

    mb1 = messagebuffer(net, 1)
    mb2 = messagebuffer(net, 2)
    mb3 = messagebuffer(net, 3)
    mb4 = messagebuffer(net, 4)
    mb5 = messagebuffer(net, 5)

    @test isempty(mb2.buffer)
    @test isempty(mb3.buffer)
    @test isempty(mb4.buffer)
    for _ in 1:4
        @test !isnothing(querydelete!(mb1, QTCPPairBegin, ❓, ❓, ❓, ❓, ❓, ❓))
        @test !isnothing(querydelete!(mb5, QTCPPairEnd, ❓, ❓, ❓, ❓, ❓, ❓))
    end
    @test isempty(mb1.buffer)
    @test isempty(mb5.buffer)
end
