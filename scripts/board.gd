extends Control
signal cell_clicked(cell: Vector2i, button: int)
signal selection_changed(cells: Array)
var sim
var selected = "rail"
var show_routes = true
var route_filter = -1 # -2: next-wave directions, -1: all
var special_routes = false
var grid = true
var zoom = 1.0
var pan = Vector2.ZERO
var cell_size = 30.0
var offset = Vector2.ZERO
var hover = Vector2i(-1,-1)
var dragging = false
var box_start = Vector2i(-1,-1)
var selection: Array = []
var pulse = 0.0
var effects = true
var damage_numbers = true
var terrain: Control
var cached_offset = Vector2.INF
var cached_cell_size = -1.0
var cached_grid = true
var floor_texture: ImageTexture
var invalid_cell = Vector2i(-1,-1)
var invalid_time = 0.0
const COLORS = [Color("69ddcb"),Color("f4bb71"),Color("b4a1ff"),Color("f08da1")]

func _ready():
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	terrain = Control.new()
	terrain.set_script(preload("res://scripts/terrain.gd"))
	terrain.board = self
	terrain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	terrain.show_behind_parent = true
	terrain.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(terrain)
	var img = Image.create(sim.s.width,sim.s.height,false,Image.FORMAT_RGB8)
	for y in sim.s.height:
		for x in sim.s.width: img.set_pixel(x,y,Color("122530") if (x+y)%2 == 0 else Color("10202b"))
	floor_texture = ImageTexture.create_from_image(img)
	terrain.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func _process(delta):
	pulse += delta
	invalid_time = maxf(0,invalid_time-delta)
	update_transform()
	if terrain != null and (offset != cached_offset or cell_size != cached_cell_size or grid != cached_grid):
		cached_offset = offset
		cached_cell_size = cell_size
		cached_grid = grid
		terrain.queue_redraw()
	queue_redraw()

func home():
	zoom = 1.0
	pan = Vector2.ZERO

func jump_to(index: int):
	if sim == null: return
	zoom = maxf(zoom,2.0)
	update_transform()
	pan = (Vector2(sim.s.width,sim.s.height)*0.5-Vector2(sim.entrances()[index])-Vector2.ONE*0.5)*cell_size

func update_transform():
	if sim == null or sim.s.is_empty(): return
	cell_size = minf((size.x-90)/sim.s.width,(size.y-70)/sim.s.height)*zoom
	offset = (size-Vector2(sim.s.width,sim.s.height)*cell_size)*0.5+pan

func point(p: Vector2) -> Vector2:
	return offset+p*cell_size

func cell_at(p: Vector2) -> Vector2i:
	return Vector2i(((p-offset)/cell_size).floor())

func _gui_input(event):
	if sim == null: return
	if event is InputEventMouseMotion:
		hover = cell_at(event.position)
		if dragging: pan += event.relative
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			dragging = event.pressed
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
			var before = (event.position-offset)/cell_size
			zoom = clampf(zoom*(1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1/1.15),0.65,5.0)
			update_transform()
			pan += event.position-point(before)
		elif event.button_index == MOUSE_BUTTON_LEFT and event.shift_pressed:
			if event.pressed: box_start = cell_at(event.position)
			else:
				selection.clear()
				var end = cell_at(event.position)
				for k in sim.s.buildings:
					var p = sim.cell(k)
					if p.x >= mini(box_start.x,end.x) and p.x <= maxi(box_start.x,end.x) and p.y >= mini(box_start.y,end.y) and p.y <= maxi(box_start.y,end.y): selection.append(p)
				box_start = Vector2i(-1,-1)
				selection_changed.emit(selection)
		elif event.pressed and event.button_index in [MOUSE_BUTTON_LEFT,MOUSE_BUTTON_RIGHT]:
			var mini = minimap_rect()
			if mini.has_point(event.position):
				var norm = (event.position-mini.position)/mini.size
				zoom = maxf(zoom,1.7)
				update_transform()
				pan = (Vector2(0.5,0.5)-norm)*Vector2(sim.s.width,sim.s.height)*cell_size
			else: cell_clicked.emit(cell_at(event.position),event.button_index)

