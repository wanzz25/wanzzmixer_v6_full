--[[
╔══════════════════════════════════════════════════════════════════╗
║   WANZZMIXER V6 — PEARL 1024B + ART-NET BRIDGE EDITION          ║
║   by wanzzmanusia                                                ║
╠══════════════════════════════════════════════════════════════════╣
║  MANUAL MODE : Mixer internal (fader, shape, chase, cue)         ║
║  BRIDGE MODE : Terima data Art-Net dari server.py + artnet2WSS   ║
╠══════════════════════════════════════════════════════════════════╣
║  Cara pakai Bridge Mode:                                         ║
║   1. Jalankan server.py dan artnet2WSS.py di PC                  ║
║   2. Masuk game, execute WanzzMixer_V6.lua ini                   ║
║   3. Klik "BRIDGE MODE" di header → lampu ikut konsol Art-Net    ║
╚══════════════════════════════════════════════════════════════════╝
]]

if _G.WANZZMIXER and _G.WANZZMIXER.stop then pcall(_G.WANZZMIXER.stop) end
if type(_G.DMXBridgeStop) == "function" then pcall(_G.DMXBridgeStop) end

-- ──────────────────────────────────────────────
-- SERVICES
-- ──────────────────────────────────────────────
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local UIS          = game:GetService("UserInputService")
local HttpService  = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local LP           = Players.LocalPlayer

local floor, sin, cos, abs, asin, pi, random =
  math.floor, math.sin, math.cos, math.abs, math.asin, math.pi, math.random
local function clamp(v,a,b) return v<a and a or v>b and b or v end
local function round(v)     return floor(v+0.5) end

-- ──────────────────────────────────────────────
-- BRIDGE CONFIG (dari Roblox_Script.lua)
-- ──────────────────────────────────────────────
local BRIDGE_URL       = "http://127.0.0.1:5311/polling"
local BRIDGE_INTERVAL  = 1/60
local BRIDGE_BACKLOG   = 6
local BRIDGE_MAX_UNIV  = 8

-- ──────────────────────────────────────────────
-- BEAM PROFILES
-- ──────────────────────────────────────────────
local BEAM_PROFILES = {
  R1 = { label="Rig A  Pan=Ch1  Tilt=Ch2  Dimmer=Ch3/6/7/8",
         map={pan=1, tilt=2, dimmer={3,6,7,8}, strobe=4, prisma=5} },
  R2 = { label="Rig B  Tilt=Ch1  Pan=Ch2  Dimmer=Ch3/6/7/8  (swap)",
         map={tilt=1, pan=2, dimmer={3,6,7,8}, strobe=4, prisma=5} },
  R3 = { label="Rig C  Dimmer=Ch1  Pan=Ch2  Tilt=Ch3",
         map={dimmer=1, pan=2, tilt=3, strobe=4, prisma=5} },
  R4 = { label="Standar 16ch  Pan=Ch1  Tilt=Ch3  Dimmer=Ch6",
         map={pan=1, tilt=3, dimmer=6, strobe=7, prisma=11} },
}

local MODELS = {
  {name="Clara S 14R",    ch=16, kind="beam",    map={}, fixed={}},
  {name="Strobe 1000W",   ch=8,  kind="strobe",  map={dimmer={1,2,3,4,5,6,7}, strobe=8}, fixed={}},
  {name="3x1 Apple Led",  ch=12, kind="led",     map={dimmer=1,r=2,g=3,b=4,strobe=5}, fixed={}},
  {name="Parled",         ch=6,  kind="par",     map={dimmer=1,r=2,g=3,b=4,strobe=5}, fixed={}},
  {name="Fogger 3000W",   ch=1,  kind="fog",     map={dimmer=1}, fixed={}},
  {name="Blinder 4x100",  ch=4,  kind="blinder", map={dimmer={1,2,3,4}}, fixed={}},
  {name="Flower 300W",    ch=8,  kind="led",     map={dimmer=1,r=2,g=3,b=4,strobe=5}, fixed={}},
}

local PEARL_PT_SHAPES  = {"OFF","Circle","Figure 8","Pan Saw","Tilt Saw","Pan Sin","Tilt Sin","Swing","CanCan","Line Diag","Box Square","Fan Spread"}
local PEARL_DIM_SHAPES = {"OFF","Dim Spread","Pulse 1:1","Pulse 2:1","Pulse 1:2","Chase Odd/Even","Random Flash"}

-- ──────────────────────────────────────────────
-- STATE GLOBAL
-- ──────────────────────────────────────────────
local S = {
  mode="MANUAL",        -- "MANUAL" | "BRIDGE"
  master=100, blackout=false,
  beamProfile="R1",

  ptShape="OFF", panCenter=128, tiltCenter=128,
  panSize=75,   tiltSize=75,   ptSpeed=0.45,
  ptSpread=25,  ptRepeat=0,    ptDir=1,
  mirrorPan=false, invertOddTilt=false, ptPhase=0,

  dimShape="OFF", dimSpeed=0.90, dimSpread=60, dimRepeat=2, dimSize=255, dimPhase=0,

  singleSelectPro=false,
  chaseSteps={}, chasePlay=false, chaseBpm=90, chaseCross=50, chaseIdx=1, chaseT=0,
  cues={}, cuePage=1, cueSel=nil,
  model=1, labelDmx=false, layoutMode="2baris", scale=1,
  test={on=false, ch=1, val=255, autoScan=false, scanTimer=0},

  -- Bridge state
  bridgeConn=false, bridgeFrames=0, bridgeFail=0, bridgeMsg="Belum terhubung",
  car=false, running=true, tab="Fixture",
}

-- Bridge internal queues
local bridgeQueues  = {}  -- [universe] = { buffer512, ... }
local bridgeLast    = {}  -- [universe] = timestamp

local fixtures = {}
local conns    = {}
local UI       = {}
local remote   = nil
local activeSlider = nil
local lastClick    = 0
local FILE         = "wanzzmixer_v6.json"
local saves        = {}
local SEND_HZ      = 40

local function canClick()
  local n=os.clock(); if n-lastClick<0.06 then return false end
  lastClick=n; return true
end

-- ──────────────────────────────────────────────
-- PROFILE APPLY
-- ──────────────────────────────────────────────
local function applyBeamProfile(k)
  local p = BEAM_PROFILES[k] or BEAM_PROFILES.R1
  S.beamProfile = k
  MODELS[1].map = {}
  for a,v in pairs(p.map) do MODELS[1].map[a]=v end
end
applyBeamProfile("R1")

-- ──────────────────────────────────────────────
-- FIXTURE HELPERS
-- ──────────────────────────────────────────────
local function newFixture(mi, dmx)
  return {
    model=MODELS[mi], mi=mi, id=#fixtures+1, dmx=dmx, sel=true,
    panBase=128, tiltBase=128, dimBase=255, strobeBase=0, prismaBase=0,
    r=255, g=255, b=255,
    pan=128, tilt=128, strobe=0, prisma=0, dimOut=255, chase=nil
  }
end
local function clearFixtures() fixtures={} end
local function autoPatch()
  local addr=1
  for _,f in ipairs(fixtures) do
    local n=f.model.ch
    local su=floor((addr-1)/512); local eu=floor((addr+n-2)/512)
    if su~=eu then addr=(su+1)*512+1 end
    f.dmx=addr; addr=addr+n
  end
end

-- ──────────────────────────────────────────────
-- SHAPE ENGINE
-- ──────────────────────────────────────────────
local function triWave(r) return (2/pi)*asin(sin(r)) end
local function sqWave(r)  return clamp(sin(r)*3,-1,1) end

local function calcPT(shape, idx0, total, base)
  local half=(total-1)/2; local norm=(total>1) and ((idx0-half)/half) or 0
  local isRight=(idx0>=total/2); local isOdd=((idx0%2)==1)
  local eff=idx0; if S.ptRepeat>0 then eff=idx0%S.ptRepeat end
  local ph=base+(eff*S.ptSpread)*(pi/180)
  local dx,dy=0,0
  if     shape=="Circle"    then dx=sin(ph);         dy=cos(ph)
  elseif shape=="Figure 8"  then dx=sin(ph);         dy=sin(ph*2)
  elseif shape=="Pan Saw"   then dx=triWave(ph);     dy=0
  elseif shape=="Tilt Saw"  then dx=0;               dy=triWave(ph)
  elseif shape=="Pan Sin"   then dx=sin(ph);         dy=0
  elseif shape=="Tilt Sin"  then dx=0;               dy=sin(ph)
  elseif shape=="Swing"     then dx=sin(ph);         dy=cos(ph*2)*0.6
  elseif shape=="CanCan"    then dx=sin(ph*0.5)*0.35;dy=sin(ph)
  elseif shape=="Line Diag" then dx=sin(ph);         dy=sin(ph)
  elseif shape=="Box Square" then dx=sqWave(ph);     dy=sqWave(ph+pi/2)
  elseif shape=="Fan Spread" then dx=norm*sin(base); dy=cos(ph)
  end
  if S.mirrorPan and isRight then dx=-dx end
  if S.invertOddTilt and isOdd then dy=-dy end
  return dx*S.panSize, dy*S.tiltSize
end

local function calcDim(shape, idx0, base)
  if shape=="OFF" then return 1 end
  local eff=idx0; if S.dimRepeat>0 then eff=idx0%S.dimRepeat end
  local ph=base+(eff*S.dimSpread)*(pi/180)
  local cyc=(ph/(2*pi))%1
  local mod=1
  if     shape=="Dim Spread"    then mod=sin(ph)*0.5+0.5
  elseif shape=="Pulse 1:1"     then mod=(cyc<0.5) and 1 or 0
  elseif shape=="Pulse 2:1"     then mod=(cyc<0.66) and 1 or 0
  elseif shape=="Pulse 1:2"     then mod=(cyc<0.33) and 1 or 0
  elseif shape=="Chase Odd/Even" then
    local odd=(idx0%2==0); local half2=(base/pi)%2<1
    mod=(half2==odd) and 1 or 0
  elseif shape=="Random Flash"  then mod=(sin(base*7.3+idx0*4.1)>0.35) and 1 or 0
  end
  return 1-clamp(S.dimSize/255,0,1)*(1-mod)
