#include "register_types.h"
#include "sparkle_updater.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_sparkle_update_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<SparkleUpdater>();
}

void uninitialize_sparkle_update_module(ModuleInitializationLevel p_level) {
	// Nothing to tear down.
}

extern "C" {
// Entry point referenced by sparkle_update.gdextension (entry_symbol).
GDExtensionBool GDE_EXPORT sparkle_update_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_sparkle_update_module);
	init_obj.register_terminator(uninitialize_sparkle_update_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
