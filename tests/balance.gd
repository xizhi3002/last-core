extends SceneTree
const Sim = preload("res://scripts/simulation.gd")
var rows: Array = []
func _init(): run.call_deferred()

func run():
	for map_id in 5:
		for build in ["ring","piercing","control","mixed"]:
			var sim = Sim.new()
			sim.new_run(map_id,104729,{"power":0},["rail","ember","mortar","arc","lance","frost"])
			var c = Vector2i(sim.s.width/2,sim.s.height/2)
			var offsets = [Vector2i(-3,-2),Vector2i(2,-3),Vector2i(3,2),Vector2i(-2,3),Vector2i(-3,1),Vector2i(1,3)]
			var ids: Array = {"ring":["rail","ember","rail","ember","frost","spike"],"piercing":["rail","rail","rail","rail","lance","slow"],"control":["ember","frost","arc","ember","slow","mortar"],"mixed":["mortar","rail","arc","lance","frost","ember"]}[build]
			var placed = 0
			for i in 6:
				if sim.place(ids[i],c+offsets[i]) == "": placed += 1
			var t0 = Time.get_ticks_msec()
			for w in 16:
				sim.start_wave()
				for t in 16000:
					sim.step()
					if sim.s.state != "battle": break
				if sim.s.state == "reward": sim.claim_reward("power"); sim.close_shop()
				if sim.s.state == "ended": break
			var row = {"map":map_id,"seed":104729,"build":build,"placed":placed,"wave":sim.s.completed,"hp":sim.s.hp,"leaks":sim.s.leaks,"coins":sim.s.income,"ticks":sim.tick,"wall_seconds":(Time.get_ticks_msec()-t0)/1000.0,"paths":[],"rules":sim.rules.version}
			for path in sim.paths[0]: row.paths.append(path.size()-1)
			rows.append(row)
			print(JSON.stringify(row))
	var file = FileAccess.open("res://build/balance-results.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(rows,"\t"))
	quit()
