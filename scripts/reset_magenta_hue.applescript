tell application "Capture One"
	repeat with v in (get selected variants)
		tell color editor settings of adjustments of v
			set hue change of basic color correction "pink" to 0.0
		end tell
	end repeat
end tell
