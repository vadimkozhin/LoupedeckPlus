// Loupedeck Configuration GUI JavaScript
let currentConfig = null;
let currentConfigName = "";
let activeConfigName = "";
let globalOverride = false;
let availableScripts = [];
let selectedControl = null; // { type: 'knob'|'button'|'wheel'|'customModeButton', data: obj|arr, comment: string, svgId: string }
let currentWheelMode = "Hue"; // "Hue" | "Sat" | "Lum" for scroll wheel sub-editing

const callbacks = {};

function showErrorAlert(title, err) {
  let msg = title + ": " + err.message;
  if (err.line) {
    msg += "\nLine: " + err.line;
  }
  if (err.stack) {
    msg += "\n\nStack Trace:\n" + err.stack;
  }
  alert(msg);
}

// 1. Communication with Swift
function callSwift(action, params = {}) {
  return new Promise((resolve, reject) => {
    const callbackID = 'cb_' + Math.random().toString(36).substr(2, 9);
    callbacks[callbackID] = { resolve, reject };

    const message = {
      action: action,
      callbackID: callbackID,
      ...params
    };

    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.loupedeck) {
      window.webkit.messageHandlers.loupedeck.postMessage(message);
    } else {
      console.warn("Swift message handler 'loupedeck' not found. Running in browser mock mode.");
      // Browser mockup responses for developer local testing
      setTimeout(() => mockResponse(action, callbackID, params), 200);
    }
  });
}

window.receiveLoupedeckResponse = function (callbackID, data, error) {
  if (callbacks[callbackID]) {
    if (error) {
      callbacks[callbackID].reject(new Error(error));
    } else {
      callbacks[callbackID].resolve(data);
    }
    delete callbacks[callbackID];
  }
};

// Developer mockup responses for browser local development
function mockResponse(action, callbackID, params) {
  if (action === "getConfigs") {
    window.receiveLoupedeckResponse(callbackID, ["default.json", "CaptureOne.json", "Lightroom.json"], null);
  } else if (action === "getActiveConfig") {
    window.receiveLoupedeckResponse(callbackID, JSON.stringify({ activeConfig: "default.json", version: "1.0.0" }), null);
  } else if (action === "loadConfig") {
    const mock = {
      targetBundleIdentifier: "com.captureone.captureone16",
      customModeButton: { press: { midiMatch: "90 75 40", action: "custom_mode_press" } },
      knobs: [
        { comment: "Exposure Knob", default: 0.0, plus: { midiMatch: "B0 21 01", keyCode: 69, modifiers: ["option"] }, minus: { midiMatch: "B0 21 7F", keyCode: 27, modifiers: ["option"] }, press: { midiMatch: "80 21 40", action: "reset_exposure" } },
        { comment: "Red Wheel - Hue", plus: { midiMatch: "B0 01 01", action: "adjust_red_hue_up" }, minus: { midiMatch: "B0 01 7F", action: "adjust_red_hue_down" } },
        { comment: "Red Wheel - Sat", plus: { midiMatch: "B0 09 01", action: "adjust_red_saturation_up" }, minus: { midiMatch: "B0 09 7F", action: "adjust_red_saturation_down" } },
        { comment: "Red Wheel - Lum", plus: { midiMatch: "B0 11 01", action: "adjust_red_lightness_up" }, minus: { midiMatch: "B0 11 7F", action: "adjust_red_lightness_down" } }
      ],
      buttons: [
        { comment: "Undo", press: { midiMatch: "90 5F 40", keyCode: 6, modifiers: ["command"] } }
      ]
    };
    window.receiveLoupedeckResponse(callbackID, JSON.stringify(mock), null);
  } else if (action === "getScripts") {
    window.receiveLoupedeckResponse(callbackID, ["reset_exposure", "adjust_red_hue_up", "adjust_red_hue_down", "toggle_black_and_white"], null);
  } else if (action === "getSVG") {
    const mockSVG = `<svg viewBox="0 0 800 400"><rect x="10" y="10" width="780" height="380" rx="15" fill="#161a23" stroke="#00d2ff" stroke-width="2"/><text x="400" y="200" fill="#fff" font-size="20" text-anchor="middle">Loupedeck+ SVG Visualizer Mockup</text><g id="Exposure-knob"><circle cx="200" cy="150" r="30" fill="#2d3748" stroke="#a0aec0" stroke-width="2"/><text x="200" y="210" fill="#a0aec0" font-size="12" text-anchor="middle">Exposure Knob</text></g><g id="Undo"><rect x="350" y="125" width="100" height="50" rx="8" fill="#2d3748" stroke="#a0aec0" stroke-width="2"/><text x="400" y="155" fill="#a0aec0" font-size="12" text-anchor="middle">Undo</text></g></svg>`;
    window.receiveLoupedeckResponse(callbackID, mockSVG, null);
  } else if (action === "getDeviceStatus") {
    window.receiveLoupedeckResponse(callbackID, { isConnected: true, serialNumber: "LD-MOCK-12345" }, null);
  } else {
    window.receiveLoupedeckResponse(callbackID, "success", null);
  }
}

// Expose functions globally for Swift to evaluate
window.updateDeviceStatus = function (isConnected, serialNumber) {
  const statusDot = document.getElementById("status-dot");
  const statusText = document.getElementById("status-text");
  const serialWrapper = document.getElementById("serial-display-wrapper");
  const serialNumberEl = document.getElementById("serial-number");
  const lockOverlay = document.getElementById("ui-lock-overlay");

  if (isConnected) {
    statusDot.className = "status-dot connected";
    statusText.innerText = "Connected";
    lockOverlay.classList.add("hidden");
    if (serialNumber) {
      serialNumberEl.innerText = serialNumber;
      serialWrapper.style.display = "block";
    } else {
      serialWrapper.style.display = "none";
    }
  } else {
    statusDot.className = "status-dot disconnected";
    statusText.innerText = "Disconnected";
    serialWrapper.style.display = "none";
    lockOverlay.classList.remove("hidden");
  }
};

window.triggerAboutModal = function () {
  const modal = document.getElementById("about-modal");
  modal.classList.remove("hidden");
};

// 2. Initialize
document.addEventListener("DOMContentLoaded", async () => {
  // Load SVG (wrapped in try/catch to not block other async initializations)
  try {
    await loadSVG();
  } catch (err) {
    console.error("Failed to load SVG layout:", err);
  }

  // Load config list and scripts from Swift
  try {
    availableScripts = await callSwift("getScripts");
    const activeData = await callSwift("getActiveConfig");
    const activeObj = (typeof activeData === 'string') ? JSON.parse(activeData) : activeData;
    activeConfigName = activeObj.activeConfig;
    globalOverride = activeObj.globalOverride || false;

    const version = activeObj.version || "1.0.0";
    document.getElementById("app-version").innerText = `v${version}`;
    const aboutVerEl = document.getElementById("about-version");
    if (aboutVerEl) {
      aboutVerEl.innerText = `Version ${version}`;
    }

    await refreshProfilesList();

    // Default to active config
    currentConfigName = activeConfigName;
    document.getElementById("profile-select").value = currentConfigName;
    await loadProfile(currentConfigName);

    // Fetch initial device status
    try {
      const devStatus = await callSwift("getDeviceStatus");
      window.updateDeviceStatus(devStatus.isConnected, devStatus.serialNumber);
    } catch (devErr) {
      console.error("Failed to get initial device status:", devErr);
      window.updateDeviceStatus(false, "");
    }

    // Bind global inputs
    setupEventListeners();
  } catch (err) {
    console.error("Initialization error:", err);
    const container = document.getElementById("svg-container");
    container.innerHTML += `<div class="empty-state" style="color:var(--danger-color); padding-top:0;"><p>Configs not loaded: ${err.message}</p></div>`;
  }
});

// Load and inject SVG keyboard layout
async function loadSVG() {
  const container = document.getElementById("svg-container");
  try {
    const svgText = await callSwift("getSVG");
    container.innerHTML = svgText;
    setupSvgInteractions();
  } catch (err) {
    container.innerHTML = `<div class="empty-state" style="color:var(--danger-color)"><p>Failed to load keyboard layout: ${err.message}</p></div>`;
    throw err; // Re-throw to handle in initializer
  }
}

let customModeVisualActive = false;
let fnVisualActive = false;

// Setup SVG Hover & Click states
function setupSvgInteractions() {
  const svg = document.querySelector("#svg-container svg");
  if (!svg) return;

  // Set initial LED and modifier states
  updateLedVisuals();
  updateFnVisual();

  // Find all groups with IDs
  const groups = svg.querySelectorAll("g[id]");
  groups.forEach(g => {
    const id = g.getAttribute("id");

    // Skip border decoration elements
    if (id.includes("border")) {
      return;
    }

    // Skip internal SVG elements
    if (id.startsWith("svg") || id.startsWith("layer") || /^(g|path|rect|circle|ellipse)\d*$/i.test(id)) {
      // Check if it matches a control
      const hasControl = findControlInConfig(id);
      if (!hasControl) return;
    }

    // Check if it's one of the special buttons
    if (["Custom-Mode", "Hue", "Sat", "Lum", "Fn"].includes(id)) {
      g.classList.add("interactive-element");
      g.addEventListener("click", (e) => {
        e.stopPropagation();
        handleSpecialButtonClick(id);
      });
      return;
    }

    g.classList.add("interactive-element");

    g.addEventListener("click", (e) => {
      e.stopPropagation();
      selectControl(id, g);
    });
  });
}

