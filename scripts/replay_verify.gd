extends SceneTree
# 无窗口回放验证入口：服务端提供初始配置，不接受客户端存档作为权威结果。
# 该入口不独立验证初始配置签名；信任边界由调用它的服务端负责。
## The service supplies its own signed initial configuration; no client snapshots accepted.
const Sim = preload("res://scripts/simulation.gd")
# 延迟到场景树初始化之后再启动命令行回放。
func _init(): run.call_deferred()

# 输出机器可读的失败结果，并以非零退出码结束。
func fail(reason: String):
	print(JSON.stringify({"valid":false,"reason":reason}))
	quit(1)

# 读取服务端任务，用同一模拟器按 tick 重放合法命令并输出结算结果。
func run():
	var args = OS.get_cmdline_user_args()
	if args.size()!=1: fail("expected job path"); return
	var job = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not job is Dictionary: fail("invalid job"); return
	var initial: Dictionary = job.initial
	var sim = Sim.new()
	if initial.version != sim.rules.version: fail("rules mismatch"); return
	sim.new_run(int(initial.map),int(initial.seed),initial.meta,initial.loadout)
	var last_tick = 0
	for cmd in job.commands:
		var target = int(cmd.tick)
		if target < last_tick or target > 5000000: fail("invalid tick budget"); return
		while sim.tick < target:
			if sim.s.state != "battle": fail("ticks outside battle"); return
			sim.step()
		last_tick = target
		var a: Array = cmd.args
		match cmd.kind:
			"place":
				if sim.place(str(a[0]),Vector2i(int(a[1]),int(a[2]))) != "": fail("illegal placement"); return
			"remove":
				if not sim.remove(Vector2i(int(a[0]),int(a[1]))): fail("illegal removal"); return
			"move":
				var cells: Array = []
				for p in a[0]: cells.append(Vector2i(int(p[0]),int(p[1])))
				if sim.move_group(cells,Vector2i(int(a[1]),int(a[2]))) != "": fail("illegal move"); return
			"start":
				if not sim.start_wave(): fail("illegal start"); return
			"priority":
				if not sim.set_priority(Vector2i(int(a[0]),int(a[1])),str(a[2])): fail("illegal priority"); return
			"reward":
				if not sim.claim_reward(str(a[0])): fail("illegal reward"); return
			"buy":
				if not sim.buy(int(a[0])): fail("illegal purchase"); return
			"close_shop":
				if sim.s.state != "shop": fail("not in shop"); return
				sim.close_shop()
			"challenge":
				if not sim.set_challenge(bool(a[0])): fail("illegal challenge"); return
			"finish": sim.finish("verified replay end")
			_: fail("unknown operation"); return
	if sim.s.state != "ended": fail("unfinished expedition"); return
	print(JSON.stringify({"valid":true,"wave":sim.s.completed,"income":sim.s.income,"spent":sim.s.spent,"hp":sim.s.hp,"map":sim.s.map,"seed":sim.s.seed,"version":sim.s.version}))
	quit()
