extends CharacterBody2D

const SPEED = 120
const JUMP_VELOCITY = -350

@onready var coyote_timer: Timer = $CoyoteTimer
@onready var input_buffer_timer: Timer = $InputBufferTimer
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

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


func _physics_process(delta: float) -> void:
	# Gravity is skipped during a dash.
	if not is_on_floor() and dash_timer == 0.0:
		var gravity = get_gravity()
		velocity += gravity * delta
		velocity += gravity * 0.75 * delta

	var direction := Input.get_axis("player_left", "player_right")

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
	move_and_slide()
	_finish_dash_frame(delta)

	update_animations(direction)
	wall_slide(delta)
	change_collision(direction)


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

	elif not input_buffer_timer.is_stopped() and not coyote_timer.is_stopped():
		velocity.y = JUMP_VELOCITY
		coyote_timer.stop()
		input_buffer_timer.stop()

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
			animated_sprite.play("default")
		else:
			animated_sprite.play("walk")
	else:
		if wall_contact_coyote > 0:
			animated_sprite.play("wall_slide")
		else:
			animated_sprite.play("jump" if velocity.y < 0 else "fall")
			


func change_collision(direction):
	if is_on_floor():
		collision_shape.position = Vector2(float(look_dir_x), 3.5)
		collision_shape.shape.size = Vector2(8.0, 21.0)
	else:
		collision_shape.position = Vector2(float(look_dir_x), -3.5)
		collision_shape.shape.size = Vector2(8.0, 9.0)

	collision_shape.position.x = abs(collision_shape.position.x) * look_dir_x


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
