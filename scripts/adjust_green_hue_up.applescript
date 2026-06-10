tell application "Capture One"
	repeat with v in (get selected variants)
		tell color editor settings of adjustments of v
			set hue change of basic color correction "green" to (get hue change of basic color correction "green") + 1.0
		end tell
	end repeat
end tell
