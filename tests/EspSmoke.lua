-- Validate projected geometry and the real Drawing property contract.
local Vector3={}
Vector3.__index=function(v,k)
    if k=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end
    return Vector3[k]
end
function Vector3.new(x,y,z) return setmetatable({X=x,Y=y,Z=z},Vector3) end
Vector3.__add=function(a,b) return Vector3.new(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
Vector3.__sub=function(a,b) return Vector3.new(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
Vector3.__mul=function(a,b)
    if type(b)=="number" then return Vector3.new(a.X*b,a.Y*b,a.Z*b) end
    return Vector3.new(a.X*b.X,a.Y*b.Y,a.Z*b.Z)
end
local CFrame={}
function CFrame.new(position,angle)
    local c,s=math.cos(angle or 0),math.sin(angle or 0)
    return {Position=position,LookVector=Vector3.new(0,0,1),
        PointToWorldSpace=function(_,p) return position+Vector3.new(p.X*c-p.Y*s,p.X*s+p.Y*c,p.Z) end,
        PointToObjectSpace=function(_,p) p=p-position; return Vector3.new(p.X*c+p.Y*s,-p.X*s+p.Y*c,p.Z) end}
end
CFrame.lookAt=function(position) return CFrame.new(position) end
local Drawing
-- ESP_MODULE

local target=Instance.new("Model",workspace)
target.Name="OtherPlayer"
local humanoid=Instance.new("Humanoid",target)
humanoid.Health,humanoid.MaxHealth=75,100
local function part(name,position,size,transparency)
    local p=Instance.new("Part",target)
    p.Name,p.Position,p.Size,p.Transparency=name,position,size,transparency or 0
    p.CFrame=CFrame.new(position)
    rawset(p,"IsA",function(_,kind) return kind=="Part" or kind=="BasePart" end)
    return p
end
local root=part("HumanoidRootPart",Vector3.new(0,0,100),Vector3.new(2,2,1),1)
local torso=part("Torso",Vector3.new(0,0,100),Vector3.new(2,3,1))
local head=part("Head",Vector3.new(0,2,100),Vector3.new(1.5,1.5,1.5))
humanoid.RootPart=root
rawset(target,"GetDescendants",function() return {root,torso,head} end)
local owner=Instance.new("Player")
owner.Name,owner.Character="OtherPlayer",target
Players.GetPlayers=function() return {Players.LocalPlayer,owner} end
Players.GetPlayerFromCharacter=function(_,model) return model==target and owner or nil end
local stats=Instance.new("Folder",owner); stats.Name="PlayerStats"
local level=Instance.new("IntValue",stats); level.Name,level.Value="Level",250
workspace.CurrentCamera={CFrame=CFrame.new(Vector3.new(0,0,0)),ViewportSize=Vector2.new(800,600),
    WorldToViewportPoint=function(_,p) return Vector3.new(400+p.X*10,300-p.Y*10,p.Z),true end}

local function render()
    RunService.RenderStepped:Fire()
    assert(#SmokeEnv.Errors==0,table.concat(SmokeEnv.Errors,"\n"))
end
local function visible(lines)
    local count=0
    for _,line in ipairs(lines or {}) do
        if line.Gui then
            if line.Gui.Visible and not rawget(line.Gui,"_destroyed") then count+=1 end
        else
            for _,object in ipairs(line.Objects) do
                if object.Visible then
                    assert(object.Transparency==1 and object.Thickness>0,"invalid Drawing properties")
                    assert((object.To-object.From).Magnitude>0,"zero-length stroke")
                    count+=1
                end
            end
        end
    end
    return count
end

for _,draw in ipairs({false,true}) do
    Drawing=draw and {new=function(class)
        assert(class=="Line","unexpected Drawing primitive")
        return {Remove=function(self) self.Removed=true; self.Visible=false end}
    end} or nil
    for _,style in ipairs({"Full","Corners","Outline"}) do
        Players.LocalPlayer.Character=target
        local rectangles,cleanup={},nil
        local startup={IntroDone=true}
        local menu={Gui={Enabled=true,DisplayOrder=1000,Parent=Services.CoreGui},
            GetOcclusionRects=function() return rectangles end}
        local originalNew,highlightCalls=Instance.new,0
        Instance.new=function(class,...)
            if class=="Highlight" then highlightCalls+=1; error("native highlights unavailable") end
            return originalNew(class,...)
        end
        local feature=EspModule.Start({Services={Players=Players},Player=Players.LocalPlayer,
            UIRef={},AICUI={},CONFIG={},UI=menu,Startup=startup,
            Lifetime={OnEnd=function(fn) cleanup=fn end}})
        local kind=feature.S.Kinds.Player
        kind.Enabled,kind.Label,kind.Outline,kind.Box=true,true,style=="Outline",style~="Outline"
        feature.S.Settings.BoxStyle=style=="Corners" and "Corners" or "Full"
        feature:Update(1)
        Instance.new=originalNew
        local entry=assert(feature.S.Entries[target],"local player not scanned")
        assert(entry.BoxHeight and entry.BoxHeight>4,"rig measurement failed")
        render()
        local lines=style=="Outline" and entry.ContourLines or entry.BoxLines
        assert(visible(lines)>0,"style emitted no rendered strokes: "..style)
        assert(highlightCalls==0,"outline still relies on native Highlight")
        if draw then assert(lines[1].Objects and not lines[1].Gui,"Drawing backend not restored")
        else assert(lines[1].Gui,"GUI fallback missing") end
        if style~="Outline" then assert(#lines==(style=="Corners" and 8 or 4),"wrong box edge count")
        else
            assert(#entry.BodyParts==2,"outline includes invisible hitboxes")
            if draw then
                for _,line in ipairs(lines) do
                    local middle=(line.From+line.To)*.5
                    local seam=math.abs(middle.Y-287.5)<.01 or math.abs(middle.Y-285)<.01
                    assert(not (seam and middle.X>392.6 and middle.X<407.4),"internal overlapping-part seam was drawn")
                end
            end
            local before=lines[1].From
            torso.CFrame=CFrame.new(torso.Position,.3); render()
            if draw then assert((lines[1].From-before).Magnitude>.01,"outline ignores limb rotation") end
            torso.CFrame=CFrame.new(torso.Position)
            head.CFrame=CFrame.new(Vector3.new(0,2,-1))
            torso.CFrame=CFrame.new(Vector3.new(0,0,-1)); render()
            assert(visible(lines)==0,"body behind near plane emitted inverted outline")
            head.CFrame=CFrame.new(head.Position)
            torso.CFrame=CFrame.new(torso.Position)
        end
        rectangles={{397,260,403,280}}; render()
        assert(visible(lines)>0,"partial overlap erases entire target")
        if draw then
            local split=false
            for _,line in ipairs(lines) do
                if #line.Objects>1 then split=true end
                for _,object in ipairs(line.Objects) do
                    if object.Visible and math.abs(object.From.Y-object.To.Y)<.001
                        and object.From.Y>260 and object.From.Y<280 then
                        assert(math.max(object.From.X,object.To.X)<=397 or math.min(object.From.X,object.To.X)>=403,
                            "border crosses menu instead of clipping")
                    end
                end
            end
            if style=="Full" then assert(split,"menu crossing did not split the border") end
        end
        rectangles={{0,0,100,100},{350,200,500,380}}; render()
        assert(visible(lines)==0,"fully covered target not culled")
        rectangles={}; render(); assert(visible(lines)>0,"closing menus did not restore geometry")
        startup.IntroDone=false; render(); assert(visible(lines)==0,"ESP shows through intro")
        startup.IntroDone=true
        feature.S.Settings.Range=50; render(); assert(visible(lines)==0,"out-of-range geometry visible")
        feature.S.Settings.Range=900
        humanoid.Health=0; render(); assert(visible(lines)==0,"dead body outlined")
        humanoid.Health=75; render(); assert(visible(lines)>0,"live body did not resume drawing")
        for _,text in ipairs(entry.TextParts) do assert(text.Gui.Parent.DisplayOrder<1000,"text above menus") end
        cleanup(); assert(visible(lines)==0,"cleanup leaked Drawing objects")
    end
end
print("ESP SMOKE PASSED: reference boxes/corners, rotating body contours, menu segment clipping, GUI fallback, cleanup")