func minimap_rect() -> Rect2:
	return Rect2(size.x-160,size.y-115,140,90)

func draw_terrain(canvas: Control):
	canvas.draw_rect(Rect2(Vector2.ZERO,size),Color("0a131e"))
	if sim == null or sim.s.is_empty(): return
	update_transform()
	var s: Dictionary = sim.s
	var outer = Rect2(offset,Vector2(s.width,s.height)*cell_size)
	canvas.draw_rect(outer.grow(6),Color("0d202b"))
	if floor_texture != null: canvas.draw_texture_rect(floor_texture,outer,false)
	if grid and cell_size > 9:
		var lines = PackedVector2Array()
		for x in range(s.width+1):
			lines.append(point(Vector2(x,0)))
			lines.append(point(Vector2(x,s.height)))
		for y in range(s.height+1):
			lines.append(point(Vector2(0,y)))
			lines.append(point(Vector2(s.width,y)))
		canvas.draw_multiline(lines,Color("1c303d"),0.65)
	for k in s.rocks:
		var c = point(Vector2(sim.cell(k))+Vector2.ONE*0.5)
		var r = cell_size*0.36
		canvas.draw_colored_polygon(PackedVector2Array([c+Vector2(-r,-r*0.5),c+Vector2(r*0.5,-r),c+Vector2(r,r*0.1),c+Vector2(r*0.5,r),c+Vector2(-r,r*0.6)]),Color("293b4b"))
		canvas.draw_line(c+Vector2(-r,-r*0.5),c+Vector2(r*0.5,-r),Color("496071"),2)
	for k in s.terrain:
		var pos = point(Vector2(sim.cell(k)))
		var terrain_id = s.terrain[k]
		var c = Color(sim.rules.terrain[terrain_id].color)
		canvas.draw_rect(Rect2(pos+Vector2.ONE*cell_size*0.08,Vector2.ONE*cell_size*0.84),c*Color(1,1,1,0.6))
		if terrain_id == "lane":
			canvas.draw_line(pos+Vector2(cell_size*0.2,cell_size*0.8),pos+Vector2(cell_size*0.8,cell_size*0.2),Color("ab9265"),1)
		elif terrain_id == "highland":
			canvas.draw_rect(Rect2(pos+Vector2.ONE*cell_size*0.18,Vector2.ONE*cell_size*0.64),Color("7baca8"),false,1)
		else: canvas.draw_line(pos+Vector2(cell_size*0.3,0),pos+Vector2(cell_size*0.65,cell_size),Color("b496c6"),1)

