extends Node2D
class_name TetrisBoard

## Attach to a Node2D in your main scene, alongside a TileMap that shares
## the same cell_size. Assign player_path to the platformer character.
## Requires Input Map actions: move_left, move_right, rotate_cw,
## rotate_ccw, soft_drop, hard_drop.

signal piece_locked(cells)
signal player_squashed
signal topped_out
@export var grid_width := 8          # narrower than classic 10 = tighter
@export var grid_height := 20        # corridor for the platformer to dodge in
@export var cell_size := 32          # on-screen size of each grid cell (gameplay scale)
@export var tile_map_layer: TileMapLayer
@export var active_piece_layer: TileMapLayer   # child of tile_map_layer — shows the falling piece
@export var player_path: NodePath
@export var block_texture: Texture2D    # the 16x16 sheet used by the Blocks TileSet
@export var block_source_id := 0        # TileSet source id — check the Blocks TileSet if unsure
@export var atlas_tile_size := 16       # the RAW pixel size of one tile in block_texture — must match your asset sheet, NOT cell_size

# --- feel / difficulty knobs, tune these by playtesting ---
@export var fall_interval := 0.8     # seconds per auto-drop step
@export var soft_drop_multiplier := 8.0
@export var lock_delay := 0.5        # grace period once a piece touches down

# --- the fairness mechanic: telegraph before slam, then cooldown ---
@export var telegraph_duration := 0.5
@export var slam_cooldown := 3.0

var grid: Array = []                 # grid[y][x] = piece name String or ""
var current_piece: String
var rotation_state := 0
var piece_pos: Vector2i
var fall_timer := 0.0
var lock_timer := 0.0
var slam_cooldown_timer := 0.0
var telegraphing := false
var telegraph_timer := 0.0
var telegraph_cells: Array = []
var bag: Array = []
var player_ref: Node2D


func _grid_origin() -> Vector2:
	# Single source of truth: wherever you drag the Blocks node IS the
	# origin. No separate value to keep in sync by hand.
	if tile_map_layer:
		return tile_map_layer.position
	return Vector2.ZERO


func _ready() -> void:
	grid.resize(grid_height)
	for y in grid_height:
		var row := []
		row.resize(grid_width)
		for x in grid_width:
			row[x] = ""
		grid[y] = row
	if player_path != NodePath():
		player_ref = get_node(player_path)
	spawn_piece()


func _process(delta: float) -> void:
	if slam_cooldown_timer > 0.0:
		slam_cooldown_timer -= delta

	if telegraphing:
		telegraph_timer -= delta
		# Blink by toggling visibility/tint on the active-piece layer instead
		# of a manual redraw — the tiles are already there, sitting correctly.
		if active_piece_layer:
			active_piece_layer.visible = sin(telegraph_timer * 20.0) > 0.0
			active_piece_layer.self_modulate = Color(1, 0.3, 0.3)
		if telegraph_timer <= 0.0:
			_execute_hard_drop()
		return

	var grounded := not _fits(current_piece, rotation_state, piece_pos + Vector2i(0, 1))

	if grounded:
		lock_timer -= delta
		if lock_timer <= 0.0:
			_settle_or_squash()
	else:
		lock_timer = lock_delay
		fall_timer += delta
		var interval := fall_interval
		if Input.is_action_pressed("soft_drop"):
			interval /= soft_drop_multiplier
		if fall_timer >= interval:
			fall_timer = 0.0
			piece_pos += Vector2i(0, 1)

	_update_active_piece_visual()


func _unhandled_input(event: InputEvent) -> void:
	if telegraphing:
		return
	if event.is_action_pressed("move_left"):
		_try_move(Vector2i(-1, 0))
	elif event.is_action_pressed("move_right"):
		_try_move(Vector2i(1, 0))
	elif event.is_action_pressed("rotate_cw"):
		_try_rotate(1)
	elif event.is_action_pressed("hard_drop") and slam_cooldown_timer <= 0.0:
		_start_telegraph()


func _start_telegraph() -> void:
	telegraphing = true
	telegraph_timer = telegraph_duration
	telegraph_cells = _get_world_cells(current_piece, rotation_state, piece_pos)


func _execute_hard_drop() -> void:
	telegraphing = false
	telegraph_cells = []
	if active_piece_layer:
		active_piece_layer.visible = true
		active_piece_layer.self_modulate = Color(1, 1, 1)

	var drop_pos := piece_pos
	while _fits(current_piece, rotation_state, drop_pos + Vector2i(0, 1)):
		drop_pos += Vector2i(0, 1)
	piece_pos = drop_pos

	if _check_squash(current_piece, rotation_state, piece_pos):
		emit_signal("player_squashed")
		return

	_lock_piece()
	slam_cooldown_timer = slam_cooldown


