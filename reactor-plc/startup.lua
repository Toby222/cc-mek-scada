--
-- Reactor Programmable Logic Controller
--

os.loadAPI("scada-common/log.lua")
os.loadAPI("scada-common/util.lua")
os.loadAPI("scada-common/ppm.lua")
os.loadAPI("scada-common/comms.lua")

os.loadAPI("reactor-plc/config.lua")
os.loadAPI("reactor-plc/plc.lua")

local R_PLC_VERSION = "alpha-v0.1.0"

local print_ts = util.print_ts

print(">> Reactor PLC " .. R_PLC_VERSION .. " <<")

-- mount connected devices
ppm.mount_all()

local reactor = ppm.get_device("fissionReactor")
local modem = ppm.get_device("modem")

local init_ok = true
local control_degraded = { degraded = false, no_reactor = false, no_modem = false }

-- we need a reactor and a modem
if reactor == nil then
    print_ts("Fission reactor not found. Running in a degraded state...\n");
    log._warning("no reactor on startup")
    init_ok = false
    control_degraded.degraded = true
    control_degraded.no_reactor = true
end
if modem == nil then
    print_ts("No modem found. Disabling reactor and running in a degraded state...\n")
    log._warning("no modem on startup")
    reactor.scram()
    init_ok = false
    control_degraded.degraded = true
    control_degraded.no_modem = true
end

::init::
if init_ok then
    -- just booting up, no fission allowed (neutrons stay put thanks)
    reactor.scram()

    -- init internal safety system
    local iss = plc.iss_init(reactor)
    log._debug("iss init")

    -- start comms
    local plc_comms = plc.comms_init(config.REACTOR_ID, modem, config.LISTEN_PORT, config.SERVER_PORT, reactor, iss)
    log._debug("comms init")

    -- comms watchdog, 3 second timeout
    local conn_watchdog = watchdog.new_watchdog(3)
    log._debug("conn watchdog started")

    -- loop clock (10Hz, 2 ticks)
    local loop_tick = os.startTimer(0.05)
    log._debug("loop clock started")
else
    log._warning("booted in a degraded state, awaiting peripheral connections...")
end

-- send status updates at ~3.33Hz (every 6 server ticks) (every 3 loop ticks)
-- send link requests at 0.5Hz (every 40 server ticks) (every 20 loop ticks)
local UPDATE_TICKS = 3
local LINK_TICKS = 20

-- start by linking
local ticks_to_update = LINK_TICKS

-- runtime variables
local control_state = false
local reactor_scram = true      -- treated as latching e-stop

-- event loop
while true do
    local event, param1, param2, param3, param4, param5 = os.pullEventRaw()

    if init_ok then
        -- if we tried to SCRAM but failed, keep trying
        -- if it disconnected, isPowered will return nil (and error logs will get spammed at 10Hz, so disable reporting)
        -- in that case, SCRAM won't be called until it reconnects (this is the expected use of this check)
        ppm.disable_reporting()
        if reactor_scram and reactor.isPowered() then
            reactor.scram()
        end
        ppm.enable_reporting()
    end

    -- check for peripheral changes before ISS checks
    if event == "peripheral_detach" then
        local device = ppm.handle_unmount(param1)

        if device.type == "fissionReactor" then
            print_ts("reactor disconnected!\n")
            log._error("reactor disconnected!")
            control_degraded.no_reactor = true
            -- send an alarm: plc_comms.send_alarm(ALARMS.PLC_PERI_DC) ?
        elseif device.type == "modem" then
            print_ts("modem disconnected!\n")
            log._error("modem disconnected!")
            control_degraded.no_modem = true

            if init_ok then
                -- try to scram reactor if it is still connected
                reactor_scram = true
                if reactor.scram() then
                    print_ts("successful reactor SCRAM\n")
                else
                    print_ts("failed reactor SCRAM\n")
                end
            end

            control_degraded.degraded = true
        end
    elseif event == "peripheral" then
        local device = ppm.mount(param1)

        if device.type == "fissionReactor" then
            -- reconnected reactor
            reactor_scram = true
            device.scram()

            print_ts("reactor reconnected.\n")
            log._info("reactor reconnected.")
            control_degraded.no_reactor = false

            if init_ok then
                iss.reconnect_reactor(device)
                plc_comms.reconnect_reactor(device)
            end

            -- determine if we are still in a degraded state
            if get_device("modem") not nil then
                control_degraded.degraded = false
            end
        elseif device.type == "modem" then
            -- reconnected modem
            if init_ok then
                plc_comms.reconnect_modem(device)
            end

            print_ts("modem reconnected.\n")
            log._info("modem reconnected.")
            control_degraded.no_modem = false

            -- determine if we are still in a degraded state
            if ppm.get_device("fissionReactor") not nil then
                control_degraded.degraded = false
            end
        end

        if not init_ok and not control_degraded.degraded then
            init_ok = false
            goto init
        end
    end

    -- check safety (SCRAM occurs if tripped)
    if not control_degraded.degraded then
        local iss_tripped, iss_status, iss_first = iss.check()
        reactor_scram = reactor_scram or iss_tripped
        if iss_first then
            plc_comms.send_iss_alarm(iss_status)
        end
    end

    -- handle event
    if event == "timer" and param1 == loop_tick then
        if not control_degraded.no_modem then
            -- basic event tick, send updated data if it is time (~3.33Hz)
            -- iss was already checked (main reason for this tick rate)
            ticks_to_update = ticks_to_update - 1

            if plc_comms.is_linked() then
                if ticks_to_update <= 0 then
                    plc_comms.send_status(control_state, iss_tripped)
                    ticks_to_update = UPDATE_TICKS
                end
            else
                if ticks_to_update <= 0 then
                    plc_comms.send_link_req()
                    ticks_to_update = LINK_TICKS
                end
            end
        end
    elseif event == "modem_message" then
        -- got a packet
        -- feed the watchdog first so it doesn't uhh...eat our packets
        conn_watchdog.feed()

        local packet = plc_comms.parse_packet(p1, p2, p3, p4, p5)
        plc_comms.handle_packet(packet)
        reactor_scram = reactor_scram or plc_comms.is_scrammed()
    elseif event == "timer" and param1 == conn_watchdog.get_timer() then
        -- haven't heard from server recently? shutdown reactor
        reactor_scram = true        
        plc_comms.unlink()
        iss.trip_timeout()
        print_ts("[alert] server timeout, reactor disabled\n")
    elseif event == "terminate" then
        -- safe exit
        if init_ok then
            reactor_scram = true
            if reactor.scram() then
                print_ts("[alert] exiting, reactor disabled\n")
            else
                -- send an alarm: plc_comms.send_alarm(ALARMS.PLC_LOST_CONTROL) ?
                print_ts("[alert] exiting, reactor failed to disable\n")
            end
        end
        -- send an alarm: plc_comms.send_alarm(ALARMS.PLC_SHUTDOWN) ?
        print_ts("[alert] exited")
        return
    end
end
