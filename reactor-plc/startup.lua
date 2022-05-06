--
-- Reactor Programmable Logic Controller
--

local log = require("scada-common.log")
local mqueue = require("scada-common.mqueue")
local ppm = require("scada-common.ppm")
local util = require("scada-common.util")

local config = require("config")
local plc = require("plc")
local threads = require("threads")

local R_PLC_VERSION = "alpha-v0.6.4"

local print = util.print
local println = util.println
local print_ts = util.print_ts
local println_ts = util.println_ts

log.init(config.LOG_PATH, config.LOG_MODE)

log.info("========================================")
log.info("BOOTING reactor-plc.startup " .. R_PLC_VERSION)
log.info("========================================")
println(">> Reactor PLC " .. R_PLC_VERSION .. " <<")

-- mount connected devices
ppm.mount_all()

-- shared memory across threads
local __shared_memory = {
    -- networked setting
    networked = config.NETWORKED,

    -- PLC system state flags
    plc_state = {
        init_ok = true,
        shutdown = false,
        degraded = false,
        no_reactor = false,
        no_modem = false
    },

    setpoints = {
        burn_rate_en = false,
        burn_rate = 0.0
    },
    
    -- core PLC devices
    plc_dev = {
        reactor = ppm.get_fission_reactor(),
        modem = ppm.get_wireless_modem()
    },

    -- system objects
    plc_sys = {
        rps = nil,
        plc_comms = nil,
        conn_watchdog = nil
    },

    -- message queues
    q = {
        mq_rps = mqueue.new(),
        mq_comms_tx = mqueue.new(),
        mq_comms_rx = mqueue.new()
    }
}

local smem_dev = __shared_memory.plc_dev
local smem_sys = __shared_memory.plc_sys

local plc_state = __shared_memory.plc_state

-- we need a reactor and a modem
if smem_dev.reactor == nil then
    println("boot> fission reactor not found");
    log.warning("no reactor on startup")

    plc_state.init_ok = false
    plc_state.degraded = true
    plc_state.no_reactor = true
end
if networked and smem_dev.modem == nil then
    println("boot> wireless modem not found")
    log.warning("no wireless modem on startup")

    if smem_dev.reactor ~= nil then
        smem_dev.reactor.scram()
    end

    plc_state.init_ok = false
    plc_state.degraded = true
    plc_state.no_modem = true
end

function init()
    if plc_state.init_ok then
        -- just booting up, no fission allowed (neutrons stay put thanks)
        smem_dev.reactor.scram()

        -- init reactor protection system
        smem_sys.rps = plc.rps_init(smem_dev.reactor)
        log.debug("rps init")

        if __shared_memory.networked then
            -- start comms
            smem_sys.plc_comms = plc.comms(config.REACTOR_ID, smem_dev.modem, config.LISTEN_PORT, config.SERVER_PORT, smem_dev.reactor, smem_sys.rps)
            log.debug("comms init")

            -- comms watchdog, 3 second timeout
            smem_sys.conn_watchdog = util.new_watchdog(3)
            log.debug("conn watchdog started")
        else
            println("boot> starting in offline mode");
            log.debug("running without networking")
        end

        os.queueEvent("clock_start")

        println("boot> completed");
    else
        println("boot> system in degraded state, awaiting devices...")
        log.warning("booted in a degraded state, awaiting peripheral connections...")
    end
end

-- initialize PLC
init()

-- init threads
local main_thread = threads.thread__main(__shared_memory, init)
local rps_thread  = threads.thread__rps(__shared_memory)

if __shared_memory.networked then
    -- init comms threads
    local comms_thread_tx = threads.thread__comms_tx(__shared_memory)
    local comms_thread_rx = threads.thread__comms_rx(__shared_memory)

    -- setpoint control only needed when networked
    local sp_ctrl_thread = threads.thread__setpoint_control(__shared_memory)

    -- run threads
    parallel.waitForAll(main_thread.exec, rps_thread.exec, comms_thread_tx.exec, comms_thread_rx.exec, sp_ctrl_thread.exec)

    if plc_state.init_ok then
        -- send status one last time after RPS shutdown
        smem_sys.plc_comms.send_status(plc_state.degraded)
        smem_sys.plc_comms.send_rps_status()

        -- close connection
        smem_sys.plc_comms.close(smem_sys.conn_watchdog)
    end
else
    -- run threads, excluding comms
    parallel.waitForAll(main_thread.exec, rps_thread.exec)
end

println_ts("exited")
log.info("exited")