end

local function stepEffects(dt)
  if #fixtures==0 then return end
  if S.test.on and S.test.autoScan then
    S.test.scanTimer=S.test.scanTimer+dt
    if S.test.scanTimer>=1.2 then
      S.test.scanTimer=0; S.test.ch=S.test.ch%16+1
      if UI.refreshTest then UI.refreshTest() end
    end
  end
  local dirf=S.ptDir
  if S.ptDir==0 then dirf=(sin(S.ptPhase*0.25)>=0) and 1 or -1 end
  if S.ptShape~="OFF" then S.ptPhase=S.ptPhase+(S.ptSpeed*2*pi)*dirf*dt end
  if S.dimShape~="OFF" then S.dimPhase=S.dimPhase+(S.dimSpeed*2*pi)*dt end

  local selBeams={}
  for _,f in ipairs(fixtures) do
    f.pan=f.panBase; f.tilt=f.tiltBase; f.strobe=f.strobeBase; f.prisma=f.prismaBase
    if f.sel and f.model.kind=="beam" then selBeams[#selBeams+1]=f end
  end
  if S.ptShape~="OFF" and #selBeams>0 then
    for i,f in ipairs(selBeams) do
      local ox,oy=calcPT(S.ptShape,i-1,#selBeams,S.ptPhase)
      f.pan=clamp(round(f.panBase+ox),0,255)
      f.tilt=clamp(round(f.tiltBase+oy),0,255)
    end
  end

  local chOn=S.chasePlay and #S.chaseSteps>0
  if chOn then
    local dur=60/math.max(1,S.chaseBpm)
    S.chaseT=S.chaseT+dt
    while S.chaseT>=dur do S.chaseT=S.chaseT-dur; S.chaseIdx=S.chaseIdx%#S.chaseSteps+1 end
    local a=S.chaseSteps[S.chaseIdx]; local b=S.chaseSteps[S.chaseIdx%#S.chaseSteps+1]
    local cross=clamp(S.chaseCross/100,0,1)
    local u=(cross<=0) and 0 or clamp((S.chaseT/dur-(1-cross))/cross,0,1)
    for _,f in ipairs(fixtures) do
      local sa,sb=a[f.id],b[f.id]
      if sa and sb then
        f.pan=sa.pan+(sb.pan-sa.pan)*u; f.tilt=sa.tilt+(sb.tilt-sa.tilt)*u
        f.strobe=sa.strobe+(sb.strobe-sa.strobe)*u; f.chase=sa.dim+(sb.dim-sa.dim)*u
      end
    end
  else for _,f in ipairs(fixtures) do f.chase=nil end end

  local si=0
  for _,f in ipairs(fixtures) do
    local base=f.chase or f.dimBase; local mult=1
    if S.dimShape~="OFF" and f.sel and f.model.kind~="fog" then
      si=si+1; mult=calcDim(S.dimShape,si-1,S.dimPhase)
    end
    f.dimOut=S.blackout and 0 or base*mult
  end
end

-- ──────────────────────────────────────────────
-- DMX OUTPUT — MANUAL MODE
-- ──────────────────────────────────────────────
local function outVal(f, param)
  local eff=clamp(round(f.dimOut*(S.master/100)),0,255)
  if     param=="dimmer" then return eff
  elseif param=="pan"    then return f.pan
  elseif param=="tilt"   then return f.tilt
  elseif param=="strobe" then return f.strobe
  elseif param=="prisma" then return f.prisma
  elseif param=="r"      then return f.r
  elseif param=="g"      then return f.g
  elseif param=="b"      then return f.b
  end
  return nil
end

local function buildFrame()
  local U={}
  local function put(abs_, v)
    if abs_<1 or abs_>4096 then return end
    local u=floor((abs_-1)/512)+1; local c=(abs_-1)%512+1
    local t=U[u]; if not t then t={}; U[u]=t end
    t[c]=clamp(round(v),0,255)
  end
  for _,f in ipairs(fixtures) do
    for ch,val in pairs(f.model.fixed) do put(f.dmx+tonumber(ch)-1,val) end
    for param,chs in pairs(f.model.map) do
      local v=outVal(f,param)
      if v~=nil then
        if type(chs)=="table" then for _,c in ipairs(chs) do put(f.dmx+c-1,v) end
        else put(f.dmx+chs-1,v) end
      end
    end
    if S.test.on and f.sel and f.mi==S.model and S.test.ch<=f.model.ch then
      put(f.dmx+S.test.ch-1,S.test.val)
    end
  end
  return U
end

-- ──────────────────────────────────────────────
-- BRIDGE — INCOMING FRAME PROCESSING
-- ──────────────────────────────────────────────
local function validUniv(raw)
  local u=tonumber(raw)
  if u and u>=1 and u<=BRIDGE_MAX_UNIV and u==floor(u) then return u end
end

local function sortFrameKeys(t)
  local k={}
  for key in pairs(t) do if type(key)=="string" and tonumber(key:sub(2)) then k[#k+1]=key end end
  table.sort(k,function(a,b) return tonumber(a:sub(2))<tonumber(b:sub(2)) end)
  return k
end

local function makeDmxBuffer(ch_table)
  local buf=buffer.create(512)
  for ch,val in pairs(ch_table) do
    local c,v=tonumber(ch),tonumber(val)
    if c and v and c>=1 and c<=512 then buffer.writeu8(buf,c-1,clamp(floor(v),0,255)) end
  end
  return buf
end

local function enqueueBridgeFrames(universes)
  for rawU, frames in pairs(universes) do
    local u=validUniv(rawU)
    if u and type(frames)=="table" then
      local q=bridgeQueues[u]; if not q then q={}; bridgeQueues[u]=q end
      for _,fk in ipairs(sortFrameKeys(frames)) do
        local fr=frames[fk]
        if type(fr)=="table" and type(fr.channels)=="table" then
          q[#q+1]=makeDmxBuffer(fr.channels)
          while #q>BRIDGE_BACKLOG do table.remove(q,1) end
        end
      end
    end
  end
end

-- ──────────────────────────────────────────────
-- FIND REMOTE
-- ──────────────────────────────────────────────
local function findRemote()
  local ok,r=pcall(function()
    local v=workspace:FindFirstChild("Vehicles")
    local car=v and v:FindFirstChild(LP.Name.."'s Car")
    return car and car:FindFirstChild("UDP_DMXDATA")
  end)
  if ok and r and r:IsA("RemoteEvent") then return r end
  return nil
end

-- ──────────────────────────────────────────────
-- SEND FRAME (gabungan manual + bridge)
-- ──────────────────────────────────────────────
local function sendFrame()
  if not remote or not remote.Parent then return end

  if S.mode=="BRIDGE" then
    -- Kirim frame dari antrian bridge
    local payload,any={},false
    for u,q in pairs(bridgeQueues) do
      if #q>0 then payload[u]=table.remove(q,1); any=true end
    end
    if any then pcall(remote.FireServer,remote,payload) end
  else
    -- Kirim frame dari mixer internal
    if #fixtures==0 then return end
    local U=buildFrame()
    local payload={}
    for u,t in pairs(U) do
      local buf=buffer.create(512)
      for c,v in pairs(t) do buffer.writeu8(buf,c-1,v) end
      payload[u]=buf
    end
    pcall(remote.FireServer,remote,payload)
  end
end

-- ──────────────────────────────────────────────
-- BRIDGE POLLING TASK
-- ──────────────────────────────────────────────
local httpRequest = http_request or request or (syn and syn.request) or (fluxus and fluxus.request)

task.spawn(function()
  local failures=0
  while S.running do
    if S.mode~="BRIDGE" then task.wait(0.5); failures=0; goto continue end

    local ok,resp=false,nil
    if httpRequest then
      ok,resp=pcall(httpRequest,{Url=BRIDGE_URL,Method="GET"})
    end

    if ok and type(resp)=="table" and resp.StatusCode==200 then
      local dok,body=pcall(HttpService.JSONDecode,HttpService,resp.Body)
      if dok and type(body)=="table" and type(body.data)=="table" then
        failures=0
        S.bridgeConn=true
        S.bridgeMsg="Terhubung ✓"
        for username,universes in pairs(body.data) do
          if type(username)=="string" and type(universes)=="table" then
            if username:lower()==LP.Name:lower() then
              S.bridgeFrames=S.bridgeFrames+1
              enqueueBridgeFrames(universes)
            end
          end
        end
        if UI.refreshBridgeStatus then UI.refreshBridgeStatus() end
      end
    else
      failures=failures+1
      if failures>=30 then
        S.bridgeConn=false
        S.bridgeMsg="Server tidak ditemukan di "..BRIDGE_URL
        if UI.refreshBridgeStatus then UI.refreshBridgeStatus() end
      end
    end

    ::continue::
    task.wait(BRIDGE_INTERVAL)
  end
end)

-- ──────────────────────────────────────────────
-- SAVE / LOAD
-- ──────────────────────────────────────────────
local function snapshotAll()
  local fx={}
  for _,f in ipairs(fixtures) do
    fx[#fx+1]={mi=f.mi,dmx=f.dmx,sel=f.sel,dimBase=f.dimBase,panBase=f.panBase,tiltBase=f.tiltBase}
  end
  local cq={}; for k,v in pairs(S.cues) do cq[tostring(k)]=v end
  return {
    fixtures=fx, cues=cq, chase=S.chaseSteps, beamMap=MODELS[1].map,
    set={
      master=S.master, beamProfile=S.beamProfile,
      ptShape=S.ptShape, panCenter=S.panCenter, tiltCenter=S.tiltCenter,
      panSize=S.panSize, tiltSize=S.tiltSize, ptSpeed=S.ptSpeed,
      ptSpread=S.ptSpread, ptRepeat=S.ptRepeat, ptDir=S.ptDir,
      mirrorPan=S.mirrorPan, invertOddTilt=S.invertOddTilt,
      dimShape=S.dimShape, dimSpeed=S.dimSpeed, dimSpread=S.dimSpread,
      dimRepeat=S.dimRepeat, dimSize=S.dimSize,
    }
  }
end

local function applySnapshot(d)
  if type(d)~="table" then return end
  if type(d.set)=="table" and d.set.beamProfile then applyBeamProfile(d.set.beamProfile) end
  if type(d.beamMap)=="table" then MODELS[1].map=d.beamMap end
  if type(d.fixtures)=="table" then
    fixtures={}
    for _,x in ipairs(d.fixtures) do
      local mi=tonumber(x.mi)
      if mi and MODELS[mi] then
        local f=newFixture(mi,tonumber(x.dmx) or 1)
        f.sel=x.sel and true or false
        f.dimBase=tonumber(x.dimBase) or 255
        f.panBase=tonumber(x.panBase) or 128
        f.tiltBase=tonumber(x.tiltBase) or 128
        f.dimOut=f.dimBase
        fixtures[#fixtures+1]=f
      end
    end
  end
  if type(d.cues)=="table" then
    S.cues={}; for k,v in pairs(d.cues) do S.cues[tonumber(k) or k]=v end
  end
  if type(d.chase)=="table" then
    S.chaseSteps={}
    for _,st in ipairs(d.chase) do
      local o={}; for k,v in pairs(st) do o[tonumber(k) or k]=v end
      S.chaseSteps[#S.chaseSteps+1]=o
    end
  end
  if type(d.set)=="table" then
    local st=d.set
    S.master=tonumber(st.master) or S.master
    S.ptShape=st.ptShape or "OFF"; S.dimShape=st.dimShape or "OFF"
    S.panCenter=tonumber(st.panCenter) or 128; S.tiltCenter=tonumber(st.tiltCenter) or 128
    S.panSize=tonumber(st.panSize) or 75; S.tiltSize=tonumber(st.tiltSize) or 75
    S.ptSpeed=tonumber(st.ptSpeed) or 0.45; S.ptSpread=tonumber(st.ptSpread) or 25
    S.ptRepeat=tonumber(st.ptRepeat) or 0; S.ptDir=tonumber(st.ptDir) or 1
    S.mirrorPan=st.mirrorPan and true or false; S.invertOddTilt=st.invertOddTilt and true or false
    S.dimSpeed=tonumber(st.dimSpeed) or 0.90; S.dimSpread=tonumber(st.dimSpread) or 60
    S.dimRepeat=tonumber(st.dimRepeat) or 2; S.dimSize=tonumber(st.dimSize) or 255
  end
end

local function fileOk() return type(writefile)=="function" and type(readfile)=="function" end
local function writeSaves() if not fileOk() then return end pcall(function() writefile(FILE,HttpService:JSONEncode({saves=saves})) end) end
local function readSaves()
  if not fileOk() then return end
  local ok,d=pcall(function()
    if isfile and not isfile(FILE) then return nil end
    return HttpService:JSONDecode(readfile(FILE))
  end)
  if ok and type(d)=="table" and type(d.saves)=="table" then saves=d.saves end
end

-- ══════════════════════════════════════════════
--  UI HELPERS — PALETTE BARU
-- ══════════════════════════════════════════════
local C = {
  bg     = Color3.fromRGB(8,   8,  12),
  panel  = Color3.fromRGB(16,  16,  24),
  card   = Color3.fromRGB(26,  26,  38),
  input  = Color3.fromRGB(10,  10,  16),
  border = Color3.fromRGB(55,  55,  78),
  text   = Color3.fromRGB(235, 235, 248),
  muted  = Color3.fromRGB(130, 130, 155),
  white  = Color3.fromRGB(255, 255, 255),
  black  = Color3.fromRGB(0,   0,   0),
  cyan   = Color3.fromRGB(0,   210, 240),   -- aktif / accent
  purple = Color3.fromRGB(130, 60,  220),   -- header / bridge
  red    = Color3.fromRGB(235, 55,  65),    -- error / blackout
  green  = Color3.fromRGB(30,  200, 85),    -- connected / ok
  orange = Color3.fromRGB(240, 145, 30),    -- bridge mode aktif
  dim    = Color3.fromRGB(50,  50,  68),    -- strip inactive
}

local function track(c) conns[#conns+1]=c; return c end
local function new(cls,props,parent)
  local o=Instance.new(cls)
  for k,v in pairs(props or {}) do o[k]=v end
  if parent then o.Parent=parent end
  return o
end
local function corner(o,r) return new("UICorner",{CornerRadius=UDim.new(0,r or 6)},o) end
local function stroke(o,th,col)
  return new("UIStroke",{Color=col or C.border,Thickness=th or 1.2,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},o)
end
local function pad(o,p) return new("UIPadding",{PaddingLeft=UDim.new(0,p),PaddingRight=UDim.new(0,p),PaddingTop=UDim.new(0,p),PaddingBottom=UDim.new(0,p)},o) end
local function lbl(parent,text,props)
  local p={BackgroundTransparency=1,Text=text,TextColor3=C.text,Font=Enum.Font.Code,
    TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,Size=UDim2.new(1,0,0,18),TextWrapped=true}
  for k,v in pairs(props or {}) do p[k]=v end
  return new("TextLabel",p,parent)
end
local function setActive(b,on)
  if not b then return end
  b.BackgroundColor3 = on and C.cyan or C.card
  b.TextColor3       = on and C.black or C.text
end
local function btn(parent,text,cb,props)
  local p={BackgroundColor3=C.card,TextColor3=C.text,Font=Enum.Font.Code,TextSize=11,
    Text=text,AutoButtonColor=false,Size=UDim2.new(0,84,0,28),BorderSizePixel=0,TextWrapped=true}
  for k,v in pairs(props or {}) do p[k]=v end
  local b=new("TextButton",p,parent)
  corner(b,5); stroke(b)
  track(b.MouseEnter:Connect(function()
    TweenService:Create(b,TweenInfo.new(0.1),{BackgroundColor3=Color3.new(b.BackgroundColor3.R+0.06,b.BackgroundColor3.G+0.06,b.BackgroundColor3.B+0.08)}):Play()
  end))
  track(b.MouseLeave:Connect(function()
    if b.BackgroundColor3~=C.cyan then TweenService:Create(b,TweenInfo.new(0.1),{BackgroundColor3=C.card}):Play() end
  end))
  if cb then track(b.Activated:Connect(function()
    if activeSlider~=nil then return end
    if not canClick() then return end
    cb(b)
  end)) end
  return b
end
local function mkInput(parent,text,w,cb,ph)
  local b=new("TextBox",{Size=UDim2.new(0,w,0,28),BackgroundColor3=C.input,TextColor3=C.text,
    PlaceholderText=ph or "",PlaceholderColor3=C.muted,Text=text,Font=Enum.Font.Code,
    TextSize=11,ClearTextOnFocus=false,BorderSizePixel=0},parent)
  corner(b,5); stroke(b)
  track(b.FocusLost:Connect(function() if cb then cb(b.Text,b) end end))
  return b
end
local function rowF(parent,h,gap)
  local r=new("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,h or 0),
    AutomaticSize=h and Enum.AutomaticSize.None or Enum.AutomaticSize.Y},parent)
  new("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,gap or 8),
    Wraps=true,VerticalAlignment=Enum.VerticalAlignment.Center,SortOrder=Enum.SortOrder.LayoutOrder},r)
  return r
end
local function gridF(parent,cols,cellH,gap)
  local g=new("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y},parent)
  local gp=gap or 6
  new("UIGridLayout",{CellSize=UDim2.new(1/cols,-gp,0,cellH),CellPadding=UDim2.new(0,gp,0,gp),SortOrder=Enum.SortOrder.LayoutOrder},g)
  return g
end
local function boxF(parent,title,spacing)
  local b=new("Frame",{BackgroundColor3=C.card,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,BorderSizePixel=0},parent)
  corner(b,8); stroke(b); pad(b,10)
  new("UIListLayout",{Padding=UDim.new(0,spacing or 10),SortOrder=Enum.SortOrder.LayoutOrder},b)
  if title then
    local h=new("Frame",{BackgroundColor3=C.purple,Size=UDim2.new(1,-20,0,22),BorderSizePixel=0,LayoutOrder=0},b)
    corner(h,4)
    lbl(h," "..title,{TextColor3=C.white,TextSize=11,Font=Enum.Font.GothamBold,Size=UDim2.new(1,0,1,0)})
  end
  return b
end

local function mkSlider(parent,min,max,init,cb,size)
  local f=new("Frame",{BackgroundTransparency=1,Size=size or UDim2.new(1,0,0,30),Active=true},parent)
  local tr=new("Frame",{Size=UDim2.new(1,-12,0,10),Position=UDim2.new(0,6,0.5,-5),BackgroundColor3=C.panel,BorderSizePixel=0},f)
  corner(tr,5); stroke(tr,1)
  local fill=new("Frame",{Size=UDim2.new(0,0,1,0),BackgroundColor3=C.cyan,BorderSizePixel=0},tr)
  corner(fill,5)
  local knob=new("Frame",{Size=UDim2.new(0,16,0,24),AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.new(0,0,0.5,0),BackgroundColor3=C.white,BorderSizePixel=0},tr)
  corner(knob,4); stroke(knob,1.5)
  local obj={value=init,frame=f}
  local function vis(v)
    local r=clamp((max>min) and ((v-min)/(max-min)) or 0,0,1)
    fill.Size=UDim2.new(r,0,1,0); knob.Position=UDim2.new(r,0,0.5,0)
  end
  function obj.set(v) obj.value=v; vis(v) end
  local function upd(x)
    local w=tr.AbsoluteSize.X; if w<=0 then return end
    local r=clamp((x-tr.AbsolutePosition.X)/w,0,1)
    local v=min+r*(max-min)
    if (max-min)>=10 then v=round(v) else v=floor(v*100+0.5)/100 end
    obj.value=v; vis(v); if cb then cb(v) end
  end
  track(f.InputBegan:Connect(function(i)
    if (i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch) and activeSlider==nil then
      activeSlider=obj; upd(i.Position.X)
    end
  end))
  track(UIS.InputChanged:Connect(function(i)
    if activeSlider==obj and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then upd(i.Position.X) end
  end))
  track(UIS.InputEnded:Connect(function(i)
    if activeSlider==obj and (i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch) then activeSlider=nil end
  end))
  vis(init); return obj
end

local function slideRow(parent,name,min,max,init,step,fmt,cb)
  local r=new("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,34)},parent)
  lbl(r,name,{Size=UDim2.new(0,100,1,0),TextSize=11})
  local vl=lbl(r,fmt(init),{Size=UDim2.new(0,72,1,0),Position=UDim2.new(1,-72,0,0),TextXAlignment=Enum.TextXAlignment.Right,TextSize=11,TextColor3=C.cyan})
  local sl=mkSlider(r,min,max,init,function(v) vl.Text=fmt(v); cb(v) end,UDim2.new(1,-244,1,0))
  sl.frame.Position=UDim2.new(0,104,0,0)
  btn(r,"-",function() local nv=clamp(sl.value-step,min,max); sl.set(nv); vl.Text=fmt(nv); cb(nv) end,
    {Position=UDim2.new(1,-136,0.5,-13),Size=UDim2.new(0,28,0,26)})
  btn(r,"+",function() local nv=clamp(sl.value+step,min,max); sl.set(nv); vl.Text=fmt(nv); cb(nv) end,
    {Position=UDim2.new(1,-104,0.5,-13),Size=UDim2.new(0,28,0,26)})
  local o={}; function o.set(v) sl.set(v); vl.Text=fmt(v) end; return o
end

-- ══════════════════════════════════════════════
--  GUI UTAMA
-- ══════════════════════════════════════════════
local function guiParent()
  local ok,h=pcall(function() return gethui and gethui() end)
  if ok and h then return h end
  local ok2,cg=pcall(function() return game:GetService("CoreGui") end)
  if ok2 and cg then return cg end
  return LP:WaitForChild("PlayerGui")
end
local gui=new("ScreenGui",{Name="WANZZMIXER",ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Sibling,DisplayOrder=999})
pcall(function() gui.Parent=guiParent() end)
if not gui.Parent then gui.Parent=LP:WaitForChild("PlayerGui") end

local WIN_W,WIN_H=580,680
local win=new("Frame",{Size=UDim2.new(0,WIN_W,0,WIN_H),Position=UDim2.new(0,20,0,20),
  BackgroundColor3=C.bg,BorderSizePixel=0,Active=true},gui)
corner(win,10); stroke(win,2,C.purple)

local uiscale=new("UIScale",{Scale=1},win)
do
  local vp=workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
  local sc=1
  if vp then sc=clamp(math.min((vp.X*0.96)/WIN_W,(vp.Y*0.94)/WIN_H),0.5,1) end
  S.scale=sc; uiscale.Scale=sc
end

-- ── HEADER ──────────────────────────────────
local header=new("Frame",{Size=UDim2.new(1,0,0,46),BackgroundColor3=C.panel,BorderSizePixel=0,Active=true},win)
-- Gradient garis atas
local topLine=new("Frame",{Size=UDim2.new(1,0,0,2),BackgroundColor3=C.purple,BorderSizePixel=0},header)

-- Kiri: judul
local titleLbl=lbl(header,"◈  WANZZMIXER  V6  —  PEARL 1024B  +  ART-NET BRIDGE",{
  Position=UDim2.new(0,12,0,8),Size=UDim2.new(0,360,0,28),
  Font=Enum.Font.GothamBold,TextSize=13,TextColor3=C.cyan,TextXAlignment=Enum.TextXAlignment.Left})

-- Kanan: tombol
local hRight=new("Frame",{BackgroundTransparency=1,Size=UDim2.new(0,230,1,0),Position=UDim2.new(1,-234,0,0)},header)
new("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,5),HorizontalAlignment=Enum.HorizontalAlignment.Right,VerticalAlignment=Enum.VerticalAlignment.Center},hRight)
local function setScale(v) S.scale=clamp(v,0.4,1.5); uiscale.Scale=S.scale end
btn(hRight,"A-",function() setScale(S.scale-0.1) end,{Size=UDim2.new(0,30,0,26)})
btn(hRight,"A+",function() setScale(S.scale+0.1) end,{Size=UDim2.new(0,30,0,26)})

-- Dot status mobil
local dotBtn=btn(hRight,"",nil,{Size=UDim2.new(0,30,0,26)})
local dot=new("Frame",{Size=UDim2.new(0,10,0,10),Position=UDim2.new(0.5,-5,0.5,-5),BackgroundColor3=C.red,BorderSizePixel=0},dotBtn)
corner(dot,10)

-- Minimize & Close
local body=new("Frame",{Size=UDim2.new(1,0,1,-46),Position=UDim2.new(0,0,0,46),BackgroundTransparency=1,ClipsDescendants=true},win)
btn(hRight,"-",function(b)
  body.Visible=not body.Visible
  win.Size=body.Visible and UDim2.new(0,WIN_W,0,WIN_H) or UDim2.new(0,WIN_W,0,46)
  b.Text=body.Visible and "-" or "+"
end,{Size=UDim2.new(0,30,0,26)})
local closeBtn=btn(hRight,"✕",nil,{Size=UDim2.new(0,30,0,26),BackgroundColor3=C.red,TextColor3=C.white})

-- Drag
do
  local drag,ds,sp=false,nil,nil
  track(header.InputBegan:Connect(function(i)
    if (i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch) and activeSlider==nil then
      drag=true; ds=i.Position; sp=win.Position
    end
  end))
  track(UIS.InputChanged:Connect(function(i)
    if drag and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then
      local d=i.Position-ds; win.Position=UDim2.new(sp.X.Scale,sp.X.Offset+d.X,sp.Y.Scale,sp.Y.Offset+d.Y)
    end
  end))
  track(UIS.InputEnded:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then drag=false end
  end))
end

-- ── MASTER BAR ──────────────────────────────
local masterBar=new("Frame",{Size=UDim2.new(1,0,0,44),BackgroundColor3=C.panel,BorderSizePixel=0},body)
local mLbl=lbl(masterBar,"Master  100%",{Position=UDim2.new(0,10,0,0),Size=UDim2.new(0,88,1,0),TextSize=11,TextColor3=C.cyan})
local mSl=mkSlider(masterBar,0,100,100,function(v) S.master=v; mLbl.Text="Master  "..v.."%" end,UDim2.new(0,180,0,28))
mSl.frame.Position=UDim2.new(0,100,0.5,-14)

-- Mode toggle MANUAL / BRIDGE
local modeBtn=btn(masterBar,"◉  MANUAL MODE",function(b)
  if S.mode=="MANUAL" then
    S.mode="BRIDGE"; b.Text="◎  BRIDGE MODE"; b.BackgroundColor3=C.orange; b.TextColor3=C.black
    bridgeQueues={}; S.bridgeFrames=0
    if UI.refreshBridgeStatus then UI.refreshBridgeStatus() end
  else
    S.mode="MANUAL"; b.Text="◉  MANUAL MODE"; b.BackgroundColor3=C.card; b.TextColor3=C.text
  end
end,{Position=UDim2.new(0,290,0.5,-13),Size=UDim2.new(0,130,0,26),TextSize=11})

local boBtn=btn(masterBar,"⚫ BLACKOUT",function() S.blackout=not S.blackout; UI.refreshFooter() end,
  {Position=UDim2.new(0,430,0.5,-13),Size=UDim2.new(0,90,0,26),TextSize=11})
btn(masterBar,"⚡ LOCATE",function()
  S.blackout=false
  for _,f in ipairs(fixtures) do if f.sel then f.dimBase=255;f.dimOut=255;f.panBase=S.panCenter;f.tiltBase=S.tiltCenter end end
  if UI.syncProgramSliders then UI.syncProgramSliders() end; UI.refreshFooter()
end,{Position=UDim2.new(0,526,0.5,-13),Size=UDim2.new(0,46,0,26),TextSize=10})

-- ── TABS ────────────────────────────────────
local TABS={"Fixture","Layout","Program","Shape","Chase","Cue","Bridge","Save"}
local tabBar=new("Frame",{Size=UDim2.new(1,0,0,38),Position=UDim2.new(0,0,0,44),BackgroundColor3=C.panel,BorderSizePixel=0},body)
local tabLine=new("Frame",{Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),BackgroundColor3=C.purple,BorderSizePixel=0},tabBar)
new("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,3),VerticalAlignment=Enum.VerticalAlignment.Center,HorizontalAlignment=Enum.HorizontalAlignment.Center},tabBar)

local tabBtns,tabFrames={},{}

local function switchTab(name)
  S.tab=name
  for n,f in pairs(tabFrames) do f.Visible=(n==name) end
  for n,b in pairs(tabBtns) do
    setActive(b,n==name)
    if n==name then stroke(b,1.5,C.cyan) else stroke(b,1,C.border) end
  end
end

for _,n in ipairs(TABS) do
  tabBtns[n]=btn(tabBar,n:upper(),function() switchTab(n) end,
    {Size=UDim2.new(1/#TABS,-4,0,30),TextSize=10,LayoutOrder=_})
  local sf=new("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=4,
    CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,Visible=false,
    Size=UDim2.new(1,-20,1,-112),Position=UDim2.new(0,10,0,86)},body)
  new("UIListLayout",{Padding=UDim.new(0,8),SortOrder=Enum.SortOrder.LayoutOrder},sf)
  tabFrames[n]=sf
end

-- ── STRIP BAR ───────────────────────────────
local stripBar=new("Frame",{Size=UDim2.new(1,0,0,38),Position=UDim2.new(0,0,0,82),BackgroundColor3=C.panel,BorderSizePixel=0,Visible=true},body)
local stripScroll=new("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=0,
  Size=UDim2.new(0,350,1,0),Position=UDim2.new(0,62,0,0),
  CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.X,
  ScrollingDirection=Enum.ScrollingDirection.X},stripBar)
new("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,4),VerticalAlignment=Enum.VerticalAlignment.Center},stripScroll)
btn(stripBar,"<",function() stripScroll.CanvasPosition=Vector2.new(math.max(0,stripScroll.CanvasPosition.X-140),0) end,
  {Position=UDim2.new(0,4,0.5,-14),Size=UDim2.new(0,26,0,28)})
btn(stripBar,">",function() stripScroll.CanvasPosition=Vector2.new(stripScroll.CanvasPosition.X+140,0) end,
  {Position=UDim2.new(0,32,0.5,-14),Size=UDim2.new(0,26,0,28)})
local function selGroup(kind)
  for i,f in ipairs(fixtures) do
    if kind=="semua" then f.sel=true
    elseif kind=="ganjil" then f.sel=(i%2~=0)
    elseif kind=="genap" then f.sel=(i%2==0) end
  end; UI.refreshSel()
end
for i,g in ipairs({{"Semua","semua"},{"Ganjil","ganjil"},{"Genap","genap"}}) do
  btn(stripBar,g[1],function() selGroup(g[2]) end,
    {Position=UDim2.new(0,415+(i-1)*55,0.5,-14),Size=UDim2.new(0,50,0,28),TextSize=10})
end

local stripBtns={}
function UI.rebuildStrip()
  for _,b in ipairs(stripBtns) do b:Destroy() end; stripBtns={}
  for i,f in ipairs(fixtures) do
    local b=btn(stripScroll,tostring(i),function()
      if S.tab=="Program" and S.singleSelectPro then
        for _,fx in ipairs(fixtures) do fx.sel=false end; f.sel=true
      else f.sel=not f.sel end
      UI.refreshSel()
      if UI.syncProgramSliders then UI.syncProgramSliders() end
    end,{Size=UDim2.new(0,32,0,30),TextSize=11,LayoutOrder=i,BackgroundColor3=C.dim})
    stripBtns[i]=b
  end
end

-- ── FOOTER ──────────────────────────────────
local footer=new("Frame",{Size=UDim2.new(1,0,0,24),Position=UDim2.new(0,0,1,-24),BackgroundColor3=C.panel,BorderSizePixel=0},body)
local fL=lbl(footer,"",{Position=UDim2.new(0,8,0,0),Size=UDim2.new(0.65,0,1,0),TextColor3=C.muted,TextSize=10})
local fR=lbl(footer,"",{Position=UDim2.new(0.65,0,0,0),Size=UDim2.new(0.35,-8,1,0),TextColor3=C.muted,TextSize=10,TextXAlignment=Enum.TextXAlignment.Right})
function UI.refreshFooter()
  local beam,par=0,0
  for _,f in ipairs(fixtures) do if f.model.kind=="beam" then beam=beam+1 elseif f.model.kind=="par" then par=par+1 end end
  fL.Text=#fixtures.." FIXTURE  Beam:"..beam.."  Par:"..par.."  |  "..S.mode.."  |  Mobil: "..(S.car and "✓" or "–")
  fR.Text="V6  |  Skala "..round(S.scale*100).."%"
  dot.BackgroundColor3=S.car and C.green or C.red
  boBtn.BackgroundColor3=S.blackout and C.red or C.card
  boBtn.TextColor3=S.blackout and C.white or C.text
end

-- ══════════════════════════════════════════════
--  TAB: FIXTURE
-- ══════════════════════════════════════════════
local tFix=tabFrames["Fixture"]

local profBox=boxF(tFix,"PROFIL CHANNEL BEAM — PILIH SESUAI GERAKAN RIG",6)
local profGrid=gridF(profBox,1,28,4)
local profBtns={}
for _,k in ipairs({"R1","R2","R3","R4"}) do
  profBtns[k]=btn(profGrid,BEAM_PROFILES[k].label,function()
    applyBeamProfile(k)
    for pk,pb in pairs(profBtns) do setActive(pb,pk==k) end
    if UI.refreshTest then UI.refreshTest() end
  end,{Size=UDim2.new(1,0,1,0),TextSize=10})
end
setActive(profBtns["R1"],true)

local patchBox=boxF(tFix,"PATCH FIXTURE",8)
local mdRow=rowF(patchBox,nil,5)
local mdBtns={}
for i,m in ipairs(MODELS) do
  mdBtns[i]=btn(mdRow,m.name.." ("..m.ch.."ch)",function()
    S.model=i; for j,b in ipairs(mdBtns) do setActive(b,j==i) end
  end,{Size=UDim2.new(0,160,0,28),TextSize=10})
end
setActive(mdBtns[1],true)

local addRow=rowF(patchBox,nil,6)
lbl(addRow,"Jumlah:",{Size=UDim2.new(0,52,0,28)})
local qtyBox=mkInput(addRow,"1",46)
lbl(addRow,"DMX:",{Size=UDim2.new(0,36,0,28)})
local startBox=mkInput(addRow,"",72,nil,"auto / 1-512")
btn(addRow,"+ Tambah",function()
  local qty=clamp(floor(tonumber(qtyBox.Text) or 1),1,100)
  local cust=tonumber(startBox.Text)
  for i=1,qty do
    local d=1
    if cust and i==1 then d=floor(cust)
    elseif #fixtures>0 then local l=fixtures[#fixtures]; d=l.dmx+l.model.ch end
    fixtures[#fixtures+1]=newFixture(S.model,d)
  end; UI.rebuildAll()
end,{Size=UDim2.new(0,80,0,28)})

local qRow=rowF(patchBox,nil,6)
btn(qRow,"+ 28 Beam (jangkah 16)",function()
  for i=1,28 do
    local d=(#fixtures>0) and (fixtures[#fixtures].dmx+fixtures[#fixtures].model.ch) or 1+(i-1)*16
    fixtures[#fixtures+1]=newFixture(1,d)
  end; UI.rebuildAll()
end,{Size=UDim2.new(0,175,0,28),TextSize=10})
btn(qRow,"Auto Patch",function() autoPatch(); UI.rebuildAll() end,{Size=UDim2.new(0,90,0,28)})
btn(qRow,"Hapus Semua",function()
  clearFixtures(); S.ptShape="OFF"; S.dimShape="OFF"; UI.rebuildAll(); UI.refreshShape()
end,{Size=UDim2.new(0,110,0,28)})

local fixList
local function renderFixList()
  if fixList then fixList:Destroy() end
  fixList=new("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,LayoutOrder=10},tFix)
  new("UIListLayout",{Padding=UDim.new(0,4),SortOrder=Enum.SortOrder.LayoutOrder},fixList)
  if #fixtures==0 then
    lbl(fixList,"— Kosong —",{Size=UDim2.new(1,0,0,28),TextColor3=C.muted,TextXAlignment=Enum.TextXAlignment.Center})
  else
    for i,f in ipairs(fixtures) do
      local r=new("Frame",{BackgroundColor3=C.card,Size=UDim2.new(1,0,0,30),BorderSizePixel=0,LayoutOrder=i},fixList)
      corner(r,5); stroke(r)
      lbl(r,"#"..i.."  "..f.model.name,{Position=UDim2.new(0,8,0,0),Size=UDim2.new(0.5,0,1,0),TextSize=11})
      lbl(r,"U"..floor((f.dmx-1)/512)+1,{Position=UDim2.new(1,-175,0,0),Size=UDim2.new(0,50,1,0),TextColor3=C.muted,TextSize=10})
      local inp=mkInput(r,tostring(f.dmx),60,function(t,b)
        local v=tonumber(t); if v then f.dmx=clamp(floor(v),1,4096) end
        b.Text=tostring(f.dmx); UI.refreshLayout()
      end)
      inp.Position=UDim2.new(1,-112,0.5,-14)
      btn(r,"✕",function()
        table.remove(fixtures,i)
        for k,x in ipairs(fixtures) do x.id=k end; UI.rebuildAll()
      end,{Position=UDim2.new(1,-38,0.5,-13),Size=UDim2.new(0,28,0,26),BackgroundColor3=C.red})
    end
  end
end

-- ══════════════════════════════════════════════
--  TAB: LAYOUT
-- ══════════════════════════════════════════════
local tLay=tabFrames["Layout"]
local layRow=rowF(tLay,nil,6)
local stage=new("Frame",{BackgroundColor3=Color3.fromRGB(7,7,10),Size=UDim2.new(1,0,0,310),BorderSizePixel=0,LayoutOrder=5,ClipsDescendants=true},tLay)
corner(stage,8); stroke(stage,2,C.purple)
lbl(stage,"▲  BELAKANG / RIGGING",{Position=UDim2.new(0.5,-80,0,4),Size=UDim2.new(0,160,0,14),TextXAlignment=Enum.TextXAlignment.Center,TextColor3=C.muted,TextSize=9})
lbl(stage,"▼  DEPAN / PENONTON",{Position=UDim2.new(0.5,-80,1,-16),Size=UDim2.new(0,160,0,14),TextXAlignment=Enum.TextXAlignment.Center,TextColor3=C.muted,TextSize=9})
local nodes={}
function UI.refreshLayout()
  for _,n in ipairs(nodes) do n:Destroy() end; nodes={}
  local mode=S.layoutMode
  for i,f in ipairs(fixtures) do
    local i0=i-1; local x,y=20,40
    if     mode=="baris"   then x=14+(i0%14)*35; y=120+floor(i0/14)*44
    elseif mode=="2baris"  then x=14+(i0%14)*35; y=40+floor(i0/14)*85
    elseif mode=="busur"   then local a=(pi/(#fixtures+1))*i; x=250-cos(a)*215; y=40+sin(a)*190
    elseif mode=="grid"    then x=55+(i0%7)*58; y=30+floor(i0/7)*50
    else local ip=f.model.kind~="beam"; x=14+(i0%14)*35; y=ip and 250 or (40+floor(i0/14)*65)
    end
    local sub=S.labelDmx and ("U"..floor((f.dmx-1)/512)+1..":"..f.dmx) or f.model.name:sub(1,5)
    local n=btn(stage,i.."\n"..sub,function() f.sel=not f.sel; UI.refreshSel() end,
      {Position=UDim2.new(0,x,0,y),Size=UDim2.new(0,33,0,36),TextSize=8,TextWrapped=false})
    n.BackgroundColor3=f.sel and C.cyan or C.dim
    n.TextColor3=f.sel and C.black or C.text
    nodes[#nodes+1]=n
  end
end
for _,m in ipairs({{"Baris","baris"},{"2Baris","2baris"},{"Busur","busur"},{"Grid","grid"},{"Per Tipe","pertype"}}) do
  btn(layRow,m[1],function() S.layoutMode=m[2]; UI.refreshLayout() end,{Size=UDim2.new(0,68,0,28)})
end
btn(layRow,"Label: Nama",function(b) S.labelDmx=not S.labelDmx; b.Text=S.labelDmx and "Label: DMX" or "Label: Nama"; UI.refreshLayout() end,
  {Size=UDim2.new(0,100,0,28)})

-- ══════════════════════════════════════════════
--  TAB: PROGRAM
-- ══════════════════════════════════════════════
local tPro=tabFrames["Program"]
local slDim,slPan,slTilt,slStrobe,slPrisma

local qbox=boxF(tPro,"KONTROL CEPAT",8)
local qq=rowF(qbox,nil,6)
btn(qq,"✦ DIMMER ON",function()
  for _,f in ipairs(fixtures) do if f.sel then f.dimBase=255;f.dimOut=255 end end
  if slDim then slDim.set(255) end
end,{Size=UDim2.new(0,110,0,30),BackgroundColor3=Color3.fromRGB(30,80,30)})
btn(qq,"✦ DIMMER OFF",function()
  for _,f in ipairs(fixtures) do if f.sel then f.dimBase=0;f.dimOut=0 end end
  if slDim then slDim.set(0) end
end,{Size=UDim2.new(0,110,0,30),BackgroundColor3=Color3.fromRGB(70,25,25)})
btn(qq,"⇄ Tukar Pan/Tilt",function()
  local m=MODELS[1].map; local t=m.pan; m.pan=m.tilt; m.tilt=t
  if UI.refreshTest then UI.refreshTest() end
end,{Size=UDim2.new(0,130,0,30)})
btn(qq,"1 Lampu",function(b)
  S.singleSelectPro=not S.singleSelectPro
  b.Text=S.singleSelectPro and "1 Lampu: ON" or "1 Lampu"; setActive(b,S.singleSelectPro)
end,{Size=UDim2.new(0,90,0,30)})

local pbox=boxF(tPro,"FADER MANUAL",10)
local function setSel(field,v)
  for _,f in ipairs(fixtures) do if f.sel then f[field]=v; if field=="dimBase" then f.dimOut=v end end end
end
slDim    = slideRow(pbox,"Dimmer",    0,255,255,5, function(v) return round(v).."" end, function(v) setSel("dimBase",v) end)
slPan    = slideRow(pbox,"Pan Dasar", 0,255,128,2, function(v) return round(v).."" end, function(v) S.panCenter=v; setSel("panBase",v) end)
slTilt   = slideRow(pbox,"Tilt Dasar",0,255,128,2, function(v) return round(v).."" end, function(v) S.tiltCenter=v; setSel("tiltBase",v) end)
slPrisma = slideRow(pbox,"Prisma",    0,255,0,  5, function(v) return round(v).."" end, function(v) setSel("prismaBase",v) end)
slStrobe = slideRow(pbox,"Strobo",    0,255,0,  5, function(v) return round(v).."" end, function(v) setSel("strobeBase",v) end)
slideRow(pbox,"Merah (R)",0,255,255,5, function(v) return round(v).."" end, function(v) setSel("r",v) end)
slideRow(pbox,"Hijau (G)",0,255,255,5, function(v) return round(v).."" end, function(v) setSel("g",v) end)
slideRow(pbox,"Biru (B)", 0,255,255,5, function(v) return round(v).."" end, function(v) setSel("b",v) end)

function UI.syncProgramSliders()
  for _,f in ipairs(fixtures) do if f.sel then
    slDim.set(f.dimBase); slPan.set(f.panBase); slTilt.set(f.tiltBase)
    slPrisma.set(f.prismaBase); slStrobe.set(f.strobeBase); break
  end end
end

-- Auto-scan box
local tbox=boxF(tPro,"AUTO-SCAN & TES CHANNEL",8)
lbl(tbox,"Aktifkan 'Auto-Scan', perhatikan gerakan/nyala lampu di mobil → catat nomor CH → klik 'Set …'",
  {Size=UDim2.new(1,0,0,28),TextColor3=C.muted,TextSize=10})
local tRow=rowF(tbox,nil,6)
local tChLbl=lbl(tRow,"CH 1",{Size=UDim2.new(0,54,0,28),TextSize=14,TextColor3=C.cyan,TextXAlignment=Enum.TextXAlignment.Center})
local function testModel()
  for _,f in ipairs(fixtures) do if f.sel then return f.model,f.mi end end
  return MODELS[S.model],S.model
end
function UI.refreshTest()
  local m,mi=testModel(); S.test.ch=clamp(S.test.ch,1,m.ch); S.model=mi
  tChLbl.Text="CH "..S.test.ch
  if UI.mapInfo then
    local p={}; for k,v in pairs(m.map) do p[#p+1]=k.."="..(type(v)=="table" and table.concat(v,",") or tostring(v)) end
    table.sort(p); UI.mapInfo.Text=m.name.."  Map: "..table.concat(p," | ")
  end
end
btn(tRow,"− CH",function() S.test.ch=S.test.ch-1; UI.refreshTest() end,{Size=UDim2.new(0,48,0,28)})
btn(tRow,"+ CH",function() S.test.ch=S.test.ch+1; UI.refreshTest() end,{Size=UDim2.new(0,48,0,28)})
local testBtn=btn(tRow,"Tes: OFF",function(b)
  S.test.on=not S.test.on; if not S.test.on then S.test.autoScan=false end
  b.Text=S.test.on and "Tes: ON" or "Tes: OFF"; setActive(b,S.test.on)
end,{Size=UDim2.new(0,76,0,28)})
btn(tRow,"Auto-Scan: OFF",function(b)
  S.test.autoScan=not S.test.autoScan
  if S.test.autoScan then S.test.on=true; testBtn.Text="Tes: ON"; setActive(testBtn,true) end
  b.Text=S.test.autoScan and "Auto-Scan: ON" or "Auto-Scan: OFF"; setActive(b,S.test.autoScan)
end,{Size=UDim2.new(0,130,0,28)})
slideRow(tbox,"Nilai Tes",0,255,255,5,function(v) return round(v).."" end,function(v) S.test.val=round(v) end)
local aRow=rowF(tbox,nil,5)
for _,p in ipairs({{"Set Pan","pan"},{"Set Tilt","tilt"},{"Set Dimmer","dimmer"},{"Set Strobe","strobe"},{"Set Prisma","prisma"}}) do
  btn(aRow,p[1],function()
    local m=testModel(); m.map[p[2]]=S.test.ch; UI.refreshTest()
  end,{Size=UDim2.new(0,90,0,26),TextSize=10})
end
UI.mapInfo=lbl(tbox,"",{Size=UDim2.new(1,0,0,22),TextColor3=C.muted,TextSize=9})

-- ══════════════════════════════════════════════
--  TAB: SHAPE
-- ══════════════════════════════════════════════
local tShp=tabFrames["Shape"]

local ptBox=boxF(tShp,"PAN/TILT SHAPE GENERATOR — PEARL 1024B",8)
local ptGrid=gridF(ptBox,4,30,6)
local ptBtns={}
for _,nm in ipairs(PEARL_PT_SHAPES) do
  ptBtns[nm]=btn(ptGrid,nm,function()
    S.ptShape=nm
    if nm~="OFF" then
      for _,f in ipairs(fixtures) do if f.sel and f.dimBase==0 then f.dimBase=255;f.dimOut=255 end end
      if UI.syncProgramSliders then UI.syncProgramSliders() end
    end; UI.refreshShape()
  end,{Size=UDim2.new(1,0,1,0),TextSize=10})
end

local advBox=boxF(tShp,"PARAMETER SHAPE P/T",9)
local slPanSz  = slideRow(advBox,"Pan Size",    0,127,S.panSize,  2,function(v) return round(v).."  ("..round(v/127*100).."%)" end,function(v) S.panSize=v end)
local slTiltSz = slideRow(advBox,"Tilt Size",   0,127,S.tiltSize, 2,function(v) return round(v).."  ("..round(v/127*100).."%)" end,function(v) S.tiltSize=v end)
local slPtSpd  = slideRow(advBox,"Speed",       5,200,S.ptSpeed*100,5,function(v) return string.format("%.2f Hz",v/100) end,function(v) S.ptSpeed=v/100 end)
local slPtSpr  = slideRow(advBox,"Spread",      0,180,S.ptSpread, 5,function(v) return round(v).." deg" end,function(v) S.ptSpread=v end)
local slPtRep  = slideRow(advBox,"Repeat Grup", 0,14, S.ptRepeat, 1,function(v) return v==0 and "Semua" or round(v).." Lampu" end,function(v) S.ptRepeat=round(v) end)

local sqRow=rowF(advBox,nil,5)
lbl(sqRow,"Quick Spread:",{Size=UDim2.new(0,85,0,26),TextColor3=C.muted,TextSize=10})
for _,sp in ipairs({{"Rata",15,0},{"Bareng",0,0},{"2 Grup",180,2},{"4 Grup",90,4}}) do
  btn(sqRow,sp[1],function() S.ptSpread=sp[2];S.ptRepeat=sp[3]; slPtSpr.set(S.ptSpread);slPtRep.set(S.ptRepeat) end,
    {Size=UDim2.new(0,80,0,26),TextSize=10})
end

local symRow=rowF(advBox,nil,8)
local mirBtn=btn(symRow,"Mirror L/R: OFF",function(b)
  S.mirrorPan=not S.mirrorPan; b.Text=S.mirrorPan and "Mirror L/R: ON" or "Mirror L/R: OFF"; setActive(b,S.mirrorPan)
end,{Size=UDim2.new(0,130,0,28),TextSize=10})
local invBtn=btn(symRow,"Invert Tilt Ganjil: OFF",function(b)
  S.invertOddTilt=not S.invertOddTilt; b.Text=S.invertOddTilt and "Invert Tilt: ON" or "Invert Tilt Ganjil: OFF"; setActive(b,S.invertOddTilt)
end,{Size=UDim2.new(0,160,0,28),TextSize=10})
local dirBtns={}
for _,d in ipairs({{"CW",1},{"CCW",-1},{"Bounce",0}}) do
  dirBtns[d[2]]=btn(symRow,d[1],function() S.ptDir=d[2]; UI.refreshShape() end,{Size=UDim2.new(0,52,0,28),TextSize=10})
end

local dimBox=boxF(tShp,"DIMMER SHAPE GENERATOR — KELAP-KELIP",8)
local dimGrid=gridF(dimBox,4,28,5)
local dimBtns={}
for _,nm in ipairs(PEARL_DIM_SHAPES) do
  dimBtns[nm]=btn(dimGrid,nm,function()
    S.dimShape=nm
    if nm~="OFF" then
      for _,f in ipairs(fixtures) do if f.sel and f.dimBase==0 then f.dimBase=255;f.dimOut=255 end end
      if UI.syncProgramSliders then UI.syncProgramSliders() end
    end; UI.refreshShape()
  end,{Size=UDim2.new(1,0,1,0),TextSize=9})
end
slideRow(dimBox,"Dim Speed", 10,300,S.dimSpeed*100,10,function(v) return string.format("%.2f Hz",v/100) end,function(v) S.dimSpeed=v/100 end)
slideRow(dimBox,"Dim Spread",0, 180,S.dimSpread,   15,function(v) return round(v).." deg" end,function(v) S.dimSpread=v end)
slideRow(dimBox,"Dim Repeat",0, 14, S.dimRepeat,    1,function(v) return v==0 and "Wave" or round(v).." Grup" end,function(v) S.dimRepeat=round(v) end)

-- XY Monitor
local monBox=boxF(tShp,"LIVE MONITOR",8)
local prevRow=rowF(monBox,nil,10)
local xy=new("Frame",{BackgroundColor3=Color3.fromRGB(7,7,10),Size=UDim2.new(0,90,0,70),BorderSizePixel=0},prevRow)
corner(xy,6); stroke(xy,1.5,C.purple)
local xyDot=new("Frame",{Size=UDim2.new(0,10,0,10),AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.new(0.5,0,0.5,0),BackgroundColor3=C.cyan,BorderSizePixel=0},xy)
corner(xyDot,10)
local liveTxt=lbl(prevRow,"Pan=128 | Tilt=128 | Dim=255",{Size=UDim2.new(0,380,0,60),TextSize=11})
local monGrid=gridF(monBox,14,24,4)
local monBars={}
local function rebuildMonitor()
  for _,c in ipairs(monGrid:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end; monBars={}
  for i,_ in ipairs(fixtures) do
    local m=new("Frame",{BackgroundColor3=C.panel,BorderSizePixel=0,LayoutOrder=i},monGrid)
    stroke(m,1); lbl(m,tostring(i),{Size=UDim2.new(1,0,1,-4),TextXAlignment=Enum.TextXAlignment.Center,TextSize=9})
    monBars[i]=new("Frame",{BackgroundColor3=C.cyan,BorderSizePixel=0,Position=UDim2.new(0,0,1,-3),Size=UDim2.new(0,0,0,3)},m)
  end
end

function UI.refreshShape()
  for n,b in pairs(ptBtns) do setActive(b,n==S.ptShape) end
  for n,b in pairs(dimBtns) do setActive(b,n==S.dimShape) end
  for n,b in pairs(dirBtns) do setActive(b,n==S.ptDir) end
  setActive(mirBtn,S.mirrorPan); setActive(invBtn,S.invertOddTilt)
  slPanSz.set(S.panSize); slTiltSz.set(S.tiltSize)
  slPtSpd.set(S.ptSpeed*100); slPtSpr.set(S.ptSpread); slPtRep.set(S.ptRepeat)
end

-- ══════════════════════════════════════════════
--  TAB: CHASE
-- ══════════════════════════════════════════════
local tCh=tabFrames["Chase"]
local chInfo=lbl(tCh,"0 step",{Size=UDim2.new(1,0,0,18),TextSize=12,TextColor3=C.cyan})
local cRow=rowF(tCh,nil,8)
local function snapStep()
  local st={}
  for _,f in ipairs(fixtures) do st[f.id]={pan=f.pan,tilt=f.tilt,strobe=f.strobe,prisma=f.prisma,dim=f.dimBase} end
  return st
end
function UI.refreshChase()
  chInfo.Text=#S.chaseSteps.." step  "..(S.chasePlay and "▶ PLAY (step "..S.chaseIdx..")" or "■ Stop")
end
btn(cRow,"+ Step",function() S.chaseSteps[#S.chaseSteps+1]=snapStep(); UI.refreshChase() end,{Size=UDim2.new(0,76,0,28)})
btn(cRow,"− Step",function() S.chaseSteps[#S.chaseSteps]=nil; S.chaseIdx=1; UI.refreshChase() end,{Size=UDim2.new(0,76,0,28)})
btn(cRow,"Kosong",function() S.chaseSteps={}; S.chasePlay=false; S.chaseIdx=1; UI.refreshChase() end,{Size=UDim2.new(0,76,0,28)})
btn(cRow,"▶ Play",function(b) S.chasePlay=not S.chasePlay; S.chaseT=0; b.Text=S.chasePlay and "■ Stop" or "▶ Play"; setActive(b,S.chasePlay); UI.refreshChase() end,{Size=UDim2.new(0,76,0,28)})
local cbox=boxF(tCh,"KONTROL CHASE",10)
slideRow(cbox,"Rate (BPM)",10,300,S.chaseBpm, 5,function(v) return round(v).." BPM" end,function(v) S.chaseBpm=v end)
slideRow(cbox,"Crossfade", 0, 100,S.chaseCross,5,function(v) return round(v).."%" end,  function(v) S.chaseCross=v end)

-- ══════════════════════════════════════════════
--  TAB: CUE
-- ══════════════════════════════════════════════
local tCue=tabFrames["Cue"]
local cueRow=rowF(tCue,nil,8)
local cueGridF,cuePageLbl
local function currLook() return {ptShape=S.ptShape,panSize=S.panSize,tiltSize=S.tiltSize,ptSpeed=S.ptSpeed,ptSpread=S.ptSpread,ptRepeat=S.ptRepeat,ptDir=S.ptDir,mirrorPan=S.mirrorPan,invertOddTilt=S.invertOddTilt,dimShape=S.dimShape,dimSpeed=S.dimSpeed,dimSpread=S.dimSpread,dimRepeat=S.dimRepeat} end
local function applyLook(l)
  if type(l)~="table" then return end
  S.ptShape=l.ptShape or "OFF"; S.panSize=tonumber(l.panSize) or S.panSize; S.tiltSize=tonumber(l.tiltSize) or S.tiltSize
  S.ptSpeed=tonumber(l.ptSpeed) or S.ptSpeed; S.ptSpread=tonumber(l.ptSpread) or S.ptSpread; S.ptRepeat=tonumber(l.ptRepeat) or S.ptRepeat
  S.ptDir=tonumber(l.ptDir) or S.ptDir; S.mirrorPan=l.mirrorPan and true or false; S.invertOddTilt=l.invertOddTilt and true or false
  S.dimShape=l.dimShape or "OFF"; S.dimSpeed=tonumber(l.dimSpeed) or S.dimSpeed; S.dimSpread=tonumber(l.dimSpread) or S.dimSpread; S.dimRepeat=tonumber(l.dimRepeat) or S.dimRepeat
  UI.refreshShape()
end
function UI.refreshCue()
  if cueGridF then cueGridF:Destroy() end
  cueGridF=gridF(tCue,6,46,6); cueGridF.LayoutOrder=20
  local s0=(S.cuePage-1)*24+1
  cuePageLbl.Text="Hal "..S.cuePage.."/8  ("..s0.."-"..(s0+23)..")"
  for i=s0,s0+23 do
    local cue=S.cues[i]
    local lc=cue and (cue.ptShape.."\n"..(cue.dimShape~="OFF" and cue.dimShape or "")) or "—"
    local b=btn(cueGridF,"CUE "..i.."\n"..lc,function()
      S.cueSel=i; if S.cues[i] then applyLook(S.cues[i]) end; UI.refreshCue()
    end,{Size=UDim2.new(1,0,1,0),TextSize=9,LayoutOrder=i})
    setActive(b,S.cueSel==i)
    if cue and S.cueSel~=i then b.BackgroundColor3=Color3.fromRGB(38,38,55) end
  end
end
btn(cueRow,"Store Cue",function() if S.cueSel then S.cues[S.cueSel]=currLook(); UI.refreshCue() end end,{Size=UDim2.new(0,90,0,28)})
btn(cueRow,"Hapus Cue",function() if S.cueSel then S.cues[S.cueSel]=nil; UI.refreshCue() end end,{Size=UDim2.new(0,90,0,28)})
btn(cueRow,"Off Semua",function() UI.offAll() end,{Size=UDim2.new(0,90,0,28)})
local cNav=rowF(tCue,nil,8)
btn(cNav,"<",function() S.cuePage=S.cuePage-1; if S.cuePage<1 then S.cuePage=8 end; UI.refreshCue() end,{Size=UDim2.new(0,40,0,28)})
cuePageLbl=lbl(cNav,"",{Size=UDim2.new(0,170,0,28),TextXAlignment=Enum.TextXAlignment.Center,TextSize=12})
btn(cNav,">",function() S.cuePage=S.cuePage+1; if S.cuePage>8 then S.cuePage=1 end; UI.refreshCue() end,{Size=UDim2.new(0,40,0,28)})

-- ══════════════════════════════════════════════
--  TAB: BRIDGE
-- ══════════════════════════════════════════════
local tBrg=tabFrames["Bridge"]

local bInfoBox=boxF(tBrg,"STATUS KONEKSI ART-NET BRIDGE",10)
local bStatus=lbl(bInfoBox,"Status: Belum terhubung",{Size=UDim2.new(1,0,0,22),TextSize=13,TextColor3=C.red})
local bFrames=lbl(bInfoBox,"Frame diterima: 0",{Size=UDim2.new(1,0,0,18),TextSize=11,TextColor3=C.muted})
local bUrl=lbl(bInfoBox,"URL: "..BRIDGE_URL,{Size=UDim2.new(1,0,0,18),TextSize=10,TextColor3=C.muted})

function UI.refreshBridgeStatus()
  bStatus.Text="Status: "..S.bridgeMsg
  bStatus.TextColor3=S.bridgeConn and C.green or C.red
  bFrames.Text="Frame diterima: "..S.bridgeFrames
end

local bCfgBox=boxF(tBrg,"KONFIGURASI BRIDGE",10)
lbl(bCfgBox,"URL Server (default: 127.0.0.1:5311)",{Size=UDim2.new(1,0,0,18),TextSize=10,TextColor3=C.muted})
local urlInput=mkInput(bCfgBox,BRIDGE_URL,400,function(t)
  BRIDGE_URL=t; bUrl.Text="URL: "..BRIDGE_URL
end)

local bHowBox=boxF(tBrg,"CARA PAKAI BRIDGE MODE",10)
for _,line in ipairs({
  "1.  Jalankan  server.py  di PC (pip install -r requirements.txt)",
  "2.  Jalankan  artnet2WSS.py  → isi username = nama akun Roblox kamu",
  "3.  Sambungkan konsol Art-Net (MagicQ dll.) ke PC via Art-Net/UDP",
  "4.  Di sini klik tombol  ◎ BRIDGE MODE  di master bar atas",
  "5.  Status berubah hijau = data Art-Net mengalir ke lampu Roblox",
  "6.  Klik lagi untuk kembali ke mode mixer manual",
  "",
  "Catatan: Bridge Mode & Manual Mode tidak bisa jalan bersamaan.",
  "Tab Fixture / Program / Shape masih bisa dipakai untuk preview.",
}) do lbl(bHowBox,line,{Size=UDim2.new(1,0,0,18),TextSize=10,TextColor3=C.muted}) end

-- ══════════════════════════════════════════════
--  TAB: SAVE
-- ══════════════════════════════════════════════
local tSave=tabFrames["Save"]
local sRow=rowF(tSave,nil,8)
local saveName=mkInput(sRow,"",320,nil,"Nama project…")
btn(sRow,"💾 Save",function()
  local n=saveName.Text:match("^%s*(.-)%s*$"); if n=="" then n="Pearl_Show" end
  saves[n]=snapshotAll(); writeSaves(); saveName.Text=""; UI.refreshSaves()
end,{Size=UDim2.new(0,76,0,28)})
btn(rowF(tSave,nil,8),"⟳ Reset Polos",function()
  clearFixtures(); applyBeamProfile("R1"); S.ptShape="OFF"; S.dimShape="OFF"; S.cues={}; S.chaseSteps={}
  UI.rebuildAll(); UI.refreshShape(); UI.refreshCue(); UI.refreshChase()
end,{Size=UDim2.new(0,120,0,28)})
local saveInfoLbl=lbl(tSave,"",{Size=UDim2.new(1,0,0,18),TextColor3=C.muted,TextSize=10})
local saveList
function UI.refreshSaves()
  if saveList then saveList:Destroy() end
  saveList=new("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,LayoutOrder=20},tSave)
  new("UIListLayout",{Padding=UDim.new(0,4),SortOrder=Enum.SortOrder.LayoutOrder},saveList)
  local names={}; for n in pairs(saves) do names[#names+1]=n end; table.sort(names)
  saveInfoLbl.Text=fileOk() and ("File: "..FILE.."  |  "..#names.." save") or "Executor tidak support file."
  for i,n in ipairs(names) do
    local r=new("Frame",{BackgroundColor3=C.card,Size=UDim2.new(1,0,0,30),BorderSizePixel=0,LayoutOrder=i},saveList)
    corner(r,5); stroke(r)
    lbl(r,n,{Position=UDim2.new(0,8,0,0),Size=UDim2.new(1,-150,1,0),TextSize=11})
    btn(r,"Load",function()
      applySnapshot(saves[n])
      for pk,pb in pairs(profBtns) do setActive(pb,pk==S.beamProfile) end
      UI.rebuildAll(); UI.refreshShape(); UI.refreshCue(); UI.refreshChase(); UI.syncProgramSliders()
    end,{Position=UDim2.new(1,-140,0.5,-13),Size=UDim2.new(0,56,0,26)})
    btn(r,"Delete",function() saves[n]=nil; writeSaves(); UI.refreshSaves() end,
      {Position=UDim2.new(1,-78,0.5,-13),Size=UDim2.new(0,62,0,26),BackgroundColor3=C.red})
  end
end

-- ══════════════════════════════════════════════
--  FUNGSI REFRESH GLOBAL
-- ══════════════════════════════════════════════
function UI.refreshSel()
  for i,f in ipairs(fixtures) do
    if stripBtns[i] then
      stripBtns[i].BackgroundColor3=f.sel and C.cyan or C.dim
      stripBtns[i].TextColor3=f.sel and C.black or C.text
    end
  end; UI.refreshLayout()
end
function UI.rebuildAll()
  UI.rebuildStrip(); UI.refreshSel(); renderFixList(); rebuildMonitor(); UI.refreshFooter()
end
function UI.offAll()
  S.ptShape="OFF"; S.dimShape="OFF"; S.chasePlay=false
  for _,f in ipairs(fixtures) do f.dimBase=0;f.dimOut=0;f.panBase=S.panCenter;f.tiltBase=S.tiltCenter end
  S.cueSel=nil; UI.refreshShape(); UI.refreshCue(); UI.refreshChase(); UI.syncProgramSliders()
end

-- ══════════════════════════════════════════════
--  INISIALISASI
-- ══════════════════════════════════════════════
readSaves()
UI.rebuildAll(); UI.refreshShape(); UI.refreshCue(); UI.refreshChase(); UI.refreshSaves()
mSl.set(S.master)
switchTab("Fixture")
UI.refreshTest()
UI.refreshBridgeStatus()

-- ══════════════════════════════════════════════
--  MAIN LOOP
-- ══════════════════════════════════════════════
local acc,uiAcc,carAcc=0,0,0
track(RunService.Heartbeat:Connect(function(dt)
  if not S.running then return end
  if S.mode=="MANUAL" then stepEffects(dt) end
  acc=acc+dt
  if acc>=1/SEND_HZ then acc=0; sendFrame() end
  uiAcc=uiAcc+dt
  if uiAcc>=0.10 then
    uiAcc=0
    local first; for _,f in ipairs(fixtures) do if f.sel then first=f; break end end
    first=first or fixtures[1]
    if first then
      xyDot.Position=UDim2.new(clamp(first.pan/255,0.05,0.95),0,clamp(first.tilt/255,0.05,0.95),0)
      liveTxt.Text=string.format("Shape P/T: %s  |  Dim Shape: %s\nPan=%d  Tilt=%d  Dim=%d  |  Mode: %s",
        S.ptShape,S.dimShape,round(first.pan),round(first.tilt),round(first.dimOut),S.mode)
    else
      liveTxt.Text="Belum ada fixture  |  Mode: "..S.mode
    end
    if S.tab=="Shape" then
      for i,f in ipairs(fixtures) do
        local bar=monBars[i]
        if bar then bar.Size=UDim2.new(clamp((S.blackout and 0 or f.dimOut)/255,0,1),0,0,3) end
      end
    end
    if S.tab=="Bridge" then UI.refreshBridgeStatus() end
  end
  carAcc=carAcc+dt
  if carAcc>=1 then
    carAcc=0
    remote=findRemote()
    local now=remote~=nil
    if now~=S.car then S.car=now; UI.refreshFooter() end
  end
end))

-- ══════════════════════════════════════════════
--  STOP & REGISTER
-- ══════════════════════════════════════════════
local function stop()
  S.running=false
  for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  pcall(function() gui:Destroy() end)
  if _G.WANZZMIXER and _G.WANZZMIXER.id==S.id then _G.WANZZMIXER=nil end
  if _G.DMXBridgeStop==stop then _G.DMXBridgeStop=nil end
end
S.id=tostring(os.clock())..tostring(random(1,1e6))
track(closeBtn.Activated:Connect(stop))
_G.WANZZMIXER={stop=stop,id=S.id}
_G.DMXBridgeStop=stop

print("╔══════════════════════════════════════╗")
print("║   WANZZMIXER V6 — PEARL 1024B BRIDGE ║")
print("╚══════════════════════════════════════╝")