function handleSpecialButtonClick(id) {
  if (id === "Custom-Mode") {
    customModeVisualActive = !customModeVisualActive;
    updateLedVisuals();
    updateActiveTab();
  } else if (id === "Fn") {
    fnVisualActive = !fnVisualActive;
    updateFnVisual();
    updateActiveTab();
  } else if (["Hue", "Sat", "Lum"].includes(id)) {
    currentWheelMode = id;
    updateLedVisuals();

    // If the selected control is a wheel, re-render form
    if (selectedControl && selectedControl.type === "wheel") {
      renderEditorForms();
    }
  }
}

function updateLedVisuals() {
  const customLed = document.getElementById("Custom-Mode-led");
  const hueLed = document.getElementById("Hue-led");
  const satLed = document.getElementById("Sat-led");
  const lumLed = document.getElementById("Lum-led");

  const cmBorder = document.getElementById("cm_border");
  const cmBorder2 = document.getElementById("cm_border2");
  const hueBorder = document.getElementById("hue_border");
  const satBorder = document.getElementById("sat_border");
  const lumBorder = document.getElementById("lum_border");

  if (customLed) {
    if (customModeVisualActive) {
      customLed.classList.add("led-active-white");
    } else {
      customLed.classList.remove("led-active-white");
    }
  }

  if (cmBorder) {
    if (customModeVisualActive) cmBorder.classList.add("border-active-green");
    else cmBorder.classList.remove("border-active-green");
  }

  if (cmBorder2) {
    if (customModeVisualActive) cmBorder2.classList.add("border-active-green");
    else cmBorder2.classList.remove("border-active-green");
  }

  if (hueLed) {
    if (currentWheelMode === "Hue") hueLed.classList.add("led-active");
    else hueLed.classList.remove("led-active");
  }

  if (hueBorder) {
    if (currentWheelMode === "Hue") hueBorder.classList.add("border-active");
    else hueBorder.classList.remove("border-active");
  }

  if (satLed) {
    if (currentWheelMode === "Sat") satLed.classList.add("led-active");
    else satLed.classList.remove("led-active");
  }

  if (satBorder) {
    if (currentWheelMode === "Sat") satBorder.classList.add("border-active");
    else satBorder.classList.remove("border-active");
  }

  if (lumLed) {
    if (currentWheelMode === "Lum") lumLed.classList.add("led-active");
    else lumLed.classList.remove("led-active");
  }

  if (lumBorder) {
    if (currentWheelMode === "Lum") lumBorder.classList.add("border-active");
    else lumBorder.classList.remove("border-active");
  }
}

function updateFnVisual() {
  const fnButton = document.getElementById("Fn");
  if (fnButton) {
    if (fnVisualActive) {
      fnButton.classList.add("modifier-active");
    } else {
      fnButton.classList.remove("modifier-active");
    }
  }
}

function updateActiveTab() {
  if (selectedControl) {
    const type = selectedControl.type;
    let targetTab = "normal";

    if (type === 'customModeButton') {
      targetTab = "normal";
    } else {
      if (customModeVisualActive && fnVisualActive) {
        targetTab = "cm-fn";
      } else if (customModeVisualActive) {
        targetTab = "cm";
      } else if (fnVisualActive) {
        targetTab = "fn";
      }
    }
    switchTab(targetTab);
  }
}

const HARDWARE_CONTROLS = {
  // Buttons
  "Undo": { type: "button", comment: "Undo", press: "90 5F 40", release: "80 5F 40" },
  "Redo": { type: "button", comment: "Redo", press: "90 60 40", release: "80 60 40" },
  "L1": { type: "button", comment: "L1", press: "90 72 40", release: "80 72 40" },
  "L2": { type: "button", comment: "L2", press: "90 73 40", release: "80 73 40" },
  "L3": { type: "button", comment: "L3", press: "90 74 40", release: "80 74 40" },
  "Clr-Bw": { type: "button", comment: "Clr/BW", press: "90 65 40", release: "80 65 40" },
  "Screen-Mode": { type: "button", comment: "Screen Mode", press: "90 61 40", release: "80 61 40" },
  "Before-After": { type: "button", comment: "Before/After Toggle", press: "90 66 40", release: "80 66 40" },
  "Export": { type: "button", comment: "Export Dialog", press: "90 58 40", release: "80 58 40" },
  "Copy": { type: "button", comment: "Copy Adjustments", press: "90 5C 40", release: "80 5C 40" },
  "Paste": { type: "button", comment: "Paste Adjustments", press: "90 5D 40", release: "80 5D 40" },
  "Fn": { type: "button", comment: "Fn Button", press: "90 6E 40", release: "80 6E 40" },
  "Custom-Mode": { type: "customModeButton", comment: "Custom Mode Button", press: "90 75 40", release: "80 75 40" },
  "C1": { type: "button", comment: "C1", press: "90 31 40", release: "80 31 40" },
  "C2": { type: "button", comment: "C2", press: "90 32 40", release: "80 32 40" },
  "C3": { type: "button", comment: "C3", press: "90 33 40", release: "80 33 40" },
  "C4": { type: "button", comment: "C4", press: "90 34 40", release: "80 34 40" },
  "C5": { type: "button", comment: "C5", press: "90 35 40", release: "80 35 40" },
  "C6": { type: "button", comment: "C6", press: "90 36 40", release: "80 36 40" },
  "Hue": { type: "button", comment: "Hue Mode Button", press: "90 62 40", release: "80 62 40" },
  "Sat": { type: "button", comment: "Sat Mode Button", press: "90 63 40", release: "80 63 40" },
  "Lum": { type: "button", comment: "Lum Mode Button", press: "90 64 40", release: "80 64 40" },
  "Cal": { type: "button", comment: "ColorTag --/col (Clear)", press: "90 41 40", release: "80 41 40" },
  "red": { type: "button", comment: "ColorTag red", press: "90 42 40", release: "80 42 40" },
  "yellow": { type: "button", comment: "ColorTag yellow", press: "90 43 40", release: "80 43 40" },
  "green": { type: "button", comment: "ColorTag green", press: "90 44 40", release: "80 44 40" },
  "blue": { type: "button", comment: "ColorTag blue", press: "90 45 40", release: "80 45 40" },
  "violet": { type: "button", comment: "ColorTag violet", press: "90 46 40", release: "80 46 40" },
  "P1": { type: "button", comment: "P1", press: "90 50 40", release: "80 50 40" },
  "P2": { type: "button", comment: "P2", press: "90 51 40", release: "80 51 40" },
  "P3": { type: "button", comment: "P3", press: "90 52 40", release: "80 52 40" },
  "P4": { type: "button", comment: "P4", press: "90 53 40", release: "80 53 40" },
  "P5": { type: "button", comment: "P5", press: "90 54 40", release: "80 54 40" },
  "P6": { type: "button", comment: "P6", press: "90 55 40", release: "80 55 40" },
  "P7": { type: "button", comment: "P7", press: "90 56 40", release: "80 56 40" },
  "P8": { type: "button", comment: "P8", press: "90 57 40", release: "80 57 40" },
  "Up": { type: "button", comment: "Up Arrow", press: "90 4C 40", release: "80 4C 40" },
  "Down": { type: "button", comment: "Down Arrow", press: "90 4D 40", release: "80 4D 40" },
  "Left": { type: "button", comment: "Left Arrow", press: "90 4E 40", release: "80 4E 40" },
  "Right": { type: "button", comment: "Right Arrow", press: "90 4F 40", release: "80 4F 40" },

  // Knobs
  "Exposure-knob": { type: "knob", comment: "Exposure Knob", baseNote: "21", press: "80 21 40", release: "80 21 40" },
  "D1-knob": { type: "knob", comment: "D1 knob", baseNote: "29", press: "80 29 40", release: "80 29 40" },
  "Contrast-knob": { type: "knob", comment: "Contrast Knob", baseNote: "2E", press: "80 2E 40", release: "80 2E 40" },
  "Clarity-knob": { type: "knob", comment: "Clarity Knob", baseNote: "2D", press: "80 2D 40", release: "80 2D 40" },
  "Shadows-knob": { type: "knob", comment: "Shadows Knob", baseNote: "2C", press: "80 2C 40", release: "80 2C 40" },
  "Highlights-knob": { type: "knob", comment: "Highlights Knob", baseNote: "28", press: "80 28 40", release: "80 28 40" },
  "Blacks-nkob": { type: "knob", comment: "Blacks Knob", baseNote: "22", press: "80 22 40", release: "80 22 40" },
  "Whites-knob": { type: "knob", comment: "Whites Knob", baseNote: "23", press: "80 23 40", release: "80 23 40" },
  "Saturation-knob": { type: "knob", comment: "Saturation Knob", baseNote: "24", press: "80 24 40", release: "80 24 40" },
  "D2-knob": { type: "knob", comment: "D2 knob", baseNote: "2A", press: "80 2A 40", release: "80 2A 40" },
  "Control-Dial": { type: "knob", comment: "Control Dial", baseNote: "30", press: "90 30 40", release: "80 30 40" },
  "Temperature-knob": { type: "knob", comment: "Temperature Knob", baseNote: "26", press: "90 26 40", release: "80 26 40" },
  "Tint-knob": { type: "knob", comment: "Tint Knob", baseNote: "27", press: "90 27 40", release: "80 27 40" },
  "Vibrance-knob": { type: "knob", comment: "Vibrance Knob", baseNote: "25", press: "80 25 40", release: "80 25 40" },

  // Wheels
  "Red-scroll": { type: "wheel", color: "Red", baseNotes: ["01", "09", "11"] },
  "Orange-scroll": { type: "wheel", color: "Orange", baseNotes: ["02", "0A", "12"] },
  "Yellow-scroll": { type: "wheel", color: "Yellow", baseNotes: ["03", "0B", "13"] },
  "Green-scroll": { type: "wheel", color: "Green", baseNotes: ["04", "0C", "14"] },
  "Cyan-scroll": { type: "wheel", color: "Cyan", baseNotes: ["05", "0D", "15"] },
  "BLue-scroll": { type: "wheel", color: "Blue", baseNotes: ["06", "0E", "16"] },
  "Violet-scroll": { type: "wheel", color: "Violet", baseNotes: ["07", "0F", "17"] },
  "Magenta-scroll": { type: "wheel", color: "Magenta", baseNotes: ["08", "10", "18"] }
};

