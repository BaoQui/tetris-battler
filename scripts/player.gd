extends CharacterBody2D

signal squashed
signal win_requested

# Damage / invincibility
@export var hit_invincibility_time: float = 1.0
@export var knockback_speed: float = 220.0
@export var knockback_up_boost: float = 160.0
@export var blink_interval: float = 0.08

var squash_lockout: float = 0.0
var _blink_tween: Tween

const SPEED = 120
const JUMP_VELOCITY = -350

@onready var coyote_timer: Timer = $CoyoteTimer
@onready var input_buffer_timer: Timer = $InputBufferTimer
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var ray_cast_2d: RayCast2D = $RayCast2D
@onready var walk_audio_player: AudioStreamPlayer2D = $SFX_HOLDER/WalkAudioPlayer
@onready var dash_audio_player: AudioStreamPlayer2D = $SFX_HOLDER/DashAudioPlayer
@onready var jump_audio_player: AudioStreamPlayer2D = $SFX_HOLDER/JumpAudioPlayer

# Win condition
var is_win: bool = false
var round_active: bool = false
var knockback_timer: float = 0.0
var _hurt_tween: Tween
@export var knockback_control_lock: float = 0.18

# Jump constants and variables
var wall_jump_lock: float = 0.0
const WALL_JUMP_LOCK_TIME: float = 0.18

var wall_contact_coyote: float = 0.0
const WALL_CONTACT_COYOTE_TIME: float = 0.2

var look_dir_x: int = 1
const WALL_JUMP_PUSH_FORCE: float = 250
const VELOCITY_WEIGHT_X: float = 0.10

var is_wall_sliding: bool = false
const GRAVITY_NORMAl: float = 14.5
const GRAVITY_WALL: float = 30
const WALLJUMP_VELOCITY = -350

# Dash constants and variables
const DASH_DISTANCE: float = 32.0
const DASH_TIME: float = 0.12
const DASH_SPEED: float = DASH_DISTANCE / DASH_TIME
const DASH_COOLDOWN: float = 0.5

var can_dash: bool = true
var dash_direction: int = 1
var dash_timer: float = 0.0
var dash_cooldown_timer: float = 0.0
var was_on_floor: bool = false

const spawn_visual_interval_dash: float = 0.06
const spawn_visual_interval_super_dash: float = 0.025
var spawn_visual_timer: float = 0.0

# Crouch variables
var is_crouching: bool = false

# Auto-unstuck
const UNSTUCK_MAX_PASSES: int = 4
const UNSTUCK_PUSH_MARGIN: float = 0.5


func _physics_process(delta: float) -> void:
	if not round_active:
		return
	squash_lockout = maxf(0.0, squash_lockout - delta)
	knockback_timer = maxf(0.0, knockback_timer - delta)
	if not is_on_floor() and dash_timer == 0.0:
		velocity += get_gravity() * 1.75 * delta
	var wants_crouch := Input.is_action_pressed("crouch") and is_on_floor()
	is_crouching = wants_crouch or (is_crouching and not _can_stand())
	var direction := Input.get_axis("player_left", "player_right")
	change_collision(direction)
	if knockback_timer <= 0.0:
		_jump(delta, direction)
		if wall_jump_lock <= 0.0 and dash_timer == 0.0:
			if direction > 0:
				animated_sprite.flip_h = false
				velocity.x = direction * SPEED
			elif direction < 0:
				animated_sprite.flip_h = true
				velocity.x = direction * SPEED
			else:
				velocity.x = move_toward(velocity.x, 0, SPEED)
			if direction and wall_contact_coyote == 0.0 and not is_on_wall():
				look_dir_x = int(direction)
		_dash_logic(delta)
	movement_audio()
	move_and_slide()
	if squash_lockout <= 0.0:
		for i in get_slide_collision_count():
			var contact := get_slide_collision(i)
			var collider := contact.get_collider()
			if not collider is Node:
				continue
			var falling_piece: bool = collider.is_in_group("tetris_piece")
			var locked_blocks: bool = collider.is_in_group("tetris_blocks")
			if not falling_piece and not locked_blocks:
				continue
			var slamming: bool = falling_piece and bool(collider.get_meta("slam_active", false))
			# Inspect THIS contact's normal, not is_on_ceiling() for other contacts.
			var hit_underside := contact.get_normal().dot(Vector2.DOWN) > 0.65
			if slamming or hit_underside:
				squashed.emit()
				break
	_finish_dash_frame(delta)
	_resolve_stuck_overlap()
	update_animations(direction)
	if knockback_timer <= 0.0:
		wall_slide(delta)

