# Constants Definitions
var ON  = true
var OFF = false
var VALVE_RELAY_INDEX = 2                  # Zero-based: Power3
var PUMP_RELAY_INDEX = 0                   # Zero-based: Power1
var VALVE_MAXON_TIME = (90 * 60)           # 90-minute absolute safety timeout
var VALVE_INHIBIT_TIME = (6 * 60 * 60)     # Six-hour retry lockout
var VALVE_MANOFF_TIME = (4 * 60 * 60)      # Four-hour minimum MAN OFF
var PUMP_INHIBIT_TIME = (30 * 60)          # 30-minutes


# Script-Wide Variable Definitions
var PumpSM = nil                # pump state machine
var PumpWindowActive = nil      # Pump Time Window Active [nil, -1, 0 to n]
var PumpInhibitTimer = nil      # Pump Inhibut Timer
var PumpInhibitCounter = nil    # Number of times that the Pool Pump became inhibited since midnight
var ValveSM = nil               # water-valve state machine
var ValveTimeoutTimer = nil     # Timestamp when the valve operation should end
var ValveInhibitTimer = nil     # Timestamp when the valve refil lockout ends
var ValveOffTimer = nil         # Timestamp when the valve MAN OFF time should expire
var DailyValveOnCounter = nil   # Number of times that the Refill Valve has activated since midnight
var actual_pump_state = nil     # Actual state of the Pump Output
var actual_lights_state = nil   # Actual state of the Lights Output
var actual_valve_state = nil    # Actual state of the Valve Output
var actual_max_level = nil      # Actual state of the Max Tank Level Sensor - below threshold
var actual_min_level = nil      # Actual state of the Min Tank Level Sensor - below threshold
var actual_water_empty = nil    # Actual state of the Tank Empty Sensor - below threshold
var critical_low_level = nil    # Singlular handle to assess if the water level is critically low (empty)


var PUMPSTATE = {
  "OFF_TW":     0,    # Pump in Autonomous Mode      - OFF State
  "OFF_MAN":    1,    # Pump in Manual Overrive Mode - OFF State
  "ON_TW":      2,    # Pump in Autonomous Mode      -  ON State
  "ON_MAN":     3,    # Pump in Manual Override Mode -  ON State
  "ON_FILL":    4,    # Pump in Auto-ON Mode exclusively to assist w/ Tank ReFill Function
  "INHIBIT":    5,    # Pump in Operational Inhibit State (OFF) Awaiting The Inhibit Timer Expiry to Resume TW Operation
  "LOCKOUT":    6     # Pump in a Full Lockout Mode Due to Continuous Lockouts (to no effect) - brrestart required to reset
}

var VALVESTATE = {
  "OFF_AUT":     0,    # Valve in Autonomous Mode      - OFF State
  "OFF_MAN":     1,    # Valve in Manual Overrive Mode - OFF State
  "ON_AUT":      2,    # Valve in Autonomous Mode      -  ON State
  "ON_MAN":      3,    # Valve in Manual Override Mode -  ON State
  "INHIBIT":     4,    # Valve in Operational Inhibit State (OFF) Awaiting The Inhibit Timer Expiry to Resume AUTO Operation
  "LOCKOUT":     5     # Valve in a Full Lockout Mode Due to Continuous Overuse (to no effect) - brrestart required to reset
}

# NOTE - Windows must not cross the midnight mark - no built in overflow protection
var PumpTimeWindows = [
  [60, 180],        # [01 * 60][03 * 60] [01:00 – 03:00]
  [360, 660],       # [06 * 60][11 * 60] [06:00 – 11:00]
  [780, 900],       # [13 * 60][15 * 60] [13:00 – 15:00]
  [1020, 1320]      # [17 * 60][22 * 60] [17:00 – 22:00]
]


# Read actual IO states and populate global variables
def get_actual_io_states()
  # Read in real world information from sensors and realys
  var actual_relay_states = tasmota.get_power()
  var actual_snsr_states = tasmota.get_switches()

  actual_pump_state    = actual_relay_states[0]
  actual_lights_state  = actual_relay_states[1]
  actual_valve_state   = actual_relay_states[2]
  actual_max_level     = actual_snsr_states[1]
  actual_min_level     = actual_snsr_states[0]
  actual_water_empty   = actual_snsr_states[2]

  critical_low_level   = (actual_water_empty && actual_min_level && actual_max_level)