const CODE_TO_MACOS_KEYCODE = {
  // Letters
  "KeyA": 0, "KeyB": 11, "KeyC": 8, "KeyD": 2, "KeyE": 14, "KeyF": 3, "KeyG": 5, "KeyH": 4, "KeyI": 34, "KeyJ": 38,
  "KeyK": 40, "KeyL": 37, "KeyM": 46, "KeyN": 45, "KeyO": 31, "KeyP": 35, "KeyQ": 12, "KeyR": 15, "KeyS": 1, "KeyT": 17,
  "KeyU": 32, "KeyV": 9, "KeyW": 13, "KeyX": 7, "KeyY": 16, "KeyZ": 6,
  // Digits
  "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit5": 23, "Digit6": 22, "Digit7": 26, "Digit8": 28, "Digit9": 25, "Digit0": 29,
  // F Keys
  "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
  // Special Keys
  "Space": 49, "Escape": 53, "Enter": 36, "NumpadEnter": 76, "Tab": 48, "Backspace": 51,
  "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
  // Punctuation
  "Minus": 27, "Equal": 24, "BracketLeft": 33, "BracketRight": 30, "Semicolon": 41, "Quote": 39, "Comma": 43, "Period": 47, "Slash": 44, "Backslash": 42, "Backquote": 50,
  // Modifiers (Added to support single-modifier detection)
  "ControlLeft": 59, "ControlRight": 62,
  "ShiftLeft": 56, "ShiftRight": 60,
  "AltLeft": 58, "AltRight": 61,
  "MetaLeft": 55, "MetaRight": 54
};

function getCharFromMacKeyCode(code) {
  if (code === undefined || code === null || isNaN(code)) return "";
  for (const [key, val] of Object.entries(CODE_TO_MACOS_KEYCODE)) {
    if (val === code) {
      let cleanName = key;
      if (key.startsWith("Key")) {
        cleanName = key.substring(3);
      } else if (key.startsWith("Digit")) {
        cleanName = key.substring(5);
      } else if (key.startsWith("Arrow")) {
        cleanName = key.substring(5) + " Arrow";
      } else if (key === "ControlLeft" || key === "ControlRight") {
        cleanName = "Control";
      } else if (key === "ShiftLeft" || key === "ShiftRight") {
        cleanName = "Shift";
      } else if (key === "AltLeft" || key === "AltRight") {
        cleanName = "Option";
      } else if (key === "MetaLeft" || key === "MetaRight") {
        cleanName = "Command";
      }
      return cleanName;
    }
  }
  return "";
}

function setupKeyDetector(parentDiv) {
  if (!parentDiv) return;
  const detector = parentDiv.querySelector(".key-detector");
  const detectorBtn = parentDiv.querySelector(".key-detector-btn");
  const resultDiv = parentDiv.querySelector(".key-detector-result");
  const keycodeInput = parentDiv.querySelector(".action-keycode");
  const mappedCharSpan = parentDiv.querySelector(".keycode-mapped-char");

  if (!detector || !resultDiv || !keycodeInput) return;

  function updateMappedChar() {
    if (mappedCharSpan) {
      const val = parseInt(keycodeInput.value);
      const char = getCharFromMacKeyCode(val);
      mappedCharSpan.value = char || "";
    }
  }

  // Update initially
  updateMappedChar();

  // Listen for changes
  keycodeInput.addEventListener("input", updateMappedChar);
  keycodeInput.addEventListener("change", updateMappedChar);

  if (detectorBtn) {
    detectorBtn.addEventListener("click", () => {
      detector.focus();
    });
  }

  detector.addEventListener("keydown", (e) => {
    e.preventDefault();
    e.stopPropagation();

    const modifiers = [];
    if (e.ctrlKey) modifiers.push("control");
    if (e.altKey) modifiers.push("option");
    if (e.shiftKey) modifiers.push("shift");
    if (e.metaKey) modifiers.push("command");

    // Filter out the currently pressed key from modifiers list if it is a modifier itself
    if (e.code === "ControlLeft" || e.code === "ControlRight") {
      const idx = modifiers.indexOf("control");
      if (idx !== -1) modifiers.splice(idx, 1);
    } else if (e.code === "ShiftLeft" || e.code === "ShiftRight") {
      const idx = modifiers.indexOf("shift");
      if (idx !== -1) modifiers.splice(idx, 1);
    } else if (e.code === "AltLeft" || e.code === "AltRight") {
      const idx = modifiers.indexOf("option");
      if (idx !== -1) modifiers.splice(idx, 1);
    } else if (e.code === "MetaLeft" || e.code === "MetaRight") {
      const idx = modifiers.indexOf("command");
      if (idx !== -1) modifiers.splice(idx, 1);
    }

    const macCode = CODE_TO_MACOS_KEYCODE[e.code];
    let keyName = e.key;
    if (keyName === " ") keyName = "Space";

    // Beautify modifier key names if they are the primary key
    if (e.code === "ControlLeft" || e.code === "ControlRight") keyName = "Control";
    else if (e.code === "ShiftLeft" || e.code === "ShiftRight") keyName = "Shift";
    else if (e.code === "AltLeft" || e.code === "AltRight") keyName = "Option";
    else if (e.code === "MetaLeft" || e.code === "MetaRight") keyName = "Command";

    if (macCode !== undefined) {
      const comboText = (modifiers.length > 0 ? modifiers.join(" + ") + " + " : "") + keyName;
      resultDiv.innerText = `Detected KeyCode: ${macCode} (${comboText})`;

      // Automatically update the fields for convenience!
      keycodeInput.value = macCode;

      // If it's the keystroke parent, check/uncheck the modifier checkboxes
      const modCheckboxes = parentDiv.querySelectorAll(".action-mod");
      modCheckboxes.forEach(cb => {
        cb.checked = modifiers.includes(cb.value);
      });

      // Update mapped character label
      updateMappedChar();

      // Auto-save settings on update
      saveControlSettings();
    } else {
      resultDiv.innerText = `Key '${keyName}' is not mapped to macOS virtual keycode.`;
    }
  });

  detector.addEventListener("focus", () => {
    if (detectorBtn) {
      detectorBtn.style.borderColor = "var(--accent-color)";
      detectorBtn.style.background = "rgba(0, 210, 255, 0.1)";
      detectorBtn.style.boxShadow = "0 0 0 3px rgba(0, 210, 255, 0.15)";
    }
    resultDiv.innerText = "Press key combination on your keyboard...";
  });

  detector.addEventListener("blur", () => {
    if (detectorBtn) {
      detectorBtn.style.borderColor = "var(--border-color)";
      detectorBtn.style.background = "rgba(255, 255, 255, 0.05)";
      detectorBtn.style.boxShadow = "none";
    }
    resultDiv.innerText = "";
  });
}

function getMidiNoteFromMidiMatch(midiMatch) {
  if (!midiMatch || typeof midiMatch !== 'string') return null;
  const parts = midiMatch.trim().split(/\s+/);
  if (parts.length >= 2) {
    return parts[1].toLowerCase();
  }
  return null;
}

function getConfigItemMidiNotes(item) {
  const notes = new Set();
  if (!item) return notes;
  const keys = [
    'press', 'release', 'plus', 'minus',
    'cm_press', 'cm_release', 'cm_plus', 'cm_minus',
    'fn_press', 'fn_release', 'fn_plus', 'fn_minus',
    'cm_fn_press', 'cm_fn_release', 'cm_fn_plus', 'cm_fn_minus'
  ];
  for (const key of keys) {
    if (item[key] && item[key].midiMatch) {
      const note = getMidiNoteFromMidiMatch(item[key].midiMatch);
      if (note) {
        notes.add(note);
      }
    }
  }
  return notes;
}

