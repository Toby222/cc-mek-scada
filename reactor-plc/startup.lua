--
-- Reactor Programmable Logic Controller
--

os.loadAPI("scada-common/log.lua")
os.loadAPI("scada-common/util.lua")
os.loadAPI("scada-common/ppm.lua")
os.loadAPI("scada-common/comms.lua")

os.loadAPI("config.lua")
os.loadAPI("plc.lua")

local R_PLC_VERSION = "alpha-v0.1.2"

local print = util.print
local println = util.println
local print_ts = util.print_ts
local println_ts = util.println_ts

log._info("========================================")
log._info("BOOTING reactor-plc.startup " .. R_PLC_VERSION)
log._info("========================================")
println(">> Reactor PLC " .. R_PLC_VERSION .. " <<")

-- mount connected devices
ppm.mount_all()

local reactor = ppm.get_device("fissionReactor")
local modem = ppm.get_device("modem")

local networked = config.NETWORKED

local plc_state = {
    init_ok = true,
    scram = true,       -- treated as latching e-stop, all conditions must be OK to set false
    degraded = false,
    no_reactor = false,
    no_modem = false
}

-- we need a reactor and a modem
if reactor == nil then
    println("boot> fission reactor not found");
    log._warning("no reactor on startup")

    plc_state.init_ok = false
    plc_state.degraded = true
    plc_state.no_reactor = true
end
if networked and modem == nil then
    println("boot> modem not found")
    log._warning("no modem on startup")

    if reactor ~= nil then
        reactor.scram()
    end

    plc_state.init_ok = false
    plc_state.degraded = true
    plc_state.no_modem = true
end

local iss = nil
local plc_comms = nil
local conn_watchdog = nil

-- send status updates at ~3.33Hz (every 6 server ticks) (every 3 loop ticks)
-- send link requests at 0.5Hz (every 40 server ticks) (every 20 loop ticks)
local UPDATE_TICKS = 3
local LINK_TICKS = 20

local loop_tick = nil
local ticks_to_update = LINK_TICKS  -- start by linking

function init()
    if plc_state.init_ok then
        -- just booting up, no fission allowed (neutrons stay put thanks)
        reactor.scram()

        -- init internal safety system
        iss = plc.iss_init(reactor)
        log._debug("iss init")

        if networked then
            -- start comms
            plc_comms = plc.comms_init(config.REACTOR_ID, modem, config.LISTEN_PORT, config.SERVER_PORT, reactor, iss)
            log._debug("comms init")

            -- comms watchdog, 3 second timeout
            conn_watchdog = util.new_watchdog(3)
            log._debug("conn watchdog started")
        else
            log._debug("running without networking")
        end

        -- loop clock (10Hz, 2 ticks)
        loop_tick = os.startTimer(0.05)
        log._debug("loop clock started")

        println("boot> completed");
    else
        println("boot> system in degraded state, awaiting devices...")
        log._warning("booted in a degraded state, awaiting peripheral connections...")
    end
end

-- initialize PLC
init()