func _jump(delta, direction):
	if wall_jump_lock > 0.0:
		wall_jump_lock = maxf(0.0, wall_jump_lock - delta)

		if dash_timer == 0.0:
			velocity.x = lerp(
				velocity.x,
				direction * SPEED / 2,
				VELOCITY_WEIGHT_X * 0.5
			)
	elif dash_timer == 0.0:
		velocity.x = lerp(
			velocity.x,
			direction * SPEED / 2,
			VELOCITY_WEIGHT_X
		)

	if Input.is_action_just_pressed("player_jump"):
		input_buffer_timer.start()

	if is_on_floor():
		# Landing resets the dash cooldown.
		if not was_on_floor:
			dash_cooldown_timer = 0.0

		coyote_timer.start()

		if dash_timer == 0.0 and dash_cooldown_timer == 0.0 and not can_dash:
			can_dash = true

	was_on_floor = is_on_floor()

	# Prevent jumping from changing the dash direction or velocity.
	if dash_timer > 0.0:
		return

	if (
		not is_on_floor()
		and wall_contact_coyote > 0.0
		and Input.is_action_just_pressed("player_jump")
	):
		velocity.x = -look_dir_x * WALL_JUMP_PUSH_FORCE
		velocity.y = WALLJUMP_VELOCITY

		look_dir_x = -look_dir_x
		wall_jump_lock = WALL_JUMP_LOCK_TIME
		wall_contact_coyote = 0.0

		coyote_timer.stop()
		input_buffer_timer.stop()

		# Kicks away from the wall, biased slightly upward.
		_spawn_spark_burst(global_position, Vector2(look_dir_x, -0.4), 55.0)

	elif not input_buffer_timer.is_stopped() and not coyote_timer.is_stopped():
		velocity.y = JUMP_VELOCITY
		coyote_timer.stop()
		input_buffer_timer.stop()

		# Kicks down and out from the feet.
		_spawn_spark_burst(global_position, Vector2(0, 1), 110.0)

	elif not is_on_floor():
		if Input.is_action_just_released("player_jump"):
			velocity.y *= 0.70


func wall_slide(delta):
	# Wall sliding cannot change velocity during a dash.
	if dash_timer > 0.0:
		is_wall_sliding = false
		wall_contact_coyote = maxf(wall_contact_coyote - delta, 0.0)
		return

	is_wall_sliding = (
		not is_on_floor()
		and velocity.y > 0
		and is_on_wall()
		and (
			Input.is_action_pressed("player_left")
			or Input.is_action_pressed("player_right")
		)
	)

	if is_wall_sliding:
		look_dir_x = -int(get_wall_normal().x)
		wall_contact_coyote = WALL_CONTACT_COYOTE_TIME
		velocity.y = GRAVITY_WALL
	else:
		wall_contact_coyote = maxf(wall_contact_coyote - delta, 0.0)


func update_animations(direction):
	if is_on_floor():
		if direction == 0:
			if is_crouching:
				animated_sprite.play("crouch")
			else:
				animated_sprite.play("default")
		else:
			if is_crouching:
				animated_sprite.play("crouch_walk")
			else:
				animated_sprite.play("walk")
	else:
		if wall_contact_coyote > 0:
			animated_sprite.play("wall_slide")
		else:
			animated_sprite.play("jump" if velocity.y < 0 else "fall")