end


# Return a TXT version of the valve state enumertation
def valve_state_name(state)
  if (state == nil)
    return "UNINITIALIZED"
  elif (state == VALVESTATE["OFF_AUT"])
    return "OFF_AUT"
  elif (state == VALVESTATE["OFF_MAN"])
    return "OFF_MAN"
  elif (state == VALVESTATE["ON_AUT"])
    return "ON_AUT"
  elif (state == VALVESTATE["ON_MAN"])
    return "ON_MAN"
  elif (state == VALVESTATE["INHIBIT"])
    return "INHIBITED"
  elif (state == VALVESTATE["LOCKOUT"])
    return "ALARM: VALVE LOCKED OUT - brrestart to reset"
  else
    return "UNKNOWN"
  end
end

# Return a TXT version of the pump state enumertation
def pump_state_name(state)
  if (state == nil)
    return "UNINITIALIZED"
  elif (state == PUMPSTATE["OFF_TW"])
    return "OFF_TW"
  elif (state == PUMPSTATE["OFF_MAN"])
    return "OFF_MAN"
  elif (state == PUMPSTATE["ON_TW"])
    return "ON_TW"
  elif (state == PUMPSTATE["ON_MAN"])
    return "ON_MAN"
  elif (state == PUMPSTATE["ON_FILL"])
    return "ON_FILL"
  elif (state == PUMPSTATE["INHIBIT"])
    return "INHIBITED"
  elif (state == PUMPSTATE["LOCKOUT"])
    return "ALARM: PUMP LOCKED OUT - brrestart to reset"
  else
    return "UNKNOWN"
  end
end


# Change the logical valve state and consistently maintain timers/logging.
def set_valve_SM(newState)
  if (ValveSM == newState)
    # The new Valve SM state matches the existing one - ignore the request
    # print("BR VALVE: Current State = " .. valve_state_name(ValveSM))
  else
    # Set the Valve SM state to the new value
    print("BR VALVE: Valve SM state " .. valve_state_name(ValveSM) .. " -> " .. valve_state_name(newState))
    if (newState == VALVESTATE["ON_AUT"])
      if (DailyValveOnCounter == nil)
        DailyValveOnCounter = 1
      else
        DailyValveOnCounter += 1
      end
    end
    ValveSM = newState
  end
end


# Set Tasmota water-valve relay output.
# .. onoff is [true | false]
def set_valve_power(onoff)
  if (onoff == nil)  # skip nil values entirely
    return
  elif (actual_valve_state == onoff)
    # Current Valve Output Power already matches the desired - no op
    return
  else
    # Set Tasmota Power3 - Valve Relay Output to [true | false]
    print("BR VALVE: Valve power change from " .. str(actual_valve_state) .. " to " .. str(onoff))
    tasmota.set_power(VALVE_RELAY_INDEX, onoff)
  end
end


# Read in the current minute since midnight
def get_current_minute()
  var timestamp = tasmota.rtc()["local"]
  if ((timestamp == nil) || (timestamp == 0))
    # Time not yet available post boot
    return (nil)
  else
    # Time is ready for consumption
    var now = tasmota.time_dump(timestamp)
    return ((now["hour"] * 60) + now["min"])  # Return the current minute since midnight
  end
end


# Determine if the current time falls in one of the defined pump run windows
#   0 to 3 available time window index
#     -1   Outside of all active windows
#   NOTE - windows must not cross the midnight mark - no built in protection
def get_active_pump_time_window()
  var minute = get_current_minute()
  if (minute == nil)
    PumpWindowActive = nil
    return (PumpWindowActive)
  end

  var i = 0
  while (i < size(PumpTimeWindows))
    var start_minute = PumpTimeWindows[i][0]
    var end_minute   = PumpTimeWindows[i][1]

    if (minute >= start_minute) && (minute < end_minute)
      PumpWindowActive = i
      return (PumpWindowActive)  # Current time is within a specific run window
    end

    i += 1
  end

  PumpWindowActive = -1
  return (PumpWindowActive)  # Current time is outside all defined pump run windows