function getHardwareControlMidiNotes(hw) {
  const notes = [];
  if (!hw) return notes;
  if (hw.baseNote) {
    notes.push(hw.baseNote.toLowerCase());
  }
  if (hw.baseNotes) {
    hw.baseNotes.forEach(n => notes.push(n.toLowerCase()));
  }
  if (hw.press) {
    const n = getMidiNoteFromMidiMatch(hw.press);
    if (n) notes.push(n);
  }
  if (hw.release) {
    const n = getMidiNoteFromMidiMatch(hw.release);
    if (n) notes.push(n);
  }
  return Array.from(new Set(notes));
}

// Find control in local JSON state
function findControlInConfig(svgId) {
  if (!currentConfig) return null;

  if (svgId === 'Custom-Mode') {
    return { type: 'customModeButton', data: currentConfig.customModeButton || { press: { midiMatch: "90 75 40" }, release: { midiMatch: "80 75 40" } } };
  }

  const normId = svgId.toLowerCase();
  if (!currentConfig.knobs) currentConfig.knobs = [];
  if (!currentConfig.buttons) currentConfig.buttons = [];

  const hw = HARDWARE_CONTROLS[svgId];

  // 1. MIDI-First matching
  if (hw) {
    const hwNotes = getHardwareControlMidiNotes(hw);
    if (hwNotes.length > 0) {
      if (hw.type === 'knob') {
        const match = currentConfig.knobs.find(k => {
          const itemNotes = getConfigItemMidiNotes(k);
          return hwNotes.some(n => itemNotes.has(n));
        });
        if (match) {
          return { type: 'knob', comment: match.comment, data: match };
        }
      } else if (hw.type === 'wheel') {
        const matches = currentConfig.knobs.filter(k => {
          const itemNotes = getConfigItemMidiNotes(k);
          return hwNotes.some(n => itemNotes.has(n));
        });
        if (matches.length > 0) {
          const color = hw.color || svgId.substring(0, svgId.lastIndexOf('-'));
          return { type: 'wheel', color: color, data: matches, comment: color + " Wheels" };
        }
      } else if (hw.type === 'button') {
        const match = currentConfig.buttons.find(b => {
          const itemNotes = getConfigItemMidiNotes(b);
          return hwNotes.some(n => itemNotes.has(n));
        });
        if (match) {
          return { type: 'button', comment: match.comment, data: match };
        }
      }
    }
  }

  // 2. Comment-based fallback (original search logic)
  if (currentConfig.knobs) {
    if (normId.endsWith('-scroll')) {
      let color = svgId.substring(0, svgId.lastIndexOf('-')); // e.g. "Red", "Light-blue", "BLue"
      if (color.toLowerCase() === 'blue') color = 'Blue';
      if (color.toLowerCase() === 'cyan') color = 'Cyan';

      const matches = currentConfig.knobs.filter(k => k.comment && k.comment.toLowerCase().startsWith(color.toLowerCase() + " wheel"));
      if (matches.length > 0) {
        return { type: 'wheel', color: color, data: matches, comment: color + " Wheels" };
      }
    }

    // Check normal knob
    const knobName = svgId.replace('-knob', '').replace('-nkob', '').replace('-', ' ').toLowerCase();
    const match = currentConfig.knobs.find(k => k.comment && k.comment.toLowerCase().startsWith(knobName));
    if (match) {
      return { type: 'knob', comment: match.comment, data: match };
    }

    // Control Dial
    if (svgId === 'Control-Dial') {
      const match = currentConfig.knobs.find(k => k.comment && k.comment.toLowerCase() === 'control dial');
      if (match) {
        return { type: 'knob', comment: match.comment, data: match };
      }
    }
  }

  if (currentConfig.buttons) {
    const btnName = svgId.replace('-', ' ').toLowerCase();

    if (svgId === 'Clr-Bw') {
      const match = currentConfig.buttons.find(b => b.comment && b.comment.toLowerCase() === 'clr/bw');
      if (match) return { type: 'button', comment: match.comment, data: match };
    }

    if (svgId === 'Screen-Mode') {
      const match = currentConfig.buttons.find(b => b.comment && b.comment.toLowerCase().startsWith('screen mode'));
      if (match) return { type: 'button', comment: match.comment, data: match };
    }

    if (svgId === 'Before-After') {
      const match = currentConfig.buttons.find(b => b.comment && b.comment.toLowerCase().startsWith('before/after'));
      if (match) return { type: 'button', comment: match.comment, data: match };
    }

    if (['up', 'down', 'left', 'right'].includes(normId)) {
      const match = currentConfig.buttons.find(b => b.comment && b.comment.toLowerCase().startsWith(normId + ' arrow'));
      if (match) return { type: 'button', comment: match.comment, data: match };
    }

    if (svgId === 'Cal') {
      const match = currentConfig.buttons.find(b => b.comment && (b.comment.toLowerCase().includes('--/col') || b.comment.toLowerCase().includes('col')));
      if (match) return { type: 'button', comment: match.comment, data: match };
    }

    const match = currentConfig.buttons.find(b => b.comment && (b.comment.toLowerCase() === btnName || b.comment.toLowerCase().startsWith(btnName + ' ')));
    if (match) {
      return { type: 'button', comment: match.comment, data: match };
    }
  }

  // 3. Fallback: If not in config, create it from HARDWARE_CONTROLS!
  if (hw) {
    if (hw.type === 'wheel') {
      const color = hw.color || svgId.substring(0, svgId.lastIndexOf('-'));
      const wheelModes = ["Hue", "Sat", "Lum"];
      const newMatches = wheelModes.map((mode, modeIdx) => {
        const baseNote = hw.baseNotes[modeIdx];
        const comment = `${color} Wheel - ${mode}`;
        const newWheel = {
          comment: comment,
          plus: { midiMatch: `B0 ${baseNote} 01` },
          minus: { midiMatch: `B0 ${baseNote} 7F` },
          press: { midiMatch: `80 ${baseNote} 40` }
        };
        currentConfig.knobs.push(newWheel);
        return newWheel;
      });
      return { type: 'wheel', color: color, data: newMatches, comment: color + " Wheels" };
    } else if (hw.type === 'knob') {
      const pressStatus = hw.press ? hw.press.split(' ')[0] : '80';
      const newKnob = {
        comment: hw.comment,
        plus: { midiMatch: `B0 ${hw.baseNote} 01` },
        minus: { midiMatch: `B0 ${hw.baseNote} 7F` },
        press: { midiMatch: `${pressStatus} ${hw.baseNote} 40` }
      };
      currentConfig.knobs.push(newKnob);
      return { type: 'knob', comment: hw.comment, data: newKnob };
    } else if (hw.type === 'button' || hw.type === 'customModeButton') {
      const newBtn = {
        comment: hw.comment,
        press: { midiMatch: hw.press },
        release: { midiMatch: hw.release }
      };
      currentConfig.buttons.push(newBtn);
      return { type: 'button', comment: hw.comment, data: newBtn };
    }
  }

  return null;
}

// 3. Selection & Panel Loading
function selectControl(id, element) {
  // Show control pane & hide profile settings
  showPane("control");

  // Autosave any current control settings first!
  if (selectedControl) {
    saveControlSettings();
  }

  // Clear previous selected element style
  document.querySelectorAll(".interactive-element").forEach(el => el.classList.remove("selected"));

  if (element) {
    element.classList.add("selected");
  }

  const control = findControlInConfig(id);
  if (!control) {
    // Unmapped/non-editable control
    selectedControl = null;
    document.getElementById("selected-control-badge").innerText = "Not Mapped";
    document.getElementById("selected-control-badge").className = "badge";
    document.getElementById("no-control-selected").classList.remove("hidden");
    document.getElementById("no-control-selected").innerHTML = `<div class="empty-icon">🔒</div><p>'${id}' is a hardware control not configurable in this profile.</p>`;
    document.getElementById("control-editor").classList.add("hidden");
    return;
  }

  selectedControl = { ...control, svgId: id };

  // Update UI Panels
  document.getElementById("no-control-selected").classList.add("hidden");
  document.getElementById("control-editor").classList.remove("hidden");

  document.getElementById("selected-control-badge").innerText = control.type.toUpperCase();
  document.getElementById("selected-control-badge").className = "badge active";

  // Default value (Knobs only)
  const defaultValGroup = document.getElementById("knob-default-group");
  if (control.type === 'knob' || control.type === 'wheel') {
    defaultValGroup.classList.remove("hidden");
    const activeKnobData = (control.type === 'wheel') ? control.data[0] : control.data; // default value comes from Hue knob
    document.getElementById("knob-default-value").value = activeKnobData.default !== undefined ? activeKnobData.default : "";
  } else {
    defaultValGroup.classList.add("hidden");
  }

  // Setup editor inputs based on Tabs
  renderEditorForms();
}

