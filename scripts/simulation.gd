extends RefCounted
# 纯数据战斗模拟器：界面、回放验证与数值测试共用。
# STEP 为每次模拟经过的秒数；加速通过增加步数实现，不改变单步规则。
# s 保存出征状态；enemies 是当前敌人；shots 只保存短暂的攻击表现。
# 预算 budget 用于建造；income / spent 记录本局金币收入和消费，二者不能混用。
## Pure fixed-step simulation. UI, replay verification and balance tests share this file.
const STEP = 1.0 / 30.0
const DIRS = [Vector2i(0,-1), Vector2i(1,0), Vector2i(0,1), Vector2i(-1,0)]
var rules: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/rules.json"))
var s: Dictionary = {}
var enemies: Array = []
var shots: Array = []
var fields: Array = []
var paths: Array = []
var wave_queue: Array = []
var spawn_clock = 0.0
var tick = 0
var events: Array = []
var report: Dictionary = {}
var defs: Dictionary = {}
var invalid_entries: Array = []

# 将蓝图列表转换为按 id 查询的字典，减少战斗期间的查找工作。
func _init():
	for d in rules.towers:
		defs[d.id] = d

# 将整数地格坐标转成字符串键，例如 Vector2i(2, 3) 对应 2,3。
func key(p: Vector2i) -> String:
	return "%d,%d" % [p.x,p.y]

# 将字符串地格键还原为整数坐标，与 key 配对使用。
func cell(k: String) -> Vector2i:
	var a = k.split(",")
	return Vector2i(int(a[0]),int(a[1]))

# 建立出征状态；使用固定种子生成岩体与地形，并确保入口可达核心。
func new_run(map_id: int, map_seed: int, meta: Dictionary, loadout: Array):
	var m = rules.maps[map_id]
	s = {"version":rules.version,"map":map_id,"seed":map_seed,"width":int(m.width),"height":int(m.height),
		"state":"prepare","wave":0,"completed":0,"hp":100,"max_hp":100,"budget":int(m.budget),
		"income":0,"spent":0,"buildings":{},"rocks":[],"terrain":{},"growth":{"power":0,"haste":0,"range":0},
		"meta":meta.duplicate(true),"loadout":loadout.duplicate(),"challenge":false,"challenge_bonus":false,
		"challenges_won":0,"reward_claimed":0,"shop_stock":[1,1,1],"kills":0,"leaks":0,"log":[],"commands":[],
		"auto_rebuild":false,"ruins":{},"run_id":"%d-%d" % [map_seed,Time.get_ticks_usec()]}
	enemies.clear()
	shots.clear()
	tick = 0
	var rng = RandomNumberGenerator.new()
	rng.seed = map_seed
	for i in range(int(m.rocks)):
		var p = Vector2i(rng.randi_range(2,s.width-3),rng.randi_range(2,s.height-3))
		if Vector2(p).distance_to(Vector2(s.width/2.0,s.height/2.0)) < 4.5 or key(p) in s.rocks:
			continue
		s.rocks.append(key(p))
	rebuild_paths()
	while not connected() and not s.rocks.is_empty():
		s.rocks.pop_back()
		rebuild_paths()
	for i in range(8+map_id*7):
		var p = Vector2i(rng.randi_range(2,s.width-3),rng.randi_range(2,s.height-3))
		if Vector2(p).distance_to(Vector2(s.width/2.0,s.height/2.0)) < 4.5 or key(p) in s.rocks: continue
		s.terrain[key(p)] = ["highland","lane","rift"][i%3]
	note("出征就绪。所有入口必须保持连通。")

# 返回核心占据的地格；根据地图宽度奇偶选择居中的核心尺寸。
func core_cells() -> Array:
	var a: Array = []
	var n = 2 if s.width % 2 == 0 else 3
	var x0 = (s.width-n)/2
	var y0 = (s.height-n)/2
	for y in range(y0,y0+n):
		for x in range(x0,x0+n): a.append(Vector2i(x,y))
	return a

# 返回北、东、南、西四个入口，顺序也用于波次方向编号。
func entrances() -> Array:
	return [Vector2i(s.width/2,0),Vector2i(s.width-1,s.height/2),Vector2i(s.width/2,s.height-1),Vector2i(0,s.height/2)]