end


# ------------------------------ Main Loop for Valve Control Logic -----------------------------------
def evaluate_valve_state()

  # print("BR VALVE: Valve SM = " .. valve_state_name(ValveSM))

  var nVSM = nil   # next Pump State Machine State
  var nVPow = nil  # next Pump Power State

  if (critical_low_level && (ValveSM != VALVESTATE["LOCKOUT"]) && (ValveSM != VALVESTATE["INHIBIT"]) && (ValveSM != VALVESTATE["ON_AUT"]))
    if ((DailyValveOnCounter != nil) && (DailyValveOnCounter >= 3))
      # Do not allow the critical-low path to bypass the daily refill limit
      print("BR VALVE: ALARM - Pool water is critically low, but the daily refill limit has been reached. Moving valve to LOCKOUT.")
      ValveTimeoutTimer = nil
      ValveInhibitTimer = nil
      ValveOffTimer = nil
      set_valve_SM(VALVESTATE["LOCKOUT"])
      set_valve_power(OFF)
      return
    end
    # Daily refill limit has not been reached
    print("BR VALVE: ALARM - Pool water level critically low. Opening the refill valve.")
    # Preserve an existing valid ON timer; otherwise start a new safety timer
    if (!actual_valve_state || (ValveTimeoutTimer == nil))
      ValveTimeoutTimer = tasmota.millis(VALVE_MAXON_TIME * 1000)
    end
    # A critical-low refill overrides and cancels any manual-OFF hold
    ValveOffTimer = nil
    ValveInhibitTimer = nil
    set_valve_SM(VALVESTATE["ON_AUT"])
    set_valve_power(ON)
    return
  end

  if (ValveSM == VALVESTATE["LOCKOUT"])  # valve lockout active
    # no questions asked - brrestart is the only way out
    ValveTimeoutTimer = nil
    set_valve_SM(VALVESTATE["LOCKOUT"])
    set_valve_power(OFF)
    return

  elif (ValveSM == VALVESTATE["INHIBIT"])
    if (ValveInhibitTimer == nil)
      # INHIBIT cannot recover predictably without a valid timer
      print("BR VALVE: ERROR - Valve INHIBIT has no timer. Moving valve to LOCKOUT.")
      ValveTimeoutTimer = nil
      ValveOffTimer = nil
      ValveInhibitTimer = nil
      set_valve_SM(VALVESTATE["LOCKOUT"])
      set_valve_power(OFF)
    elif (tasmota.time_reached(ValveInhibitTimer))
      # The complete inhibit period has elapsed
      ValveInhibitTimer = nil
      ValveTimeoutTimer = nil
      ValveOffTimer = nil
      if (critical_low_level || actual_min_level)
        # Water remains below the automatic refill threshold
        if ((DailyValveOnCounter == nil) || (DailyValveOnCounter < 3))
          print("BR VALVE: Valve inhibit period ended and water level remains low. Resuming automatic refill.")
          ValveTimeoutTimer = tasmota.millis(VALVE_MAXON_TIME * 1000)
          set_valve_SM(VALVESTATE["ON_AUT"])
          set_valve_power(ON)
        else
          print("BR VALVE: ALARM - Valve inhibit period ended, but the daily refill limit has been reached. Moving valve to LOCKOUT.")
          set_valve_SM(VALVESTATE["LOCKOUT"])
          set_valve_power(OFF)
        end
      else
        # Water is no longer low; return to normal automatic OFF
        set_valve_SM(VALVESTATE["OFF_AUT"])
        set_valve_power(OFF)
      end
    else
      # Inhibit timer is valid and still counting
      ValveTimeoutTimer = nil
      ValveOffTimer = nil
      set_valve_SM(VALVESTATE["INHIBIT"])
      set_valve_power(OFF)
    end

  elif (((ValveSM == VALVESTATE["ON_AUT"]) || (ValveSM == VALVESTATE["ON_MAN"])) && !actual_valve_state)  # manual override
    # manual valve OFF override
    print("BR VALVE: Manual Valve OFF Override Detected.  Switching the Refil Valve OFF.")
    ValveTimeoutTimer = nil
    ValveOffTimer = tasmota.millis(VALVE_MANOFF_TIME * 1000)  # set the manual valve off time limit
    set_valve_SM(VALVESTATE["OFF_MAN"])
    set_valve_power(OFF)

  elif (((ValveSM == VALVESTATE["OFF_AUT"]) || (ValveSM == VALVESTATE["OFF_MAN"])) && actual_valve_state)  # manual override
    # manual valve ON override
    print("BR VALVE: Manual Valve ON Override Detected.  Switching the Refill Valve ON.")
    ValveTimeoutTimer = tasmota.millis(VALVE_MAXON_TIME * 1000)  # set the valve fill time
    set_valve_SM(VALVESTATE["ON_MAN"])
    set_valve_power(ON)

  elif ((ValveSM == VALVESTATE["ON_MAN"]) && actual_valve_state)
    if (ValveTimeoutTimer == nil)
      print("BR VALVE: ERROR - ON_MAN has no safety timer. Inhibiting valve.")
      ValveInhibitTimer = tasmota.millis(VALVE_INHIBIT_TIME * 1000)
      set_valve_SM(VALVESTATE["INHIBIT"])
      set_valve_power(OFF)
    elif (tasmota.time_reached(ValveTimeoutTimer))
      ValveTimeoutTimer = nil
      ValveInhibitTimer = tasmota.millis(VALVE_INHIBIT_TIME * 1000)
      set_valve_SM(VALVESTATE["INHIBIT"])
      set_valve_power(OFF)
    else
      set_valve_SM(VALVESTATE["ON_MAN"])
      set_valve_power(ON)
    end

  elif ((ValveSM == VALVESTATE["OFF_MAN"]) && !actual_valve_state)
    if ((ValveOffTimer != nil) && tasmota.time_reached(ValveOffTimer))
      # The manual-OFF period has expired
      ValveOffTimer = nil
      if (actual_min_level)
        # Water is below the minimum-level threshold
        if ((DailyValveOnCounter == nil) || (DailyValveOnCounter < 3))
          print("BR VALVE: Manual OFF period ended and water level is low. Resuming automatic refill.")
          ValveInhibitTimer = nil
          ValveTimeoutTimer = tasmota.millis(VALVE_MAXON_TIME * 1000)
          set_valve_SM(VALVESTATE["ON_AUT"])
          set_valve_power(ON)
        else
          # Do not allow OFF_MAN expiration to bypass the daily refill limit
          print("BR VALVE: ALARM - Manual OFF period ended, but the daily refill limit has been reached. Moving valve to LOCKOUT.")
          ValveTimeoutTimer = nil
          ValveInhibitTimer = nil
          set_valve_SM(VALVESTATE["LOCKOUT"])
          set_valve_power(OFF)
        end
      else
        # Water is above the minimum-level threshold; return to automatic OFF
        ValveTimeoutTimer = nil
        ValveInhibitTimer = nil
        set_valve_SM(VALVESTATE["OFF_AUT"])
        set_valve_power(OFF)
      end
    else
      # OFF timer is still running, or is missing; fail safely with valve OFF
      set_valve_SM(VALVESTATE["OFF_MAN"])
      set_valve_power(OFF)
    end

  elif (ValveSM == VALVESTATE["ON_AUT"] && actual_valve_state)
    if ((ValveTimeoutTimer != nil) && (tasmota.time_reached(ValveTimeoutTimer)))
      ValveTimeoutTimer = nil
      ValveOffTimer = nil
      ValveInhibitTimer = tasmota.millis(VALVE_INHIBIT_TIME * 1000)  # set the valve inhibit time
      set_valve_SM(VALVESTATE["INHIBIT"])
      set_valve_power(OFF)
    elif (ValveTimeoutTimer == nil)
      print("BR VALVE: ERROR - ON_AUT has no safety timer. Inhibiting valve.")
      ValveInhibitTimer = tasmota.millis(VALVE_INHIBIT_TIME * 1000)
      set_valve_SM(VALVESTATE["INHIBIT"])
      set_valve_power(OFF)
    else
      set_valve_SM(VALVESTATE["ON_AUT"])
      set_valve_power(ON)
    end

  elif (ValveSM == VALVESTATE["OFF_AUT"] && !actual_valve_state)
    if (actual_min_level && ((DailyValveOnCounter == nil) || (DailyValveOnCounter < 3)))
      # tank water level has dipped below fill threshold but the tank is not empty
      ValveTimeoutTimer = tasmota.millis(VALVE_MAXON_TIME * 1000)  # set the valve fill time
      set_valve_SM(VALVESTATE["ON_AUT"])
      set_valve_power(ON)
    elif (actual_min_level && (DailyValveOnCounter >= 3))
      print("BR VALVE: ALERT - 3rd daily refill valve activation attempt.  Valve moving to a LOCKOUT state.  Power cycle or restart required.")
      ValveTimeoutTimer = nil
      set_valve_SM(VALVESTATE["LOCKOUT"])
      set_valve_power(OFF)
    elif (!actual_min_level)  # tank water level is above fill threshold
      ValveTimeoutTimer = nil
      set_valve_SM(VALVESTATE["OFF_AUT"])
      set_valve_power(OFF)
    else
      # Remain in OFF_AUT
      ValveTimeoutTimer = nil
      set_valve_SM(VALVESTATE["OFF_AUT"])
      set_valve_power(OFF)
    end

  else  # Valve SM == nil or other
    # .. w/o exceptions or overrides - return to prior known state
    if (ValveSM == nil)
      print("BR VALVE: ERROR - Valve SM State is nil. Skipping this procssing loop.")
    end

    ValveInhibitTimer = nil
    ValveTimeoutTimer = nil
    ValveOffTimer = nil
    set_valve_SM(VALVESTATE["OFF_AUT"])
    set_valve_power(OFF)
  end
