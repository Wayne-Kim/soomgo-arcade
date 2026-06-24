#pragma once
// SparkleUpdater: a thin GDExtension class exposing the macOS Sparkle updater to GDScript.
// GDScript talks to this only through the UpdateManager autoload facade.

#include <godot_cpp/classes/ref_counted.hpp>

namespace godot {

class SparkleUpdater : public RefCounted {
	GDCLASS(SparkleUpdater, RefCounted)

protected:
	static void _bind_methods();

public:
	SparkleUpdater();
	~SparkleUpdater();

	// Nudge a background update check now (Sparkle still also checks on its own schedule).
	void start_automatic_checks();
	// Present Sparkle's user-facing "Check for Updates" flow.
	void check_for_updates();

private:
	// Opaque pointer to the retained SPUStandardUpdaterController (Objective-C); kept void* so
	// this header stays pure C++ and compiles in non-Objective-C translation units.
	void *controller = nullptr;
};

} // namespace godot
