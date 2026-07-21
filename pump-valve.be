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
var ValveSM = nil               # water-valve state machine
var ValveTimeoutTimer = nil     # Timestamp when the valve operation should end
var ValveInhibitTimer = nil     # Timestamp when the valve refil lockout ends
var ValveOffTimer = nil         # Timestamp when the valve MAN OFF time should expire
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
    return
  else
    # Set the Valve SM state to the new value
    print("BR VALVE: Valve SM state " .. valve_state_name(ValveSM) .. " -> " .. valve_state_name(newState))
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
  var timestamp = tasmota.rtc("local")
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
  var nVSM = nil   # next Pump State Machine State
  var nVPow = nil  # next Pump Power State

  if (critical_low_level && (ValveSM != VALVESTATE["LOCKOUT"]) && (ValveSM != VALVESTATE["INHIBIT"]) && (ValveSM != VALVESTATE["ON_AUT"]))
    # we are currently not inhibited but the pool tank is empty
    print("BR VALVE: ALARM - Pool Water Level Critically Low - Level Tank is Empty. Opening the Refill Valve.")
    if (!actual_valve_state || (ValveTimeoutTimer == nil))
      ValveTimeoutTimer = tasmota.millis(VALVE_MAXON_TIME * 1000)  # set the valve fill time
    end
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

  elif (ValveSM == VALVESTATE["INHIBIT"])  # valve inhibit active
    if ((ValveInhibitTimer != nil) && tasmota.time_reached(ValveInhibitTimer))
      # inhibit timer has expired, lockout not in effect
      ValveInhibitTimer = nil
      if (critical_low_level || actual_min_level)  # water level is low - re-activate refill valve
        print("BR VALVE: Valve Inhibit Period Has Ended.  Pool Water Level is still low.  Turning the Refill Valve ON.")
        ValveTimeoutTimer = tasmota.millis(VALVE_MAXON_TIME * 1000)  # set the valve fill time
        set_valve_SM(VALVESTATE["ON_AUT"])
        set_valve_power(ON)
      else  # Water Level is not low
        ValveTimeoutTimer = nil
        set_valve_SM(VALVESTATE["OFF_AUT"])
        set_valve_power(OFF)
      end
    else  # inhibit timer is still counting - enforce inhibit
      ValveTimeoutTimer = nil
      set_valve_SM(VALVESTATE["INHIBIT"])
      set_valve_power(OFF)
      return
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
    # remain in ON_MAN for the duration of the Valve ON Time
    if ((ValveTimeoutTimer != nil) && tasmota.time_reached(ValveTimeoutTimer))
      ValveTimeoutTimer = nil
      ValveInhibitTimer = tasmota.millis(VALVE_INHIBIT_TIME * 1000)
      set_valve_SM(VALVESTATE["INHIBIT"])
      set_valve_power(OFF)
    else  # Valve On Timer still counting
      # remain in Valve State ON_MAN
      set_valve_SM(VALVESTATE["ON_MAN"])
      set_valve_power(ON)
    end

  elif ((ValveSM == VALVESTATE["OFF_MAN"]) && !actual_valve_state)
    if ((ValveOffTimer != nil) && tasmota.time_reached(ValveOffTimer))  # remain in the OFF_MAN until the critical or low water is detected or OFF time is reached
      ValveOffTimer = nil
      if (actual_min_level)  # tank water level has dipped below fill threshold but the tank is not empty
        ValveTimeoutTimer = tasmota.millis(VALVE_MAXON_TIME * 1000)  # set the valve fill time
        set_valve_SM(VALVESTATE["ON_AUT"])
        set_valve_power(ON)
      else  # tank water level is above fill threshold
        ValveTimeoutTimer = nil
        set_valve_SM(VALVESTATE["OFF_AUT"])
        set_valve_power(OFF)
      end
    else  # ValveOffTimer is still running - enforce manual valve OFF time
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
    if (actual_min_level)  # tank water level has dipped below fill threshold but the tank is not empty
      ValveTimeoutTimer = tasmota.millis(VALVE_MAXON_TIME * 1000)  # set the valve fill time
      set_valve_SM(VALVESTATE["ON_AUT"])
      set_valve_power(ON)
    else  # tank water level is above fill threshold
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
    print("BR PUMP&V: Pump SM state " .. pump_state_name(PumpSM) .. " -> " .. pump_state_name(newState))
    PumpSM = newState
  end
end


