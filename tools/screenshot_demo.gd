extends SceneTree
## Screenshot of the demo classroom mid-shockwave (used for the README):
##   xvfb-run godot --path . --rendering-driver opengl3 --script res://tools/screenshot_demo.gd -- <out.png>

func _initialize() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	root.size = Vector2i(1280, 720)
	var demo = load("res://demo/props_demo.tscn").instantiate()
	root.add_child(demo)
	demo.get_node("UI").visible = false
	for i in 30:
		await physics_frame
	demo._shockwave()
	for i in 22:
		await physics_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out)
	quit()