end


# Set Tasmota Pool Pump Power State
#  ..onoff must be [ true | false ]
def set_pump_power(onoff)
  if (onoff == nil)  # skip nil values entirely
    return
  elif (actual_pump_state == onoff)
    # The actual pump state already matches the new desired state - no op
    return
  else
    # Set tasmota Power0 - Pump Relay Output to [true | false]
    tasmota.set_power(PUMP_RELAY_INDEX, onoff)
  end
end


# Set the Pump State Machine - PumpSM to the new value
def set_pump_SM(newState)
  if (PumpSM == newState)
    # The new Pump SM State matches the existing one - no op
    return
  else
    # Set the Pump SM State to the new value
    if (newState == PUMPSTATE["INHIBIT"])
      if (PumpInhibitCounter == nil)
        PumpInhibitCounter = 1
      else
        PumpInhibitCounter += 1
      end
    end
    PumpSM = newState
  end
end


# ------------------------------------- Main Loop for Pump Control Logic ------------------------------------------
def evaluate_pump_state()
  # print("BR PUMP&V: Pump TW = " .. PumpWindowActive)
  var nextPSM = nil   # next Pump State Machine State
  var nextPPow = nil  # next Pump Power State

  if (critical_low_level && (PumpSM != PUMPSTATE["LOCKOUT"]) && (PumpSM != PUMPSTATE["INHIBIT"]))
    # Tank is critically empty. Stop the pump regardless of whether it was
    # running for its schedule, manually, or to assist automatic filling.
    if ((PumpInhibitCounter == nil) || (PumpInhibitCounter < 3))
      print("BR PUMP&V: ALARM - Pool Water Level Critically Low. Stopping pump and entering INHIBIT.")
      PumpInhibitTimer = tasmota.millis(PUMP_INHIBIT_TIME * 1000)
      set_pump_SM(PUMPSTATE["INHIBIT"])
      set_pump_power(OFF)
    else
      print("BR PUMP&V: ALARM - Pool Water Level Critically Low after repeated inhibits. Moving pump to LOCKOUT.")
      PumpInhibitTimer = nil
      set_pump_SM(PUMPSTATE["LOCKOUT"])
      set_pump_power(OFF)
    end
    return
  end

  if (PumpSM == PUMPSTATE["LOCKOUT"])  # pump lockout active
    # no questions asked - brrestart is the only way out
    nextPSM = PUMPSTATE["LOCKOUT"]
    nextPPow = OFF

  elif (PumpSM == PUMPSTATE["INHIBIT"])
    if (PumpInhibitTimer == nil)
      # An inhibited pump without a valid timer cannot recover predictably
      print("BR PUMP&V: ERROR - Pump INHIBIT has no timer. Moving pump to LOCKOUT.")
      nextPSM = PUMPSTATE["LOCKOUT"]
      nextPPow = OFF
    elif (tasmota.time_reached(PumpInhibitTimer))
      # The full inhibit period has elapsed
      PumpInhibitTimer = nil
      if (critical_low_level)
        # Water is still critically low after the complete inhibit period
        print("BR PUMP&V: ALARM - Tank remains critically empty after pump inhibit. Moving pump to LOCKOUT.")
        nextPSM = PUMPSTATE["LOCKOUT"]
        nextPPow = OFF
      elif ((PumpInhibitCounter != nil) && (PumpInhibitCounter >= 3))
        # Enforce the daily inhibit limit independently of valve or schedule
        print("BR PUMP&V: ALARM - Pump inhibit limit reached. Moving pump to LOCKOUT.")
        nextPSM = PUMPSTATE["LOCKOUT"]
        nextPPow = OFF
      elif (ValveSM == VALVESTATE["ON_AUT"])
        # Water is no longer critically low and automatic filling continues
        nextPSM = PUMPSTATE["ON_FILL"]
        nextPPow = ON
      elif (PumpWindowActive == nil)
        # Time is unavailable; leave INHIBIT safely without starting the pump
        print("BR PUMP&V: Pump inhibit ended, but current time is invalid. Moving to OFF_TW.")
        nextPSM = PUMPSTATE["OFF_TW"]
        nextPPow = OFF
      elif (PumpWindowActive >= 0)
        # Resume scheduled operation
        nextPSM = PUMPSTATE["ON_TW"]
        nextPPow = ON
      else
        # No refill and outside all scheduled windows
        nextPSM = PUMPSTATE["OFF_TW"]
        nextPPow = OFF
      end
    else
      # Inhibit timer is valid and still counting
      nextPSM = PUMPSTATE["INHIBIT"]
      nextPPow = OFF
    end

  # Detect manual OFF before processing ON_FILL.
  elif (((PumpSM == PUMPSTATE["ON_TW"]) || (PumpSM == PUMPSTATE["ON_MAN"]) || (PumpSM == PUMPSTATE["ON_FILL"])) && !actual_pump_state)
    print("BR PUMP&V: Manual Pump OFF Override Detected.")
    nextPSM = PUMPSTATE["OFF_MAN"]
    nextPPow = OFF

  elif (PumpSM == PUMPSTATE["ON_FILL"])
    if (ValveSM == VALVESTATE["ON_AUT"])
      # Automatic filling is still active
      nextPSM = PUMPSTATE["ON_FILL"]
      nextPPow = ON
    else
      # Automatic filling has ended; return to schedule control
      if (PumpWindowActive == nil)
        print("BR PUMP&V: ERROR - Time invalid inside of active ON_FILL state")
        nextPSM = PumpSM
        nextPPow = nil
      elif (PumpWindowActive >= 0)
        nextPSM = PUMPSTATE["ON_TW"]
        nextPPow = ON
      else
        nextPSM = PUMPSTATE["OFF_TW"]
        nextPPow = OFF
      end
    end

  elif (((PumpSM == PUMPSTATE["OFF_TW"]) || (PumpSM == PUMPSTATE["OFF_MAN"])) && actual_pump_state)
    # Manual pump ON override
    print("BR PUMP&V: Manual Pump ON Override Detected.")
    nextPSM = PUMPSTATE["ON_MAN"]
    nextPPow = ON

  elif ((PumpSM == PUMPSTATE["ON_MAN"]) && actual_pump_state)
    if (PumpWindowActive == nil)
      print("BR PUMP&V: ERROR - Time invalid inside of active ON_MAN state")
      nextPSM = PumpSM
      nextPPow = nil
    elif (PumpWindowActive >= 0)
      # Scheduled window has started; release manual ON override
      nextPSM = PUMPSTATE["ON_TW"]
      nextPPow = ON
    else
      # Continue manual ON outside scheduled windows
      nextPSM = PUMPSTATE["ON_MAN"]
      nextPPow = ON
    end

  elif ((PumpSM == PUMPSTATE["OFF_MAN"]) && !actual_pump_state)
    if (ValveSM == VALVESTATE["ON_AUT"])
      # Manual OFF overrides ON_FILL for the remainder of this refill
      nextPSM = PUMPSTATE["OFF_MAN"]
      nextPPow = OFF
    elif (PumpWindowActive == nil)
      # Time is unavailable; retain the safe manual-OFF state
      print("BR PUMP&V: ERROR - Time invalid inside of active OFF_MAN state")
      nextPSM = PUMPSTATE["OFF_MAN"]
      nextPPow = OFF
    elif (PumpWindowActive >= 0)
      # Continue manual OFF until the active window ends
      nextPSM = PUMPSTATE["OFF_MAN"]
      nextPPow = OFF
    else
      # Refill and scheduled window have both ended
      nextPSM = PUMPSTATE["OFF_TW"]
      nextPPow = OFF
    end

  elif (PumpSM == PUMPSTATE["ON_TW"])
    if (ValveSM == VALVESTATE["ON_AUT"])
      # Automatic refill started while pump was already running
      nextPSM = PUMPSTATE["ON_FILL"]
      nextPPow = ON
    elif (PumpWindowActive == nil)
      # Time is not yet valid; preserve current pump state
      print("BR PUMP&V: ERROR - Time invalid inside of active ON_TW state")
      nextPSM = PumpSM
      nextPPow = nil
    elif (PumpWindowActive >= 0)
      # Remain in the active pump time window
      nextPSM = PUMPSTATE["ON_TW"]
      nextPPow = ON
    else
      # Pump window has ended
      nextPSM = PUMPSTATE["OFF_TW"]
      nextPPow = OFF
    end

  elif (PumpSM == PUMPSTATE["OFF_TW"])
    if (ValveSM == VALVESTATE["ON_AUT"])
      # Automatic refill requires the pump outside its normal schedule
      nextPSM = PUMPSTATE["ON_FILL"]
      nextPPow = ON
    elif (PumpWindowActive == nil)
      # Time is not yet valid; preserve current pump state
      print("BR PUMP&V: ERROR - Time invalid inside of active OFF_TW state")
      nextPSM = PumpSM
      nextPPow = nil
    elif (PumpWindowActive >= 0)
      nextPSM = PUMPSTATE["ON_TW"]
      nextPPow = ON
    else
      nextPSM = PUMPSTATE["OFF_TW"]
      nextPPow = OFF
    end

  else  # (PumpSM == nil) or any other invalid setting
    # .. w/o exceptions or overrides - return to prior known state
    if (PumpSM == nil)
      print("BR PUMP&V: ERROR - PumpSM is nil. Skipping this procssing loop.")
    end

    if (PumpWindowActive == nil)
      print("BR PUMP&V: INIT PASS - Current Time Still Invalid.")
      nextPSM = PumpSM
      nextPPow = nil
    elif (PumpWindowActive >= 0)
      print("BR PUMP&V: INIT PASS - We are within an Active Window - Move to ON_TW")
      nextPSM = PUMPSTATE["ON_TW"]
      nextPPow = ON
    else
      print("BR PUMP&V: INIT PASS - We are outside of all Active Windows - Move to OFF_TW")
      nextPSM = PUMPSTATE["OFF_TW"]
      nextPPow = OFF
    end

  end

  if (nextPSM != PumpSM)  # State Transistion
    if ((nextPSM == PUMPSTATE["ON_TW"]) && (PumpWindowActive >= 0))
      print("BR PUMP&V: Pump SM = " .. pump_state_name(PumpSM) .. " --> " .. pump_state_name(nextPSM) .. "  [OFF @ "
      .. tasmota.strftime("%H:%M", PumpTimeWindows[PumpWindowActive][1] * 60) .. "]")
    else
       print("BR PUMP&V: Pump SM = " .. pump_state_name(PumpSM) .. " --> " .. pump_state_name(nextPSM))
    end
  else
    # print("BR PUMP&V: PUMP Current State = " .. pump_state_name(PumpSM))
  end

  set_pump_SM(nextPSM)
  set_pump_power(nextPPow)
