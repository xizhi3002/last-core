extends SceneTree
# 独立存档下验证触屏部署事务、暂停、缩放与全图布局。
var game
var failures: Array = []
var checks = 0
var taps = 0
func _init(): run.call_deferred()
func check(ok: bool,message: String):
	checks += 1
	if not ok: failures.append(message); push_error(message)
func touch(b,index,pos,pressed,canceled=false):
	var e = InputEventScreenTouch.new()
	e.index=index; e.position=pos; e.pressed=pressed; e.canceled=canceled
	b.handle_touch(e)
func drag(b,index,pos):
	var e = InputEventScreenDrag.new()
	e.index=index; e.position=pos
	b.handle_touch(e)
func snap(name):
	await process_frame
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://build/mobile-"+name+".png")
func free_cell(id="rail") -> Vector2i:
	for y in game.sim.s.height:
		for x in game.sim.s.width:
			var p=Vector2i(x,y)
			if game.sim.placement_error(id,p)=="": return p
	return Vector2i(-1,-1)
func find_blueprint(node):
	if node is Button and node.text == "磁轨炮\n65": return node
	for child in node.get_children():
		var found = find_blueprint(child)
		if found != null: return found
	return null
func run():
	# 任何脚本运行异常都由看门狗给出非零退出，避免空跑。
	create_timer(90).timeout.connect(func(): push_error("MOBILE TIMEOUT"); quit(2))
	root.size=Vector2i(960,540)
	game=load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	await snap("menu")
	game.begin_run(104729)
	await snap("battle")
	var b=game.board
	check(game.speed==0.5,"slower default")
	check(b.size.y>410,"battlefield occupies most height")
	check(game.hud.start.get_global_rect().end.x<=960,"top controls fit")
	check(b.offset.x>=0 and b.offset.y>=0,"full map starts inside viewport")
	check(b.point(Vector2(game.sim.s.width,game.sim.s.height)).x<=b.size.x,"full map right edge fits")
	check(b.point(Vector2(game.sim.s.width,game.sim.s.height)).y<=b.size.y,"full map bottom fits")
	# 经过真实视口派发，覆盖从按钮跨越到棋盘的输入捕获。
	var blueprint = find_blueprint(game)
	var start_pos = blueprint.get_global_rect().get_center()
	var target_cell = free_cell()
	var target_pos = b.global_position+b.point(Vector2(target_cell)+Vector2.ONE*0.5)
	var press = InputEventScreenTouch.new()
	press.index=0;press.position=start_pos;press.pressed=true
	root.push_input(press,true)
	var drag_event = InputEventScreenDrag.new()
	drag_event.index=0;drag_event.position=start_pos+Vector2(0,-30)
	root.push_input(drag_event,true)
	drag_event = InputEventScreenDrag.new()
	drag_event.index=0;drag_event.position=target_pos
	root.push_input(drag_event,true)
	var release = InputEventScreenTouch.new()
	release.index=0;release.position=target_pos;release.pressed=false
	root.push_input(release,true)
	check(not game.draft.is_empty() and game.draft.cell==target_cell,"blueprint touch drag crosses controls")
	check(game.sim.s.buildings.is_empty(),"blueprint release requires confirmation")
	game.cancel_draft()
	b.cell_clicked.connect(func(_p,_button): taps+=1)
	var pixel=Vector2(100,80)
	touch(b,0,pixel,true);touch(b,0,pixel,false)
	check(taps==1,"single tap once")
	var old_pan=b.pan
	touch(b,0,pixel,true);drag(b,0,pixel+Vector2(60,20));touch(b,0,pixel+Vector2(60,20),false)
	check(taps==1 and b.pan!=old_pan,"inspect drag pans without placing")
	var old_zoom=b.zoom
	touch(b,0,pixel,true);touch(b,1,pixel+Vector2(100,0),true)
	drag(b,1,pixel+Vector2(160,0));touch(b,1,pixel+Vector2(160,0),false);touch(b,0,pixel,false)
	check(taps==1 and b.zoom>old_zoom,"pinch does not tap")
	touch(b,0,pixel,true);touch(b,0,pixel,false,true)
	check(taps==1,"canceled touch ignored")
	b.home();b.update_transform()
	game.sim.s.state="intermission";game.paused=true
	var countdown=game.countdown
	game._process(1.0)
	check(game.countdown==countdown,"paused intermission freezes countdown")
	var budget=game.sim.s.budget
	var p=free_cell()
	game.begin_draft("place","rail")
	game.update_draft(p)
	check(game.draft_error=="","valid preview")
	check(game.sim.s.buildings.is_empty() and game.sim.s.budget==budget,"preview has no mutation")
	check(game.sim.s.state=="edit" and game.paused,"editing while paused allowed")
	await snap("preview")
	game.cancel_draft()
	check(game.sim.s.buildings.is_empty() and game.sim.s.budget==budget,"cancel preserves budget")
	game.begin_draft("place","rail");game.update_draft(game.sim.core_cells()[0])
	check(game.draft_error!="","core placement rejected")
	game.confirm_draft()
	check(game.sim.s.buildings.is_empty(),"invalid confirmation rejected")
	game.update_draft(p);game.confirm_draft();game.confirm_draft()
	check(game.sim.s.buildings.size()==1 and game.sim.s.budget==budget-65,"confirm spends once")
	check(b.focus_cell==p,"selected tower persistent range")
	await snap("tower")
	game.begin_draft("move","rail",p)
	var q=free_cell()
	var source_pixel=b.point(Vector2(p)+Vector2.ONE*0.5)
	var dest_pixel=b.point(Vector2(q)+Vector2.ONE*0.5)
	old_pan=b.pan
	touch(b,0,source_pixel,true);drag(b,0,dest_pixel);touch(b,0,dest_pixel,false)
	check(game.draft.cell==q and b.pan==old_pan,"draft drag moves ghost instead of camera")
	check(game.sim.s.buildings.has(game.sim.key(p)),"move preview preserves source")
	await snap("move")
	game.confirm_draft()
	check(not game.sim.s.buildings.has(game.sim.key(p)) and game.sim.s.buildings.has(game.sim.key(q)),"move confirmed")
	game.begin_draft("remove","rail",q);game.cancel_draft()
	check(game.sim.s.buildings.size()==1,"remove cancel preserves tower")
	game.begin_draft("remove","rail",q);game.confirm_draft()
	check(game.sim.s.buildings.is_empty(),"remove confirm")
	game.begin_draft("place","wall");game.update_draft(free_cell("wall"));game.confirm_draft()
	check(game.sim.s.buildings.size()==1,"obstacle confirmation")
	game.start_wave();game.paused=true
	var tick=game.sim.tick
	game._process(1.0)
	check(game.sim.tick==tick,"pause freezes combat")
	game.paused=false;game._process(0.2)
	check(game.sim.tick>tick,"resume advances combat")
	game._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	check(game.paused and b.fingers.is_empty(),"background pauses and clears touch")
	game.show_mobile_operations();await snap("operations");game.close_modal()
	for map_id in 5:
		game.chosen_map=map_id;game.begin_run(104729)
		await process_frame;await process_frame
		b=game.board;b.update_transform()
		check(b.offset.x>=0 and b.offset.y>=0 and b.point(Vector2(game.sim.s.width,game.sim.s.height)).x<=b.size.x+0.1 and b.point(Vector2(game.sim.s.width,game.sim.s.height)).y<=b.size.y+0.1,"full map "+str(map_id))
	await snap("large-map")
	game.chosen_map=0;game.begin_run(104729);game.starter_layout()
	game.focused_cell=game.sim.cell(game.sim.s.buildings.keys()[0]);game.board.focus_cell=game.focused_cell;game.refresh_tactical_panel()
	await snap("battle")
	game.show_settings();await snap("settings");game.close_modal()
	var out=FileAccess.open("res://build/mobile-test-results.json",FileAccess.WRITE)
	out.store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("MOBILE TEST ",checks," checks: ",failures)
	game.queue_free();await process_frame
	quit(0 if failures.is_empty() else 1)