# 判断地格是否处于地图边界内。
func inside(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < s.width and p.y < s.height

# 判断地格是否阻路；特殊怪忽略玩家建筑，所有怪都受岩体阻挡。
func blocked(p: Vector2i, special = false) -> bool:
	if not inside(p) or key(p) in s.rocks: return true
	if not special and s.buildings.has(key(p)):
		return s.buildings[key(p)].id not in ["spike","slow"]
	return false

# 从核心反向广度优先搜索，分别生成普通怪与特殊怪的距离场和路线。
func rebuild_paths():
	fields.clear()
	paths.clear()
	for special in [false,true]:
		var f: Dictionary = {}
		var q = core_cells()
		for p in q: f[key(p)] = 0
		# 从全部核心格同时扩散；队列头索引避免每次移除首项的搬移开销。
		var head = 0
		while head < q.size():
			var p: Vector2i = q[head]
			head += 1
			for d in DIRS:
				var n: Vector2i = p+d
				if not blocked(n,special) and not f.has(key(n)):
					f[key(n)] = f[key(p)]+1
					q.append(n)
		fields.append(f)
		var all_paths: Array = []
		for p in entrances():
			var path: Array = [p]
			var current: Vector2i = p
			while f.has(key(current)) and f[key(current)] > 0:
				current = next_cell(current,special)
				path.append(current)
				if path.size() > s.width*s.height: break
			all_paths.append(path)
		paths.append(all_paths)

# 选择距离场数值更小的相邻格；方向顺序固定，保证路线可复现。
func next_cell(p: Vector2i, special = false) -> Vector2i:
	var f: Dictionary = fields[1 if special else 0]
	var best = p
	var score = f.get(key(p),999999)
	for d in DIRS:
		if f.get(key(p+d),999999) < score:
			best = p+d
			score = f[key(best)]
	return best

# 检查四个入口在普通怪距离场中是否都可达。
func connected() -> bool:
	for p in entrances():
		if not fields[0].has(key(p)): return false
	return true

# 只有准备、编辑或休整阶段允许修改布局。
func editable() -> bool:
	return s.state in ["prepare","edit","intermission"]

# 检查蓝图、地格、预算和障碍数量；成功返回空字符串。
func placement_error(id: String,p: Vector2i) -> String:
	if not editable(): return "战斗中无法修改防线"
	if not defs.has(id): return "未知蓝图"
	if id not in s.loadout and id not in ["wall","fence","spike","slow"]: return "未携带此蓝图"
	if not inside(p) or p in core_cells() or p in entrances() or key(p) in s.rocks: return "此地格不可建造"
	if s.terrain.get(key(p),"") == "lane": return "禁建通道：敌人可通行，不能放置建筑"
	if s.buildings.has(key(p)): return "此格已有建筑"
	if s.budget < defs[id].cost: return "建造预算不足"
	if id in ["wall","fence"]:
		var count = 0
		for b in s.buildings.values():
			if b.id in ["wall","fence"]: count += 1
		if count >= rules.maps[s.map].walls: return "已达该地图障碍上限"
	return ""

# 试放建筑后重算路径；若封路则撤销，成功才扣预算并记录命令。
func place(id: String,p: Vector2i, record = true) -> String:
	invalid_entries.clear()
	var error = placement_error(id,p)
	if error != "": return error
	s.buildings[key(p)] = {"id":id,"cooldown":0.0,"hp":defs[id].get("hp",1),"angle":-PI/2,"damage":0.0,"shots":0,"priority":"core"}
	rebuild_paths()
	if not connected():
		for i in 4:
			if not fields[0].has(key(entrances()[i])): invalid_entries.append(i)
		s.buildings.erase(key(p))
		rebuild_paths()
		return "封路无效：必须保留所有入口的通路"
	s.budget -= int(defs[id].cost)
	if record: command("place",[id,p.x,p.y])
	return ""

# 在可编辑阶段拆除建筑，全额退还预算并刷新路线。
func remove(p: Vector2i) -> bool:
	if not editable() or not s.buildings.has(key(p)): return false
	s.budget += int(defs[s.buildings[key(p)].id].cost)
	s.buildings.erase(key(p))
	rebuild_paths()
	command("remove",[p.x,p.y])
	return true

# 整体平移选中建筑；目标无效或封路时恢复原布局。
func move_group(cells: Array,offset: Vector2i) -> String:
	if not editable(): return "战斗中无法移动"
	# 深拷贝嵌套建筑数据，保证任意一步失败都可以完整回滚。
	var old: Dictionary = s.buildings.duplicate(true)
	var moving: Dictionary = {}
	for p in cells:
		if old.has(key(p)):
			moving[key(p+offset)] = old[key(p)]
			s.buildings.erase(key(p))
	for k in moving:
		var p = cell(k)
		if not inside(p) or p in core_cells() or p in entrances() or k in s.rocks or s.buildings.has(k) or s.terrain.get(k,"") == "lane":
			s.buildings = old
			return "目标区域不可用"
		s.buildings[k] = moving[k]
	rebuild_paths()
	if not connected():
		s.buildings = old
		rebuild_paths()
		return "移动会封路"
	var coords: Array = []
	for p in cells: coords.append([p.x,p.y])
	command("move",[coords,offset.x,offset.y])
	return ""

# 按出征种子与波数确定敌人、入口和强度，供预览与实战共用。
func wave_info(w: int) -> Dictionary:
	var rng = RandomNumberGenerator.new()
	rng.seed = int(s.seed) + w*7919
	var dirs: Array = [0,1,2,3]
	for i in range(3,0,-1):
		var j = rng.randi_range(0,i)
		var temp = dirs[i]
		dirs[i] = dirs[j]
		dirs[j] = temp
	dirs.resize(mini(3,1+(w-1)/4))
	var types: Array = ["drone"]
	if w >= 3: types.append("runner")
	if w >= 8: types.append("jumper")
	if w >= 12: types.append("breaker")
	var challenge = s.challenge and w%15 == 9
	var effective = w+10 if challenge else w
	# 普通敌人数量最多 160；超出的数量压力折算进生命倍率。精英/首领另外加入。
	var raw_count = 8+effective*2
	var count = mini(160,raw_count)
	# Continuous log-domain scaling, bounded below floating-point overflow.
	var scale = exp(minf(450.0,0.036*(effective-1))) * maxf(1.0,float(raw_count)/160.0)
	var queue: Array = []
	for i in count:
		queue.append({"type":types[rng.randi_range(0,types.size()-1)],"dir":dirs[i%dirs.size()]})
	if w%5 == 0: queue.append({"type":"boss" if w%15 == 0 else "elite","dir":dirs[0]})
	return {"wave":w,"dirs":dirs,"types":types,"count":queue.size(),"queue":queue,"scale":scale,"challenge":challenge,
		"title":"母巢机甲" if w%15 == 0 else ("重甲精英" if w%5 == 0 else ("突破挑战" if challenge else "机械虫群"))}

# 进入战斗，装入刷怪队列并重置本波统计和建筑冷却。
func start_wave() -> bool:
	if not editable(): return false
	s.wave = int(s.completed)+1
	s.state = "battle"
	var info = wave_info(s.wave)
	wave_queue = info.queue.duplicate(true)
	spawn_clock = 0.0
	enemies.clear()
	shots.clear()
	report = {"leaks":{},"destroyed":0,"damage":0.0}
	for b in s.buildings.values(): b.cooldown = 0.0
	command("start",[])
	note("第 %d 波 · %s · %d 个目标" % [s.wave,info.title,info.count])
	return true

# 推进一个固定模拟步：刷怪、炮台攻击、敌人移动、漏怪和波次结束。
func step():
	if s.get("state","") != "battle": return
	tick += 1
	spawn_clock -= STEP
	if not wave_queue.is_empty() and spawn_clock <= 0:
		var item: Dictionary = wave_queue.pop_front()
		var d: Dictionary = rules.enemies[item.type]
		var hp = float(d.hp)*wave_info_scale()
		var p: Vector2i = entrances()[item.dir]
		enemies.append({"type":item.type,"pos":Vector2(p)+Vector2.ONE*0.5,"cell":p,"next":p,"hp":hp,"max_hp":hp,"slow":0.0})
		spawn_clock += 0.32
	for shot in shots: shot.life -= STEP
	shots = shots.filter(func(v): return v.life > 0)
	# 炮台阶段：先筛选射程与视线，再排序目标，最后按武器类型扩展命中列表。
	for k in s.buildings:
		var b: Dictionary = s.buildings[k]
		var d: Dictionary = defs[b.id]
		if not d.has("damage"): continue
		b.cooldown -= STEP
		if b.cooldown > 0: continue
		var origin = Vector2(cell(k))+Vector2.ONE*0.5
		var r = effective_range(b.id,cell(k))
		var targets: Array = []
		for e in enemies:
			if e.hp > 0 and origin.distance_to(e.pos) <= r and (b.id in ["mortar","arc","pulse","spike","slow"] or line_clear(origin,e.pos)):
				targets.append(e)
		if targets.is_empty(): continue
		var priority = b.get("priority","core")
		if priority == "strong": targets.sort_custom(func(a,c): return a.hp > c.hp)
		elif priority == "weak": targets.sort_custom(func(a,c): return a.hp < c.hp)
		elif priority == "fast": targets.sort_custom(func(a,c): return rules.enemies[a.type].speed > rules.enemies[c.type].speed)
		else: targets.sort_custom(func(a,c): return distance_to_core(a) < distance_to_core(c))
		var target: Dictionary = targets[0]
		b.angle = origin.angle_to_point(target.pos)
		var damage = effective_damage(b.id)
		var haste = effective_haste(b.id)
		# 攻击间隔最低 0.10 秒；更高攻速的收益在 effective_damage 中折算。
		var interval = maxf(0.10,float(d.cooldown)/haste)
		b.cooldown += interval
		b.shots += 1
		var hit: Array = [target]
		if b.id in ["ember","pulse","frost","spike","slow"]: hit = targets
		elif b.id == "mortar":
			hit = enemies.filter(func(e): return e.hp > 0 and e.pos.distance_to(target.pos) <= 1.7)
		elif b.id == "arc":
			var last: Dictionary = target
			for i in 3:
				var nearest: Dictionary = {}
				var best = 2.8
				for e in enemies:
					if e.hp > 0 and e not in hit and e.pos.distance_to(last.pos) < best:
						best = e.pos.distance_to(last.pos)
						nearest = e
				if nearest.is_empty(): break
				hit.append(nearest)
				last = nearest
		elif b.id == "rail":
			var direction: Vector2 = (target.pos-origin).normalized()
			for e in targets:
				var relative: Vector2 = e.pos-origin
				if e != target and relative.dot(direction) > 0 and absf(relative.cross(direction)) < 0.45: hit.append(e)
		for e in hit:
			if b.id in ["frost","slow"]: e.slow = 1.1
			var armor = float(rules.enemies[e.type].armor) if b.id != "lance" else 0.0
			var actual = minf(e.hp,damage*(1.0-armor))
			e.hp -= actual
			b.damage += actual
			report.damage += actual
			if shots.size() < 180: shots.append({"from":origin,"to":e.pos,"color":d.color,"life":0.13,"kind":b.id,"damage":actual})
	# 敌人阶段：先处理击杀，再沿距离场移动；到达核心格时扣核心生命。
	for e in enemies:
		if e.hp <= 0:
			s.kills += 1
			continue
		var special = e.type in ["jumper","breaker"]
		if e.pos.distance_to(Vector2(e.next)+Vector2.ONE*0.5) < 0.001:
			e.cell = e.next
			if e.cell in core_cells():
				var leak = int(rules.enemies[e.type].leak)
				s.hp = maxi(0,int(s.hp)-leak)
				s.leaks += 1
				report.leaks[e.type] = report.leaks.get(e.type,0)+1
				e.hp = -1
				if s.hp <= 0:
					finish("核心失守")
					return
				continue
			e.next = next_cell(e.cell,special)
		# 破障者使用特殊路线，但遇到石墙或栅栏会停下攻击，摧毁后重算路径。
		if e.type == "breaker" and s.buildings.has(key(e.next)) and s.buildings[key(e.next)].id in ["wall","fence"]:
			var wall: Dictionary = s.buildings[key(e.next)]
			wall.hp -= STEP*35*sqrt(wave_info_scale())
			if wall.hp <= 0:
				s.ruins[key(e.next)] = wall.id
				s.buildings.erase(key(e.next))
				report.destroyed += 1
				rebuild_paths()
			continue
		e.slow = maxf(0.0,e.slow-STEP)
		var speed = float(rules.enemies[e.type].speed)*(0.45 if e.slow > 0 else 1.0)
		var terrain_id = s.terrain.get(key(Vector2i(e.pos.floor())),"")
		if terrain_id != "":
			var ground: Dictionary = rules.terrain[terrain_id]
			speed *= float(ground.speed)
			e.hp -= float(ground.damage)*STEP
			if e.hp <= 0: s.kills += 1; continue
		e.pos = e.pos.move_toward(Vector2(e.next)+Vector2.ONE*0.5,speed*STEP)
	enemies = enemies.filter(func(e): return e.hp > 0)
	if enemies.is_empty() and wave_queue.is_empty(): complete_wave()

# 计算当前波的生命缩放；挑战波按额外十波强度计算。
func wave_info_scale() -> float:
	var w = int(s.wave)+(10 if s.challenge and int(s.wave)%15 == 9 else 0)
	return exp(minf(450.0,0.036*(w-1)))*maxf(1.0,float(8+w*2)/160.0)

# 返回敌人与地图中心的直线距离，用于接近核心优先级。
func distance_to_core(e: Dictionary) -> float:
	return Vector2(e.pos).distance_to(Vector2(s.width,s.height)*0.5)

# 沿射线采样地格，检查岩体或石墙是否遮挡直射武器。
func line_clear(a: Vector2,b: Vector2) -> bool:
	var steps = maxi(1,int(a.distance_to(b)*3))
	for i in range(1,steps):
		var k = key(Vector2i(a.lerp(b,float(i)/steps).floor()))
		if k in s.rocks or (s.buildings.has(k) and s.buildings[k].id == "wall"): return false
	return true

# 用对数曲线计算全体强化，等级越高单级增幅越小。
func growth_multiplier(kind: String, extra = 0) -> float:
	var coefficient = {"power":0.55,"haste":0.30,"range":0.10}[kind]
	return 1.0+coefficient*log(1.0+float(s.growth[kind])+extra)

# 计算指定炮台的强化倍率，使用炮台 id 与属性组合键。
func target_growth(id: String,kind: String,extra=0) -> float:
	var coefficient = {"power":0.85,"haste":0.45,"range":0.17}[kind]
	return 1.0+coefficient*log(1.0+float(s.growth.get(id+":"+kind,0))+extra)

# 计算奖励界面展示的当前倍率或升级预览倍率。
func reward_multiplier(kind: String,target: String,extra=0) -> float:
	return growth_multiplier(kind,extra) if target == "all" else growth_multiplier(kind)*target_growth(target,kind,extra)

# 综合全体强化、指定炮台强化与速射分支计算攻速倍率。
func effective_haste(id: String) -> float:
	return growth_multiplier("haste")*target_growth(id,"haste")*(1.25 if s.meta.get(id+"_branch","") == "rapid" else 1.0)

# 综合培养计算单次伤害；攻速达到表现上限后把剩余收益转为伤害。
func effective_damage(id: String) -> float:
	var haste = effective_haste(id)
	var interval = maxf(0.10,float(defs[id].cooldown)/haste)
	return float(defs[id].damage)*growth_multiplier("power")*target_growth(id,"power")*meta_multiplier(id)*maxf(1.0,haste*interval/float(defs[id].cooldown))

# 合并永久基础火力、炮台专精、重击分支和增幅模块。
func meta_multiplier(id: String) -> float:
	var result = 1.0+0.09*float(s.meta.get("power",0))+0.07*float(s.meta.get(id,0))
	if s.meta.get(id+"_branch","") == "impact": result *= 1.3
	if s.meta.get(id+"_module","") == "amplifier": result *= 1.15
	return result

# 合并射程强化、观测模块与所在高台的射程加成。
func effective_range(id: String,p = Vector2i(-1,-1)) -> float:
	var result = float(defs[id].get("range",0))*growth_multiplier("range")*target_growth(id,"range")
	if s.meta.get(id+"_module","") == "scope": result *= 1.18
	if s.get("terrain",{}).get(key(p),"") == "highland": result += float(rules.terrain.highland.range_bonus)
	return result

# 在可编辑阶段设置建筑选敌策略，并记录可回放命令。
func set_priority(p: Vector2i,priority: String) -> bool:
	if not editable() or not s.buildings.has(key(p)) or priority not in ["core","strong","weak","fast"]: return false
	s.buildings[key(p)].priority = priority
	command("priority",[p.x,p.y,priority])
	return true

# 发放本波收益、修复存活障碍，进入休整或周期领奖状态。
func complete_wave():
	s.completed = s.wave
	var earned = int((12+int(s.wave)*2)*float(rules.maps[s.map].income))
	# 金币是本局收益账本，建造预算另行发放；避免拆建刷取永久金币。
	s.income += earned
	s.budget += 12+(8 if int(s.wave)%5 == 0 else 0)
	for b in s.buildings.values():
		if defs[b.id].has("hp"): b.hp = defs[b.id].hp
	if s.challenge and int(s.wave)%15 == 9:
		s.income += 65
		s.challenge_bonus = true
		s.challenges_won += 1
		s.challenge = false
		note("挑战成功：65 金币已到账，本周期奖励 ×1.5")
	s.state = "reward" if int(s.wave)%15 == 0 else "intermission"
	if s.auto_rebuild and s.state == "intermission":
		for k in s.ruins.keys():
			if place(s.ruins[k],cell(k),false) == "": s.ruins.erase(k)
	note("第 %d 波完成 · +%d 金币 · 核心 %d" % [s.wave,earned,s.hp])
	events.append("wave_complete")

# 计算周期金币奖励，包含成功挑战的加成。
func reward_gold() -> int:
	return int((130+int(s.completed)*9)*(1.5 if s.challenge_bonus else 1.0))

# 验证奖励类型和领取次数，发放后切换到商店，防止重复领取。
func claim_reward(kind: String) -> bool:
	if s.state != "reward" or int(s.reward_claimed) >= int(s.completed): return false
	var attribute = kind
	var target = "all"
	if ":" in kind:
		var pieces = kind.split(":")
		if pieces.size() != 2 or pieces[0] not in s.loadout or pieces[1] not in ["power","haste","range"]: return false
		target = pieces[0]
		attribute = pieces[1]
	elif kind not in ["gold","power","haste","range"]: return false
	if kind == "gold": s.income += reward_gold()
	else: s.growth[kind] = int(s.growth.get(kind,0))+(2 if s.challenge_bonus else 1)
	s.reward_claimed = s.completed
	s.challenge_bonus = false
	s.shop_stock = [1,1,1]
	s.state = "shop"
	command("reward",[kind])
	note("周期奖励已领取："+("全体 " if target == "all" else defs[target].name+" ")+{"gold":"金币","power":"火力","haste":"超频","range":"射程"}[attribute])
	return true

# 使用本局可用金币购买补给，同时检查库存和修复需求。
func buy(item: int) -> bool:
	if s.state != "shop" or item < 0 or item > 2: return false
	var cost: int = [280,360,450][item]
	if s.income-s.spent < cost or s.shop_stock[item] <= 0: return false
	if item == 0 and s.hp == s.max_hp: return false
	s.spent += cost
	s.shop_stock[item] -= 1
	if item == 0: s.hp = mini(int(s.max_hp),int(s.hp)+35)
	elif item == 1: s.budget += 120
	else: s.growth.power += 1
	command("buy",[item])
	return true

# 离开商店，回到可自动推进的休整阶段。
func close_shop():
	if s.state != "shop": return
	s.state = "intermission"
	command("close_shop",[])

# 只允许在周期指定窗口内报名或取消挑战。
func set_challenge(value: bool) -> bool:
	if not editable() or int(s.completed)%15 not in [6,7,8]: return false
	s.challenge = value
	command("challenge",[value])
	return true

# 将出征标为结束，重复调用不再产生结束事件。
func finish(reason: String):
	if s.state == "ended": return
	s.state = "ended"
	s.reason = reason
	command("finish",[reason])
	events.append("ended")
	note(reason)

# 追加面向玩家的战报，只保留最近一百条。
func note(message: String):
	s.log.append(message)
	if s.log.size() > 100: s.log.pop_front()

# 记录模拟时刻、命令类型和参数，供服务端重放操作。
func command(kind: String,args: Array):
	s.commands.append({"tick":tick,"kind":kind,"args":args})

# 深拷贝出征状态和模拟计数；不包含战斗中的敌人和刷怪队列。
func snapshot() -> Dictionary:
	var result = s.duplicate(true)
	result.tick = tick
	return result

# 检查规则版本、恢复整数状态并重建路线；用于恢复波前或波间存档。
func restore(data: Dictionary) -> bool:
	if data.get("version","") != rules.version or not data.has("buildings"): return false
	s = data.duplicate(true)
	if not s.has("terrain"): s.terrain = {}
	for name in ["map","seed","width","height","wave","completed","hp","max_hp","budget","income","spent","reward_claimed","kills","leaks","challenges_won"]:
		s[name] = int(s[name])
	tick = int(s.get("tick",0))
	enemies.clear()
	shots.clear()
	wave_queue.clear()
	rebuild_paths()
	return connected()