end

# -------------------------- Master Main Loop Orchesrator -------------------------------
def evaluate_states()
  get_actual_io_states()        # Evaluate & Record the actual Tasmota IO Relays and Switches
  get_active_pump_time_window() # Evaluate if the pump TW is active in this moment
  evaluate_valve_state()        # Process the Valve Main Control Loop
  evaluate_pump_state()         # Process the Pump Main Control Loop
end

# -------------------- Callback Reaction Functions --------------------

# Exec on NTP time change
def time_corrected()
  print("BR PUMP&V: NTP Time Correction Event")
  evaluate_states()
end

# Exec on Actual Pump Power State Change
def pump_power_changed()
  print("BR PUMP&V: Pump Power State Change")
  evaluate_states()
end

# Exec on Switch1 & Switch3 State Change - water tank empty
def tank_empty_changed()
  print("BR PUMP&V: Water Tank Low or Empty Sensor State Change Event")
  evaluate_states()
end

# Exec at Time Initialization - one time at startup presumed
# ..but could fire any time ESP32 loses NTP and re-acquires it
def evaluate_pump_schedule_rule(value, trigger, data)
  print("BR PUMP&V: NTP Time Initialization Event")
  evaluate_states()
end

# Exec based on crontab callback - one per minute
def evaluate_pump_schedule_cron()
  evaluate_states()
