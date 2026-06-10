tell application "Capture One"
	repeat with v in (get selected variants)
		tell adjustments of v
			set currentTemp to temperature
			set white balance preset to "Shot"
			set temperature to currentTemp
		end tell
	end repeat
end tell