-- event loop
while true do
    local event, param1, param2, param3, param4, param5 = os.pullEventRaw()

    if plc_state.init_ok then
        -- if we tried to SCRAM but failed, keep trying
        -- if it disconnected, isPowered will return nil (and error logs will get spammed at 10Hz, so disable reporting)
        -- in that case, SCRAM won't be called until it reconnects (this is the expected use of this check)
        ppm.disable_reporting()
        if plc_state.scram and reactor.getStatus() then
            reactor.scram()
        end
        ppm.enable_reporting()
    end

    -- check for peripheral changes before ISS checks
    if event == "peripheral_detach" then
        local device = ppm.handle_unmount(param1)

        if device.type == "fissionReactor" then
            println_ts("reactor disconnected!")
            log._error("reactor disconnected!")
            plc_state.no_reactor = true
            plc_state.degraded = true
            -- send an alarm: plc_comms.send_alarm(ALARMS.PLC_PERI_DC) ?
        elseif networked and device.type == "modem" then
            println_ts("modem disconnected!")
            log._error("modem disconnected!")
            plc_state.no_modem = true

            if plc_state.init_ok then
                -- try to scram reactor if it is still connected
                plc_state.scram = true
                if reactor.scram() then
                    println_ts("successful reactor SCRAM")
                else
                    println_ts("failed reactor SCRAM")
                end
            end

            plc_state.degraded = true
        end
    elseif event == "peripheral" then
        local type, device = ppm.mount(param1)

        if type == "fissionReactor" then
            -- reconnected reactor
            reactor = device

            plc_state.scram = true
            reactor.scram()

            println_ts("reactor reconnected.")
            log._info("reactor reconnected.")
            plc_state.no_reactor = false

            if plc_state.init_ok then
                iss.reconnect_reactor(reactor)
                if networked then
                    plc_comms.reconnect_reactor(reactor)
                end
            end

            -- determine if we are still in a degraded state
            if not networked or ppm.get_device("modem") ~= nil then
                plc_state.degraded = false
            end
        elseif networked and type == "modem" then
            -- reconnected modem
            modem = device

            if plc_state.init_ok then
                plc_comms.reconnect_modem(modem)
            end

            println_ts("modem reconnected.")
            log._info("modem reconnected.")
            plc_state.no_modem = false

            -- determine if we are still in a degraded state
            if ppm.get_device("fissionReactor") ~= nil then
                plc_state.degraded = false
            end
        end

        if not plc_state.init_ok and not plc_state.degraded then
            plc_state.init_ok = true
            init()
        end
    end

    -- check safety (SCRAM occurs if tripped)
    if not plc_state.degraded then
        local iss_tripped, iss_status, iss_first = iss.check()
        plc_state.scram = plc_state.scram or iss_tripped
        if networked and iss_first then
            plc_comms.send_iss_alarm(iss_status)
        end
    elseif plc_state.init_ok then
        reactor.scram()
    end

    -- handle event
    if event == "timer" and param1 == loop_tick and networked and not plc_state.no_modem then
        -- basic event tick, send updated data if it is time (~3.33Hz)
        -- iss was already checked (that's the main reason for this tick rate)
        ticks_to_update = ticks_to_update - 1

        if plc_comms.is_linked() then
            if ticks_to_update <= 0 then
                plc_comms.send_status(iss_tripped)
                ticks_to_update = UPDATE_TICKS
            end
        else
            if ticks_to_update <= 0 then
                plc_comms.send_link_req()
                ticks_to_update = LINK_TICKS
            end
        end
    elseif event == "modem_message" and networked and not plc_state.no_modem then
        -- got a packet
        -- feed the watchdog first so it doesn't uhh...eat our packets
        conn_watchdog.feed()

        local packet = plc_comms.parse_packet(p1, p2, p3, p4, p5)
        plc_comms.handle_packet(packet)
        plc_state.scram = plc_state.scram or plc_comms.is_scrammed()
    elseif event == "timer" and param1 == conn_watchdog.get_timer() and networked then
        -- haven't heard from server recently? shutdown reactor
        plc_state.scram = true
        plc_comms.unlink()
        iss.trip_timeout()
        println_ts("server timeout, reactor disabled")
        log._warning("server timeout, reactor disabled")
    elseif event == "terminate" then
        -- safe exit
        if plc_state.init_ok then
            plc_state.scram = true
            if reactor.scram() then
                println_ts("reactor disabled")
            else
                -- send an alarm: plc_comms.send_alarm(ALARMS.PLC_LOST_CONTROL) ?
                println_ts("exiting, reactor failed to disable")
            end
        end
        -- send an alarm: plc_comms.send_alarm(ALARMS.PLC_SHUTDOWN) ?
        println_ts("exited")
        log._info("terminate requested, exiting")
        return
    end
end
