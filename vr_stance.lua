-- Immersive VR moveset (CUSTOM build) with an added Stance toggle.
-- Based on the owner's "Immersive VR" moveset (content/v_moveset1.lua).
-- Adds an on-screen "Stance" button (same style as the L/R/C/Run buttons) that
-- toggles the IDLE leg pose between the ORIGINAL (legs in front) and a MODIFIED
-- upright stance (legs plant straight down, character stands taller).
-- Crouch behaviour is unchanged (legs stay in front while crouched).
--
-- Drop this in your executor's  UhhhhhhReanim/CustomModules/  folder, then open
-- the menu -> Custom (or press "Reload Modules"). Loads under the Custom section.

local modules = {}
local function AddModule(m) table.insert(modules, m) end

cloneref = cloneref or function(o) return o end
local RunService = cloneref(game:GetService("RunService"))
local TweenService = cloneref(game:GetService("TweenService"))
local Players = cloneref(game:GetService("Players"))
local UserInputService = cloneref(game:GetService("UserInputService"))
local StarterGui = cloneref(game:GetService("StarterGui"))
local Player = Players.LocalPlayer

-- [DEBUG] temporary on-screen notify to diagnose the joysticks
local function DbgNotify(text)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = "VRStance", Text = tostring(text), Duration = 4 })
	end)
end

