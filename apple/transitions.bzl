"""Configuration transition from a Kotlin/Native target name to the matching Apple platform.

Kotlin/Native rules build in the host configuration and pass the target to the compiler; the
Objective-C and Swift code they link against (CocoaPods) has to be built for that platform by the
Apple C++/Swift toolchains instead, as rules_apple does for its bundles.
"""

# The minimum iOS version that Kotlin/Native binaries and the native code they link are built for.
IOS_MINIMUM_OS = str(Label("//config:ios_minimum_os"))

# Kotlin/Native target -> (apple_split_cpu, --cpu, platform).
_APPLE_TARGETS = {
    "ios_arm64": ("arm64", "ios_arm64", "@apple_support//platforms:ios_arm64"),
    "ios_simulator_arm64": ("sim_arm64", "ios_sim_arm64", "@apple_support//platforms:ios_sim_arm64"),
    "ios_x64": ("x86_64", "ios_x86_64", "@apple_support//platforms:ios_x86_64"),
}

APPLE_TARGETS = _APPLE_TARGETS.keys()

def _apple_target_transition_impl(settings, attr):
    if attr.target not in _APPLE_TARGETS:
        return {k: settings[k] for k in _OUTPUTS}
    split_cpu, cpu, platform = _APPLE_TARGETS[attr.target]
    return {
        "//command_line_option:apple_platform_type": "ios",
        "//command_line_option:apple_split_cpu": split_cpu,
        "//command_line_option:compiler": None,
        "//command_line_option:cpu": cpu,
        "//command_line_option:fission": [],
        "//command_line_option:grte_top": None,
        "//command_line_option:platforms": [Label(platform)],
        "//command_line_option:ios_minimum_os": settings[IOS_MINIMUM_OS],
        "//command_line_option:minimum_os_version": settings[IOS_MINIMUM_OS],
        "//command_line_option:macos_minimum_os": None,
        "//command_line_option:tvos_minimum_os": None,
        "//command_line_option:watchos_minimum_os": None,
    }

_OUTPUTS = [
    "//command_line_option:apple_platform_type",
    "//command_line_option:apple_split_cpu",
    "//command_line_option:compiler",
    "//command_line_option:cpu",
    "//command_line_option:fission",
    "//command_line_option:grte_top",
    "//command_line_option:platforms",
    "//command_line_option:ios_minimum_os",
    "//command_line_option:minimum_os_version",
    "//command_line_option:macos_minimum_os",
    "//command_line_option:tvos_minimum_os",
    "//command_line_option:watchos_minimum_os",
]

apple_target_transition = transition(
    implementation = _apple_target_transition_impl,
    inputs = _OUTPUTS + [IOS_MINIMUM_OS],
    outputs = _OUTPUTS,
)

def _host_transition_impl(settings, _attr):
    return {
        "//command_line_option:apple_platform_type": "macos",
        "//command_line_option:apple_split_cpu": "",
        "//command_line_option:compiler": None,
        "//command_line_option:cpu": settings["//command_line_option:host_cpu"],
        "//command_line_option:fission": [],
        "//command_line_option:grte_top": None,
        "//command_line_option:platforms": [settings["//command_line_option:host_platform"]],
        "//command_line_option:ios_minimum_os": None,
        "//command_line_option:minimum_os_version": None,
        "//command_line_option:macos_minimum_os": None,
        "//command_line_option:tvos_minimum_os": None,
        "//command_line_option:watchos_minimum_os": None,
    }

# Undoes rules_apple's (and apple_target_transition's) settings, so that Kotlin/Native targets inside
# an app bundle build in the host configuration, like everywhere else, instead of a second time.
apple_host_transition = transition(
    implementation = _host_transition_impl,
    inputs = [
        "//command_line_option:host_cpu",
        "//command_line_option:host_platform",
    ],
    outputs = _OUTPUTS,
)
