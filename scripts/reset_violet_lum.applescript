tell application "Capture One"
	repeat with v in (get selected variants)
		tell color editor settings of adjustments of v
			set lightness change of basic color correction "purple" to 0.0
		end tell
	end repeat
end tell