end

# Exec on Power3#State Change - Valve Power ON Event
def pump_fill_valve_changed(value, trigger, data)
  print("BR PUMP&V: Fill Valve Power State Change")
  evaluate_states()
end

# Execute on maximum-level sensor state change.
def tank_max_level_changed(value, trigger, data)
  print("BR PUMP&V: maximum-level sensor state-change event")
  evaluate_states()
end

# Reset the Daily Valve Activation Counter
def midnight_callback()
  DailyValveOnCounter = 0
  PumpInhibitCounter = 0
end


# ------------------------  CALLBACK REGISTRATION  ------------------------

print("BR PUMP&V: registering callbacks")

# Detect web UI, physical switch, MQTT, HTTP and console changes.
tasmota.add_rule("Power1#State", pump_power_changed)

# Detect Valve Power ON Events
tasmota.add_rule("Power3#State", pump_fill_valve_changed)

# Detect Empty Tank Sensor Event Changes
tasmota.add_rule("Switch3#State", tank_empty_changed)

# Detect MAX Tank Sensor Changes
tasmota.add_rule("Switch2#State", tank_max_level_changed)

# Detect Low Tank Sensor Event Changes
tasmota.add_rule("Switch1#State", tank_empty_changed)

# Detect NTP Time Set Events
tasmota.add_rule("Time#Set", time_corrected)

# Evaluate immediately when Tasmota obtains valid time.
tasmota.add_rule("Time#Initialized", evaluate_pump_schedule_rule)

# Check for schedule boundaries every minute at 0s mark.
tasmota.add_cron("0 * * * * *", evaluate_pump_schedule_cron, "pump_schedule")

# Reset the Daily Valve Activation Counter at 5 past midnight every day
tasmota.add_cron("45 4 0 * * *", midnight_callback, "midnight_0005")

# Establish state immediately at script load instead of waiting for the first sensor, power, time, or cron event.
print("BR PUMP&V: initial post reset main loop run")
evaluate_states()

# ----------------------------------------------------------------------------