function getControlBaseMidiNote(data) {
  if (!data) return null;
  const item = Array.isArray(data) ? data[0] : data;
  const keys = ['press', 'release', 'plus', 'minus', 'fn_press', 'fn_release', 'cm_press', 'cm_release', 'cm_fn_press', 'cm_fn_release', 'fn_plus', 'fn_minus', 'cm_fn_plus', 'cm_fn_minus'];
  for (const k of keys) {
    if (item[k] && item[k].midiMatch) {
      const parts = item[k].midiMatch.trim().split(/\s+/);
      if (parts.length >= 2 && parts[1] !== '*' && parts[1] !== '**') {
        return parts[1];
      }
    }
  }
  // Try using the selected control SVG ID lookup as a fallback
  if (selectedControl && selectedControl.svgId) {
    const hw = HARDWARE_CONTROLS[selectedControl.svgId];
    if (hw) {
      if (hw.baseNote) return hw.baseNote;
      if (hw.baseNotes) {
        // If we are currently editing a wheel mode, use the correct mode note index
        const wheelModes = ["Hue", "Sat", "Lum"];
        const modeIdx = wheelModes.indexOf(currentWheelMode);
        if (modeIdx !== -1) return hw.baseNotes[modeIdx];
        return hw.baseNotes[0];
      }
      if (hw.press) {
        const parts = hw.press.trim().split(/\s+/);
        if (parts.length >= 2) return parts[1];
      }
    }
  }
  return null;
}

function renderEditorForms() {
  if (!selectedControl) return;

  const type = selectedControl.type;

  // Dynamic Title, Description, and Comment updating based on type and mode
  const commentInput = document.getElementById("control-custom-comment");
  if (type === 'wheel') {
    const wheelObj = selectedControl.data.find(k => k.comment && k.comment.includes(" - " + currentWheelMode));
    const activeComment = wheelObj ? wheelObj.comment : `${selectedControl.color} Wheel - ${currentWheelMode}`;

    document.getElementById("selected-control-title").innerText = activeComment;
    document.getElementById("selected-control-description").innerText = `Color Wheel (${currentWheelMode} Mode)`;

    commentInput.value = activeComment;
    commentInput.disabled = true;
  } else {
    document.getElementById("selected-control-title").innerText = selectedControl.comment || selectedControl.svgId.replace('-', ' ');
    document.getElementById("selected-control-description").innerText = `${selectedControl.type.toUpperCase()} Mapping`;

    if (type === 'customModeButton') {
      commentInput.value = selectedControl.data.comment || "Custom Mode Trigger";
      commentInput.disabled = true;
    } else {
      commentInput.value = selectedControl.data.comment || "";
      commentInput.disabled = false;
    }
  }

  // Update subgroups and headers for wheels to say scroll instead of rotate
  const isWheel = (type === 'wheel');
  document.querySelectorAll(".tab-content").forEach(tab => {
    const plusSubgroup = tab.querySelector(".action-event-group[id$='plus-minus'] .action-subgroup:nth-of-type(1) h5");
    const minusSubgroup = tab.querySelector(".action-event-group[id$='plus-minus'] .action-subgroup:nth-of-type(2) h5");
    if (plusSubgroup) {
      plusSubgroup.innerText = isWheel ? "Scroll Up / Plus (+)" : "Rotate Right / Plus (+)";
    }
    if (minusSubgroup) {
      minusSubgroup.innerText = isWheel ? "Scroll Down / Minus (-)" : "Rotate Left / Minus (-)";
    }

    const rotGroupHeader = tab.querySelector(".action-event-group[id$='plus-minus'] h4");
    if (rotGroupHeader) {
      if (isWheel) {
        if (tab.id === 'tab-normal') rotGroupHeader.innerText = "Scroll Action";
        else if (tab.id === 'tab-fn') rotGroupHeader.innerText = "Scroll Action (with Fn held)";
        else if (tab.id === 'tab-cm') rotGroupHeader.innerText = "Scroll Action (in Custom Mode)";
        else if (tab.id === 'tab-cm-fn') rotGroupHeader.innerText = "Scroll Action (Custom Mode + Fn)";
      } else {
        if (tab.id === 'tab-normal') rotGroupHeader.innerText = "Rotation Action";
        else if (tab.id === 'tab-fn') rotGroupHeader.innerText = "Rotation Action (with Fn held)";
        else if (tab.id === 'tab-cm') rotGroupHeader.innerText = "Rotation Action (in Custom Mode)";
        else if (tab.id === 'tab-cm-fn') rotGroupHeader.innerText = "Rotation Action (Custom Mode + Fn)";
      }
    }
  });

  // Handle wheel mode container at top
  const wheelModeContainer = document.getElementById("wheel-mode-container");
  if (type === 'wheel') {
    wheelModeContainer.classList.remove("hidden");
    wheelModeContainer.innerHTML = `
      <label>Wheel Component Mode</label>
      <select id="wheel-mode-select" style="width: 100%;">
        <option value="Hue" ${currentWheelMode === 'Hue' ? 'selected' : ''}>Hue Control</option>
        <option value="Sat" ${currentWheelMode === 'Sat' ? 'selected' : ''}>Saturation Control</option>
        <option value="Lum" ${currentWheelMode === 'Lum' ? 'selected' : ''}>Luminance Control</option>
      </select>
    `;
    document.getElementById("wheel-mode-select").addEventListener("change", (e) => {
      currentWheelMode = e.target.value;
      renderEditorForms();
    });
  } else {
    wheelModeContainer.classList.add("hidden");
    wheelModeContainer.innerHTML = "";
  }

  // Setup Modifier Tabs availability
  const tabFn = document.querySelector(".tab-btn[data-tab='fn']");
  const tabCm = document.querySelector(".tab-btn[data-tab='cm']");
  const tabCmFn = document.querySelector(".tab-btn[data-tab='cm-fn']");

  let targetTab = "normal";
  if (type === 'customModeButton') {
    // Custom Mode Button only has standard Press/Release
    tabFn.classList.add("hidden");
    tabCm.classList.add("hidden");
    tabCmFn.classList.add("hidden");
    targetTab = "normal";
  } else {
    tabFn.classList.remove("hidden");
    tabCm.classList.remove("hidden");
    tabCmFn.classList.remove("hidden");

    if (customModeVisualActive && fnVisualActive) {
      targetTab = "cm-fn";
    } else if (customModeVisualActive) {
      targetTab = "cm";
    } else if (fnVisualActive) {
      targetTab = "fn";
    }
  }
  // Show/Hide Rotation or Click sections based on type
  const hasRotation = (type === 'knob' || type === 'wheel');
  const hasClick = (type === 'knob' || type === 'button' || type === 'customModeButton' || type === 'wheel');

  const rotGroups = ["group-normal-plus-minus", "group-fn-plus-minus", "group-cm-plus-minus", "group-cm-fn-plus-minus"];
  const clickGroups = ["group-normal-press-release", "group-fn-press-release", "group-cm-press-release", "group-cm-fn-press-release"];

  rotGroups.forEach(g => {
    const el = document.getElementById(g);
    if (el) {
      if (hasRotation) el.classList.remove("hidden");
      else el.classList.add("hidden");
    }
  });

  clickGroups.forEach(g => {
    const el = document.getElementById(g);
    if (el) {
      if (hasClick) el.classList.remove("hidden");
      else el.classList.add("hidden");
    }
  });

  switchTab(targetTab);

  // Empty all action field containers
  const targets = ["normal-plus", "normal-minus", "normal-press", "normal-release",
    "fn-plus", "fn-minus", "fn-press", "fn-release",
    "cm-plus", "cm-minus", "cm-press", "cm-release",
    "cm-fn-plus", "cm-fn-minus", "cm-fn-press", "cm-fn-release"];

  targets.forEach(t => {
    const el = document.getElementById(`fields-${t}`);
    if (el) el.innerHTML = "";
  });

  // Render the fields
  if (type === 'customModeButton') {
    renderActionFields("normal-press", selectedControl.data.press, "90 75 40");
    renderActionFields("normal-release", selectedControl.data.release, "80 75 40");
  } else if (type === 'wheel') {
    // Find the correct knob mapping object for selected Wheel mode
    const wheelObj = selectedControl.data.find(k => k.comment && k.comment.includes(" - " + currentWheelMode));
    if (wheelObj) {
      const baseNote = getControlBaseMidiNote(wheelObj) || "*";
      // Normal rotation
      renderActionFields("normal-plus", wheelObj.plus, `B0 ${baseNote} 01`);
      renderActionFields("normal-minus", wheelObj.minus, `B0 ${baseNote} 7F`);
      // Normal click
      renderActionFields("normal-press", wheelObj.press, `80 ${baseNote} 40`);
      renderActionFields("normal-release", wheelObj.release, `80 ${baseNote} 40`);

      // Fn rotation
      renderActionFields("fn-plus", wheelObj.fn_plus, `B0 ${baseNote} 01`);
      renderActionFields("fn-minus", wheelObj.fn_minus, `B0 ${baseNote} 7F`);
      // Fn click
      renderActionFields("fn-press", wheelObj.fn_press, `80 ${baseNote} 40`);
      renderActionFields("fn-release", wheelObj.fn_release, `80 ${baseNote} 40`);

      // CM rotation
      renderActionFields("cm-plus", wheelObj.cm_plus, `B0 ${baseNote} 01`);
      renderActionFields("cm-minus", wheelObj.cm_minus, `B0 ${baseNote} 7F`);
      // CM click
      renderActionFields("cm-press", wheelObj.cm_press, `80 ${baseNote} 40`);
      renderActionFields("cm-release", wheelObj.cm_release, `80 ${baseNote} 40`);

      // CM + Fn rotation
      renderActionFields("cm-fn-plus", wheelObj.cm_fn_plus, `B0 ${baseNote} 01`);
      renderActionFields("cm-fn-minus", wheelObj.cm_fn_minus, `B0 ${baseNote} 7F`);
      // CM + Fn click
      renderActionFields("cm-fn-press", wheelObj.cm_fn_press, `80 ${baseNote} 40`);
      renderActionFields("cm-fn-release", wheelObj.cm_fn_release, `80 ${baseNote} 40`);
    }
  } else if (type === 'knob') {
    const k = selectedControl.data;
    const baseNote = getControlBaseMidiNote(k) || "*";
    // Normal
    renderActionFields("normal-plus", k.plus, `B0 ${baseNote} 01`);
    renderActionFields("normal-minus", k.minus, `B0 ${baseNote} 7F`);
    renderActionFields("normal-press", k.press, `80 ${baseNote} 40`);
    renderActionFields("normal-release", k.release, `80 ${baseNote} 40`);
    // Fn
    renderActionFields("fn-plus", k.fn_plus, `B0 ${baseNote} 01`);
    renderActionFields("fn-minus", k.fn_minus, `B0 ${baseNote} 7F`);
    renderActionFields("fn-press", k.fn_press, `80 ${baseNote} 40`);
    renderActionFields("fn-release", k.fn_release, `80 ${baseNote} 40`);
    // CM
    renderActionFields("cm-plus", k.cm_plus, `B0 ${baseNote} 01`);
    renderActionFields("cm-minus", k.cm_minus, `B0 ${baseNote} 7F`);
    renderActionFields("cm-press", k.cm_press, `80 ${baseNote} 40`);
    renderActionFields("cm-release", k.cm_release, `80 ${baseNote} 40`);
    // CM + Fn
    renderActionFields("cm-fn-plus", k.cm_fn_plus, `B0 ${baseNote} 01`);
    renderActionFields("cm-fn-minus", k.cm_fn_minus, `B0 ${baseNote} 7F`);
    renderActionFields("cm-fn-press", k.cm_fn_press, `80 ${baseNote} 40`);
    renderActionFields("cm-fn-release", k.cm_fn_release, `80 ${baseNote} 40`);
  } else if (type === 'button') {
    const b = selectedControl.data;
    const baseNote = getControlBaseMidiNote(b) || "*";
    // Normal
    renderActionFields("normal-press", b.press, `90 ${baseNote} 40`);
    renderActionFields("normal-release", b.release, `80 ${baseNote} 40`);
    // Fn
    renderActionFields("fn-press", b.fn_press, `90 ${baseNote} 40`);
    renderActionFields("fn-release", b.fn_release, `80 ${baseNote} 40`);
    // CM
    renderActionFields("cm-press", b.cm_press, `90 ${baseNote} 40`);
    renderActionFields("cm-release", b.cm_release, `80 ${baseNote} 40`);
    // CM + Fn
    renderActionFields("cm-fn-press", b.cm_fn_press, `90 ${baseNote} 40`);
    renderActionFields("cm-fn-release", b.cm_fn_release, `80 ${baseNote} 40`);
  }
}

