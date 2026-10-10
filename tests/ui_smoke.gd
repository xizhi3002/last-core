extends SceneTree
var game
var failures: Array = []
func _init(): run.call_deferred()
func check(ok: bool,message: String):
	if not ok: failures.append(message); push_error(message)

func run():
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.show_map_select()
	await process_frame
	check(game.screen == "maps","map screen")
	game.show_loadout()
	await process_frame
	check(game.screen == "loadout","loadout screen")
	game.begin_run(104729)
	game.starter_layout()
	await process_frame
	check(game.sim.s.buildings.size() > 3,"starter build")
	game.show_route_menu()
	await process_frame
	check(game.overlay != null,"route controls")
	game.close_modal()
	game.start_wave()
	game.paused = true
	var prior = game.sim.s.buildings.size()
	game.on_cell_clicked(Vector2i(1,1),MOUSE_BUTTON_LEFT)
	check(game.sim.s.buildings.size() == prior,"UI battle edit rejected")
	game.show_settings()
	await process_frame
	game.close_modal()
	game.sim.s.state = "reward"
	game.sim.s.completed = 15
	game.show_reward()
	await process_frame
	check(game.overlay != null,"reward modal")
	game.sim.claim_reward("power")
	game.show_run_shop()
	await process_frame
	game.sim.close_shop()
	game.close_modal()
	game.sim.s.state = "edit"
	game.save_run()
	game.show_menu()
	game.resume_run()
	await process_frame
	check(game.sim.s.completed == 15,"UI resume saved wave")
	game.show_meta_shop()
	await process_frame
	game.show_modules("rail")
	await process_frame
	game.close_modal()
	game.show_records()
	await process_frame
	var out = FileAccess.open("res://build/ui-test-results.json",FileAccess.WRITE)
	out.store_string(JSON.stringify({"failures":failures,"status":"passed" if failures.is_empty() else "failed"},"\t"))
	print("UI SMOKE ","PASS" if failures.is_empty() else "FAIL", " ",failures)
	game.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