func _draw():
	if sim == null or sim.s.is_empty(): return
	update_transform()
	var s: Dictionary = sim.s
	var active: Array = sim.wave_info(int(s.completed)+1).dirs
	if show_routes:
		for dir in 4:
			if route_filter >= 0 and route_filter != dir: continue
			if route_filter == -2 and dir not in active: continue
			var path: Array = sim.paths[1 if special_routes else 0][dir]
			var color = COLORS[dir]
			color.a = 0.65 if dir in active else 0.25
			for i in range(1,path.size()):
				var a = point(Vector2(path[i-1])+Vector2.ONE*0.5)
				var b = point(Vector2(path[i])+Vector2.ONE*0.5)
				draw_line(a,b,color,maxf(1,cell_size*0.065),true)
				if i%3 == 0:
					var d = (b-a).normalized()
					draw_line(b,b-d.rotated(0.6)*cell_size*0.22,color,1.5,true)
					draw_line(b,b-d.rotated(-0.6)*cell_size*0.22,color,1.5,true)
	for i in 4:
		var pos = point(Vector2(sim.entrances()[i])+Vector2.ONE*0.5)
		if invalid_time > 0 and i in sim.invalid_entries: draw_arc(pos,cell_size*0.5,0,TAU,24,Color("ff597b"),3,true)
		draw_circle(pos,cell_size*0.40,COLORS[i]*Color(1,1,1,0.14))
		draw_arc(pos,cell_size*0.36,0,TAU,24,COLORS[i] if i in active else Color("475566"),2,true)
		var d: Vector2 = -Vector2(sim.DIRS[i])
		draw_line(pos-d*cell_size*0.2,pos+d*cell_size*0.2,COLORS[i],2,true)
	for p in sim.core_cells():
		draw_rect(Rect2(point(Vector2(p)),Vector2.ONE*cell_size),Color("183e47"))
	var center = point(Vector2(s.width,s.height)*0.5)
	var core_r = cell_size*(0.7 if s.width%2 == 0 else 1.02)
	draw_circle(center,core_r*1.7,Color(0.25,0.9,0.78,0.035+sin(pulse*2)*0.012))
	hexagon(center,core_r,Color("5ae2c5"),Color("153d49"))
	hexagon(center,core_r*0.64,Color("96ffe0"),Color("28665f"))
	draw_circle(center,core_r*0.22,Color("b5ffee"))
	for k in s.buildings:
		var b: Dictionary = s.buildings[k]
		var pos = point(Vector2(sim.cell(k))+Vector2.ONE*0.5)
		draw_building(pos,cell_size,b.id,b.angle)
		if b.id in ["wall","fence"] and b.hp < sim.defs[b.id].hp:
			draw_line(pos+Vector2(-cell_size*0.35,-cell_size*0.4),pos+Vector2(cell_size*(float(b.hp)/sim.defs[b.id].hp*0.7-0.35),-cell_size*0.4),Color("f2a476"),2)
	for e in sim.enemies:
		var pos = point(e.pos)
		var r = cell_size*(0.42 if e.type == "boss" else (0.30 if e.type == "elite" else 0.19))
		var c = Color(sim.rules.enemies[e.type].color)
		if e.slow > 0: c = c.lerp(Color("b1e9ff"),0.5)
		var d: Vector2 = (Vector2(e.next)+Vector2.ONE*0.5-e.pos).normalized()
		if d.length() < 0.1: d = Vector2.DOWN
		var side = d.orthogonal()
		draw_colored_polygon(PackedVector2Array([pos+d*r*1.4,pos+side*r,pos-d*r,pos-side*r]),c)
		if cell_size > 12:
			draw_line(pos-side*r*1.5-d*r*0.6,pos+side*r*1.5-d*r*0.6,c,1.2)
			draw_circle(pos+d*r*0.5,r*0.21,Color("111823"))
			if e.hp < e.max_hp:
				draw_line(pos+Vector2(-r,-r*1.8),pos+Vector2(r,-r*1.8),Color("442c3b"),2)
				draw_line(pos+Vector2(-r,-r*1.8),pos+Vector2(r*(2*e.hp/e.max_hp-1),-r*1.8),c,2)
	for shot in sim.shots:
		if not effects: break
		var c = Color(shot.color)
		c.a = minf(1.0,shot.life*9)
		draw_line(point(shot.from),point(shot.to),c,2 if shot.kind != "lance" else 3,true)
		if shot.kind in ["mortar","spike"]: draw_arc(point(shot.to),cell_size*(0.25+(0.13-shot.life)*7),0,TAU,20,c,1.5,true)
		if damage_numbers and cell_size > 20 and shot.damage >= 1 and sim.shots.size() < 25:
			draw_string(get_theme_default_font(),point(shot.to)+Vector2(4,-12),str(int(shot.damage)) if shot.damage<100000 else "%.1e" % shot.damage,HORIZONTAL_ALIGNMENT_LEFT,-1,12,c)
	for p in selection: draw_rect(Rect2(point(Vector2(p)),Vector2.ONE*cell_size).grow(-1),Color("ffe1a0"),false,2)
	if box_start.x >= 0:
		var a = point(Vector2(box_start))
		var b = point(Vector2(hover)+Vector2.ONE)
		draw_rect(Rect2(a,b-a).abs(),Color(0.5,0.9,0.8,0.15))
	if sim.inside(hover):
		var pos = point(Vector2(hover)+Vector2.ONE*0.5)
		var id = selected
		if s.buildings.has(sim.key(hover)): id = s.buildings[sim.key(hover)].id
		if sim.defs.has(id):
			if sim.defs[id].has("range"):
				var r = sim.effective_range(id,hover)*cell_size
				draw_circle(pos,r,Color(0.3,0.85,0.8,0.035))
				draw_arc(pos,r,0,TAU,60,Color(0.45,0.9,0.83,0.34),1,true)
		var c = Color("67e2c5") if sim.placement_error(selected,hover) == "" else Color("f07889")
		if invalid_time > 0 and hover == invalid_cell: c = Color("ff597b")
		draw_rect(Rect2(point(Vector2(hover)),Vector2.ONE*cell_size).grow(-1),c,false,2)
	# The minimap remains screen anchored when the battlefield is panned.
	var mini = minimap_rect()
	draw_rect(mini.grow(8),Color("08121d"))
	draw_rect(mini,Color("19303c"),false,1)
	var ratio = mini.size/Vector2(s.width,s.height)
	for k in s.buildings:
		draw_rect(Rect2(mini.position+Vector2(sim.cell(k))*ratio,ratio.max(Vector2(2,2))),Color(sim.defs[s.buildings[k].id].color))
	for e in sim.enemies: draw_circle(mini.position+e.pos*ratio,1.5,Color("f17d97"))
	draw_circle(mini.get_center(),3,Color("6cf4cc"))
	var view = Rect2((-offset/cell_size)*ratio+mini.position,size/cell_size*ratio).intersection(mini)
	draw_rect(view,Color("70928f"),false,1)

