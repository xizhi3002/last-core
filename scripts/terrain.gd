extends Control
# 静态地形绘制代理：棋盘视图变化时重绘，与每帧变化的战斗层分开。
var board
func _draw():
	if board != null: board.draw_terrain(self)
