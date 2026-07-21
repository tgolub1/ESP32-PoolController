var LIGHTS_RELAY_INDEX = 1  # Zero-based: Power2
var current_lights_state = nil

var LIGHTSTATE = {
  "OFF_TW":     0,
  "OFF_MAN":    1,
  "ON_TW":      2,
  "ON_MAN":     3
}

# Determine if the active time window for pool lights operation is in effect
# .. returns true if now is within the lights ON Window, false otherwise
def get_active_lights_window()
  var rtc = tasmota.rtc("local")
  if ((rtc != nil) && (rtc !=0))
    var now = tasmota.time_dump(rtc)
    var current_minute = ((now['hour'] * 60) + now['min'])
    var ST7 = tasmota.cmd("Status 7", true)
    if (!ST7 || !ST7.contains("StatusTIM"))
      print("BR LIGHTS: ERROR - could not get ST7")
      return (nil)
    else
      var sunset_str = ST7["StatusTIM"]["Sunset"]  # e.g. 21:25
      var sunset_map = tasmota.strptime(sunset_str, "%H:%M")
      if (!sunset_map)
        print("BR LIGHTS: ERROR - Could not parse sunset_time")
        return (nil)
      else
        var sunset_minutes = ((sunset_map['hour'] * 60) + sunset_map['min']) - 9  # 10 minute negative offset
        if (sunset_minutes < 0)
          print("BR LIGHTS: ERROR Midnight Wraparround Calculation in Effect")
          sunset_minutes += 1440  # wrap around midnight
        end
        var end_window_time = (23 * 60) + 45  # 23:45
        if (sunset_minutes <= end_window_time)
          return ((current_minute >= sunset_minutes) && (current_minute < end_window_time))
        else  # wrap around case
          return ((current_minute >= sunset_minutes) || (current_minute <= end_window_time))
        end
      end
    end
  else  # rtc is not valid
    return (nil)
  end
end


def set_lights_power(onoff)
  # Read Power2 directly instead of relying on a shared cached value.
  var actual_lights_power = tasmota.get_power(LIGHTS_RELAY_INDEX)
  print("BR LIGHTS: requested power = " .. str(onoff) .. ", actual power = " .. str(actual_lights_power))

  if (actual_lights_power == onoff)
    print("BR LIGHTS: relay already matches requested state")
    return
  end

  if (onoff)
    print("BR LIGHTS: commanding Lights Relay ON")
  else
    print("BR LIGHTS: commanding LIghts Relay OFF")
  end

  tasmota.set_power(LIGHTS_RELAY_INDEX, onoff)
  print("BR LIGHTS: set_power = " .. str(onoff))
end


def set_lights_state(new_state)
  if (current_lights_state != new_state)
    print("BR LIGHTS: state " .. str(current_lights_state) .. " -> " .. str(new_state))
    current_lights_state = new_state
  else
    # no change
  end

  if ((new_state == LIGHTSTATE["OFF_TW"]) || (new_state == LIGHTSTATE["OFF_MAN"]))
    set_lights_power(false)
  elif ((new_state == LIGHTSTATE["ON_TW"]) || (new_state == LIGHTSTATE["ON_MAN"]))
    set_lights_power(true)
  else
    # no change
  end
end


