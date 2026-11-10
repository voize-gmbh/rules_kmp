"""Builds JVM code for a platform of maven.lock(platforms) with that platform's Maven resolution.

A module of such a platform, e.g. jvm_server, is built in a configuration of its own, and so is
everything it depends on: where the platform resolves a module of the hub's jvm package itself, the
jvm target stands for the platform's. The libraries of the repository the module uses are compiled
against the platform's versions too, and its classpaths hold one version of each Maven module.

The configuration is told apart by its platform suffix (the platform's name, also in its output
directory), which the exec transition resets: tools stay in the one exec configuration.
"""

_SUFFIX = "//command_line_option:platform_suffix"

def _transition_impl(settings, attr):
    return {_SUFFIX: attr.maven_platform or settings[_SUFFIX]}

maven_platform_transition = transition(
    implementation = _transition_impl,
    inputs = [_SUFFIX],
    outputs = [_SUFFIX],
)

MAVEN_PLATFORM_ATTRS = {
    "maven_platform": attr.string(
        doc = "A platform of maven.lock(platforms) to build this target and its dependencies for; empty keeps the configuration it is built in.",
    ),
}