# ------------------------------------- Main Loop for Pump Control Logic ------------------------------------------
def evaluate_pump_state()

  var nextPSM = nil   # next Pump State Machine State
  var nextPPow = nil  # next Pump Power State

  if (PumpSM == PUMPSTATE["LOCKOUT"])  # pump lockout active
    # no questions asked - brrestart is the only way out
    set_pump_SM(PUMPSTATE["LOCKOUT"])
    set_pump_power(OFF)
    return

  elif (PumpSM == PUMPSTATE["INHIBIT"])  # pump inhibit active
    if ((PumpInhibitTimer != nil) && tasmota.time_reached(PumpInhibitTimer))
      # inhibit timer has expired, lockout not in effect
      if (critical_low_level)
        PumpInhibitTimer = tasmota.millis(PUMP_INHIBIT_TIME * 1000)
        nextPSM = PUMPSTATE["INHIBIT"]
        nextPPow = OFF
      elif (ValveSM == VALVESTATE["ON_AUT"])
        PumpInhibitTimer = nil
        nextPSM = PUMPSTATE["ON_FILL"]
        nextPPow = ON
      else
        PumpInhibitTimer = nil
        if (PumpWindowActive == nil)  # Time is not yet active - make no changes
          print("BR PUMP&V: ERROR - Time invalid inside of active INHIBIT state")
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
    else
      # inhibit timer is still counting
      set_pump_SM(PUMPSTATE["INHIBIT"])
      set_pump_power(OFF)
      return
    end

  elif (critical_low_level)  # pool empty and we are not in a LOCKOUT or INHIBIT
    # we are currently not inhibited but the pool tank is empty - move to INHIBIT
    print("BR PUMP&V: ALARM - Pool Water Level Critically Low - Level Tank is Empty. Moving to Pump Inhibit State and Opening the Valve.")
    PumpInhibitTimer = tasmota.millis(PUMP_INHIBIT_TIME * 1000)  # set the inhibit time to 30-min timer
    nextPSM = PUMPSTATE["INHIBIT"]
    nextPPow = OFF

  elif (PumpSM == PUMPSTATE["ON_FILL"])
    if (ValveSM == VALVESTATE["ON_AUT"])  # the valve is still on - continue to run the pump
      nextPSM = PUMPSTATE["ON_FILL"]
      nextPPow = ON
    else  # The valve is no longer auto-filling the pool
      if (PumpWindowActive == nil)  # Time is not yet active - make no changes
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

  elif (((PumpSM == PUMPSTATE["ON_TW"]) || (PumpSM == PUMPSTATE["ON_MAN"]) || (PumpSM == PUMPSTATE["ON_FILL"])) && !actual_pump_state)  # manual override
    # manual pump OFF override
    nextPSM = PUMPSTATE["OFF_MAN"]
    nextPPow = OFF

  elif (((PumpSM == PUMPSTATE["OFF_TW"]) || (PumpSM == PUMPSTATE["OFF_MAN"])) && actual_pump_state)  # manual override
    # manual pump ON override
    nextPSM = PUMPSTATE["ON_MAN"]
    nextPPow = ON

  elif ((PumpSM == PUMPSTATE["ON_MAN"]) && actual_pump_state)
    if (PumpWindowActive == nil)  # Time is not yet active - make no changes
      print("BR PUMP&V: ERROR - Time invalid inside of active ON_MAN state")
      nextPSM = PumpSM
      nextPPow = nil
    elif (PumpWindowActive >= 0)  # ON_TW window is now active
      nextPSM = PUMPSTATE["ON_TW"]
      nextPPow = ON
    else  # we remain outside of all active windows - hold the Pump ON for the duration of the manual override
      nextPSM = PUMPSTATE["ON_MAN"]
      nextPPow = ON
    end

  elif ((PumpSM == PUMPSTATE["OFF_MAN"]) && !actual_pump_state)
    if (PumpWindowActive == nil)  # Time is not yet active - make no changes
      print("BR PUMP&V: ERROR - Time invalid inside of active OFF_MAN state")
      nextPSM = PumpSM
      nextPPow = nil
    elif (PumpWindowActive >= 0)  # ON_TW window is still active - hold the Pump OFF for the duration of the manual override
      nextPSM = PUMPSTATE["OFF_MAN"]
      nextPPow = OFF
    else  # we are now outside of all active windows - release the manual OFF hold
      nextPSM = PUMPSTATE["OFF_TW"]
      nextPPow = OFF
    end

  elif (PumpSM == PUMPSTATE["ON_TW"])
    if (PumpWindowActive == nil)  # Time is not yet active - make no changes
      print("BR PUMP&V: ERROR - Time invalid inside of active ON_TW state")
      nextPSM = PumpSM
      nextPPow = nil
    elif (PumpWindowActive >=0)  # stay in ON_TW since there are no other priorities
      nextPSM = PUMPSTATE["ON_TW"]
      nextPPow = ON
    else
      nextPSM = PUMPSTATE["OFF_TW"]
      nextPPow = OFF
    end

  elif (PumpSM == PUMPSTATE["OFF_TW"])
    if (PumpWindowActive == nil)  # Time is not yet active - make no changes
      print("BR PUMP&V: ERROR - Time invalid inside of active OFF_TW state")
      nextPSM = PumpSM
      nextPPow = nil
    elif (PumpWindowActive >=0)
      nextPSM = PUMPSTATE["ON_TW"]
      nextPPow = ON
    else  # stay in OFF_TW since there are no other priorities
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
    print("BR PUMP&V: Pump current SM = " .. str(PumpSM) .. " (" .. pump_state_name(PumpSM) .. ")" ..
    ", new SM = " .. str(nextPSM) .. " (" .. pump_state_name(nextPSM) .. ")")
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

# Establish state immediately at script load instead of waiting for the first sensor, power, time, or cron event.
print("BR PUMP&V: initial post reset main loop run")
evaluate_states()

# ----------------------------------------------------------------------------