func change_collision(_direction):
	# Stable feet and head bounds: animation changes must not create false hits.
	collision_shape.position = Vector2(float(look_dir_x), 8.5 if is_crouching else 3.5)
	collision_shape.shape.size = Vector2(8.0, 11.0 if is_crouching else 21.0)

func _dash_logic(delta: float) -> void:
	if dash_cooldown_timer > 0.0:
		dash_cooldown_timer = maxf(0.0, dash_cooldown_timer - delta)

	if can_dash and Input.is_action_just_pressed("player_dash"):
		can_dash = false
		dash_timer = DASH_TIME
		dash_cooldown_timer = DASH_COOLDOWN

		# Keep this direction throughout the dash.
		dash_direction = look_dir_x

	if dash_timer > 0.0:
		# Scale the final frame to keep total movement at 32 pixels.
		var frame_fraction: float = minf(1.0, dash_timer / delta)
		velocity.x = DASH_SPEED * dash_direction * frame_fraction
		velocity.y = 0.0

		spawn_visual_timer -= delta
		if spawn_visual_timer <= 0.0:
			spawn_visual_timer = spawn_visual_interval_dash
			_spawn_dash_afterimage()


func _spawn_dash_afterimage() -> void:
	var ghost := Sprite2D.new()
	ghost.texture = animated_sprite.sprite_frames.get_frame_texture(
		animated_sprite.animation, animated_sprite.frame
	)
	ghost.global_position = global_position
	ghost.flip_h = animated_sprite.flip_h
	ghost.modulate = Color(0.75, 0.9, 1.0, 0.6)
	get_parent().add_child(ghost)

	var tween := create_tween()
	tween.tween_property(ghost, "modulate:a", 0.0, 0.2)
	tween.tween_callback(ghost.queue_free)


# Jump and wall-jump lightning particles.
const LIGHTNING_COUNT := 2
const LIGHTNING_LENGTH_MIN := 9.0
const LIGHTNING_LENGTH_MAX := 14.0
const LIGHTNING_LIFETIME_MIN := 0.10
const LIGHTNING_LIFETIME_MAX := 0.15


func _spawn_spark_burst(
	origin: Vector2,
	bias_dir: Vector2,
	cone_degrees: float = 70.0
) -> void:
	# A narrower spread keeps the burst small.
	var half_cone := deg_to_rad(cone_degrees) * 0.35

	for i in range(LIGHTNING_COUNT):
		var fraction := (
			float(i) + randf_range(0.3, 0.7)
		) / float(LIGHTNING_COUNT)

		var angle := bias_dir.angle() + lerpf(
			-half_cone, half_cone, fraction
		)
		var direction := Vector2.from_angle(angle)
		var offset := Vector2(
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0)
		)

		_spawn_lightning_bolt(origin + offset, direction)


