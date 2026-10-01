# Classroom furniture props for a Godot 4 brawl game

A green plastic school desk and chair, modelled on the reference video. Both are
ready-to-use physics props: you can push them, pick them up and throw them, and
they stay in sync in online or LAN multiplayer.

![Preview renders](docs/preview_sheet.jpg)
![Demo: shockwave sending the classroom flying](docs/demo_shockwave.jpg)

## What's inside

```
assets/classroom_furniture/
  models/school_desk.glb      desk mesh, ~2k tris, 3 materials
  models/school_chair.glb     chair mesh, ~5.8k tris, 3 materials
  textures/*.png              tileable 1024² PBR textures (albedo / normal / ORM)
  scenes/school_desk.tscn     RigidBody3D, 9 kg, 7 box colliders, net-synced
  scenes/school_chair.tscn    RigidBody3D, 4.5 kg, 7 box colliders, net-synced
  scripts/networked_prop.gd   pick up / throw / drop / hit detection + replication
  scripts/prop_holder.gd      component you put on your player's hands
demo/                         playable test level (9 desk + chair sets)
tests/                        headless physics + two-process network tests
tools/                        generators that rebuild the models, textures and scenes
```

**How it looks**
- **Desk:** 70 × 48 cm moulded top with a rounded rim and a pen groove along the
  back edge. It sits on grey powder-coated steel: single-post height-adjustable
  legs, wide flat floor bars with chunky black rubber caps, a low stretcher, and
  a wire book basket under the top. The top is 76 cm high.
- **Chair:** one-piece green plastic shell with a curved seat, pinched waist and
  round-topped backrest. It has the same grey steel post-and-foot-bar frame,
  plus a low wire basket between the posts: a bent round-tube rim with U-shaped
  wires. Seat height is 44 cm.
- **Colours** are sampled from the video. The phone's dark, desaturated filter is
  corrected out (using the white floor tiles as the white reference), which gives
  plastic `#8BC76D` and steel `#8E9094`. To change them, edit `PLASTIC_GREEN` /
  `STEEL_GREY` in `tools/generate_assets.py` and run it again.
- **Scale:** 1 unit = 1 m, +Y up, origin on the floor, and the student side faces +Z.

## Using it in your game (Godot 4.3+)

1. Copy the `assets/classroom_furniture` folder into your project at the
   **same path** (`res://assets/classroom_furniture`). If you'd rather put it
   somewhere else, move it inside the Godot editor so the paths get fixed for you.
2. Drag `school_desk.tscn` / `school_chair.tscn` into your level. Copies placed
   in the level are synced automatically, as long as every peer loads the same
   level. For furniture created while the game runs, add the two scenes to a
   `MultiplayerSpawner`'s *Auto Spawn List*.
3. Add a `PropHolder` node (`prop_holder.gd`) to your player, where the hands
   are. Then call it from the player's input code on the peer that controls
   that player:

   ```gdscript
   @onready var hands: PropHolder = $Hands

   func _unhandled_input(event):
       if not is_multiplayer_authority(): return
       if event.is_action_pressed("grab_throw"): hands.toggle_grab_throw()
       if event.is_action_pressed("drop"):       hands.drop()
   ```

   The holder must be owned by that player's peer. That's automatic if you call
   `set_multiplayer_authority(peer_id)` on the player root, which is the usual
   pattern. Also, the player's transform has to be replicated to the host.
   Optionally, set `aim_node` to your camera or head so throws go where the
   player looks.
4. Deal damage on hits. Fast props sweep one physics step ahead, so impacts
   register even when continuous collision detection stops the prop before it
   touches anything (Godot reports no contact then). The host emits
   `hit(body, impact_speed, thrower_peer_id)` on the prop, and if the body that
   was hit has a method `on_prop_hit(prop, impact_speed, thrower_peer_id)`, it
   calls that too:

   ```gdscript
   func on_prop_hit(prop, speed, thrower_id):
       health -= int(speed * 2)   # runs on the host; replicate health as usual
   ```

**Tuning** (in the Inspector, on each prop): `throw_speed`, `throw_lift`,
`throw_spin`, `max_pickup_distance`, `hold_offset` (where the prop sits relative
to the hands), `damage_min_speed`, plus `mass` and the physics material.

### How the networking works

- **The host runs the physics.** The prop's multiplayer authority (peer 1)
  simulates it as a real `RigidBody3D`.
- **Clients follow the host.** On clients the prop is frozen as *kinematic*, so
  players still bump into it, and it smoothly follows the replicated position,
  rotation, velocity and holder.
- **Players ask, the host decides.** Pick up, throw and drop are reliable RPCs
  to the host, which checks them: in range, not already held, one prop per
  player. A held or just-thrown prop ignores its holder, so you don't hit
  yourself.
- **Resting furniture costs no bandwidth.** Sync uses *on-change* replication
  at about 30 Hz.
- **Offline needs no extra code.** With no network peer, Godot acts as peer 1,
  so single player and same-screen local multiplayer use the same code path.

## Try the demo

Open the folder in Godot 4.3+ and press F5.

| Input | Action |
|---|---|
| Mouse | Move your hand (coloured ball) |
| Left mouse button | Grab or throw |
| Right mouse button | Drop |
| Space | Shockwave |
| R | Reset furniture |
| F1 | Host on port 7777 |
| F2 | Join 127.0.0.1 |

To test across your LAN, run one copy with `-- --host` and another with
`-- --join=<host IP>`.

## Tests

```bash
godot --headless --path . --import
godot --headless --path . --script res://tests/physics_test.gd      # offline
godot --headless --path . --script res://tests/net_test.gd -- server &
godot --headless --path . --script res://tests/net_test.gd -- client  # ENet localhost
```

Both suites pass on Godot 4.3. The physics test checks that the props settle
upright, can be grabbed, follow the hand, get thrown at about 13 m/s, and report
wall hits. In the network test a client grabs a chair and throws it; the host
sees the pickup, the flight (about 5 m), and hits credited to that client.

## Rebuilding the assets

```bash
pip install numpy pillow
python3 tools/generate_assets.py   # models + textures
python3 tools/make_scenes.py       # prop scenes / colliders
```
