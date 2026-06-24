class_name A11y
extends RefCounted
## Accessibility helpers. Sets an accessible name/description on a control (using
## Godot 4.6's accessibility properties when available) and always sets tooltip_text
## as a universally-supported fallback. Keeps every interactive element labelled.

static func label(control: Control, name: String, description: String = "") -> void:
	if control == null:
		return
	control.tooltip_text = name if description.is_empty() else "%s — %s" % [name, description]
	# Godot 4.6 exposes accessibility metadata on Control; set defensively.
	if "accessibility_name" in control:
		control.set("accessibility_name", name)
	if not description.is_empty() and "accessibility_description" in control:
		control.set("accessibility_description", description)

static func make_focusable(control: Control) -> void:
	control.focus_mode = Control.FOCUS_ALL