func _spawn_lightning_bolt(
	origin: Vector2,
	direction: Vector2
) -> void:
	var bolt := Node2D.new()
	get_parent().add_child(bolt)
	bolt.top_level = true
	bolt.global_position = origin.round()
	bolt.z_index = 2

	var length := randf_range(
		LIGHTNING_LENGTH_MIN,
		LIGHTNING_LENGTH_MAX
	)
	var sideways := direction.orthogonal()
	var bend_sign := 1.0 if randf() > 0.5 else -1.0
	var bend := randf_range(1.5, 2.5) * bend_sign

	# A few broad bends, like the reference bolt.
	var points := PackedVector2Array([
		Vector2.ZERO,
		(direction * length * 0.20 + sideways * bend).round(),
		(direction * length * 0.40 + sideways * bend).round(),
		(direction * length * 0.55 - sideways * bend).round(),
		(direction * length * 0.75 - sideways * bend * 0.5).round(),
		(direction * length).round()
	])

	# Small dark teal halo.
	_add_lightning_layer(
		bolt, points, 4.0,
		Color(0.08, 0.35, 0.38, 0.22)
	)

	# Thin cyan edge surrounding a thicker white center.
	_add_lightning_layer(
		bolt, points, 2.8,
		Color(0.45, 1.0, 1.0, 0.8)
	)
	_add_lightning_layer(
		bolt, points, 1.8,
		Color(1.0, 1.0, 1.0, 1.0)
	)

	var lifetime := randf_range(
		LIGHTNING_LIFETIME_MIN,
		LIGHTNING_LIFETIME_MAX
	)
	var drift := direction * randf_range(1.0, 3.0)

	var tween := bolt.create_tween()
	tween.set_parallel(true)

	tween.tween_property(
		bolt,
		"global_position",
		bolt.global_position + drift,
		lifetime
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	# Hold briefly, then fade without the extra flickering.
	tween.tween_property(
		bolt, "modulate:a", 0.0, lifetime * 0.65
	).set_delay(lifetime * 0.35)

	tween.chain().tween_callback(bolt.queue_free)


func _add_lightning_layer(
	bolt: Node2D,
	points: PackedVector2Array,
	width: float,
	color: Color
) -> void:
	var line := Line2D.new()
	line.points = points
	line.width = width
	line.default_color = color
	line.antialiased = false
	line.joint_mode = Line2D.LINE_JOINT_BEVEL
	line.begin_cap_mode = Line2D.LINE_CAP_NONE
	line.end_cap_mode = Line2D.LINE_CAP_NONE
	bolt.add_child(line)


func _finish_dash_frame(delta: float) -> void:
	if dash_timer <= 0.0:
		return

	dash_timer = maxf(0.0, dash_timer - delta)

	# A wall stops the dash early.
	if is_on_wall():
		dash_timer = 0.0

	# Remove dash momentum when finished.
	if dash_timer == 0.0:
		velocity.x = 0.0


func check_above() -> bool:
	return ray_cast_2d.is_colliding()


func movement_audio():
	walk_audio_player.pitch_scale = .8
	if abs(velocity.x) > 0 && (is_on_floor()) && is_crouching == false:
		if not walk_audio_player.playing:
			walk_audio_player.play()

	if dash_timer > 0.0 and Input.is_action_just_pressed("player_dash"):
		dash_audio_player.play()

	if (is_on_floor() or wall_jump_lock > 0.0) and Input.is_action_just_pressed("player_jump"):
		jump_audio_player.play()


# Push out of overlapping geometry using the measured penetration depth.
func _resolve_stuck_overlap() -> void:
	for i in UNSTUCK_MAX_PASSES:
		var collision := move_and_collide(Vector2.ZERO, true, safe_margin, true)
		if not collision:
			break
		var push_distance: float = collision.get_depth() + UNSTUCK_PUSH_MARGIN
		global_position += collision.get_normal() * push_distance


# Shared entry point for damage from any source.
func take_hit(knockback_dir: Vector2 = Vector2.ZERO) -> bool:
	if not round_active or is_win or squash_lockout > 0.0:
		return false
	squash_lockout = maxf(hit_invincibility_time, 0.01)
	dash_timer = 0.0
	wall_jump_lock = 0.0
	wall_contact_coyote = 0.0
	is_wall_sliding = false
	coyote_timer.stop()
	input_buffer_timer.stop()
	knockback_timer = maxf(knockback_control_lock, 0.0)
	flash_hurt()
	_apply_knockback(knockback_dir)
	_start_invincibility_blink()
	return true

func _apply_knockback(dir: Vector2) -> void:
	var push_dir := dir
	if push_dir == Vector2.ZERO:
		push_dir = Vector2(-look_dir_x, 0)

	push_dir = push_dir.normalized()
	velocity.x = push_dir.x * knockback_speed
	velocity.y = -knockback_up_boost


# Animate self_modulate so blinking can run alongside the damage color flash.
func _start_invincibility_blink() -> void:
	if not animated_sprite:
		return

	if _blink_tween and _blink_tween.is_valid():
		_blink_tween.kill()

	animated_sprite.self_modulate.a = 1.0
	_blink_tween = create_tween()

	var cycles := maxi(1, int(hit_invincibility_time / (maxf(blink_interval, 0.01) * 2.0)))
	for i in cycles:
		_blink_tween.tween_property(
			animated_sprite, "self_modulate:a", 0.25, blink_interval
		)
		_blink_tween.tween_property(
			animated_sprite, "self_modulate:a", 1.0, blink_interval
		)

	_blink_tween.tween_callback(func(): animated_sprite.self_modulate.a = 1.0)


func flash_hurt() -> void:
	if not animated_sprite:
		return

	var hurt_color := Color(1.0, 0.15, 0.15)
	if _hurt_tween and _hurt_tween.is_valid():
		_hurt_tween.kill()
	_hurt_tween = create_tween()
	var tween := _hurt_tween
	tween.tween_property(animated_sprite, "modulate", hurt_color, 0.05)
	tween.tween_property(animated_sprite, "modulate", Color.WHITE, 0.05)
	tween.tween_property(animated_sprite, "modulate", hurt_color, 0.05)
	tween.tween_property(animated_sprite, "modulate", Color.WHITE, 0.05)


func _on_area_2d_body_entered(body: Node2D) -> void:
	if body == self and round_active and not is_win:
		win_requested.emit()


func _ready() -> void:
	# Each player owns its shape; resizing never changes another instance.
	if collision_shape.shape:
		collision_shape.shape = collision_shape.shape.duplicate()


func _can_stand() -> bool:
	var shape := RectangleShape2D.new()
	shape.size = Vector2(7.8, 20.8)
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	query.transform = global_transform * Transform2D(0.0, Vector2(float(look_dir_x), 3.5))
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	return get_world_2d().direct_space_state.intersect_shape(query, 1).is_empty()


func set_round_active(active: bool) -> void:
	round_active = active
	if not active:
		velocity = Vector2.ZERO
		walk_audio_player.stop()
		dash_audio_player.stop()
		jump_audio_player.stop()


func finish_round(won: bool) -> void:
	set_round_active(false)
	is_win = won
	dash_timer = 0.0
	coyote_timer.stop()
	input_buffer_timer.stop()
	_stop_hurt_effects()
	if won and animated_sprite.sprite_frames.has_animation("win"):
		animated_sprite.play("win")
	elif animated_sprite.sprite_frames.has_animation("death"):
		animated_sprite.play("death")
	else:
		animated_sprite.stop()


func _stop_hurt_effects() -> void:
	if _blink_tween and _blink_tween.is_valid():
		_blink_tween.kill()
	if _hurt_tween and _hurt_tween.is_valid():
		_hurt_tween.kill()
	animated_sprite.modulate = Color.WHITE
	animated_sprite.self_modulate = Color.WHITE


func reset_for_round(spawn_position: Vector2) -> void:
	set_round_active(false)
	is_win = false
	global_position = spawn_position
	squash_lockout = 0.0
	knockback_timer = 0.0
	wall_jump_lock = 0.0
	wall_contact_coyote = 0.0
	is_wall_sliding = false
	is_crouching = false
	can_dash = true
	dash_timer = 0.0
	dash_cooldown_timer = 0.0
	spawn_visual_timer = 0.0
	was_on_floor = false
	look_dir_x = 1
	dash_direction = 1
	coyote_timer.stop()
	input_buffer_timer.stop()
	_stop_hurt_effects()
	animated_sprite.flip_h = false
	collision_shape.disabled = false
	change_collision(0)
	animated_sprite.play("default")
