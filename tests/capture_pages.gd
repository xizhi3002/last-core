extends SceneTree
var game
func _init(): run.call_deferred()
func snap(name: String):
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/qa-"+name+".png")
func run():
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.show_map_select()
	await snap("maps")
	game.show_loadout()
	await snap("loadout")
	game.begin_run(104729)
	game.starter_layout()
	game.show_route_menu()
	await snap("routes")
	game.sim.s.completed = 15
	game.sim.s.state = "reward"
	game.show_reward()
	await snap("reward")
	game.sim.claim_reward("gold")
	game.show_run_shop()
	await snap("shop")
	game.show_meta_shop()
	await snap("research")
	game.show_settings()
	await snap("settings")
	game.chosen_map = 4
	game.begin_run(104729)
	game.starter_layout()
	await snap("large-map")
	game.audio_buffer = null
	game.audio_player.stop()
	await create_timer(0.2).timeout
	game.queue_free()
	await process_frame
	quit()