function renderActionFields(targetId, actionData, defaultMidiMatch) {
  const container = document.getElementById(`fields-${targetId}`);
  if (!container) return;

  const template = document.getElementById("action-template");
  const clone = template.content.cloneNode(true);

  const select = clone.querySelector(".action-type-select");
  const keystrokeDiv = clone.querySelector(".keystroke-details");
  const applescriptDiv = clone.querySelector(".applescript-details");
  const socketDiv = clone.querySelector(".socket-details");

  const keycodeInput = clone.querySelector(".action-keycode");
  const scriptSelect = clone.querySelector(".action-script-select");
  const socketInput = clone.querySelector(".action-socket-command");
  const modCheckboxes = clone.querySelectorAll(".action-mod");

  // Set MIDI Match (stored hidden or data attribute)
  container.dataset.midiMatch = (actionData && actionData.midiMatch) ? actionData.midiMatch : defaultMidiMatch;

  // Populate Script drop-down
  scriptSelect.innerHTML = `<option value="" disabled selected>Select script...</option>`;
  availableScripts.forEach(s => {
    const opt = document.createElement("option");
    opt.value = s;
    opt.innerText = s;
    scriptSelect.appendChild(opt);
  });

  // Identify type of action
  let type = "none";
  if (actionData) {
    if (actionData.socketCommand) {
      type = "socket";
    } else if (actionData.action) {
      type = "applescript";
    } else if (actionData.keyCode !== undefined && actionData.keyCode !== null) {
      type = "keystroke";
    }
  }

  // Populate Action Type Options dynamically depending on currentConfig settings
  select.innerHTML = '<option value="none">No Action</option>';
  if (type === "keystroke" || !currentConfig || currentConfig.hotkeys !== false) {
    const opt = document.createElement("option");
    opt.value = "keystroke";
    opt.innerText = "Virtual Keystroke";
    select.appendChild(opt);
  }
  if (type === "applescript" || !currentConfig || currentConfig.apple_script !== false) {
    const opt = document.createElement("option");
    opt.value = "applescript";
    opt.innerText = "Execute AppleScript";
    select.appendChild(opt);
  }
  if (type === "socket" || (currentConfig && currentConfig.lightroom_socket === true)) {
    const opt = document.createElement("option");
    opt.value = "socket";
    opt.innerText = "Socket Command";
    select.appendChild(opt);
  }

  select.value = type;

  // Toggle forms based on type
  if (type === "keystroke") {
    keystrokeDiv.classList.remove("hidden");
    keycodeInput.value = actionData.keyCode;
    // Set modifiers
    if (actionData.modifiers) {
      modCheckboxes.forEach(cb => {
        if (actionData.modifiers.includes(cb.value)) cb.checked = true;
      });
    }
  } else if (type === "applescript") {
    applescriptDiv.classList.remove("hidden");
    scriptSelect.value = actionData.action;
  } else if (type === "socket") {
    socketDiv.classList.remove("hidden");
    socketInput.value = actionData.socketCommand;
  }

  // Handle action type dropdown change
  select.addEventListener("change", (e) => {
    const val = e.target.value;
    keystrokeDiv.classList.add("hidden");
    applescriptDiv.classList.add("hidden");
    socketDiv.classList.add("hidden");

    if (val === "keystroke") keystrokeDiv.classList.remove("hidden");
    else if (val === "applescript") applescriptDiv.classList.remove("hidden");
    else if (val === "socket") socketDiv.classList.remove("hidden");
  });

  setupKeyDetector(clone.querySelector(".keystroke-details"));

  container.appendChild(clone);
}

// 4. Save Controls Mapping State
function getActionFromFields(targetId) {
  const container = document.getElementById(`fields-${targetId}`);
  if (!container || container.innerHTML === "") return null;

  const select = container.querySelector(".action-type-select");
  if (!select) return null;

  const val = select.value;
  const midiMatch = container.dataset.midiMatch;

  if (val === "none") {
    return null;
  } else if (val === "keystroke") {
    const keyCode = parseInt(container.querySelector(".keystroke-details .action-keycode").value);
    if (isNaN(keyCode)) return null;

    const modifiers = [];
    container.querySelectorAll(".keystroke-details .action-mod:checked").forEach(cb => {
      modifiers.push(cb.value);
    });

    const action = { midiMatch, keyCode };
    if (modifiers.length > 0) action.modifiers = modifiers;
    return action;
  } else if (val === "applescript") {
    const script = container.querySelector(".action-script-select").value;
    if (!script) return null;

    return { midiMatch, action: script };
  } else if (val === "socket") {
    const socketCommand = container.querySelector(".socket-details .action-socket-command").value.trim();
    if (!socketCommand) return null;

    return { midiMatch, socketCommand };
  }

  return null;
}

