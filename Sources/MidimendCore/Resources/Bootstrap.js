"use strict";
//
// Midimend bootstrap: the script-facing API layer (event classes +
// MIDI utility object). API-compatible with the Scripter MIDI plug-in in
// Logic Pro/MainStage, written from public documentation and observed
// behavior. Contains no Apple code.
//
// Host-provided natives, installed before this file is evaluated:
//   SendMIDIEventNow(event), SendMIDIEventAfterMilliseconds(event, ms),
//   SendMIDIEventAtBeat(event, beat), SendMIDIEventAfterBeats(event, beats),
//   Trace(value), GetParameter(key), SetParameter(key, value),
//   GetTimingInfo(), UpdatePluginParameters(), _HostWarnOnce(message)

class Event {
  constructor(other) {
    this.status = 0;
    this.channel = 1;
    this.data1 = 0;
    this.data2 = 0;
    this.data3 = 0;
    this.port = 1;
    this.articulationID = 0;
    this.isRealtime = true;
    this.beatPos = 0;
    if (other instanceof Event) {
      this.status = other.status;
      this.channel = other.channel;
      this.data1 = other.data1;
      this.data2 = other.data2;
      this.data3 = other.data3;
      this.port = other.port;
      this.articulationID = other.articulationID;
      this.isRealtime = other.isRealtime;
      this.beatPos = other.beatPos;
    }
  }
  send() { SendMIDIEventNow(this); }
  sendAfterMilliseconds(ms) { SendMIDIEventAfterMilliseconds(this, Number(ms)); }
  sendAtBeat(beat) { SendMIDIEventAtBeat(this, Number(beat)); }
  sendAfterBeats(beats) { SendMIDIEventAfterBeats(this, Number(beats)); }
  trace() { Trace(this.toString()); }
  className() { return this.constructor.name; }
  toString() {
    return this.className() + " status:" + this.status + " channel:" + this.channel
      + " data1:" + this.data1 + " data2:" + this.data2;
  }
}

class Note extends Event {
  constructor(other) {
    super(other);
    this.detune = (other instanceof Event && typeof other.detune === "number") ? other.detune : 0;
  }
  get pitch() { return this.data1; }
  set pitch(v) { this.data1 = v; }
  get velocity() { return this.data2; }
  set velocity(v) { this.data2 = v; }
}

class NoteOn extends Note {
  constructor(other) {
    super(other);
    this.status = 144;
  }
  toString() {
    return "NoteOn channel:" + this.channel + " pitch:" + this.pitch
      + " [" + MIDI.noteName(this.pitch) + "] velocity:" + this.velocity;
  }
}

class NoteOff extends Note {
  constructor(other) {
    super(other);
    this.status = 128;
  }
  toString() {
    return "NoteOff channel:" + this.channel + " pitch:" + this.pitch
      + " [" + MIDI.noteName(this.pitch) + "] velocity:" + this.velocity;
  }
}

class PolyPressure extends Event {
  constructor(other) {
    super(other);
    this.status = 160;
  }
  get pitch() { return this.data1; }
  set pitch(v) { this.data1 = v; }
  get value() { return this.data2; }
  set value(v) { this.data2 = v; }
  toString() {
    return "PolyPressure channel:" + this.channel + " pitch:" + this.pitch
      + " [" + MIDI.noteName(this.pitch) + "] value:" + this.value;
  }
}

class ControlChange extends Event {
  constructor(other) {
    super(other);
    this.status = 176;
  }
  get number() { return this.data1; }
  set number(v) { this.data1 = v; }
  get value() { return this.data2; }
  set value(v) { this.data2 = v; }
  toString() {
    return "ControlChange channel:" + this.channel + " number:" + this.number
      + " [" + MIDI.ccName(this.number) + "] value:" + this.value;
  }
}

class ProgramChange extends Event {
  constructor(other) {
    super(other);
    this.status = 192;
  }
  get number() { return this.data1; }
  set number(v) { this.data1 = v; }
  toString() {
    return "ProgramChange channel:" + this.channel + " number:" + this.number;
  }
}

class ChannelPressure extends Event {
  constructor(other) {
    super(other);
    this.status = 208;
  }
  get value() { return this.data1; }
  set value(v) { this.data1 = v; }
  toString() {
    return "ChannelPressure channel:" + this.channel + " value:" + this.value;
  }
}

class PitchBend extends Event {
  constructor(other) {
    super(other);
    this.status = 224;
    if (!(other instanceof Event)) this.value = 0;
  }
  get value() { return ((this.data2 << 7) | this.data1) - 8192; }
  set value(v) {
    let raw = Math.round(Number(v)) + 8192;
    if (raw < 0) raw = 0;
    if (raw > 16383) raw = 16383;
    this.data1 = raw & 127;
    this.data2 = raw >> 7;
  }
  toString() {
    return "PitchBend channel:" + this.channel + " value:" + this.value;
  }
}

// TargetEvent addresses a `type:"target"` parameter (a MIDI CC or another
// plug-in's parameter on the same channel strip). There is no host plug-in
// chain here, so v0 drops these with a warning.
class TargetEvent extends Event {
  constructor(other) {
    super(other);
    this.target = (other instanceof TargetEvent) ? other.target : "";
    this.value = (other instanceof TargetEvent) ? other.value : 0;
  }
  send() {
    _HostWarnOnce("TargetEvent is not supported in Midimend v0; event dropped.");
  }
  toString() {
    return "TargetEvent target:'" + this.target + "' value:" + this.value;
  }
}