# LIGHTS SCHEDULE EVALUATION
# ----------------------------------------------------------
def evaluate_lights_schedule()
  var active_lights_window = get_active_lights_window()  # Is the active lights window true or false
  var current_lights_status = tasmota.get_power(LIGHTS_RELAY_INDEX)  # Is the Lights Relay ON (true) or OFF (false)

  if (active_lights_window == nil)  # The clock is not valid yet
    return
  end

  if (current_lights_state == nil)
    if (!active_lights_window && !current_lights_status)
      # First time entry into a lights state machine post boot - outside of active window with lights OFF
      print("BR LIGHTS: Initial point of entry into Lights OFF window post boot with Lights OFF.  Keep the lights OFF.")
      set_lights_state(LIGHTSTATE["OFF_TW"])
    elif (active_lights_window && !current_lights_status)
      # First time entry into a lights state machine post boot - inside of active window with lights OFF
      print("BR LIGHTS: Initial point of entry into Lights ON window post boot with Lights OFF.  Turn the lights ON.")
      set_lights_state(LIGHTSTATE["ON_TW"])
    elif (!active_lights_window && current_lights_status)
      # First time entry into a lights state machine post boot - outside of active window with lights ON - keep ON and let pulsetime sort this out
      print("BR LIGHTS: Initial point of entry into Lights OFF window post boot with Lights ON.  Keep the lights ON.")
      set_lights_state(LIGHTSTATE["ON_MAN"])
    elif (active_lights_window && current_lights_status)
      # First time entry into a lights state machine post boot - inside of active window with lights ON
      print("BR LIGHTS: Initial point of entry into Lights ON window post boot with Lights ON.  Keep the lights ON.")
      set_lights_state(LIGHTSTATE["ON_TW"])
    end

  elif (current_lights_state == LIGHTSTATE["OFF_TW"])
    if (active_lights_window && current_lights_status)
      # Lights are ON and we have entered into an active window - Manual ON converstion to ON_TW
      set_lights_state(LIGHTSTATE["ON_TW"])
    elif (active_lights_window && !current_lights_status)
      # Lights are OFF and we have entered into an active window
      set_lights_state(LIGHTSTATE["ON_TW"])
    elif (!active_lights_window && current_lights_status)
      # Lights are ON but we are outside of an active window - Manual ON converstion to ON_MAN
      set_lights_state(LIGHTSTATE["ON_MAN"])
    elif (!active_lights_window && !current_lights_status)
      # Lights are OFF and we are outside of an active window - Remain in OFF_TW
      set_lights_state(LIGHTSTATE["OFF_TW"])
    end

  elif (current_lights_state == LIGHTSTATE["OFF_MAN"])
    if (active_lights_window && current_lights_status)
      # Lights are ON and we have entered into an active window - Manual ON converstion to ON_TW
      set_lights_state(LIGHTSTATE["ON_TW"])
    elif (active_lights_window && !current_lights_status)
      # Lights are OFF and we have entered into an active window - stay in OFF_MAN
      set_lights_state(LIGHTSTATE["OFF_MAN"])
    elif (!active_lights_window && current_lights_status)
      # Lights are ON but we are outside of an active window - Manual ON converstion to ON_MAN
      set_lights_state(LIGHTSTATE["ON_MAN"])
    elif (!active_lights_window && !current_lights_status)
      # Lights are OFF and we are outside of an active window - OFF_TW Conversion
      set_lights_state(LIGHTSTATE["OFF_TW"])
    end

  elif (current_lights_state == LIGHTSTATE["ON_TW"])
    if (active_lights_window && current_lights_status)
      # Lights are ON and we have entered into an active window - Remain in ON_TW
      set_lights_power(true)
    elif (active_lights_window && !current_lights_status)
      # Lights are OFF and we are in an active window - OFF_MAN conversion
      set_lights_state(LIGHTSTATE["OFF_MAN"])
    elif (!active_lights_window && current_lights_status)
      # Lights are ON but we are outside of an active window - Converstion to OFF_TW
      set_lights_state(LIGHTSTATE["OFF_TW"])
    elif (!active_lights_window && !current_lights_status)
      # Lights are OFF and we are outside of an active window - OFF_TW Conversion
      set_lights_state(LIGHTSTATE["OFF_TW"])
    end

  elif (current_lights_state == LIGHTSTATE["ON_MAN"])
    if (active_lights_window && current_lights_status)
      # Lights are ON and we have entered into an active window - Convert to ON_TW
      set_lights_state(LIGHTSTATE["ON_TW"])
    elif (active_lights_window && !current_lights_status)
      # Lights are OFF and we are in an active window - OFF_MAN conversion
      set_lights_state(LIGHTSTATE["OFF_MAN"])
    elif (!active_lights_window && current_lights_status)
      # Lights are ON but we are outside of an active window - Remain in ON_MAN
      set_lights_state(LIGHTSTATE["ON_MAN"])
    elif (!active_lights_window && !current_lights_status)
      # Lights are OFF and we are outside of an active window - OFF_TW Conversion
      set_lights_state(LIGHTSTATE["OFF_TW"])
    end
  end
end


def evaluate_lights_schedule_rule(value, trigger, data)
  evaluate_lights_schedule()
end


def evaluate_lights_schedule_cron(id)
  evaluate_lights_schedule()
end


# Exec on Actual Lights Power State Change
# Used to detect manual override on/off events
def lights_power_changed()
  print("BR LIGHTS: Lights Power State Change")
  evaluate_lights_schedule()
end


# CALLBACK REGISTRATION
# ----------------------------------------------------------
print("BR LIGHTS: registering callbacks")

# Check for schedule boundaries every minute at 45s mark.
tasmota.add_cron("30 * * * * *", evaluate_lights_schedule_cron, "lights_schedule")

# Evaluate immediately when Tasmota obtains valid time.
tasmota.add_rule("Time#Initialized", evaluate_lights_schedule_rule)

# Detect web UI, physical switch, MQTT, HTTP and console changes.
tasmota.add_rule("Power2#State", lights_power_changed)

# Initial evaluation when autoexec.be loads.
evaluate_lights_schedule()
