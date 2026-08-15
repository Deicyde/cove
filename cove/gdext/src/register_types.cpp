#include "register_types.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "cove_iosurface.h"
#include "cove_input.h"
#include "cove_drag.h"

using namespace godot;

void initialize_cove_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(CoveIOSurface);
	GDREGISTER_CLASS(CoveInput);
	GDREGISTER_CLASS(CoveDrag);
}

void uninitialize_cove_module(ModuleInitializationLevel p_level) {
	(void)p_level;
}

extern "C" GDExtensionBool GDE_EXPORT cove_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_cove_module);
	init_obj.register_terminator(uninitialize_cove_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