func _settle_or_squash() -> void:
	if _check_squash(current_piece, rotation_state, piece_pos):
		emit_signal("player_squashed")
	else:
		_lock_piece()


func _try_move(dir: Vector2i) -> void:
	if _fits(current_piece, rotation_state, piece_pos + dir):
		piece_pos += dir
		_update_active_piece_visual()


func _try_rotate(dir: int) -> void:
	var new_state := (rotation_state + dir + 4) % 4
	if _fits(current_piece, new_state, piece_pos):
		rotation_state = new_state
		_update_active_piece_visual()
	# No wall-kick table — a rotation that doesn't fit is just blocked.


func _fits(piece: String, rot: int, pos: Vector2i) -> bool:
	for offset in TetrominoData.SHAPES[piece][rot]:
		var cell: Vector2i = pos + offset
		if cell.x < 0 or cell.x >= grid_width or cell.y >= grid_height:
			return false
		if cell.y >= 0 and grid[cell.y][cell.x] != "":
			return false
	return true


func _get_world_cells(piece: String, rot: int, pos: Vector2i) -> Array:
	var cells := []
	for offset in TetrominoData.SHAPES[piece][rot]:
		cells.append(pos + offset)
	return cells


## Checked every frame the piece is grounded/telegraphing AND on hard-drop
## resolution — not just at final lock — so a slam can't skip past the
## player in a single step.
func _check_squash(piece: String, rot: int, pos: Vector2i) -> bool:
	if player_ref == null:
		return false
	var player_cells := _get_player_occupied_cells()
	for cell in _get_world_cells(piece, rot, pos):
		if cell in player_cells:
			return true
	return false


func _get_player_occupied_cells() -> Array:
	# Assumes the player has a CollisionShape2D with a RectangleShape2D.
	# Adjust get_rect() if your friend uses a CapsuleShape2D instead.
	var shape_node := player_ref.get_node("CollisionShape2D") as CollisionShape2D
	var extents: Vector2 = shape_node.shape.get_rect().size / 2.0
	var origin := _grid_origin()
	var top_left: Vector2 = player_ref.global_position - global_position - origin - extents
	var bottom_right: Vector2 = player_ref.global_position - global_position - origin + extents

	var min_x := int(floor(top_left.x / cell_size))
	var max_x := int(floor((bottom_right.x - 1) / cell_size))
	var min_y := int(floor(top_left.y / cell_size))
	var max_y := int(floor((bottom_right.y - 1) / cell_size))

	var cells := []
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			cells.append(Vector2i(x, y))
	return cells


func _lock_piece() -> void:
	var cells := _get_world_cells(current_piece, rotation_state, piece_pos)
	for cell in cells:
		if cell.y < 0:
			emit_signal("topped_out")
			return
		grid[cell.y][cell.x] = current_piece
		# Real atlas lookup — matches whatever you set in TetrominoData.TILE_ATLAS_COORDS
		if tile_map_layer:
			tile_map_layer.set_cell(cell, block_source_id, TetrominoData.TILE_ATLAS_COORDS[current_piece])
	if active_piece_layer:
		active_piece_layer.clear()
	emit_signal("piece_locked", cells)
	spawn_piece()


func reset_board() -> void:
	for y in grid_height:
		for x in grid_width:
			grid[y][x] = ""
	if tile_map_layer:
		tile_map_layer.clear()
	bag.clear()
	slam_cooldown_timer = 0.0
	telegraphing = false
	telegraph_cells = []
	spawn_piece()


func spawn_piece() -> void:
	if bag.is_empty():
		bag = TetrominoData.get_piece_names()
		bag.shuffle()
	current_piece = bag.pop_back()
	rotation_state = 0
	piece_pos = Vector2i(grid_width / 2 - 2, 0)
	lock_timer = lock_delay
	fall_timer = 0.0
	if not _fits(current_piece, rotation_state, piece_pos):
		emit_signal("topped_out")
	_update_active_piece_visual()


## Draws the falling piece through a real TileMapLayer (a child of
## tile_map_layer) instead of hand-rolled _draw() math. Being a child means
## it automatically shares tile_map_layer's exact position/scale — there's
## no origin or scale bookkeeping left to get out of sync.
func _update_active_piece_visual() -> void:
	if not active_piece_layer:
		return
	active_piece_layer.clear()
	if current_piece == "":
		return
	var atlas: Vector2i = TetrominoData.TILE_ATLAS_COORDS[current_piece]
	for cell in _get_world_cells(current_piece, rotation_state, piece_pos):
		if cell.y >= 0:
			active_piece_layer.set_cell(cell, block_source_id, atlas)
