#!/usr/bin/env python3
"""Generate the checked-in, dependency-free iOS Xcode project deterministically."""
from pathlib import Path
from hashlib import sha1
from xml.sax.saxutils import escape
import json

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'Apps/iOS'
PROJECT = APP / 'SwarmHub.xcodeproj'
PROJECT.mkdir(parents=True, exist_ok=True)

def uid(name):
    return sha1(name.encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(str(value))

objects = []
def obj(name, body):
    objects.append(f'\t\t{uid(name)} = {{ {body} }};')
    return uid(name)

source_refs = []
source_builds = []
for source in sorted((APP / 'Sources').glob('*.swift')):
    relative = source.relative_to(APP).as_posix()
    ref = obj('ref:' + relative, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(relative)}; sourceTree = SOURCE_ROOT;')
    build = obj('build:' + relative, f'isa = PBXBuildFile; fileRef = {ref};')
    source_refs.append(ref)
    source_builds.append(build)
asset = obj('assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Resources/Assets.xcassets; sourceTree = SOURCE_ROOT;')
asset_build = obj('assets-build', f'isa = PBXBuildFile; fileRef = {asset};')
product = obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = SwarmHub.app; sourceTree = BUILT_PRODUCTS_DIR;')
package = obj('core-package', 'isa = XCLocalSwiftPackageReference; relativePath = ../../Packages/SwarmHubCore;')
core_product = obj('core-product', f'isa = XCSwiftPackageProductDependency; package = {package}; productName = SwarmHubCore;')
core_build = obj('core-build', f'isa = PBXBuildFile; productRef = {core_product};')
# P5d: fail the build if shared-key approval code reaches this target (scripts/check-ios-approvals.py).
boundary_script = 'python3 "$SRCROOT/../../scripts/check-ios-approvals.py" --root "$SRCROOT/../.."\n'
boundary = obj('approval-boundary-phase', f'isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); name = "Check device-signed approvals"; outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = {quote(boundary_script)};')
sources = obj('sources-phase', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(source_builds)}); runOnlyForDeploymentPostprocessing = 0;')
resources = obj('resources-phase', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({asset_build}); runOnlyForDeploymentPostprocessing = 0;')
frameworks = obj('frameworks-phase', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({core_build}); runOnlyForDeploymentPostprocessing = 0;')
products_group = obj('products-group', f'isa = PBXGroup; children = ({product}); name = Products; sourceTree = "<group>";')
group = obj('main-group', f'isa = PBXGroup; children = ({",".join(source_refs + [asset,products_group])}); sourceTree = "<group>";')
project_configurations = []
target_configurations = []
for name in ['Debug', 'Release']:
    common = {'CLANG_ENABLE_MODULES':'YES', 'IPHONEOS_DEPLOYMENT_TARGET':'18.0', 'SDKROOT':'iphoneos', 'SWIFT_VERSION':'6.0'}
    target = {'PRODUCT_BUNDLE_IDENTIFIER':'com.konrad.swarmhub.ios', 'PRODUCT_NAME':'SwarmHub', 'TARGETED_DEVICE_FAMILY':'1',
              'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST':'NO', 'GENERATE_INFOPLIST_FILE':'YES',
              'INFOPLIST_KEY_CFBundleDisplayName':'SwarmHub', 'INFOPLIST_KEY_UILaunchScreen_Generation':'YES',
              'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES', 'INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents':'YES',
              'INFOPLIST_KEY_UISupportedInterfaceOrientations':'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',
              'MARKETING_VERSION':'0.1.0', 'CURRENT_PROJECT_VERSION':'1', 'CODE_SIGN_STYLE':'Automatic',
              'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon', 'SWIFT_STRICT_CONCURRENCY':'complete',
              # The boundary phase reads repository sources outside the declared inputs.
              'ENABLE_USER_SCRIPT_SANDBOXING':'NO'}
    if name == 'Debug':
        target.update(SWIFT_OPTIMIZATION_LEVEL='-Onone', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG', ENABLE_TESTABILITY='YES')
    else:
        target.update(SWIFT_OPTIMIZATION_LEVEL='-O', SWIFT_COMPILATION_MODE='wholemodule')
    def settings(values):
        return ' '.join(key + ' = ' + quote(value) + ';' for key,value in sorted(values.items()))
    project_configurations.append(obj('project-' + name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ {settings(common)} }};'))
    target_configurations.append(obj('target-' + name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ {settings(target)} }};'))
pc = obj('project-configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(project_configurations)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
tc = obj('target-configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(target_configurations)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = obj('app-target', f'isa = PBXNativeTarget; name = SwarmHub; productName = SwarmHub; productType = "com.apple.product-type.application"; productReference = {product}; buildConfigurationList = {tc}; buildPhases = ({boundary},{sources},{frameworks},{resources}); buildRules = (); dependencies = (); packageProductDependencies = ({core_product});')
project = obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {pc}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = {group}; productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; packageReferences = ({package}); targets = ({target});')
(PROJECT / 'project.pbxproj').write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + '\n\t};\n\trootObject = ' + project + ';\n}\n')
scheme_dir = PROJECT / 'xcshareddata/xcschemes'
scheme_dir.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="SwarmHub.app" BlueprintName="SwarmHub" ReferencedContainer="container:SwarmHub.xcodeproj"/>'
(scheme_dir / 'SwarmHub.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print('Generated ' + str(PROJECT.relative_to(ROOT)))
