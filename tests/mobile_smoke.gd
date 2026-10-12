extends SceneTree
# 手机专用流程和手势回归；--mobile --test 下运行，不使用玩家的正式存档。
var game
var failures: Array = []
var taps = 0
func _init(): run.call_deferred()
func check(ok: bool,message: String):
	if not ok: failures.append(message); push_error(message)
func touch(board,index: int,pos: Vector2,pressed: bool,canceled=false):
	var e = InputEventScreenTouch.new()
	e.index=index; e.position=pos; e.pressed=pressed; e.canceled=canceled
	board.handle_touch(e)
func drag(board,index: int,pos: Vector2):
	var e = InputEventScreenDrag.new()
	e.index=index; e.position=pos
	board.handle_touch(e)
func snap(name: String):
	await process_frame
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://build/mobile-"+name+".png")
func run():
	root.size = Vector2i(960,540)
	game=load("res://main.tscn").instantiate()
	root.add_child(game)
	await snap("menu")
	check(game.mobile,"mobile mode")
	game.show_map_select(); await snap("maps")
	game.show_loadout(); await snap("loadout")
	game.begin_run(104729)
	game.starter_layout()
	await snap("battle")
	var b=game.board
	check(b.size.y>=160,"battle board has usable height")
	check(game.hud.hint.get_global_rect().end.y <= 540,"battle toolbar fits viewport")
	b.cell_clicked.connect(func(_p,_button): taps+=1)
	var p=Vector2(100,80)
	touch(b,0,p,true);touch(b,0,p,false)
	check(taps==1,"tap emits exactly once")
	var old_pan=b.pan
	touch(b,0,p,true);drag(b,0,p+Vector2(60,20));touch(b,0,p+Vector2(60,20),false)
	check(taps==1 and b.pan!=old_pan,"drag pans without build")
	var old_zoom=b.zoom
	touch(b,0,p,true);touch(b,1,p+Vector2(100,0),true)
	drag(b,1,p+Vector2(160,0))
	touch(b,1,p+Vector2(160,0),false);touch(b,0,p,false)
	check(taps==1 and b.zoom>old_zoom,"pinch zoom no accidental tap")
	touch(b,0,p,true);touch(b,0,p,false,true)
	check(taps==1,"canceled touch ignored")
	game.sim.s.state="intermission"
	game.touch_mode="move"
	var cells=game.sim.s.buildings.keys()
	var origin=game.sim.cell(cells[0])
	game.on_cell_clicked(origin,MOUSE_BUTTON_LEFT)
	check(game.moving==[origin],"touch selects move source")
	check(game.sim.s.state=="edit","touch editing stops next-wave countdown")
	game.touch_mode="remove";game.moving.clear()
	var count=game.sim.s.buildings.size()
	game.on_cell_clicked(origin,MOUSE_BUTTON_LEFT)
	check(game.sim.s.buildings.size()==count-1,"touch removes selected tower")
	game.start_wave()
	game._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	check(game.paused and game.store.data.run.state!="battle","background saves checkpoint and pauses")
	check(b.fingers.is_empty(),"background clears touch state")
	game.show_mobile_operations();await snap("operations")
	game.close_modal()
	game.sim.s.state="reward";game.sim.s.completed=15
	game.show_reward();await snap("reward")
	game.show_settings();await snap("settings")
	game.close_modal();game.show_meta_shop();await snap("research")
	var out=FileAccess.open("res://build/mobile-test-results.json",FileAccess.WRITE)
	out.store_string(JSON.stringify({"failures":failures,"status":"passed" if failures.is_empty() else "failed"},"\t"))
	print("MOBILE TEST ",failures)
	game.queue_free();await process_frame
	quit(0 if failures.is_empty() else 1)
