extends SceneTree
# 核心规则回归测试：覆盖寻路、建造、成长、回放和连续波次等行为。
const Sim = preload("res://scripts/simulation.gd")
var checks = 0
var failures: Array = []

# 累积检查次数并记录失败，便于一次看到多个问题。
func check(condition: bool,message: String):
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

# 延迟执行测试，使场景树和预加载资源先完成初始化。
func _init():
	run.call_deferred()

# 创建固定种子与默认蓝图的模拟器，便于重复比较。
func make_sim(map_id=0,map_seed=73):
	var sim = Sim.new()
	sim.new_run(map_id,map_seed,{"power":0},["rail","ember","mortar","arc","lance","frost"])
	return sim

# 执行本文件的验证流程，输出结果后结束进程。
func run():
	var started = Time.get_ticks_msec()
	for map_id in 5:
		for map_seed in [73,104729]:
			var sim = make_sim(map_id,map_seed)
			check(sim.connected(),"all entrances connected %s/%s" % [map_id,map_seed])
			var center = Vector2.ZERO
			for p in sim.core_cells(): center += Vector2(p)+Vector2.ONE*0.5
			center /= sim.core_cells().size()
			check(center == Vector2(sim.s.width,sim.s.height)*0.5,"geometric center")
			for w in [1,5,15,51,300,10000]:
				var info = sim.wave_info(w)
				check(info.dirs.size()<=3 and info.dirs.size()>=1,"one to three directions")
				check(is_finite(info.scale) and info.scale>0,"finite endless scaling")
			for path in sim.paths[0]:
				check(path[-1] in sim.core_cells(),"preview ends at core")
	var sim = make_sim()
	var budget = sim.s.budget
	check(sim.place("rail",sim.core_cells()[0]) != "","core unbuildable")
	check(sim.s.budget == budget,"invalid placement free")
	check(sim.place("rail",Vector2i(2,1)) == "","legal build")
	check(sim.remove(Vector2i(2,1)),"remove legal")
	check(sim.s.budget == budget,"full refund")
	var north = sim.entrances()[0]
	sim.s.budget = 10000
	check(sim.place("wall",north+Vector2i(-1,0)) == "","first wall")
	check(sim.place("wall",north+Vector2i(1,0)) == "","second wall")
	budget = sim.s.budget
	check(sim.place("wall",north+Vector2i(0,1)) != "","closure rejected")
	check(sim.s.budget == budget,"closure refunds")
	check(sim.connected(),"closure preserves route")
	check(sim.start_wave(),"wave start")
	check(sim.place("rail",Vector2i(1,1)) != "","battle edit blocked")
	check(not sim.remove(north+Vector2i(-1,0)),"battle remove blocked")
	# No defenses: exercise leaks, single damage, and loss ordering.
	var loss = make_sim()
	loss.s.hp = 1
	loss.start_wave()
	for i in 4000:
		loss.step()
		if loss.s.state == "ended": break
	check(loss.s.state == "ended" and loss.s.completed == 0,"fatal leak before wave completion")
	check(loss.s.hp == 0 and loss.s.leaks == 1,"one enemy one leak")
	check(loss.s.income == 0,"no failed-wave income")
	# Reward, shop, challenge and unbounded positive growth.
	var reward = make_sim()
	reward.s.completed = 15
	reward.s.wave = 15
	reward.s.state = "reward"
	var gold = reward.reward_gold()
	check(reward.claim_reward("gold"),"reward accepted")
	check(reward.s.income == gold,"gold credited")
	check(not reward.claim_reward("power"),"mutual exclusion and idempotency")
	reward.s.income = 1000
	check(reward.buy(1),"shop valid buy")
	check(not reward.buy(1),"shop finite stock")
	check(reward.s.spent == 360,"run-only spend")
	reward.s.growth.power = 1000000
	check(reward.growth_multiplier("power",1)>reward.growth_multiplier("power"),"positive millionth growth")
	reward.s.state = "edit"
	reward.s.completed = 6
	check(reward.set_challenge(true),"challenge announced two waves ahead")
	check(reward.wave_info(9).challenge,"challenge scheduled")
	check(reward.set_challenge(false),"challenge cancellation")
	var focused = make_sim()
	focused.s.state = "reward"
	focused.s.completed = 15
	var before_damage = focused.effective_damage("rail")
	var other_damage = focused.effective_damage("ember")
	check(focused.claim_reward("rail:power"),"targeted reward")
	check(focused.effective_damage("rail") > before_damage,"targeted damage growth")
	check(focused.effective_damage("ember") == other_damage,"targeted effect isolation")
	focused.s.state = "edit"
	focused.s.terrain["2,1"] = "lane"
	check(focused.place("rail",Vector2i(2,1)) != "","no-build terrain")
	focused.s.terrain["2,1"] = "highland"
	check(focused.place("rail",Vector2i(2,1)) == "","highland buildable")
	check(focused.effective_range("rail",Vector2i(2,1)) > focused.effective_range("rail"),"highland range")
	check(focused.set_priority(Vector2i(2,1),"strong"),"editable target priority")
	focused.start_wave()
	check(not focused.set_priority(Vector2i(2,1),"weak"),"battle priority lock")
	# Identical snapshots and identical fixed-step replay.
	var first = make_sim()
	first.place("rail",Vector2i(6,5))
	var second = Sim.new()
	check(second.restore(first.snapshot()),"snapshot restore")
	first.start_wave()
	second.start_wave()
	for i in 3000:
		first.step()
		second.step()
	check(first.s.hp == second.s.hp and first.s.kills == second.s.kills and first.s.income == second.s.income,"deterministic restore")
	check(JSON.stringify(first.enemies) == JSON.stringify(second.enemies),"identical enemy state")
	first.finish("replay fixture")
	var replay_file = FileAccess.open("res://build/replay-job.json",FileAccess.WRITE)
	replay_file.store_string(JSON.stringify({"initial":{"map":0,"seed":73,"meta":{"power":0},"loadout":first.s.loadout,"version":first.s.version},"commands":first.s.commands}))
	replay_file.close()
	# A strengthened test fixture verifies all 60 waves and four reward cycles.
	var endless = make_sim()
	endless.s.budget = 5000
	endless.s.meta.power = 80
	for p in [Vector2i(5,5),Vector2i(10,5),Vector2i(10,10),Vector2i(5,10),Vector2i(7,4),Vector2i(4,7),Vector2i(11,8),Vector2i(8,11)]:
		endless.place("rail",p)
	for w in 60:
		endless.start_wave()
		for i in 12000:
			endless.step()
			if endless.s.state != "battle": break
		if endless.s.state == "reward":
			check(endless.claim_reward("power"),"60-wave cycle reward")
			endless.close_shop()
		if endless.s.state == "ended": break
	check(endless.s.completed == 60,"unending progression beyond wave 50")
	var result = {"checks":checks,"failures":failures,"seconds":(Time.get_ticks_msec()-started)/1000.0,"completed":endless.s.completed,"hp":endless.s.hp,"engine":Engine.get_version_info().string}
	var file = FileAccess.open("res://build/test-results.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"\t"))
	print(JSON.stringify(result))
	quit(0 if failures.is_empty() else 1)
