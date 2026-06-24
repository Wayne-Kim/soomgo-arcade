class_name SoundControl
extends RefCounted
## Reusable build helper for the SFX volume/mute control surface.
##
## Returns a self-contained Control wiring a Mute toggle + a volume Slider straight to
## the `Audio` autoload (which persists the choice across sessions). Built in code — like
## the rest of the UI — so every piece gets an accessible label/description, a visible
## focus ring from the high-contrast theme, and the full set of interactive states
## (enabled / disabled / focus). No new colours are introduced: it inherits the
## functional theme. Every exposed string is resolved via the translation server so it
## ships in all supported locales (en, ko).
##
## Used in the Lobby (reachable before a match) and the in-game pause overlay, so the
## audio choice can be changed from either surface and always reflects the live value.

## Build the control. `compact` drops the heading label for embedding inside an existing
## titled panel (e.g. the pause overlay).
static func build(compact: bool = false) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	if not compact:
		var heading := Label.new()
		heading.text = TranslationServer.translate("SETTINGS_SOUND")
		box.add_child(heading)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	A11y.label(row, TranslationServer.translate("SETTINGS_SOUND"), TranslationServer.translate("A11Y_SOUND"))
	box.add_child(row)

	var mute := CheckButton.new()
	mute.text = TranslationServer.translate("SETTINGS_MUTE")
	mute.button_pressed = Audio.is_muted()
	A11y.label(mute, TranslationServer.translate("SETTINGS_MUTE"), TranslationServer.translate("A11Y_MUTE"))
	A11y.make_focusable(mute)
	row.add_child(mute)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = Audio.volume()
	slider.custom_minimum_size = Vector2(160, 0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Disabled state: the volume slider is meaningless while muted, so it greys out and
	# is non-focusable until unmuted — a clear, redundant signal of the mute state.
	slider.editable = not Audio.is_muted()
	slider.focus_mode = Control.FOCUS_ALL if not Audio.is_muted() else Control.FOCUS_NONE
	A11y.label(slider, TranslationServer.translate("SETTINGS_VOLUME"), TranslationServer.translate("A11Y_VOLUME"))
	row.add_child(slider)

	slider.value_changed.connect(func(v: float): Audio.set_volume(v))
	mute.toggled.connect(func(pressed: bool):
		Audio.set_muted(pressed)
		slider.editable = not pressed
		slider.focus_mode = Control.FOCUS_ALL if not pressed else Control.FOCUS_NONE)

	return box
