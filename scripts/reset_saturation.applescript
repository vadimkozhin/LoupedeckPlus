tell application "Capture One"
	repeat with v in (get selected variants)
		set saturation of adjustments of v to {{DEFAULT}}
	end repeat
end tell