function saveControlSettings() {
  if (!selectedControl || !currentConfig) return;

  const type = selectedControl.type;

  // Read comments & default values
  const comment = document.getElementById("control-custom-comment").value || selectedControl.comment || (selectedControl.data && selectedControl.data.comment);
  let defaultValue = null;
  if (type === 'knob' || type === 'wheel') {
    const defInput = document.getElementById("knob-default-value").value;
    if (defInput !== "") defaultValue = parseFloat(defInput);
  }

  const hw = HARDWARE_CONTROLS[selectedControl.svgId];

  if (type === 'customModeButton') {
    const baseNote = getControlBaseMidiNote(selectedControl.data) || "75";
    currentConfig.customModeButton = {
      comment: comment || undefined,
      press: getActionFromFields("normal-press") || { midiMatch: `90 ${baseNote} 40` },
      release: getActionFromFields("normal-release") || { midiMatch: `80 ${baseNote} 40` }
    };
  } else if (type === 'wheel') {
    // Save to the active wheel mode (Hue, Sat, or Lum)
    const wheelObj = selectedControl.data.find(k => k.comment && k.comment.includes(" - " + currentWheelMode));
    if (wheelObj) {
      const idx = currentConfig.knobs.indexOf(wheelObj);
      if (idx !== -1) {
        const baseNote = getControlBaseMidiNote(wheelObj) || "00";
        currentConfig.knobs[idx] = {
          comment: wheelObj.comment,
          default: defaultValue !== null ? defaultValue : undefined,
          press: getActionFromFields("normal-press") || { midiMatch: `80 ${baseNote} 40` },
          release: getActionFromFields("normal-release") || { midiMatch: `80 ${baseNote} 40` },
          plus: getActionFromFields("normal-plus") || { midiMatch: `B0 ${baseNote} 01` },
          minus: getActionFromFields("normal-minus") || { midiMatch: `B0 ${baseNote} 7F` },
          cm_press: getActionFromFields("cm-press") || undefined,
          cm_release: getActionFromFields("cm-release") || undefined,
          cm_plus: getActionFromFields("cm-plus") || undefined,
          cm_minus: getActionFromFields("cm-minus") || undefined,
          fn_press: getActionFromFields("fn-press") || undefined,
          fn_release: getActionFromFields("fn-release") || undefined,
          fn_plus: getActionFromFields("fn-plus") || undefined,
          fn_minus: getActionFromFields("fn-minus") || undefined,
          cm_fn_press: getActionFromFields("cm-fn-press") || undefined,
          cm_fn_release: getActionFromFields("cm-fn-release") || undefined,
          cm_fn_plus: getActionFromFields("cm-fn-plus") || undefined,
          cm_fn_minus: getActionFromFields("cm-fn-minus") || undefined
        };
      }
    }
  } else if (type === 'knob') {
    const originalKnob = selectedControl.data;
    const idx = currentConfig.knobs.indexOf(originalKnob);

    const baseNote = getControlBaseMidiNote(originalKnob) || (hw ? hw.baseNote : "00");
    const pressStatus = (hw && hw.press) ? hw.press.split(' ')[0] : '80';

    const updatedKnob = {
      comment: comment || undefined,
      default: defaultValue !== null ? defaultValue : undefined,
      press: getActionFromFields("normal-press") || { midiMatch: `${pressStatus} ${baseNote} 40` },
      release: getActionFromFields("normal-release") || { midiMatch: `80 ${baseNote} 40` },
      plus: getActionFromFields("normal-plus") || { midiMatch: `B0 ${baseNote} 01` },
      minus: getActionFromFields("normal-minus") || { midiMatch: `B0 ${baseNote} 7F` },
      cm_press: getActionFromFields("cm-press") || undefined,
      cm_release: getActionFromFields("cm-release") || undefined,
      cm_plus: getActionFromFields("cm-plus") || undefined,
      cm_minus: getActionFromFields("cm-minus") || undefined,
      fn_press: getActionFromFields("fn-press") || undefined,
      fn_release: getActionFromFields("fn-release") || undefined,
      fn_plus: getActionFromFields("fn-plus") || undefined,
      fn_minus: getActionFromFields("fn-minus") || undefined,
      cm_fn_press: getActionFromFields("cm-fn-press") || undefined,
      cm_fn_release: getActionFromFields("cm-fn-release") || undefined,
      cm_fn_plus: getActionFromFields("cm-fn-plus") || undefined,
      cm_fn_minus: getActionFromFields("cm-fn-minus") || undefined
    };

    if (idx !== -1) {
      currentConfig.knobs[idx] = updatedKnob;
    } else {
      currentConfig.knobs.push(updatedKnob);
    }
    // Update selection state reference
    selectedControl.data = updatedKnob;
  } else if (type === 'button') {
    const originalBtn = selectedControl.data;
    const idx = currentConfig.buttons.indexOf(originalBtn);

    const baseNote = getControlBaseMidiNote(originalBtn) || (hw && hw.press ? hw.press.split(' ')[1] : "00");

    const updatedBtn = {
      comment: comment || undefined,
      press: getActionFromFields("normal-press") || { midiMatch: `90 ${baseNote} 40` },
      release: getActionFromFields("normal-release") || { midiMatch: `80 ${baseNote} 40` },
      cm_press: getActionFromFields("cm-press") || undefined,
      cm_release: getActionFromFields("cm-release") || undefined,
      fn_press: getActionFromFields("fn-press") || undefined,
      fn_release: getActionFromFields("fn-release") || undefined,
      cm_fn_press: getActionFromFields("cm-fn-press") || undefined,
      cm_fn_release: getActionFromFields("cm-fn-release") || undefined
    };

    if (idx !== -1) {
      currentConfig.buttons[idx] = updatedBtn;
    } else {
      currentConfig.buttons.push(updatedBtn);
    }
    // Update selection state reference
    selectedControl.data = updatedBtn;
  }

  // Submit complete config save
  saveProfileToServer();
}

async function saveProfileToServer() {
  try {
    currentConfig.targetBundleIdentifier = document.getElementById("target-bundle-id").value;
    currentConfig.hotkeys = document.getElementById("chk-opt-hotkeys").checked;
    currentConfig.apple_script = document.getElementById("chk-opt-applescript").checked;
    currentConfig.lightroom_socket = document.getElementById("chk-opt-socket").checked;

    const res = await callSwift("saveConfig", {
      name: currentConfigName,
      content: JSON.stringify(currentConfig, null, 2)
    });

    if (res === "success") {
      showSaveIndicator();
      updateMappedVisuals();
    }
  } catch (err) {
    showErrorAlert("Error saving profile", err);
  }
}

function showSaveIndicator() {
  // Save happens silently in the background, no visual highlight or label change
}

// 5. Global Event Bindings & Profile Switchers
function setupEventListeners() {
  // Profiles selector dropdown
  document.getElementById("profile-select").addEventListener("change", async (e) => {
    currentConfigName = e.target.value;
    await loadProfile(currentConfigName);

    // Automatically set and apply the newly selected configuration if global override is false
    if (!globalOverride) {
      try {
        await callSwift("setActiveConfig", { name: currentConfigName, globalOverride: false });
        activeConfigName = currentConfigName;
      } catch (err) {
        console.error("Error setting active config automatically:", err);
      }
    }
  });

  // Target bundle changes
  document.getElementById("target-bundle-id").addEventListener("change", (e) => {
    if (currentConfig) {
      currentConfig.targetBundleIdentifier = e.target.value;
      saveProfileToServer();
    }
  });

  // Feature options changes
  document.getElementById("chk-opt-hotkeys").addEventListener("change", (e) => {
    if (currentConfig) {
      currentConfig.hotkeys = e.target.checked;
      saveProfileToServer();
      if (selectedControl) {
        renderEditorForms();
      }
    }
  });

  document.getElementById("chk-opt-applescript").addEventListener("change", (e) => {
    if (currentConfig) {
      currentConfig.apple_script = e.target.checked;
      saveProfileToServer();
      if (selectedControl) {
        renderEditorForms();
      }
    }
  });

  document.getElementById("chk-opt-socket").addEventListener("change", (e) => {
    if (currentConfig) {
      currentConfig.lightroom_socket = e.target.checked;
      saveProfileToServer();
      if (selectedControl) {
        renderEditorForms();
      }
    }
  });

  // Browse App bundle ID
  document.getElementById("btn-browse-app").addEventListener("click", async () => {
    try {
      const bundleID = await callSwift("browseApp");
      document.getElementById("target-bundle-id").value = bundleID;
      if (currentConfig) {
        currentConfig.targetBundleIdentifier = bundleID;
        saveProfileToServer();
      }
    } catch (err) {
      if (err.message !== "Cancelled") {
        showErrorAlert("Error browsing app", err);
      }
    }
  });

  // Global Override Switch
  document.getElementById("chk-global-override").addEventListener("change", async (e) => {
    try {
      globalOverride = e.target.checked;
      await callSwift("setActiveConfig", {
        name: currentConfigName,
        globalOverride: globalOverride
      });
      activeConfigName = currentConfigName;
      await loadProfile(currentConfigName);
    } catch (err) {
      showErrorAlert("Error setting global override", err);
    }
  });

  // Manage Profiles Button
  document.getElementById("btn-manage-profiles").addEventListener("click", () => {
    showPane("profile");
  });

  // Save button click
  document.getElementById("btn-save-control").addEventListener("click", () => {
    saveControlSettings();
  });

  // Autosave control settings on change inside editor
  document.getElementById("control-editor").addEventListener("change", () => {
    saveControlSettings();
  });

  // New Profile triggers
  const modal = document.getElementById("new-profile-modal");
  document.getElementById("btn-new-profile").addEventListener("click", () => {
    modal.classList.remove("hidden");
    document.getElementById("new-profile-name").value = "";
    document.getElementById("new-profile-name").focus();
  });

  document.getElementById("btn-modal-cancel").addEventListener("click", () => {
    modal.classList.add("hidden");
  });

  document.getElementById("btn-modal-create").addEventListener("click", async () => {
    const nameInput = document.getElementById("new-profile-name").value.trim();
    if (!nameInput) return;

    let profileName = nameInput;
    if (!profileName.toLowerCase().endsWith(".json")) {
      profileName += ".json";
    }

    try {
      const createdName = await callSwift("createConfig", { name: profileName });
      modal.classList.add("hidden");
      await refreshProfilesList();

      currentConfigName = createdName;
      document.getElementById("profile-select").value = currentConfigName;
      await loadProfile(currentConfigName);
    } catch (err) {
      showErrorAlert("Error creating profile", err);
    }
  });

  // Rename Profile triggers
  const renameModal = document.getElementById("rename-profile-modal");
  document.getElementById("btn-rename-profile").addEventListener("click", () => {
    const nameWithoutExt = currentConfigName.replace(/\.json$/i, "");
    document.getElementById("rename-profile-name").value = nameWithoutExt;
    renameModal.classList.remove("hidden");
    document.getElementById("rename-profile-name").focus();
  });

  document.getElementById("btn-rename-cancel").addEventListener("click", () => {
    renameModal.classList.add("hidden");
  });

  document.getElementById("btn-rename-save").addEventListener("click", async () => {
    const newNameInput = document.getElementById("rename-profile-name").value.trim();
    if (!newNameInput) return;

    try {
      const renamedName = await callSwift("renameConfig", { oldName: currentConfigName, newName: newNameInput });
      renameModal.classList.add("hidden");
      await refreshProfilesList();

      currentConfigName = renamedName;
      document.getElementById("profile-select").value = currentConfigName;
      await loadProfile(currentConfigName);
    } catch (err) {
      showErrorAlert("Error renaming profile", err);
    }
  });

  // Delete Profile trigger
  document.getElementById("btn-delete-profile").addEventListener("click", async () => {
    if (currentConfigName.toLowerCase() === "default.json") {
      alert("Cannot delete the default template profile.");
      return;
    }

    const isOverridingProfile = (globalOverride && currentConfigName === activeConfigName);
    let confirmed = false;
    if (isOverridingProfile) {
      confirmed = confirm(`Warning: The profile "${currentConfigName.replace(".json", "")}" is currently set to Apply Globally and overrides all other profiles.\n\nDeleting this profile will turn off global override mode and switch back to default.json.\n\nAre you sure you want to delete it?`);
    } else {
      confirmed = confirm(`Are you sure you want to delete the profile "${currentConfigName.replace(".json", "")}"? This action cannot be undone.`);
    }
    if (!confirmed) return;

    try {
      if (isOverridingProfile) {
        await callSwift("setActiveConfig", { name: "default.json", globalOverride: false });
        activeConfigName = "default.json";
        globalOverride = false;
      }

      await callSwift("deleteConfig", { name: currentConfigName });
      await refreshProfilesList();

      currentConfigName = "default.json";
      document.getElementById("profile-select").value = currentConfigName;
      await loadProfile(currentConfigName);
    } catch (err) {
      showErrorAlert("Error deleting profile", err);
    }
  });

  // About Modal Close
  document.getElementById("btn-about-close").addEventListener("click", () => {
    document.getElementById("about-modal").classList.add("hidden");
  });

  // Tab click bindings
  document.querySelectorAll(".tab-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      switchTab(btn.dataset.tab);
    });
  });
}

