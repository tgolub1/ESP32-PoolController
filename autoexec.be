# autoexec.be

def safe_load(filename)
  try
    if load(filename)
      log("AUTOEXEC: loaded " + filename, 2)
      return true
    else
      log("AUTOEXEC: script not found: " + filename, 1)
      return false
    end
    except .. as error_type, error_message
      log("AUTOEXEC: failed " + filename + ": " + str(error_type) + " - " + str(error_message), 1)
      return false
    end
end

safe_load("pump-valve.be")
safe_load("lights.be")