func hexagon(pos: Vector2,r: float,line: Color,fill: Color):
	var points = PackedVector2Array()
	for i in 6: points.append(pos+Vector2.from_angle(PI/3*i-PI/6)*r)
	draw_colored_polygon(points,fill)
	points.append(points[0])
	draw_polyline(points,line,1.8,true)

func draw_building(pos: Vector2,unit: float,id: String,angle: float):
	var c = Color(sim.defs[id].color)
	var r = unit*0.32
	if id in ["wall","fence"]:
		draw_rect(Rect2(pos-Vector2.ONE*r,Vector2.ONE*r*2),Color("253b4a"))
		draw_rect(Rect2(pos-Vector2.ONE*r,Vector2.ONE*r*2),c,false,1.5)
		for i in 3: draw_line(pos+Vector2(-r+i*r,-r),pos+Vector2(-r+i*r,r),c,1)
	elif id in ["spike","slow"]:
		draw_arc(pos,r,0,TAU,20,c,1.4,true)
		draw_line(pos+Vector2(-r,0),pos+Vector2(r,0),c,1)
		draw_line(pos+Vector2(0,-r),pos+Vector2(0,r),c,1)
		draw_circle(pos,r*0.3,c)
	else:
		draw_circle(pos+Vector2(0,unit*0.08),r*1.25,Color("07121b"))
		hexagon(pos,r,c,Color("1a303e"))
		var direction = Vector2.from_angle(angle)
		if id in ["arc","frost","pulse"]:
			draw_circle(pos,r*0.48,c)
			draw_arc(pos,r*0.76,pulse,pulse+4.3,16,c,1.2,true)
		elif id == "mortar":
			draw_circle(pos,r*0.62,c)
			draw_circle(pos,r*0.35,Color("10232e"))
		else:
			draw_line(pos-direction*r*0.25,pos+direction*r*1.35,c,maxf(2,unit*0.12),true)
			if id == "rail": draw_line(pos-direction.orthogonal()*r*0.24,pos+direction*r*1.15-direction.orthogonal()*r*0.24,c,1,true)