function switchTab(tabName) {
  document.querySelectorAll(".tab-btn").forEach(btn => {
    if (btn.dataset.tab === tabName) btn.classList.add("active");
    else btn.classList.remove("active");
  });

  document.querySelectorAll(".tab-content").forEach(content => {
    if (content.id === `tab-${tabName}`) content.classList.add("active");
    else content.classList.remove("active");
  });

  updateFoldStates();
}

function showPane(paneName) {
  const profilePane = document.getElementById("profile-settings-editor");
  const controlPane = document.getElementById("control-settings-editor");

  if (paneName === "profile") {
    // Save any current control mapping changes first!
    if (selectedControl) {
      saveControlSettings();
    }

    profilePane.classList.remove("hidden");
    controlPane.classList.add("hidden");

    // Clear selection styles on SVG
    selectedControl = null;
    document.querySelectorAll(".interactive-element").forEach(el => el.classList.remove("selected"));
  } else {
    profilePane.classList.add("hidden");
    controlPane.classList.remove("hidden");
  }
}

function updateFoldStates() {
  const activeTabPane = document.querySelector(".tab-content.active");
  if (!activeTabPane) return;

  const visibleGroups = Array.from(activeTabPane.querySelectorAll(".action-event-group")).filter(g => !g.classList.contains("hidden"));

  visibleGroups.forEach((g, idx) => {
    let header = g.querySelector(".action-group-header");
    let content = g.querySelector(".action-group-content");

    if (!header && !content) {
      const h4 = g.querySelector("h4");
      header = document.createElement("div");
      header.className = "action-group-header";

      if (h4) {
        header.appendChild(h4);
      }

      const icon = document.createElement("span");
      icon.className = "fold-icon";
      icon.innerText = "▼";
      header.appendChild(icon);

      content = document.createElement("div");
      content.className = "action-group-content";

      while (g.firstChild) {
        content.appendChild(g.firstChild);
      }

      g.appendChild(header);
      g.appendChild(content);

      header.addEventListener("click", () => {
        g.classList.toggle("collapsed");
      });
    }

    g.classList.remove("collapsed");
  });
}

async function refreshProfilesList() {
  const select = document.getElementById("profile-select");
  const files = await callSwift("getConfigs");

  select.innerHTML = "";
  files.forEach(f => {
    const opt = document.createElement("option");
    opt.value = f;
    opt.innerText = f.replace(".json", "");
    select.appendChild(opt);
  });
}

async function loadProfile(name) {
  try {
    const data = await callSwift("loadConfig", { name: name });
    currentConfig = (typeof data === 'string') ? JSON.parse(data) : data;

    // Clear selection
    selectedControl = null;
    document.querySelectorAll(".interactive-element").forEach(el => el.classList.remove("selected"));
    document.getElementById("no-control-selected").classList.remove("hidden");
    document.getElementById("no-control-selected").innerHTML = `<div class="empty-icon">🎛️</div><p>Click on any button or knob on the device layout to configure its actions.</p>`;
    document.getElementById("control-editor").classList.add("hidden");

    // Update global inputs
    document.getElementById("target-bundle-id").value = currentConfig.targetBundleIdentifier || "";
    document.getElementById("chk-opt-hotkeys").checked = (currentConfig.hotkeys !== false);
    document.getElementById("chk-opt-applescript").checked = (currentConfig.apple_script !== false);
    document.getElementById("chk-opt-socket").checked = (currentConfig.lightroom_socket === true);

    // Update global override UI
    const wrapper = document.getElementById("chk-global-override-wrapper");
    const otherOverride = document.getElementById("override-by-other-profile");
    const overridingNameSpan = document.getElementById("overriding-profile-name");

    if (globalOverride && name !== activeConfigName) {
      wrapper.classList.add("hidden");
      otherOverride.classList.remove("hidden");
      overridingNameSpan.innerText = activeConfigName.replace(".json", "");
    } else {
      wrapper.classList.remove("hidden");
      otherOverride.classList.add("hidden");
      document.getElementById("chk-global-override").checked = (globalOverride && name === activeConfigName);
    }

    // Enable/disable delete and rename actions for the current profile
    const isDefault = (name.toLowerCase() === "default.json");
    document.getElementById("btn-rename-profile").disabled = isDefault;
    document.getElementById("btn-delete-profile").disabled = isDefault;

    // Highlight mapped controls
    updateMappedVisuals();
  } catch (err) {
    showErrorAlert("Error loading profile (" + name + ")", err);
  }
}

function hasAction(actObj) {
  if (!actObj) return false;
  return !!(actObj.action || actObj.keyCode || actObj.socketCommand || actObj.applescript);
}

function isControlMapped(svgId) {
  const ctrl = findControlInConfig(svgId);
  if (!ctrl || !ctrl.data) return false;

  if (ctrl.type === 'wheel') {
    if (Array.isArray(ctrl.data)) {
      for (const w of ctrl.data) {
        if (hasAction(w.plus) || hasAction(w.minus) || hasAction(w.press) || hasAction(w.release) ||
          hasAction(w.cm_plus) || hasAction(w.cm_minus) || hasAction(w.cm_press) || hasAction(w.cm_release) ||
          hasAction(w.fn_plus) || hasAction(w.fn_minus) || hasAction(w.fn_press) || hasAction(w.fn_release) ||
          hasAction(w.fn_cm_plus) || hasAction(w.fn_cm_minus) || hasAction(w.fn_cm_press) || hasAction(w.fn_cm_release)) {
          return true;
        }
      }
    }
    return false;
  }

  const m = ctrl.data;
  return !!(
    hasAction(m.plus) || hasAction(m.minus) || hasAction(m.press) || hasAction(m.release) ||
    hasAction(m.cm_plus) || hasAction(m.cm_minus) || hasAction(m.cm_press) || hasAction(m.cm_release) ||
    hasAction(m.fn_plus) || hasAction(m.fn_minus) || hasAction(m.fn_press) || hasAction(m.fn_release) ||
    hasAction(m.fn_cm_plus) || hasAction(m.fn_cm_minus) || hasAction(m.fn_cm_press) || hasAction(m.fn_cm_release)
  );
}

function updateMappedVisuals() {
  const specialKeys = ["Custom-Mode", "Hue", "Sat", "Lum", "Fn"];
  document.querySelectorAll(".interactive-element").forEach(el => {
    const id = el.id;
    if (id) {
      if (specialKeys.includes(id)) {
        el.classList.remove("mapped");
      } else if (isControlMapped(id)) {
        el.classList.add("mapped");
      } else {
        el.classList.remove("mapped");
      }
    }
  });
}

window.handleProfileAutoSwitch = async function (profileName) {
  if (profileName !== currentConfigName) {
    currentConfigName = profileName;
    document.getElementById("profile-select").value = currentConfigName;
    await loadProfile(currentConfigName);
  }
};
