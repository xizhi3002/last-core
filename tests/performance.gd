extends SceneTree
# 最大地图短时性能采样：记录帧率、内存和敌人数量，不替代长时间压力测试。
var game
var samples: Array = []
var started = 0
var last = 0
# 延迟执行测试，使场景树和预加载资源先完成初始化。
func _init(): run.call_deferred()
# 执行本文件的验证流程，输出结果后结束进程。
func run():
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.chosen_map = 4
	game.begin_run(104729)
	game.sim.s.budget = 6000
	game.sim.s.meta.power = 5
	var c = Vector2i(40,24)
	for y in range(-5,6):
		for x in range(-5,6):
			if maxi(absi(x),absi(y)) == 5 and (x+y)%2 == 0:
				game.sim.place(["rail","mortar","arc","ember"][absi(x+y)%4],c+Vector2i(x,y))
	game.sim.s.completed = 74
	game.start_wave()
	game.speed = 3
	started = Time.get_ticks_msec()
	last = started
	while Time.get_ticks_msec()-started < 15000:
		await process_frame
		if Time.get_ticks_msec()-last > 1000:
			last = Time.get_ticks_msec()
			samples.append({"fps":Engine.get_frames_per_second(),"frame_ms":Performance.get_monitor(Performance.TIME_PROCESS)*1000,"memory_mb":Performance.get_monitor(Performance.MEMORY_STATIC)/1048576.0,"enemies":game.sim.enemies.size(),"effects":game.sim.shots.size()})
	var result = {"device":RenderingServer.get_video_adapter_name(),"engine":Engine.get_version_info().string,"map":"81x49","speed":3,"buildings":game.sim.s.buildings.size(),"samples":samples,"note":"15-second render smoke benchmark, synthetic wave 75 fixture; not a multi-hour soak test"}
	var out = FileAccess.open("res://build/performance-results.json",FileAccess.WRITE)
	out.store_string(JSON.stringify(result,"\t"))
	print(JSON.stringify(result))
	game.queue_free()
	await process_frame
	quit()
