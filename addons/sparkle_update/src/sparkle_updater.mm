// Objective-C++ implementation: bridges godot::SparkleUpdater to Sparkle's standard updater.
// Built only for the macOS target (see SConstruct); never compiled on other platforms.

#include "sparkle_updater.h"

#import <Foundation/Foundation.h>
#import <Sparkle/Sparkle.h>

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void SparkleUpdater::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start_automatic_checks"), &SparkleUpdater::start_automatic_checks);
	ClassDB::bind_method(D_METHOD("check_for_updates"), &SparkleUpdater::check_for_updates);
}

SparkleUpdater::SparkleUpdater() {
	@autoreleasepool {
		// Starting the updater immediately enables Sparkle's automatic background checks using the
		// SUFeedURL / SUPublicEDKey from the app's Info.plist. No delegates needed for the common
		// "check automatically, prompt the user when an update exists" behaviour.
		SPUStandardUpdaterController *c =
			[[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES
														updaterDelegate:nil
													  userDriverDelegate:nil];
		controller = (__bridge_retained void *)c; // keep it alive for this object's lifetime
	}
}

SparkleUpdater::~SparkleUpdater() {
	if (controller) {
		// Balance the __bridge_retained above so the controller is released.
		SPUStandardUpdaterController *c = (__bridge_transfer SPUStandardUpdaterController *)controller;
		(void)c;
		controller = nullptr;
	}
}

void SparkleUpdater::start_automatic_checks() {
	if (!controller) {
		return;
	}
	SPUStandardUpdaterController *c = (__bridge SPUStandardUpdaterController *)controller;
	[c.updater checkForUpdatesInBackground];
}

void SparkleUpdater::check_for_updates() {
	if (!controller) {
		return;
	}
	SPUStandardUpdaterController *c = (__bridge SPUStandardUpdaterController *)controller;
	[c checkForUpdates:nil];
}
