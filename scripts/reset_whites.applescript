tell application "Capture One"
	repeat with v in (get selected variants)
		set white recovery of adjustments of v to {{DEFAULT}}
	end repeat
end tell
