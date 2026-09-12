extends CharacterBody2D


const SPEED = 120
const JUMP_VELOCITY = -350
@onready var coyote_timer: Timer = $CoyoteTimer
@onready var input_buffer_timer: Timer = $InputBufferTimer
@onready var dash_timer: Timer = $DashTimer

#Jump Const and Variables
var wall_jump_lock: float = 0.0
const WALL_JUMP_LOCK_TIME: float = .18
var wall_contact_coyote: float = 0.0
const WALL_CONTACT_COYOTE_TIME: float = 0.2
var look_dir_x: int = 1
const WALL_JUMP_PUSH_FORCE: float = 250
const VELOCITY_WEIGHT_X: float = .10
var is_wall_sliding: bool = false
const GRAVITY_NORMAl: float = 14.5
const GRAVITY_WALL: float = 30
const WALLJUMP_VELOCITY = -350

#Dash Variables
const DASH_SPEED: float = 200
const DASH_TIME: float = 0.18
const DASH_COOLDOWN: float = 0.25  
var is_dashing: bool = false
var can_dash: bool = true
var dash_direction: int = 1
var dash_cooldown_timer: float = 0.0


func _physics_process(delta: float) -> void:
	if _dash(delta, Input.get_axis("player_left", "player_right")):
		move_and_slide()
		return
	# Add the gravity.
	if not is_on_floor():
		var gravity = get_gravity()
		velocity += get_gravity() * delta
		if Input.is_action_pressed("player_jump") && velocity.y < 0:
			if wall_jump_lock > 0.0:
				velocity += gravity * .75 * delta
			else:
				velocity += gravity * .75 * delta
		else:
			velocity += gravity * delta
	# Handle jump.
	if Input.is_action_just_pressed("player_jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var direction := Input.get_axis("player_left", "player_right")
	#Movement Acceleration/Declea
	_jump(delta, direction)
	if wall_jump_lock <= 0.0:
		if direction:
			velocity.x = direction * SPEED
		else:
			velocity.x = move_toward(velocity.x, 0, SPEED)

	move_and_slide()
	wall_slide(delta)
func _jump(delta, direction):
		#When wall_jumping
	if wall_jump_lock > 0.0:
		wall_jump_lock -= delta
		#Lerp(from, to weight) -> Current Velocity -> New Velocity -> Weight (For not snapping instantly to the new value but slowly: Game Feel)
		velocity.x = lerp(velocity.x, direction * SPEED /2, VELOCITY_WEIGHT_X * 0.5)	
	else: 
		velocity.x = lerp(velocity.x, direction * SPEED /2, VELOCITY_WEIGHT_X)
	
	if Input.is_action_just_pressed("player_jump"):
		#Input Buffer (Makes it so you can queue a jump before you hit the ground)
		$InputBufferTimer.start()
	
	#Floor Reset values and Coyote Time starts on floor and restarts CoyoteTimer to max value
	if is_on_floor():
		#Coyote Timer (Makes it so you have some grace to jump after falling off the ledge)
		$CoyoteTimer.start()
		
	#Input Timer active (Pressed Jump Recently), Coyote Timer Active (Grace Active), and check_above(nothing straight above your head
	if not $InputBufferTimer.is_stopped() and not $CoyoteTimer.is_stopped():
		velocity.y = JUMP_VELOCITY
		$CoyoteTimer.stop()
		$InputBufferTimer.stop()
	#Air Actions
	elif !is_on_floor():
		
		if Input.is_action_just_pressed("player_jump"):
			#if on wall and press jump -> Wall Jump
			if wall_contact_coyote > 0.0:
				velocity.x = -look_dir_x * WALL_JUMP_PUSH_FORCE
				velocity.y = WALLJUMP_VELOCITY

				wall_jump_lock = WALL_JUMP_LOCK_TIME
				wall_contact_coyote = 0.0				
			
		
		#if jump released, jump descends much faster so less floaty character
		if Input.is_action_just_released("player_jump"):
			velocity.y = velocity.y * .70
			
func wall_slide(delta):
	is_wall_sliding = !is_on_floor() and velocity.y > 0 and is_on_wall() and (Input.is_action_pressed("player_left") or Input.is_action_pressed("player_right"))
		
	if is_wall_sliding:
		look_dir_x = -int(get_wall_normal().x)
		wall_contact_coyote = WALL_CONTACT_COYOTE_TIME
		if Input.is_action_pressed("crouch"):
			velocity.y = GRAVITY_WALL + 50
		else:
			velocity.y = GRAVITY_WALL
		
	else: 
		wall_contact_coyote = max(wall_contact_coyote - delta, 0.0)
		
func _dash(delta: float, direction: float) -> bool:
	if dash_cooldown_timer > 0.0:
		dash_cooldown_timer -= delta
	elif is_on_floor() and not is_dashing:
		can_dash = true
		
	if Input.is_action_just_pressed("player_dash") and can_dash and not is_dashing:
		is_dashing = true
		can_dash = false
		dash_direction = look_dir_x if direction == 0 else int(sign(direction))
		dash_timer.start(DASH_TIME)

	if is_dashing:
		velocity.x = dash_direction * DASH_SPEED
		velocity.y = 0
		if dash_timer.is_stopped():
			is_dashing = false
			dash_cooldown_timer = DASH_COOLDOWN  

	return is_dashing
