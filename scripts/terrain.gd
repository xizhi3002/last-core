extends Control
var board
func _draw():
	if board != null: board.draw_terrain(self)