const MIDI = {
  _noteNames: Object.freeze((function () {
    const chroma = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
    const out = [];
    for (let i = 0; i < 128; i++) out.push(chroma[i % 12] + (Math.floor(i / 12) - 2));
    return out;
  })()),

  // Standard MIDI 1.0 controller names; unassigned numbers fall back to
  // "Controller <n>". (Names may differ slightly from Logic's own table.)
  _ccNames: Object.freeze((function () {
    const named = {
      0: "Bank MSB", 1: "Modulation", 2: "Breath", 4: "Foot Control",
      5: "Portamento Time", 6: "Data MSB", 7: "Volume", 8: "Balance",
      10: "Pan", 11: "Expression", 12: "Effect Control 1", 13: "Effect Control 2",
      16: "General Purpose 1", 17: "General Purpose 2", 18: "General Purpose 3",
      19: "General Purpose 4", 32: "Bank LSB", 38: "Data LSB",
      64: "Sustain", 65: "Portamento", 66: "Sostenuto", 67: "Soft Pedal",
      68: "Legato", 69: "Hold 2", 70: "Sound Variation", 71: "Resonance",
      72: "Release Time", 73: "Attack Time", 74: "Brightness",
      75: "Sound Control 6", 76: "Sound Control 7", 77: "Sound Control 8",
      78: "Sound Control 9", 79: "Sound Control 10",
      80: "General Purpose 5", 81: "General Purpose 6", 82: "General Purpose 7",
      83: "General Purpose 8", 84: "Portamento Control",
      91: "Reverb", 92: "Tremolo", 93: "Chorus", 94: "Detune", 95: "Phaser",
      96: "Data Increment", 97: "Data Decrement",
      98: "NRPN LSB", 99: "NRPN MSB", 100: "RPN LSB", 101: "RPN MSB",
      120: "All Sound Off", 121: "Reset All Controllers", 122: "Local Control",
      123: "All Notes Off", 124: "Omni Mode Off", 125: "Omni Mode On",
      126: "Mono Mode On", 127: "Poly Mode On",
    };
    const out = [];
    for (let i = 0; i < 128; i++) out.push(named[i] || ("Controller " + i));
    return out;
  })()),

  noteNumber(name) {
    return this._noteNames.indexOf(String(name).toUpperCase());
  },
  noteName(number) {
    const n = parseInt(number);
    return (n >= 0 && n <= 127) ? this._noteNames[n] : "?";
  },
  ccName(number) {
    const n = parseInt(number);
    return (n >= 0 && n <= 127) ? this._ccNames[n] : "?";
  },
  allNotesOff() {
    const e = new ControlChange();
    e.number = 123;
    e.value = 0;
    this._sendEventOnAllChannels(e);
  },
  _sendEventOnAllChannels(e) {
    for (let ch = 1; ch <= 16; ch++) {
      e.channel = ch;
      e.send();
    }
  },
  normalizeStatus(value) {
    const v = parseInt(value);
    if (isNaN(v)) return 128;
    return Math.min(239, Math.max(128, v));
  },
  normalizeChannel(value) {
    const v = parseInt(value);
    if (isNaN(v)) return 1;
    return Math.min(16, Math.max(1, v));
  },
  normalizeData(value) {
    const v = parseInt(value);
    if (isNaN(v)) return 0;
    return Math.min(127, Math.max(0, v));
  },
};

// Called by the host for every incoming channel-voice message.
// A per-type handler wins over HandleMIDI; with neither defined, events pass
// through unmodified.
function _dispatchMIDIEvent(statusByte, d1, d2, port) {
  const type = statusByte & 0xF0;
  let e;
  switch (type) {
    case 0x80: e = new NoteOff(); break;
    case 0x90: e = new NoteOn(); break;
    case 0xA0: e = new PolyPressure(); break;
    case 0xB0: e = new ControlChange(); break;
    case 0xC0: e = new ProgramChange(); break;
    case 0xD0: e = new ChannelPressure(); break;
    case 0xE0: e = new PitchBend(); break;
    default: return;
  }
  e.channel = (statusByte & 0x0F) + 1;
  e.data1 = d1;
  e.data2 = d2;
  e.port = port;

  let handled = false;
  switch (type) {
    case 0x80:
    case 0x90:
      if (typeof HandleNote === "function") { HandleNote(e); handled = true; }
      break;
    case 0xA0:
      if (typeof HandlePolyPressure === "function") { HandlePolyPressure(e); handled = true; }
      break;
    case 0xB0:
      if (typeof HandleControlChange === "function") { HandleControlChange(e); handled = true; }
      break;
    case 0xC0:
      if (typeof HandleProgramChange === "function") { HandleProgramChange(e); handled = true; }
      break;
    case 0xD0:
      if (typeof HandleChannelPressure === "function") { HandleChannelPressure(e); handled = true; }
      break;
    case 0xE0:
      if (typeof HandlePitchBend === "function") { HandlePitchBend(e); handled = true; }
      break;
  }
  if (!handled) {
    if (typeof HandleMIDI === "function") HandleMIDI(e);
    else e.send();
  }
}

// Called by the host after the user script was evaluated; resolves callbacks
// that may be lexically declared (const/let) and thus invisible as globals.
function _resolveUserCallback(name) {
  switch (name) {
    case "ParameterChanged": return (typeof ParameterChanged === "function") ? ParameterChanged : undefined;
    case "Idle": return (typeof Idle === "function") ? Idle : undefined;
    case "Reset": return (typeof Reset === "function") ? Reset : undefined;
    default: return undefined;
  }
}

function _resolvePluginParameters() {
  return (typeof PluginParameters !== "undefined") ? PluginParameters : undefined;
}

function _resolveNeedsTimingInfo() {
  return (typeof NeedsTimingInfo !== "undefined") ? !!NeedsTimingInfo : false;
}
