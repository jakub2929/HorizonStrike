extends SceneTree
## Dev/build only: writes Godot's own license and the copyright info of the libraries it bundles to a file.
##   godot --headless --path game --script res://dev/print_licenses.gd -- <out file>


func _initialize() -> void:
	var ua := OS.get_cmdline_user_args()
	var out := ua[0] if ua.size() > 0 else "godot_licenses.txt"
	var t := "Godot Engine %s\n%s\n\n" % [Engine.get_version_info().get("string", ""), Engine.get_license_text()]
	t += "Third-party components bundled in the Godot Engine\n==================================================\n\n"
	for c in Engine.get_copyright_info():
		t += "* %s\n" % c.get("name", "")
		for part in c.get("parts", []):
			for cr in part.get("copyright", []):
				t += "  Copyright %s\n" % cr
			t += "  License: %s\n" % part.get("license", "")
		t += "\n"
	var licenses: Dictionary = Engine.get_license_info()
	t += "\nLicense texts\n=============\n\n"
	for k in licenses:
		t += "--- %s ---\n%s\n\n" % [k, licenses[k]]
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		printerr("cannot write %s" % out)
		quit(1)
		return
	f.store_string(t)
	f.close()
	print("licenses written: %s (%d bytes)" % [out, t.length()])
	quit(0)