AddModule(function()
	local VRService = cloneref(game:GetService("VRService"))
	
	local m = {}
	m.ModuleType = "MOVESET"
	m.Name = "Immersive VR (Stance)"
	m.Description = "fake but real vr altho clunky — custom build w/ Stance toggle\n\nM1 - Point Left Hand\nM2 - Point Right Hand\nLeftControl/Button B - Toggle Run\nC - Crouch\nF / Stance button - Toggle upright idle stance"
	m.Assets = {}

	m.Config = function(parent: GuiBase2d)
		Util_CreateSwitch(parent, "Proper Arm Control (joysticks)", ProperArms).Changed:Connect(function(v)
			ProperArms = v
			DbgNotify("ProperArms = " .. tostring(v))
		end)
	end

	local scale, isdancing = 1, false
	local hum, root, torso

	local function SetCFrame(part, cf)
		part.CFrame = cf
		part.Velocity, part.RotVelocity = Vector3.zero, Vector3.zero
		local antigravity = Instance.new("BodyForce", part)
		antigravity.Force = Vector3.new(0, workspace.Gravity * part:GetMass(), 0)
		RunService.PreRender:Once(function()
			part.CFrame = cf
			part.Velocity, part.RotVelocity = Vector3.zero, Vector3.zero
		end)
		RunService.Stepped:Once(function()
			part.CFrame = cf
			part.Velocity, part.RotVelocity = Vector3.zero, Vector3.zero
		end)
		RunService.PostSimulation:Once(function()
			antigravity:Destroy()
		end)
	end

	local rcp = RaycastParams.new()
	rcp.FilterType = Enum.RaycastFilterType.Exclude
	rcp.RespectCanCollide = true
	rcp.IgnoreWater = true
	local function PhysicsRaycast(origin, direction)
		return workspace:Raycast(origin, direction, rcp)
	end
	local mouse = Player:GetMouse()
	local function MouseHit()
		local ray = mouse.UnitRay
		local dist = 2000
		local raycast = PhysicsRaycast(ray.Origin, ray.Direction * dist)
		if raycast then
			return raycast.Position
		end
		return ray.Origin + ray.Direction * dist
	end

	-- grok made ts
	local function IK2Bone(from: Vector3, target: Vector3, direction: Vector3, lenA: number, lenB: number): CFrame
		-- 2-segment IK solver (upper arm lenA, forearm lenB). Returns CFrame at target position
		-- whose rotation orients the bone next to the hand (forearm) using the pole direction
		-- for the elbow bend plane. Logic tested: elbow solved via law-of-cosines + pole projection;
		-- last bone roll is pole-consistent so the entire chain stays in the correct plane.
		-- Handles full extension when unreachable; assumes reachable for under-extension (standard).

		local root = from
		local goal = target
		local pole = direction

		local toGoal = goal - root
		local dist = toGoal.Magnitude
		if dist < 1e-6 then
			return CFrame.new(goal) -- degenerate case, no valid plane
		end

		local dir = toGoal / dist

		-- project pole onto plane perpendicular to dir (defines bend direction)
		local poleProj = pole - dir * pole:Dot(dir)
		local poleMag = poleProj.Magnitude
		if poleMag < 1e-6 then
			-- fallback perpendicular (avoids singularity)
			local arb = Vector3.yAxis
			if math.abs(dir:Dot(arb)) > 0.99 then
				arb = Vector3.xAxis
			end
			poleProj = (arb - dir * arb:Dot(dir)).Unit
		else
			poleProj /= poleMag
		end

		-- compute elbow position
		local elbowPos
		if dist > lenA + lenB then
			-- fully extended toward target (unreachable case)
			elbowPos = root + dir * lenA
		else
			-- standard triangle solution
			local a = (lenA * lenA + dist * dist - lenB * lenB) / (2 * dist)
			local hSq = lenA * lenA - a * a
			local h = hSq > 0 and math.sqrt(hSq) or 0
			elbowPos = root + dir * a + poleProj * h
		end

		-- forearm direction (bone next to hand)
		local boneDir = (goal - elbowPos).Unit

		-- project pole onto plane perpendicular to forearm for consistent roll/up
		local desiredUp = pole - boneDir * pole:Dot(boneDir)
		local upMag = desiredUp.Magnitude
		if upMag < 1e-6 then
			local arb = Vector3.yAxis
			if math.abs(boneDir:Dot(arb)) > 0.99 then
				arb = Vector3.xAxis
			end
			desiredUp = (arb - boneDir * arb:Dot(boneDir)).Unit
		else
			desiredUp /= upMag
		end

		-- CFrame at target with LookVector along bone (forward = boneDir from elbow → hand)
		-- and UpVector pole-projected so rotation respects "elbow points" direction
		return CFrame.lookAt(goal, goal + boneDir, desiredUp)
	end

	local rj, nj, rsj, lsj, rhj, lhj, scale

	local LegsTarget = {}
	local FakeVRArms = {}
	local Crouching = false
	local StanceUpright = false -- [STANCE] false = original legs-in-front idle, true = legs straight down
	local StanceLift = 0 -- [STANCE] smooth body lift while upright idle so feet aren't in the ground
	local ProperArms = false -- [ARMS] false = M1/M2 point, true = on-screen joysticks aim the arms
	local LeftJoy, RightJoy -- joystick objects {Base,Knob,Held,Vec,Input}
	local JoyGui -- dedicated always-on-top ScreenGui that holds the joysticks
	local JoyConns = {}
	local CrouchDistance = 0
	local TorsoRotation = CFrame.identity

	local CROUCH_DISTANCE = 1.25
	local LEG_TWEEN_TIME = 0.25
	local LEG_MOVE_TIME = 0.25

	local function GetLegPoint(leg)
		if leg.InAir then
			return leg.Position
		end
		local tweener = math.clamp(leg.Timer / LEG_TWEEN_TIME, 0, 1)
		return leg.Target:Lerp(leg.Position, tweener) + Vector3.new(0, math.sin(math.pi * tweener) * (leg.Target - leg.Position).Magnitude * 0.1, 0)
	end
	local function ProcessLegs(leg, dt)
		local last
		for _=1, 1 do
			last = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1) * 0.2
			for i=1, #leg.Realism do
				last = last:Lerp(leg.Realism[i], math.exp(-16 * dt))
				leg.Realism[i] = last
			end
		end
		local real = CFrame.Angles(last.X, last.Y, last.Z)
		-- [STANCE] Decisive idle leg posing. While standing still (no movement input)
		-- we plant the feet at a fixed clean target instead of the dynamic stepping,
		-- which avoids the legs flipping/twisting (esp. while crouched with a leaning
		-- back). Pole points straight down + slightly forward so knees bend forward,
		-- not behind. Walking falls through to the original stepping logic below.
		if StanceUpright and not Crouching and hum.MoveDirection.Magnitude < 0.1 then
			local orig = torso.CFrame * (leg.Offset * scale)
			-- upright stance: feet straight down under the hips (legs straight, taller).
			-- Crouch is intentionally NOT handled here — it uses the normal stepping
			-- legs (standing animation), just lowered by the crouch.
			local foot = orig - Vector3.new(0, 1.9 * scale, 0)
			if foot then
				leg.Position, leg.Target, leg.InAir = foot, foot, false
				leg.Timer = leg.Timer % 1
				-- pole/bend reference: mostly downward, leaning forward, in world space
				-- so the leaning torso doesn't drag the knee direction behind the back.
				local poledir = (root.CFrame.LookVector * 0.5 - Vector3.new(0, 1, 0)).Unit
				return IK2Bone(orig, foot, poledir, 0.7 * scale, 1.2 * scale) * real * CFrame.Angles(1.57, 0, 0) * CFrame.new(0, 1 * scale, 0)
			end
		end
		local onground = hum:GetState() == Enum.HumanoidStateType.Running
		local origin = torso.CFrame * (leg.Offset * scale) + root.CFrame.LookVector * scale + root.Velocity * (LEG_MOVE_TIME * 0.6)
		local dir = (Vector3.new(0, -3, 0) - root.CFrame.LookVector * 1.5) * scale
		if hum:GetState() == Enum.HumanoidStateType.Climbing then
			onground = true
			origin = torso.CFrame * (leg.Offset * scale) + Vector3.new(0, -0.5, 0) * scale
			dir = root.CFrame.LookVector * 3 * scale
		end
		local tgt = leg.Position
		if onground then
			leg.Timer += dt / LEG_MOVE_TIME
			if leg.Timer >= 1 then
				leg.Timer %= 1
				leg.Target = leg.Position
				local cast = PhysicsRaycast(origin, dir)
				if cast then
					cast = cast.Position
				else
					cast = origin + Vector3.new(0, -2, 0)
				end
				leg.Position = cast
			end
			local tweener = math.clamp(leg.Timer / LEG_TWEEN_TIME, 0, 1)
			tgt = leg.Target:Lerp(leg.Position, tweener) + Vector3.new(0, math.sin(math.pi * tweener) * (leg.Target - leg.Position).Magnitude * 0.1, 0)
		else
			leg.InAir = true
			tgt = torso.CFrame * ((leg.Offset + Vector3.new(0, -1.3, -0.3)) * scale)
			tgt = tgt:Lerp(leg.Position + root.Velocity * dt, math.exp(-16 * dt))
			leg.Position = tgt
			leg.Target = tgt
		end
		if leg.InAir then
			leg.InAir = false
			leg.Timer = (leg.Timer % 1) + 1
		end
		local orig = torso.CFrame * (leg.Offset * scale)
		local dir = root.CFrame.Rotation * Vector3.new(leg.Offset.X, 0, -2)
		if (tgt - orig).Magnitude > 2.1 * scale then
			tgt = orig + (tgt - orig).Unit * 2.1 * scale
			return CFrame.lookAlong(tgt, tgt - orig, orig, dir) * real * CFrame.Angles(1.57, 0, 0) * CFrame.new(0, 1 * scale, 0)
		end
		return IK2Bone(orig, tgt, dir, 0.7 * scale, 1.2 * scale) * real * CFrame.Angles(1.57, 0, 0) * CFrame.new(0, 1 * scale, 0)
	end
	local function ProcessArms(arm, dt, vro, headcf, js)
		local last
		for _=1, 1 do
			last = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1) * 0.5
			for i=1, #arm.Realism do
				last = last:Lerp(arm.Realism[i], math.exp(-16 * dt))
				arm.Realism[i] = last
			end
		end
		local cast
		local pointing
		if ProperArms and js then
			-- [ARMS] Joystick aim, camera-relative. Centre -> forward, the stick tilts
			-- the aim up/down/left/right. Released -> arm falls back to its rest (down) pose.
			pointing = js.Held
			local cam = ReanimCamera.CFrame
			local dir = cam.LookVector + cam.RightVector * (js.Vec.X * 1.3) + cam.UpVector * (js.Vec.Y * 1.3)
			if dir.Magnitude < 1e-3 then dir = cam.LookVector end
			cast = dir.Unit
		else
			pointing = arm.Waving
			cast = PhysicsRaycast(vro.Position, headcf.LookVector * 32 * scale)
			if cast then
				cast = (cast.Position - vro.Position - arm.Offset.Position).Unit
				if cast ~= cast or cast.Magnitude == 0 then
					cast = headcf.LookVector
				end
			else
				cast = headcf.LookVector
			end
		end
		local ha = CFrame.new(0, -0.5, 0) * CFrame.Angles(0.3 + last.X, last.Y, last.Z) * CFrame.new(0, -0.4, 0) * CFrame.Angles(-1.57, 0, 0)
		local hb = CFrame.lookAlong(Vector3.zero, cast) * CFrame.new(0, 0, -0.5) * CFrame.Angles(last.X, last.Y, last.Z) * CFrame.new(0, 0, -0.5)
		local tm = arm.Timer
		if pointing then
			tm = math.min(1, tm + dt / 0.2)
		else
			tm = math.max(0, tm - dt / 0.2)
		end
		arm.Timer = tm
		return arm.Offset * ha:Lerp(hb, TweenService:GetValue(tm, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut))
	end

	-- [ARMS] On-screen joystick used to aim an arm (mobile-friendly; also works with mouse).
	local function UpdateJoy(js, screenpos)
		local center = js.Base.AbsolutePosition + js.Base.AbsoluteSize / 2
		local radius = js.Base.AbsoluteSize.X / 2
		local delta = Vector2.new(screenpos.X, screenpos.Y) - center
		if delta.Magnitude > radius then delta = delta.Unit * radius end
		js.Knob.Position = UDim2.new(0.5, delta.X, 0.5, delta.Y)
		js.Vec = Vector2.new(delta.X / radius, -delta.Y / radius) -- y up = positive
	end
	local function MakeJoy(sideScale, sideOff)
		local base = Instance.new("Frame")
		base.Name = "Uhhhhhh_ArmJoy"
		base.AnchorPoint = Vector2.new(0.5, 0.5)
		base.Position = UDim2.new(sideScale, sideOff, 0.62, 0)
		base.Size = UDim2.fromOffset(120, 120)
		base.BackgroundColor3 = Color3.new(1, 0, 0) -- [DEBUG] bright red to confirm it renders
		base.BackgroundTransparency = 0.2
		base.BorderSizePixel = 0
		base.Visible = true -- [DEBUG] start visible
		base.Active = true -- sink input so dragging the stick doesn't pan camera/move
		base.ZIndex = 2
		base.Parent = JoyGui
		Instance.new("UICorner", base).CornerRadius = UDim.new(1, 0)
		local st = Instance.new("UIStroke", base)
		st.Color = Color3.new(1, 1, 1)
		st.Thickness = 1.5
		st.Transparency = 0.35
		local knob = Instance.new("Frame")
		knob.AnchorPoint = Vector2.new(0.5, 0.5)
		knob.Position = UDim2.fromScale(0.5, 0.5)
		knob.Size = UDim2.fromOffset(52, 52)
		knob.BackgroundColor3 = Color3.new(1, 1, 1)
		knob.BackgroundTransparency = 0.15
		knob.BorderSizePixel = 0
		knob.ZIndex = 3
		knob.Parent = base
		Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
		return { Base = base, Knob = knob, Held = false, Vec = Vector2.zero, Input = nil }
	end
	local function WireJoy(js)
		table.insert(JoyConns, js.Base.InputBegan:Connect(function(input)
			if not ProperArms then return end
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				js.Held = true
				js.Input = input
				UpdateJoy(js, input.Position)
			end
		end))
		table.insert(JoyConns, UserInputService.InputChanged:Connect(function(input)
			if not js.Held or not js.Input then return end
			if input == js.Input or (js.Input.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement) then
				UpdateJoy(js, input.Position)
			end
		end))
		table.insert(JoyConns, UserInputService.InputEnded:Connect(function(input)
			if js.Held and js.Input and (input == js.Input or input.UserInputType == js.Input.UserInputType) then
				js.Held = false
				js.Input = nil
				js.Vec = Vector2.zero
				js.Knob.Position = UDim2.fromScale(0.5, 0.5)
			end
		end))
	end
	m.Init = function(figure: Model)
		hum = figure:FindFirstChild("Humanoid")
		root = figure:FindFirstChild("HumanoidRootPart")
		torso = figure:FindFirstChild("Torso")
		if not hum then return end
		if not root then return end
		if not torso then return end
		hum.WalkSpeed = 12
		--ReanimCamera.FPSLocked = true
		for _,v in figure:GetChildren() do
			if v:IsA("BasePart") then
				for _,w in figure:GetChildren() do
					if v ~= w and w:IsA("BasePart") then
						local nocoll = Instance.new("NoCollisionConstraint", v)
						nocoll.Part0, nocoll.Part1 = v, w
					end
				end
			end
		end
		LegsTarget = {
			{
				Position = root.CFrame * Vector3.new(-0.5, -3, 0),
				Offset = Vector3.new(-0.5, -1, 0),
				Target = root.CFrame * Vector3.new(-0.5, -3, 0),
				Timer = 0.5,
				Realism = {
					Vector3.zero,
					Vector3.zero,
					Vector3.zero,
					Vector3.zero,
				},
				InAir = false,
			},
			{
				Position = root.CFrame * Vector3.new(0.5, -3, 0),
				Offset = Vector3.new(0.5, -1, 0),
				Target = root.CFrame * Vector3.new(0.5, -3, 0),
				Timer = 0,
				Realism = {
					Vector3.zero,
					Vector3.zero,
					Vector3.zero,
					Vector3.zero,
				},
				InAir = false,
			},
		}
		FakeVRArms = {
			{
				Timer = 1,
				Realism = {
					Vector3.zero,
					Vector3.zero,
					Vector3.zero,
					Vector3.zero,
				},
				Waving = false,
				Offset = CFrame.new(-1.5, -1, 0),
			},
			{
				Timer = 1,
				Realism = {
					Vector3.zero,
					Vector3.zero,
					Vector3.zero,
					Vector3.zero,
				},
				Waving = false,
				Offset = CFrame.new(1.5, -1, 0),
			},
		}
		Crouching = false
		CrouchDistance = 0
		ContextActions:BindAction("Uhhhhhh_VRWaveL", function(_, state, _)
			if state == Enum.UserInputState.Begin then
				FakeVRArms[1].Waving = true
			end
			if state == Enum.UserInputState.End then
				FakeVRArms[1].Waving = false
			end
		end, true, Enum.UserInputType.MouseButton1)
		ContextActions:SetTitle("Uhhhhhh_VRWaveL", "L")
		ContextActions:SetPosition("Uhhhhhh_VRWaveL", UDim2.new(1, -230, 1, -130))
		ContextActions:BindAction("Uhhhhhh_VRWaveR", function(_, state, _)
			if state == Enum.UserInputState.Begin then
				FakeVRArms[2].Waving = true
			end
			if state == Enum.UserInputState.End then
				FakeVRArms[2].Waving = false
			end
		end, true, Enum.UserInputType.MouseButton2)
		ContextActions:SetTitle("Uhhhhhh_VRWaveR", "R")
		ContextActions:SetPosition("Uhhhhhh_VRWaveR", UDim2.new(1, -180, 1, -130))
		ContextActions:BindAction("Uhhhhhh_VRCrouch", function(_, state, _)
			if state == Enum.UserInputState.Begin then
				Crouching = not Crouching
			end
		end, true, Enum.KeyCode.C)
		ContextActions:SetTitle("Uhhhhhh_VRCrouch", "C")
		ContextActions:SetPosition("Uhhhhhh_VRCrouch", UDim2.new(1, -130, 1, -230))
		ContextActions:BindAction("Uhhhhhh_VRRun", function(_, state, _)
			if state == Enum.UserInputState.Begin then
				if hum.WalkSpeed == 12 then
					hum.WalkSpeed = 24
				else
					hum.WalkSpeed = 12
				end
			end
		end, true, Enum.KeyCode.LeftControl, Enum.KeyCode.ButtonB)
		ContextActions:SetTitle("Uhhhhhh_VRRun", "Run")
		ContextActions:SetPosition("Uhhhhhh_VRRun", UDim2.new(1, -180, 1, -230))
		-- [STANCE] On-screen button (mobile-tappable, like L/R/C/Run) + F key.
		-- Toggles the idle leg pose between original (legs in front) and upright.
		StanceUpright = false
		ContextActions:BindAction("Uhhhhhh_VRStance", function(_, state, _)
			if state == Enum.UserInputState.Begin then
				StanceUpright = not StanceUpright
			end
		end, true, Enum.KeyCode.F)
		ContextActions:SetTitle("Uhhhhhh_VRStance", "Stance")
		ContextActions:SetPosition("Uhhhhhh_VRStance", UDim2.new(1, -230, 1, -230))
		-- [ARMS] Dedicated always-on-top ScreenGui for the joysticks (so they aren't
		-- hidden behind the menu and don't depend on the main GUI's z-order).
		JoyGui = Instance.new("ScreenGui")
		JoyGui.Name = "Uhhhhhh_ArmJoysticks"
		JoyGui.ResetOnSpawn = false
		JoyGui.IgnoreGuiInset = true
		JoyGui.DisplayOrder = 100000
		JoyGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		JoyGui.Enabled = true
		-- IMPORTANT: parent to a container that actually renders a ScreenGui. Never nest
		-- inside another ScreenGui (e.g. HiddenGui) — that silently renders nothing.
		local guiparent
		pcall(function() guiparent = gethui() end)
		if not guiparent then pcall(function() guiparent = cloneref(game:GetService("CoreGui")) end) end
		if not guiparent then guiparent = Player:FindFirstChildOfClass("PlayerGui") end
		JoyGui.Parent = guiparent
		-- Build the two aim joysticks (left-arm on the left, right-arm on the right).
		LeftJoy = MakeJoy(0, 100)
		RightJoy = MakeJoy(1, -100)
		WireJoy(LeftJoy)
		WireJoy(RightJoy)
		DbgNotify("joysticks built, parent=" .. tostring(JoyGui.Parent and JoyGui.Parent.ClassName or "NIL"))
	end
	m.Update = function(dt: number, figure: Model)
		local t = os.clock()
		scale = figure:GetScale()
		isdancing = not not figure:GetAttribute("IsDancing")
		rcp.FilterDescendantsInstances = {figure, Player.Character}

		-- [DEBUG] force the joysticks visible regardless of the toggle, to test rendering.
		if LeftJoy then LeftJoy.Base.Visible = not isdancing end
		if RightJoy then RightJoy.Base.Visible = not isdancing end

		-- get vii
		hum = figure:FindFirstChild("Humanoid")
		root = figure:FindFirstChild("HumanoidRootPart")
		torso = figure:FindFirstChild("Torso")
		if not hum then return end
		if not root then return end
		if not torso then return end

		-- joints
		local rj = root:FindFirstChild("RootJoint")
		local nj = torso:FindFirstChild("Neck")
		local rsj = torso:FindFirstChild("Right Shoulder")
		local lsj = torso:FindFirstChild("Left Shoulder")
		local rhj = torso:FindFirstChild("Right Hip")
		local lhj = torso:FindFirstChild("Left Hip")

		if Crouching then
			CrouchDistance = CROUCH_DISTANCE + (CrouchDistance - CROUCH_DISTANCE) * math.exp(-16 * dt)
		else
			CrouchDistance *= math.exp(-16 * dt)
		end

		-- [STANCE] Smoothly raise the body while standing upright + idle so the
		-- straightened legs reach the floor instead of sinking into it.
		local liftTarget = (StanceUpright and not Crouching and hum.MoveDirection.Magnitude < 0.1) and 0.5 or 0
		StanceLift = liftTarget + (StanceLift - liftTarget) * math.exp(-16 * dt)

		if not isdancing then
			rj.Enabled, nj.Enabled, rsj.Enabled, lsj.Enabled, rhj.Enabled, lhj.Enabled = false, false, false, false, false, false
			--hum.HipHeight = 2 * scale
			hum.HipHeight = 2 * scale - 2 - CrouchDistance * scale + StanceLift * scale
			root.CustomPhysicalProperties = PhysicalProperties.new(3.15, 0.3, 0.5)
			local head = figure:FindFirstChild("Head")
			local rarm = figure:FindFirstChild("Right Arm")
			local larm = figure:FindFirstChild("Left Arm")
			local rleg = figure:FindFirstChild("Right Leg")
			local lleg = figure:FindFirstChild("Left Leg")
			local chead, clarm, crarm
			local vro = root.CFrame * CFrame.new(0, 1.5 * scale, 0)
			local vroot = root.CFrame
			vro += Vector3.new(0, CrouchDistance * scale, 0)
			-- [CROUCH] (removed `vroot += CrouchDistance`) keeping the torso bottom down
			-- with the rest lowers the whole torso vertically instead of bending/tilting
			-- it, so crouch reads like the standing pose, just lower.
			if VRService.VREnabled then
				chead, clarm, crarm = VRService:GetUserCFrame(Enum.UserCFrame.Head), VRService:GetUserCFrame(Enum.UserCFrame.LeftHand), VRService:GetUserCFrame(Enum.UserCFrame.RightHand)
				if ReanimCamera:IsFirstPerson() then
					local _, y, _ = chead:ToEulerAngles(Enum.RotationOrder.YXZ)
					vro *= CFrame.Angles(0, -y, 0)
				end
			else
				local x, y, z = root.CFrame.Rotation:ToObjectSpace(ReanimCamera.CFrame.Rotation):ToEulerAngles(Enum.RotationOrder.YXZ)
				if ReanimCamera:IsFirstPerson() then
					y *= 0
				else
					if math.abs(y) > math.pi / 2 then
						y = math.pi - y
					end
				end
				chead = CFrame.new(0, -0.5, 0) * CFrame.fromEulerAngles(x, y, z, Enum.RotationOrder.YXZ) * CFrame.new(0, 0.5, 0) + Vector3.new(0, -CrouchDistance, 0)
				clarm = ProcessArms(FakeVRArms[1], dt, vro, chead, LeftJoy) + Vector3.new(0, -CrouchDistance, 0)
				crarm = ProcessArms(FakeVRArms[2], dt, vro, chead, RightJoy) + Vector3.new(0, -CrouchDistance, 0)
			end
			chead += chead.Position * (scale - 1)
			clarm += clarm.Position * (scale - 1)
			crarm += crarm.Position * (scale - 1)
			local armo = CFrame.Angles(1.57, 0, 0) * CFrame.new(0, 0, 0)
			SetCFrame(head, vro * chead)
			SetCFrame(larm, vro * clarm * armo)
			SetCFrame(rarm, vro * crarm * armo)
			local z1, z2 = vroot:PointToObjectSpace(GetLegPoint(LegsTarget[1])).Z, vroot:PointToObjectSpace(GetLegPoint(LegsTarget[2])).Z
			local yabai = CFrame.Angles(0, math.atan(z1 - z2) * 0.5 / scale, 0)
			TorsoRotation = yabai:Lerp(TorsoRotation, math.exp(-4 * dt))
			SetCFrame(torso, IK2Bone(
				vroot * Vector3.new(0, -3 * scale, 0),
				vro * chead * Vector3.new(0, -0.5 * scale, 0),
				-vroot.LookVector, 1.5 * scale, 1.5 * scale)
			 * CFrame.Angles(1.57, 3.14, 3.14) * CFrame.new(0, -1 * scale, 0) * TorsoRotation)
			SetCFrame(lleg, ProcessLegs(LegsTarget[1], dt))
			SetCFrame(rleg, ProcessLegs(LegsTarget[2], dt))
		else
			rj.Enabled, nj.Enabled, rsj.Enabled, lsj.Enabled, rhj.Enabled, lhj.Enabled = true, true, true, true, true, true
			hum.HipHeight = 2 * scale - 2
			root.CustomPhysicalProperties = nil
		end
	end
	m.Destroy = function(figure: Model?)
		ContextActions:UnbindAction("Uhhhhhh_VRWaveL")
		ContextActions:UnbindAction("Uhhhhhh_VRWaveR")
		ContextActions:UnbindAction("Uhhhhhh_VRCrouch")
		ContextActions:UnbindAction("Uhhhhhh_VRRun")
		ContextActions:UnbindAction("Uhhhhhh_VRStance")
		-- [ARMS] tear down joysticks + their input connections
		for _, c in JoyConns do pcall(function() c:Disconnect() end) end
		table.clear(JoyConns)
		LeftJoy, RightJoy = nil, nil
		if JoyGui then JoyGui:Destroy() JoyGui = nil end
	end
	return m
end)

return modules
