-- Vokoma engine experiment: measures open, frame-step, back-step and seek latency in mpv.
-- Usage: mpv --pause --script=bench.lua --script-opts=bench-out=FILE,bench-label=NAME <media>
local opts = { out = "bench.json", label = "", steps = 20, seeks = 10, timeout = 30, reverse = true }
require("mp.options").read_options(opts, "bench")
local utils = require "mp.utils"

local co, waiting, timer, expected_old
local function resume(kind, ...)
  if waiting == kind then
    waiting = nil
    if timer then timer:kill() timer = nil end
    local ok, err = coroutine.resume(co, true, ...)
    if not ok then mp.msg.error("bench failed: " .. tostring(err)) mp.commandv("quit", "3") end
  end
end
local function wait(kind)
  waiting = kind
  timer = mp.add_timeout(opts.timeout, function()
    if waiting == kind then
      waiting = nil
      local ok, err = coroutine.resume(co, false)
      if not ok then mp.msg.error("bench failed: " .. tostring(err)) mp.commandv("quit", "3") end
    end
  end)
  return coroutine.yield()
end
mp.register_event("playback-restart", function() resume("restart") end)
mp.observe_property("time-pos", "number", function(_, v)
  -- Ignore notifications that repeat the position held before the command was sent.
  if v and (not expected_old or math.abs(v - expected_old) > 0.000001) then resume("timepos", v) end
end)

local function stats(t)
  local s = {}
  for _, v in ipairs(t) do s[#s + 1] = v end
  table.sort(s)
  if #s == 0 then return { n = 0 } end
  local function q(p) return s[math.max(1, math.min(#s, math.floor(p * (#s - 1) + 1.5)))] end
  local r = function(x) return math.floor(x * 10 + 0.5) / 10 end
  return { n = #s, min = r(s[1]), med = r(q(0.5)), p90 = r(q(0.9)), max = r(s[#s]) }
end

-- Runs `cmd` n times; each completes on `kind`. Returns ms timings plus the positions reached.
local function measure(n, kind, cmd)
  local ms, pos, timeouts, streak = {}, {}, 0, 0
  for i = 1, n do
    expected_old = mp.get_property_number("time-pos")
    local t0 = mp.get_time()
    cmd(i)
    local ok = wait(kind)
    if ok then ms[#ms + 1] = (mp.get_time() - t0) * 1000 streak = 0 else timeouts = timeouts + 1 streak = streak + 1 end
    pos[#pos + 1] = mp.get_property_number("time-pos", -1)
    -- Give up on a test after 3 consecutive timeouts (a hung mode would otherwise cost n*timeout).
    if streak >= 3 then timeouts = timeouts + (n - i) break end
  end
  return ms, pos, timeouts
end

-- Counts steps whose position delta is not one frame (within 20%) in the expected direction.
local function bad_steps(start, pos, dir, frame)
  local bad, prev = 0, start
  for _, p in ipairs(pos) do
    local d = (p - prev) * dir
    if d < frame * 0.8 or d > frame * 1.2 then bad = bad + 1 end
    prev = p
  end
  return bad
end

local function seek_exact(t)
  mp.commandv("seek", tostring(t), "absolute+exact")
  wait("restart")
end

local function run()
  local out = { label = opts.label, mpv = mp.get_property("mpv-version"), file = mp.get_property("filename") }
  local t_open = mp.get_time()
  wait("restart")
  out.open_ms = math.floor((mp.get_time() - t_open) * 1000)
  local dur = mp.get_property_number("duration", 0)
  local fps = mp.get_property_number("container-fps", 24)
  local frame = 1 / fps
  out.duration, out.fps = dur, fps
  out.hwdec = mp.get_property("hwdec-current", "")
  out.vcodec = mp.get_property("video-codec", "")
  out.tests = {}
  local function add(name, ms, extra)
    local s = stats(ms)
    for k, v in pairs(extra or {}) do s[k] = v end
    out.tests[name] = s
    mp.msg.info(name .. " " .. utils.format_json(s))
  end

  local ms, pos, to, start, t0, ok
  -- Frame stepping at two places: mid-file, and near the end of a long keyframe gap if any.
  for idx, frac in ipairs({ 0.31, 0.62 }) do
    seek_exact(dur * frac)
    start = mp.get_property_number("time-pos")
    ms, pos, to = measure(opts.steps, "timepos", function() mp.commandv("frame-step") end)
    add("fwd_step_" .. idx, ms, { timeouts = to, bad = bad_steps(start, pos, 1, frame) })
    start = mp.get_property_number("time-pos")
    ms, pos, to = measure(opts.steps, "restart", function() mp.commandv("frame-back-step") end)
    add("back_step_" .. idx, ms, { timeouts = to, bad = bad_steps(start, pos, -1, frame) })
  end

  -- Alternative back step: backward play direction keeps a decoded-frame reversal buffer.
  -- bench-reverse=no skips this block to isolate whether it causes later hangs.
  if opts.reverse then
  seek_exact(dur * 0.45)
  t0 = mp.get_time()
  mp.set_property("play-direction", "backward")
  ok = wait("restart")
  out.tests.reverse_enter_ms = ok and math.floor((mp.get_time() - t0) * 1000) or -1
  start = mp.get_property_number("time-pos")
  ms, pos, to = measure(opts.steps * 3, "timepos", function() mp.commandv("frame-step") end)
  add("reverse_step", ms, { timeouts = to, bad = bad_steps(start, pos, -1, frame) })
  t0 = mp.get_time()
  mp.set_property("play-direction", "forward")
  ok = wait("restart")
  out.tests.reverse_leave_ms = ok and math.floor((mp.get_time() - t0) * 1000) or -1
  end

  -- Long seeks to scattered positions (cold cache), keyframe then exact.
  local function scattered(i) return dur * (((i * 0.6180339887) % 1) * 0.9 + 0.05) end
  ms, pos, to = measure(opts.seeks, "restart", function(i)
    mp.commandv("seek", tostring(scattered(i)), "absolute+keyframes") end)
  add("seek_far_keyframe", ms, { timeouts = to })
  ms, pos, to = measure(opts.seeks, "restart", function(i)
    mp.commandv("seek", tostring(scattered(i + 100)), "absolute+exact") end)
  add("seek_far_exact", ms, { timeouts = to })

  -- Arrow-key style short seeks around one spot.
  seek_exact(dur * 0.5)
  ms, pos, to = measure(opts.seeks, "restart", function() mp.commandv("seek", "5", "relative+exact") end)
  add("seek_fwd5_exact", ms, { timeouts = to })
  ms, pos, to = measure(opts.seeks, "restart", function() mp.commandv("seek", "-5", "relative+exact") end)
  add("seek_back5_exact", ms, { timeouts = to })
  ms, pos, to = measure(opts.seeks, "restart", function() mp.commandv("seek", "-5", "relative+keyframes") end)
  add("seek_back5_keyframe", ms, { timeouts = to })

  local f = assert(io.open(opts.out, "a"))
  f:write(utils.format_json(out) .. "\n")
  f:close()
  mp.commandv("quit")
end

co = coroutine.create(run)
mp.register_event("file-loaded", function()
  if coroutine.status(co) == "suspended" and not waiting then coroutine.resume(co) end
end)
